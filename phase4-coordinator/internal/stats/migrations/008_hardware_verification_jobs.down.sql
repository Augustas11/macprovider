-- Operator rollback artifact for autotune hardware evidence verification.
-- The embedded migration runner intentionally applies only *.up.sql.

REVOKE ALL ON hardware_verification_jobs FROM provider_onboarding;
REVOKE ALL ON hardware_verification_trust FROM provider_onboarding;
REVOKE ALL ON SEQUENCE hardware_verification_jobs_id_seq FROM provider_onboarding;
REVOKE ALL ON hardware_verification_jobs FROM stats_hardware_verifier;
REVOKE ALL ON hardware_verification_trust FROM stats_hardware_verifier;
REVOKE ALL ON provider_hardware_profiles FROM stats_hardware_verifier;
REVOKE ALL ON chip_hardware_profiles FROM stats_hardware_verifier;
REVOKE USAGE ON SCHEMA public FROM stats_hardware_verifier;
REVOKE ALL ON FUNCTION hardware_verification_jobs_guard_verifier_update() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_hardware_verification_jobs_guard_verifier_update
    ON hardware_verification_jobs;
DROP FUNCTION IF EXISTS hardware_verification_jobs_guard_verifier_update();
DROP TABLE IF EXISTS hardware_verification_trust;
DROP TABLE IF EXISTS hardware_verification_jobs;
DROP ROLE IF EXISTS stats_hardware_verifier;
