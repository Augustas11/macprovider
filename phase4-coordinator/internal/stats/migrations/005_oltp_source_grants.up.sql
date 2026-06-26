-- SPEC-017 v0.1.8 §7.2.2 IMPL-authored OLTP source grants.
--
-- The locked SPEC normatively pins the rollup role's WRITE grants
-- only; the OLTP READ grants are IMPL-authored against the
-- dependency line-3 versions at IMPL time. This file is the
-- IMPL-author's enumeration against:
--
--   SPEC-002 v1.4 §7 — provider_tokens (authenticated provider
--     identity source per BUILD §1 prereq 4 +
--     [[provider-auth-unauthenticated-end-to-end]]).
--   SPEC-005 v0.3 §4.3-§4.8 — ledger tables that source the
--     rollup's earnings/tokens/jobs aggregates.
--
-- This migration is IDEMPOTENT and DEFENSIVE: if a dependency
-- table is not present in this database (e.g. the operator runs
-- coordinator against an OLTP cluster in a separate DB), the
-- grant is silently skipped instead of failing the migration.
-- The rollup (Step 2) will fail closed at first tick if any
-- expected source table is unreachable; this migration's job is
-- only to encode the grant intent against tables present here.
--
-- AC-9 invariant (BUILD §E.1): stats_reader MUST receive
-- "permission denied" (NOT "relation does not exist") on
-- `SELECT 1 FROM ledger_request_credits LIMIT 1`. The test harness
-- creates stub OLTP tables matching the SPEC-005 names so the
-- grants below apply and the deny becomes a permission-class
-- error, not a missing-relation error.

DO $$
DECLARE
    tbl text;
    oltp_tables text[] := ARRAY[
        'ledger_request_credits',
        'ledger_operator_credits',
        'ledger_payout_ready',
        'ledger_reconciliation_runs',
        'provider_tokens'
    ];
BEGIN
    FOREACH tbl IN ARRAY oltp_tables
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = tbl
        ) THEN
            EXECUTE format('GRANT SELECT ON %I TO stats_rollup', tbl);
            -- Defense-in-depth: explicitly deny on the request-path
            -- role so a future Step 2 migration that introduces a
            -- new ledger view cannot inherit a permissive default.
            EXECUTE format('REVOKE ALL ON %I FROM stats_reader, provider_portal', tbl);
        END IF;
    END LOOP;
END
$$;
