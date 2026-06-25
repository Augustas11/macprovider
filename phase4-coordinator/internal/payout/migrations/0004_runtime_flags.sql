-- SPEC-016 §4.8a — runtime_flags + outbox + sentinel.
-- Bootstrap-seed semantics handled in Go (see internal/payout/bootstrap.go);
-- the SQL only declares schema.

CREATE TABLE IF NOT EXISTS runtime_flags (
    name              TEXT PRIMARY KEY,
    value             INTEGER NOT NULL CHECK(value IN (0,1)),
    updated_at_utc    TEXT NOT NULL,
    updated_by_actor  TEXT NOT NULL,
    updated_reason    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS runtime_flag_audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    flag_name         TEXT NOT NULL,
    old_value         INTEGER NOT NULL CHECK(old_value IN (0,1)),
    new_value         INTEGER NOT NULL CHECK(new_value IN (0,1)),
    actor             TEXT NOT NULL,
    reason            TEXT NOT NULL,
    occurred_at_utc   TEXT NOT NULL,
    emitted_to_log    INTEGER NOT NULL DEFAULT 0 CHECK(emitted_to_log IN (0,1))
);
CREATE INDEX IF NOT EXISTS idx_rfa_unemitted
    ON runtime_flag_audit(id) WHERE emitted_to_log = 0;

CREATE TABLE IF NOT EXISTS runtime_flags_bootstrapped (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    bootstrapped_at_utc TEXT NOT NULL
);
