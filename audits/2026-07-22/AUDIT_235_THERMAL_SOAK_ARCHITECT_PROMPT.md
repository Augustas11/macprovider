# AUDIT_235 — thermal-soak instrument — ARCHITECT lane

You are auditing a **test-harness change** on branch `research/235-thermal-soak`
in the macprovider repo. Review for ARCHITECTURE / DESIGN-COHERENCE issues
(this lane). Report findings CRITICAL / HIGH / MEDIUM / LOW / INFO with
file:line and a concrete recommendation. Bar for merge: 0 CRITICAL, 0 HIGH,
0 MEDIUM.

## What the change is

RESEARCH_235 builds the *instrument* for a thermal/sustained-load soak (issue
#584: sustained synthetic load collapsed a healthy provider ~30 → 8.9 → 5.3
tok/s and disconnected it — a thermal/sustained-throughput degradation no test
in the repo characterizes). The soak *run* is the real deliverable but is
PARKED until a dedicated lab Mac exists; this session ships only the instrument
so it's ready the moment hardware is. Parts:

1. Benchmark invariant **B10** "sustained streaming-TPS retention"
   (`internal/benchmark/benchmark.go`): windows streaming decode-TPS p50 into a
   first-5min and last-5min window; retention = final/first; PASS ≥0.85 / WARN
   ≥0.70 / FAIL <0.70 (**provisional** — calibrated later from a real run), SKIP
   <8 samples/window. Gated behind a scenario `sustained_gate_armed` flag
   (default false → would-be FAIL downgraded to WARN) so the uncalibrated gate
   never blocks.
2. Scenario `scenarios/15_thermal_soak.yaml`: 45–60 min, 2 buyers, stream,
   max_tokens=64, 30B model, targets a LAB stack.
3. `test/e2e/thermal-soak/`: `thermal-collector.sh` (pmset + powermetrics →
   NDJSON) and `join-thermal.py` (correlate TPS decay to thermal), + README.

## Focus for THIS lane (design coherence)

- **Invariant-ID choice.** The forcing prompt said "B8", but B8/B9 are claimed
  by RESEARCH_236 (open PR #696, unmerged). This change uses **B10** to avoid a
  collision regardless of merge order, and documents the B8/B9 gap. Is B10 the
  right call, and is the gap documented coherently in benchmark.go, schema.go,
  and SPEC §3.5? Any residual place that still says B8?
- **Metric basis.** B10 uses *streaming* decode-TPS (post-TTFT tokens / decode
  duration), NOT the non-streaming `sustained_tps` field (which is
  structurally unreliable — reads 17k–33k tok/s for a warm 30B). Confirm the
  chosen basis is consistent with B2 and that the code doesn't accidentally mix
  in the unreliable field.
- **Pacing / scenario design.** Scenario 15 uses 2 buyers + a 1s inter-request
  floor to keep the provider continuously busy while capping concurrency at ≤2
  (within Pearl N_eff=2.5). Reuses scenario 07's pacing model. Is this a
  faithful "sustained load" characterization, or will it under/over-drive the
  provider vs the #584 incident's load? Is 5-min windows × ≥8-sample floor
  well-matched to the 45–60 min duration and expected request rate?
- **Provisional/unarmed posture.** The task explicitly wants B10 shipped
  provisional and the gate left UNARMED until a lab soak calibrates it (mirrors
  RESEARCH_236's CacheGateArmed). Verify the `sustained_gate_armed` mechanism
  actually delivers "measures + reports but never blocks" until armed, and that
  the SPEC/scenario/README consistently say so. Flag any place that reads as
  final-calibrated.
- **Fit with the existing suite.** Does B10 slot cleanly next to B1-B7 (verdict
  shape, SKIP semantics, WARN-doesn't-block convention)? Does the new
  `SustainedTPSMetrics` on `BuyerMetrics` and the `SustainedGateArmed` scenario
  field fit the established patterns (cf. ColdWarm/B7, ProviderSlots)?
- **Deliverable completeness for an INSTRUMENT-ONLY session.** Given the run is
  parked, is what ships self-sufficient — will a fresh operator with a lab Mac
  be able to run the soak, get a B10 verdict, and correlate thermal from the
  README + scripts alone? Is the parked D3 (report + safe-load envelope +
  #463 recommendation) clearly flagged as pending, not silently dropped?
- **Scope discipline.** Did the change avoid touching scenario 07/08 or the
  money path? Any scope creep?

## How to review

Branch checked out at repo root. Read the full files listed above plus
`docs/notes/SPEC-NETWORK-BENCHMARK-v0.1.md` §3.5/§4.15 and
`test/e2e/thermal-soak/README.md`. This is a research/test-harness change, not
money-path — judge design coherence and whether the instrument is fit to be run
later, not production-deployment concerns. Do NOT flag the provisional
threshold *values* (calibrated later by design).
