package payout

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/rs/zerolog"
)

// SPEC-016 §4.7 — reorg detection (record-only).
//
// The §4.7 reorg path is split: the cancel-vs-provider carve-out
// is normative (v0.1.14 / v0.1.15 / v0.1.16 / v0.1.17 / v0.1.20).
// Step 2 implements:
//   - Reorg-poll cadence (M1 — v0.1.20 round-20 closure) over
//     confirmed_at_utc >= now - reorg_poll_window.
//   - Two-RPC discipline for the re-poll (both must return
//     "not found" to be a reorg; one RPC error is NOT a reorg —
//     emit payout_reorg_poll_rpc_error WARN and the row stays
//     confirmed).
//   - Cancel-self-transfer reorg recovery (LIVE-AGAIN UPDATE
//     within BEGIN IMMEDIATE; clear cancel_reconfirm_stale
//     marker per v0.1.16/17).
//   - Provider-payout reorg observation (emit payout_reorg_revert
//     PAGE; do NOT modify ledger_payout_ready; the
//     payout_reorg_orphans INSERT lands in Step 3 via the
//     /admin/payout/record-orphan endpoint).
//
// NOTE on [arch:1.1] SPEC drift (v0.1.21 §4.7 → unimplementable
// SQL): the SPEC names `payout_attempts.id` and
// `payout_external_id`, neither of which exist in §4.5. This
// IMPL queries (payout_id, attempt_seq, tx_hash) and joins
// through ledger_payout_ready when the orphan-recording endpoint
// (Step 3) needs the external id. Architect r2 validated this
// substitution.

// ReorgPoller runs the §4.7 re-poll cycle.
type ReorgPoller struct {
	DB          *sql.DB
	RPCs        TwoRPCs
	HotWallet   string
	PollWindow  time.Duration
	RunInterval time.Duration
	Logger      zerolog.Logger
	NowFn       func() time.Time
}

// Run executes one re-poll cycle: for every confirmed, non-
// abandoned, non-cancel row inside the [now - pollWindow, now]
// confirmed_at_utc window, re-poll receipt status on BOTH RPCs.
//
// Returns the number of rows polled. Errors from individual rows
// are logged but do NOT abort the cycle (cycle is best-effort
// per SPEC §4.7).
func (p *ReorgPoller) Run(ctx context.Context) (int, error) {
	if p.NowFn == nil {
		p.NowFn = func() time.Time { return time.Now().UTC() }
	}
	cutoff := p.NowFn().Add(-p.PollWindow).UTC().Format(time.RFC3339Nano)

	type pollRow struct {
		PayoutID             int64
		AttemptSeq           int
		TxHash               sql.NullString
		IsCancelSelfTransfer int
		BlockNumber          sql.NullInt64
	}

	rows, err := p.DB.QueryContext(ctx, `
SELECT payout_id, attempt_seq, tx_hash, is_cancel_self_transfer, block_number
  FROM payout_attempts
 WHERE confirmed_at_utc IS NOT NULL
   AND abandoned_at_utc IS NULL
   AND confirmed_at_utc >= ?
 ORDER BY confirmed_at_utc DESC`, cutoff)
	if err != nil {
		return 0, fmt.Errorf("ReorgPoller.Run: SELECT: %w", err)
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		var r pollRow
		if err := rows.Scan(&r.PayoutID, &r.AttemptSeq, &r.TxHash, &r.IsCancelSelfTransfer, &r.BlockNumber); err != nil {
			p.Logger.Warn().Err(err).Msg("reorg poll row scan failed")
			continue
		}
		count++
		if !r.TxHash.Valid {
			continue
		}
		txHash := r.TxHash.String

		// Re-poll on BOTH RPCs.
		recA, errA := p.RPCs.Primary.TransactionReceipt(ctx, txHash)
		recB, errB := p.RPCs.Secondary.TransactionReceipt(ctx, txHash)

		// RPC errors: NOT a reorg.
		if errA != nil || errB != nil {
			rpcSource := p.RPCs.Primary.Label()
			errClass := classifyRPCErr(errA)
			if errA == nil {
				rpcSource = p.RPCs.Secondary.Label()
				errClass = classifyRPCErr(errB)
			}
			p.Logger.Warn().
				Str("event", "payout_reorg_poll_rpc_error").
				Str("severity", "WARN").
				Int64("payout_id", r.PayoutID).
				Int("attempt_seq", r.AttemptSeq).
				Str("tx_hash", txHash).
				Str("rpc_source", rpcSource).
				Str("error_class", errClass).
				Str("ts_utc", p.NowFn().UTC().Format(time.RFC3339Nano)).
				Send()
			continue
		}

		// Both receipts present → no reorg (sanity check that the
		// receipts agree; disagreement is its own PAGE per §4.4).
		if recA != nil && recB != nil {
			continue
		}

		// At least one receipt is "not found". SPEC §4.7: BOTH
		// must return "not found" to count as a reorg (one nil
		// could be a transient pruning).
		if recA != nil || recB != nil {
			// One RPC reports it; the other doesn't. Could be
			// transient — log as a softer signal.
			p.Logger.Warn().
				Int64("payout_id", r.PayoutID).
				Int("attempt_seq", r.AttemptSeq).
				Str("tx_hash", txHash).
				Bool("primary_found", recA != nil).
				Bool("secondary_found", recB != nil).
				Msg("reorg poll: one RPC reports not-found; treating as transient")
			continue
		}

		// BOTH RPCs report "not found" → reorg.
		if r.IsCancelSelfTransfer == 1 {
			if err := p.handleCancelReorg(ctx, r.PayoutID, r.AttemptSeq, txHash); err != nil {
				p.Logger.Error().Err(err).Msg("cancel reorg handling failed")
			}
			continue
		}
		// Provider-payout reorg.
		p.handleProviderReorg(r.PayoutID, r.AttemptSeq, txHash, r.BlockNumber)
	}
	if err := rows.Err(); err != nil {
		return count, err
	}
	return count, nil
}

// handleProviderReorg emits the §4.7 PAGE event for a
// provider-payout reorg. The payout_reorg_orphans INSERT is
// Step 3's /admin/payout/record-orphan responsibility — the
// runner only records the observation via the log surface.
func (p *ReorgPoller) handleProviderReorg(payoutID int64, attemptSeq int, txHash string, lastBlock sql.NullInt64) {
	lastBlockI := int64(0)
	if lastBlock.Valid {
		lastBlockI = lastBlock.Int64
	}
	p.Logger.Error().
		Str("event", "payout_reorg_revert").
		Str("severity", "PAGE").
		Int64("payout_id", payoutID).
		Int("attempt_seq", attemptSeq).
		Str("tx_hash", txHash).
		Int64("last_seen_block", lastBlockI).
		Str("rpc_source", "both").
		Int("is_cancel_self_transfer", 0).
		Str("observed_via", "reorg_poll_cadence").
		Str("ts_utc", p.NowFn().UTC().Format(time.RFC3339Nano)).
		Send()
}

// handleCancelReorg implements the v0.1.14 cancel-side
// LIVE-AGAIN UPDATE: clear confirmed_at_utc / block_number /
// gas_used_native_wei / cancel_reconfirm_stale_paged_at_utc on
// the cancel row so the §4.3 cancel-handling pre-check picks it
// up again on the next cycle.
func (p *ReorgPoller) handleCancelReorg(ctx context.Context, payoutID int64, attemptSeq int, txHash string) error {
	conn, err := p.DB.Conn(ctx)
	if err != nil {
		return fmt.Errorf("handleCancelReorg: Conn: %w", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return fmt.Errorf("handleCancelReorg: BEGIN: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	now := p.NowFn().UTC().Format(time.RFC3339Nano)
	res, err := conn.ExecContext(ctx, `
UPDATE payout_attempts
   SET confirmed_at_utc                    = NULL,
       block_number                        = NULL,
       gas_used_native_wei                 = NULL,
       cancel_reconfirm_stale_paged_at_utc = NULL,
       last_error                          = ?,
       updated_at_utc                      = ?
 WHERE payout_id = ?
   AND attempt_seq = ?
   AND is_cancel_self_transfer = 1
   AND abandoned_at_utc IS NULL
   AND confirmed_at_utc IS NOT NULL`,
		"cancel_self_transfer_reorged:"+txHash, now, payoutID, attemptSeq,
	)
	if err != nil {
		return fmt.Errorf("handleCancelReorg: UPDATE: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return fmt.Errorf("handleCancelReorg: COMMIT: %w", err)
	}
	committed = true

	if n == 0 {
		// Operator abandoned in the gap; do NOT proceed.
		return nil
	}
	p.Logger.Error().
		Str("event", "payout_reorg_revert").
		Str("severity", "PAGE").
		Int64("payout_id", payoutID).
		Int("attempt_seq", attemptSeq).
		Str("tx_hash", txHash).
		Int("is_cancel_self_transfer", 1).
		Str("observed_via", "reorg_poll_cadence").
		Str("ts_utc", now).
		Send()
	return nil
}

func classifyRPCErr(err error) string {
	if err == nil {
		return ""
	}
	var rpcErr *RPCError
	if errors.As(err, &rpcErr) {
		return fmt.Sprintf("rpc_%d", rpcErr.Code)
	}
	return "network"
}
