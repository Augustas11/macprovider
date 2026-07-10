-- Existing deployments already recorded migration 008 before onboarding
-- replay reads included decision_reason. Add the column privilege forward;
-- never rewrite an applied migration.
GRANT SELECT (decision_reason)
ON hardware_verification_jobs
TO provider_onboarding;
