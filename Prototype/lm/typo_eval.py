#!/usr/bin/env python3
"""Score the typo-correction idea offline.

Input: Prototype/typo_dump.json (candidate lists dumped by CI for the
typo'd input and every 1-edit variant) + Prototype/candidates.json (the
clean-input candidate lists from the rerank harness) + the trained LM.

Per item:
- typo_app_top1 : the typo'd input's app-order first candidate == expected
- typo_lm_top1  : LM-best of the typo'd input's own candidates == expected
- pool_lm_top1  : LM-best of the pool (typo candidates + every variant's
                  candidates, deduped) == expected  <- the proposed feature
- ceiling       : expected present anywhere in the pool
- clean baselines (same items, from candidates.json): app / LM top-1
- over-correction control: pool the CLEAN candidates with the clean
  variants' candidates; the LM winner must not change (dethrone rate),
  and must stay == expected where the clean-only winner was expected.
- trigger separability: LM winner score (sum and per-char avg) for clean
  inputs vs typo inputs — if these separate, a "run correction only when
  the top score is low" trigger is viable.
"""
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROTO = HERE.parent
sys.path.insert(0, str(HERE))

from rerank_eval import load_model, score_strings  # noqa: E402
from gen_typo_fixture import to_hira  # noqa: E402


def lm_winner(model, stoi, strings):
    """Return (winner_string, winner_sum, winner_avg) or None if empty."""
    if not strings:
        return None
    sums, avgs = score_strings(model, stoi, strings)
    best = max(range(len(strings)), key=lambda i: sums[i])
    return strings[best], sums[best], avgs[best]


def dedupe(lists):
    seen = set()
    out = []
    for lst in lists:
        for s in lst:
            if s not in seen:
                seen.add(s)
                out.append(s)
    return out


def rate(x, n):
    return f"{x}/{n} = {x / n:.3f}" if n else f"{x}/0"


def main():
    dump = json.loads((PROTO / "typo_dump.json").read_text(encoding="utf-8"))
    clean_raw = json.loads((PROTO / "candidates.json").read_text(encoding="utf-8"))
    fixture = json.loads((PROTO / "typo_fixture.json").read_text(encoding="utf-8"))
    # candidates.json keys are the eval kana as authored (katakana intact);
    # the fixture/dump kana are hiragana-normalized. Normalize to join.
    clean_by_kana = {to_hira(it["kana"]): it for it in clean_raw}
    kind_by_kana = {it["kana"]: it.get("typo_kind", "?") for it in fixture}

    model, stoi = load_model()

    n = 0
    typo_app = typo_lm = pool_lm = ceiling = 0
    base_app = base_lm = 0
    ctrl_items = ctrl_dethroned = 0
    ctrl_kept_expected = ctrl_expected_winners = 0
    clean_win_sum, clean_win_avg = [], []
    typo_win_sum, typo_win_avg = [], []
    by_kind = {}
    unmatched_clean = 0

    for item in dump:
        kana = item["kana"]
        expected = item["expected"]
        clean = clean_by_kana.get(kana)
        if clean is None:
            unmatched_clean += 1
            continue
        n += 1
        kind = kind_by_kana.get(kana, "?")
        k = by_kind.setdefault(kind, [0, 0, 0, 0])  # n, typo_lm, pool_lm, ceiling
        k[0] += 1

        typo_cands = item["typo_candidates"]
        pool = dedupe([typo_cands] + list(item["variant_candidates"].values()))
        clean_cands = clean["candidates"]

        if typo_cands and typo_cands[0] == expected:
            typo_app += 1
        tw = lm_winner(model, stoi, typo_cands)
        if tw and tw[0] == expected:
            typo_lm += 1
            k[1] += 1
        if tw:
            typo_win_sum.append(tw[1])
            typo_win_avg.append(tw[2])
        pw = lm_winner(model, stoi, pool)
        if pw and pw[0] == expected:
            pool_lm += 1
            k[2] += 1
        if expected in pool:
            ceiling += 1
            k[3] += 1

        if clean_cands and clean_cands[0] == expected:
            base_app += 1
        cw = lm_winner(model, stoi, clean_cands)
        if cw and cw[0] == expected:
            base_lm += 1
        if cw:
            clean_win_sum.append(cw[1])
            clean_win_avg.append(cw[2])

        # Over-correction control: clean candidates pooled with the clean
        # variants' candidates must keep the same LM winner.
        clean_pool = dedupe([clean_cands] + list(item["clean_variant_candidates"].values()))
        cpw = lm_winner(model, stoi, clean_pool)
        if cw and cpw:
            ctrl_items += 1
            if cpw[0] != cw[0]:
                ctrl_dethroned += 1
            if cw[0] == expected:
                ctrl_expected_winners += 1
                if cpw[0] == expected:
                    ctrl_kept_expected += 1

    print(f"items scored: n={n} (dump items without a clean match: {unmatched_clean})")
    print()
    print(f"{'metric':34s} top-1 / rate")
    print(f"{'clean app order (baseline)':34s} {rate(base_app, n)}")
    print(f"{'clean LM rerank (baseline)':34s} {rate(base_lm, n)}")
    print(f"{'typo app order (no correction)':34s} {rate(typo_app, n)}")
    print(f"{'typo LM rerank only':34s} {rate(typo_lm, n)}")
    print(f"{'typo pooled variants + LM':34s} {rate(pool_lm, n)}")
    print(f"{'pool ceiling (expected in pool)':34s} {rate(ceiling, n)}")
    print()
    print("by typo kind (n, typo_lm, pool_lm, ceiling):")
    for kind, (kn, kl, kp, kc) in sorted(by_kind.items()):
        print(f"  {kind:6s} n={kn:3d}  typo_lm={kl / kn:.3f}  pool_lm={kp / kn:.3f}  ceiling={kc / kn:.3f}")
    print()
    print(f"over-correction control (n={ctrl_items}):")
    print(f"  clean LM winner dethroned by clean-variant pool: {rate(ctrl_dethroned, ctrl_items)}")
    print(f"  where clean winner was expected (n={ctrl_expected_winners}), pool kept it: "
          f"{rate(ctrl_kept_expected, ctrl_expected_winners)}")
    print()
    print("trigger separability — LM winner scores:")
    def dist(name, vals):
        if vals:
            print(f"  {name:12s} mean={statistics.mean(vals):8.2f}  median={statistics.median(vals):8.2f}  (n={len(vals)})")
    dist("clean sum", clean_win_sum)
    dist("typo  sum", typo_win_sum)
    dist("clean avg", clean_win_avg)
    dist("typo  avg", typo_win_avg)


if __name__ == "__main__":
    main()
