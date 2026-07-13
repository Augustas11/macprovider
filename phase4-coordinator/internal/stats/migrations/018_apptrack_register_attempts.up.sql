-- FIX-570 A1 (ADV-C2): durable App-track registration attempt marker.
--
-- Reconciliation of a cross-store App-track referral mint proves the PostgreSQL
-- half committed. Before this migration that proof JOINed provider_register_nonces
-- (an operator-prunable replay cache, migration 006, 65s floor) with
-- provider_identities. In the 65s..2min reconcile window the nonce can be pruned
-- while the identity row persists, so ProviderRegistrationPrepared returned
-- prepared=false and reconciliation DESTRUCTIVELY compensated a committed
-- credential + referral redemption.
--
-- provider_register_attempts is written in the SAME transaction as the identity
-- prepare and is NEVER touched by the replay-nonce pruner. It gives
-- reconciliation a durable, attempt-bound commitment marker. Its own pruner has a
-- >= 7 day floor so it can never race the 2-minute reconcile horizon.
--
-- FIX-570 C1a (adv-C1): the commitment IDENTITY is keyed on REPLAY-STABLE SIGNED
-- fields only — (provider_id, nonce, ts_utc). source_ip is UNSIGNED and
-- connection-dependent (NAT/proxy churn between the original attempt and a
-- lost-response replay), so including it in the key made an identical signed
-- replay from a different source IP MISS the marker and be treated as
-- uncommitted — destroying the committed credential. source_ip is retained ONLY
-- as non-authoritative diagnostic metadata (nullable) and never participates in
-- the match.
CREATE TABLE IF NOT EXISTS provider_register_attempts (
    provider_id  TEXT NOT NULL,
    nonce        TEXT NOT NULL,
    ts_utc       TIMESTAMPTZ NOT NULL,
    source_ip    TEXT,
    committed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (provider_id, nonce, ts_utc)
);

CREATE INDEX IF NOT EXISTS idx_provider_register_attempts_committed_at
    ON provider_register_attempts(committed_at);

-- Long-horizon prune for the durable attempt marker. Distinct from
-- prune_provider_register_nonces: the floor here is 7 days so reconciliation
-- (which runs at a 2-minute horizon) can never race a prune.
CREATE OR REPLACE FUNCTION prune_provider_register_attempts(retain_for INTERVAL DEFAULT INTERVAL '30 days')
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    deleted_count BIGINT;
BEGIN
    IF retain_for < INTERVAL '7 days' THEN
        RAISE EXCEPTION 'retain_for must be at least 7 days';
    END IF;

    DELETE FROM provider_register_attempts
     WHERE committed_at < NOW() - retain_for;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

-- Runtime onboarding keeps only SELECT/INSERT; it never prunes or deletes.
GRANT SELECT, INSERT ON provider_register_attempts TO provider_onboarding;

REVOKE ALL ON FUNCTION prune_provider_register_attempts(INTERVAL) FROM PUBLIC;
REVOKE ALL ON FUNCTION prune_provider_register_attempts(INTERVAL) FROM provider_onboarding;
