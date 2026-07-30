# IMPL audit prompt — SPEC-016 FULL IMPLEMENTATION, shared context, **r3**

r3 holistic re-audit covering the SPEC-016 implementation on
`impl/spec-016` after the r2 fix-pass landed at commit `90e3dbf`.
r2 returned 1 HIGH + 2 MEDIUM in code + sec lanes; arch lane was
CONVERGENT at r2. r2 HIGH was a regression of r1-1 caught
correctly by the audit loop.

This r3 round must:

1. **Verify every r2 finding is closed.** For each `[full-{code,
   sec}:r2-N]`, walk the fix at HEAD and confirm the SPEC
   invariant the finding cited is now enforced.
2. **Catch defects introduced BY the r2 fix-pass.** Particular
   attention to the confirmedDepth refactor — does the new bool
   close the original variable-leak window without opening any new
   one? Does the buildExecutableMask correctly handle SQLite's
   `'` escape-by-doubling rule?
3. **Verify arch CONVERGENCE didn't regress.** Arch lane returned
   0/0/0/0/0 at r2; nothing in r2 fix-pass should have invalidated
   that.

## What r2 closed

### HIGH

| Tag | One-line closure | Files |
|-----|------------------|-------|
| `[full-code:r2-1]` | confirmedDepth bool; recPri/recSec only assigned inside break path | `runner.go::pollAndConfirm` |

### MEDIUM

| Tag | One-line closure | Files |
|-----|------------------|-------|
| `[full-code:r2-2]` | TestRunner_PollAndConfirm_RejectsShallowSecondary regression test | `runner_e2e_test.go` |
| `[full-sec:r2-1]` | buildExecutableMask helper; skip comments + string literals before applying addColumnStmt regex | `migrations.go::buildExecutableMask`, new test in `migrations_test.go` |

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `90e3dbf impl(016): FULL-r2 fix-pass — close 1H + 2M; r2 caught r1 regression`
- Diff base: `main`

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit `f0152c0`

## Implementation surface

Same surface as r1 + r2 (see prior prompt files).
r2 fix-pass deltas concentrated in:

- `phase4-coordinator/internal/payout/runner.go` (confirmedDepth refactor)
- `phase4-coordinator/internal/payout/runner_e2e_test.go` (shallow-secondary regression)
- `phase4-coordinator/internal/payout/migrations.go` (buildExecutableMask)
- `phase4-coordinator/internal/payout/migrations_test.go` (mask test)

## Lane-specific prompts

- `specs/AUDIT_SPEC_016_IMPL_FULL_CODE_PROMPT_r3.md`
- `specs/AUDIT_SPEC_016_IMPL_FULL_SECURITY_PROMPT_r3.md`

Architecture lane is NOT re-fired at r3 (it converged at r2). If
the next round wants arch re-verification, fire it separately.

All lanes are read-only.

## Per-lane BLOCK rule

Each lane must return 0/0/0/X (LOWs OK) to declare CONVERGENT.
Anything ≥ MEDIUM triggers a fix-pass + r4.

## Output format

- `specs/SPEC-016-IMPL-FULL-code-r3-audit.md`
- `specs/SPEC-016-IMPL-FULL-security-r3-audit.md`

Standard structure. Tag findings `[full-{lane}:r3-N]`. Reference
the prior `[full-{lane}:rN-M]` if regression.

## Discipline

- Verify r2 closures hold; cross-step focus.
- Wall-clock target: 20-30 min (smallest surface yet).
- Read-only.
