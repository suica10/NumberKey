#!/usr/bin/env python3
"""Train a small character-level GRU language model on corpus.txt.

This is the prototype scorer for candidate reranking: small enough to be a
plausible on-device Core ML model later (int8 size is printed at the end).
Saves lm.pt (state_dict + vocab + config) next to this script.

Resumable: every CHECKPOINT_EVERY batches the model + optimizer + position
are saved to lm-partial.pt. The per-epoch data order is derived from a fixed
seed, so a restarted process reproduces the exact order and skips finished
batches. The VM hosting this job is replaced without warning, so training
MUST survive being killed at any point.
"""
import argparse
import json
import math
import random
import time
from pathlib import Path

import torch
from torch import nn

HERE = Path(__file__).resolve().parent
SPECIALS = ["<pad>", "<bos>", "<eos>", "<unk>"]
CHECKPOINT_EVERY = 40  # batches (~2 min). The host VM is replaced often and
# detached processes die with it, so progress is banked in small increments.


def build_vocab(sentences, min_freq=3):
    from collections import Counter

    counts = Counter()
    for s in sentences:
        counts.update(s)
    chars = [c for c, n in counts.items() if n >= min_freq]
    vocab = SPECIALS + sorted(chars)
    return {c: i for i, c in enumerate(vocab)}


class CharLM(nn.Module):
    def __init__(self, vocab_size, emb=128, hidden=512, layers=2):
        super().__init__()
        self.embedding = nn.Embedding(vocab_size, emb, padding_idx=0)
        self.gru = nn.GRU(emb, hidden, layers, batch_first=True)
        self.out = nn.Linear(hidden, vocab_size)

    def forward(self, x):
        h, _ = self.gru(self.embedding(x))
        return self.out(h)


def encode(sentence, stoi, max_len=64):
    ids = [stoi["<bos>"]]
    ids += [stoi.get(c, stoi["<unk>"]) for c in sentence[: max_len - 2]]
    ids.append(stoi["<eos>"])
    return ids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sentences", type=int, default=60000)
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--hidden", type=int, default=512)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    random.seed(args.seed)
    torch.set_num_threads(2)

    lines = [l.rstrip("\n") for l in (HERE / "corpus.txt").open(encoding="utf-8")]
    lines = [l for l in lines if 3 <= len(l) <= 60]
    random.shuffle(lines)
    lines = lines[: args.sentences]
    holdout = lines[:1000]
    train = lines[1000:]
    stoi = build_vocab(train)
    print(f"train={len(train)} vocab={len(stoi)}", flush=True)

    def batchify(data):
        seqs = [encode(s, stoi) for s in data]
        maxlen = max(len(s) for s in seqs)
        x = torch.zeros(len(seqs), maxlen, dtype=torch.long)
        for i, s in enumerate(seqs):
            x[i, : len(s)] = torch.tensor(s)
        return x

    model = CharLM(len(stoi), hidden=args.hidden)
    params = sum(p.numel() for p in model.parameters())
    print(f"params={params/1e6:.2f}M (fp32 {params*4/1e6:.1f}MB, int8 ~{params/1e6:.1f}MB)", flush=True)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    loss_fn = nn.CrossEntropyLoss(ignore_index=0)

    partial_path = HERE / "lm-partial.pt"
    start_epoch, start_batch = 0, 0
    if partial_path.exists():
        ckpt = torch.load(partial_path, weights_only=False)
        if ckpt.get("stoi") == stoi and ckpt.get("hidden") == args.hidden:
            model.load_state_dict(ckpt["state_dict"])
            opt.load_state_dict(ckpt["opt_state"])
            start_epoch, start_batch = ckpt["epoch"], ckpt["next_batch"]
            print(f"resumed from partial: epoch {start_epoch+1} batch {start_batch}", flush=True)
        else:
            print("partial checkpoint incompatible; starting over", flush=True)

    def save_partial(epoch, next_batch):
        torch.save(
            {"state_dict": model.state_dict(), "opt_state": opt.state_dict(),
             "stoi": stoi, "hidden": args.hidden, "epoch": epoch, "next_batch": next_batch},
            partial_path,
        )

    for epoch in range(start_epoch, args.epochs):
        model.train()
        # Deterministic per-epoch order so a resume reproduces it exactly.
        order = list(range(len(train)))
        random.Random(1234 + epoch).shuffle(order)
        total, nb = 0.0, 0
        t0 = time.time()
        batch_no = 0
        for i in range(0, len(order), args.batch):
            if epoch == start_epoch and batch_no < start_batch:
                batch_no += 1
                continue
            batch = batchify([train[j] for j in order[i : i + args.batch]])
            logits = model(batch[:, :-1])
            loss = loss_fn(logits.reshape(-1, len(stoi)), batch[:, 1:].reshape(-1))
            opt.zero_grad()
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            total += loss.item()
            nb += 1
            batch_no += 1
            if batch_no % CHECKPOINT_EVERY == 0:
                save_partial(epoch, batch_no)
                print(f"  checkpoint epoch {epoch+1} batch {batch_no}", flush=True)
        print(f"epoch {epoch+1}/{args.epochs} train loss {total/max(nb,1):.4f} ({time.time()-t0:.0f}s)", flush=True)
        torch.save(
            {"state_dict": model.state_dict(), "stoi": stoi, "hidden": args.hidden},
            HERE / f"lm-epoch{epoch+1}.pt",
        )
        print(f"saved lm-epoch{epoch+1}.pt", flush=True)
        save_partial(epoch + 1, 0)

    model.eval()
    with torch.no_grad():
        batch = batchify(holdout)
        logits = model(batch[:, :-1])
        loss = loss_fn(logits.reshape(-1, len(stoi)), batch[:, 1:].reshape(-1))
    print(f"holdout loss {loss.item():.4f} perplexity {math.exp(loss.item()):.2f}", flush=True)

    torch.save(
        {"state_dict": model.state_dict(), "stoi": stoi, "hidden": args.hidden},
        HERE / "lm.pt",
    )
    (HERE / "train_result.json").write_text(
        json.dumps(
            {"params": params, "vocab": len(stoi), "holdout_loss": loss.item(),
             "perplexity": math.exp(loss.item()), "sentences": len(train), "epochs": args.epochs},
            indent=2,
        ),
        encoding="utf-8",
    )
    partial_path.unlink(missing_ok=True)
    print("saved lm.pt", flush=True)


if __name__ == "__main__":
    main()
