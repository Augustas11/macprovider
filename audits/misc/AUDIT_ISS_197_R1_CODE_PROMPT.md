You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), CODE lane.

## Scope

SPEC-002 v1.5.1 R-2 normative clarifications, doc-only, additive on top of v1.5.0
(merged via PR #224 on 2026-06-29). No code changes; the two clauses describe
contracts the implementation already exhibits as of v1.4.2 R-2 + v1.5.0.

The two clauses (in `specs/SPEC-002-coordinator.md`):

1. **`external_request_id` UUID-tolerance** — coordinator MUST NOT reject non-
   UUID-shaped inbound `X-Request-ID`; MUST apply `sanitizeExternalRequestID`
   (trim; cap 128; reject `<0x20`, `0x7f`, `0x80-0x9f`; on failure treat as
   absent and do NOT echo malformed payload to logs). Gateway-routed traffic
   gets UUIDv4 per SPEC-006 R-G3; direct buyer-port traffic MAY carry any
   sanitized printable 1-128-byte string.

2. **Column-present / index-absent state semantics** — three states:
   (A) column-absent + index-absent (legacy);
   (B) column-present + index-absent ("rollout incomplete, unindexed");
   (C) column-present + index-present (fully migrated).
   Tooling MUST introspect BOTH `PRAGMA table_info` AND `sqlite_master`
   and report state (B) explicitly rather than falling back to fuzzy match.

## What to verify

For each clause, verify the SPEC text accurately describes the
**implementation as it currently is** in:

- `phase4-coordinator/internal/buyer/server.go` (`sanitizeExternalRequestID`
  at around line 4981; usage at around line 1312).
- `phase4-coordinator/internal/requestlog/store.go` (column definitions,
  ensureColumns migration, `MigrateIndexes`).
- `phase4-coordinator/cmd/coordinator/main.go` or whatever subcommand path
  hosts `coordinator migrate-indexes`.

Look for:

- **Mismatches** between the new normative text and the actual code paths
  (e.g. cap is 256, not 128; rejected ranges differ; `migrate-indexes` is
  daemon-side not subcommand-side; etc.).
- **Missing-but-implied** code paths: does the SPEC promise something the
  code doesn't yet do (e.g. a `--diagnostics` flag that doesn't exist)?
- **Hidden divergence between v1.4.2 and v1.5.0 patterns**: did v1.4.2's
  `external_request_id` migration ship with both DDLs at once, contradicting
  the new "two-state-machines" framing?
- **Test corpus alignment**: any existing test that pins behavior the new
  SPEC text now restricts or relaxes? Particularly:
  - `phase4-coordinator/internal/buyer/server_test.go` sanitize tests
  - `phase4-coordinator/internal/requestlog/store_test.go` migration tests

## Severity rubric

- **CRITICAL**: the new SPEC clauses contradict shipped behavior such that
  the v1.5.1 normative text would block a real audit harness from working
  correctly.
- **HIGH**: a normative MUST in the new clauses is not what the code does
  (e.g. SPEC says "reject control characters" but code accepts them).
- **MEDIUM**: ambiguity in the SPEC text that would cause two reasonable
  reconciliation harness authors to produce divergent outputs.
- **LOW / NIT**: wording, grammar, cross-reference fixes.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

Return a structured findings list with severity, file:line, evidence,
and recommended fix.
