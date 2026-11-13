#!/usr/bin/env python3
"""Score the app's candidate lists (candidates.json from the CI dump) with the
prototype LM and compare ranking quality against the app's own order.

Methods reported:
- baseline:  the app's order as-is
- lm_sum:    LM total log-probability only
- lm_avg:    LM per-character log-probability only
- blend:     z-scored lm_avg + w * z-scored rank prior; w tuned on the first
             half of the eval set and reported on the second half
Also reports recall@12 (expected string present in the candidate list at all)
and input-integrity drops (convertTarget != kana).
"""
import argparse
import json
import math
from pathlib import Path

import torch

HERE = Path(__file__).resolve().parent


def load_model():
    from train_lm import CharLM

    ckpt = torch.load(HERE / "lm.pt", weights_only=False)
    model = CharLM(len(ckpt["stoi"]), hidden=ckpt["hidden"])
    model.load_state_dict(ckpt["state_dict"])
    model.eval()
    return model, ckpt["stoi"]


@torch.no_grad()
def score_strings(model, stoi, strings):
    """Return (sum_logprob, avg_logprob) per string."""
    seqs = []
    for s in strings:
        ids = [stoi["<bos>"]] + [stoi.get(c, stoi["<unk>"]) for c in s] + [stoi["<eos>"]]
        seqs.append(ids)
    maxlen = max(len(s) for s in seqs)
    x = torch.zeros(len(seqs), maxlen, dtype=torch.long)
    for i, s in enumerate(seqs):
        x[i, : len(s)] = torch.tensor(s)
    logits = model(x[:, :-1])
    logp = torch.log_softmax(logits, dim=-1)
    targets = x[:, 1:]
    picked = logp.gather(-1, targets.unsqueeze(-1)).squeeze(-1)
    mask = targets != 0
    sums = (picked * mask).sum(dim=1)
    counts = mask.sum(dim=1).clamp(min=1)
    return sums.tolist(), (sums / counts).tolist()


def rank_of(order, expected_idx):
    return order.index(expected_idx) + 1


def accuracy(items, key_fn):
    top1 = top3 = 0
    for it in items:
        order = key_fn(it)
        r = rank_of(order, it["expected_idx"])
        top1 += r == 1
        top3 += r <= 3
    n = len(items)
    return top1 / n, top3 / n


def zscores(vals):
    m = sum(vals) / len(vals)
    var = sum((v - m) ** 2 for v in vals) / len(vals)
    sd = math.sqrt(var) or 1.0
    return [(v - m) / sd for v in vals]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("candidates", type=Path)
    args = ap.parse_args()

    raw = json.loads(args.candidates.read_text(encoding="utf-8"))
    dropped = sum(1 for it in raw if it["convertTarget"] != it["kana"])
    items = []
    missing = 0
    for it in raw:
        if it["convertTarget"] != it["kana"]:
            continue
        if it["expected"] not in it["candidates"]:
            missing += 1
            continue
        items.append(
            {"expected_idx": it["candidates"].index(it["expected"]), "candidates": it["candidates"]}
        )
    total = len(items) + missing
    print(f"items={total} input-mismatch-dropped={dropped} recall@12={len(items)/total:.3f} (expected absent in {missing})")

    model, stoi = load_model()
    for it in items:
        sums, avgs = score_strings(model, stoi, it["candidates"])
        it["lm_sum"] = sums
        it["lm_avg"] = avgs

    def by_baseline(it):
        return list(range(len(it["candidates"])))

    def by_lm_sum(it):
        return sorted(range(len(it["candidates"])), key=lambda i: -it["lm_sum"][i])

    def by_lm_avg(it):
        return sorted(range(len(it["candidates"])), key=lambda i: -it["lm_avg"][i])

    def blend_fn(w):
        def f(it):
            n = len(it["candidates"])
            prior = zscores([-math.log(i + 1) for i in range(n)])
            lm = zscores(it["lm_avg"])
            return sorted(range(n), key=lambda i: -(lm[i] + w * prior[i]))

        return f

    def report(name, subset, fn):
        t1, t3 = accuracy(subset, fn)
        print(f"{name:28s} top1={t1:.3f} top3={t3:.3f}  (n={len(subset)})")

    report("baseline (app order)", items, by_baseline)
    report("lm_sum only", items, by_lm_sum)
    report("lm_avg only", items, by_lm_avg)

    half = len(items) // 2
    tune, test = items[:half], items[half:]
    best_w, best_t1 = None, -1.0
    for w in [0.25, 0.5, 1.0, 2.0, 4.0]:
        t1, _ = accuracy(tune, blend_fn(w))
        if t1 > best_t1:
            best_w, best_t1 = w, t1
    print(f"tuned blend weight on first half: w={best_w} (tune top1={best_t1:.3f})")
    report("blend (held-out half)", test, blend_fn(best_w))
    report("blend (full set)", items, blend_fn(best_w))


if __name__ == "__main__":
    main()
