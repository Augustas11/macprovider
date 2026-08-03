-- SPEC-016 §7.4 — weekly reconciliation queries.
--
-- This file is the canonical checked-in artifact required by the
-- SPEC. The Go side embeds it via go:embed and exposes named
-- queries via ParseLabeledQueries. Operators MAY also pipe this
-- file directly through `sqlite3` against the live DB.
--
-- The :from_utc / :to_utc / :now_minus_30d / :hot_wallet bind
-- params are caller-supplied. Any row returned by ANY query is a
-- reconciliation failure or security incident — see SPEC §7.4 for
-- triage guidance. Query (F) is the canonical money-conservation
-- check; non-zero result is a SEV-1 incident.

-- ============================================================
-- Unlabeled regression #1 — per-provider in-DB vs on-chain delta.
-- SPEC §7.4 lines 3853-3874. delta != 0 means either the runner
-- broadcast an amount that doesn't match provider_credits OR a
-- DB hand-edit. Caller binds :from_utc + :to_utc.
-- ============================================================
SELECT
  lpr.provider_id,
  SUM(lpr.provider_credits) AS in_db_credits,
  SUM(pa.amount_base_units) AS on_chain_usdc_base_units,
  SUM(lpr.provider_credits) - SUM(pa.amount_base_units) AS delta
FROM ledger_payout_ready lpr
INNER JOIN payout_attempts pa ON pa.payout_id = lpr.id
WHERE lpr.status = 'consumed'
  AND lpr.payout_currency = 'USDC-BASE'
  AND pa.confirmed_at_utc IS NOT NULL
  AND pa.abandoned_at_utc IS NULL
  AND pa.is_cancel_self_transfer = 0
  AND pa.confirmed_at_utc >= :from_utc
  AND pa.confirmed_at_utc <  :to_utc
GROUP BY lpr.provider_id
HAVING delta != 0;

-- ============================================================
-- Unlabeled regression #2 — NULL payout_currency detector.
-- SPEC §7.4 lines 3879-3882. A consumed row with NULL
-- payout_currency is an IMPL bug (ClaimPayoutReady was called
-- without the canonical string).
-- ============================================================
SELECT id, provider_id, gross_credits, payout_external_id
  FROM ledger_payout_ready
 WHERE status = 'consumed'
   AND payout_currency IS NULL;

-- ============================================================
-- Unlabeled regression #3 — chain-balance reconciliation.
-- SPEC §7.4 lines 3900-3911. expected_balance = total_funded -
-- total_paid_out. Cancel self-transfers (is_cancel_self_transfer=1)
-- move 1 base unit hot→hot (net-zero on-chain), so they MUST be
-- excluded from outflow. Caller binds :hot_wallet and compares
-- the result against on-chain balanceOf(hot_wallet).
-- ============================================================
SELECT
  (SELECT COALESCE(SUM(amount_base_units), 0)
     FROM payout_hot_wallet_funding
    WHERE to_address = :hot_wallet)
  -
  (SELECT COALESCE(SUM(amount_base_units), 0)
     FROM payout_attempts
    WHERE confirmed_at_utc IS NOT NULL
      AND abandoned_at_utc IS NULL
      AND is_cancel_self_transfer = 0
      AND from_address = :hot_wallet);

-- ============================================================
-- (A) Orphans unresolved >30d.
-- SPEC §7.4 lines 3941-3948. Signal of compensation neglect /
-- favoritism. Operator must either resolve with a
-- compensation_settlement_id or document operator_resolution as
-- 'no compensation'.
-- ============================================================
-- @label: A
SELECT id, payout_id, attempt_seq, orphan_tx_hash, observed_at_utc
  FROM payout_reorg_orphans
 WHERE resolved_at_utc IS NULL
   AND observed_at_utc < :now_minus_30d;

-- ============================================================
-- (B) Compensation forgery detection.
-- SPEC §7.4 lines 3950-3957. Any orphan whose
-- compensation_settlement_id references a row that no longer
-- exists. Hand-edit / silent delete signal — SECURITY incident.
-- ============================================================
-- @label: B
SELECT pro.id, pro.payout_id, pro.attempt_seq, pro.compensation_settlement_id
  FROM payout_reorg_orphans pro
 WHERE pro.compensation_settlement_id IS NOT NULL
   AND pro.compensation_settlement_id NOT IN
       (SELECT id FROM ledger_payout_ready);

-- ============================================================
-- (C) Reorg-compensation orphan-mismatch.
-- SPEC §7.4 lines 3959-3968. ledger_payout_ready rows whose
-- idempotency_key matches reorg_compensation:* but have no
-- corresponding orphan row linking back. Fake-compensation
-- signal — SECURITY incident.
-- ============================================================
-- @label: C
SELECT lpr.id, lpr.provider_id, lpr.idempotency_key, lpr.gross_credits
  FROM ledger_payout_ready lpr
 WHERE lpr.idempotency_key LIKE 'reorg_compensation:%'
   AND lpr.id NOT IN
       (SELECT compensation_settlement_id FROM payout_reorg_orphans
         WHERE compensation_settlement_id IS NOT NULL);

-- ============================================================
-- (D) Cancel self-transfer observability roll-up.
-- SPEC §7.4 lines 3991-4001. v0.1.14 codex round-15 MEDIUM-1
-- closure. Confirmed cancel self-transfers do NOT consume
-- ledger_payout_ready and are intentionally excluded from outflow
-- sums above; this query gives operators ground-truth audit of
-- every gas-burning cancel event. RESULT MUST NOT be added to
-- provider outflow sums (queries (A) and (B)/(C)).
-- ============================================================
-- @label: D
SELECT payout_id, attempt_seq, nonce, tx_hash,
       confirmed_at_utc, block_number,
       gas_used_native_wei
  FROM payout_attempts
 WHERE is_cancel_self_transfer = 1
   AND confirmed_at_utc >= :from_utc
   AND confirmed_at_utc <  :to_utc
 ORDER BY confirmed_at_utc ASC;

-- ============================================================
-- (E) Hot-wallet self-funding detection.
-- SPEC §7.4 lines 4012-4026. v0.1.20 round-20 C2 closure. The
-- hot wallet cannot legally fund itself; any row where source
-- equals destination is either operator-key compromise or
-- hand-edit. §4.9 rejects from_address == to_address at insert;
-- query (E) catches DB hand-edits.
-- ============================================================
-- @label: E
SELECT id, from_address, to_address, amount_base_units,
       tx_hash, block_number, observed_at_utc, source
  FROM payout_hot_wallet_funding
 WHERE lower(from_address) = lower(to_address);

-- ============================================================
-- (F) Money-conservation aggregate invariant.
-- SPEC §7.4 lines 4028-4051. v0.1.20 round-20 M5 closure. Sum of
-- consumed ledger credits MUST equal sum of confirmed
-- non-abandoned non-cancel on-chain transfers. ANY non-zero
-- conservation_delta is a SEV-1 incident; operator MUST halt the
-- runner via payout.enabled=false until resolved.
-- ============================================================
-- @label: F
SELECT
  (SELECT COALESCE(SUM(provider_credits), 0)
     FROM ledger_payout_ready
    WHERE status = 'consumed'
      AND payout_currency = 'USDC-BASE')
  -
  (SELECT COALESCE(SUM(amount_base_units), 0)
     FROM payout_attempts pa
     INNER JOIN ledger_payout_ready lpr
        ON lpr.id = pa.payout_id
    WHERE lpr.status = 'consumed'
      AND lpr.payout_currency = 'USDC-BASE'
      AND pa.confirmed_at_utc IS NOT NULL
      AND pa.abandoned_at_utc IS NULL
      AND pa.is_cancel_self_transfer = 0)
  AS conservation_delta;
