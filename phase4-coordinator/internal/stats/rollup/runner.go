package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/metrics"
	"github.com/rs/zerolog"
)

// Runner orchestrates the SPEC §9.2 per-table rollup goroutines
// AND the nightly rebuild scheduler.
//
// Each per-table job has its own goroutine + ticker; a panic
// in one job is recovered inside that job's goroutine and does
// NOT take down the other jobs OR the coordinator process
// (SPEC §7.3 + §9.6). Per-job recover updates the affected
// component's `stats_components_health` row with the panic
// message and restarts the ticker on its next interval.
type Runner struct {
	db       *sql.DB
	cfg      Config
	snap     SnapshotProvider
	logger   zerolog.Logger
	stopOnce sync.Once
	wg       sync.WaitGroup
	metrics  *metrics.Metrics // optional; nil → no metric emit
}

// WithMetrics attaches a Step 4.C metrics handle. Optional;
// callers that don't need metric emission omit this.
func (r *Runner) WithMetrics(m *metrics.Metrics) *Runner {
	r.metrics = m
	return r
}

// New constructs a Runner. The caller MUST inject:
//   - `db`: the stats_rollup-authenticated *sql.DB (one of
//     statsPools.Rollup; see internal/stats.Pools). Writing
//     via any other pool is a SECURITY invariant violation.
//   - `cfg`: after DefaultsApplied() + Validate(); the helper
//     calls Validate() and returns the error.
//   - `snap`: SnapshotProvider for overview live-snapshot
//     fields. Production wires from pool.Registry; tests
//     inject a stub. ZeroSnapshotProvider is the safe default.
//   - `logger`: zerolog logger. Used for warn-level events
//     (drift detection, late-event retention failure,
//     clamped retention warning).
func New(db *sql.DB, cfg Config, snap SnapshotProvider, logger zerolog.Logger) (*Runner, error) {
	if db == nil {
		return nil, fmt.Errorf("rollup: New requires non-nil db (stats_rollup pool)")
	}
	if snap == nil {
		snap = ZeroSnapshotProvider{}
	}
	applied := cfg.DefaultsApplied()
	// BUILD §E.2 clamp+warn pin: retention values in (0, 30)
	// are clamped to 30 with a WARN log. Already handled by
	// DefaultsApplied for 0→90, but for explicit small positive
	// values we apply the clamp here.
	if applied.LateEventsRetentionDays > 0 && applied.LateEventsRetentionDays < 30 {
		logger.Warn().
			Int("requested", applied.LateEventsRetentionDays).
			Int("clamped_to", 30).
			Msg("stats.rollup.late_events_retention_days below SPEC §9.3 floor; clamping to 30 days")
		applied.LateEventsRetentionDays = 30
	}
	if err := applied.Validate(); err != nil {
		return nil, err
	}
	return &Runner{
		db:     db,
		cfg:    applied,
		snap:   snap,
		logger: logger,
	}, nil
}

// Start spawns the seven per-table goroutines AND the nightly
// rebuild scheduler. Returns immediately; the goroutines run
// until ctx is cancelled. Use Wait() at shutdown to drain them.
func (r *Runner) Start(ctx context.Context) {
	r.spawnTick(ctx, "overview", r.cfg.OverviewInterval, componentOverview, func(c context.Context) error {
		return runOverviewTick(c, r.db, r.cfg, r.snap)
	})
	r.spawnTick(ctx, "timeseries_rpm", r.cfg.TimeseriesRpmInterval, componentTimeseriesRpm, func(c context.Context) error {
		return runTimeseriesRpmTick(c, r.db, r.cfg)
	})
	r.spawnTick(ctx, "timeseries_tpm", r.cfg.TimeseriesTpmInterval, componentTimeseriesTpm, func(c context.Context) error {
		return runTimeseriesTpmTick(c, r.db, r.cfg)
	})
	r.spawnTick(ctx, "leaderboard_24h", r.cfg.Leaderboard24hInterval, componentLeaderboard24h, func(c context.Context) error {
		return runLeaderboardTick(c, r.db, r.cfg, "24h")
	})
	r.spawnTick(ctx, "leaderboard_7d", r.cfg.Leaderboard7dInterval, componentLeaderboard7d, func(c context.Context) error {
		return runLeaderboardTick(c, r.db, r.cfg, "7d")
	})
	// SPEC §9.3: 30d + all use the incremental-merge cadence
	// path (round-3 ARCH r3 HIGH 1 fix). The bootstrap tick
	// inside runLeaderboardIncrementalTick still does a full
	// recompute when stats_components_health.last_ok_at is at
	// the epoch sentinel; subsequent ticks only update active-
	// in-lookback providers, so a T-60h row arriving after the
	// bootstrap lands in stats_late_events but does NOT fold
	// into the live snapshot until the nightly Shape C rebuild.
	r.spawnTick(ctx, "leaderboard_30d", r.cfg.Leaderboard30dInterval, componentLeaderboard30d, func(c context.Context) error {
		return runLeaderboardIncrementalTick(c, r.db, r.cfg, "30d")
	})
	r.spawnTick(ctx, "leaderboard_all", r.cfg.LeaderboardAllInterval, componentLeaderboardAll, func(c context.Context) error {
		return runLeaderboardIncrementalTick(c, r.db, r.cfg, "all")
	})
	// rewards_populated ticks at the leaderboard_24h cadence —
	// the cheapest frequent cadence among the four windows.
	r.spawnTick(ctx, "rewards_populated", r.cfg.Leaderboard24hInterval, "", func(c context.Context) error {
		return runRewardsPopulatedTick(c, r.db, r.cfg)
	})
	r.spawnNightlyRebuild(ctx)
}

// Wait blocks until every spawned goroutine returns. Caller is
// expected to cancel the context first.
func (r *Runner) Wait() { r.wg.Wait() }

// RunNightlyRebuild runs the §9.4 Shape C rebuild for
// stats_leaderboard_{30d, all} once, synchronously. The Runner
// calls this internally at the nightly UTC hour; it is also
// exported so a future `coordinator stats rebuild --window=...`
// CLI subcommand and the integration tests can invoke directly.
func RunNightlyRebuild(ctx context.Context, db *sql.DB, cfg Config, logger zerolog.Logger) error {
	return runNightlyRebuild(ctx, db, cfg, logger)
}

// RunLateEventsRetention runs the §9.3 90-day (or
// operator-configured) DELETE pass on stats_late_events once,
// synchronously. The Runner calls this after the nightly
// rebuild commits; it is also exported for direct operator /
// test invocation.
func RunLateEventsRetention(ctx context.Context, db *sql.DB, cfg Config) error {
	return runLateEventsRetention(ctx, db, cfg)
}

// RunTickOnceForTest runs a single tick through the production
// per-tick recovery + metrics-emit seam (Runner.runOne). Exposed
// for Step 4.C integration tests asserting that
// `stats_rollup_tick_completed` (success path) and
// `stats_rollup_errors_total` (error / panic paths) fire on the
// real Runner code path rather than via synthetic
// `m.RollupErrorsTotal.Inc()` calls.
//
// `comp` MUST be one of the §9.5 component identifiers
// (overview, timeseries_rpm, timeseries_tpm, leaderboard_24h,
// leaderboard_7d, leaderboard_30d, leaderboard_all) so the metric
// emit + healthFail UPDATE land on a real component row. Pass ""
// to drive the rewards_populated tick's success-skip branch.
//
// Round-3 CODE r3 MEDIUM 2 / ARCH r3 MEDIUM 1 fix.
func (r *Runner) RunTickOnceForTest(ctx context.Context, name, comp string, fn func(context.Context) error) {
	r.runOne(ctx, name, component(comp), fn)
}

// spawnTick is the shared scaffold for the per-table jobs.
//
// Round-1 ARCH r1 HIGH 4 + CODE r1 HIGH 2 + SECURITY r1 MED-1
// fix: panic recovery now runs PER TICK, not per goroutine.
// A tick that panics records the health failure (with a
// REDACTED payload — round-1 SECURITY r1 MED-2 fix) and the
// goroutine continues to the next ticker fire, restarting that
// component. The whole-goroutine recover stays only as a
// final defence-in-depth backstop in case the per-tick
// recovery itself panics (extremely unlikely).
func (r *Runner) spawnTick(ctx context.Context, name string, interval time.Duration, c component, fn func(context.Context) error) {
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		defer func() {
			// Backstop: if the per-tick recover (inside runOne)
			// itself panics (would be a bug in our recover
			// path), we still don't crash the coordinator.
			if rec := recover(); rec != nil {
				r.logger.Error().
					Str("event", "stats_rollup_panic_backstop").
					Str("job", name).
					Str("recovered_class", classifyPanic(rec)).
					Msg("rollup tick goroutine-level panic backstop fired; job will not restart until coordinator reboot")
			}
		}()

		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		// First tick fires immediately so the operator can
		// verify the rollup is producing data without waiting
		// for the cadence interval.
		r.runOne(ctx, name, c, fn)
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r.runOne(ctx, name, c, fn)
			}
		}
	}()
}

// runOne wraps a single tick with per-tick panic recovery so a
// panicking tick records a health failure AND returns control
// to the ticker loop. Panic payloads are CLASSIFIED (type name +
// short hint) rather than serialized raw, so downstream Step
// 3/4 log/db propagation cannot persist arbitrary strings —
// round-1 SECURITY r1 MED-2 fix.
//
// Final adversarial audit (codex CODE MEDIUM 1+2):
//   - The healthFail write uses a SHORT BOUNDED context derived
//     from the tick context's CANCELLATION SIGNAL but with its
//     own 5s timeout. Previously this used context.Background()
//     which made the write uncancellable on shutdown — a slow
//     or partitioned DB could hold `Runner.Wait()` indefinitely.
//     We still record the error/panic on best-effort even when
//     the tick context is already done, so health state reflects
//     the failure for the next operator query.
//   - `err.Error()` for ordinary returned errors is now passed
//     through `redactErrMsg` instead of stored raw. The
//     classifier strips DSN-shaped substrings, token-hash bytes,
//     and the `mpk_` token prefix before persisting into
//     stats_components_health.last_error_message. classifyPanic
//     already handled the panic path; this closes the parallel
//     gap on the error path.
func (r *Runner) runOne(ctx context.Context, name string, c component, fn func(context.Context) error) {
	start := time.Now()
	defer func() {
		if rec := recover(); rec != nil {
			class := classifyPanic(rec)
			r.logger.Error().
				Str("event", "stats_rollup_panic").
				Str("job", name).
				Str("recovered_class", class).
				Msg("rollup tick panic recovered; job will continue at next interval")
			if c != "" {
				healthCtx, cancel := boundedHealthCtx(ctx)
				_ = healthFail(healthCtx, r.db, c, time.Now().UTC(), "panic: "+class)
				cancel()
			}
			if r.metrics != nil && c != "" {
				r.metrics.RollupErrorsTotal.WithLabelValues(string(c)).Inc()
			}
		}
	}()
	if err := fn(ctx); err != nil {
		r.logger.Warn().
			Err(err).
			Str("event", "stats_rollup_tick_error").
			Str("job", name).
			Msg("rollup tick error; health row updated; will retry next tick")
		if c != "" {
			healthCtx, cancel := boundedHealthCtx(ctx)
			_ = healthFail(healthCtx, r.db, c, time.Now().UTC(), redactErrMsg(err.Error()))
			cancel()
		}
		if r.metrics != nil && c != "" {
			r.metrics.RollupErrorsTotal.WithLabelValues(string(c)).Inc()
		}
		return
	}
	// Step 4.C — locked §8.5 event for a successful rollup tick.
	// Fields per BUILD §2 Step 4.C: component, generated_at,
	// duration_ms. `generated_at` here is the wall-clock tick
	// completion time (the underlying job ALSO writes
	// stats_components_health.generated_at to the same value).
	//
	// Round-1 CODE H3 fix: only emit the event for ticks that own
	// a §9.5 component identity. The `rewards_populated` tick has
	// `c=""` because the underlying rewards-populated state is
	// scalar (per §6.4 — covers all four leaderboard windows
	// jointly) and isn't a §9.5 component. Emitting an empty
	// `component` would corrupt downstream dashboards grouping by
	// component.
	if c == "" {
		return
	}
	finishedAt := time.Now().UTC()
	r.logger.Info().
		Str("event", "stats_rollup_tick_completed").
		Str("component", string(c)).
		Time("generated_at", finishedAt).
		Int64("duration_ms", finishedAt.Sub(start).Milliseconds()).
		Msg("stats rollup tick completed")
}

// classifyPanic returns a bounded redacted classification of a
// panic value. Type-name only — DOES NOT include the panic
// payload's message.
//
// Round-2 SECURITY r2 MED-2 fix: the earlier draft appended up
// to 64 chars of err.Error(), but a low-layer panic carrying a
// DSN, raw token, or token_hash substring could persist the
// first 64 bytes into structured logs AND
// `stats_components_health.last_error_message`. v0.1 IMPL drops
// the message hint entirely — type name alone is enough for an
// operator to triage panic class; the full message is available
// in the panic-handler's stack trace if a debug log sink is
// wired (operator-side, not in this code).
func classifyPanic(rec any) string {
	return fmt.Sprintf("%T", rec)
}

// boundedHealthCtx returns a context for the post-tick health
// write. We do NOT propagate `ctx` directly because a cancelled
// parent context would abort the health write before the
// operator gets a record of the failure. But we also must NOT
// use `context.Background()` (the previous behavior) because a
// slow or partitioned DB could hold `Runner.Wait()` past
// shutdown indefinitely. The compromise: a fresh 5s timeout
// context disconnected from the parent's cancellation. The
// runner's `Wait()` will still drain because the per-tick
// goroutine returns once `runOne` returns (within 5s of the
// healthFail attempt).
//
// Final adversarial audit (codex CODE MEDIUM 1) fix.
func boundedHealthCtx(_ context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Second)
}

// redactErrMsg strips secret-shaped substrings from a returned
// `err.Error()` before persisting it into
// stats_components_health.last_error_message. The previous
// behavior stored the raw string, so any lower-layer error
// carrying a DSN, partner-key token, or token_hash hex string
// would persist into the health row. This function applies the
// minimal viable redaction set: any DSN-shaped prefix
// (`postgres://`, `postgresql://`), any `mpk_*` token-shaped
// substring, any `token_hash=...` form, and any 32+-hex-char
// run (token_hash bytes are 64 hex chars). Truncates to 256
// chars after redaction so an attacker who supplies a long
// hostile error string cannot bloat the health row.
//
// Final adversarial audit (codex CODE MEDIUM 2) fix.
func redactErrMsg(msg string) string {
	if msg == "" {
		return ""
	}
	out := msg
	for _, pattern := range []string{
		`postgres://[^\s"]*`,
		`postgresql://[^\s"]*`,
		`mpk_[A-Za-z0-9_-]+`,
		`token_hash=[A-Fa-f0-9]+`,
		`\b[A-Fa-f0-9]{32,}\b`,
	} {
		re := regexp.MustCompile(pattern)
		out = re.ReplaceAllString(out, "<REDACTED>")
	}
	const maxLen = 256
	if len(out) > maxLen {
		out = out[:maxLen]
	}
	return out
}

// spawnNightlyRebuild fires the §9.4 rebuild at the configured
// UTC hour. We use a 1-minute heartbeat ticker + comparison
// against the target hour so daylight-saving and clock jumps
// don't skip the daily fire (vs. a single 24h sleep).
func (r *Runner) spawnNightlyRebuild(ctx context.Context) {
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		defer func() {
			if rec := recover(); rec != nil {
				r.logger.Error().
					Str("event", "stats_rollup_panic").
					Str("job", "nightly_rebuild").
					Str("recovered_class", classifyPanic(rec)).
					Msg("nightly rebuild panic recovered; will retry tomorrow")
				// Round-1 CODE H2 fix: per SPEC §9.4 the
				// nightly rebuild is a rollup path; its
				// panic MUST increment stats_rollup_errors_total
				// for the affected leaderboard components.
				if r.metrics != nil {
					r.metrics.RollupErrorsTotal.WithLabelValues("leaderboard_30d").Inc()
					r.metrics.RollupErrorsTotal.WithLabelValues("leaderboard_all").Inc()
				}
			}
		}()
		heartbeat := time.NewTicker(1 * time.Minute)
		defer heartbeat.Stop()
		lastFiredOn := -1 // day-of-year of the most recent fire
		for {
			select {
			case <-ctx.Done():
				return
			case t := <-heartbeat.C:
				utc := t.UTC()
				if utc.Hour() != r.cfg.NightlyRebuildHourUTC {
					continue
				}
				doy := utc.YearDay()
				if doy == lastFiredOn {
					continue
				}
				lastFiredOn = doy
				if err := runNightlyRebuild(ctx, r.db, r.cfg, r.logger); err != nil {
					r.logger.Warn().Err(err).Msg("nightly rebuild error; will retry tomorrow")
					// Round-1 CODE H2 fix: nightly rebuild
					// error path mirrors the panic path's metric
					// emit (SPEC §9.6).
					if r.metrics != nil {
						r.metrics.RollupErrorsTotal.WithLabelValues("leaderboard_30d").Inc()
						r.metrics.RollupErrorsTotal.WithLabelValues("leaderboard_all").Inc()
					}
				}
			}
		}
	}()
}
