package payout

import (
	"context"
	"database/sql"
	"errors"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// Reaper runs two background loops at payout.tuning.run_interval:
//
//  1. §4.8a runtime_flag_audit reaper — scans for audit rows
//     committed > 5 minutes ago with emitted_to_log = 0, CAS-
//     claims them, emits the §7.1 flip event AND increments the
//     payout_flag_audit_reaped (WARN) counter per row.
//
//  2. §4.8c cancel_reconfirm_stale_outbox reaper — scans for
//     outbox rows whose stale_started_at_utc is older than
//     3 × run_interval, CAS-claims them, and emits
//     payout_cancel_self_transfer_reconfirm_stale (PAGE) once per
//     stale period (the UNIQUE(payout_id, attempt_seq,
//     stale_started_at_utc) constraint enforces single-emit at
//     the DB layer; the CAS protects against the late sync-emit
//     vs reaper race).
//
// Both loops share the same Runner.Stop bool-returns pattern from
// Step 2 — Stop(ctx) blocks until either the current loop tick
// completes (clean exit, true) or ctx.Done() fires (timeout,
// false). main.go uses the bool to decide whether the lease-style
// release is safe; for the reaper there is no lease to release,
// but the same shape keeps shutdown wiring uniform.
type Reaper struct {
	db          *sql.DB
	pauseSvc    *PauseResumeService
	tickEvery   time.Duration
	staleAge    time.Duration   // fallback when tuning == nil
	tuning      *TuningProvider // §6.5 SIGHUP-reloadable; staleAge = 3×RunInterval at each ReapOnce
	log         zerolog.Logger
	nowFn       func() time.Time
	mu          sync.Mutex
	cancel      context.CancelFunc
	done        chan struct{}
	started     bool
	stopOnce    sync.Once
	stopWasFast bool
}

// currentStaleAge returns the live cancel-reconfirm stale cutoff.
// When TuningProvider is wired, returns 3 × RunInterval from the
// §6.5 atomic snapshot. When nil, returns the static staleAge field.
// Step 4 r1 [arch:4.2] closure: SIGHUP-changed RunInterval lands in
// the next ReapOnce without a process restart for the stale-age
// CHECK; the ticker cadence (tickEvery) is captured at Start and
// requires restart to change (documented limitation).
func (r *Reaper) currentStaleAge() time.Duration {
	if r.tuning != nil {
		return 3 * r.tuning.Snapshot().RunInterval
	}
	return r.staleAge
}

// ReaperOptions bundles dependencies.
type ReaperOptions struct {
	DB       *sql.DB
	PauseSvc *PauseResumeService
	// TickEvery is the loop cadence — payout.tuning.run_interval.
	// Tested with smaller values; production is in the [5m, 24h]
	// range per SPEC §6.5. Captured at Start; SIGHUP changes to
	// run_interval do NOT change the ticker cadence until restart
	// (Step 4 r1 [arch:4.2] documented limitation).
	TickEvery time.Duration
	// StaleAge is the cancel-reconfirm stale cutoff —
	// 3 × payout.tuning.run_interval per §4.7. Used as fallback
	// when Tuning is nil; otherwise the per-cycle ReapOnce reads
	// 3 × Tuning.Snapshot().RunInterval.
	StaleAge time.Duration
	// Tuning is the §6.5 SIGHUP-reloadable snapshot provider.
	// Step 4 r1 [arch:4.2] closure.
	Tuning *TuningProvider
	Logger zerolog.Logger
	NowFn  func() time.Time
}

// NewReaper constructs a stopped Reaper. Call Start(ctx) to launch
// the background loops, Stop(ctx) to wind them down.
func NewReaper(opts ReaperOptions) (*Reaper, error) {
	if opts.DB == nil {
		return nil, errors.New("payout.NewReaper: DB required")
	}
	if opts.PauseSvc == nil {
		return nil, errors.New("payout.NewReaper: PauseSvc required")
	}
	if opts.TickEvery <= 0 {
		return nil, errors.New("payout.NewReaper: TickEvery must be positive")
	}
	if opts.StaleAge <= 0 {
		return nil, errors.New("payout.NewReaper: StaleAge must be positive")
	}
	nowFn := opts.NowFn
	if nowFn == nil {
		nowFn = time.Now
	}
	return &Reaper{
		db:        opts.DB,
		pauseSvc:  opts.PauseSvc,
		tickEvery: opts.TickEvery,
		staleAge:  opts.StaleAge,
		tuning:    opts.Tuning,
		log:       opts.Logger,
		nowFn:     nowFn,
		done:      make(chan struct{}),
	}, nil
}

// Start launches the background loop. ctx controls the outer
// lifetime; Stop signals an inner cancel that interleaves with
// ctx cancellation. Idempotent — repeat calls are a no-op.
func (r *Reaper) Start(ctx context.Context) {
	r.mu.Lock()
	if r.started {
		r.mu.Unlock()
		return
	}
	innerCtx, cancel := context.WithCancel(ctx)
	r.cancel = cancel
	r.started = true
	r.mu.Unlock()

	go func() {
		defer close(r.done)
		ticker := time.NewTicker(r.tickEvery)
		defer ticker.Stop()
		// Eager first pass so a cold start with an orphaned audit
		// row from a prior crash reaps inside the first tick.
		r.runOnce(innerCtx)
		for {
			select {
			case <-innerCtx.Done():
				return
			case <-ticker.C:
				r.runOnce(innerCtx)
			}
		}
	}()
}

// Stop signals the loop to exit and waits up to ctx.Done() for it
// to finish the current tick. Returns true on clean exit, false
// on ctx timeout (mirrors Runner.Stop from Step 2).
func (r *Reaper) Stop(ctx context.Context) bool {
	r.mu.Lock()
	if !r.started {
		r.mu.Unlock()
		return true
	}
	r.mu.Unlock()
	r.stopOnce.Do(func() {
		r.cancel()
	})
	select {
	case <-r.done:
		r.stopWasFast = true
		return true
	case <-ctx.Done():
		return false
	}
}

// runOnce performs ONE pass over both outbox tables.
func (r *Reaper) runOnce(ctx context.Context) {
	// §4.8a runtime_flag_audit reaper.
	if reaped, err := r.pauseSvc.ReapOnce(ctx); err != nil {
		r.log.Error().Err(err).
			Str("event", "payout_flag_audit_reaper_failed").Send()
	} else if reaped > 0 {
		r.log.Info().
			Str("event", "payout_flag_audit_reaper_pass").
			Int("reaped", reaped).Send()
	}

	// §4.8c cancel_reconfirm_stale_outbox reaper. Per-row
	// payout_stale_outbox_reaped emits happen inside the claim
	// callback; we don't emit a separate aggregate event so the
	// §7.1 field set lands on the per-row event.
	if _, err := r.reapStaleOutbox(ctx); err != nil {
		r.log.Error().Err(err).
			Str("event", "payout_stale_outbox_reaper_failed").Send()
	}
}

// reapStaleOutbox scans for outbox rows older than staleAge and
// CAS-claims+emits each one. Returns the count of successfully
// reaped rows.
func (r *Reaper) reapStaleOutbox(ctx context.Context) (int, error) {
	cutoff := r.nowFn().Add(-r.currentStaleAge())
	rows, err := ListUnemittedStaleOutboxOlderThan(ctx, r.db, cutoff)
	if err != nil {
		return 0, err
	}
	reaped := 0
	for _, row := range rows {
		if ctx.Err() != nil {
			return reaped, ctx.Err()
		}
		err := ClaimAndEmitStaleOutbox(ctx, r.db, row.ID, func(row StaleOutboxRow) {
			// Codex Step 3 r1 [code:1.3] MEDIUM closure +
			// Step 3 r2 [arch:r2-3.3] MEDIUM closure: emit the
			// full §7.1 field set (event_id + run_id +
			// updated_at_utc + ts_utc on the PAGE event;
			// updated_at_utc maps to reorg_reactivated_at_utc
			// which is the SPEC §4.8c column name).
			tsUTC := r.nowFn().UTC().Format(time.RFC3339Nano)
			r.log.Error().
				Str("event", "payout_cancel_self_transfer_reconfirm_stale").
				Int64("event_id", row.ID).
				Str("run_id", row.RunID).
				Int64("payout_id", row.PayoutID).
				Int("attempt_seq", row.AttemptSeq).
				Str("stale_started_at_utc", row.StaleStartedAtUTC).
				Int64("nonce", row.Nonce).
				Str("tx_hash", row.TxHash).
				Uint64("last_seen_block", row.LastSeenBlock).
				Str("reorg_reactivated_at_utc", row.ReorgReactivatedAtUTC).
				Str("updated_at_utc", row.ReorgReactivatedAtUTC).
				Str("ts_utc", tsUTC).
				Str("severity", "PAGE").Send()
			// Per-row WARN counter event with field set per
			// §7.1 (codex Step 3 r1 [code:1.3] MEDIUM closure).
			staleStarted, _ := time.Parse(time.RFC3339Nano, row.StaleStartedAtUTC)
			lagSec := int64(0)
			if !staleStarted.IsZero() {
				lagSec = int64(r.nowFn().Sub(staleStarted).Seconds())
			}
			r.log.Warn().
				Str("event", "payout_stale_outbox_reaped").
				Int64("event_id", row.ID).
				Int64("payout_id", row.PayoutID).
				Int("attempt_seq", row.AttemptSeq).
				Str("stale_started_at_utc", row.StaleStartedAtUTC).
				Int64("reap_lag_seconds", lagSec).
				Str("ts_utc", tsUTC).
				Str("severity", "WARN").Send()
			reaped++
		})
		if err != nil {
			r.log.Error().Err(err).
				Int64("outbox_id", row.ID).
				Str("event", "payout_stale_outbox_claim_failed").Send()
		}
	}
	return reaped, nil
}
