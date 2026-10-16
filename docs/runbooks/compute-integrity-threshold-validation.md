# Compute-integrity scoring: real-chip threshold validation

Related: #1644, SPEC-036 §5A (FR-21, FR-22, FR-23).

This is the hardware gate of PR #1986. It measures the cross-provider
scoring thresholds on real Apple Silicon. Production data cannot replace
it: no provider runs the FR-21 scoring job yet, and the coordinator stores
no per-token log-probabilities.

Follow `lab-campaign-loop.md`. Build the PR branch on the lab box. Use only
a lab process: `msb-compute-score` loads its own model and never touches the
buyer-serving provider. Pause a live provider only in an announced window,
and never run the lab beside it.

## Thresholds under test

Values come from `phase4-coordinator/internal/computeintegrity/scoring.go`.

| Threshold | Value | Must hold for |
|---|---|---|
| Cold prior, greedy | `top1_rate >= 0.85` and `mean_logprob >= -1.0` | honest outputs, same and cross chip |
| Cold prior, sampled (`temperature: 0.7`) | `mean_logprob >= -4.0` | honest outputs, same and cross chip |
| Hot (`temperature: 1.0`) | cover only, never scored by the coordinator | none (measured for information) |
| Hard floor, greedy | `top1_rate >= 0.50` and `mean_logprob >= -3.0` | every honest output |
| Hard floor, sampled | `mean_logprob >= -6.0` | every honest output |
| Minimum scored tokens | 16 | — |

The learned band replaces the cold prior once it is warm: 32 measurements
from 3 or more operators, floor `median - max(6 * MAD, margin)`, margin 0.25
for log-probability and 0.05 for top-1. SPEC-036 §7A.3 needs both regimes:
the cold prior decides every key until its band warms (steps 1 to 4), and
step 5 checks the warm band.

## Inputs

- `MODEL`: a catalog model that providers serve.
- `SUBST`: a plausible substitute, such as a smaller model of the same
  family or a lower-bit quantization of `MODEL`, with the same tokenizer.
- `CORPUS`: `phase4-coordinator/internal/computeintegrity/corpus/generic_v1.json`,
  or the private production corpus.
- Two chip classes, A and B (for example an M-series Max/Ultra and a base
  M-series).

## Steps

Build on each box:

```bash
cd phase3-binary && swift build -c release --product macprovider-cli
CLI=.build/release/macprovider-cli
```

1. Honest outputs and same-chip score, on chip A:

   ```bash
   $CLI msb-compute-score --model "$MODEL" --corpus "$CORPUS" \
     --emit-outputs honest-A.json --report A-scores-honest-A.json
   ```

2. Cross-chip honest score, on chip B, after copying `honest-A.json` there:

   ```bash
   $CLI msb-compute-score --model "$MODEL" --score-outputs honest-A.json \
     --report B-scores-honest-A.json
   ```

   Then repeat steps 1 and 2 with A and B swapped.

3. Substituted outputs, scored under the claimed model:

   ```bash
   # chip A
   $CLI msb-compute-score --model "$SUBST" --corpus "$CORPUS" --emit-outputs subst-A.json
   # chip B
   $CLI msb-compute-score --model "$MODEL" --score-outputs subst-A.json \
     --report B-scores-subst-A.json
   ```

4. Scoring next to concurrent generation, on either chip:

   ```bash
   $CLI msb-compute-score --model "$MODEL" --score-outputs honest-A.json \
     --concurrent-load 4 --report A-scores-under-load.json
   ```

5. Warm band. Collect honest reports from at least 3 chips, standing in for 3
   operators, with at least 32 measured items per class. Compute the learned
   floor from them, then check a held-out honest report and the substituted
   report against it:

   ```bash
   python3 -I scripts/lab/1986-compute-score/warmband.py \
     A-scores-honest-A.json,B-scores-honest-B.json,C-scores-honest-C.json \
     B-scores-honest-A.json B-scores-subst-A.json
   ```

   `scripts/lab/1986-compute-score/summarize.py <reports>` prints the
   per-class table against the cold prior and the hard floors.

## Pass criteria

Read `summary.greedy`, `summary.sampled` and `summary.hot` in each report
(or run `python3 -I tools/summarize.py <reports>` from the lab dir).

- **Honest, steps 1 and 2:**
  - `above_hard_floor == measured` in every class;
  - `in_cold_prior / measured >= 0.99` in every class.

  One out-of-band measurement moves an honest key to `suspect`, and a
  failure needs 3 of the last 5 escalation measurements out with both
  scorers agreeing. At a 1% miss rate, escalations stay rare and a false
  failure is on the order of 1e-5 per escalation.
- **Substituted, step 3:** greedy `in_cold_prior / measured <= 0.20`.
  Detection while a model is cold rests on greedy probes: escalation uses
  greedy until the sampled band warms, so 3 of 5 escalation measurements
  fall out of band. The cold sampled and hot bands are not detectors; they
  only have to accept honest outputs. Hot outputs are reported for
  information only: the coordinator never scores them, because honest
  `temperature: 1.0` runs can degenerate below every floor.
- **Under load, step 4:** in `under_load`:
  - `generations_ok_while_scoring > 0`;
  - `generations_failed == 0`;
  - `score_statuses` holds only `ok`;
  - `max_mean_logprob_drift` is set and `<= 0.05`.
- **Warm band, step 5:**
  - the held-out honest report is at least 99% in band in each class;
  - the substituted report is at most 20% in band for greedy and for
    sampled. Hot is not judged.

If an honest class fails, set its cold prior below the observed minimum with
the FR-22 margin (0.25 for log-probability, 0.05 for top-1). Keep the prior
above the substituted median, put that change and the reports in the PR, and
rerun step 3. If the honest and substituted ranges overlap, the cold prior
cannot separate them. Record that in the PR and keep the change in draft.

## Evidence

Put the reports in `docs/evidence/` only when `specs/CONFORMANCE.json` cites
them. Otherwise they go in the private operations repository. They contain
corpus prompts, outputs and aggregates, and nothing else.
