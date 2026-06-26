CLOSURE on round-1 findings:
  L1: PASS — `forwardWithFailover` now names FOUR intentional divergences and explicitly lists `skipRetryBudgetCheck` / WS-non-streaming queue-full budget bypass as #4 with the M2-1d baseline test justification (`phase4-coordinator/internal/buyer/forward_with_failover.go:20`, `:35`).
  L2: Deferred — advisory before adding a fourth transport or more terminal branches; this pass does not add a fourth transport.
  L3: Deferred — advisory before HTTP callback reuse becomes likely; current `extra any` use remains single-transport HTTP scratch state.

ARCH-1 / CODE-1 GATE: HOLDS — executable state-machine ownership still centralizes `failoverCandidate`, same-attempt `state.provider = next`, retry-budget policy, and normal retry advance in the shared core/helper set.

NEW FINDINGS (round 2):
CRITICAL (0): none
HIGH (0): none
MEDIUM (0): none
LOW (1):
  L4. Secondary documentation still says "three" intentional divergences after L1 made four canonical.
      Evidence: `transportCallbacks`'s comment still says the shape isolates "the three audit-flagged INTENTIONAL differences" at `phase4-coordinator/internal/buyer/forward_with_failover.go:205`; `REMAINING_WORK.md`'s 2026-06-26 sweep note also names only three preserved INTENTIONAL differences at `audits/2026-06-10/REMAINING_WORK.md:7`.
      Impact: Non-blocking documentation drift only. The primary `forwardWithFailover` block, the WS callback comment, and the skip hook itself correctly name the fourth queue-full retry-budget bypass.
      Fix: Update the secondary comments to say four divergences, or explicitly distinguish the original three PR #93 divergences from the fourth M2-1e/M2-1d queue-full budget bypass.
QUESTIONS (0): none

GATE EVIDENCE:
  - Single executable `failoverCandidate` call site: `phase4-coordinator/internal/buyer/forward_with_failover.go:139`.
  - Single same-attempt failover mutation: `phase4-coordinator/internal/buyer/forward_with_failover.go:143`. Other provider assignments are initial selection (`server.go:1220`) and normal retry advance (`server.go:1770`).
  - Single-owner-per-category retry semantics map still holds: budget gate in `forwardWithFailover` / `shouldRetry`; same-attempt failover selection in `failoverCandidate`; retry mutation in `advanceToNextProvider`; per-transport rendering/log envelopes in callback bundles.
  - Doc trail remains gate-sufficient: ARCH-1 / CODE-1 entries are removed from the severity punch list and the M2-1 row is `RESOLVED` at `audits/2026-06-10/REMAINING_WORK.md:89`. The only doc-trail issue is LOW L4's stale "three" count in the sweep note.

VALIDATION:
  - Ran from `phase4-coordinator`: `go test ./internal/buyer -run 'TestM2_1C|TestM92|TestM2_1D' -count=1`
  - Result: pass (`ok github.com/augstar/macprovider-coordinator/internal/buyer 0.361s`).

VERDICT: architect lane READY TO MERGE — ARCH-1 / CODE-1 → RESOLVED
