You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), ARCHITECT lane, ROUND 1.

## Scope

SPEC-002 v1.5.2 + SPEC-005 v0.3.3 — monotonic `attempt_n` column promotion.
Closes SPEC-005 §OQ-1.

## What landed

(See code lane prompt for full IMPL surface.)

## Verify

- **SPEC-002 ↔ SPEC-005 consistency**: SPEC-002 v1.5.2 introduces the
  column and the per-column migration state (`legacy | populating |
  populated`). SPEC-005 v0.3.3 consumes it via the row-mapping rule.
  Are the two SPECs internally consistent on the rollout window —
  specifically the "row 3+ quarantine rule" treatment?
- **Cross-SPEC dependency graph**: SPEC-005 v0.3.3 now depends on
  SPEC-002 v1.5.2. Does any other SPEC (SPEC-006, SPEC-007, SPEC-016)
  need to bump its SPEC-002 dependency, or are they unaffected by the
  new column (since they don't consume attempt_n directly)?
- **Migration state vocabulary**: SPEC-002 v1.5.1 introduced
  `legacy | unindexed | indexed` per-key state. SPEC-002 v1.5.2 adds
  `legacy | populating | populated` per-column state. Are the two
  state machines clearly distinct? Is the choice of
  "populating/populated" vs "unindexed/indexed" justified, or does it
  invite confusion?
- **State machine completeness**: the per-column states are derived
  from `(column_present, null_count)`. Is `(absent, 0)` a possible
  state? `(present, NULL count)`? Are there edge cases (e.g. column
  added but daemon never ran, so total=0)?
- **Quarantine rule migration**: the SPEC text claims that the
  v0.3.1 row-3+ quarantine is satisfied by v1.5.2. But during the
  rollout window (populating state), some rows still trigger the
  fallback derivation and could quarantine. Is this transition
  cleanly documented?
- **Backfill subcommand vs migrate-indexes**: both follow the
  operator-driven, one-shot, idempotent pattern. Should they share
  a common CLI structure (e.g. a `coordinator migrate` umbrella
  with subcommands)? Out-of-scope for #168 but worth flagging.
- **CLI machine-readable enum vocabulary**: v1.5.1 pinned
  `"legacy" | "unindexed" | "indexed"` as canonical strings.
  v1.5.2 pins `"legacy" | "populating" | "populated"`. Should these
  share a top-level "schema migration state" type? Or are they
  intentionally separate because they describe different dimensions
  (per-key index state vs per-column population state)?
- **`coordinator backfill-attempt-n` write-side safety**: SPEC says
  the operator MAY run this with the daemon up (single-writer cap
  serializes). Should the SPEC RECOMMEND a maintenance window, or
  is the under-the-cap behavior actually safe and well-defined?
- **No new dependencies on OpenStore vs OpenStoreReadOnly**: the
  `--check` path uses OpenStoreReadOnly (no schema mutation). The
  backfill path uses OpenStore (which runs migrate()). Is this
  ordering correct?

## Severity rubric

- **CRITICAL**: contradiction with another normative SPEC.
- **HIGH**: ambiguity that would split implementations.
- **MEDIUM**: cross-SPEC pointer gaps, scope-clarity issues.
- **LOW / NIT**: phrasing, edge cases.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
