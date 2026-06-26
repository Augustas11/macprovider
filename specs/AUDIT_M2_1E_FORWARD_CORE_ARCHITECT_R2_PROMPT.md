# M2-1e forwardWithFailover core — ARCHITECT-lane audit, Round 2 (closure verification)

Round 1 produced `specs/M2_1E_FORWARD_CORE_ARCHITECT_audit.md`:
**0 CRITICAL / 0 HIGH / 0 MEDIUM / 3 LOW / 0 QUESTIONS**.
VERDICT: architect lane READY TO MERGE — **ARCH-1 / CODE-1 → RESOLVED**.

The author addressed architect L1 (naming the fourth INTENTIONAL
divergence). L2 (split callback bag) and L3 (replace `extra any`)
are explicitly deferred per the round-1 audit's own framing ("before
adding a fourth transport / before contributors compose pieces").

## Branch / commit
- Branch: `fix/m2-1e-forward-with-failover-core`
- Worktree: `../macprovider-m2-1e-forward-core`
- Read: `git diff origin/main`

## Round-1 findings to verify closure on

- **L1.** Name the retry-budget bypass as the fourth INTENTIONAL
  transport divergence.
  - Fix expected: `forward_with_failover.go` doc block now enumerates
    4 (was 3) INTENTIONAL divergences, with `skipRetryBudgetCheck`
    explicitly named as #4 with its M2-1d-baseline justification.
- **L2.** Split callback bag before adding a fourth transport.
  - Deferred (advisory; this PR doesn't add a fourth transport).
- **L3.** Replace `extra any` before HTTP callback reuse becomes
  likely.
  - Deferred (advisory; current scope is single-transport extra).

## ARCH-1 / CODE-1 gate confirmation

Re-confirm the round-1 ARCHITECT GATE verdict still holds after the
comment-only fix-pass:

- Single `failoverCandidate` call site (in core)?
- Single `state.provider = next` same-attempt mutation (in core)?
- Single-owner-per-category retry-semantics map?
- Doc trail (REMAINING_WORK.md) still correct (ARCH-1 / CODE-1
  entries removed; M2-1 row `RESOLVED`; 2026-06-26 sweep note
  precise)?

## Output format

```
CLOSURE on round-1 findings:
  L1: PASS|PARTIAL|FAIL — <one line>
  L2: <note deferred>
  L3: <note deferred>

ARCH-1 / CODE-1 GATE: HOLDS | WITHDRAWN — <one-line reason if withdrawn>

NEW FINDINGS (round 2):
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/M2_1E_FORWARD_CORE_ARCHITECT_r2_audit.md`.

If L1 closed AND gate holds AND zero NEW C/H/M, end with:
`VERDICT: architect lane READY TO MERGE — ARCH-1 / CODE-1 → RESOLVED`
