# A3 — Coordinator-side swap veto

**Type**: ship-now · **Size**: S (~3-5 operator hours) · **Dependencies**: none

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **VALID**.

**Status (2026-07-29)**: complete in PR #801 at `66fec87f` ("Reject swapped
autotune evidence at the coordinator").

## Problem (roadmap §4.4)
`swap_detected` is a paid-recommendation hard veto client-side (#742) but is
decoded and then **ignored** coordinator-side — `benchmarkPassesGate` never
checks it (`internal/autotune/gate.go:88,107`). A provider that edits
`last-recommendation.json`, or simply serves a swapping model, is not stopped.

## Change
Reject a benchmark with `swap_detected == true` in `benchmarkPassesGate`,
symmetric with the client rule.

## Files
`internal/autotune/gate.go`; test in `internal/autotune/`.

## Tests
`SwapDetected` is already decoded into `VerifiedBenchmark`
(`internal/autotune/evidence.go:13`), so the single added predicate + a unit
test is complete as scoped.

## Contingency note
`benchmarkPassesGate` is reached only through `ResolveMaxAdmission` →
`EvaluateHelloGate` → `checkAutotuneHelloGate`, which returns early while
`require_autotune_hello_gate` is false (`server.go:2333`). So A3's rejection
**bites nothing in the current prod config** — it is correct pre-positioning for
when the gate turns on (Brief B5), not a live-gap closure. Ship it (the
asymmetry is a real latent bug), but do not frame it as fixing something today.

## Non-goals
Does not touch the ceiling, routing, or the hello-gate flag; hardens one
existing predicate. Money-path-adjacent → three-lane audit.
