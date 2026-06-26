L4 CLOSURE: PASS — the primary `forwardWithFailover` block, `transportCallbacks` comment, and 2026-06-26 `REMAINING_WORK.md` sweep note all now name the FOUR intentional per-transport divergences.

ARCH-1 / CODE-1 GATE: HOLDS — committed state still centralizes `failoverCandidate`, same-attempt `state.provider = next`, retry-budget policy, and normal retry advance in the shared core/helper set.

NEW FINDINGS (r3):
CRITICAL (0): none
HIGH (0): none
MEDIUM (0): none
LOW (0): none
QUESTIONS (0): none

GATE EVIDENCE:
  - `phase4-coordinator/internal/buyer/forward_with_failover.go` is tracked in `git diff --name-status origin/main`, closing the r2 CODE-lane tracked-file blocker.
  - L4 text check: `phase4-coordinator/internal/buyer/forward_with_failover.go:20` says `The FOUR INTENTIONAL`; `phase4-coordinator/internal/buyer/forward_with_failover.go:208` says `shape isolates the FOUR audit-flagged INTENTIONAL differences`; `audits/2026-06-10/REMAINING_WORK.md:7` says `The FOUR audit-flagged INTENTIONAL per-transport differences`.
  - Single executable `failoverCandidate` call site remains `phase4-coordinator/internal/buyer/forward_with_failover.go:139`.
  - Single same-attempt failover mutation remains `phase4-coordinator/internal/buyer/forward_with_failover.go:143`; the other provider assignments are initial selection in `server.go:1220` and normal retry advance in `server.go:1770`.
  - ARCH-1 / CODE-1 per-finding entries remain absent from the severity punch list; the M2-1 task row remains `RESOLVED` at `audits/2026-06-10/REMAINING_WORK.md:89`.
  - Validation: from `phase4-coordinator`, `go test ./internal/buyer -run 'TestM2_1C_RowSequence|TestM92_RowSequence|TestM2_1D_RowSequence' -count=1` passed (`ok github.com/augstar/macprovider-coordinator/internal/buyer 0.336s`).

VERDICT: architect lane READY TO MERGE — ARCH-1 / CODE-1 → RESOLVED
