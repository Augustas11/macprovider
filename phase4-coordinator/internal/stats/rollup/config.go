package rollup

import (
	"errors"
	"strings"
	"time"
)

// Config is the rollup package's view of the operator-tunable
// knobs. cmd/coordinator/main.go translates from
// stats.RollupConfig at startup.
//
// All durations + ratios are derived from the config knobs the
// SPEC §9.2 / §9.3 / §9.4 sections normatively pin. v0.1
// operators can tighten cadences below the SPEC floors without
// a SPEC change; loosening requires a SPEC bump.
type Config struct {
	// BackfillMode — "partial" (Path A, default) or "full"
	// (Path B). See SPEC §9.7.
	BackfillMode string
	// PartialHistorySinceUnix — rollup-start unix-second
	// boundary when BackfillMode = "partial". 0 when
	// BackfillMode = "full" OR PartialHistorySince was unset.
	PartialHistorySinceUnix int64

	// UsdPerMillionCredits — credits→USD conversion factor
	// (SPEC-005 v0.3 + SPEC-016 v0.1.19 deferral). Default 1.0.
	UsdPerMillionCredits float64

	// DriftThresholdRatio — >0.005 fractional divergence emits
	// `stats_rollup_drift_detected` (SPEC §9.4). Default 0.005.
	DriftThresholdRatio float64

	// NightlyRebuildHourUTC — UTC hour for nightly
	// `stats_leaderboard_all` + `_30d` rebuild (SPEC §9.3).
	// Default 9.
	NightlyRebuildHourUTC int

	// LateEventsLookbackHours — 48h per SPEC §9.3 default.
	LateEventsLookbackHours int

	// LateEventsRetentionDays — 90 default; floor 30 per SPEC
	// §9.3. Below-floor clamped to 30 (with a WARN log emitted
	// by the rollup runner at startup).
	LateEventsRetentionDays int

	// OverviewInterval — SPEC §9.2 cadence floor 30s. Operator
	// MAY tighten.
	OverviewInterval time.Duration
	// TimeseriesRpmInterval — SPEC §9.2 30s rolling.
	TimeseriesRpmInterval time.Duration
	// TimeseriesTpmInterval — SPEC §9.2 30s rolling.
	TimeseriesTpmInterval time.Duration
	// LeaderboardInterval (per window) — 60s / 5m / 30m / 6h
	// per SPEC §9.2.
	Leaderboard24hInterval time.Duration
	Leaderboard7dInterval  time.Duration
	Leaderboard30dInterval time.Duration
	LeaderboardAllInterval time.Duration
}

// DefaultsApplied returns a copy of c with any zero-value field
// filled to the SPEC §9.2 / §9.3 / §9.4 default. The runner
// calls this once at startup; tests can call it explicitly to
// avoid duplicating constants.
func (c Config) DefaultsApplied() Config {
	if strings.TrimSpace(c.BackfillMode) == "" {
		c.BackfillMode = "partial"
	}
	if c.UsdPerMillionCredits == 0 {
		c.UsdPerMillionCredits = 1.0
	}
	if c.DriftThresholdRatio == 0 {
		c.DriftThresholdRatio = 0.005
	}
	if c.NightlyRebuildHourUTC == 0 {
		// 0 is also a valid UTC hour. To distinguish "unset"
		// from "midnight UTC", the cmd/coordinator translation
		// layer is the place that sets 9 as the default when
		// the operator hasn't pinned a value. Here we accept
		// whatever was passed (0 means midnight UTC).
	}
	if c.LateEventsLookbackHours == 0 {
		c.LateEventsLookbackHours = 48
	}
	// LateEventsRetentionDays clamp+warn pin per BUILD §2 Step 2:
	// 0 → 90 default; (0, 30) → 30 with a WARN log emitted by
	// the runner at startup.
	if c.LateEventsRetentionDays == 0 {
		c.LateEventsRetentionDays = 90
	}
	if c.OverviewInterval == 0 {
		c.OverviewInterval = 30 * time.Second
	}
	if c.TimeseriesRpmInterval == 0 {
		c.TimeseriesRpmInterval = 30 * time.Second
	}
	if c.TimeseriesTpmInterval == 0 {
		c.TimeseriesTpmInterval = 30 * time.Second
	}
	if c.Leaderboard24hInterval == 0 {
		c.Leaderboard24hInterval = 60 * time.Second
	}
	if c.Leaderboard7dInterval == 0 {
		c.Leaderboard7dInterval = 5 * time.Minute
	}
	if c.Leaderboard30dInterval == 0 {
		c.Leaderboard30dInterval = 30 * time.Minute
	}
	if c.LeaderboardAllInterval == 0 {
		c.LeaderboardAllInterval = 6 * time.Hour
	}
	return c
}

// Validate returns the first error encountered while checking
// the config. Called by the runner at startup before any
// goroutine is spawned.
func (c Config) Validate() error {
	switch c.BackfillMode {
	case "partial", "full":
	default:
		return errors.New("rollup: backfill_mode must be 'partial' or 'full'")
	}
	if c.UsdPerMillionCredits < 0 {
		return errors.New("rollup: usd_per_million_credits must be >= 0")
	}
	if c.DriftThresholdRatio < 0.001 || c.DriftThresholdRatio > 0.05 {
		return errors.New("rollup: drift_threshold_ratio must be in [0.001, 0.05]")
	}
	if c.NightlyRebuildHourUTC < 0 || c.NightlyRebuildHourUTC > 23 {
		return errors.New("rollup: nightly_rebuild_hour_utc must be in [0, 23]")
	}
	if c.LateEventsLookbackHours < 24 {
		return errors.New("rollup: late_events_lookback_hours must be >= 24 (SPEC §9.3 floor)")
	}
	if c.LateEventsRetentionDays < 30 {
		return errors.New("rollup: late_events_retention_days < 30 after clamp pass; check DefaultsApplied")
	}
	return nil
}
