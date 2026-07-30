-- SPEC-016 §3.1 + §3.2.
-- Per §3.1 the table MUST live in the same SQLite database as
-- ledger_payout_ready; the migration runner asserts this via
-- PRAGMA database_list at startup.

CREATE TABLE IF NOT EXISTS provider_payout_addresses (
    provider_id      TEXT NOT NULL,
    chain            TEXT NOT NULL CHECK(chain = 'base-mainnet'),
    address          TEXT NOT NULL,
    payout_allowed   INTEGER NOT NULL DEFAULT 1 CHECK(payout_allowed IN (0,1)),
    pending_until_utc TEXT NULL,
    rotated_from     TEXT NULL,
    registered_at_utc TEXT NOT NULL,
    registered_against_hot_wallet TEXT NOT NULL,
    UNIQUE(provider_id, chain)
);
CREATE INDEX IF NOT EXISTS idx_ppa_provider ON provider_payout_addresses(provider_id);

-- §3.2 anti-replay table. PK scoped to canonical_address (NOT
-- provider_id) — see §3.2 step 5 paragraph on cross-provider
-- replay defense-in-depth.
CREATE TABLE IF NOT EXISTS provider_payout_address_nonces (
    canonical_address TEXT NOT NULL,
    nonce             TEXT NOT NULL,
    seen_at_utc       TEXT NOT NULL,
    PRIMARY KEY(canonical_address, nonce)
);
CREATE INDEX IF NOT EXISTS idx_ppan_seen ON provider_payout_address_nonces(seen_at_utc);
