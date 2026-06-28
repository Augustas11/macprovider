# Audit prompt — ISS-210 R1

## What's under review

Branch `fix/iss-210-demo-usage-events-pk` against `origin/main`
(HEAD `3019238`).

Closes [#210](https://github.com/Augustas11/macprovider/issues/210).
Direct structural sibling of #196 (which shipped as PR #213,
landed `38d03db`). Changes the gateway `demo_usage_events` table
PRIMARY KEY from `(request_id)` to `(demo_token_hash, request_id)`,
closing the cross-demo collision attack where two demo identities
could collide on a buyer-supplied X-Request-ID and have the second
identity's settlement silently drop the audit row.

## What's the same as #196

- Migration pattern: `ensureDemoUsageEventsCompositePK` mirrors
  `ensureUsageEventsCompositePK` exactly — detect legacy shape,
  rename-aside, create canonical, copy, drop, recreate aux DDL,
  stamp v3 inside the same tx.
- Shared `demoUsageEventsTableDDL` + `demoUsageEventsAuxiliaryDDL`
  constants used by both fresh-install and rebuild paths so
  sqlite_master is byte-equal.
- Schema version bump 2 → 3.
- archive-restore.sh + OPS.md updated.
- `maxKnownSchemaVersion = 3` keeps the rollback gate intact.

## What this PR does NOT touch

- Coordinator side (already deferred to #211).
- SPEC-007 explorer docs (deferred to #212).
- `usage_events` table from #196 — already migrated to v2 in PR #213.
- The `SettleDemoReservation` / `EnsureDemoUsageEvent` Go call sites —
  the existing INSERT OR IGNORE semantics remain valid; the new
  composite PK makes the (demo_token_hash, request_id) duplicate the
  only legitimate idempotent no-op.

## Severity bar (TIGHT — user feedback on R5 audit churn)

Three independent lanes (code / security / architect). Report ONLY
CRITICAL or HIGH. MEDIUM findings should be filed as comments
inline in the prompt response but NOT iterated on.

- **CRITICAL** — provable wrong behavior, data corruption, or new
  exploit surface introduced by this PR.
- **HIGH** — a real bug/risk that would fire under realistic inputs,
  OR a #196-style invariant gap.
- (Report MEDIUM as advisory only, do not gate merge on it.)

## CODE lane

Files in scope:
- `phase5-gateway/internal/storage/sqlite/migrate.go`
- `phase5-gateway/internal/storage/sqlite/store.go`
- `phase5-gateway/internal/storage/sqlite/demo_usage_events_pk_test.go`
- `phase5-gateway/dist/archive-restore.sh`
- `OPS.md`

Things to check:
1. `ensureDemoUsageEventsCompositePK` rebuild atomicity — same
   pattern as v2 (rename-aside, create canonical, copy, drop, stamp
   v3 in same tx). Any divergence from the v2 reference?
2. Column order in the INSERT...SELECT — does it match
   `demoUsageEventsTableDDL`?
3. PK detection — does `(len(pkCols) == 2 && both names match)`
   handle the SQLite-pk-ordering correctly when composite PK was
   declared `PRIMARY KEY (demo_token_hash, request_id)`?
4. Schema version stamping path — v3 stamped inside rebuild tx AND
   in the outer Migrate() unconditional stamp loop. Idempotent on
   re-run?

## SECURITY lane

The attack:
1. Demo identity D1 (demo_token_hash=H1) fires a streaming chat
   completion with X-Request-ID=R. Settles cleanly; row written.
2. Demo identity D2 (H2 != H1) fires same prompt + same X-Request-ID.
   Streams response back. Settlement attempts:
   - usage_events: composite PK (account_id, request_id) — succeeds.
   - demo_usage_events PRE-FIX: single PK (request_id) collides; row
     for D2 is silently lost.
   - demo_usage_events POST-FIX: composite (demo_token_hash, request_id)
     — second row inserted, audit trail intact.

Verify:
1. The fix actually closes the exploit end-to-end (cross-demo
   inserts both succeed).
2. No NEW exploit surface opened — e.g., does the unscoped
   `WHERE request_id = ?` lookup somewhere now leak the wrong
   demo's data?
3. `SettleDemoReservation` write path (plain INSERT) and
   `EnsureDemoUsageEvent` fallback path (INSERT OR IGNORE) — both
   compatible with the new PK?

## ARCHITECT lane

1. Consistency with #196 invariants — does this PR follow the same
   conventions (shared DDL constants, byte-equal sqlite_master,
   atomic schema stamp, archive-restore version)?
2. SPEC-006 § N (demo path) — does any spec text constrain the
   demo_usage_events PK shape? If so, addendum needed.
3. Downgrade story — rollback path documented in deploy-pearl-vps.sh
   step 5b (added in #196) already snapshots gateway.db. Any
   demo-specific concern?
4. demo_usage_events does NOT have account_id (it has
   demo_token_hash + client_ip). Is the PK choice
   `(demo_token_hash, request_id)` correct given that the
   exploit is about demo_token_hash collision? Or should it be
   `(client_ip, demo_token_hash, request_id)` for defense in depth?

## Output format

```
SEVERITY: <CRITICAL|HIGH>
TITLE: <short>
FILE: <path>:<line>
DETAIL: <why this is wrong / what fires>
SUGGESTED FIX: <action>
```

Plus optional advisory MEDIUMs (will not gate merge).

If 0 CRITICAL/HIGH: output exactly `0 CRITICAL / 0 HIGH`.
