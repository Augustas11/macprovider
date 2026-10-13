-- SPEC-050 v0.1.0 (SPEC-050-R002, R003, R013) — MALIBU stake ledger.
--
-- Append-only lock/unlock events on ledger MALIBU. Amounts are integer units
-- of 1e-8 MALIBU, the scale of provider_rewards_ledger.amount_malibu
-- NUMERIC(24,8). A lock moves withdrawable MALIBU of one provider into a
-- stake; an unlock stops it earning at once and releases it at release_at.
--
-- Only the coordinator writes here, through rewards_writer, which gets SELECT
-- and INSERT and nothing else. stats_reader and stats_rollup get no grant.
-- A trigger refuses UPDATE and DELETE for every role, so the ledger stays
-- append-only even under an admin connection.

CREATE TABLE IF NOT EXISTS malibu_stake_events (
    id               BIGSERIAL PRIMARY KEY,
    account_id       TEXT NOT NULL CHECK (length(account_id) BETWEEN 1 AND 128),
    github_user_id   BIGINT NOT NULL CHECK (github_user_id > 0),
    provider_id      TEXT NOT NULL CHECK (length(provider_id) BETWEEN 1 AND 256),
    event_type       TEXT NOT NULL CHECK (event_type IN ('lock', 'unlock')),
    amount_units     BIGINT NOT NULL CHECK (amount_units > 0),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    release_at       TIMESTAMPTZ NULL,
    idempotency_key  TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 128),
    request_digest   TEXT NOT NULL CHECK (length(request_digest) = 64),
    CONSTRAINT malibu_stake_events_release_shape
        CHECK ((event_type = 'unlock') = (release_at IS NOT NULL)),
    CONSTRAINT malibu_stake_events_idempotency
        UNIQUE (account_id, idempotency_key, provider_id)
);

CREATE INDEX IF NOT EXISTS malibu_stake_events_provider_idx
    ON malibu_stake_events (provider_id, created_at);
CREATE INDEX IF NOT EXISTS malibu_stake_events_account_idx
    ON malibu_stake_events (account_id, created_at);

CREATE OR REPLACE FUNCTION malibu_stake_events_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'malibu_stake_events is append-only';
END;
$$;

DROP TRIGGER IF EXISTS malibu_stake_events_no_update ON malibu_stake_events;
CREATE TRIGGER malibu_stake_events_no_update
    BEFORE UPDATE OR DELETE ON malibu_stake_events
    FOR EACH ROW EXECUTE FUNCTION malibu_stake_events_append_only();

REVOKE ALL ON malibu_stake_events FROM PUBLIC;
GRANT SELECT, INSERT ON malibu_stake_events TO rewards_writer;
GRANT USAGE ON SEQUENCE malibu_stake_events_id_seq TO rewards_writer;
