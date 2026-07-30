# M2-1e forwardWithFailover core — CODE-lane audit, Round 2 (closure verification)

Round 1 produced `specs/M2_1E_FORWARD_CORE_CODE_audit.md`:
**0 CRITICAL / 0 HIGH / 0 MEDIUM / 2 LOW / 2 QUESTIONS**. The author
applied targeted fixes for two of the four. Verify closure + flag any
NEW issue introduced.

## Branch / commit
- Branch: `fix/m2-1e-forward-with-failover-core`
- Worktree: `../macprovider-m2-1e-forward-core`
- Read: `git diff origin/main`

## Round-1 findings to verify closure on

- **L1.** Streaming `onFailoverHit` callback comment misattributed the
  WS-only gate to the classifier.
  - Fix expected: comment now clearly states the gate lives in the
    streaming dispatch callback (`if !wsTunneled { tr.failoverEligible
    = false }`), with the classifier behavior referenced as background.
- **L2.** Some row-sequence-sensitive branches lack explicit
  forward_loop assertions (receipt-bearing null-usage, HTTP retry-budget
  exhaustion, WS-NS cancelled).
  - Deferred to follow-up (advisory finding).
- **Q1.** Should the HTTP-streaming failoverEligible-clearing live in
  the classifier instead of the dispatch callback?
  - Architect-overlap; current placement preserves behavior, architect
    lane chose to leave it as-is.
- **Q2.** Prompt said 12 scenarios; actual is 11.
  - Fix expected: count corrected to 11 in
    `forward_with_failover.go` doc block AND
    `audits/2026-06-10/REMAINING_WORK.md` 2026-06-26 sweep note.

## Audit lenses for fresh issues (apply briefly)

- The streaming dispatch's `if !wsTunneled { tr.failoverEligible =
  false }` line — is the new comment self-contained enough?
- Any other surface where the 11 vs 12 count drifts?
- Side-effects of comment-only edits — should be none, but verify.

## Output format

```
CLOSURE on round-1 findings:
  L1: PASS|PARTIAL|FAIL — <one line>
  L2: <note deferred>
  Q1: <note deferred>
  Q2: PASS|PARTIAL|FAIL — <one line>

NEW FINDINGS (round 2):
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/M2_1E_FORWARD_CORE_CODE_r2_audit.md`.

If all addressed findings closed AND zero NEW CRITICAL/HIGH/MEDIUM,
end with: `VERDICT: code lane READY TO MERGE`
