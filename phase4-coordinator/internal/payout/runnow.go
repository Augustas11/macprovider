package payout

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

// runnerExecutor is the narrow surface RunNowController needs from
// *Runner. Declared as an interface so tests can inject a fakeRunner
// that forces RunOnce to return ErrRunnerHalted without needing a
// real runner lifecycle.
//
// Step 4 r3 [code:r3-4] MEDIUM closure: the prior tests could not
// exercise the post-RunOnce ErrRunnerHalted race path because
// *Runner exposes IsHalted atomically; a fake lets tests force the
// "IsHalted=false at admission, but RunOnce returns ErrRunnerHalted"
// scenario deterministically.
type runnerExecutor interface {
	IsHalted() bool
	HaltReason() string
	RunOnce(ctx context.Context) (string, error)
}

// RunNowController centralises the §4.2 admin run-now contract:
// rate-limit by payout.tuning.run_now_min_interval, emit
// payout_run_now_invoked on EVERY invocation outcome (accepted,
// rate_limited, runner_halted, cycle_in_flight_or_failed), and gate
// on Runner.IsHalted.
//
// Step 4 r2 [code:r2-1]/[sec:r2-1]/[arch:r2-4.1] CONVERGENT MAJOR
// closure: the previous Step2/3/4 mux handlers each duplicated the
// same IsHalted + RunOnce sequence without reading RunNowMinInterval
// or emitting payout_run_now_invoked. This centralised controller
// closes all three lanes simultaneously.
type RunNowController struct {
	runner           *Runner
	tuning           *TuningProvider
	log              zerolog.Logger
	nowFn            func() time.Time
	fallbackInterval time.Duration // used when tuning is nil (test path)

	// runnerExec holds the injectable runner for test paths.
	// nil = use c.runner directly (production). Set by tests.
	runnerExec runnerExecutor

	mu           sync.Mutex
	lastAccepted time.Time
}

// NewRunNowController constructs a RunNowController. runner and log
// are required. tuning may be nil (test path — fallbackInterval is
// used instead). fallbackInterval is the minimum interval to enforce
// when tuning is nil; 60s is the SPEC §6.5 lower bound for
// run_now_min_interval.
func NewRunNowController(
	runner *Runner,
	tuning *TuningProvider,
	fallbackInterval time.Duration,
	log zerolog.Logger,
) (*RunNowController, error) {
	if runner == nil {
		return nil, errors.New("RunNowController: runner is required")
	}
	c := &RunNowController{
		runner:           runner,
		tuning:           tuning,
		log:              log,
		nowFn:            func() time.Time { return time.Now().UTC() },
		fallbackInterval: fallbackInterval,
	}
	return c, nil
}

// execOrRunner returns the injectable executor when set (test path),
// otherwise falls back to the concrete *Runner (production path).
func (c *RunNowController) execOrRunner() runnerExecutor {
	if c.runnerExec != nil {
		return c.runnerExec
	}
	return c.runner
}

// currentInterval returns the live RunNowMinInterval from the tuning
// provider snapshot. Falls back to the construction-time fallback
// value when tuning is nil (test path).
func (c *RunNowController) currentInterval() time.Duration {
	if c.tuning != nil {
		return c.tuning.Snapshot().RunNowMinInterval
	}
	return c.fallbackInterval
}

// emitRunNowInvoked emits the §7.1 payout_run_now_invoked event.
// Called on every path including 429 and 409 — SPEC §7.1 line ~3716
// requires the event for EVERY invocation outcome.
// actor is the operator_key identifier from the authenticated request.
//
// Note: outcome is an additional field beyond the SPEC §7.1 minimum
// (run_id, actor, ts_utc). It is added defensively so operators can
// distinguish outcomes in their log aggregator. Flagged for the next
// audit if the strict §7.1 field set must be enforced.
func (c *RunNowController) emitRunNowInvoked(runID, actor, outcome string, now time.Time) {
	c.log.Info().
		Str("event", "payout_run_now_invoked").
		Str("run_id", runID).
		Str("actor", actor).
		Str("outcome", outcome).
		Str("ts_utc", now.UTC().Format(time.RFC3339Nano)).
		Send()
}

// ServeRunNow handles POST /admin/payout/run-now. actor is the
// operator_key identifier from the authenticated request (matches
// what other admin endpoints use — "operator_key" or the key label).
//
// Behavior per SPEC §4.2:
//  1. Generate run_id.
//  2. Check rate limit: if within RunNowMinInterval window, return 429
//     and emit payout_run_now_invoked with outcome=rate_limited.
//  3. If runner.IsHalted(): return 409 and emit with outcome=runner_halted.
//  4. Call runner.RunOnce:
//     - ErrRunnerHalted (concurrent halt race): 409 runner_halted body.
//     - other error: 409 cycle_in_flight_or_failed.
//     - nil: 200 ok with run_id; lastAccepted updated.
func (c *RunNowController) ServeRunNow(w http.ResponseWriter, r *http.Request, actor string) {
	now := c.nowFn()
	runID := uuid.NewString()
	interval := c.currentInterval()

	// Rate limit: hold mu during the window check and lastAccepted update
	// to prevent concurrent requests from both slipping through.
	c.mu.Lock()
	withinWindow := !c.lastAccepted.IsZero() && now.Sub(c.lastAccepted) < interval
	if withinWindow {
		// Do not update lastAccepted on a rate-limited request.
		c.mu.Unlock()
		c.emitRunNowInvoked(runID, actor, "rate_limited", now)
		writeError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	// Mark accepted inside the lock before releasing so a concurrent
	// request that arrives after us sees the updated timestamp.
	c.lastAccepted = now
	c.mu.Unlock()

	exec := c.execOrRunner()

	// Step 4 r2 [code:r2-3] MEDIUM closure: pre-check IsHalted as a
	// fast path, but RunOnce's own halt check may also fire if
	// RequestHalt races after this line. Both paths emit runner_halted.
	if exec.IsHalted() {
		c.emitRunNowInvoked(runID, actor, "runner_halted", now)
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":  "runner_halted",
			"reason": exec.HaltReason(),
		})
		return
	}

	// Step 4 r3 [code:r3-1] HIGH closure: RunOnce now returns the
	// run_id it used for payout_run_started / payout_run_finished.
	// We replace our pre-generated runID with the cycle's actual
	// run_id so payout_run_now_invoked.run_id == payout_run_started.run_id.
	cycleRunID, err := exec.RunOnce(r.Context())
	if cycleRunID != "" {
		runID = cycleRunID
	}
	if err != nil {
		// Step 4 r2 [code:r2-3] MEDIUM closure: if RequestHalt fired
		// after IsHalted() check above but before/during RunOnce, the
		// runner returns ErrRunnerHalted. Return runner_halted body
		// (not cycle_in_flight_or_failed) so the audit trail is correct.
		if errors.Is(err, ErrRunnerHalted) {
			c.emitRunNowInvoked(runID, actor, "runner_halted", now)
			writeJSON(w, http.StatusConflict, map[string]any{
				"error":  "runner_halted",
				"reason": exec.HaltReason(),
			})
			return
		}
		c.emitRunNowInvoked(runID, actor, "cycle_in_flight_or_failed", now)
		writeError(w, http.StatusConflict, "cycle_in_flight_or_failed")
		return
	}

	c.emitRunNowInvoked(runID, actor, "accepted", now)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "run_id": runID})
}
