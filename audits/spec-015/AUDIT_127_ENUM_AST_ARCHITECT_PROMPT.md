# Issue #127 phase7-verify TestReasonEnumBijection AST walk — ARCHITECT-lane audit

You are the **architect** lane of a three-lane audit (code / security /
architect) of the issue #127 AST-walking enum-bijection test. Stay
narrowly in your lane.

## Branch / commit

- Branch: `fix/phase7-verify-enum-ast-walk`
- Worktree: `../macprovider-127-enum-ast` (origin/main base: 8585586)
- File in scope (`git diff origin/main`):
  - `phase7-verify/internal/verify/enum_drift_test.go` (test-only)

## What this change does (operator summary — NOT the audit answer)

Issue #127 was deferred earlier today (see comment on the issue):
"Tracking confirms the deferral until first SPEC-015 v0.3 reason-
enum extension — when that lands, ship the AST walk in the same PR."

That forcing function did NOT fire — PR #178 added a `warnings[]`
enum value (`non_default_tls_trust`), not a `reason` enum value.
However, the hand-maintained slice has grown to 20 entries (from
10 in the original report; the issue body's comment quotes "22"
which counts pre-rename overcount), so the drift surface is now
larger than at the original defer. The user pulled this in early
to finish the `v1.0.1-followup` queue cleanly before deploying to
Pearl.

## Architect-lane scope (apply each; stay in lane)

### ARCH-1. Is this the right time to land #127?
- The original deferral was "ship in same PR as the next reason-
  enum extension." That forcing function has NOT fired. Pulling
  #127 in standalone now is a deviation from the documented plan.
- Is this premature, or does the grown drift surface (20 hand-
  maintained entries) justify it? Recall the issue body says:
  "Defer until first SPEC-015 v0.3 reason-enum extension lands."
- Counterpoint: shipping the AST walk now means the NEXT reason-
  enum extension lands without ANY test-fixture overhead. Net
  win on future-cost; immediate cost is one test-only diff.
- The user explicitly chose this to finalize the v1.0.1-followup
  label (PRs #178 already closed #126/#128, the only other label
  members). After this, the label has 0 open items.

### ARCH-2. Single-source-of-truth shape
- The new architecture: Go reason constants are the source of
  truth. Schema is checked against them. SPEC §10.4.2 is
  human-maintained, in lock-step via PR review.
- Alternative shapes to consider:
  - **A (current)**: Go constants → AST walk → schema check. SPEC
    is a parallel human-maintained doc.
  - **B**: Schema is canonical, codegen Go constants from it.
    Cost: Build-system step. Benefit: SPEC-aligned single source.
  - **C**: SPEC table is canonical, codegen both Go and schema from
    it. Cost: Spec-format parser. Benefit: spec is truly the source.
- The author chose A (minimum-friction, no codegen). Is this the
  right boundary?

### ARCH-3. Reserved-marker convention
- `FORWARD-COMPAT`/`RESERVED` is now a convention for marking
  constants that are declared but intentionally unused. This is
  a new convention; should it be documented in
  `phase7-verify/internal/verify/implementation-notes.md` or
  similar? Currently the only documentation is the comment IN
  enum_drift_test.go.
- The existing `reasonBundlePubkeyProviderMismatch` comment uses
  the exact word "FORWARD-COMPAT" — that's already in the live
  tree. Confirm.
- Long-term, could this marker convention be extended to other
  unused declarations (e.g. warning kinds, result types)? Out
  of scope for this PR but worth flagging.

### ARCH-4. Test surface budget
- The new test file is ~340 lines (up from 116). Most of the
  growth is the table-driven `_DetectsDrift` test with 5
  synthetic fixtures. Is the test growth justified?
- Counterpoint: without the drift-detection table, the live test
  is a black box — passing-on-trunk gives no confidence it would
  catch a regression on a future PR. The synthetic fixtures are
  the verification-of-the-verification.
- Alternative: drop the `_DetectsDrift` table, rely on the
  bijection check working "by construction." Acceptable trade?

### ARCH-5. Spec doc reference
- SPEC §10.4.2 lists the reason enum table in Markdown. The new
  test does NOT parse the spec; it only cross-checks Go ↔ schema.
  The original issue body's "Suggested fix" mentioned parsing
  spec markdown. The author chose NOT to.
- Rationale: spec markdown parsing is fragile (depends on table
  format), and the spec is human-maintained / reviewed alongside
  schema changes anyway. The schema is the machine-consumable
  contract.
- Confirm this is the right architectural boundary.

### ARCH-6. Closing the v1.0.1-followup label
- After this PR merges, the `v1.0.1-followup` label has zero open
  issues (assuming #126/#128 closed by PR #178 and #127 closed
  by this PR). That's a clean signal that the v1.0.1 verifier
  release is fully hardened. Worth noting in the PR body /
  change-log? (No SPEC change in this PR; nothing to add.)

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/127_ENUM_AST_ARCHITECT_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM AND the early-land timing is acceptable
architecturally, end with:
`VERDICT: architect lane READY TO MERGE`
