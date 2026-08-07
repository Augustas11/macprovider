-- Emission tick uses SELECT … FOR UPDATE / UPDATE on provider_rewards_ledger
-- (cap-hold replay). Migration 012 only granted SELECT, INSERT to rewards_writer,
-- which surfaces as permission denied (42501) once those paths run.
GRANT SELECT, INSERT, UPDATE ON provider_rewards_ledger TO rewards_writer;
GRANT USAGE, SELECT ON SEQUENCE provider_rewards_ledger_id_seq TO rewards_writer;
