-- SPEC-016 §4.6 — per-from_address nonce cursor.
-- Single row per wallet; on cold-start the runner queries both
-- RPCs' getTransactionCount(pending) and stamps
-- max(cursor_in_db, max(rpc_a, rpc_b)). The chain itself is the
-- on-chain source of truth; this row exists so the runner can
-- detect cursor regressions after a restart against a lying RPC.

CREATE TABLE IF NOT EXISTS wallet_nonce_cursor (
    from_address     TEXT PRIMARY KEY,
    next_nonce       INTEGER NOT NULL CHECK(next_nonce >= 0),
    last_synced_at_utc TEXT NOT NULL,
    rpc_a_last_value INTEGER NOT NULL,
    rpc_b_last_value INTEGER NOT NULL
);
