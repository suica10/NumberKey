# Neural rerank prototype

Goal: test whether a small on-device language model can improve One Keyboard's
candidate ordering — measured, not assumed. The user does not need this feature
personally; it exists as a sales-phase selling point ("on-device AI optimises
candidates; your typing never leaves the device"), and it only ships if the
numbers below show a real improvement.

## Method

1. `eval_sentences.json` — 120 everyday Japanese sentences (kana input as typed
   + the natural mixed-script conversion). General register on purpose: the
   feature targets typical buyers, not the maker's own vocabulary.
2. `Tests/CandidateDumpTests.swift` — env-gated XCTest that runs the app's real
   `ConversionService` (AzooKey converter, same options as production) over the
   eval set and dumps the top-12 candidate lists to `candidates.json`.
   Run via the gated steps in `.github/workflows/build-ipa.yml` on this branch.
3. `lm/fetch_corpus.py` — Tatoeba Japanese sentences (CC BY 2.0 FR), ~249k.
4. `lm/train_lm.py` — character-level GRU LM (embedding 128, GRU 512×2,
   ~4.0M params ≈ 4MB int8 — a plausible keyboard-extension size).
5. `lm/rerank_eval.py` — scores each candidate list with the LM and compares
   top-1/top-3 accuracy: app order (baseline) vs LM-only vs blend with a rank
   prior (blend weight tuned on the first half, reported on the held-out half).

## Results

First run, 2026-11-13. Training: 59,000 sentences actually consumed
(3 epochs over the corpus subset the trainer iterates), char GRU LM,
holdout loss 2.6001, **perplexity 13.46**. Eval: 119 contexts;
the expected string was absent from the 12 candidates in 15 of them
(**recall@12 = 0.874** — a converter ceiling no reranker can fix),
leaving n=104 scored contexts.

| ordering | top-1 | top-3 |
|---|---|---|
| baseline (app order) | 0.760 | 0.990 |
| LM only (sum log-prob) | 0.865 | 1.000 |
| LM only (avg log-prob) | 0.837 | 1.000 |
| blend, prior w=0.25 tuned on first half — held-out half (n=52) | 0.827 | 1.000 |
| blend — full set | 0.817 | 1.000 |

Reading: reranking is a real improvement, not noise-sized — the pure LM
order beats the app order by +10.5pt top-1 on the full set, and the
conservative blend still gains +6.7pt on held-out data. Caveats: the
eval set is small (n=104) and drawn from the same everyday-sentence
register the LM trained on (Tatoeba), so real-world chat text may gain
less. This measures selection accuracy offline only; on-device latency
of scoring 12 candidates per conversion still has to be measured
before any integration ships.

## Notes

- Reranking can only reorder what the converter already proposes; recall@12
  (expected string present in the list) is reported as the ceiling.
- Floors for any future integration: no typing-latency regression, no
  candidate-order degradation, small model. Fallback to the app order when
  the model is unavailable.

## LM v2 training (2026-11-14)

A second training run in `lm2/`, ordered by the user ("more data +
optimization"). The v1 model in `lm/` is the shipped production model and
stays untouched.

- Data: the full corpus instead of v1's 60k slice. Exact-dedupe removed
  0 lines (the corpus was already unique — 248,970 lines); 247,895 lines
  pass the trainer's 3–60 char filter, so with the 1,000-sentence holdout
  the run trains on **246,895 sentences × 3 epochs** (v1: 59,000).
- Same architecture (embedding 128, GRU 512×2, batch 128, lr 2e-3). The
  larger corpus grows the vocab 2,287 → 2,824 (more chars pass
  min_freq 3), so params go 4.03M → 4.37M (int8 ≈ 4.4MB — still a
  plausible keyboard-extension size).
- Training is resumable (checkpoints every 40 batches) and supervised by
  the `rerank-lm2-training-watch` cron, which relaunches it after VM
  replacements and reports completion.
- **Ship gate: v2 ships ONLY if `lm2/rerank_eval.py` on `candidates.json`
  beats v1's LM-only (sum log-prob) top-1 of 0.865.** Otherwise v1 stays.
