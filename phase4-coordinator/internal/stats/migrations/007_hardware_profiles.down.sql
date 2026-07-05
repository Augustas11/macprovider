-- Operator rollback artifact for network stats hardware enrichment.
-- The embedded migration runner intentionally applies only *.up.sql;
-- this file is validated by tests/runbooks and executed manually by
-- operators only during rollback.

REVOKE ALL ON provider_hardware_profiles FROM stats_rollup;
REVOKE ALL ON chip_hardware_profiles FROM stats_rollup;
REVOKE ALL ON provider_hardware_profiles FROM provider_onboarding;
REVOKE ALL ON FUNCTION provider_hardware_profiles_guard_verification() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_provider_hardware_profiles_guard_verification
    ON provider_hardware_profiles;
DROP FUNCTION IF EXISTS provider_hardware_profiles_guard_verification();
DROP TABLE IF EXISTS chip_hardware_profiles;
DROP TABLE IF EXISTS provider_hardware_profiles;
