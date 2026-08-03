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
	"sync/atomic"
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
	DB                    *sql.DB
	Security              SecurityConfig
	RPCs                  TwoRPCs
	Signer                Signer
	Claimer               PayoutClaimer
	Logger                zerolog.Logger
	RunInterval           time.Duration
	MaxRowsPerRun         int
	ConfirmationBlocks    int
	PerPayoutCapBaseUnits int64
	PerDayCapBaseUnits    int64
	ReceiptPollInterval   time.Duration
	ReceiptPollTimeout    time.Duration

	// LowBalanceThreshold / LowNativeThreshold drive the §6.2
	// balance-monitoring emits at the top of each cycle (Step 4).
	// 0 disables. Read once per cycle so SIGHUP reloads land
	// without a runner restart.
	//
	// Step 4 r1 [code:r1-2]/[arch:4.3] closure: these defaults
	// apply only when Tuning is nil. When Tuning is set, the live
	// snapshot's LowBalanceThreshold/LowNativeThreshold override.
	LowBalanceThreshold int64
	LowNativeThreshold  int64

	// Tuning is the §6.5 SIGHUP-reloadable snapshot provider.
	// When non-nil, Runner reads ConfirmationBlocks, MaxRowsPerRun,
	// LowBalanceThreshold, and LowNativeThreshold from Tuning.Snapshot()
	// once per cycle at the top of RunOnce. When nil, the static
	// fields above are used (test path).
	//
	// Step 4 r1 [code:r1-1]/[sec:r1-2]/[arch:4.2] convergent closure.
	// The runner's cadence (RunInterval) is captured at construction
	// and CANNOT be live-reloaded — a SIGHUP change to RunInterval
	// is documented as a known limitation requiring restart.
	Tuning *TuningProvider

	// ChronicOutageTracker, when non-nil, is evaluated once per
	// RunOnce cycle to emit payout_rpc_chronic_outage PAGE when a
	// single RPC has been failing for longer than the tracker's
	// window. #165 A2 closes the silent-degradation gap in the
	// two-RPC discipline.
	ChronicOutage *ChronicOutageTracker

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

	// Step 4 r1 [arch:4.1]/[sec:r1-1] convergent closure: halted
	// is set by RequestHalt (called by the chain-balance worker on
	// negative drift). RunOnce checks at top and aborts the cycle
	// with payout_runner_halted_skipping_cycle emitted; admin
	// run-now refuses with 409. Operator runbook drives recovery
	// (flip payout.enabled=false + investigate + restart).
	halted      atomic.Bool
	haltReason  atomic.Value // string
	haltedAtUTC atomic.Value // string (RFC3339Nano)

	// activeSnap is the §6.5 tuning snapshot captured at the top
	// of RunOnce. Single-threaded under mu+inFlight (only one
	// cycle in flight at a time), so a plain field suffices. Used
	// by processRow and all downstream helpers via r.snap().
	// Cleared in RunOnce's defer.
	activeSnap TuningSnapshot

	// runningBalance tracks the hot wallet USDC balance across one
	// RunOnce cycle. Set at top of RunOnce from a primary-RPC
	// balanceOf read; nil when the read failed (callers treat as
	// "unknown" and skip the check).
	//
	// Deduction is co-located with the actual spend EVENT — NOT
	// with rowOutcomePaid. Two paths spend hot-wallet USDC in this
	// cycle and both call r.deductPaidAmount() immediately after
	// BroadcastBoth returns acceptedAny + StampBroadcastAt persists:
	//   - allocateBuildSignBroadcast (fresh row)
	//   - rebroadcastAndPoll (persisted bytes broadcast this cycle)
	// The two other paths that return rowOutcomePaid (claimAndLog
	// for existing-confirmed; pollAndConfirm for prior-cycle
	// broadcast) reflect spend that already happened in a PRIOR
	// cycle — the top-of-cycle on-chain balance read already
	// accounts for it, so a second deduction would double-count
	// (Step 4 r7 [code:r7-1] HIGH closure).
	//
	// allocateBuildSignBroadcast reads runningBalance via the
	// r.hotWalletBalance() helper just before the attempt INSERT
	// — AFTER per-payout-cap, daily-cap, and existing-attempt
	// checks have decided this row needs a fresh transfer.
	//
	// Step 4 r6 [code:r6-1] HIGH closure: the r5 fix-pass placed
	// the balance guard at the top of the row loop, which
	// regressed per-payout-cap and daily-cap-trip rows on low
	// balance. The correct authority layer is here, inside the
	// broadcast path, after the cap/state decisions.
	//
	// Single-threaded under mu+inFlight; cleared in RunOnce defer.
	runningBalance *big.Int

	// recoveryOnly latches the R2-HIGH "recovery-only cycle" mode:
	// checkNonceGap returned gapRecoveryOnly (a rebroadcastable
	// crash-recovery attempt sits at the on-chain pending nonce, one
	// below the DB cursor). In this mode the row loop still drives
	// recovery rebroadcast + all unrelated in-flight polls/confirms,
	// but the single terminal fresh-allocation call site in processRow
	// is suppressed (returns rowOutcomeSkipped) so NO fresh nonce is
	// allocated past the unfilled hole this cycle. Set by RunOnce's
	// gap switch and cleared in the same cycle's defer. Single-threaded
	// under mu+inFlight.
	recoveryOnly bool
	// gapRecoveryObservedNonce / gapRecoveryExpectedNonce carry the
	// on-chain observed pending nonce and the DB cursor's expected nonce
	// captured by checkNonceGap on the gapRecoveryOnly path. They exist
	// ONLY so RunOnce can emit the per-cycle payout_nonce_gap_recovery_only
	// diagnostic (from_address + observed/expected + ts) — they are never
	// used to target or drive an attempt. Meaningful only while
	// recoveryOnly is true; single-threaded under mu+inFlight.
	gapRecoveryObservedNonce uint64
	gapRecoveryExpectedNonce uint64
}

// hotWalletBalance returns the cycle-scoped running USDC balance
// captured at the top of RunOnce, or nil if the initial RPC read
// failed (treated as "unknown"; balance-gated paths fall through
// and let downstream sign/broadcast surface the failure).
//
// Step 4 r6 [code:r6-1] HIGH closure: consumed by
// allocateBuildSignBroadcast for the per-row insufficient-funds
// check.
func (r *Runner) hotWalletBalance() *big.Int {
	if r.runningBalance == nil {
		return nil
	}
	// Return a defensive copy so the caller can't mutate the
	// running tally accidentally.
	return new(big.Int).Set(r.runningBalance)
}

// deductPaidAmount subtracts a paid amount from the cycle-scoped
// running balance after a successful row. No-op when the running
// balance is unknown (initial RPC read failed).
func (r *Runner) deductPaidAmount(amount int64) {
	if r.runningBalance == nil || amount <= 0 {
		return
	}
	r.runningBalance.Sub(r.runningBalance, new(big.Int).SetInt64(amount))
}

// RequestHalt is the chain-balance worker's halt entry point.
// Sets the persistent halt flag and persists the reason; the next
// cycle observes the flag and skips. Safe to call concurrently and
// idempotently — the first reason wins.
//
// SPEC §7.4: drift beyond tolerance MUST halt the runner.
// Step 4 r1 [arch:4.1]/[sec:r1-1] convergent closure.
func (r *Runner) RequestHalt(reason string) {
	if r == nil {
		return
	}
	if r.halted.CompareAndSwap(false, true) {
		r.haltReason.Store(reason)
		r.haltedAtUTC.Store(r.opts.NowFn().UTC().Format(time.RFC3339Nano))
		r.opts.Logger.Error().
			Str("event", "payout_runner_halted").
			Str("severity", "PAGE").
			Str("reason", reason).
			Str("ts_utc", r.opts.NowFn().UTC().Format(time.RFC3339Nano)).
			Send()
	}
}

// IsHalted reports whether RequestHalt has been called. Admin
// run-now uses this to refuse 409. The halt flag is process-local
// and survives only until restart — operator runbook expects a
// human-driven restart after investigation.
func (r *Runner) IsHalted() bool {
	if r == nil {
		return false
	}
	return r.halted.Load()
}

// HaltReason returns the reason recorded by RequestHalt, or "" if
// the runner is not halted.
func (r *Runner) HaltReason() string {
	if r == nil {
		return ""
	}
	v := r.haltReason.Load()
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// EmitAdminInvokedWhileHalted records the §7.1 observability event
// when an admin endpoint with the explicit-bypass-during-halt policy
// is invoked while RequestHalt is in effect. Closes FULL-r1
// [full-code:r1-3] MEDIUM. The endpoint is named (abandon-attempt,
// pause-registration, etc.) so a runbook can correlate operator
// triage actions to the halt reason. Non-blocking: the handler still
// runs; this is observability only.
func (r *Runner) EmitAdminInvokedWhileHalted(endpoint string) {
	if r == nil {
		return
	}
	r.opts.Logger.Warn().
		Str("event", "payout_admin_invoked_while_halted").
		Str("severity", "WARN").
		Str("endpoint", endpoint).
		Str("reason", r.HaltReason()).
		Str("ts_utc", r.opts.NowFn().UTC().Format(time.RFC3339Nano)).
		Send()
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
// to finish before returning. Returns true if the loop exited
// cleanly (r.done fired), false if ctx.Done() fired first.
//
// Codex round-2 [arch:3.1-r2] MEDIUM closure: a "false" return
// means the runner MIGHT still be mid-cycle; callers SHOULD let
// the lease stale out (3 × run_interval) rather than calling
// Release, so a slow shutdown doesn't race the next process's
// Acquire against the original holder still finishing its
// broadcast.
func (r *Runner) Stop(ctx context.Context) bool {
	close(r.stop)
	select {
	case <-r.done:
		return true
	case <-ctx.Done():
		return false
	}
}

func (r *Runner) loop(ctx context.Context) {
	defer close(r.done)
	heartbeatTicker := time.NewTicker(r.opts.RunInterval)
	defer heartbeatTicker.Stop()
	cycleTicker := time.NewTicker(r.opts.RunInterval)
	defer cycleTicker.Stop()
	// Run once immediately to drain any backlog at startup.
	if _, err := r.RunOnce(ctx); err != nil {
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
			if _, err := r.RunOnce(ctx); err != nil {
				r.opts.Logger.Warn().Err(err).Msg("payout runner cycle errored")
			}
		}
	}
}

// currentTuning returns the live §6.5 tuning snapshot. When a
// TuningProvider is wired (production path), reads come from the
// SIGHUP-reloadable atomic snapshot. When nil (test path), the
// static RunnerOptions fields are used.
//
// Step 4 r1 [code:r1-1]/[sec:r1-2]/[arch:4.2] convergent closure:
// snapshot is read ONCE per RunOnce at the top, so all reads
// within a cycle see a consistent view even if SIGHUP arrives
// mid-cycle.
func (r *Runner) currentTuning() TuningSnapshot {
	if r.opts.Tuning != nil {
		return r.opts.Tuning.Snapshot()
	}
	return TuningSnapshot{
		AddressCoolingOffPeriod: 0,
		RunInterval:             r.opts.RunInterval,
		ConfirmationBlocks:      r.opts.ConfirmationBlocks,
		MaxRowsPerRun:           r.opts.MaxRowsPerRun,
		LowBalanceThreshold:     r.opts.LowBalanceThreshold,
		LowNativeThreshold:      r.opts.LowNativeThreshold,
	}
}

// snap returns r.activeSnap. When called outside a RunOnce cycle
// (zero-value), falls back to currentTuning(). All processRow
// downstream helpers must call this rather than reading
// r.opts.ConfirmationBlocks / MaxRowsPerRun / LowBalance / LowNative
// directly, so SIGHUP reloads land at the next cycle boundary
// (Step 4 r1 [code:r1-1]/[arch:4.2] closure).
func (r *Runner) snap() TuningSnapshot {
	if r.activeSnap.ConfirmationBlocks == 0 {
		return r.currentTuning()
	}
	return r.activeSnap
}

// RunOnce executes one §4.3 cycle synchronously. Used by Start
// (cadence) and by the admin /admin/payout/run-now endpoint.
//
// Returns (runID, nil) on success or (runID, err) on error; the
// runID is the same UUID emitted in payout_run_started /
// payout_run_finished so callers (e.g. run-now handler) can
// surface the same ID to operators for correlation.
//
// Step 4 r3 [code:r3-1] HIGH closure: previous signature was
// (ctx) error — the run-now handler and the runner both generated
// independent UUIDs so payout_run_now_invoked.run_id never matched
// payout_run_started.run_id. Returning the run_id here lets
// runnow.go emit payout_run_now_invoked with the actual cycle ID.
//
// The cycle is best-effort: per-row errors are logged but the
// cycle continues with the next row. Fatal errors (lease lost,
// invariant violation) abort the cycle and trip the runner-halt
// signal via the returned error.
func (r *Runner) RunOnce(ctx context.Context) (string, error) {
	// Step 4 r1 [arch:4.1]/[sec:r1-1] convergent closure: refuse
	// the cycle if RequestHalt has been called. The PAGE event
	// was already emitted at halt time; the per-cycle skip event
	// here is observability for the operator runbook.
	if r.halted.Load() {
		r.opts.Logger.Warn().
			Str("event", "payout_runner_halted_skipping_cycle").
			Str("severity", "PAGE").
			Str("reason", r.HaltReason()).
			Str("ts_utc", r.opts.NowFn().UTC().Format(time.RFC3339Nano)).
			Send()
		return "", ErrRunnerHalted
	}
	r.mu.Lock()
	if r.inFlight {
		r.mu.Unlock()
		return "", errors.New("RunOnce: cycle already in flight")
	}
	r.inFlight = true
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		r.inFlight = false
		r.mu.Unlock()
	}()

	// Snapshot the §6.5 tuning ONCE at the top of the cycle so all
	// downstream reads see a consistent view. SIGHUP between calls
	// to processRow within a single cycle does NOT take effect
	// until the next cycle. Cleared on cycle exit (mu+inFlight
	// guarantees no concurrent reader).
	snap := r.currentTuning()
	r.activeSnap = snap
	defer func() { r.activeSnap = TuningSnapshot{} }()

	runID := uuid.NewString()
	now := r.opts.NowFn()
	r.opts.Logger.Info().
		Str("event", "payout_run_started").
		Str("run_id", runID).
		Str("ts_utc", now.Format(time.RFC3339Nano)).
		Send()

	paid, capped, failed, skipped, skippedFunds := 0, 0, 0, 0, 0
	defer func() {
		// §7.1 payout_run_finished — full field set per
		// codex round-1 [arch:3.4] closure.
		// Step 4 r5 [code:r5-1] HIGH closure: skipped_funds now
		// reflects actual rows skipped due to insufficient funds;
		// previously hardcoded 0.
		r.opts.Logger.Info().
			Str("event", "payout_run_finished").
			Str("run_id", runID).
			Str("ts_utc", r.opts.NowFn().Format(time.RFC3339Nano)).
			Int("paid", paid).
			Int("capped", capped).
			Int("failed", failed).
			Int("skipped_no_addr", skipped).
			Int("skipped_funds", skippedFunds).
			Str("error_text", "").
			Send()
	}()

	// §4.7 step 5 runner-owned stale-transition production (codex
	// Step 3 r1 [arch:3.2] MAJOR closure; r2 [arch:r2-3.2-A] adds
	// two-RPC not-found verification; r2 [arch:r2-3.3] persists
	// run_id). Runs BEFORE the §4.3 step 1 SELECT so the PAGE
	// event for a stale cancel fires inside the same cycle that
	// would otherwise blindly hold the stranded row indefinitely.
	//
	// Step 4 r3 [arch:r3-4.1] MAJOR closure: use snap.RunInterval
	// (the per-cycle TuningProvider snapshot) instead of
	// r.opts.RunInterval (the startup-time value). The reaper
	// already does this (reaper.go:58); the stale-cancel threshold
	// 3 × run_interval must be live-read on both paths so a SIGHUP
	// run_interval change takes effect without a restart.
	// #165 A1: cap on PRODUCED outbox rows (NOT scanned candidates)
	// sized from snap.MaxRowsPerRun so the stale-cancel producer
	// matches the §4.3 step 1 cap (bounded by the same operator
	// config). The scan inside ProduceStaleOutboxRows is keyset-
	// paginated so memory stays bounded regardless of backlog depth.
	if produced, err := ProduceStaleOutboxRows(ctx, r.opts.DB, r.opts.Logger,
		r.opts.RPCs, runID, now, snap.RunInterval, snap.MaxRowsPerRun,
	); err != nil {
		r.opts.Logger.Warn().Err(err).
			Str("event", "payout_stale_outbox_producer_failed").Send()
	} else if produced > 0 {
		r.opts.Logger.Warn().
			Str("event", "payout_stale_outbox_produced").
			Int("produced", produced).
			Str("run_id", runID).
			Str("ts_utc", now.Format(time.RFC3339Nano)).Send()
	}

	// §6.2 balance monitoring (Step 4). Runs ONCE per cycle so
	// SIGHUP-tuned thresholds land without a runner restart.
	// Failure here is observability-only — degraded telemetry is
	// preferred over a money-path stall on transient RPC error.
	r.emitBalanceAlerts(ctx, runID, now, snap)

	// #165 A2: chronic single-RPC outage detector. Runs once per
	// cycle after the §6.2 alerts so the sliding-window includes
	// the freshest RPC calls. Observability-only — never blocks
	// the cycle.
	r.opts.ChronicOutage.Evaluate(ctx, now)

	// SPEC-016 §7.1 payout_nonce_gap pre-check. Runs ONCE per cycle
	// BEFORE the §4.3 step 1 SELECT and BEFORE any fresh nonce
	// allocation. A confirmed gap (on-chain pending nonce fell BEHIND
	// the DB cursor via an abandoned-unfilled hole) HALTS the whole
	// cadence cycle for the single hot wallet: no rows are processed,
	// nothing is allocated/built/broadcast, and NO automatic gap-fill
	// is attempted. Per-cycle skip only — the next cadence cycle
	// re-checks against fresh on-chain state.
	// R2-HIGH tri-state gate (architect Option A). gapHalt returns
	// without processing rows; gapProceed runs the normal cycle;
	// gapRecoveryOnly latches r.recoveryOnly so the row loop drives
	// recovery + unrelated in-flight work but processRow suppresses the
	// single fresh-allocation call site (no fresh nonce past the hole).
	decision, err := r.checkNonceGap(ctx, now)
	if err != nil {
		return runID, fmt.Errorf("checkNonceGap: %w", err)
	}
	switch decision {
	case gapHalt:
		return runID, nil
	case gapRecoveryOnly:
		r.recoveryOnly = true
		defer func() { r.recoveryOnly = false }()
		// Per-cycle §7.1 diagnostic: a rebroadcastable crash-recovery
		// attempt sits at the on-chain pending nonce, so this cycle
		// suppresses fresh allocation and lets the normal row loop drive
		// the recovery rebroadcast + all unrelated in-flight work. Emitted
		// EVERY recovery-only cycle so an unselectable-recovery fail-closed
		// PAUSE (payout_allowed=0 / cooling-off / off-page) is visible to
		// the operator rather than a silent payout stall.
		r.opts.Logger.Warn().
			Str("event", "payout_nonce_gap_recovery_only").
			Str("run_id", runID).
			Str("from_address", strings.ToLower(r.opts.Security.HotWalletAddress)).
			Uint64("expected_nonce", r.gapRecoveryExpectedNonce).
			Uint64("observed_pending_nonce", r.gapRecoveryObservedNonce).
			Str("ts_utc", now.UTC().Format(time.RFC3339Nano)).
			Send()
	case gapProceed:
		// normal cycle
	}

	// §4.3 step 1: SELECT ready rows.
	hotWallet := r.opts.Security.HotWalletAddress
	rows, err := SelectReadyPayouts(ctx, r.opts.DB, hotWallet, now.Format(time.RFC3339Nano), snap.MaxRowsPerRun)
	if err != nil {
		return runID, fmt.Errorf("SelectReadyPayouts: %w", err)
	}

	// Step 4 r5 [code:r5-1] HIGH closure (r6 [code:r6-1] HIGH refit;
	// r7 [code:r7-1] HIGH refit): §4.3 step 6-7 + §7.1 line 3722
	// require a per-row hot-wallet USDC balance check before
	// sign/broadcast. The CHECK lives inside allocateBuildSignBroadcast
	// (after per-payout-cap + daily-cap + existing-attempt decisions);
	// RunOnce just captures the cycle's initial balance here. Deduction
	// of paid amounts happens INSIDE the broadcast paths (the two
	// rowOutcomePaid sites that actually move money this cycle:
	// allocateBuildSignBroadcast and rebroadcastAndPoll), NOT at the
	// RunOnce outcome switch — see the runningBalance field comment
	// above for the rationale. On RPC failure the running balance
	// stays nil and the in-broadcast check falls through.
	r.runningBalance, _ = r.currentHotWalletUSDCBalance(ctx)
	defer func() { r.runningBalance = nil }()

rowLoop:
	for _, row := range rows {
		// FULL-r1 [full-code:r1-2] HIGH closure: halt may be
		// requested mid-cycle (the chain-balance worker calls
		// RequestHalt on payout_chain_balance_drift_negative). Gate
		// at the row-loop boundary so an in-flight cycle stops
		// before processing the next row. Emit a single
		// observability event the FIRST time a halted row is
		// skipped; the chain-balance worker already emitted the
		// PAGE event at halt time, and RunOnce's pre-cycle gate
		// emits payout_runner_halted_skipping_cycle on next
		// invocation. Defense-in-depth gates inside
		// allocateBuildSignBroadcast / rebroadcastAndPoll /
		// claimAndLog cover the irreversible chain-write windows
		// (post-COMMIT, post-SelfFence, pre-broadcast, pre-claim).
		if r.halted.Load() {
			r.opts.Logger.Warn().
				Str("event", "payout_runner_halted_skipping_rows").
				Str("run_id", runID).
				Str("reason", r.HaltReason()).
				Str("ts_utc", r.opts.NowFn().UTC().Format(time.RFC3339Nano)).
				Send()
			break rowLoop
		}
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
				return runID, perr
			}
			continue
		}
		switch outcome {
		case rowOutcomePaid:
			paid++
			// NOTE: deduction of the paid amount from runningBalance
			// happens INSIDE the broadcast paths (allocateBuildSignBroadcast
			// + rebroadcastAndPoll) the moment the chain accepts the
			// tx, NOT here at the outcome level. Step 4 r7 [code:r7-1]
			// HIGH closure: rowOutcomePaid is overloaded — it is also
			// returned by claimAndLog (existing confirmed in prior
			// cycle) and pollAndConfirm (prior-cycle broadcast confirms
			// now). Both of those reflect spend that ALREADY HAPPENED
			// in a prior cycle; the top-of-cycle on-chain balance
			// already accounts for them. Deducting again would
			// double-count and cause spurious payout_insufficient_funds
			// emissions on subsequent fresh rows.
		case rowOutcomeCapped:
			capped++
		case rowOutcomeDailyCapTripped:
			// Step 4 r5 [code:r5-2] HIGH closure: daily cap trip halts
			// all subsequent rows in this cycle per SPEC §4.3 step 4.
			// Use a labeled break to exit the outer for loop.
			capped++
			break rowLoop
		case rowOutcomeInsufficientFunds:
			// Step 4 r6 [code:r6-1] HIGH closure: insufficient hot-wallet
			// USDC for the row's required transfer. payout_insufficient_funds
			// was already emitted by allocateBuildSignBroadcast. Per
			// SPEC §4.3 step 6-7 we halt the cycle so subsequent rows
			// are NOT processed; the next cadence cycle re-checks
			// against a fresh balance.
			skippedFunds++
			break rowLoop
		case rowOutcomeSkipped:
			skipped++
		case rowOutcomeFailed:
			failed++
		}
	}
	return runID, nil
}

// currentHotWalletUSDCBalance reads the hot wallet USDC balance from
// the primary RPC. Returns (nil, err) on RPC or parse error — callers
// treat nil as "balance unknown" and skip the check.
//
// Step 4 r5 [code:r5-1] HIGH closure: used by RunOnce to guard the
// row loop against insufficient-funds sign/broadcast per SPEC §4.3
// step 6-7 + §7.1 line 3722.
func (r *Runner) currentHotWalletUSDCBalance(ctx context.Context) (*big.Int, error) {
	hotLower := strings.ToLower(r.opts.Security.HotWalletAddress)
	data := usdcBalanceCalldata(hotLower)
	res, err := r.opts.RPCs.Primary.CallContract(ctx, USDCContractAddressBase, data)
	if err != nil {
		return nil, err
	}
	bal, ok := parseBalanceResult(res)
	if !ok {
		return nil, fmt.Errorf("currentHotWalletUSDCBalance: parse failed")
	}
	return bal, nil
}

// gapDecision is the tri-state result of the §7.1 nonce-gap pre-check
// (R2-HIGH, architect Option A). It replaces the old (bool halt, error)
// return so a rebroadcastable-at-observed hole no longer collapses into
// a blanket "proceed" that lets the row loop allocate past the hole.
type gapDecision int

const (
	// gapProceed: no gap to guard (no cursor yet, or observed >=
	// expected). Normal cycle — fresh allocation may happen.
	gapProceed gapDecision = iota
	// gapHalt: fail-closed. Nonce state unverifiable, a real abandon
	// hole, or a reorg-suspect chain contradiction. RunOnce returns
	// without processing any row this cycle.
	gapHalt
	// gapRecoveryOnly: a rebroadcastable crash-recovery attempt sits at
	// the on-chain pending nonce (observed = expected-1). The cycle
	// proceeds to drive that attempt's rebroadcast + all unrelated
	// in-flight polls/confirms, but the single terminal fresh-allocation
	// call site in processRow is suppressed so NO fresh nonce is
	// allocated past the unfilled hole this cycle.
	gapRecoveryOnly
)

// checkNonceGap performs the SPEC-016 §7.1 payout_nonce_gap (WARN)
// pre-check ONCE per cadence cycle, BEFORE any fresh nonce is
// allocated. It guards fresh nonce allocation: the on-chain pending
// nonce having fallen BEHIND the DB cursor (observed_pending_nonce <
// expected_nonce) means nonce `observed` is not yet mined, so allocating
// N+1 into that hole would stall the money path on-chain. This is a
// SAFETY GATE, so it fails CLOSED: every path that cannot POSITIVELY
// prove the hole is benign crash-recovery HALTS the cycle (return
// halt=true after emitting the right diagnostic) rather than falling
// through to allocation. RunOnce then skips ALL rows this cycle for the
// single hot wallet — no allocate/build/broadcast and NO automatic
// gap-fill. The next cadence cycle re-checks against fresh on-chain
// state. This is a per-cycle skip, NOT a runner halt (RequestHalt stays
// reserved for §7.4 negative-drift).
//
// Decision table (each path maps to a concrete RPC/DB check):
//   - no cursor yet                         → cold-start incomplete; cannot
//     compute a gap → proceed (nothing to guard yet)
//   - two-RPC read error / >1 disagreement  → nonce state UNVERIFIABLE →
//     HALT fail-closed (emit payout_nonce_gap_precheck_skipped). A
//     transient blip is re-checked next cycle; a chronic RPC outage is
//     separately PAGEd by the chronic-outage detector. This must NOT fall
//     through to allocation — an unverified cursor is exactly when a hole
//     could be allocated into.
//   - observed >= expected                  → steady state (==) or an
//     out-of-band spend (observed>expected is a DIFFERENT pathology,
//     NOT payout_nonce_gap) → proceed
//   - observed < expected: a nonce MAY be missing. Resolve via the
//     payout_attempts row at nonce == observed, in this order:
//     1. rebroadcastable attempt AT observed → benign crash-recovery
//     (bytes re-broadcast next cycle) → PROCEED. This is the ONLY
//     proceed path in the observed<expected branch.
//     2. abandoned/unconfirmed/non-cancel CAUSE AT observed → real
//     abandon hole → emit payout_nonce_gap (WARN) → HALT.
//     3. otherwise (a confirmed row AT observed, OR nothing at observed)
//     → chain-contradicted / unexplained. Because observed is not yet
//     mined, any confirmed_at_utc row at `observed` is stale-by-
//     definition (reorged-out inside the reorg window), so it must
//     NOT suppress the gap. Emit payout_nonce_gap_reorg_suspect (info)
//     → HALT. The reorg poller (reorg.go) independently detects and
//     reconciles the stale row and emits its own payout_reorg_*
//     alerts; this halt only prevents allocating into the hole
//     meanwhile.
//
// This also closes a latent stall: an operator abandon WITHOUT a cancel
// (§4.6 permits broadcast_cancel_self_transfer:false) leaves the
// abandoned row out of LookupExistingLatest, so cancelsBlockFresh stays
// false and processRow would allocate N+1 into the hole and stall
// silently on-chain. The halt here fires in exactly that state.
//
// R2-HIGH (architect Option A): the rebroadcastable-at-observed path no
// longer returns a blanket "proceed" — that let the row loop fresh-
// allocate N+1 past the unfilled hole whenever the recovery attempt was
// not selected by SelectReadyPayouts or its rebroadcast failed, stalling
// the whole hot wallet on-chain. It now returns gapRecoveryOnly: the
// cycle proceeds far enough to drive recovery + unrelated in-flight
// work, but suppresses fresh allocation. See gapDecision.
func (r *Runner) checkNonceGap(ctx context.Context, now time.Time) (gapDecision, error) {
	hotWallet := r.opts.Security.HotWalletAddress
	expected, ok, err := ReadNonceCursor(ctx, r.opts.DB, hotWallet)
	if err != nil {
		return gapHalt, fmt.Errorf("ReadNonceCursor: %w", err)
	}
	if !ok {
		return gapProceed, nil
	}

	// Per-cycle two-RPC pending-nonce read, reusing the audited
	// ColdStartNonceSync discipline (both RPCs, "pending" tag, ±1
	// tolerance, chosen = max). observed = chosen. A returned error is
	// either a transient RPC failure OR a >1 cross-RPC disagreement;
	// both mean "skip the gap check this cycle" — NOT a gap.
	observed, _, _, _, err := r.opts.RPCs.ColdStartNonceSync(ctx, hotWallet)
	if err != nil {
		// Nonce state is UNVERIFIABLE this cycle (transient RPC failure OR
		// a >1 cross-RPC disagreement). Fail CLOSED: HALT rather than
		// allocate against an unverified cursor — an unverified read is
		// exactly the state in which a fresh N+1 could be dropped into a
		// hole and stall. Info diagnostic only; a chronic RPC outage is
		// separately PAGEd by the chronic-outage detector. Redact the raw
		// error (an RPC URL can carry a secret) — log only a classified
		// error class, never err.Error()/the URL.
		r.opts.Logger.Warn().
			Str("event", "payout_nonce_gap_precheck_skipped").
			Str("error_class", classifyRPCErr(err)).
			Str("from_address", strings.ToLower(hotWallet)).
			Str("ts_utc", now.UTC().Format(time.RFC3339Nano)).
			Send()
		return gapHalt, nil
	}

	if observed >= expected {
		return gapProceed, nil
	}

	// observed < expected: a nonce MAY be missing at nonce == observed.
	// Resolve via the payout_attempts row there. Fail closed on everything
	// except a positively-benign crash-recovery.

	// 1. Rebroadcastable attempt AT observed → benign crash-recovery; the
	//    persisted bytes re-broadcast next cycle and fill the nonce. This
	//    is the ONLY proceed path in this branch.
	rebroad, err := rebroadcastableAttemptExists(ctx, r.opts.DB, hotWallet, observed)
	if err != nil {
		return gapHalt, fmt.Errorf("rebroadcastableAttemptExists: %w", err)
	}
	if rebroad {
		// R2-HIGH (architect Option A): the persisted bytes WILL be
		// re-broadcast to fill the hole, but only if the recovery attempt
		// is actually driven this cycle. Do NOT blanket-proceed (that let
		// the row loop fresh-allocate N+1 past the hole when the recovery
		// row was unselectable or its rebroadcast failed). Enter
		// recovery-only mode: the normal row loop rebroadcasts the
		// selected recovery attempt (and any live cancel) while
		// processRow suppresses fresh allocation. Capture observed +
		// expected purely so RunOnce can emit the per-cycle
		// payout_nonce_gap_recovery_only diagnostic.
		r.gapRecoveryObservedNonce = observed
		r.gapRecoveryExpectedNonce = expected
		return gapRecoveryOnly, nil
	}

	// 2. Durable abandon CAUSE AT observed (abandoned, unconfirmed,
	//    non-cancel) → a real abandon hole. Emit §7.1 payout_nonce_gap
	//    (WARN) and HALT. Checked before the reorg-suspect fallback so the
	//    dual case (a real abandon CAUSE and a stale confirmed row both at
	//    observed) is reported as the more specific payout_nonce_gap.
	cause, err := nonceGapCauseExists(ctx, r.opts.DB, hotWallet, observed)
	if err != nil {
		return gapHalt, fmt.Errorf("nonceGapCauseExists: %w", err)
	}
	if cause {
		r.opts.Logger.Warn().
			Str("event", "payout_nonce_gap").
			Str("severity", "WARN").
			Str("from_address", strings.ToLower(hotWallet)).
			Uint64("expected_nonce", expected).
			Uint64("observed_pending_nonce", observed).
			Str("ts_utc", now.UTC().Format(time.RFC3339Nano)).
			Send()
		return gapHalt, nil
	}

	// 3. Otherwise: a confirmed row sits at observed (stale-by-definition,
	//    since observed is not yet mined → reorged-out inside the reorg
	//    window), OR nothing at all sits at observed (chain-contradicted /
	//    unexplained). Both are uncertain, so HALT fail-closed. Emit an
	//    info payout_nonce_gap_reorg_suspect (NO raw RPC error/URL); the
	//    reorg poller reconciles the stale row and emits its own
	//    payout_reorg_* alerts.
	r.opts.Logger.Warn().
		Str("event", "payout_nonce_gap_reorg_suspect").
		Str("from_address", strings.ToLower(hotWallet)).
		Uint64("expected_nonce", expected).
		Uint64("observed_pending_nonce", observed).
		Str("ts_utc", now.UTC().Format(time.RFC3339Nano)).
		Send()
	return gapHalt, nil
}

type rowOutcome int

const (
	rowOutcomePaid rowOutcome = iota
	rowOutcomeCapped
	// rowOutcomeDailyCapTripped is returned by processRow (via
	// allocateBuildSignBroadcast) when the per-day window sum would
	// exceed PerDayCapBaseUnits. Distinct from rowOutcomeCapped
	// (per-payout cap) so RunOnce can BREAK the row loop.
	// Step 4 r5 [code:r5-2] HIGH closure.
	rowOutcomeDailyCapTripped
	// rowOutcomeInsufficientFunds is returned by
	// allocateBuildSignBroadcast when, AFTER per-payout-cap +
	// per-day-cap + existing-attempt decisions have all passed and
	// a fresh transfer is about to be initiated, the running
	// hot-wallet USDC balance is below the required amount. RunOnce
	// breaks the row loop on this outcome per SPEC §4.3 step 6-7.
	// Distinct from rowOutcomeCapped + rowOutcomeDailyCapTripped:
	// those are cap-policy decisions; this is a chain-state
	// observation.
	// Step 4 r6 [code:r6-1] HIGH closure: the r5 fix-pass placed
	// this check at the top of the row loop, regressing per-payout-cap
	// + daily-cap rows on low balance. The correct authority layer
	// is inside the broadcast path, after the cap/state decisions.
	rowOutcomeInsufficientFunds
	rowOutcomeFailed
	rowOutcomeSkipped
)

// processRow runs §4.3 steps 2-9 for a single ready row. The
// §6.5 tuning snapshot is read off r.activeSnap via r.snap();
// the snapshot was captured by RunOnce at cycle start so all
// confirmation_blocks reads within one cycle see the same view.
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
	// §7.1 payout_capped — full field set.
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
	// Step 5 NORMATIVE (closes codex round-1 [code:1.1]): if the
	// previous cycle persisted raw_signed_tx + tx_hash but crashed
	// or lost lease before broadcast (broadcast_at_utc IS NULL),
	// the next holder MUST rebroadcast the persisted bytes
	// bit-for-bit. Re-signing is FORBIDDEN per §4.6. SPEC §4.3 step
	// 5 path "broadcast (but not confirmed) → jump to step 7 to
	// poll" applies only AFTER the broadcast happens; before that,
	// the persisted-bytes path takes precedence.
	if existing != nil && len(existing.RawSignedTx) > 0 && !existing.BroadcastAtUtc.Valid && !existing.AbandonedAtUtc.Valid {
		return r.rebroadcastAndPoll(ctx, conn, runID, row, existing)
	}
	if existing != nil && existing.BroadcastAtUtc.Valid && !existing.ConfirmedAtUtc.Valid {
		// Step 7 polling.
		return r.pollAndConfirm(ctx, conn, runID, row, existing)
	}

	// No existing live non-cancel attempt — cancel pre-check + fresh allocation.
	// Closes codex round-1 [code:1.2]: implement the full state
	// machine (unbroadcast → rebroadcast/stamp/poll;
	// broadcast-unconfirmed → cancel-specific poll/mark-confirmed;
	// confirmed → INFO emit + proceed to fresh allocation without
	// calling ClaimPayoutReady).
	cancels, err := LookupLiveCancels(ctx, conn, row.PayoutID)
	if err != nil {
		return rowOutcomeFailed, fmt.Errorf("LookupLiveCancels: %w", err)
	}
	cancelsBlockFresh := false
	for _, c := range cancels {
		c := c // shadow for closure-safety
		switch {
		case !c.BroadcastAtUtc.Valid:
			// Unbroadcast cancel: rebroadcast persisted bytes,
			// stamp broadcast_at_utc on accept, then poll
			// next cycle. Fresh allocation HALTS this cycle.
			r.rebroadcastCancel(ctx, runID, c)
			cancelsBlockFresh = true
		case c.BroadcastAtUtc.Valid && !c.ConfirmedAtUtc.Valid:
			// Broadcast-unconfirmed cancel: poll via
			// cancel-specific verification. Fresh allocation
			// HALTS until confirmation (or operator abandon).
			if outcome := r.pollCancelOnce(ctx, runID, c); outcome == rowOutcomePaid {
				// confirmed during this cycle → don't HALT;
				// fresh allocation can proceed below (SPEC
				// §4.3 step 5 confirmed-cancel branch).
				continue
			}
			cancelsBlockFresh = true
		case c.ConfirmedAtUtc.Valid:
			// Confirmed cancel: nonce gap is filled — proceed
			// to fresh non-cancel allocation. SPEC §4.3 step 5
			// confirmed-cancel branch: do NOT call
			// ClaimPayoutReady (cancels do NOT consume
			// ledger_payout_ready); the
			// payout_cancel_self_transfer_confirmed INFO emit
			// is the responsibility of the transition cycle
			// (MarkConfirmedAtTx clears
			// cancel_reconfirm_stale_paged_at_utc). A
			// subsequently-loaded confirmed cancel here does
			// NOT re-emit per v0.1.15 round-16 MED-1 closure.
		}
	}
	if cancelsBlockFresh {
		return rowOutcomeSkipped, nil
	}

	// R2-HIGH (architect Option A): in recovery-only mode suppress ONLY
	// this terminal fresh-allocation call site. Every earlier branch
	// (claimAndLog, rebroadcastAndPoll, pollAndConfirm, cancel handling)
	// has already run unchanged above, so recovery rebroadcast + all
	// unrelated in-flight polls/confirms still progress this cycle — only
	// a FRESH nonce allocation past the unfilled hole is prevented.
	if r.recoveryOnly {
		return rowOutcomeSkipped, nil
	}

	// Fresh allocation (§4.3 step 5 — INSERT inside BEGIN IMMEDIATE).
	return r.allocateBuildSignBroadcast(ctx, runID, row, amount)
}

// rebroadcastAndPoll handles the SPEC §4.3 step 5 "persisted but
// unbroadcast" path: rebroadcast the byte-identical envelope on
// both RPCs (re-signing FORBIDDEN), stamp broadcast_at_utc on
// accept, then transition to pollAndConfirm. Closes
// [code:1.1] MAJOR.
func (r *Runner) rebroadcastAndPoll(ctx context.Context, conn *sql.Conn, runID string, row ReadyRow, attempt *AttemptRow) (rowOutcome, error) {
	if !attempt.TxHash.Valid || attempt.TxHash.String == "" {
		// Defensive: a row with raw_signed_tx but NULL or EMPTY tx_hash is
		// a SPEC violation and is NOT rebroadcastable. R2-LOW-2: this Go
		// precondition must match the round-1-tightened
		// rebroadcastableAttemptExists SQL (tx_hash IS NOT NULL AND
		// tx_hash <> ''); a malformed empty-hash row must fall through to
		// fail-closed here, never attempt a malformed rebroadcast. Surface
		// as invariant.
		r.emitInvariantViolation(row.PayoutID, "raw_signed_tx_without_hash", fmt.Sprintf("attempt_seq=%d", attempt.AttemptSeq))
		return rowOutcomeFailed, nil
	}
	// Post-COMMIT lease re-read before broadcast (mirrors §4.3 step 6).
	if err := SelfFence(ctx, r.opts.DB, r.state); err != nil {
		return rowOutcomeFailed, err
	}
	// FULL-r1 [full-code:r1-2] HIGH closure: defense-in-depth halt
	// gate before re-broadcasting persisted bytes — same rationale
	// as allocateBuildSignBroadcast. The bytes stay persisted; the
	// next non-halted cycle (post operator restart) will rebroadcast.
	if r.halted.Load() {
		return rowOutcomeSkipped, nil
	}
	acceptedAny, _, _, primErr, secErr := r.opts.RPCs.BroadcastBoth(ctx, attempt.RawSignedTx)
	if !acceptedAny {
		// Both rejected — leave broadcast_at_utc NULL; the next
		// cycle retries. M4-style nonce-collision check inline.
		if IsNonceTooLow(primErr) || IsNonceTooLow(secErr) {
			// Chain-serialized race: the prior holder already
			// broadcast these bytes (or a peer at the same
			// nonce did). Stamp broadcast_at_utc and proceed
			// to poll — the chain is the source of truth.
			now := r.opts.NowFn().UTC().Format(time.RFC3339Nano)
			_ = StampBroadcastAt(ctx, r.opts.DB, row.PayoutID, attempt.AttemptSeq, now)
			return r.pollAndConfirm(ctx, conn, runID, row, attempt)
		}
		r.opts.Logger.Warn().
			Err(primErr).
			Err(secErr).
			Int64("payout_id", row.PayoutID).
			Int("attempt_seq", attempt.AttemptSeq).
			Msg("persisted-bytes rebroadcast rejected by both RPCs (will retry next cycle)")
		return rowOutcomeFailed, nil
	}
	now := r.opts.NowFn().UTC().Format(time.RFC3339Nano)
	if err := StampBroadcastAt(ctx, r.opts.DB, row.PayoutID, attempt.AttemptSeq, now); err != nil {
		r.opts.Logger.Warn().Err(err).Msg("StampBroadcastAt failed after rebroadcast")
	}
	// Step 4 r7 [code:r7-1] HIGH closure: persisted bytes were
	// broadcast THIS cycle (the prior cycle stored them but never
	// stamped broadcast_at_utc). Money has now left the hot wallet
	// in this cycle, so deduct from runningBalance — subsequent
	// fresh rows in the same cycle must see the post-spend tally.
	r.deductPaidAmount(attempt.AmountBaseUnits)
	return r.pollAndConfirm(ctx, conn, runID, row, attempt)
}

// pollCancelOnce polls a broadcast-unconfirmed cancel row via
// cancel-specific §4.3 step 7 verification (tx.to == hot_wallet,
// no Transfer log, value == 1 wei). On confirmation it stamps
// confirmed_at_utc + block_number + gas_used_native_wei and
// emits payout_cancel_self_transfer_confirmed INFO per §7.1
// (v0.1.15 transition-only emission).
//
// Returns rowOutcomePaid on confirmation (semantic abuse — the
// outcome is just a signal that the cancel transitioned; the
// runner doesn't count it as a paid provider payout). Other
// outcomes mean "still pending" or "polling failed".
func (r *Runner) pollCancelOnce(ctx context.Context, runID string, cancel AttemptRow) rowOutcome {
	if !cancel.TxHash.Valid {
		return rowOutcomeFailed
	}
	txHash := cancel.TxHash.String
	recA, errA := r.opts.RPCs.Primary.TransactionReceipt(ctx, txHash)
	recB, errB := r.opts.RPCs.Secondary.TransactionReceipt(ctx, txHash)
	if errA != nil || errB != nil {
		return rowOutcomeFailed
	}
	if recA == nil || recB == nil {
		return rowOutcomeFailed
	}
	if !ReceiptsAgree(recA, recB) {
		r.emitRPCDisagreement(cancel.PayoutID, cancel.AttemptSeq, recA, recB)
		return rowOutcomeFailed
	}
	// FULL-r1 [full-code:r1-1] HIGH closure: SPEC §4.3 step 7
	// requires BOTH RPCs at depth >= ConfirmationBlocks. A lagging
	// secondary can return the same receipt before its own head is
	// deep enough; if we measured depth on the primary head only
	// we could mark cancel-confirmed using single-RPC depth.
	headPri, err := r.opts.RPCs.Primary.BlockNumber(ctx)
	if err != nil {
		return rowOutcomeFailed
	}
	headSec, err := r.opts.RPCs.Secondary.BlockNumber(ctx)
	if err != nil {
		return rowOutcomeFailed
	}
	conf := int64(r.snap().ConfirmationBlocks)
	if int64(headPri)-int64(recA.BlockNumber) < conf {
		return rowOutcomeFailed
	}
	if int64(headSec)-int64(recB.BlockNumber) < conf {
		return rowOutcomeFailed
	}
	if recA.Status != 1 {
		return rowOutcomeFailed
	}
	// Cancel-specific chain-side verification on BOTH receipts.
	// Closes codex round-2 [code:r2-2.1] MEDIUM: ReceiptsAgree
	// only compares tx_hash/block/status/to; it does NOT compare
	// log arrays, so a primary that fabricates an absent USDC
	// log while the secondary carries an unexpected one would
	// slip past a primary-only check.
	if !addressEqualFold(recA.To, r.opts.Security.HotWalletAddress) {
		r.emitChainValueMismatch(cancel.PayoutID, cancel.AttemptSeq, txHash, "cancel_self_transfer_mismatch",
			fmt.Sprintf("primary receipt.to=%s != hot_wallet", recA.To))
		return rowOutcomeFailed
	}
	if !addressEqualFold(recB.To, r.opts.Security.HotWalletAddress) {
		r.emitChainValueMismatch(cancel.PayoutID, cancel.AttemptSeq, txHash, "cancel_self_transfer_mismatch",
			fmt.Sprintf("secondary receipt.to=%s != hot_wallet", recB.To))
		return rowOutcomeFailed
	}
	usdcLower := strings.ToLower(USDCContractAddressBase)
	if hasUSDCTransferLog(recA, usdcLower) {
		r.emitChainValueMismatch(cancel.PayoutID, cancel.AttemptSeq, txHash, "cancel_self_transfer_mismatch",
			"primary: unexpected USDC Transfer log on cancel tx")
		return rowOutcomeFailed
	}
	if hasUSDCTransferLog(recB, usdcLower) {
		r.emitChainValueMismatch(cancel.PayoutID, cancel.AttemptSeq, txHash, "cancel_self_transfer_mismatch",
			"secondary: unexpected USDC Transfer log on cancel tx")
		return rowOutcomeFailed
	}
	// Cancel-specific tx-body verification per SPEC §4.3 step 7
	// (cancel branch): tx.value MUST be 1 wei, tx.input MUST be
	// empty, tx.to AND tx.from MUST equal hot_wallet, on BOTH
	// RPC views. Closes codex round-3 [code:r3-3.1] MEDIUM.
	txA, err := r.opts.RPCs.Primary.TransactionByHash(ctx, txHash)
	if err != nil || txA == nil {
		return rowOutcomeFailed
	}
	txB, err := r.opts.RPCs.Secondary.TransactionByHash(ctx, txHash)
	if err != nil || txB == nil {
		return rowOutcomeFailed
	}
	if err := verifyCancelTxView(txA, r.opts.Security.HotWalletAddress); err != nil {
		r.emitChainValueMismatch(cancel.PayoutID, cancel.AttemptSeq, txHash, "cancel_self_transfer_mismatch",
			"primary: "+err.Error())
		return rowOutcomeFailed
	}
	if err := verifyCancelTxView(txB, r.opts.Security.HotWalletAddress); err != nil {
		r.emitChainValueMismatch(cancel.PayoutID, cancel.AttemptSeq, txHash, "cancel_self_transfer_mismatch",
			"secondary: "+err.Error())
		return rowOutcomeFailed
	}
	now := r.opts.NowFn().UTC().Format(time.RFC3339Nano)
	rowsAffected, err := r.markConfirmedStandalone(ctx, cancel.PayoutID, cancel.AttemptSeq,
		int64(recA.BlockNumber), int64(recA.GasUsed), now)
	if err != nil || rowsAffected == 0 {
		return rowOutcomeFailed
	}
	// §7.1 transition-only INFO emit.
	r.opts.Logger.Info().
		Str("event", "payout_cancel_self_transfer_confirmed").
		Str("run_id", runID).
		Int64("payout_id", cancel.PayoutID).
		Int("attempt_seq", cancel.AttemptSeq).
		Int64("nonce", cancel.Nonce).
		Str("tx_hash", txHash).
		Uint64("block_number", recA.BlockNumber).
		Uint64("gas_used_native_wei", recA.GasUsed).
		Str("ts_utc", now).
		Send()
	return rowOutcomePaid
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
		// Step 4 r5 [code:r5-2] HIGH closure: SPEC §4.3 step 4 +
		// §7.1 line 3723 require payout_daily_cap_tripped (NOT
		// payout_capped) when the 24h window sum would exceed the
		// daily cap. RunOnce breaks the row loop on this outcome so
		// subsequent rows in the same cycle are skipped.
		// payout_capped is reserved for per-payout cap.
		r.opts.Logger.Warn().
			Str("event", "payout_daily_cap_tripped").
			Str("severity", "WARN").
			Str("run_id", runID).
			Int64("window_paid_usdc_base_units", committedSum).
			Int64("cap_usdc_base_units", r.opts.PerDayCapBaseUnits).
			Str("ts_utc", r.opts.NowFn().UTC().Format(time.RFC3339Nano)).
			Send()
		return rowOutcomeDailyCapTripped, nil
	}

	// Step 4 r6 [code:r6-1] HIGH closure: per-row hot-wallet USDC
	// balance check, performed AFTER per-payout-cap (caller in
	// processRow) + per-day-cap (above) + existing-attempt state
	// machine (caller) have all decided this row needs a fresh
	// transfer. SPEC §4.3 step 6-7 + §7.1 line 3722.
	//
	// The running balance is captured at the top of RunOnce; the
	// deduction for THIS fresh broadcast happens BELOW, immediately
	// after BroadcastBoth returns acceptedAny + StampBroadcastAt
	// persists (Step 4 r7 [code:r7-1] HIGH closure — only paths
	// that actually move money this cycle deduct; claim/poll paths
	// for prior-cycle spends don't). nil balance means the initial
	// RPC read failed; we fall through and let downstream
	// sign/broadcast surface the failure naturally.
	if running := r.hotWalletBalance(); running != nil {
		required := new(big.Int).SetInt64(amount)
		if running.Cmp(required) < 0 {
			r.opts.Logger.Error().
				Str("event", "payout_insufficient_funds").
				Str("severity", "PAGE").
				Str("run_id", runID).
				Int64("payout_id", row.PayoutID).
				Str("provider_id", row.ProviderID).
				Str("required_usdc_base_units", required.String()).
				Str("available_usdc_base_units", running.String()).
				Str("ts_utc", r.opts.NowFn().UTC().Format(time.RFC3339Nano)).
				Send()
			// No attempt row was inserted; the BEGIN IMMEDIATE txn
			// rolls back via the deferred ROLLBACK on `committed == false`.
			return rowOutcomeInsufficientFunds, nil
		}
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
			// §7.1 payout_signer_unavailable: from_address,
			// error_class, ts_utc.
			r.opts.Logger.Error().
				Str("event", "payout_signer_unavailable").
				Str("severity", "PAGE").
				Str("from_address", r.opts.Security.HotWalletAddress).
				Str("error_class", err.Error()).
				Str("ts_utc", r.opts.NowFn().UTC().Format(time.RFC3339Nano)).
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

	// FULL-r1 [full-code:r1-2] HIGH closure: defense-in-depth halt
	// gate immediately before the irreversible chain-write. The
	// COMMIT above persisted the attempt + bumped the nonce cursor,
	// but the chain-write (BroadcastBoth) has not happened yet; if
	// halt was requested in the post-COMMIT window we MUST NOT
	// broadcast. The unbroadcast row is reaped by §4.8c stale-CAS
	// once it ages out. Silent return — the row-loop top emit and
	// the prior PAGE event already make the halt visible.
	if r.halted.Load() {
		return rowOutcomeSkipped, nil
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

	// Step 4 r7 [code:r7-1] HIGH closure: chain has accepted the
	// fresh broadcast; the USDC transfer is now in flight. Deduct
	// from runningBalance so any subsequent fresh row in the same
	// cycle sees the post-spend tally without another RPC call.
	// Co-located with the spend EVENT, not with rowOutcomePaid
	// (which is overloaded — also returned by claim/poll paths
	// that reflect prior-cycle spends already in the top-of-cycle
	// balance read).
	r.deductPaidAmount(amount)

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

	// FULL-r2 [full-code:r2-1] HIGH closure: track an explicit
	// confirmedDepth bool. The r1 closure rewrote depth to read
	// both heads, but kept assigning recPri/recSec at the top of
	// every iteration. If the LAST iteration before deadline
	// returned non-nil but shallow receipts, the post-loop nil
	// guard at line 1243 fell through and markConfirmedStandalone
	// + ClaimPayoutReady marked paid on a shallow receipt —
	// regressing r1-1 and violating SPEC §4.3 step 7. The
	// confirmed receipts are now captured into recPri/recSec ONLY
	// inside the break path, and the post-loop guard refuses to
	// proceed when confirmedDepth is false.
	var recPri, recSec *Receipt
	confirmedDepth := false
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return rowOutcomeFailed, ctx.Err()
		default:
		}
		candidatePri, perrA := r.opts.RPCs.Primary.TransactionReceipt(ctx, txHash)
		candidateSec, perrB := r.opts.RPCs.Secondary.TransactionReceipt(ctx, txHash)
		if perrA == nil && perrB == nil && candidatePri != nil && candidateSec != nil {
			// FULL-r1 [full-code:r1-1] HIGH closure: SPEC §4.3
			// step 7 requires BOTH RPCs at depth >=
			// ConfirmationBlocks. Read both heads and gate on the
			// stricter (per-RPC) depth so a lagging secondary
			// cannot let a primary-deep receipt drive confirmation.
			headPri, errPri := r.opts.RPCs.Primary.BlockNumber(ctx)
			if errPri != nil {
				time.Sleep(r.opts.ReceiptPollInterval)
				continue
			}
			headSec, errSec := r.opts.RPCs.Secondary.BlockNumber(ctx)
			if errSec != nil {
				time.Sleep(r.opts.ReceiptPollInterval)
				continue
			}
			conf := int64(r.snap().ConfirmationBlocks)
			depthPri := int64(headPri) - int64(candidatePri.BlockNumber)
			depthSec := int64(headSec) - int64(candidateSec.BlockNumber)
			if depthPri >= conf && depthSec >= conf {
				recPri = candidatePri
				recSec = candidateSec
				confirmedDepth = true
				break
			}
		}
		time.Sleep(r.opts.ReceiptPollInterval)
	}
	if !confirmedDepth || recPri == nil || recSec == nil {
		// Treat as transient — leave row pending; next cycle re-polls.
		// confirmedDepth is the authority; the nil checks are defense-
		// in-depth.
		r.opts.Logger.Warn().
			Int64("payout_id", row.PayoutID).
			Str("tx_hash", txHash).
			Msg("receipt poll deadline expired without both-RPC depth; will retry next cycle")
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
	// Chain-side value verification (a, b, c) on BOTH receipts —
	// closes codex round-1 [sec:2.2] HIGH / [code:1.3] MEDIUM:
	// a malicious primary RPC can return a minimal receipt that
	// passes ReceiptsAgree while serving fabricated tx-by-hash
	// and log data; the secondary must independently confirm.
	if err := r.verifyChainSideTransfer(ctx, attempt, recPri, recSec); err != nil {
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
	// §4.3 step 8 — Claim. Carry block_number + nonce so the
	// §7.1 payout_paid emit includes them.
	freshAttempt := &AttemptRow{
		PayoutID:    row.PayoutID,
		AttemptSeq:  attempt.AttemptSeq,
		TxHash:      sql.NullString{String: txHash, Valid: true},
		BlockNumber: sql.NullInt64{Int64: int64(recPri.BlockNumber), Valid: true},
		Nonce:       attempt.Nonce,
	}
	_ = conn // future trigger-presence intra-tx check anchors here
	return r.claimAndLog(ctx, runID, row, freshAttempt)
}

// claimAndLog issues ClaimPayoutReady and emits payout_paid /
// payout_failed.
func (r *Runner) claimAndLog(ctx context.Context, runID string, row ReadyRow, attempt *AttemptRow) (rowOutcome, error) {
	// FULL-r1 [full-code:r1-2] HIGH closure: defense-in-depth halt
	// gate before ClaimPayoutReady. The chain has already confirmed
	// the transfer; if halt fires here we defer the billing-side
	// claim to a future cycle. The runner's confirmed row stays in
	// the DB and will be re-claimed once the operator clears the
	// halt (process restart).
	if r.halted.Load() {
		return rowOutcomeSkipped, nil
	}
	claimed, err := r.opts.Claimer.ClaimPayoutReady(ctx, row.PayoutID, row.GrossCredits, attempt.TxHash.String, "USDC-BASE")
	nowStr := r.opts.NowFn().UTC().Format(time.RFC3339Nano)
	if err != nil {
		// §7.1 payout_failed: run_id, payout_id, attempt_seq,
		// provider_id, stage, error_class, error_text, ts_utc.
		r.opts.Logger.Error().
			Str("event", "payout_failed").
			Str("severity", "PAGE").
			Str("run_id", runID).
			Int64("payout_id", row.PayoutID).
			Int("attempt_seq", attempt.AttemptSeq).
			Str("provider_id", row.ProviderID).
			Str("stage", "claim").
			Str("error_class", "claim_error").
			Str("error_text", err.Error()).
			Str("ts_utc", nowStr).
			Send()
		return rowOutcomeFailed, fmt.Errorf("ClaimPayoutReady: %w", err)
	}
	if !claimed {
		r.opts.Logger.Warn().
			Str("event", "payout_failed").
			Str("severity", "PAGE").
			Str("run_id", runID).
			Int64("payout_id", row.PayoutID).
			Int("attempt_seq", attempt.AttemptSeq).
			Str("provider_id", row.ProviderID).
			Str("stage", "claim").
			Str("error_class", "not_ready_or_amount_changed").
			Str("error_text", "").
			Str("ts_utc", nowStr).
			Send()
		return rowOutcomeFailed, nil
	}
	// §7.1 payout_paid: run_id, payout_id, attempt_seq,
	// provider_id, amount_usdc_base_units, tx_hash,
	// block_number, nonce, ts_utc.
	blockNumber := int64(0)
	if attempt.BlockNumber.Valid {
		blockNumber = attempt.BlockNumber.Int64
	}
	r.opts.Logger.Info().
		Str("event", "payout_paid").
		Str("run_id", runID).
		Int64("payout_id", row.PayoutID).
		Int("attempt_seq", attempt.AttemptSeq).
		Str("provider_id", row.ProviderID).
		Int64("amount_usdc_base_units", row.ProviderCredits).
		Str("tx_hash", attempt.TxHash.String).
		Int64("block_number", blockNumber).
		Int64("nonce", attempt.Nonce).
		Str("ts_utc", nowStr).
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
		MaxPriorityFeePerGas: big.NewInt(2_000_000_000),  // 2 gwei — production tuning lands in Step 4
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

// verifyChainSideTransfer implements §4.3 step 7 (a, b, c) on
// BOTH RPC receipts and BOTH eth_getTransactionByHash returns.
// Closes codex round-1 [sec:2.2] HIGH / [code:1.3] MEDIUM: a
// malicious primary RPC could pass ReceiptsAgree's minimal field
// set while serving fabricated tx-by-hash data + log arrays;
// independent verification on both sides defangs this.
func (r *Runner) verifyChainSideTransfer(ctx context.Context, attempt *AttemptRow, recA, recB *Receipt) error {
	usdcAddrLower := strings.ToLower(USDCContractAddressBase)
	if recA.To != usdcAddrLower {
		return fmt.Errorf("primary receipt.to %s != USDC %s", recA.To, usdcAddrLower)
	}
	if recB.To != usdcAddrLower {
		return fmt.Errorf("secondary receipt.to %s != USDC %s", recB.To, usdcAddrLower)
	}
	// (a) Fetch the full tx on BOTH RPCs and assert input
	// byte-equality on BOTH.
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
	if !bytes.Equal(txA.Input, want) {
		return errors.New("primary tx.input byte-mismatch")
	}
	if !bytes.Equal(txB.Input, want) {
		return errors.New("secondary tx.input byte-mismatch")
	}
	// (b) Both RPCs MUST agree tx.from == hot wallet.
	if !addressEqualFold(txA.From, r.opts.Security.HotWalletAddress) {
		return fmt.Errorf("primary tx.from %s != hot_wallet", txA.From)
	}
	if !addressEqualFold(txB.From, r.opts.Security.HotWalletAddress) {
		return fmt.Errorf("secondary tx.from %s != hot_wallet", txB.From)
	}
	if !addressEqualFold(txA.From, txB.From) {
		return fmt.Errorf("tx.from disagreement: primary=%s secondary=%s", txA.From, txB.From)
	}
	// (c) Exactly one Transfer log matching on BOTH receipts.
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
	if cnt := countMatchingTransferLog(recA, usdcAddrLower, transferTopic, hotTopic, toTopic, attempt.AmountBaseUnits); cnt != 1 {
		return fmt.Errorf("primary matching Transfer log count = %d, want 1", cnt)
	}
	if cnt := countMatchingTransferLog(recB, usdcAddrLower, transferTopic, hotTopic, toTopic, attempt.AmountBaseUnits); cnt != 1 {
		return fmt.Errorf("secondary matching Transfer log count = %d, want 1", cnt)
	}
	return nil
}

// verifyCancelTxView enforces the SPEC §4.3 cancel-branch tx-body
// invariants against ONE RPC's eth_getTransactionByHash response.
// Called for both primary + secondary in pollCancelOnce so the
// runner does not mark a cancel confirmed against a lying RPC
// that fabricated receipt-level fields. Closes codex round-3
// [code:r3-3.1] MEDIUM.
//
// Per SPEC §4.3 step 7 (cancel branch):
//   - tx.to MUST equal hot_wallet (NOT USDC contract)
//   - tx.value MUST equal 1 (one wei native self-transfer)
//   - tx.input MUST be empty
//   - tx.from MUST equal hot_wallet (sender = hot wallet)
func verifyCancelTxView(tx *Transaction, hotWalletAddress string) error {
	if !addressEqualFold(tx.To, hotWalletAddress) {
		return fmt.Errorf("tx.to %s != hot_wallet", tx.To)
	}
	if !addressEqualFold(tx.From, hotWalletAddress) {
		return fmt.Errorf("tx.from %s != hot_wallet", tx.From)
	}
	if len(tx.Input) != 0 {
		return fmt.Errorf("tx.input must be empty (got %d bytes)", len(tx.Input))
	}
	// tx.Value is the raw hex string from JSON-RPC ("0x1" expected).
	// Tolerate "0x01" / "0X1" via case-fold + leading-zero strip.
	v := strings.TrimPrefix(strings.ToLower(tx.Value), "0x")
	v = strings.TrimLeft(v, "0")
	if v != "1" {
		return fmt.Errorf("tx.value must be 0x1 wei (got %q)", tx.Value)
	}
	return nil
}

// hasUSDCTransferLog returns true iff the receipt carries any
// log against the USDC contract — used by the cancel-self-
// transfer verification to assert NO ERC-20 transfer occurred.
func hasUSDCTransferLog(receipt *Receipt, usdcAddrLower string) bool {
	for _, log := range receipt.Logs {
		if log.Address == usdcAddrLower {
			return true
		}
	}
	return false
}

// countMatchingTransferLog counts logs in receipt that match the
// canonical USDC Transfer signature with the expected from/to/amount.
func countMatchingTransferLog(receipt *Receipt, usdcAddrLower, transferTopic, hotTopic, toTopic string, amount int64) int {
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
		got := new(big.Int).SetBytes(log.Data)
		want := big.NewInt(amount)
		if got.Cmp(want) == 0 {
			matchCount++
		}
	}
	return matchCount
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

// emitBalanceAlerts reads the hot wallet's USDC + native balances
// from BOTH RPCs (primary only suffices for the threshold check —
// the chain-balance worker does the cross-RPC reconciliation). It
// emits §7.1 events when balances fall below the configured
// thresholds. Threshold == 0 disables that probe.
//
// This is the SPEC §6.2 monitoring surface; it is independent of
// the chain-balance worker (§7.4). The two are intentionally
// orthogonal: one is "we're running low on funds for upcoming
// payouts" (operational alert); the other is "the books don't
// match the chain" (incident-class drift detector).
func (r *Runner) emitBalanceAlerts(ctx context.Context, runID string, now time.Time, snap TuningSnapshot) {
	if snap.LowBalanceThreshold <= 0 && snap.LowNativeThreshold <= 0 {
		return
	}
	hotLower := strings.ToLower(r.opts.Security.HotWalletAddress)

	if snap.LowBalanceThreshold > 0 {
		data := usdcBalanceCalldata(hotLower)
		res, err := r.opts.RPCs.Primary.CallContract(ctx, USDCContractAddressBase, data)
		if err != nil {
			r.opts.Logger.Warn().Err(err).
				Str("event", "payout_balance_probe_rpc_error").
				Str("probe", "usdc").
				Str("run_id", runID).Send()
		} else if bal, ok := parseBalanceResult(res); ok {
			threshold := new(big.Int).SetInt64(snap.LowBalanceThreshold)
			if bal.Cmp(threshold) < 0 {
				// Step 4 r2 [code:r2-4] MEDIUM closure: §7.1 field
				// names — from_address, usdc_base_units,
				// threshold_usdc_base_units (was hot_wallet /
				// balance_usdc_base_units / threshold).
				r.opts.Logger.Warn().
					Str("event", "payout_low_balance").
					Str("severity", "WARN").
					Str("from_address", hotLower).
					Str("usdc_base_units", bal.String()).
					Int64("threshold_usdc_base_units", snap.LowBalanceThreshold).
					Str("run_id", runID).
					Str("ts_utc", now.UTC().Format(time.RFC3339Nano)).Send()
			}
		}
	}

	if snap.LowNativeThreshold > 0 {
		bal, err := r.opts.RPCs.Primary.NativeBalance(ctx, hotLower)
		if err != nil {
			r.opts.Logger.Warn().Err(err).
				Str("event", "payout_balance_probe_rpc_error").
				Str("probe", "native").
				Str("run_id", runID).Send()
		} else if bal < uint64(snap.LowNativeThreshold) {
			// Step 4 r2 [code:r2-4] MEDIUM closure: §7.1 field names
			// — from_address, native_wei, threshold_wei (was
			// hot_wallet / balance_wei / threshold_wei).
			r.opts.Logger.Warn().
				Str("event", "payout_low_native_balance").
				Str("severity", "WARN").
				Str("from_address", hotLower).
				Uint64("native_wei", bal).
				Int64("threshold_wei", snap.LowNativeThreshold).
				Str("run_id", runID).
				Str("ts_utc", now.UTC().Format(time.RFC3339Nano)).Send()
		}
	}
}
