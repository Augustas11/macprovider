-- Operator rollback artifact. The embedded runner applies only *.up.sql.
REVOKE ALL ON provider_register_attempts FROM provider_onboarding;
REVOKE ALL ON FUNCTION prune_provider_register_attempts(INTERVAL) FROM PUBLIC;

DROP FUNCTION IF EXISTS prune_provider_register_attempts(INTERVAL);
DROP TABLE IF EXISTS provider_register_attempts;
