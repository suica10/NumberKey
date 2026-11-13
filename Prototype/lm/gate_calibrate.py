#!/usr/bin/env python3
"""Calibrate the trigger gate for the typo-correction feature.

Simulates the production policy on typo_dump.json + candidates.json:
  1. normal conversion + LM rerank (winner = argmax lm_sum),
  2. IF winner lm_avg < THRESHOLD: generate budgeted 1-edit variants of the
     input, convert, pool with the original candidates, LM-score the pool,
  3. replace the winner ONLY IF pooled best beats the original winner by
     at least MARGIN (swept on both sum and avg).

Variant selection mirrors the intended production budgets (total cap 120;
per-kind caps sub 56 / trans 16 / del 16 / ins 32, backfill ins-first) and
is applied to the variant sets reconstructed per kind from the input
romaji; the candidate lists come from typo_dump.json, so a selected
variant the dump's random cap dropped contributes no candidates (the
simulation is therefore a slight underestimate of the production pool).

Per-item winner facts are checkpointed to gate_rows.jsonl; the sweep runs
on the checkpoint, so reruns are cheap.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROTO = HERE.parent
sys.path.insert(0, str(HERE))

from rerank_eval import load_model, score_strings  # noqa: E402
from gen_typo_fixture import kana_to_romaji, romaji_to_kana, edits, to_hira  # noqa: E402

ROWS_PATH = HERE / "gate_rows.jsonl"
BUDGETS = {"sub": 56, "trans": 16, "del": 16, "ins": 32}
KIND_ORDER = ["sub", "trans", "del", "ins"]
BACKFILL_ORDER = ["ins", "sub", "trans", "del"]
CAP = 120


def kind_kana_sets(roma):
    subs, dels, trans, inss = edits(roma)
    own = romaji_to_kana(roma)
    out = {}
    for name, lst in (("sub", subs), ("trans", trans), ("del", dels), ("ins", inss)):
        s = set()
        for v in lst:
            k = romaji_to_kana(v)
            if k:
                s.add(k)
        s.discard(own)
        out[name] = s
    return out


def budgeted_selection(sets):
    selected, seen, leftover = [], set(), {}
    for k in KIND_ORDER:
        lst = sorted(sets[k] - seen)
        take = lst[: BUDGETS[k]]
        leftover[k] = lst[BUDGETS[k]:]
        for v in take:
            if v not in seen:
                seen.add(v)
                selected.append(v)
    for k in BACKFILL_ORDER:
        for v in leftover[k]:
            if len(selected) >= CAP:
                break
            if v not in seen:
                seen.add(v)
                selected.append(v)
        if len(selected) >= CAP:
            break
    return selected


def dedupe(lists):
    seen, out = set(), []
    for lst in lists:
        for s in lst:
            if s not in seen:
                seen.add(s)
                out.append(s)
    return out


def winner(model, stoi, strings):
    if not strings:
        return None
    sums, avgs = score_strings(model, stoi, strings)
    best = max(range(len(strings)), key=lambda i: sums[i])
    return {"s": strings[best], "sum": sums[best], "avg": avgs[best]}


def score_item(model, stoi, item, clean_cands, fx):
    typo_cands = item["typo_candidates"]
    typo_roma = kana_to_romaji(item["typo_kana"])
    sel = budgeted_selection(kind_kana_sets(typo_roma)) if typo_roma else []
    dumped = item["variant_candidates"]
    pool = dedupe([typo_cands] + [dumped[v] for v in sel if v in dumped])

    clean_roma = fx["romaji"]
    csel = budgeted_selection(kind_kana_sets(clean_roma))
    cdumped = item["clean_variant_candidates"]
    cpool = dedupe([clean_cands] + [cdumped[v] for v in csel if v in cdumped])

    return {
        "kana": item["kana"],
        "expected": item["expected"],
        "kind": fx.get("typo_kind", "?"),
        "typo_win": winner(model, stoi, typo_cands),
        "pool_win": winner(model, stoi, pool),
        "clean_win": winner(model, stoi, clean_cands),
        "cpool_win": winner(model, stoi, cpool),
        "n_sel": len(sel),
        "n_sel_dumped": sum(1 for v in sel if v in dumped),
        "n_csel": len(csel),
        "n_csel_dumped": sum(1 for v in csel if v in cdumped),
        "pool_has_expected": item["expected"] in pool,
    }


def simulate(rows, threshold, margin, metric):
    """Return (typo_recovery, clean_dethrone, typo_fires, clean_fires)."""
    rec = deth = tf = cf = 0
    for r in rows:
        tw, pw = r["typo_win"], r["pool_win"]
        final = tw
        if tw and pw and tw["avg"] < threshold:
            tf += 1
            gain = (pw["sum"] - tw["sum"]) if metric == "sum" else (pw["avg"] - tw["avg"])
            if gain >= margin:
                final = pw
        rec += bool(final and final["s"] == r["expected"])
        cw, cpw = r["clean_win"], r["cpool_win"]
        cfinal = cw
        if cw and cpw and cw["avg"] < threshold:
            cf += 1
            gain = (cpw["sum"] - cw["sum"]) if metric == "sum" else (cpw["avg"] - cw["avg"])
            if gain >= margin:
                cfinal = cpw
        deth += bool(cw and cfinal and cfinal["s"] != cw["s"])
    n = len(rows)
    return rec / n, deth / n, tf / n, cf / n


def main():
    dump = json.loads((PROTO / "typo_dump.json").read_text(encoding="utf-8"))
    clean_raw = json.loads((PROTO / "candidates.json").read_text(encoding="utf-8"))
    fixture = {it["kana"]: it for it in json.loads((PROTO / "typo_fixture.json").read_text(encoding="utf-8"))}
    clean_by_kana = {to_hira(it["kana"]): it for it in clean_raw}
    items = [it for it in dump if it["kana"] in clean_by_kana]

    rows = {}
    if ROWS_PATH.exists():
        for line in ROWS_PATH.read_text(encoding="utf-8").splitlines():
            if line.strip():
                r = json.loads(line)
                rows[r["kana"]] = r
    todo = [it for it in items if it["kana"] not in rows]
    if todo:
        model, stoi = load_model()
        with ROWS_PATH.open("a", encoding="utf-8") as fh:
            for i, item in enumerate(todo):
                row = score_item(model, stoi, item, clean_by_kana[item["kana"]]["candidates"], fixture[item["kana"]])
                rows[item["kana"]] = row
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
                fh.flush()
                print(f"scored {i + 1}/{len(todo)}", flush=True)
    else:
        print("all items already scored (checkpoint)")

    rows = [rows[it["kana"]] for it in items]
    n = len(rows)
    base_rec = sum(1 for r in rows if r["typo_win"] and r["typo_win"]["s"] == r["expected"]) / n
    pool_rec = sum(1 for r in rows if r["pool_win"] and r["pool_win"]["s"] == r["expected"]) / n
    ceil = sum(1 for r in rows if r["pool_has_expected"]) / n
    clean_base = sum(1 for r in rows if r["clean_win"] and r["clean_win"]["s"] == r["expected"]) / n
    naive_deth = sum(1 for r in rows if r["clean_win"] and r["cpool_win"] and r["cpool_win"]["s"] != r["clean_win"]["s"]) / n
    print(f"n={n}  ungated: typo recovery={pool_rec:.3f} (ceiling {ceil:.3f}), no-correction={base_rec:.3f}")
    print(f"clean LM top-1={clean_base:.3f}, naive always-pool dethrone={naive_deth:.3f}")
    miss = [r["n_sel"] - r["n_sel_dumped"] for r in rows]
    print(f"selected typo variants missing from dump: mean={sum(miss) / n:.1f} max={max(miss)}")

    thresholds = [-3.3, -3.4, -3.5, -3.6, -3.7, -3.8, -3.9, -4.0, -4.1, -4.2, -4.3]
    grids = {"sum": [0, 0.5, 1, 1.5, 2, 3, 4, 6], "avg": [0, 0.02, 0.05, 0.08, 0.1, 0.15, 0.2, 0.3]}
    results = []
    for metric, margins in grids.items():
        for t in thresholds:
            for m in margins:
                rec, deth, tf, cf = simulate(rows, t, m, metric)
                results.append((metric, t, m, rec, deth, tf, cf))
    print()
    print(f"{'metric':4s} {'thr':>5s} {'margin':>6s} {'recov':>6s} {'dethr':>6s} {'tfire':>6s} {'cfire':>6s}")
    ok = [r for r in results if r[4] <= 0.05]
    ok.sort(key=lambda r: (-r[3], r[4], -r[2]))
    for metric, t, m, rec, deth, tf, cf in ok[:15]:
        print(f"{metric:4s} {t:5.1f} {m:6.2f} {rec:6.3f} {deth:6.3f} {tf:6.3f} {cf:6.3f}")
    if ok:
        metric, t, m, rec, deth, tf, cf = ok[0]
        print()
        print(f"CHOSEN: metric={metric} THRESHOLD={t} MARGIN={m} -> recovery={rec:.3f} dethrone={deth:.3f}")
        # per-kind recovery at the chosen constants
        kinds = {}
        for r in rows:
            tw, pw = r["typo_win"], r["pool_win"]
            final = tw
            if tw and pw and tw["avg"] < t:
                gain = (pw["sum"] - tw["sum"]) if metric == "sum" else (pw["avg"] - tw["avg"])
                if gain >= m:
                    final = pw
            k = kinds.setdefault(r["kind"], [0, 0])
            k[0] += 1
            k[1] += bool(final and final["s"] == r["expected"])
        for kind, (kn, kr) in sorted(kinds.items()):
            print(f"  kind {kind:6s} n={kn:3d} recovery={kr / kn:.3f}")
    else:
        print("NO constants with dethrone <= 0.05; best-dethrone rows:")
        results.sort(key=lambda r: (r[4], -r[3]))
        for metric, t, m, rec, deth, tf, cf in results[:10]:
            print(f"{metric:4s} {t:5.1f} {m:6.2f} {rec:6.3f} {deth:6.3f} {tf:6.3f} {cf:6.3f}")


if __name__ == "__main__":
    main()
