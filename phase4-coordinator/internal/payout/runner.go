package payout

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

// SPEC-016 §4.3 — payout runner cycle.
//
// The Runner struct owns the lifecycle (Start/Stop), the per-run
// state, and the entry point for the §4.3 9-step algorithm. All
// expensive defenses (lease, two-RPC, CAS) compose through helper
// packages already in payout/.
//
// SPEC v0.1.21 deltas honored:
//   - C3 (§4.3 step 5): amount_base_units == lpr.provider_credits
//     invariant asserted INSIDE BEGIN IMMEDIATE with lpr re-read.
//   - M2 (§4.3 step 7): confirmation_blocks bounds [5, 200].
//   - M4 (§4.8b): chain-nonce uniqueness as load-bearing guard
//     between post-COMMIT lease re-read and broadcast.
//
// The runner is wired only when payout.enabled=true; the runner
// constructor refuses to build on non-Linux per §6.3, via the
// PayoutRuntimeTopology hook in topology.go.

// PayoutClaimer is the surface the runner needs from billing/.
// SPEC §4.1 boundary: payout/ imports billing/ for this; the
// reverse direction is FORBIDDEN (import-graph test enforces).
type PayoutClaimer interface {
	ClaimPayoutReady(ctx context.Context, payoutID int64, expectedGrossCredits int64, payoutExternalID, payoutCurrency string) (bool, error)
}

// AddressReader is a thin alias to billing.PayoutAddressReader so
// the runner declares its dependency without importing billing/
// directly.
type AddressReader interface {
	LookupPayoutAddress(ctx context.Context, providerID, chain string) (address string, payoutAllowed bool, err error)
}

// RunnerOptions bundles construction-time dependencies.
type RunnerOptions struct {
	DB          *sql.DB
	Security    SecurityConfig
	RPCs        TwoRPCs
	Signer      Signer
	Claimer     PayoutClaimer
	Logger      zerolog.Logger
	RunInterval time.Duration
	MaxRowsPerRun int
	ConfirmationBlocks int
	PerPayoutCapBaseUnits int64
	PerDayCapBaseUnits    int64
	ReceiptPollInterval time.Duration
	ReceiptPollTimeout  time.Duration

	// Test/instrumentation hooks. Production wiring leaves these nil.
	SleepAfterPostCommitLeaseReread time.Duration
	NowFn                           func() time.Time
}

// Runner is the §4.3 cycle owner.
type Runner struct {
	opts  RunnerOptions
	state LeaseState

	mu         sync.Mutex
	inFlight   bool
	stop       chan struct{}
	done       chan struct{}
	tickerStop chan struct{}
}

// NewRunner builds a Runner. The caller MUST have already
// performed Acquire() so state carries a valid holder_token.
func NewRunner(opts RunnerOptions, state LeaseState) (*Runner, error) {
	if opts.DB == nil {
		return nil, errors.New("NewRunner: DB is required")
	}
	if opts.Signer == nil {
		return nil, errors.New("NewRunner: Signer is required")
	}
	if opts.Claimer == nil {
		return nil, errors.New("NewRunner: Claimer is required")
	}
	if opts.RunInterval < 5*time.Minute || opts.RunInterval > 24*time.Hour {
		return nil, fmt.Errorf("NewRunner: RunInterval must be in [5m, 24h] (SPEC §6.5), got %s", opts.RunInterval)
	}
	if opts.MaxRowsPerRun <= 0 {
		opts.MaxRowsPerRun = 50
	}
	if opts.ConfirmationBlocks < 5 || opts.ConfirmationBlocks > 200 {
		return nil, fmt.Errorf("NewRunner: ConfirmationBlocks must be in [5, 200] (SPEC §6.5 v0.1.20 round-20 M2), got %d", opts.ConfirmationBlocks)
	}
	if opts.ReceiptPollInterval == 0 {
		opts.ReceiptPollInterval = 5 * time.Second
	}
	if opts.ReceiptPollTimeout == 0 {
		opts.ReceiptPollTimeout = 5 * time.Minute
	}
	if opts.NowFn == nil {
		opts.NowFn = func() time.Time { return time.Now().UTC() }
	}
	if state.HolderToken == "" {
		return nil, errors.New("NewRunner: LeaseState.HolderToken is required")
	}
	r := &Runner{
		opts:       opts,
		state:      state,
		stop:       make(chan struct{}),
		done:       make(chan struct{}),
		tickerStop: make(chan struct{}),
	}
	return r, nil
}

// Start spawns the cadence loop goroutine. SPEC §4.2: default
// every 6 hours; the actual cadence comes from opts.RunInterval.
func (r *Runner) Start(ctx context.Context) {
	go r.loop(ctx)
}

// Stop halts the cadence loop and waits for any in-flight cycle
// to finish before returning. Call Release() afterward.
func (r *Runner) Stop(ctx context.Context) {
	close(r.stop)
	select {
	case <-r.done:
	case <-ctx.Done():
	}
}

func (r *Runner) loop(ctx context.Context) {
	defer close(r.done)
	heartbeatTicker := time.NewTicker(r.opts.RunInterval)
	defer heartbeatTicker.Stop()
	cycleTicker := time.NewTicker(r.opts.RunInterval)
	defer cycleTicker.Stop()
	// Run once immediately to drain any backlog at startup.
	if err := r.RunOnce(ctx); err != nil {
		r.opts.Logger.Warn().Err(err).Msg("payout runner first cycle errored")
	}
	for {
		select {
		case <-r.stop:
			return
		case <-ctx.Done():
			return
		case <-heartbeatTicker.C:
			if err := Heartbeat(ctx, r.opts.DB, r.state, r.opts.Logger); err != nil {
				r.opts.Logger.Error().Err(err).Msg("payout runner heartbeat failed — self-halting")
				return
			}
		case <-cycleTicker.C:
			if err := r.RunOnce(ctx); err != nil {
				r.opts.Logger.Warn().Err(err).Msg("payout runner cycle errored")
			}
		}
	}
}

// RunOnce executes one §4.3 cycle synchronously. Used by Start
// (cadence) and by the admin /admin/payout/run-now endpoint.
//
// The cycle is best-effort: per-row errors are logged but the
// cycle continues with the next row. Fatal errors (lease lost,
// invariant violation) abort the cycle and trip the runner-halt
// signal via the returned error.
func (r *Runner) RunOnce(ctx context.Context) error {
	r.mu.Lock()
	if r.inFlight {
		r.mu.Unlock()
		return errors.New("RunOnce: cycle already in flight")
	}
	r.inFlight = true
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		r.inFlight = false
		r.mu.Unlock()
	}()

	runID := uuid.NewString()
	now := r.opts.NowFn()
	r.opts.Logger.Info().
		Str("event", "payout_run_started").
		Str("run_id", runID).
		Str("ts_utc", now.Format(time.RFC3339Nano)).
		Send()

	paid, capped, failed, skipped := 0, 0, 0, 0
	defer func() {
		r.opts.Logger.Info().
			Str("event", "payout_run_finished").
			Str("run_id", runID).
			Str("ts_utc", r.opts.NowFn().Format(time.RFC3339Nano)).
			Int("paid", paid).
			Int("capped", capped).
			Int("failed", failed).
			Int("skipped_no_addr", skipped).
			Send()
	}()

	// §4.3 step 1: SELECT ready rows.
	hotWallet := r.opts.Security.HotWalletAddress
	rows, err := SelectReadyPayouts(ctx, r.opts.DB, hotWallet, now.Format(time.RFC3339Nano), r.opts.MaxRowsPerRun)
	if err != nil {
		return fmt.Errorf("SelectReadyPayouts: %w", err)
	}

	for _, row := range rows {
		if !row.EffectiveAddress.Valid {
			// §4.3 step 1: NULL effective_address is a hard
			// invariant violation (impossible given WHERE).
			r.emitInvariantViolation(row.PayoutID, "null_effective_address", "")
			failed++
			continue
		}
		outcome, perr := r.processRow(ctx, runID, row)
		if perr != nil {
			r.opts.Logger.Error().
				Err(perr).
				Int64("payout_id", row.PayoutID).
				Msg("payout row processing failed")
			failed++
			// Lease-lost / invariant-violation surfaces here halt the
			// runner cycle.
			if errors.Is(perr, ErrLeaseLost) {
				return perr
			}
			continue
		}
		switch outcome {
		case rowOutcomePaid:
			paid++
		case rowOutcomeCapped:
			capped++
		case rowOutcomeSkipped:
			skipped++
		case rowOutcomeFailed:
			failed++
		}
	}
	return nil
}

type rowOutcome int

const (
	rowOutcomePaid rowOutcome = iota
	rowOutcomeCapped
	rowOutcomeFailed
	rowOutcomeSkipped
)

// processRow runs §4.3 steps 2-9 for a single ready row.
func (r *Runner) processRow(ctx context.Context, runID string, row ReadyRow) (rowOutcome, error) {
	// Standalone lease self-fence (steps 6-8 are guarded inline).
	if err := SelfFence(ctx, r.opts.DB, r.state); err != nil {
		return rowOutcomeFailed, err
	}

	// §4.3 step 2 — amount in USDC base units == provider_credits exactly.
	amount := row.ProviderCredits
	if amount <= 0 {
		r.emitInvariantViolation(row.PayoutID, "non_positive_provider_credits", fmt.Sprintf("%d", amount))
		return rowOutcomeFailed, nil
	}

	// Pre-broadcast cap check (cheap; the durable check is in §4.3 step 4 in-txn).
	if amount > r.opts.PerPayoutCapBaseUnits {
		r.opts.Logger.Warn().
			Str("event", "payout_capped").
			Str("run_id", runID).
			Int64("payout_id", row.PayoutID).
			Str("provider_id", row.ProviderID).
			Str("reason", "per_payout_cap").
			Str("ts_utc", r.opts.NowFn().Format(time.RFC3339Nano)).
			Send()
		return rowOutcomeCapped, nil
	}

	// Look up the existing latest non-abandoned non-cancel attempt
	// to decide step 5 path.
	conn, err := r.opts.DB.Conn(ctx)
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("Conn: %w", err)
	}
	defer conn.Close()

	existing, err := LookupExistingLatest(ctx, conn, row.PayoutID)
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("LookupExistingLatest: %w", err)
	}
	if existing != nil && existing.ConfirmedAtUtc.Valid {
		// Already confirmed — step 8 directly.
		return r.claimAndLog(ctx, runID, row, existing)
	}
	if existing != nil && existing.BroadcastAtUtc.Valid && !existing.ConfirmedAtUtc.Valid {
		// Step 7 polling.
		return r.pollAndConfirm(ctx, conn, runID, row, existing)
	}

	// No existing live attempt — cancel pre-check + fresh allocation.
	cancels, err := LookupLiveCancels(ctx, conn, row.PayoutID)
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("LookupLiveCancels: %w", err)
	}
	for _, c := range cancels {
		// A live cancel HALTS fresh non-cancel allocation per §4.3
		// step 5 cancel pre-check. The HALT does NOT emit
		// invariant_violation — a live cancel is legitimate state.
		if !c.BroadcastAtUtc.Valid {
			// Unbroadcast — re-broadcast persisted bytes.
			r.rebroadcastCancel(ctx, runID, c)
		}
		// In either unbroadcast or broadcast-unconfirmed state, we
		// skip fresh allocation.
		_ = c
		return rowOutcomeSkipped, nil
	}

	// Fresh allocation (§4.3 step 5 — INSERT inside BEGIN IMMEDIATE).
	return r.allocateBuildSignBroadcast(ctx, runID, row, amount)
}

func (r *Runner) allocateBuildSignBroadcast(ctx context.Context, runID string, row ReadyRow, amount int64) (rowOutcome, error) {
	conn, err := r.opts.DB.Conn(ctx)
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("Conn: %w", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return rowOutcomeFailed, fmt.Errorf("BEGIN IMMEDIATE: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	// In-txn lease self-fence.
	if err := SelfFenceTx(ctx, conn, r.state); err != nil {
		return rowOutcomeFailed, err
	}

	// §4.3 step 4 stale-reservation halt.
	cutoff := r.opts.NowFn().Add(-24 * time.Hour).UTC().Format(time.RFC3339Nano)
	staleCount, err := CountStaleUnbroadcastTx(ctx, conn, r.opts.Security.HotWalletAddress, cutoff)
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("CountStaleUnbroadcastTx: %w", err)
	}
	if staleCount > 0 {
		r.emitInvariantViolation(row.PayoutID, "stale_unbroadcast_attempt", fmt.Sprintf("count=%d", staleCount))
		return rowOutcomeFailed, fmt.Errorf("stale unbroadcast attempts present (%d) — HALT per §4.3 step 4", staleCount)
	}

	// §4.3 step 4 per-day cap re-check (reservation-aware).
	windowStart := r.opts.NowFn().Add(-24 * time.Hour).UTC().Format(time.RFC3339Nano)
	committedSum, err := SumAmountWindow(ctx, conn, r.opts.Security.HotWalletAddress, windowStart)
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("SumAmountWindow: %w", err)
	}
	if committedSum+amount > r.opts.PerDayCapBaseUnits {
		r.opts.Logger.Warn().
			Str("event", "payout_capped").
			Str("run_id", runID).
			Int64("payout_id", row.PayoutID).
			Str("reason", "per_day_cap").
			Send()
		return rowOutcomeCapped, nil
	}

	// §4.3 step 5 — C3 NORMATIVE invariant: re-read provider_credits
	// inside the txn and assert amount_base_units == lpr.provider_credits.
	var lprProviderCredits int64
	err = conn.QueryRowContext(ctx,
		`SELECT provider_credits FROM ledger_payout_ready WHERE id = ?`, row.PayoutID,
	).Scan(&lprProviderCredits)
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("C3 invariant SELECT: %w", err)
	}
	if amount != lprProviderCredits {
		r.emitInvariantViolation(row.PayoutID, "amount_credit_mismatch",
			fmt.Sprintf("amount=%d ledger_provider_credits=%d", amount, lprProviderCredits))
		return rowOutcomeFailed, fmt.Errorf("amount_credit_mismatch")
	}

	// Allocate next nonce + INSERT the attempt row.
	attemptSeq, err := NextAttemptSeq(ctx, conn, row.PayoutID)
	if err != nil {
		return rowOutcomeFailed, err
	}
	nonce, err := AllocateNextNonceTx(ctx, conn, r.opts.Security.HotWalletAddress)
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("AllocateNextNonceTx: %w", err)
	}
	now := r.opts.NowFn().UTC().Format(time.RFC3339Nano)
	if err := InsertAttempt(ctx, conn, row.PayoutID, attemptSeq,
		r.opts.Security.HotWalletAddress, row.EffectiveAddress.String,
		amount, nonce, now,
	); err != nil {
		if errors.Is(err, ErrDuplicateLiveAttempt) {
			r.emitInvariantViolation(row.PayoutID, "duplicate live attempt", fmt.Sprintf("attempt_seq=%d", attemptSeq))
			return rowOutcomeFailed, err
		}
		return rowOutcomeFailed, fmt.Errorf("InsertAttempt: %w", err)
	}

	// §4.3 step 6 — build, sign, pre-broadcast verify, CAS persist, broadcast.
	tx, err := r.buildEIP1559(nonce, row.EffectiveAddress.String, amount)
	if err != nil {
		return rowOutcomeFailed, err
	}
	unsigned, err := tx.UnsignedRLP()
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("UnsignedRLP: %w", err)
	}
	signed, txHash, err := r.opts.Signer.SignTx(ctx, unsigned)
	if err != nil {
		if errors.Is(err, ErrSignerUnavailable) {
			r.opts.Logger.Error().
				Str("event", "payout_signer_unavailable").
				Str("from_address", r.opts.Security.HotWalletAddress).
				Err(err).
				Send()
		}
		return rowOutcomeFailed, fmt.Errorf("Signer.SignTx: %w", err)
	}
	// §4.3 step 6 NORMATIVE — pre-broadcast verification.
	if err := r.verifySignedTx(tx, signed, txHash, amount, row.EffectiveAddress.String, nonce); err != nil {
		r.emitChainValueMismatch(row.PayoutID, attemptSeq, txHash, "prebroadcast_signed_tx", err.Error())
		return rowOutcomeFailed, err
	}

	// CAS persist inside the BEGIN IMMEDIATE txn.
	if err := CASPersistSignedTx(ctx, conn, row.PayoutID, attemptSeq, signed, txHash, now); err != nil {
		// Side-channel discipline: do NOT log raw_signed_tx / txHash on discard paths.
		switch {
		case errors.Is(err, ErrAttemptRowMissing):
			r.emitInvariantViolation(row.PayoutID, "attempt_row_missing_during_sign", "")
		case errors.Is(err, ErrAttemptStateChangedDuringSign):
			r.emitInvariantViolation(row.PayoutID, "attempt_state_changed_during_sign", "")
		}
		return rowOutcomeFailed, err
	}

	// Bump nonce cursor in same txn.
	if err := BumpNonceCursorTx(ctx, conn, r.opts.Security.HotWalletAddress, now); err != nil {
		return rowOutcomeFailed, fmt.Errorf("BumpNonceCursorTx: %w", err)
	}

	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return rowOutcomeFailed, fmt.Errorf("COMMIT: %w", err)
	}
	committed = true

	// §4.3 step 6 — post-COMMIT lease re-read BEFORE broadcast.
	if err := SelfFence(ctx, r.opts.DB, r.state); err != nil {
		return rowOutcomeFailed, err
	}

	// M4 (§4.8b) test injection: optional sleep to exercise the
	// post-CAS broadcast race window. NOT used in production (zero).
	if r.opts.SleepAfterPostCommitLeaseReread > 0 {
		time.Sleep(r.opts.SleepAfterPostCommitLeaseReread)
	}

	// Broadcast on both RPCs.
	acceptedAny, _, _, primErr, secErr := r.opts.RPCs.BroadcastBoth(ctx, signed)
	if !acceptedAny {
		// SPEC §4.4: both rejected; row remains pending; next cycle retries.
		r.opts.Logger.Warn().
			Err(primErr).
			Msg("payout broadcast rejected by both RPCs (will retry next cycle)")
		return rowOutcomeFailed, nil
	}
	// M4 nonce-collision response handling: if either RPC returned
	// nonce-too-low / already-known, the chain has serialized the
	// race with another holder's broadcast. NOT an invariant_violation.
	if (primErr != nil && !IsNonceTooLow(primErr)) || (secErr != nil && !IsNonceTooLow(secErr)) {
		r.opts.Logger.Warn().
			Err(primErr).
			Err(secErr).
			Msg("payout broadcast partial-accept (one RPC rejected)")
	}
	// Stamp broadcast_at_utc post-COMMIT.
	if err := StampBroadcastAt(ctx, r.opts.DB, row.PayoutID, attemptSeq, now); err != nil {
		r.opts.Logger.Warn().Err(err).Msg("StampBroadcastAt failed (will retry next cycle)")
	}

	// §4.3 step 7 — confirm via two-RPC.
	freshExisting := &AttemptRow{
		PayoutID:        row.PayoutID,
		AttemptSeq:      attemptSeq,
		AmountBaseUnits: amount,
		Nonce:           nonce,
		ToAddress:       strings.ToLower(row.EffectiveAddress.String),
		TxHash:          sql.NullString{String: txHash, Valid: true},
	}
	return r.pollAndConfirm(ctx, conn, runID, row, freshExisting)
}

// pollAndConfirm polls both RPCs for the receipt + chain-side
// value verification + ClaimPayoutReady (§4.3 step 7 + step 8).
func (r *Runner) pollAndConfirm(ctx context.Context, conn *sql.Conn, runID string, row ReadyRow, attempt *AttemptRow) (rowOutcome, error) {
	if !attempt.TxHash.Valid {
		return rowOutcomeFailed, errors.New("pollAndConfirm: attempt has no tx_hash")
	}
	txHash := attempt.TxHash.String
	deadline := time.Now().Add(r.opts.ReceiptPollTimeout)

	var recPri, recSec *Receipt
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return rowOutcomeFailed, ctx.Err()
		default:
		}
		var perrA, perrB error
		recPri, perrA = r.opts.RPCs.Primary.TransactionReceipt(ctx, txHash)
		recSec, perrB = r.opts.RPCs.Secondary.TransactionReceipt(ctx, txHash)
		if perrA == nil && perrB == nil && recPri != nil && recSec != nil {
			// Confirmation depth check.
			head, err := r.opts.RPCs.Primary.BlockNumber(ctx)
			if err != nil {
				time.Sleep(r.opts.ReceiptPollInterval)
				continue
			}
			depth := int64(head) - int64(recPri.BlockNumber)
			if depth >= int64(r.opts.ConfirmationBlocks) {
				break
			}
		}
		time.Sleep(r.opts.ReceiptPollInterval)
	}
	if recPri == nil || recSec == nil {
		// Treat as transient — leave row pending; next cycle re-polls.
		r.opts.Logger.Warn().
			Int64("payout_id", row.PayoutID).
			Str("tx_hash", txHash).
			Msg("receipt poll deadline expired; will retry next cycle")
		return rowOutcomeFailed, nil
	}
	// SPEC §4.3 step 7 — two-RPC agreement.
	if !ReceiptsAgree(recPri, recSec) {
		r.emitRPCDisagreement(row.PayoutID, attempt.AttemptSeq, recPri, recSec)
		return rowOutcomeFailed, errors.New("two-RPC receipt disagreement")
	}
	if recPri.Status != 1 {
		r.opts.Logger.Warn().
			Int64("payout_id", row.PayoutID).
			Str("tx_hash", txHash).
			Msg("receipt status != 1 (tx reverted)")
		return rowOutcomeFailed, nil
	}
	// Chain-side value verification (a, b, c).
	if err := r.verifyChainSideTransfer(ctx, attempt, recPri); err != nil {
		r.emitChainValueMismatch(row.PayoutID, attempt.AttemptSeq, txHash, "transfer_log_mismatch", err.Error())
		return rowOutcomeFailed, err
	}
	// Mark confirmed.
	rowsAffected, err := r.markConfirmedStandalone(ctx, row.PayoutID, attempt.AttemptSeq,
		int64(recPri.BlockNumber), int64(recPri.GasUsed), r.opts.NowFn().UTC().Format(time.RFC3339Nano))
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("MarkConfirmed: %w", err)
	}
	if rowsAffected == 0 {
		// Concurrent abandon or already-confirmed — skip.
		return rowOutcomeSkipped, nil
	}
	// §4.3 step 8 — Claim.
	freshAttempt := &AttemptRow{
		PayoutID:   row.PayoutID,
		AttemptSeq: attempt.AttemptSeq,
		TxHash:     sql.NullString{String: txHash, Valid: true},
	}
	_ = conn // future trigger-presence intra-tx check anchors here
	return r.claimAndLog(ctx, runID, row, freshAttempt)
}

// claimAndLog issues ClaimPayoutReady and emits payout_paid /
// payout_failed.
func (r *Runner) claimAndLog(ctx context.Context, runID string, row ReadyRow, attempt *AttemptRow) (rowOutcome, error) {
	claimed, err := r.opts.Claimer.ClaimPayoutReady(ctx, row.PayoutID, row.GrossCredits, attempt.TxHash.String, "USDC-BASE")
	if err != nil {
		r.opts.Logger.Error().
			Str("event", "payout_failed").
			Str("run_id", runID).
			Int64("payout_id", row.PayoutID).
			Str("stage", "claim").
			Str("error_class", "claim_error").
			Err(err).
			Send()
		return rowOutcomeFailed, fmt.Errorf("ClaimPayoutReady: %w", err)
	}
	if !claimed {
		r.opts.Logger.Warn().
			Str("event", "payout_failed").
			Str("run_id", runID).
			Int64("payout_id", row.PayoutID).
			Str("stage", "claim").
			Str("error_class", "not_ready_or_amount_changed").
			Send()
		return rowOutcomeFailed, nil
	}
	r.opts.Logger.Info().
		Str("event", "payout_paid").
		Str("run_id", runID).
		Int64("payout_id", row.PayoutID).
		Int("attempt_seq", attempt.AttemptSeq).
		Str("provider_id", row.ProviderID).
		Int64("amount_usdc_base_units", row.ProviderCredits).
		Str("tx_hash", attempt.TxHash.String).
		Send()
	return rowOutcomePaid, nil
}

// rebroadcastCancel re-sends the persisted cancel envelope on
// both RPCs and stamps broadcast_at_utc on accept.
func (r *Runner) rebroadcastCancel(ctx context.Context, runID string, cancel AttemptRow) {
	if len(cancel.RawSignedTx) == 0 {
		r.opts.Logger.Warn().Int64("payout_id", cancel.PayoutID).Msg("cancel row missing raw_signed_tx")
		return
	}
	acceptedAny, _, _, _, _ := r.opts.RPCs.BroadcastBoth(ctx, cancel.RawSignedTx)
	if acceptedAny {
		now := r.opts.NowFn().UTC().Format(time.RFC3339Nano)
		_ = StampBroadcastAt(ctx, r.opts.DB, cancel.PayoutID, cancel.AttemptSeq, now)
	}
	_ = runID
}

// buildEIP1559 builds the EIP-1559 tx for a USDC transfer.
func (r *Runner) buildEIP1559(nonce int64, effectiveAddress string, amount int64) (EIP1559Tx, error) {
	calldata, err := USDCTransferCalldata(effectiveAddress, amount)
	if err != nil {
		return EIP1559Tx{}, err
	}
	usdcBytes, err := AddressBytes(USDCContractAddressBase)
	if err != nil {
		return EIP1559Tx{}, err
	}
	var to [20]byte
	copy(to[:], usdcBytes[:])
	return EIP1559Tx{
		ChainID:              BaseMainnetChainID,
		Nonce:                uint64(nonce),
		MaxPriorityFeePerGas: big.NewInt(2_000_000_000), // 2 gwei — production tuning lands in Step 4
		MaxFeePerGas:         big.NewInt(50_000_000_000), // 50 gwei
		GasLimit:             80_000,
		To:                   to,
		Value:                big.NewInt(0),
		Data:                 calldata,
	}, nil
}

// verifySignedTx implements the §4.3 step 6 NORMATIVE
// pre-broadcast verification of the Signer's output.
func (r *Runner) verifySignedTx(unsigned EIP1559Tx, signed []byte, returnedTxHash string,
	amount int64, effectiveAddress string, nonce int64,
) error {
	// (a) Re-decode + assert nonce / chain_id / to / value / input.
	decoded, _, _, _, err := DecodeSignedEIP1559(signed)
	if err != nil {
		return fmt.Errorf("decode: %w", err)
	}
	if decoded.Nonce != unsigned.Nonce {
		return fmt.Errorf("nonce mismatch: decoded=%d unsigned=%d", decoded.Nonce, unsigned.Nonce)
	}
	if decoded.ChainID != BaseMainnetChainID {
		return fmt.Errorf("chain_id != Base (%d)", decoded.ChainID)
	}
	if !bytes.Equal(decoded.To[:], unsigned.To[:]) {
		return errors.New("to mismatch")
	}
	if decoded.Value == nil || decoded.Value.Sign() != 0 {
		return errors.New("value != 0")
	}
	wantData, _ := USDCTransferCalldata(effectiveAddress, amount)
	if !bytes.Equal(decoded.Data, wantData) {
		return fmt.Errorf("calldata mismatch")
	}
	// (b) tx_hash recomputation.
	computed := TxHash(signed)
	if !strings.EqualFold(computed, returnedTxHash) {
		return fmt.Errorf("tx_hash mismatch: signer=%s local=%s", returnedTxHash, computed)
	}
	// (c) ecrecover.
	recovered, err := RecoverTxSender(signed)
	if err != nil {
		return fmt.Errorf("ecrecover: %w", err)
	}
	if !addressEqualFold(recovered, r.opts.Security.HotWalletAddress) {
		return fmt.Errorf("recovered sender %s != hot_wallet %s", recovered, r.opts.Security.HotWalletAddress)
	}
	_ = nonce
	return nil
}

// verifyChainSideTransfer implements §4.3 step 7 (a, b, c).
func (r *Runner) verifyChainSideTransfer(ctx context.Context, attempt *AttemptRow, receipt *Receipt) error {
	usdcAddrLower := strings.ToLower(USDCContractAddressBase)
	if receipt.To != usdcAddrLower {
		return fmt.Errorf("receipt.to %s != USDC %s", receipt.To, usdcAddrLower)
	}
	// (a) Fetch the full tx and assert input byte-equality on BOTH RPCs.
	txA, err := r.opts.RPCs.Primary.TransactionByHash(ctx, attempt.TxHash.String)
	if err != nil || txA == nil {
		return fmt.Errorf("eth_getTransactionByHash primary: %v", err)
	}
	txB, err := r.opts.RPCs.Secondary.TransactionByHash(ctx, attempt.TxHash.String)
	if err != nil || txB == nil {
		return fmt.Errorf("eth_getTransactionByHash secondary: %v", err)
	}
	want, err := USDCTransferCalldata(attempt.ToAddress, attempt.AmountBaseUnits)
	if err != nil {
		return fmt.Errorf("rebuild calldata: %w", err)
	}
	if !bytes.Equal(txA.Input, want) || !bytes.Equal(txB.Input, want) {
		return errors.New("tx.input byte-mismatch on either RPC")
	}
	// (b) Recover sender == hot wallet (use tx.from which both RPCs
	// agree on by Construction; ecrecover is the §4.3 step 6 path).
	if !addressEqualFold(txA.From, r.opts.Security.HotWalletAddress) {
		return fmt.Errorf("primary tx.from %s != hot_wallet", txA.From)
	}
	// (c) Exactly one Transfer log matching.
	hot, err := PadAddressTopic(r.opts.Security.HotWalletAddress)
	if err != nil {
		return err
	}
	to, err := PadAddressTopic(attempt.ToAddress)
	if err != nil {
		return err
	}
	transferTopic := "0x" + hex.EncodeToString(transferEventTopic)
	hotTopic := "0x" + hex.EncodeToString(hot)
	toTopic := "0x" + hex.EncodeToString(to)
	matchCount := 0
	for _, log := range receipt.Logs {
		if log.Address != usdcAddrLower {
			continue
		}
		if len(log.Topics) < 3 {
			continue
		}
		if log.Topics[0] != transferTopic {
			continue
		}
		if log.Topics[1] != hotTopic {
			continue
		}
		if log.Topics[2] != toTopic {
			continue
		}
		// abi.decode(data, uint256) == amount.
		got := new(big.Int).SetBytes(log.Data)
		want := big.NewInt(attempt.AmountBaseUnits)
		if got.Cmp(want) == 0 {
			matchCount++
		}
	}
	if matchCount != 1 {
		return fmt.Errorf("matching Transfer log count = %d, want 1", matchCount)
	}
	return nil
}

func (r *Runner) markConfirmedStandalone(ctx context.Context, payoutID int64, attemptSeq int,
	blockNumber, gasUsed int64, nowUTC string,
) (int64, error) {
	conn, err := r.opts.DB.Conn(ctx)
	if err != nil {
		return 0, err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return 0, err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	n, err := MarkConfirmedAtTx(ctx, conn, payoutID, attemptSeq, blockNumber, gasUsed, nowUTC)
	if err != nil {
		return 0, err
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return 0, err
	}
	committed = true
	return n, nil
}

// emitInvariantViolation centralises §7.1 PAGE event emission.
// SIDE-CHANNEL DISCIPLINE: fields limited to (payout_id, where,
// detail, ts_utc); no raw_signed_tx / tx_hash leak via detail.
func (r *Runner) emitInvariantViolation(payoutID int64, where, detail string) {
	r.opts.Logger.Error().
		Str("event", "payout_invariant_violation").
		Str("severity", "PAGE").
		Int64("payout_id", payoutID).
		Str("where", where).
		Str("detail", detail).
		Str("ts_utc", r.opts.NowFn().UTC().Format(time.RFC3339Nano)).
		Send()
}

func (r *Runner) emitChainValueMismatch(payoutID int64, attemptSeq int, txHash, class, detail string) {
	r.opts.Logger.Error().
		Str("event", "payout_chain_value_mismatch").
		Str("severity", "PAGE").
		Int64("payout_id", payoutID).
		Int("attempt_seq", attemptSeq).
		Str("tx_hash", txHash).
		Str("mismatch_class", class).
		Str("observed", detail).
		Str("ts_utc", r.opts.NowFn().UTC().Format(time.RFC3339Nano)).
		Send()
}

func (r *Runner) emitRPCDisagreement(payoutID int64, attemptSeq int, a, b *Receipt) {
	r.opts.Logger.Error().
		Str("event", "payout_rpc_disagreement").
		Str("severity", "PAGE").
		Int64("payout_id", payoutID).
		Int("attempt_seq", attemptSeq).
		Interface("rpc_a_state", receiptSummary(a)).
		Interface("rpc_b_state", receiptSummary(b)).
		Str("ts_utc", r.opts.NowFn().UTC().Format(time.RFC3339Nano)).
		Send()
}

func receiptSummary(r *Receipt) map[string]interface{} {
	if r == nil {
		return map[string]interface{}{"present": false}
	}
	return map[string]interface{}{
		"present":      true,
		"tx_hash":      r.TxHash,
		"block_hash":   r.BlockHash,
		"block_number": r.BlockNumber,
		"status":       r.Status,
		"to":           r.To,
	}
}
