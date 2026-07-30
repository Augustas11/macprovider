-- SPEC-016 §4.7 step 5 — #165 R4 code MEDIUM closure. The keyset-
-- paginated stale-cancel producer iterates payout_attempts via
-- ORDER BY (updated_at_utc, payout_id, attempt_seq) with strict-
-- tuple cursor advance. Without a matching ordered index, SQLite
-- materializes a TEMP B-TREE per chunk fetch — at chunk 256 and
-- ceiling 20000 that is up to 78 sorts per cycle in the
-- pathological-backlog path.
--
-- Partial index on the exact stale-cancel predicate keeps the
-- index covering and small (only is_cancel_self_transfer=1
-- rows with un-paged + un-abandoned + un-confirmed state are
-- candidates). EXPLAIN QUERY PLAN should now report
-- "USING INDEX idx_pa_stale_cancel_keyset" with no TEMP B-TREE.
CREATE INDEX IF NOT EXISTS idx_pa_stale_cancel_keyset
    ON payout_attempts(updated_at_utc, payout_id, attempt_seq)
    WHERE is_cancel_self_transfer = 1
      AND cancel_reconfirm_stale_paged_at_utc IS NULL
      AND abandoned_at_utc IS NULL
      AND confirmed_at_utc IS NULL;
