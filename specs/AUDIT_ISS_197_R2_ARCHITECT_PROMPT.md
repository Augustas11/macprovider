You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), ARCHITECT lane, ROUND 2.

R1 returned 2 HIGH + 1 MEDIUM + 1 LOW. R2 fixes:

- HIGH #1 (state-(B) operational binding): SPEC §11 v1.5.1 now binds
  production reconciliation tooling to fail closed under state
  `unindexed`. Override (`--allow-unindexed-scan`) is allowed but MUST
  NOT be default.
- HIGH #2 (per-key state machine): SPEC §11 v1.5.1 + the v1.5.1
  change-log block recast the state machine as PER-KEY (each composite
  reconciliation key has its own legacy/unindexed/indexed state);
  aggregate is min-wise. Implementation:
  `requestlog.Store.MigrationState` returns `{Aggregate, Keys[]}`.
- MEDIUM (machine-readable enum + CLI surface): canonical vocabulary
  `"legacy"|"unindexed"|"indexed"` pinned normatively. New CLI surface
  `coordinator migrate-indexes --check --format json`.
- LOW (naming clash with state (C)): renamed "Phase-C reconciliation
  tooling" → "reconciliation tooling" throughout.

## Verify

- **Per-key vs whole-schema clarity**: does the SPEC text consistently
  describe the state machine as per-key with aggregate, or are there
  any remaining whole-schema-only phrasings that would mislead an
  implementer?
- **Aggregate definition completeness**: the rule is `legacy if any
  legacy; indexed iff all indexed; unindexed otherwise`. Are there
  edge cases (e.g. zero keys in `migrationKeyDefs` — should that be
  `indexed` or undefined)? Is the rule reversible — given an
  aggregate, can you infer the per-key set? (Probably not; verify the
  SPEC doesn't promise that.)
- **SPEC-005 alignment**: does SPEC-005 still describe a binary
  legacy/migrated schema-check model? If so, does the v1.5.1 cross-
  reference adequately update SPEC-005's contract, or does SPEC-005
  need a separate version bump? Check `specs/SPEC-005-billing.md`.
- **SPEC-007 cross-reference**: v1.5.1 says SPEC-007 explorer gates by
  resolved row fields (not schema state) so it's independent. Verify
  this against the current PR #221-merged SPEC-007 v0.3 text.
- **`coordinator migrate-indexes --check` placement**: is this CLI
  surface adequately documented? Should the SPEC also describe the
  text-format output, or is JSON-only normative?
- **migrationKeyDefs registry**: future SPEC versions adding more
  composite indexes will extend `migrationKeyDefs`. Is the SPEC text
  clear that this is the extension point, so downstream tools can
  rely on the JSON shape being stable?
- **Operational binding scope**: the v1.5.1 MUST applies to
  "production reconciliation tooling running in steady-state closing-
  the-books". Is that scope crisp enough to avoid arguments about
  whether e.g. dev harnesses, the harness reconciler (issue #226), or
  the explorer's gateway proxy qualify?
- **Override-bound semantics**: `--allow-unindexed-scan` is described
  as bounded by row-count or wall-clock budget. Does the SPEC need to
  specify a default budget, or leave it to the tool? Either is
  defensible — flag if the current "MAY support" language is too vague.

## Severity rubric

- **CRITICAL**: a contradiction with another normative SPEC remains, OR
  the per-key state machine + aggregate rule is internally inconsistent.
- **HIGH**: ambiguity that would cause two SPEC-conformant implementations
  to disagree on observable state-machine behavior.
- **MEDIUM**: cross-SPEC alignment gap (SPEC-005 schema-check text not
  updated; SPEC-007 cross-reference loose).
- **LOW / NIT**: phrasing, registry-extension docs, default-budget
  specificity.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

Return a structured findings list with severity, file:line (or section),
evidence, and recommended fix.
