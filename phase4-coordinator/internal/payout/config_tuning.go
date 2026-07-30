package payout

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog"
)

// TuningSnapshot is the immutable per-reload value of the §6.5
// `payout.tuning.*` namespace. Consumers (Runner, ReorgPoller,
// Reaper, address service) read from it via Provider.Snapshot()
// which returns a copy — there is no shared mutable state across
// the SIGHUP boundary.
//
// Field set mirrors config.PayoutTuningConfig but is owned by
// this package so the import-graph guard at Step 1 still holds
// (config → payout direction only).
type TuningSnapshot struct {
	// AddressCoolingOffPeriod — §3.3 cooling-off window for newly
	// registered/rotated addresses. Bound: >= 1h.
	AddressCoolingOffPeriod time.Duration

	// RunInterval — §4.2 runner cadence. Bound: [5m, 24h].
	RunInterval time.Duration

	// RunNowMinInterval — §4.2 admin run-now rate limit floor.
	// Bound: [10s, 1h].
	RunNowMinInterval time.Duration

	// ConfirmationBlocks — §4.3 step 7 receipt depth threshold.
	// Bound: [5, 200] per SPEC v0.1.20 round-20 M2.
	ConfirmationBlocks int

	// MaxRowsPerRun — §4.3 step 1 cap. Bound: [1, 500].
	MaxRowsPerRun int

	// ReorgPollWindow — §4.7 re-poll window. Bound: [1h, 168h].
	ReorgPollWindow time.Duration

	// LowBalanceThreshold — §6.2 USDC base-units alert floor; 0
	// disables. Bound: <= 2 × per_day_cap.
	LowBalanceThreshold int64

	// LowNativeThreshold — §6.2 native wei alert floor; 0
	// disables. Bound: <= 1e18.
	LowNativeThreshold int64

	// RPCURLPrimaryPinSPKI / RPCURLSecondaryPinSPKI — SHA-256
	// SPKI pins. Bound: 64-hex-char OR empty.
	RPCURLPrimaryPinSPKI   string
	RPCURLSecondaryPinSPKI string
}

// Hard bounds per SPEC-016 §6.5 (v0.1.21). Centralised so that
// LoadFromConfig (parse-time) and Reload (SIGHUP-time) use the
// same numeric thresholds; SPEC §6.5 normatively requires
// "Hot-reload re-enforces ALL bounds at reload time" — the only
// way to guarantee that is to make the bound-set the SAME
// function call.
var (
	addressCoolingOffMin  = 1 * time.Hour
	runIntervalMin        = 5 * time.Minute
	runIntervalMax        = 24 * time.Hour
	runNowMinIntervalMin  = 10 * time.Second
	runNowMinIntervalMax  = 1 * time.Hour
	confirmationBlocksMin = 5
	confirmationBlocksMax = 200
	maxRowsPerRunMin      = 1
	maxRowsPerRunMax      = 500
	reorgPollWindowMin    = 1 * time.Hour
	reorgPollWindowMax    = 168 * time.Hour
	lowNativeThresholdMax = int64(1_000_000_000_000_000_000) // 1e18 wei
	spkiPinRegex          = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)
)

// validateBounds applies the §6.5 hard-bound matrix to a candidate
// snapshot. It also enforces the cross-field constraint
// `low_balance_threshold <= 2 × per_day_cap`. perDayCap comes from
// the immutable security namespace (loaded at startup); it does
// NOT flow through this loader.
//
// Returns *BoundViolationError naming the first failing field —
// the §7.1 emitter surfaces key/attempted_value/bound to operators.
//
// Step 4 r3 [code:r3-2]/[sec:r3-2] MEDIUM closure: switched from
// plain fmt.Errorf to *BoundViolationError so emitRejected can log
// the structured §7.1 field set (key, attempted_value, bound).
func validateBounds(t TuningSnapshot, perDayCap int64) error {
	if t.AddressCoolingOffPeriod < addressCoolingOffMin {
		return &BoundViolationError{
			Field:     "payout.tuning.address_cooling_off_period",
			Attempted: t.AddressCoolingOffPeriod.String(),
			Bound:     fmt.Sprintf(">= %s", addressCoolingOffMin),
		}
	}
	if t.RunInterval < runIntervalMin || t.RunInterval > runIntervalMax {
		return &BoundViolationError{
			Field:     "payout.tuning.run_interval",
			Attempted: t.RunInterval.String(),
			Bound:     fmt.Sprintf("[%s, %s]", runIntervalMin, runIntervalMax),
		}
	}
	if t.RunNowMinInterval < runNowMinIntervalMin || t.RunNowMinInterval > runNowMinIntervalMax {
		return &BoundViolationError{
			Field:     "payout.tuning.run_now_min_interval",
			Attempted: t.RunNowMinInterval.String(),
			Bound:     fmt.Sprintf("[%s, %s]", runNowMinIntervalMin, runNowMinIntervalMax),
		}
	}
	if t.ConfirmationBlocks < confirmationBlocksMin || t.ConfirmationBlocks > confirmationBlocksMax {
		return &BoundViolationError{
			Field:     "payout.tuning.confirmation_blocks",
			Attempted: fmt.Sprintf("%d", t.ConfirmationBlocks),
			Bound:     fmt.Sprintf("[%d, %d]", confirmationBlocksMin, confirmationBlocksMax),
		}
	}
	if t.MaxRowsPerRun < maxRowsPerRunMin || t.MaxRowsPerRun > maxRowsPerRunMax {
		return &BoundViolationError{
			Field:     "payout.tuning.max_rows_per_run",
			Attempted: fmt.Sprintf("%d", t.MaxRowsPerRun),
			Bound:     fmt.Sprintf("[%d, %d]", maxRowsPerRunMin, maxRowsPerRunMax),
		}
	}
	if t.ReorgPollWindow < reorgPollWindowMin || t.ReorgPollWindow > reorgPollWindowMax {
		return &BoundViolationError{
			Field:     "payout.tuning.reorg_poll_window",
			Attempted: t.ReorgPollWindow.String(),
			Bound:     fmt.Sprintf("[%s, %s]", reorgPollWindowMin, reorgPollWindowMax),
		}
	}
	if t.LowNativeThreshold < 0 || t.LowNativeThreshold > lowNativeThresholdMax {
		return &BoundViolationError{
			Field:     "payout.tuning.low_native_threshold",
			Attempted: fmt.Sprintf("%d", t.LowNativeThreshold),
			Bound:     fmt.Sprintf("[0, %d]", lowNativeThresholdMax),
		}
	}
	if t.LowBalanceThreshold < 0 {
		return &BoundViolationError{
			Field:     "payout.tuning.low_balance_threshold",
			Attempted: fmt.Sprintf("%d", t.LowBalanceThreshold),
			Bound:     ">= 0",
		}
	}
	// Cross-field: low_balance_threshold MUST be <= 2 × per_day_cap.
	// perDayCap = 0 means the security loader hasn't been wired yet
	// (test path); skip the cross-field check in that case.
	if perDayCap > 0 && t.LowBalanceThreshold > 2*perDayCap {
		return &BoundViolationError{
			Field:     "payout.tuning.low_balance_threshold",
			Attempted: fmt.Sprintf("%d", t.LowBalanceThreshold),
			Bound:     fmt.Sprintf("<= 2 × per_day_cap (%d)", 2*perDayCap),
		}
	}
	if t.RPCURLPrimaryPinSPKI != "" && !spkiPinRegex.MatchString(t.RPCURLPrimaryPinSPKI) {
		return &BoundViolationError{
			Field:     "payout.tuning.rpc_url_primary_pin_spki",
			Attempted: redactSPKI(t.RPCURLPrimaryPinSPKI),
			Bound:     "64-hex-char SHA-256 or empty",
		}
	}
	if t.RPCURLSecondaryPinSPKI != "" && !spkiPinRegex.MatchString(t.RPCURLSecondaryPinSPKI) {
		return &BoundViolationError{
			Field:     "payout.tuning.rpc_url_secondary_pin_spki",
			Attempted: redactSPKI(t.RPCURLSecondaryPinSPKI),
			Bound:     "64-hex-char SHA-256 or empty",
		}
	}
	return nil
}

// TuningProvider holds the SIGHUP-reloadable §6.5
// `payout.tuning.*` namespace as an immutable atomic.Value. Every
// consumer reads via Snapshot() (returns the latest committed
// snapshot by value); reload uses atomic store after the new
// candidate passes validateBounds(). No reader ever observes a
// torn read.
//
// Design (codex Step 3 r3 architect Step 4 advisory):
//   - The provider DOES NOT own the runner or any background
//     loop. It is a passive value holder. Lifecycle-aware
//     restart (Runner.Stop + reload + Runner.Start) is the
//     caller's responsibility — that's main.go's SIGHUP handler.
//   - The snapshot is captured at the top of each runner cycle
//     (RunOnce reads via Snapshot()), so a SIGHUP between cycles
//     takes effect at the next cycle without an in-flight cycle
//     observing a mid-flight change.
//   - Old in-flight `pending_until_utc` rows MUST NOT be
//     recomputed on AddressCoolingOffPeriod reload (SPEC §6.5).
//     The address handler reads the current snapshot at
//     write-time; rows already written keep their original
//     cooling-off.
type TuningProvider struct {
	v         atomic.Value // holds TuningSnapshot
	log       zerolog.Logger
	perDayCap int64 // immutable from §6.5 security namespace
}

// NewTuningProvider constructs a provider seeded with the
// startup config + the immutable per_day_cap from the security
// namespace. The seed itself MUST pass validateBounds before
// process start — the caller is config.Validate() at startup;
// this function ALSO double-checks so a misconfigured deploy
// fails-fast at constructor time rather than later at the first
// SIGHUP.
func NewTuningProvider(initial TuningSnapshot, perDayCapUSDCBaseUnits int64, log zerolog.Logger) (*TuningProvider, error) {
	if err := validateBounds(initial, perDayCapUSDCBaseUnits); err != nil {
		return nil, fmt.Errorf("payout.NewTuningProvider: initial snapshot failed bounds: %w", err)
	}
	p := &TuningProvider{
		log:       log,
		perDayCap: perDayCapUSDCBaseUnits,
	}
	p.v.Store(initial)
	return p, nil
}

// Snapshot returns the current snapshot by value. Safe to call
// from any goroutine; the atomic.Value Load is the synchronization
// point. The returned value is a copy — modifications to the
// returned struct have no effect on the live provider.
func (p *TuningProvider) Snapshot() TuningSnapshot {
	return p.v.Load().(TuningSnapshot)
}

// ErrTuningBoundViolation is returned by Reload when the
// candidate snapshot fails the §6.5 bound matrix. Caller (SIGHUP
// handler) emits payout_config_reload_rejected PAGE and retains
// the live value.
var ErrTuningBoundViolation = errors.New("payout: tuning reload rejected — bound violation")

// BoundViolationError carries the structured §7.1 fields for a
// payout_config_reload_rejected event: key, attempted_value, bound.
// Returned by validateBoundsStructured so emitRejected can log the
// full §7.1 field set.
//
// Step 4 r3 [code:r3-2]/[sec:r3-2] CONVERGENT MEDIUM closure:
// structured error instead of plain string so the SIGHUP handler
// emits key/attempted_value/bound per §7.1 line 3731.
//
// Step 4 r4 [code:r4-5] LOW closure: fields renamed to Field/Attempted
// to match the r4 review contract; Actor added as a structured field.
// The §7.1 wire log field names (key, attempted_value, bound, actor)
// are unchanged — only the Go struct field names are renamed here.
type BoundViolationError struct {
	Field     string // e.g. "payout.tuning.run_interval"
	Attempted string // human-readable of the attempted value
	Bound     string // human-readable of the violated bound
	Actor     string // e.g. "operator_key:coordinator"
}

func (e *BoundViolationError) Error() string {
	return fmt.Sprintf("%s: attempted=%s violated bound=%s", e.Field, e.Attempted, e.Bound)
}

// Reload validates the candidate snapshot and, on success, atomic-
// stores it as the new live value. Per SPEC §6.5 normative:
//
//   - Success: emit `payout_config_reloaded` PAGE with key + old +
//     new for every changed key.
//   - Bound violation: emit `payout_config_reload_rejected` PAGE
//     with the failing field; LIVE VALUE IS RETAINED.
//
// Returns (changedKeys, nil) on success, where changedKeys lists the
// tuning field names that actually changed. The SIGHUP handler uses
// this to detect SPKI pin changes and drain RPC idle connections.
// Returns (nil, ErrTuningBoundViolation) wrapped with the violated
// field on rejection. The runner cycle observes the new value at
// the NEXT cycle's top (snapshot read at top of RunOnce).
//
// Step 4 r3 [sec:r3-1]/[arch:r3-4.2] closure: changedKeys return
// lets the SIGHUP handler call CloseIdleConnections on the RPC
// clients when an SPKI pin key is in the changed set.
func (p *TuningProvider) Reload(ctx context.Context, candidate TuningSnapshot) ([]string, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	old := p.Snapshot()
	if bve := validateBounds(candidate, p.perDayCap); bve != nil {
		p.emitRejected(bve)
		// Step 4 r5 [code:r5-6] LOW closure: wrap both the sentinel
		// error and the *BoundViolationError so callers can use
		// errors.Is(err, ErrTuningBoundViolation) AND
		// errors.As(err, &bve) to extract the structured violation.
		// Double-%w is valid in Go 1.20+.
		return nil, fmt.Errorf("%w: %w", ErrTuningBoundViolation, bve)
	}
	// Atomic store — the next Snapshot() call sees the new value.
	p.v.Store(candidate)
	changed := p.emitReloaded(old, candidate)
	return changed, nil
}

// emitReloaded fires one payout_config_reloaded PAGE event per
// changed key and returns the list of changed key names. Per §7.1
// the field set is {key, old_value, new_value, actor, ts_utc,
// severity=PAGE}. Operators get one log line per actual change so
// the audit trail names exactly what flipped.
//
// Step 4 r3 [code:r3-2]/[sec:r3-2] CONVERGENT MEDIUM closure:
// renamed old→old_value, new→new_value per §7.1 line 3730; added
// actor field ("operator_key:coordinator" = coordinator process
// acting on behalf of the operator via SIGHUP). Returns changed
// key names so the SIGHUP handler can detect SPKI pin changes.
func (p *TuningProvider) emitReloaded(old, newSnap TuningSnapshot) []string {
	tsUTC := time.Now().UTC().Format(time.RFC3339Nano)
	var changed []string
	emit := func(key, oldS, newS string) {
		changed = append(changed, key)
		p.log.Warn().
			Str("event", "payout_config_reloaded").
			Str("key", key).
			Str("old_value", oldS).
			Str("new_value", newS).
			Str("actor", "operator_key:coordinator").
			Str("ts_utc", tsUTC).
			Str("severity", "PAGE").
			Send()
	}
	if old.AddressCoolingOffPeriod != newSnap.AddressCoolingOffPeriod {
		emit("payout.tuning.address_cooling_off_period", old.AddressCoolingOffPeriod.String(), newSnap.AddressCoolingOffPeriod.String())
	}
	if old.RunInterval != newSnap.RunInterval {
		emit("payout.tuning.run_interval", old.RunInterval.String(), newSnap.RunInterval.String())
	}
	if old.RunNowMinInterval != newSnap.RunNowMinInterval {
		emit("payout.tuning.run_now_min_interval", old.RunNowMinInterval.String(), newSnap.RunNowMinInterval.String())
	}
	if old.ConfirmationBlocks != newSnap.ConfirmationBlocks {
		emit("payout.tuning.confirmation_blocks", fmt.Sprintf("%d", old.ConfirmationBlocks), fmt.Sprintf("%d", newSnap.ConfirmationBlocks))
	}
	if old.MaxRowsPerRun != newSnap.MaxRowsPerRun {
		emit("payout.tuning.max_rows_per_run", fmt.Sprintf("%d", old.MaxRowsPerRun), fmt.Sprintf("%d", newSnap.MaxRowsPerRun))
	}
	if old.ReorgPollWindow != newSnap.ReorgPollWindow {
		emit("payout.tuning.reorg_poll_window", old.ReorgPollWindow.String(), newSnap.ReorgPollWindow.String())
	}
	if old.LowBalanceThreshold != newSnap.LowBalanceThreshold {
		emit("payout.tuning.low_balance_threshold", fmt.Sprintf("%d", old.LowBalanceThreshold), fmt.Sprintf("%d", newSnap.LowBalanceThreshold))
	}
	if old.LowNativeThreshold != newSnap.LowNativeThreshold {
		emit("payout.tuning.low_native_threshold", fmt.Sprintf("%d", old.LowNativeThreshold), fmt.Sprintf("%d", newSnap.LowNativeThreshold))
	}
	if old.RPCURLPrimaryPinSPKI != newSnap.RPCURLPrimaryPinSPKI {
		emit("payout.tuning.rpc_url_primary_pin_spki", redactSPKI(old.RPCURLPrimaryPinSPKI), redactSPKI(newSnap.RPCURLPrimaryPinSPKI))
	}
	if old.RPCURLSecondaryPinSPKI != newSnap.RPCURLSecondaryPinSPKI {
		emit("payout.tuning.rpc_url_secondary_pin_spki", redactSPKI(old.RPCURLSecondaryPinSPKI), redactSPKI(newSnap.RPCURLSecondaryPinSPKI))
	}
	return changed
}

// emitRejected fires one payout_config_reload_rejected PAGE event
// with the full §7.1 field set. The live value is retained.
//
// Step 4 r3 [code:r3-2]/[sec:r3-2] CONVERGENT MEDIUM closure:
// structured §7.1 fields key/attempted_value/bound/actor/ts_utc per
// line 3731. When err is *BoundViolationError the fields are
// individually extracted; otherwise key="yaml_parse" covers parse
// failures and the raw error lands in attempted_value.
func (p *TuningProvider) emitRejected(err error) {
	tsUTC := time.Now().UTC().Format(time.RFC3339Nano)
	var bve *BoundViolationError
	if errors.As(err, &bve) {
		actor := bve.Actor
		if actor == "" {
			actor = "operator_key:coordinator"
		}
		p.log.Error().
			Str("event", "payout_config_reload_rejected").
			Str("key", bve.Field).
			Str("attempted_value", bve.Attempted).
			Str("bound", bve.Bound).
			Str("actor", actor).
			Str("ts_utc", tsUTC).
			Str("severity", "PAGE").
			Send()
	} else {
		// YAML-parse failure or other pre-bound error.
		// Step 4 r5 [code:r5-7] LOW closure: use sanitized literal
		// "config_load_failed" instead of err.Error() to prevent raw
		// YAML content (which may contain secrets) from reaching logs.
		// The raw error is available via the log.Error().Err() chain
		// in the SIGHUP handler; emitRejected is a pure-signal path.
		p.log.Error().
			Str("event", "payout_config_reload_rejected").
			Str("key", "yaml_parse").
			Str("attempted_value", "config_load_failed").
			Str("bound", "valid_yaml").
			Str("actor", "operator_key:coordinator").
			Str("ts_utc", tsUTC).
			Str("severity", "PAGE").
			Send()
	}
}

// redactSPKI returns an 8-char prefix of an SPKI pin for log
// surfaces. The pin is a SHA-256 hex string and not itself
// secret, but operators have historically conflated cert pins
// with private keys; the truncation is defensive.
func redactSPKI(s string) string {
	if len(s) <= 8 {
		return s
	}
	return s[:8] + "…"
}
