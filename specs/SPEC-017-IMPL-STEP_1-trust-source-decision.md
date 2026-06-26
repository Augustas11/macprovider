# SPEC-017 Step 1 — trust-source decision record

Round-1 SECURITY r1 HIGH 1 fix: BUILD §1 prereq 4 +
`[[provider-auth-unauthenticated-end-to-end]]` require the
provider-identity trust-source decision to be recorded at the
review boundary, not buried in SQL comments. This file is the
durable record; the Step 1 PR description links it.

## Decision

**Step 1 grants `stats_rollup` SELECT on
SPEC-002 v1.4 §7 `provider_tokens` as the authenticated
provider-identity source.** No other provider-identity table
appears in the Step 1 OLTP grant inventory
(`005_oltp_source_grants.up.sql`).

The grant fires through the defensive idempotent DO block — if
`provider_tokens` does not exist in the current database, the
grant is silently skipped. This MUST NOT be interpreted as
permission for Step 2's rollup to fall back to any
unauthenticated identity source.

## Step 2 invariants this decision pins

1. **Step 2 rollup queries MUST join on `provider_tokens`** (or
   a downstream surface sourced from it) when materializing the
   `provider_id` column in any `stats_*` table. Joining on a
   `provider_session` / `provider_handshake` table sourced from
   raw hello-frame payloads — even via a view — is forbidden by
   this trust-source decision and is a CRITICAL Step 2
   SECURITY-lane finding.
2. **Live-beta production operates with
   `auth.require_provider_tokens = false`** historically per
   `[[provider-auth-unauthenticated-end-to-end]]` (XSEC-1). The
   Step 2 rollup MUST filter to authenticated rows (per the
   `provider_tokens` join above) OR public cutover MUST be
   blocked until the auth gap is closed at the
   coordinator-config level. The Step 2 IMPL author surfaces the
   chosen path to the operator before writing the rollup
   queries; the Step 4.C cutover-runbook checkbox records which
   path applies in production.
3. **`stats_rollup` MUST NOT receive a SELECT grant on any
   unauthenticated provider-identity surface in a future Step
   2/3/4 migration.** If a new OLTP table appears in
   `005_oltp_source_grants.up.sql` (or a successor), the
   SECURITY-lane audit MUST verify its identity field traces
   back to `provider_tokens`.

## Out-of-scope (Step 2/3/4 work, not Step 1)

- The runtime check that `auth.require_provider_tokens = true`
  on the production coordinator at cutover time. That gate
  lives in the Step 4.C cutover runbook.
- Migration of the public leaderboard suppression flag if
  `require_provider_tokens` flips to false post-cutover. That
  is an operator emergency-suppression path
  (`provider_visibility.mode = 'bucketed' AND actor_kind =
  'operator'` per §6.6.3); the §6.6.3 audit invariant remains
  enforced.

## Verification

- `005_oltp_source_grants.up.sql` enumerates `provider_tokens`
  in its `oltp_tables` array; defense-in-depth `REVOKE ALL ...
  FROM stats_reader, provider_portal` ensures the request-path
  + portal roles cannot read it.
- Integration test `TestAC9_StatsReaderPermissionDeniedOnLedger`
  in `phase4-coordinator/internal/stats/integration_test.go`
  asserts `stats_reader` is denied SELECT on `provider_tokens`
  (alongside the SPEC-005 ledger tables).
- This file is referenced in the Step 1 PR description.
