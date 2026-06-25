-- SPEC-016 §4.6 — gas reservation column for pending cancel rows.
--
-- Closes codex round-1 [sec:2.1] HIGH: a stolen operator key
-- could burn hot-wallet native gas BEYOND the configured 24h
-- aggregate cap because the cap-check summed only
-- gas_used_native_wei (NULL on pending cancels until confirm).
-- The reservation column lets the cap-check sum COALESCE(used,
-- reserved) so pending broadcasts count toward the budget at
-- estimate-time.
--
-- Reservation is stamped at INSERT time inside the §4.6 BEGIN
-- IMMEDIATE txn; on confirmation MarkConfirmedAtTx populates
-- gas_used_native_wei and the reservation becomes redundant.
-- Abandoned rows drop out of the rolling SUM via the existing
-- WHERE abandoned_at_utc IS NULL filter.

ALTER TABLE payout_attempts ADD COLUMN gas_reserved_native_wei INTEGER NULL;
