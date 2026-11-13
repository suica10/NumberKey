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
