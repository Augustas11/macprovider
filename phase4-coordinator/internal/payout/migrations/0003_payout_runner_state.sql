-- SPEC-016 §4.8 — single-row runner state + bootstrap triggers.

CREATE TABLE IF NOT EXISTS payout_runner_state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    last_run_started_at_utc  TEXT NULL,
    last_run_finished_at_utc TEXT NULL,
    last_run_paid            INTEGER NOT NULL DEFAULT 0,
    last_run_capped          INTEGER NOT NULL DEFAULT 0,
    last_run_failed          INTEGER NOT NULL DEFAULT 0,
    last_run_skipped_no_addr INTEGER NOT NULL DEFAULT 0,
    last_run_cancel_gas_native_wei INTEGER NOT NULL DEFAULT 0,
    last_run_error_text      TEXT NULL,
    payout_bootstrap_complete INTEGER NOT NULL DEFAULT 0 CHECK(payout_bootstrap_complete IN (0,1)),
    bootstrap_completed_at_utc TEXT NULL,
    updated_at_utc           TEXT NOT NULL
);

-- One-way flip: 0 → 1 permitted; 1 → 0 rejected by trigger.
CREATE TRIGGER IF NOT EXISTS trg_prs_bootstrap_one_way
BEFORE UPDATE OF payout_bootstrap_complete ON payout_runner_state
WHEN OLD.payout_bootstrap_complete = 1 AND NEW.payout_bootstrap_complete = 0
BEGIN
    SELECT RAISE(ABORT, 'payout_bootstrap_complete is one-way');
END;

-- Auto-flip on first confirmation.
CREATE TRIGGER IF NOT EXISTS trg_pa_bootstrap_flip
AFTER UPDATE OF confirmed_at_utc ON payout_attempts
WHEN NEW.confirmed_at_utc IS NOT NULL AND OLD.confirmed_at_utc IS NULL
BEGIN
    UPDATE payout_runner_state
       SET payout_bootstrap_complete = 1,
           bootstrap_completed_at_utc = NEW.confirmed_at_utc,
           updated_at_utc = NEW.confirmed_at_utc
     WHERE id = 1 AND payout_bootstrap_complete = 0;
END;

-- Sibling trigger for INSERTs that land confirmed_at_utc non-NULL
-- directly (test harnesses or future helpers).
CREATE TRIGGER IF NOT EXISTS trg_pa_bootstrap_flip_insert
AFTER INSERT ON payout_attempts
WHEN NEW.confirmed_at_utc IS NOT NULL
BEGIN
    UPDATE payout_runner_state
       SET payout_bootstrap_complete = 1,
           bootstrap_completed_at_utc = NEW.confirmed_at_utc,
           updated_at_utc = NEW.confirmed_at_utc
     WHERE id = 1 AND payout_bootstrap_complete = 0;
END;
