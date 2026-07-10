# Audit prompt — ISS-196 R1 ARCHITECT lane

## What's under review

`fix/iss-196-account-scoped-pk` against `origin/main` (HEAD `ad76194`).
Changes the gateway's `usage_events` table PRIMARY KEY from
`(request_id)` to `(account_id, request_id)` to close [issue #196](https://github.com/Augustas11/macprovider/issues/196).

## Audit lens — ARCHITECTURE / INVARIANTS

You are the architect. Hold the PR to system invariants that span beyond the
files changed. Severity bar:

- **CRITICAL** — fix violates a spec, breaks a load-bearing invariant, or
  introduces a new one inconsistent with neighboring tables.
- **HIGH** — design pattern divergence from existing migrations (e.g.,
  `ensureOAuthStateActionColumn` set a precedent for in-place upgrade —
  is the new function consistent with that pattern?), or a missed
  cross-cutting consequence (explorer queries, reconciler scripts,
  audit-trail JOINs, deploy gates).
- **MEDIUM** — documentation drift between spec and implementation;
  forward-compatibility concerns for downstream tooling.
- **LOW** — won't file.

## Concrete things to check

1. **SPEC alignment.** SPEC-005 § BL-1 / BL-2 (billing ledger
   invariants) and SPEC-006 § 17.7 (settle-after-commit fallback).
   Does the composite PK preserve the documented uniqueness
   guarantees? Does any spec document need an addendum to describe
   the change?
2. **Append-only triggers.** The migration drops + recreates the
   `usage_events_no_update` and `usage_events_no_delete` triggers
   manually inside the rebuild. Is this consistent with how
   `schemaSQL` declares them? Drift between the migration's trigger
   bodies and the canonical schemaSQL bodies?
3. **Symmetry with `quota_reservations` / `concurrency_reservations`.**
   Those tables already have composite PK `(account_id, request_id)`.
   Does usage_events now match the same shape, conventions,
   index naming? Any reconcile-script that joins all three tables?
4. **Per-account ordering / sort columns.** Now that
   `(account_id, request_id)` is the PK, the natural query order is
   account-prefixed. Are there explorer/reconciler queries that
   relied on `request_id`-only sort and now do a full scan? Look at
   `explorer.go:64` (latest request per account) and `:299`
   (timeline). Look at SPEC-006 § 14.3 demo audit join.
5. **Forward-compatibility with SPEC-002 v1.4.2 `external_request_id`
   work (PR #195 / #192).** That work adds buyer-vs-internal request
   id distinction. Does this PR's composite-PK rebuild interact
   correctly with the `external_request_id` column added on the
   coordinator side? (Different DB, but architectural alignment.)
6. **Existing in-place upgrade pattern.** `ensureOAuthStateActionColumn`
   uses `ALTER TABLE ADD COLUMN` — additive, low-risk. This new
   function does a full table rebuild — more invasive. Is the
   precedent / blast radius documented? Is there a SPEC-XXX
   addendum or DECISION_CRITERIA.md entry warranted?
7. **Downgrade story.** Operator runs deploy, picks up the new
   binary, migration runs. If they need to roll back to the
   previous binary, can it open the migrated DB? (Old binary
   expects single-column PK schema — would it crash on Open or
   just keep working since CREATE IF NOT EXISTS is a no-op?)
8. **Naming.** `idx_usage_account_date` was created before this
   change; the composite PK now provides `(account_id, ...)`
   index-like access. Is the secondary index redundant? (Probably
   not — `(account_id, window_date)` is more specific — but worth
   flagging if it is.)
9. **`schemaSQL` source of truth.** New installs land at composite
   PK directly via schemaSQL; old installs go through the upgrade
   function. The two paths must converge byte-for-byte. Does the
   trigger-body whitespace in the upgrade function exactly match
   schemaSQL? (Tabs vs spaces, etc. — affects schema hash
   comparisons in tools like sqldiff.)

## Output format

```
SEVERITY: <CRITICAL|HIGH|MEDIUM>
TITLE: <short>
FILE: <path>:<line>  (or "design" / "spec")
DETAIL: <invariant violated; cross-system impact>
SUGGESTED FIX: <action — spec amendment, code change, or doc>
```

If 0 findings, output exactly: `0 CRITICAL / 0 HIGH / 0 MEDIUM`.

## R2 update — what changed since R1
- Rebased onto current main (ad76194 includes #193 — the prior CRITICAL on 503 was a stale-base false positive).
- Shared usageEventsAuxiliaryDDL constant (addresses R1 MEDIUM byte-match).
- maxKnownSchemaVersion=2 + checkSchemaVersionGate (addresses R1 HIGH rollback).
- ExplorerSessionDetail accountID parameter + ambiguity (addresses R1 HIGH explorer).
- Filed #210 (demo_usage_events) and #211 (coord request_log).

Re-audit against the same bar.

## R3 update — what changed since R2
- A1 (gateway-coord join): documented in PR body, deferred to #211 — not a blocker for #196 (gateway-only scope).
- A2 (rollback safety): deploy-pearl-vps.sh new step 5b snapshots gateway.db pre-restart; rollback hint updated to require both binary.prev AND db.pre-deploy.<ts>; binary-only rollback flagged as unsafe after schema bump.
- A3 (archive-restore EXPECTED_VERSION): bumped to 2; OPS.md updated; archive_rotate_test comment updated.
- A4 (request_id lost its index): added `idx_usage_request ON usage_events(request_id)` to usageEventsAuxiliaryDDL.
- A5 (ambiguity check usage-only): explorerAccountIDsForRequest now UNIONs across usage_events, quota_reservations, concurrency_reservations.
- A6 (sqlite_master byte mismatch): rebuild now uses rename-aside + create-canonical-name pattern, both paths share `usageEventsTableDDL` constant; new test `TestUsageEventsSqliteMasterByteIdenticalAcrossPaths` asserts byte-equality.

Re-audit on the same bar.

## R4 update — what changed since R3
- WAL snapshot HIGH fixed: deploy step 5b now uses `sqlite3 .backup` (WAL-consistent) + integrity_check verify; exit 5 on failure.
- SPEC-007 doc drift filed as #212 (out of scope for this PR per scope control).

Re-audit on the same bar.
