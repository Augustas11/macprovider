# Codex audit: M4 step 2, batched cached follow-up turns (AC-26)

Commits: `f9a71a3b` (cached turns behind a flag), `ff49716e` (per-tuple
`cached_turns_accepted` grant and checkpoint layout validation), and the
cancel fixes that followed.

| Lane | R1 | R2 | R3 | R4 |
| --- | --- | --- | --- | --- |
| Code | FAIL 0/0/1: no checkpoint layout validation | FAIL 0/0/1: cancel lost when a retained install fails | FAIL 0/0/1: cancel lost during the discard inside `finishQueued` | **PASS**, after a single-pass sweep of every M4 await point |
| Security / money path | **PASS** | not re-run | not re-run | not re-run |
| Architecture | FAIL 0/0/1: cached turns entered canary before the AC-26 proof | **PASS** | not re-run | not re-run |

- **Lost-cancel pattern.** Across the M4 audits, five findings were
  lost-cancel windows on new await points: step 1 R1 and R2, and step 2 R2 and
  R3.
- **Root fix.** Every pre-admission completion now goes through
  `finishQueued`. It checks for a pending cancel after its last await, and
  every terminal path goes through `finishTerminal`.
- **Carried to the live enable.** Real MLX restore tests are Metal-gated and
  skip off-hardware. The relay-rig e2e on the Studio covers the runtime path.
  The AC-26 packaged proof, with receipts and settlement, is still required
  before `cached_turns_accepted` is set on a live provider.
