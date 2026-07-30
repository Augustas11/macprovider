-- SPEC-016 §4.5 — payout_attempts table + seven partial indexes
-- (five non-UNIQUE + two partial UNIQUE) per SPEC L1408-1463.
--
-- v0.1.16 (codex round-17 MED-1 closure): the column
-- cancel_reconfirm_stale_paged_at_utc is the durable suppression
-- marker for the §4.7 cancel-reorg reconfirm-stale PAGE event.
-- NULL = not-stale or newly-reactivated; non-NULL = stale-paged
-- at the recorded timestamp.

CREATE TABLE IF NOT EXISTS payout_attempts (
    payout_id        INTEGER NOT NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    attempt_seq      INTEGER NOT NULL CHECK(attempt_seq >= 1),
    chain            TEXT NOT NULL CHECK(chain = 'base-mainnet'),
    from_address     TEXT NOT NULL,
    to_address       TEXT NOT NULL,
    amount_base_units INTEGER NOT NULL CHECK(amount_base_units > 0),
    nonce            INTEGER NOT NULL CHECK(nonce >= 0),
    raw_signed_tx    BLOB NULL,
    tx_hash          TEXT NULL,
    broadcast_at_utc TEXT NULL,
    confirmed_at_utc TEXT NULL,
    block_number     INTEGER NULL,
    gas_used_native_wei INTEGER NULL,
    is_cancel_self_transfer INTEGER NOT NULL DEFAULT 0 CHECK(is_cancel_self_transfer IN (0,1)),
    last_error       TEXT NULL,
    abandoned_at_utc TEXT NULL,
    abandoned_reason TEXT NULL,
    cancel_reconfirm_stale_paged_at_utc TEXT NULL,
    updated_at_utc   TEXT NOT NULL,
    PRIMARY KEY(payout_id, attempt_seq)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_from_nonce_active
    ON payout_attempts(from_address, nonce)
 WHERE abandoned_at_utc IS NULL;

CREATE INDEX IF NOT EXISTS idx_pa_unconfirmed
    ON payout_attempts(payout_id)
 WHERE confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL;

CREATE INDEX IF NOT EXISTS idx_pa_confirmed_recent
    ON payout_attempts(confirmed_at_utc)
 WHERE confirmed_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;

CREATE INDEX IF NOT EXISTS idx_pa_broadcast_recent
    ON payout_attempts(broadcast_at_utc)
 WHERE broadcast_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;

CREATE INDEX IF NOT EXISTS idx_pa_cancel_recent
    ON payout_attempts(broadcast_at_utc)
 WHERE is_cancel_self_transfer = 1 AND broadcast_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_one_active_per_payout
    ON payout_attempts(payout_id)
 WHERE confirmed_at_utc IS NOT NULL AND abandoned_at_utc IS NULL AND is_cancel_self_transfer = 0;

CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_one_live_non_cancel_per_payout
    ON payout_attempts(payout_id)
 WHERE abandoned_at_utc IS NULL AND is_cancel_self_transfer = 0;
