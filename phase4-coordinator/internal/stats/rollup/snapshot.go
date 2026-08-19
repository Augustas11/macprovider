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

// RoutabilitySnapshotProvider is the optional v0.2 extension for
// the public current-health read model. Runner checks for this
// interface at tick time so legacy tests that only implement the
// overview snapshot keep working.
type RoutabilitySnapshotProvider interface {
	RoutabilitySnapshot() RoutabilitySnapshot
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

func (ZeroSnapshotProvider) RoutabilitySnapshot() RoutabilitySnapshot {
	return RoutabilitySnapshot{
		Summary:   RoutabilitySummary{State: "offline"},
		Models:    []ModelRoutability{},
		Providers: []ProviderRoutability{},
		At:        time.Now().UTC(),
	}
}

// RoutabilitySnapshot is the pre-redacted public current-health
// projection written into stats_routability_current on every
// routability tick.
type RoutabilitySnapshot struct {
	Summary   RoutabilitySummary    `json:"summary"`
	Models    []ModelRoutability    `json:"models"`
	Providers []ProviderRoutability `json:"providers"`
	At        time.Time             `json:"-"`
}

type RoutabilitySummary struct {
	State                   string `json:"state"`
	ProvidersTotal          int    `json:"providers_total"`
	ProvidersRoutable       int    `json:"providers_routable"`
	ProvidersServingCapable int    `json:"providers_serving_capable"`
	ModelsTotal             int    `json:"models_total"`
	ModelsRedundant         int    `json:"models_redundant"`
	ModelsOperational       int    `json:"models_operational"`
	ModelsDegraded          int    `json:"models_degraded"`
	ModelsUnknown           int    `json:"models_unknown"`
	ModelsOffline           int    `json:"models_offline"`
}

type ModelRoutability struct {
	ModelID                      string `json:"model_id"`
	State                        string `json:"state"`
	ProviderCount                int    `json:"provider_count"`
	RoutableProviderCount        int    `json:"routable_provider_count"`
	ServingCapableProviderCount  int    `json:"serving_capable_provider_count"`
	SlotsFree                    int    `json:"slots_free"`
	SlotsTotal                   int    `json:"slots_total"`
	MaxContextTokens             int    `json:"max_context_tokens"`
	RecentSuccessProviderCount1h int    `json:"recent_success_provider_count_1h"`
}

type ProviderRoutability struct {
	ProviderRef             string `json:"provider_ref"`
	ModelID                 string `json:"model_id,omitempty"`
	State                   string `json:"state"`
	Routable                bool   `json:"routable"`
	ServingCapable          bool   `json:"serving_capable"`
	RoutabilityScore        int    `json:"routability_score"`
	SlotsFree               int    `json:"slots_free"`
	SlotsTotal              int    `json:"slots_total"`
	LastHeartbeatAgeSeconds int    `json:"last_heartbeat_age_seconds"`
	UptimeBucket            string `json:"uptime_bucket"`
	RecentSuccess1h         bool   `json:"recent_success_1h"`
	ReceiptValidity         string `json:"receipt_validity"`
	Attestation             string `json:"attestation"`
	ComputeIntegrity        string `json:"compute_integrity"`
	StaleData               bool   `json:"stale_data"`
}
