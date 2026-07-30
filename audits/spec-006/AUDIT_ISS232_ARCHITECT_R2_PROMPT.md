## Lane: ARCHITECT — Round 2

## Context

R1 ARCH: 0 C / 0 H / 1 M / 0 L (docs).

R1 fix-pass landed as commit `9cffa7c`:
1. Switched anchor to `SawSSEErrorEvent`.
2. Updated README + I1 invariant comment.

## Your job

ARCHITECT LANE round 2: re-audit.

- Is the new anchor (SSE error envelope) the right architectural choice vs SawTerminator? SEC R1 made the case for it; does it hold up under design review?
- The corroboration now lives partly in `phase5-gateway` (which emits the envelope) and partly in the harness (which detects it). Is this cross-service coupling acceptable, or does it need a SPEC contract?
- The R1 ARCH M was about README + I1 comment. Are there OTHER docs / SPEC references that should be updated (SPEC-006 §17.7, beta/DECISION_CRITERIA references, the issue body, etc.)?
- Should `SawSSEErrorEvent` also carry the error CODE (e.g. `stream_truncated`, `provider_disconnected`) so triage can cross-check the gateway's outcome label against the buyer-observed error code?
- The R0 design had Option 1 (chosen) and Options 2 (suspicious-delta) and 3 (per-outcome tolerance) as alternatives. After R1's fix, is the binary corroboration check still complete, or should this PR also ship a triage signal (Option 2-shaped)?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/result.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/README.md`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/invariants/hard.go`

R1→R2 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
