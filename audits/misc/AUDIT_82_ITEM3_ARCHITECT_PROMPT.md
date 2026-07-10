# Issue #82 item 3 — coordinator-cli pre-flip-audit — ARCHITECT-lane audit

You are the **architect** lane of a three-lane audit of #82 item 3.
SPEC-003 v0.10 → v0.10.1 — additive patch on locked v0.10. Stay
narrowly in your lane.

## Branch / commit

- Branch: `fix/coordinator-cli-pre-flip-audit`
- Worktree: `../macprovider-82-item3-preflip` (origin/main base: 5a233bc)
- Files in scope (`git diff origin/main`).

## Architect-lane scope (apply each; stay in lane)

### ARCH-1. Is v0.10.1 a legitimate additive patch?
- v0.10 added FR-C10 (pair_ot minting policy) and was locked.
- v0.10.1 changes:
  - No wire-shape change.
  - No primitive added.
  - Updates FR-C9.4 runbook prose to point at a shipped command
    instead of a tracking issue.
- The command itself was already referenced in the v0.8.4
  runbook (as "tracking issue #82"); v0.10.1 turns the
  tracking-reference into a normative-requirement reference.
- Is this an ADDITIVE patch or a normative-strengthening
  change requiring a higher version bump? Recall SPEC-002
  v1.4.1 shipped an additive `auth_state` field as patch;
  SPEC-015 v0.3.4 shipped a new enum value as patch. v0.10.1
  shipping a runbook prose tightening + new CLI subcommand
  follows the same convention.

### ARCH-2. Subcommand naming + placement
- The subcommand is named `pre-flip-audit` (per the issue's
  proposed name). It lives alongside `list-tokens`,
  `prune-tokens`, etc. in `phase4-coordinator/cmd/
  coordinator-cli/main.go`. Is this the right placement?
- Alternative: a separate audit-tooling binary
  (`coordinator-audit-cli`). The current placement is
  pragmatic (one binary, one operator workflow) and matches
  the existing `prune-tokens` placement which is also
  operator-side. Confirm.
- The naming "pre-flip-audit" is specific to the
  `RequireProviderTokens` flip. If future audit-style gates
  are added (e.g. SPEC-016 payout-pipeline freshness check),
  would they be additional subcommands or extend this one?
  Out of scope for this PR but worth flagging.

### ARCH-3. Authority of the executable gate
- SPEC-003 FR-C9.4 already specified the freshness check as
  MUST. The new command makes that check executable. Is the
  SPEC supposed to say "operators MUST integrate this
  command" or "operators MUST verify freshness (and the
  command is the reference implementation)"?
- The current SPEC v0.10.1 prose says: "The
  `last_used_at` freshness check is automated by ... Operators
  MUST integrate this command into the deploy pipeline as a
  precondition". This binds the SPEC to the specific command
  name. Is that the right binding tightness?
- Alternative: the SPEC requires the check; the command is
  the implementation; operators MUST use AN automated check,
  and the shipped command is the reference. Looser, more
  forward-compatible.

### ARCH-4. Closing criterion for #82
- After this PR + the explorer auth_state PR (item 4), #82
  has all 4 items shipped. Confirm:
  - Item 1: PR #174 (gateway /poolz)
  - Item 2: shipped earlier (AuthMintFailed enum + wiring +
    /poolz exposure)
  - Item 3: this PR
  - Item 4: pending separate PR
- The "all 4 items shipped + verified" closing criterion in
  the issue body will be met. Confirm.

### ARCH-5. Test infrastructure boundary
- `backdateLastUsed` opens the DB directly via `sql.Open` to
  inject test timestamps. Is this an acceptable test-only
  shortcut, or should `auth.Store` expose a test-only
  helper (e.g. `auth.Store.SetLastUsedForTest`)? The current
  approach is contained to the test file; no new auth API
  surface. Tradeoff: test brittleness if the DB schema
  changes, vs production-API cleanliness.

### ARCH-6. SPEC version cadence
- Recent additive patches: SPEC-002 v1.4 → v1.4.1, SPEC-015
  v0.3.3 → v0.3.4, SPEC-003 v0.10 → v0.10.1 (this PR).
  Three additive patches in a row using the third-level
  patch number. Is this version cadence sustainable, or
  should additive patches roll into the next minor (e.g.
  collect into v0.11)? The current per-patch numbering
  preserves merge-time atomicity; the alternative would
  bundle. Confirm the current convention is the right
  choice.

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

Write to `specs/82_ITEM3_ARCHITECT_audit.md`. If 0 CRITICAL/HIGH/
MEDIUM AND v0.10.1 is a legitimate additive patch, end with:
`VERDICT: architect lane READY TO MERGE — SPEC-003 v0.10.1 additive bump approved`
