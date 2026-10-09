## Round 2 (anchored)

Round 1 results are in this directory: r1-code-RESULT.md, r1-security-RESULT.md, r1-architecture-RESULT.md, r1-claude-RESULT.md. Fix commits since round 1: 81d324722, c3938bc41, 4953e6020, 662552b77, fe48bfc28 (`git log a18a65777..HEAD`).

Operator decisions that are NOT findings:
- Ragged shared prefill ships enabled by default, with the 2048 prefill budget and no flag. This follows AGENTS.md rule 11 (a lab-proven change ships on) and an operator veto of default-off. The required mitigation is the offset-spread cap.
- Pre-existing items not fixed in this PR: /v1/status hiding full providers, the calibration request timeout, probe word-vs-token counting, MSB lab commands reachable in release builds, and the TestHeartbeatSwapEmitterWritesAuditLogRow millisecond timing flake.

Tasks:
1. For each round-1 NEW CRITICAL/HIGH/MEDIUM finding (and the LOWs that were fixed), state FIXED / NOT FIXED / PARTIALLY FIXED with file:line evidence.
2. Find regressions or new defects introduced by the fix commits. Pay particular attention to:
   - the X-MacProvider-Capacity-Shed-429 header: every gateway path sends it; without it the coordinator returns the exact pre-PR 503; the header can't be spoofed by a buyer to change billing; the gateway strips or overrides any client-supplied copy;
   - the max_concurrency_depth_override rollback design and its config precedence;
   - live-slot reservation locking;
   - receipt TTFT semantics for streaming, non-streaming and replay;
   - the lower-seat-report acceptance;
   - the ragged spread cap.
Same output format and VERDICT line as COMMON.md. Count NEW findings only (new in this PR, including ones introduced by the fixes).
