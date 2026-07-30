-- SPEC-016 §4.8c — durable delivery record for the §7.1
-- payout_cancel_self_transfer_reconfirm_stale PAGE event.

CREATE TABLE IF NOT EXISTS cancel_reconfirm_stale_outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payout_id                 INTEGER NOT NULL,
    attempt_seq               INTEGER NOT NULL,
    stale_started_at_utc      TEXT NOT NULL,
    nonce                     INTEGER NOT NULL,
    tx_hash                   TEXT NOT NULL,
    last_seen_block           INTEGER NOT NULL,
    reorg_reactivated_at_utc  TEXT NOT NULL,
    emitted_to_log            INTEGER NOT NULL DEFAULT 0 CHECK(emitted_to_log IN (0,1)),
    FOREIGN KEY(payout_id, attempt_seq) REFERENCES payout_attempts(payout_id, attempt_seq) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_crso_unemitted
    ON cancel_reconfirm_stale_outbox(id) WHERE emitted_to_log = 0;
CREATE UNIQUE INDEX IF NOT EXISTS idx_crso_one_per_stale_period
    ON cancel_reconfirm_stale_outbox(payout_id, attempt_seq, stale_started_at_utc);
