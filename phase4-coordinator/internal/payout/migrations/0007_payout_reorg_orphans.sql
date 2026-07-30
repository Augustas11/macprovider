-- SPEC-016 §4.7 — reorg-orphan ledger with IMMUTABLE snapshot
-- columns (v0.1.9 — codex round-10 MED-5 closure).
-- §9.5b.1 compensation binds to observed_* values, NOT to current
-- ledger_payout_ready columns.

CREATE TABLE IF NOT EXISTS payout_reorg_orphans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payout_id        INTEGER NOT NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    attempt_seq      INTEGER NOT NULL,
    orphan_tx_hash   TEXT NOT NULL,
    last_seen_block  INTEGER NOT NULL,
    observed_at_utc  TEXT NOT NULL,
    rpc_source       TEXT NOT NULL,
    observed_provider_id           TEXT    NOT NULL,
    observed_provider_credits      INTEGER NOT NULL,
    observed_gross_credits         INTEGER NOT NULL,
    observed_amount_base_units     INTEGER NOT NULL,
    operator_resolution TEXT NULL,
    compensation_settlement_id INTEGER NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    resolved_at_utc  TEXT NULL,
    FOREIGN KEY(payout_id, attempt_seq) REFERENCES payout_attempts(payout_id, attempt_seq) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_pro_unresolved ON payout_reorg_orphans(observed_at_utc) WHERE resolved_at_utc IS NULL;
