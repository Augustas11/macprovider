-- Durable commitment marker for App-track provider registration.
--
-- The replay nonce table is intentionally short-lived and therefore cannot
-- prove that the PostgreSQL half of a cross-store referral mint committed.
-- This table is written in the same transaction as provider identity prepare
-- and survives well beyond the SQLite saga reconciliation horizon.
--
-- The primary key contains signed, replay-stable fields only. source_ip is
-- connection-dependent diagnostic metadata and is never authoritative.
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

-- Keep attempt evidence for at least seven days. This is deliberately much
-- longer than the registration reconciliation horizon.
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

-- The runtime role can record and verify commitments but cannot mutate them or
-- choose the database-owned commitment timestamp used by retention.
REVOKE INSERT ON provider_register_attempts FROM provider_onboarding;
GRANT SELECT ON provider_register_attempts TO provider_onboarding;
GRANT INSERT (provider_id, nonce, ts_utc, source_ip)
    ON provider_register_attempts TO provider_onboarding;

REVOKE ALL ON FUNCTION prune_provider_register_attempts(INTERVAL) FROM PUBLIC;
REVOKE ALL ON FUNCTION prune_provider_register_attempts(INTERVAL) FROM provider_onboarding;
