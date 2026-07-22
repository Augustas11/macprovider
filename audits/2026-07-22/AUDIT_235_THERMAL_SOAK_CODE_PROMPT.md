# AUDIT_235 — thermal-soak instrument — CODE-CORRECTNESS lane

You are auditing a **test-harness change** on branch `research/235-thermal-soak`
in the macprovider repo. Review the diff vs `origin/main` for CODE-CORRECTNESS
issues only (this lane). Do NOT rewrite; report findings with severity
CRITICAL / HIGH / MEDIUM / LOW / INFO, each with file:line and a concrete fix.
Bar for merge: 0 CRITICAL, 0 HIGH, 0 MEDIUM.

## What the change is

RESEARCH_235 builds the *instrument* for a thermal/sustained-load soak test
(issue #584: a sustained synthetic load collapsed a healthy provider's
throughput ~30 → 8.9 → 5.3 tok/s and disconnected it). NO soak has been run;
the campaign is parked pending a lab Mac. Three parts:

1. **New benchmark invariant `B10` "sustained streaming-TPS retention"** in
   `test/network-harness/internal/benchmark/benchmark.go`. It windows the
   per-request *streaming* decode-TPS distribution (tokens / (last_byte −
   (start + ttft)) — the same basis as B2, NOT the non-streaming sustained_tps
   field) by wall-clock StartUTC into a first window ([t0, t0+300s)) and a
   final window ((tEnd−300s, tEnd]), computes `retention = final_p50 /
   first_p50`, and scores it PASS ≥0.85 / WARN ≥0.70 / FAIL <0.70. SKIP if
   either window has <8 samples. A scenario flag `sustained_gate_armed`
   (default false) downgrades a would-be FAIL to WARN so the uncalibrated gate
   can't block. New: `SustainedTPSMetrics` struct, `computeSustainedTPS`,
   `evalB10`, case dispatch, constants, unit tests.
2. **B10 added to the scenario invariant allow-list** in
   `test/network-harness/internal/scenario/schema.go` (was B1-B7), plus a new
   `SustainedGateArmed bool` field on the `Benchmark` struct.
3. Scenario YAML + provider-side shell/python capture scripts (audited in the
   architect/security lanes; this lane focuses on the Go).

## Focus for THIS lane (correctness)

- Is the windowing math correct? t0/tEnd derivation, the `Before`/`!Before`
  boundary conditions on `firstCutoff`/`finalCutoff`, off-by-one/edge cases
  (single sample, all-same-timestamp, empty). Could a sample be double-counted
  or dropped at a boundary in a way that biases retention?
- Overlapping windows on short runs: the code documents that first/final can
  overlap when the run is <10 min and relies on the ≥8-sample floor as the
  guard, not disjointness. Is that reasoning sound, or can it produce a
  misleading retention (e.g. retention ≈ 1.0 that hides decay) on a real
  45–60 min soak? Is there any way the two windows silently coincide on a
  long run?
- `retention = final_p50 / first_p50` guards `first_p50 > 0`. Any div-by-zero,
  NaN, or Inf path? What if all TPS samples are equal / zero?
- `percentile` reuse: `computeSustainedTPS` calls the package `percentile`
  helper on unsorted slices — confirm that's safe (the helper sorts if
  needed) and that passing the same backing array isn't mutated unexpectedly.
- `evalB10` status logic: verify the armed vs unarmed branch. Unarmed must
  NEVER emit FAIL (the test `TestB10_Retention_Unarmed_DowngradesFailToWarn`
  asserts `!res.AnyFailed()`); confirm no path violates that.
- The unit-test fixture `makeTPSResult` sets TTFT=200ms, tokens=64 and derives
  LastByteUTC so TPS is exact. Confirm the fixtures actually exercise the
  PASS/WARN/FAIL/SKIP boundaries they claim (0.933/0.80/0.60), and that
  `soakResults` produces disjoint 5-min windows with 10 samples each.
- Any Go correctness smell: unused vars, shadowing, integer/float division,
  slice aliasing, time-zone assumptions on StartUTC.
- Back-compat: does adding the `SustainedTPS` field (json:"sustained_tps") to
  `BuyerMetrics` or the allow-list change break any existing artifact
  consumer or existing B1-B7 behavior?

## How to review

The branch is checked out at the repo root you're invoked in. Read the full
files, not just the diff:
- `test/network-harness/internal/benchmark/benchmark.go`
- `test/network-harness/internal/benchmark/benchmark_test.go`
- `test/network-harness/internal/scenario/schema.go`

`go build ./... && go test ./... && go vet ./...` are GREEN in
`test/network-harness`. Report only real defects; provisional thresholds are
intentional (they're calibrated later from a lab run) — do NOT flag the
threshold *values* as wrong, but DO flag any logic that mis-applies them.
