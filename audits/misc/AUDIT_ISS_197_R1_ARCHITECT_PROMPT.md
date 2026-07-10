You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), ARCHITECT lane.

## Scope

SPEC-002 v1.5.1 R-2 normative clarifications, doc-only, additive on top of v1.5.0
(merged via PR #224 on 2026-06-29).

The two clauses (in `specs/SPEC-002-coordinator.md`):

1. **`external_request_id` UUID-tolerance**: opaque sanitized text 1-128 bytes;
   coordinator MUST NOT reject non-UUID-shaped IDs but MUST apply sanitization;
   cross-service reconciliation MUST NOT assume UUIDv4 shape.

2. **Column-present / index-absent state semantics**: three states (A) legacy,
   (B) unindexed/rollout-incomplete, (C) fully migrated; tooling MUST introspect
   both `PRAGMA table_info` AND `sqlite_master`; MUST report state (B) as
   `"unindexed"` distinct from state (A) "legacy".

The original issue #197 framed these as additions to v1.4.3 R-2 of SPEC-002,
but v1.4.3 never shipped (we leapfrogged to v1.5.0 via #211). v1.5.1 is the
landing zone.

## What to verify

- **Cross-SPEC consistency**:
  - SPEC-006 v0.9.1 (gateway forward contract — R-G3 UUIDv4 minting).
    Does v1.5.1's "MAY carry any non-control 1-128-byte text" on the
    direct buyer-port path conflict with SPEC-006's gateway-side R-G3,
    or is the boundary clearly drawn (gateway=UUIDv4, coordinator=opaque
    text)?
  - SPEC-005 v0.3.1 reconciliation contract — does the v1.5.1 "state (B) MUST
    be reported as unindexed" requirement propagate cleanly to SPEC-005's
    reconciliation tooling, or does SPEC-005 still describe a binary
    legacy/migrated state model?
  - SPEC-007 v0.3 explorer addendum (PR #221) — does the explorer surface
    introspect column AND index state per the v1.5.1 contract, or does it
    still use column-only PRAGMA-based gating?

- **Implementation extensibility**: v1.5.1 says tooling MUST introspect both
  `PRAGMA table_info` AND `sqlite_master`. Does the current
  `coordinator migrate-indexes` output expose that state machine in a
  machine-readable way? Should v1.5.1 also require the coordinator to expose
  a `/admin/migration-state` or `migrate-indexes --check` mode that returns
  the three-state status, so external tooling has a single source of truth?

- **Naming consistency**: v1.5.1 uses "state (A) / (B) / (C)". Other SPEC
  sections use "rollout window", "deploy ordering", "pre-v1.5.0", etc. Is
  the state-letter notation introduced cleanly, or does it conflict with
  any existing notation in SPEC-002 / SPEC-005 / SPEC-006?

- **Migration ordering with v1.5.0**: v1.5.0 added a SECOND partial-NULL
  composite index (`idx_request_log_account_external_request_id`) on top of
  v1.4.2 R-2's `idx_request_log_external_request_id`. Both ship via
  `coordinator migrate-indexes`. The v1.5.1 state machine assumes "one
  column ↔ one index"; in reality, post-v1.5.0, the schema has two
  separately-migratable composite indexes. Does v1.5.1 need to clarify
  whether the state machine is per-key (separate for each composite
  reconciliation key) or whole-schema (single migrate-indexes run covers
  both)? `coordinator migrate-indexes` is whole-schema — one CLI
  invocation, all partial-NULL indexes built atomically.

- **Audit tooling contract**: v1.5.1 says tooling MUST report state (B)
  as `"unindexed"`. Is there a canonical naming for the three states the
  SPEC should standardize on (e.g. `migration_state: "legacy" | "unindexed"
  | "indexed"`)? This bites if multiple downstream teams write tooling
  that uses different strings.

- **Scope creep risk**: the issue scope was "two clarifications to the
  freshly-merged R-2". Did the v1.5.1 text drift beyond that — e.g. by
  adding implicit MUSTs that weren't in v1.5.0 / v1.4.2?

- **Reconciler false-positive class**: if state (B) tooling correctly
  reports "unindexed" but uses the slow exact-composite-key join, does
  this introduce a window where the reconciler is so slow it falls
  behind the steady-state ingest rate? (See `tracking-issue-scope-control`
  memory and the existing reconciler at issue #226.)

## Severity rubric

- **CRITICAL**: a contradiction between v1.5.1 and another normative SPEC
  that an implementer cannot resolve.
- **HIGH**: v1.5.1 introduces an ambiguity that would cause two SPEC-conformant
  implementations to disagree on observable behavior.
- **MEDIUM**: cross-SPEC pointer / naming / state-machine cleanups that
  improve operator and tooling-author ergonomics.
- **LOW / NIT**: phrasing, grammar.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

Return a structured findings list with severity, file:line (or section),
evidence, and recommended fix.
