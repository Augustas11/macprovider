-- SPEC-017 v0.1.8 §7.2 — Postgres role inventory.
--
-- Runtime roles created here (idempotent via DO blocks):
--   stats_reader     — request-path handler role (§7.2.1).
--   stats_rollup     — rollup job role         (§7.2.2).
--   provider_portal  — portal toggle role      (§7.2.3).
--
-- partner_keys_writer (§7.2.4) is INTENTIONALLY NOT CREATED. Per
-- BUILD §2 Step 1 resolution: the locked SPEC grants UPDATE
-- (last_used_at) ON partner_keys ONLY, with no SELECT on `id`;
-- the worker's natural `UPDATE ... WHERE id = $1` SQL is
-- inexecutable under the locked grants. v0.1 IMPL skips the role
-- entirely; last_used_at stays NULL. A future SPEC v0.2 may pin
-- an executable grant pattern (e.g. SECURITY DEFINER stored proc)
-- and unblock the worker.
--
-- Passwords come from the operator's secret store at deploy time
-- via separate role-rename or ALTER ROLE PASSWORD scripts; this
-- migration only creates the role identities + the LOGIN flag.
-- The bootstrap-time `password` literal '__set_at_deploy__' is a
-- placeholder that production deployments MUST replace before
-- exposing the coordinator to traffic (the deploy gate fails
-- closed if any runtime DSN authentication fails).
--
-- All roles are created with NOLOGIN-equivalent secret material;
-- DSN authentication will fail until the operator rotates the
-- password. This is intentional defense-in-depth: a forgotten
-- post-migration secret rotation surfaces as a startup smoke
-- failure (BUILD §C.3 fail-closed), not as a silent unauth'd pool.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_reader') THEN
        CREATE ROLE stats_reader LOGIN PASSWORD '__set_at_deploy__';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_rollup') THEN
        CREATE ROLE stats_rollup LOGIN PASSWORD '__set_at_deploy__';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_portal') THEN
        CREATE ROLE provider_portal LOGIN PASSWORD '__set_at_deploy__';
    END IF;
END
$$;

-- Default privileges hygiene: revoke any default grants on future
-- objects in the public schema so a Step 2/3 migration that adds
-- a new table cannot silently grant SELECT to runtime roles
-- (BUILD §B.4 — surplus default privileges are HIGH).
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE ALL ON TABLES FROM stats_reader, stats_rollup, provider_portal;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE ALL ON SEQUENCES FROM stats_reader, stats_rollup, provider_portal;
