-- Operator rollback artifact for migration 020. The embedded migration runner
-- intentionally applies only *.up.sql; execute manually only when rolling back
-- the waiting-trust chip-profile projection.

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_onboarding') THEN
        REVOKE SELECT (chip_normalized) ON chip_hardware_profiles FROM provider_onboarding;
    END IF;
END $$;

DELETE FROM schema_migrations_spec017 WHERE version = 20;

COMMIT;
