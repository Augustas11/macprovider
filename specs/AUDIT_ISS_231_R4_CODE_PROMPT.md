# Audit: ISS-231 R4 code lens — verify R3 fixes

R3 returned (code 0/0/0/1) + (sec 0/0/1/0) + (arch 0/0/0/1). R4
verifies on commit `98309b5`. Tree: `spec/iss-231-spec-007-v04`.
`git log --oneline -7`.

## R3 findings to verify

- **CODE LOW**: gofmt drift. Fix: `gofmt -w` applied.
- **SEC MEDIUM**: missing request_id-leading index on
  quota_reservations + concurrency_reservations. Fix: added
  `idx_quota_request` + `idx_concurrency_request` to schemaSQL;
  bumped `maxKnownSchemaVersion` 3→4 with INSERT OR IGNORE.
- **ARCH LOW**: stale "full list" wording in v0.4 change-log.
  Fix: paragraph rewritten to say "bounded forensic sample".

## What I want (R4 code lens)

Expect 0/0/0/N. Specifically:

- gofmt clean?
- Migration v4 idempotent + safe to apply on existing v3 DBs?
- INSERT OR IGNORE on schema_migrations(4) doesn't race the
  schema-version-gate check?
- EXPLAIN QUERY PLAN inference looks right?

End with `## Convergence X/X/X/X → DECISION`.
