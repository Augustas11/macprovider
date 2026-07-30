# SPEC-017 IMPL Prompt Code-Mechanics Audit — Round 5

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.6 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**NOT READY:** 1 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW.

Round 5 verifies the round-4 CODE blockers are absorbed: Step 4.B is now blocked
on explicit SPEC reconciliation rather than silently shipping no-burst nginx;
the rollup import carve-out is exactly billing/session/pool and excludes
`internal/explorer`; Step 2 uses per-table freshness markers instead of a
`stats_*.generated_at` shorthand; AC-7 has separate `down` and `degraded`
fixtures; and the prompt's external SPEC-005 table-definition citation now
points at §4.3-§4.8.

One new code-mechanics blocker remains in the Step 1 AC-10 transaction fixture.
The fixture's UPSERT is not valid PostgreSQL for `DO UPDATE`, and even after the
missing conflict target is added it does not produce the `bucketed -> exact`
state transition that the audit row claims on an empty fixture.

## Findings

### CODE-R5-001 — AC-10 provider-portal UPSERT fixture is invalid PostgreSQL and does not prove the claimed toggle

**Severity:** CRITICAL  
**Category:** G.1, E.1, I.2  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 157-164; `SPEC-017-network-stats-api.md` lines 1082-1089 and 1795-1798

Step 1's AC-10 concrete transaction test tells the IMPL author to run:

```sql
INSERT INTO provider_visibility (provider_id, mode)
VALUES ('p1', 'bucketed')
ON CONFLICT DO UPDATE SET mode = 'exact', updated_at = now();
```

This is not mechanically writable against PostgreSQL as a `DO UPDATE` UPSERT:
`ON CONFLICT DO UPDATE` requires a conflict target such as
`ON CONFLICT (provider_id) DO UPDATE ...`. The locked SPEC already pins the
correct state-transition shape in §6.3:

```sql
INSERT ... ON CONFLICT (provider_id)
DO UPDATE SET mode = EXCLUDED.mode, updated_at = now()
```

There is a second mechanics error even if the conflict target is added. On an
empty fixture, `VALUES ('p1', 'bucketed')` inserts a `bucketed` row and never
executes the `DO UPDATE` arm, while the immediately following audit insert
claims `old_mode = 'bucketed'` and `new_mode = 'exact'`. The test then asserts
only the audit row, not that `provider_visibility.mode` became `exact`. An
author following this prompt can either get a SQL execution failure or write a
passing test that proves the audit insert but not the AC-10 visibility toggle.

The rollback subcase is also underspecified: after the successful subcase has
inserted `p1`, "assert no rows in either table" is only true if the test uses a
fresh fixture or a distinct rollback provider. As written, two conforming test
authors could choose different setup/cleanup behavior.

**Fix:** Replace the AC-10 test shape with a concrete, valid two-phase fixture.
For example:

```sql
-- setup, before switching to the provider_portal transaction assertion
INSERT INTO provider_visibility (provider_id, mode)
VALUES ('p1', 'bucketed');

BEGIN;
INSERT INTO provider_visibility (provider_id, mode)
VALUES ('p1', 'exact')
ON CONFLICT (provider_id) DO UPDATE
SET mode = EXCLUDED.mode, updated_at = now();
INSERT INTO provider_visibility_audit
  (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
VALUES
  ('p1', 'bucketed', 'exact', 'provider', 'p1', '127.0.0.1', 'test');
COMMIT;
```

Then assert both:

- `provider_visibility.mode = 'exact'` for `provider_id = 'p1'`.
- Exactly one audit row exists for `p1` with `old_mode = 'bucketed'`,
  `new_mode = 'exact'`, and `actor_kind = 'provider'`.

For the rollback subcase, use a distinct `provider_id` such as `p_rollback`
or reset the fixture before the subcase, then assert no rows for that specific
provider in either table after rollback.

## Category Walk

- **A. Section number drift:** SPEC-017 citations in the prompt resolve to the
  intended locked sections. The prompt's §5.1, §5.2, §5.3, §5.4.x, §5.6,
  §5.7, §5.8, §5.9, §6.x, §7.x, §8.5, §9.x, §10 AC, and §11 Q citations match
  their current headings/content.
- **B. Postgres grant shape correctness:** Role names, table names, grant kinds,
  and BIGSERIAL sequence grants match the locked §7.2 inventory. The
  `partner_keys_writer` default-off resolution preserves the locked
  column-scoped grant rather than widening it. The remaining SQL issue is a DML
  fixture, not a GRANT line; see CODE-R5-001.
- **C. Go package boundary correctness:** The prompt's package layout matches
  the existing flat `internal/explorer/` handler pattern while keeping `store`
  and `rollup` subpackages. Request-path packages use `stats_reader`; rollup is
  limited to billing/session/pool read-only and excludes `internal/explorer`.
- **D. Wire-contract correctness:** Partner-key length math, CORS 204,
  closed error vocabulary, 405 envelope, status codes, cache directives,
  `X-Stats-Generated-At`, ETag/304, and redaction directives match the locked
  SPEC.
- **E. AC test-coverage mapping:** AC-1 through AC-21 are assigned in the §2.4
  matrix. AC-10's assigned Step 1 SQL fixture is not mechanically valid; see
  CODE-R5-001.
- **F. Migration / IMPL-time decision drift:** OLTP source grants are explicitly
  IMPL-authored against locked dependency line-3 at IMPL time. Hostname and
  backfill choices are implemented as both-path code with cutover selection.
- **G. Test-shape correctness:** The rollup fixture corpus and Step 3/4 tests
  are concrete. The AC-10 transaction fixture needs the SQL fix in
  CODE-R5-001 before it is mechanically writable.
- **H. Idiomatic Go correctness:** Per-role `*sql.DB` isolation is pinned and
  compatible with the current coordinator startup pattern. Recover middleware
  shape and context-based bearer handoff are concrete. No v0.1
  `last_used_at` worker/channel is required.
- **I. Naming hygiene:** Role names, table names, event names, and package paths
  are consistent with SPEC-017 and do not collide with the existing explorer
  `internal_bearer_accepted` event.

## Self-Verification

- [x] Walked every `§X.Y` citation against the SPEC.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 5 is close, but not at the requested 0C/0H/0M lock target. The r4 CODE
items are absorbed: Step 4.B no longer silently resolves the nginx burst
conflict, rollup no longer imports `internal/explorer`, freshness tests now use
real per-table markers, AC-7 has pinned `down` and `degraded` fixtures, and the
SPEC-005 table-definition citation is corrected.

The remaining blocker is a new Step 1 AC-10 SQL-fixture mechanics error. The
prompt's provider-portal transaction test uses
`ON CONFLICT DO UPDATE SET ...` with no conflict target, which is invalid
PostgreSQL for `DO UPDATE`; the locked SPEC §6.3 correctly requires
`ON CONFLICT (provider_id) DO UPDATE SET mode = EXCLUDED.mode, updated_at =
now()`. Even after adding that target, the prompt inserts `mode = 'bucketed'`
on an empty fixture, so the `DO UPDATE` arm never runs and the row remains
bucketed while the audit row claims `new_mode = 'exact'`. The test also does
not assert the final `provider_visibility.mode`, so it can pass without proving
the AC-10 toggle. Fix the fixture by seeding `p1` as bucketed, UPSERTing
`p1` to exact with `ON CONFLICT (provider_id)`, asserting both final mode and
audit row, and using a distinct provider or clean fixture for rollback.
