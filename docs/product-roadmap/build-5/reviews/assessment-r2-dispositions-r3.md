# Product Build 5 assessment r2 finding dispositions

Date: 2026-09-11

Source review: `assessment-r2-sol.md`

Source review SHA-256:
`9c7a211bce4dffd64a821fab94b6203b0faa6708aa1c7e188d112686bc2684af`

Correction revision: assessment/evidence/benchmark/checkpoint R3

This disposition record does not approve R3. A fresh independent GPT-5.6 Sol
review must verify exact R3 digests and report zero Critical, High, and Medium
findings before the assessment gate passes.

| Finding | R3 correction | Disposition |
|---|---|---|
| H1 impossible Entry 110 workloads | `feasibility-assessment.md` now records the exact 1/2/3/4 mapping and blocks four-row M4 Max serving tests. `test-benchmark-spec.md` places MSB-01/02/03 on one Ultra >=128 GiB host/artifact, while M5/Max work uses separate legal development IDs. A future governed non-serving mode is the only alternative. | Corrected; no capacity cap is bypassed. |
| H2 no batch/serial arbiter | Both plan and test spec define one generation-scoped `ResidentModelExecutionArbiter`, serial XOR batch states, lease/drain/recovery/warm-swap transitions, and deterministic plus real-runtime no-overlap tests. | Corrected. |
| H3 wrong MSB executor mapping | R3 maps MSB-01 to one native serial iterator, MSB-02/03 to candidate shared forward with exact identical/ragged shapes, MSB-04 to live-MoE serial/candidate arms, and MSB-05 to native two iterators versus pinned oMLX. Candidate-versus-oMLX is a new `MSB-X1`. | Corrected. |
| H4 non-executable memory gate | R3 defines `memory-budget-v1`, checked formulas, one 10% allowance, process physical footprint authority, non-added MLX diagnostics, 100 ms samples, exact pressure/thermal/swap failures, 120-second recovery, and baseline tolerances. | Corrected. |
| M1 SPEC-039 conformance omitted | Evidence, dependency graph, Stage A, authority gates, and qualification blockers now state SPEC-039 draft/pending-reconciliation and R001-R014 pending/unmapped. | Corrected. |
| M2 3B tuple not reproducible | A fresh R3 run has a committed sanitized log and exact snapshot revision, six-file manifest, prompt, harness, executable, metallib, dependency-lock, host, and toolchain hashes. It remains explicitly exploratory because current source scans the first snapshot and inserts dummy descriptor hashes. Future harness rules require exact revision selection and derived nonzero authority. | Corrected without overstating the run. |
| M3 open statistics/workloads | R3 freezes MSB repetitions, paired bootstrap estimator/resampling unit/count/seed/method, p95/p99 minimums, prompt corpus form, barrier, mixed ingress, slow consumer, cancellation schedule, warm-up, and numeric exclusions. | Corrected. |
| M4 MoE tolerance undefined | C12 and MSB-04 require exact greedy token IDs plus terminal/accounting equality. No adjustable output tolerance is accepted; raw-logit diagnostics require a future preregistered revision. | Corrected. |
| M5 incomplete release identity | C10 now requires protected Xcode 16.4/Swift 6.1.2/SDK 15.5, locked dependencies, final standalone/Malibu CLI byte identity, metallib/resource identity, codesign/notarization/stapling/Gatekeeper verification, immutable checks, and previous-stable updater coverage. | Corrected. |

No runtime, scheduler, configuration, conformance, release, or production
enablement changes were made in this correction.
