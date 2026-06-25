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
	addressCoolingOffMin   = 1 * time.Hour
	runIntervalMin         = 5 * time.Minute
	runIntervalMax         = 24 * time.Hour
	runNowMinIntervalMin   = 10 * time.Second
	runNowMinIntervalMax   = 1 * time.Hour
	confirmationBlocksMin  = 5
	confirmationBlocksMax  = 200
	maxRowsPerRunMin       = 1
	maxRowsPerRunMax       = 500
	reorgPollWindowMin     = 1 * time.Hour
	reorgPollWindowMax     = 168 * time.Hour
	lowNativeThresholdMax  = int64(1_000_000_000_000_000_000) // 1e18 wei
	spkiPinRegex           = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)
)

// validateBounds applies the §6.5 hard-bound matrix to a candidate
// snapshot. It also enforces the cross-field constraint
// `low_balance_threshold <= 2 × per_day_cap`. perDayCap comes from
// the immutable security namespace (loaded at startup); it does
// NOT flow through this loader.
//
// Returns a wrapped error naming the first failing field — the
// §7.1 emitter surfaces the field name to operators.
func validateBounds(t TuningSnapshot, perDayCap int64) error {
	if t.AddressCoolingOffPeriod < addressCoolingOffMin {
		return fmt.Errorf("address_cooling_off_period %s < min %s", t.AddressCoolingOffPeriod, addressCoolingOffMin)
	}
	if t.RunInterval < runIntervalMin || t.RunInterval > runIntervalMax {
		return fmt.Errorf("run_interval %s outside [%s, %s]", t.RunInterval, runIntervalMin, runIntervalMax)
	}
	if t.RunNowMinInterval < runNowMinIntervalMin || t.RunNowMinInterval > runNowMinIntervalMax {
		return fmt.Errorf("run_now_min_interval %s outside [%s, %s]", t.RunNowMinInterval, runNowMinIntervalMin, runNowMinIntervalMax)
	}
	if t.ConfirmationBlocks < confirmationBlocksMin || t.ConfirmationBlocks > confirmationBlocksMax {
		return fmt.Errorf("confirmation_blocks %d outside [%d, %d]", t.ConfirmationBlocks, confirmationBlocksMin, confirmationBlocksMax)
	}
	if t.MaxRowsPerRun < maxRowsPerRunMin || t.MaxRowsPerRun > maxRowsPerRunMax {
		return fmt.Errorf("max_rows_per_run %d outside [%d, %d]", t.MaxRowsPerRun, maxRowsPerRunMin, maxRowsPerRunMax)
	}
	if t.ReorgPollWindow < reorgPollWindowMin || t.ReorgPollWindow > reorgPollWindowMax {
		return fmt.Errorf("reorg_poll_window %s outside [%s, %s]", t.ReorgPollWindow, reorgPollWindowMin, reorgPollWindowMax)
	}
	if t.LowNativeThreshold < 0 || t.LowNativeThreshold > lowNativeThresholdMax {
		return fmt.Errorf("low_native_threshold %d outside [0, %d]", t.LowNativeThreshold, lowNativeThresholdMax)
	}
	if t.LowBalanceThreshold < 0 {
		return fmt.Errorf("low_balance_threshold %d must be >= 0", t.LowBalanceThreshold)
	}
	// Cross-field: low_balance_threshold MUST be <= 2 × per_day_cap.
	// perDayCap = 0 means the security loader hasn't been wired yet
	// (test path); skip the cross-field check in that case.
	if perDayCap > 0 && t.LowBalanceThreshold > 2*perDayCap {
		return fmt.Errorf("low_balance_threshold %d > 2 × per_day_cap %d (= %d)", t.LowBalanceThreshold, perDayCap, 2*perDayCap)
	}
	if t.RPCURLPrimaryPinSPKI != "" && !spkiPinRegex.MatchString(t.RPCURLPrimaryPinSPKI) {
		return fmt.Errorf("rpc_url_primary_pin_spki must be 64-hex-char SHA-256 or empty")
	}
	if t.RPCURLSecondaryPinSPKI != "" && !spkiPinRegex.MatchString(t.RPCURLSecondaryPinSPKI) {
		return fmt.Errorf("rpc_url_secondary_pin_spki must be 64-hex-char SHA-256 or empty")
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

// Reload validates the candidate snapshot and, on success, atomic-
// stores it as the new live value. Per SPEC §6.5 normative:
//
//   - Success: emit `payout_config_reloaded` PAGE with key + old +
//     new for every changed key.
//   - Bound violation: emit `payout_config_reload_rejected` PAGE
//     with the failing field; LIVE VALUE IS RETAINED.
//
// Returns ErrTuningBoundViolation wrapped with the violated
// field on rejection. The runner cycle observes the new value at
// the NEXT cycle's top (snapshot read at top of RunOnce).
func (p *TuningProvider) Reload(ctx context.Context, candidate TuningSnapshot) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	old := p.Snapshot()
	if err := validateBounds(candidate, p.perDayCap); err != nil {
		p.emitRejected(err)
		return fmt.Errorf("%w: %v", ErrTuningBoundViolation, err)
	}
	// Atomic store — the next Snapshot() call sees the new value.
	p.v.Store(candidate)
	p.emitReloaded(old, candidate)
	return nil
}

// emitReloaded fires one payout_config_reloaded PAGE event per
// changed key. Per §7.1 the field set is {key, old, new, ts_utc,
// severity=PAGE}. Operators get one log line per actual change so
// the audit trail names exactly what flipped.
func (p *TuningProvider) emitReloaded(old, new TuningSnapshot) {
	tsUTC := time.Now().UTC().Format(time.RFC3339Nano)
	emit := func(key, oldS, newS string) {
		p.log.Warn().
			Str("event", "payout_config_reloaded").
			Str("key", key).
			Str("old", oldS).
			Str("new", newS).
			Str("ts_utc", tsUTC).
			Str("severity", "PAGE").
			Send()
	}
	if old.AddressCoolingOffPeriod != new.AddressCoolingOffPeriod {
		emit("payout.tuning.address_cooling_off_period", old.AddressCoolingOffPeriod.String(), new.AddressCoolingOffPeriod.String())
	}
	if old.RunInterval != new.RunInterval {
		emit("payout.tuning.run_interval", old.RunInterval.String(), new.RunInterval.String())
	}
	if old.RunNowMinInterval != new.RunNowMinInterval {
		emit("payout.tuning.run_now_min_interval", old.RunNowMinInterval.String(), new.RunNowMinInterval.String())
	}
	if old.ConfirmationBlocks != new.ConfirmationBlocks {
		emit("payout.tuning.confirmation_blocks", fmt.Sprintf("%d", old.ConfirmationBlocks), fmt.Sprintf("%d", new.ConfirmationBlocks))
	}
	if old.MaxRowsPerRun != new.MaxRowsPerRun {
		emit("payout.tuning.max_rows_per_run", fmt.Sprintf("%d", old.MaxRowsPerRun), fmt.Sprintf("%d", new.MaxRowsPerRun))
	}
	if old.ReorgPollWindow != new.ReorgPollWindow {
		emit("payout.tuning.reorg_poll_window", old.ReorgPollWindow.String(), new.ReorgPollWindow.String())
	}
	if old.LowBalanceThreshold != new.LowBalanceThreshold {
		emit("payout.tuning.low_balance_threshold", fmt.Sprintf("%d", old.LowBalanceThreshold), fmt.Sprintf("%d", new.LowBalanceThreshold))
	}
	if old.LowNativeThreshold != new.LowNativeThreshold {
		emit("payout.tuning.low_native_threshold", fmt.Sprintf("%d", old.LowNativeThreshold), fmt.Sprintf("%d", new.LowNativeThreshold))
	}
	if old.RPCURLPrimaryPinSPKI != new.RPCURLPrimaryPinSPKI {
		emit("payout.tuning.rpc_url_primary_pin_spki", redactSPKI(old.RPCURLPrimaryPinSPKI), redactSPKI(new.RPCURLPrimaryPinSPKI))
	}
	if old.RPCURLSecondaryPinSPKI != new.RPCURLSecondaryPinSPKI {
		emit("payout.tuning.rpc_url_secondary_pin_spki", redactSPKI(old.RPCURLSecondaryPinSPKI), redactSPKI(new.RPCURLSecondaryPinSPKI))
	}
}

// emitRejected fires one payout_config_reload_rejected PAGE event
// naming the failing field. The live value is retained.
func (p *TuningProvider) emitRejected(err error) {
	p.log.Error().
		Err(err).
		Str("event", "payout_config_reload_rejected").
		Str("ts_utc", time.Now().UTC().Format(time.RFC3339Nano)).
		Str("severity", "PAGE").
		Msg("payout tuning reload rejected — live value retained")
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
