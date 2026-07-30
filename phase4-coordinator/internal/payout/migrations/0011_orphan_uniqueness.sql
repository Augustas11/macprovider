-- SPEC-016 §4.7 — codex Step 3 r1 [code:1.1] MEDIUM closure.
-- The Step 1 schema declared no uniqueness for an orphan
-- observation tuple, allowing duplicate /admin/payout/record-orphan
-- submissions to create parallel rows. The endpoint's documented
-- response table promises 409 on duplicates; this partial UNIQUE
-- INDEX makes the DB layer enforce that promise.
--
-- Scoped to unresolved rows: once an orphan is resolved
-- (resolved_at_utc IS NOT NULL), a subsequent fresh observation
-- for the same tuple is legitimate (the chain re-orphaned the
-- same tx — though in practice this is rare).
CREATE UNIQUE INDEX IF NOT EXISTS idx_pro_unique_active
    ON payout_reorg_orphans(payout_id, attempt_seq, orphan_tx_hash)
 WHERE resolved_at_utc IS NULL;
