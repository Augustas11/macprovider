-- SPEC-017 v0.1.8 §7.2 — grant inventory. Enumerates SPEC-017-owned
-- tables ONLY. OLTP source grants for stats_rollup (SPEC-002 §7
-- provider_tokens + SPEC-005 §4 ledger tables) live in
-- 005_oltp_source_grants.up.sql, which is conditional on the
-- dependency tables existing in the same database. If the operator
-- runs the coordinator against an OLTP cluster that hosts SPEC-002 /
-- SPEC-005 tables in a separate database, the OLTP grants migration
-- runs there instead.
--
-- All grants below run AFTER the table creates in 001 (BUILD §B.1).

-- ===== Defense-in-depth: revoke from PUBLIC (round-1 CODE r1 B1). =====
-- The earlier draft revoked from each runtime role before the
-- grant block — a no-op because the role had no prior grant.
-- The locked SPEC requires the deny boundary to be on PUBLIC,
-- not the runtime roles. PUBLIC is the implicit grantee of any
-- default privilege; revoking it here keeps a future Step 2/3
-- table from auto-inheriting SELECT for everyone.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

-- ===== stats_reader (§7.2.1) — request-path handler role. =====
GRANT USAGE ON SCHEMA public TO stats_reader;

GRANT SELECT ON
    stats_overview_current,
    stats_timeseries_rpm_30m,
    stats_timeseries_tpm_30m,
    stats_leaderboard_24h,
    stats_leaderboard_7d,
    stats_leaderboard_30d,
    stats_leaderboard_all,
    stats_components_health,
    stats_rewards_populated,
    provider_visibility,
    partner_keys
TO stats_reader;

-- Explicit denies on rollup-internal / write-only tables.
-- Pre-emptive REVOKE; no-op if no prior grant existed.
REVOKE ALL ON
    stats_late_events,
    provider_rewards_ledger,
    provider_visibility_audit
FROM stats_reader;

-- ===== stats_rollup (§7.2.2) — rollup job role. =====
GRANT USAGE ON SCHEMA public TO stats_rollup;

GRANT SELECT, INSERT, UPDATE, DELETE ON
    stats_overview_current,
    stats_timeseries_rpm_30m,
    stats_timeseries_tpm_30m,
    stats_leaderboard_24h,
    stats_leaderboard_7d,
    stats_leaderboard_30d,
    stats_leaderboard_all,
    stats_components_health,
    stats_late_events,
    stats_rewards_populated
TO stats_rollup;

GRANT SELECT ON
    provider_visibility,
    provider_rewards_ledger
TO stats_rollup;

-- BIGSERIAL backing-sequence USAGE for the INSERT path on
-- stats_late_events (§9.3).
GRANT USAGE, SELECT ON SEQUENCE stats_late_events_id_seq TO stats_rollup;

-- Explicit denies on partner_keys + audit table (§7.2.2 invariant).
REVOKE ALL ON partner_keys, provider_visibility_audit FROM stats_rollup;

-- The §9.4 Shape C rebuild uses DELETE+INSERT in a single
-- transaction; the locked grant set does NOT include
-- TRUNCATE / ALTER / DROP. Shape A/B require those privileges and
-- would widen the role inventory beyond the locked SPEC (BUILD §B.3
-- CRITICAL invariant).

-- ===== provider_portal (§7.2.3) — portal toggle role. =====
GRANT USAGE ON SCHEMA public TO provider_portal;

-- SPEC §7.2.3 v0.1.8 erratum (2026-06-26) authorizes SELECT
-- alongside INSERT + UPDATE on provider_visibility for
-- provider_portal.
--
-- SPEC §6.3 normatively pins the toggle SQL pattern as
--   INSERT INTO provider_visibility (provider_id, mode)
--   VALUES ($1, $2)
--   ON CONFLICT (provider_id) DO UPDATE
--     SET mode = EXCLUDED.mode, updated_at = now()
-- PostgreSQL's `INSERT ... ON CONFLICT DO UPDATE` implementation
-- reads the conflicting row's existing data to evaluate the DO
-- UPDATE branch, which requires SELECT — empirically verified
-- by the AC-10 integration test on the live Postgres CI job
-- (run 28224894287): without the SELECT grant, the UPSERT
-- errors with `pq: permission denied for table
-- provider_visibility`.
--
-- The earlier text of this comment described the SELECT as an
-- "IMPL-authored deviation" / "SPEC v0.2 candidate"; the v0.1.8
-- §7.2.3 erratum closed that gap by enumerating SELECT in the
-- locked grant set. This migration now reflects the locked SPEC
-- inventory, not a deviation.
--
-- The grant is column-unrestricted because the §6.3 pattern
-- uses EXCLUDED.* and updates `updated_at = now()`; the locked
-- §6.1 schema's only other column is
-- `blocked_from_partner_projection`, which the portal does not
-- need to read either, so column scoping is operator-optional
-- without functional impact.
GRANT INSERT, SELECT, UPDATE ON provider_visibility TO provider_portal;
GRANT INSERT ON provider_visibility_audit TO provider_portal;
GRANT USAGE, SELECT ON SEQUENCE provider_visibility_audit_id_seq
    TO provider_portal;

-- Explicit deny on all stats_* + OLTP. No-op REVOKE for paths
-- that never had a grant; the line documents the intended deny set.
REVOKE ALL ON
    stats_overview_current,
    stats_timeseries_rpm_30m,
    stats_timeseries_tpm_30m,
    stats_leaderboard_24h,
    stats_leaderboard_7d,
    stats_leaderboard_30d,
    stats_leaderboard_all,
    stats_components_health,
    stats_late_events,
    stats_rewards_populated,
    provider_rewards_ledger,
    partner_keys
FROM provider_portal;
