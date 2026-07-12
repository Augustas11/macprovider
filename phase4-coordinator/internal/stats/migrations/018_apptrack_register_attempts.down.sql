-- Operator rollback artifact for the FIX-570 A1 durable attempt marker.
-- The embedded migration runner intentionally applies only *.up.sql.

REVOKE ALL ON provider_register_attempts FROM provider_onboarding;
REVOKE ALL ON FUNCTION prune_provider_register_attempts(INTERVAL) FROM PUBLIC;

DROP FUNCTION IF EXISTS prune_provider_register_attempts(INTERVAL);
DROP TABLE IF EXISTS provider_register_attempts;
