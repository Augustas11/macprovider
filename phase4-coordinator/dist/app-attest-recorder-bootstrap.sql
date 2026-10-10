-- Give the migration-031 app_attest_recorder role LOGIN (SPEC-033 §2.7, §5.7).
-- The coordinator connects as this role only to record App Attest
-- verifications (SELECT, INSERT on provider_app_attest_verifications); auto-trust
-- reads that table. Run with the admin/operator Postgres role after migration
-- 031 created the NOLOGIN role. The normal path is
-- phase4-coordinator/dist/provision-app-attest-recorder.py (via
-- `scripts/ops/pearl-runtime.sh next --run`), which generates the password on
-- the database host, passes only its SCRAM-SHA-256 verifier here, and writes
-- ONBOARDING_APP_ATTEST_RECORD_DSN into the coordinator env file:
--
--   export APP_ATTEST_RECORDER_PASSWORD_SCRAM='SCRAM-SHA-256$4096:...'
--   psql -v ON_ERROR_STOP=1 -q -f app-attest-recorder-bootstrap.sql
--   unset APP_ATTEST_RECORDER_PASSWORD_SCRAM
--
-- Every refusal raises, so psql exits non-zero under ON_ERROR_STOP (\quit takes
-- no exit status). The verifier is read with \getenv, never from argv, and the plaintext
-- password never reaches this session, the server log or any output, and
-- statement logging is switched off for the session first, so the verifier is
-- not logged either. The grants are re-asserted so a drifted role ends with
-- exactly SELECT, INSERT on that one table, no access to the trust tables and
-- no role memberships (dist/provision-app-attest-recorder.py then checks
-- onboarding.AppAttestRecorderPolicySQL).

\set ON_ERROR_STOP on

-- Before any credential material is interpolated, switch off every server
-- statement-logging path for this session (PostgreSQL 13+). These settings
-- need a superuser or GRANT SET; without them the session stops here.
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_duration_sample = -1;
SET log_transaction_sample_rate = 0;
SET log_min_error_statement = 'panic';

\getenv recorder_scram APP_ATTEST_RECORDER_PASSWORD_SCRAM
\if :{?recorder_scram}
\else
  \echo 'missing required APP_ATTEST_RECORDER_PASSWORD_SCRAM environment variable'
  DO $$ BEGIN RAISE EXCEPTION 'app_attest_recorder bootstrap refused'; END $$;
\endif
SELECT :'recorder_scram' ~ '^SCRAM-SHA-256\$[0-9]+:[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+$' AS recorder_scram_ok \gset
\if :recorder_scram_ok
\else
  \echo 'APP_ATTEST_RECORDER_PASSWORD_SCRAM must be a SCRAM-SHA-256 verifier, not a plaintext password'
  DO $$ BEGIN RAISE EXCEPTION 'app_attest_recorder bootstrap refused'; END $$;
\endif
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_attest_recorder')
   AND to_regclass('public.provider_app_attest_verifications') IS NOT NULL AS migration_031_ok \gset
\if :migration_031_ok
\else
  \echo 'app_attest_recorder or provider_app_attest_verifications is missing: apply stats migration 031 first'
  DO $$ BEGIN RAISE EXCEPTION 'app_attest_recorder bootstrap refused'; END $$;
\endif

BEGIN;

REVOKE ALL ON provider_app_attest_verifications FROM app_attest_recorder;
DO $$
DECLARE
    t TEXT;
BEGIN
    -- Table-level REVOKE ALL also removes column-level grants.
    FOREACH t IN ARRAY ARRAY['hardware_verification_trust', 'hardware_trust_grants', 'hardware_trust_pending', 'hardware_verification_jobs', 'provider_identities', 'provider_hardware_profiles']
    LOOP
        IF to_regclass(t) IS NOT NULL THEN
            EXECUTE format('REVOKE ALL ON %I FROM app_attest_recorder', t);
        END IF;
    END LOOP;
    -- No SECURITY DEFINER function (trust request/approve/revoke,
    -- auto_trust_attested_hardware) is executable by the recorder.
    FOR t IN
        SELECT p.oid::regprocedure::text
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.prosecdef
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM app_attest_recorder', t);
    END LOOP;
END
$$;
GRANT SELECT, INSERT ON provider_app_attest_verifications TO app_attest_recorder;
GRANT USAGE ON SCHEMA public TO app_attest_recorder;

ALTER ROLE app_attest_recorder LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'recorder_scram';

DO $$
DECLARE
    membership RECORD;
BEGIN
    FOR membership IN
        SELECT granted.rolname AS parent_role, member.rolname AS member_role
          FROM pg_auth_members m
          JOIN pg_roles granted ON granted.oid = m.roleid
          JOIN pg_roles member ON member.oid = m.member
         WHERE member.rolname = 'app_attest_recorder'
            OR granted.rolname = 'app_attest_recorder'
    LOOP
        EXECUTE format('REVOKE %I FROM %I', membership.parent_role, membership.member_role);
    END LOOP;
END
$$;

COMMIT;
