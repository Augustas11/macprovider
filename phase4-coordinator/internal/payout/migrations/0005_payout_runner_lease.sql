-- SPEC-016 §4.8b — singleton runner lease.
-- Zero-row by default; first acquire INSERTs.

CREATE TABLE IF NOT EXISTS payout_runner_lease (
    id                       INTEGER PRIMARY KEY CHECK(id = 1),
    holder_host              TEXT NOT NULL,
    holder_pid               INTEGER NOT NULL,
    holder_started_at_utc    TEXT NOT NULL,
    holder_token             TEXT NOT NULL,
    heartbeat_at_utc         TEXT NOT NULL,
    acquired_at_utc          TEXT NOT NULL,
    takeover_count           INTEGER NOT NULL DEFAULT 0
);
