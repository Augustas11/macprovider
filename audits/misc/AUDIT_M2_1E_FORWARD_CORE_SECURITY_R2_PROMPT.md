# M2-1e forwardWithFailover core — SECURITY-lane audit, Round 2 (closure verification)

Round 1 produced `specs/M2_1E_FORWARD_CORE_SECURITY_audit.md`:
**0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 2 QUESTIONS**.
VERDICT: security lane READY TO MERGE. The author applied
comment-only fixes from the code + architect lanes. Re-verify
nothing security-relevant regressed.

## Branch / commit
- Branch: `fix/m2-1e-forward-with-failover-core`
- Worktree: `../macprovider-m2-1e-forward-core`
- Read: `git diff origin/main`

## Round-1 questions (informational)

- **Q1.** shouldRetry not strictly time-idempotent — receipt-bearing
  path calls shouldRetry twice across dispatch + core; a deadline /
  cancel boundary could cause the second call to return false and
  use the generic terminal renderer instead of the receipt-preserving
  path. Acknowledged as preserved-from-pre-refactor behavior.
- **Q2.** `dispatchedAttempt.extra any` future-proofing — addressed
  in architect lane L3.

## Audit lenses for fresh issues (comment-only fix-pass)

The only edits since r1 are comment-only:
- `forward_with_failover.go` doc block: enumerated 4 INTENTIONAL
  divergences (was 3); count corrected to 11.
- `server.go` streaming `onFailoverHit` callback comment rewritten.
- `audits/2026-06-10/REMAINING_WORK.md` count corrected to 11.

Confirm:
- No money-path semantic change.
- No new cancelAttempt / shouldRetry / logAttempt call site.
- No provider attribution surface change.

## Output format

```
CLOSURE on round-1 findings:
  Q1: noted (pre-refactor preserved)
  Q2: noted (cross-lane to architect)

NEW FINDINGS (round 2):
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/M2_1E_FORWARD_CORE_SECURITY_r2_audit.md`.

If zero NEW CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: security lane READY TO MERGE`
