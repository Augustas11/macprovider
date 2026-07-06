package rollup

import "time"

// SnapshotProvider exposes the live point-in-time fields the
// §5.1 `/v1/stats/overview` endpoint surfaces alongside the
// cumulative SPEC-005 ledger counters. These are in-process
// coordinator state (pool.Registry, telemetry surfaces) and
// CANNOT be read from any OLTP table.
//
// main.go injects a default implementation that aggregates from
// `internal/pool.Registry.Snapshot()` and existing telemetry.
// Tests inject a stub. Fields the operator has not wired a real
// source for default to zero with an OPS.md note.
//
// Fields below map 1:1 to the live-pool columns in
// `stats_overview_current`.
type SnapshotProvider interface {
	OverviewSnapshot() OverviewSnapshot
}

// OverviewSnapshot is the live point-in-time tuple of
// `stats_overview_current` columns the rollup writes at every
// overview tick.
type OverviewSnapshot struct {
	NodesOnline           int
	NodesHardwareAttested int
	BandwidthGBPerSec     int64
	NetworkPowerKW        float64
	NetworkUtilizationPct int
	GPUCoresTotal         int
	CPUCoresTotal         int
	UnifiedRAMGBTotal     int
	ModelsServing         int
	// CapacityEligibleProviderIDs is the exact provider population counted in
	// NodesOnline. Optional pool-scoped telemetry percentages must use this
	// population for their numerator so non-capacity sessions cannot inflate
	// public pool metrics.
	CapacityEligibleProviderIDs []string
	// At is the moment the snapshot was taken; the rollup uses
	// it as the `stats_overview_current.generated_at` value
	// when it writes (subject to the tick-time override below).
	At time.Time
}

// ZeroSnapshotProvider is the safe-default SnapshotProvider for
// tests + dev environments where no real source is wired. It
// returns zero values for every live field with `At = time.Now()`.
// Production deployments MUST inject a real provider per OPS.md.
type ZeroSnapshotProvider struct{}

// OverviewSnapshot satisfies the interface.
func (ZeroSnapshotProvider) OverviewSnapshot() OverviewSnapshot {
	return OverviewSnapshot{At: time.Now().UTC()}
}
