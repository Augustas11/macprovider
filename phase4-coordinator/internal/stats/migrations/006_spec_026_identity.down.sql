-- Operator rollback artifact for SPEC-026 v0.11 Phase 1a schema.
-- The embedded migration runner intentionally applies only *.up.sql;
-- this file is validated by tests/runbooks and executed manually by
-- operators only during rollback.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_auth_policy_approver') THEN
        REVOKE ALL ON FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) FROM provider_auth_policy_approver;
        REVOKE USAGE ON SCHEMA public FROM provider_auth_policy_approver;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_auth_policy_requester') THEN
        REVOKE ALL ON FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM provider_auth_policy_requester;
        REVOKE USAGE ON SCHEMA public FROM provider_auth_policy_requester;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_auth_policy_cutover') THEN
        REVOKE ALL ON FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) FROM provider_auth_policy_cutover;
        REVOKE USAGE ON SCHEMA public FROM provider_auth_policy_cutover;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_auth_policy_definer') THEN
        REVOKE ALL ON provider_auth_policy_grants FROM provider_auth_policy_definer;
        REVOKE ALL ON provider_auth_policy_pending FROM provider_auth_policy_definer;
        REVOKE ALL ON provider_auth_policy_cutover_runs FROM provider_auth_policy_definer;
        REVOKE ALL ON provider_auth_policy FROM provider_auth_policy_definer;
        REVOKE ALL ON provider_identities FROM provider_auth_policy_definer;
        REVOKE USAGE, CREATE ON SCHEMA public FROM provider_auth_policy_definer;
    END IF;
END
$$;
REVOKE ALL ON FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) FROM provider_onboarding;
REVOKE ALL ON FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM provider_onboarding;
REVOKE ALL ON FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) FROM provider_onboarding;
REVOKE ALL ON provider_auth_policy_grants FROM provider_onboarding;
REVOKE ALL ON provider_auth_policy_pending FROM provider_onboarding;
REVOKE ALL ON provider_auth_policy FROM provider_onboarding;
REVOKE ALL ON FUNCTION prune_provider_register_nonces(INTERVAL) FROM provider_onboarding;
REVOKE ALL ON provider_register_nonces FROM provider_onboarding;
REVOKE ALL ON provider_identities FROM provider_onboarding;
REVOKE ALL ON SEQUENCE provider_register_nonces_id_seq FROM provider_onboarding;

DROP FUNCTION IF EXISTS approve_provider_auth_policy_exemption(UUID, TEXT);
DROP FUNCTION IF EXISTS request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT);
DROP FUNCTION IF EXISTS seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]);
DROP FUNCTION IF EXISTS prune_provider_register_nonces(INTERVAL);
DROP TABLE IF EXISTS provider_auth_policy_grants;
DROP TABLE IF EXISTS provider_auth_policy_pending;
DROP TABLE IF EXISTS provider_auth_policy_cutover_runs;
DROP TABLE IF EXISTS provider_auth_policy;
DROP TABLE IF EXISTS provider_register_nonces;
DROP TABLE IF EXISTS provider_identities;

DROP ROLE IF EXISTS provider_auth_policy_cutover;
DROP ROLE IF EXISTS provider_auth_policy_approver;
DROP ROLE IF EXISTS provider_auth_policy_requester;
DROP ROLE IF EXISTS provider_auth_policy_definer;
DROP ROLE IF EXISTS provider_onboarding;
