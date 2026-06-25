-- SPEC-016 §4.9 — hot-wallet funding records.

CREATE TABLE IF NOT EXISTS payout_hot_wallet_funding (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_address       TEXT NOT NULL,
    to_address         TEXT NOT NULL,
    amount_base_units  INTEGER NOT NULL CHECK(amount_base_units > 0),
    tx_hash            TEXT NOT NULL,
    block_number       INTEGER NOT NULL,
    observed_at_utc    TEXT NOT NULL,
    source             TEXT NOT NULL CHECK(source IN ('manual','rpc-confirmed')),
    operator_note      TEXT NULL,
    UNIQUE(tx_hash)
);
CREATE INDEX IF NOT EXISTS idx_phwf_to ON payout_hot_wallet_funding(to_address);
