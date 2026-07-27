package ws

import (
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	statsmetrics "github.com/augstar/macprovider-coordinator/internal/stats/metrics"
)

func capacityTestConfig(ceiling int) config.Config {
	cfg := config.Default()
	cfg.Pool.MaxConcurrencyCeiling = ceiling
	// The warm-up gate would admit the provider as degraded, which is
	// orthogonal to the capacity clamp under test.
	cfg.Pool.WarmupGateEnabled = false
	return cfg
}

func capacityTestHello(maxConcurrency int) Hello {
	return Hello{
		Type:             "hello",
		ProviderID:       "provider-a",
		Hostname:         "mac-a",
		ModelID:          "model-a",
		ModelParamsB:     7,
		RAMGB:            16,
		MaxContextTokens: 32768,
		MaxConcurrency:   maxConcurrency,
		BinaryVersion:    "1.8.48",
	}
}

func capacityOverClaimMetricValue(t *testing.T, reg *prometheus.Registry, phase string) float64 {
	t.Helper()
	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}
	for _, mf := range families {
		if mf.GetName() != "provider_capacity_over_claim_total" {
			continue
		}
		for _, metric := range mf.GetMetric() {
			for _, label := range metric.GetLabel() {
				if label.GetName() == "phase" && label.GetValue() == phase {
					return metric.GetCounter().GetValue()
				}
			}
		}
	}
	return 0
}

// Issue #764 AC (hello): an over-claiming registration is admitted but capped.
func TestHelloCapacityIsClampedToCeiling(t *testing.T) {
	t.Parallel()
	reg := prometheus.NewRegistry()
	server := NewServer(capacityTestConfig(8), pool.NewRegistry(nil), zerolog.Nop(),
		WithCapacityOverClaimMetrics(statsmetrics.New(reg)))

	entry, ok := server.prepareProviderAdmission(nil, providerAuth{validated: true, providerID: "provider-a"}, capacityTestHello(9999))
	if !ok || entry == nil {
		t.Fatal("prepareProviderAdmission rejected a well-formed hello")
	}
	if entry.MaxConcurrency != 8 || entry.SlotsTotal != 8 || entry.SlotsFree != 8 {
		t.Fatalf("clamped hello = (max %d, total %d, free %d), want (8, 8, 8)", entry.MaxConcurrency, entry.SlotsTotal, entry.SlotsFree)
	}
	if got := capacityOverClaimMetricValue(t, reg, capacityPhaseHello); got != 1 {
		t.Fatalf("hello tripwire = %v, want 1", got)
	}
}

func TestHelloCapacityWithinCeilingIsUntouched(t *testing.T) {
	t.Parallel()
	reg := prometheus.NewRegistry()
	server := NewServer(capacityTestConfig(8), pool.NewRegistry(nil), zerolog.Nop(),
		WithCapacityOverClaimMetrics(statsmetrics.New(reg)))

	entry, ok := server.prepareProviderAdmission(nil, providerAuth{validated: true, providerID: "provider-a"}, capacityTestHello(2))
	if !ok || entry == nil {
		t.Fatal("prepareProviderAdmission rejected a well-formed hello")
	}
	if entry.MaxConcurrency != 2 || entry.SlotsTotal != 2 || entry.SlotsFree != 2 {
		t.Fatalf("honest hello = (max %d, total %d, free %d), want (2, 2, 2)", entry.MaxConcurrency, entry.SlotsTotal, entry.SlotsFree)
	}
	if got := capacityOverClaimMetricValue(t, reg, capacityPhaseHello); got != 0 {
		t.Fatalf("hello tripwire = %v, want 0 for an honest claim", got)
	}
}

func registerCapacityTestProvider(t *testing.T, server *Server, registry *pool.Registry, maxConcurrency int) {
	t.Helper()
	entry, ok := server.prepareProviderAdmission(nil, providerAuth{validated: true, providerID: "provider-a"}, capacityTestHello(maxConcurrency))
	if !ok || entry == nil {
		t.Fatal("prepareProviderAdmission rejected a well-formed hello")
	}
	entry.AssignedID = "assigned-a"
	if _, registered := registry.RegisterAt(entry, nil, time.Now().UTC()); !registered {
		t.Fatal("register failed")
	}
}

// Issue #764 AC (heartbeat): the offending heartbeat is clamped AND increments
// the tripwire. Slot coherence is preserved across the clamp.
func TestHeartbeatCapacityIsClampedAndTripsTheWire(t *testing.T) {
	t.Parallel()
	reg := prometheus.NewRegistry()
	registry := pool.NewRegistry(nil)
	server := NewServer(capacityTestConfig(8), registry, zerolog.Nop(),
		WithCapacityOverClaimMetrics(statsmetrics.New(reg)))
	registerCapacityTestProvider(t, server, registry, 2)

	// 9999 total with 9990 free = 9 in use; after clamping to 8 total the
	// provider must not advertise more free slots than it has.
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":9999,"slots_free":9990,"slots_total":9999,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)

	snap := registry.Snapshot()
	if len(snap) != 1 {
		t.Fatalf("snapshot len = %d, want 1", len(snap))
	}
	if snap[0].MaxConcurrency != 8 || snap[0].SlotsTotal != 8 {
		t.Fatalf("clamped heartbeat = (max %d, total %d), want (8, 8)", snap[0].MaxConcurrency, snap[0].SlotsTotal)
	}
	if snap[0].SlotsFree > snap[0].SlotsTotal {
		t.Fatalf("slots_free %d exceeds slots_total %d", snap[0].SlotsFree, snap[0].SlotsTotal)
	}
	if got := capacityOverClaimMetricValue(t, reg, capacityPhaseHeartbeat); got != 1 {
		t.Fatalf("heartbeat tripwire = %v, want 1", got)
	}
}

// "Permanent" means monotonic: the counter keeps rising on every offending
// frame and never falls back when the provider starts behaving.
func TestCapacityOverClaimTripwireIsMonotonic(t *testing.T) {
	t.Parallel()
	reg := prometheus.NewRegistry()
	registry := pool.NewRegistry(nil)
	server := NewServer(capacityTestConfig(8), registry, zerolog.Nop(),
		WithCapacityOverClaimMetrics(statsmetrics.New(reg)))
	registerCapacityTestProvider(t, server, registry, 2)

	overClaim := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":9999,"slots_free":9999,"slots_total":9999,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)
	honest := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":2,"slots_free":2,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)

	for i := 0; i < 3; i++ {
		server.handleHeartbeat(nil, "provider-a", "assigned-a", overClaim)
	}
	if got := capacityOverClaimMetricValue(t, reg, capacityPhaseHeartbeat); got != 3 {
		t.Fatalf("tripwire after 3 offending heartbeats = %v, want 3 (counts every frame)", got)
	}
	server.handleHeartbeat(nil, "provider-a", "assigned-a", honest)
	if got := capacityOverClaimMetricValue(t, reg, capacityPhaseHeartbeat); got != 3 {
		t.Fatalf("tripwire after an honest heartbeat = %v, want 3 (never decrements)", got)
	}
	if snap := registry.Snapshot(); snap[0].MaxConcurrency != 2 {
		t.Fatalf("honest heartbeat max_concurrency = %d, want 2", snap[0].MaxConcurrency)
	}
}

// state_update is the third provider-controlled capacity ingest; leaving it
// unclamped would let a provider restore inflated free slots after a clamped
// heartbeat.
func TestStateUpdateSlotsAreClamped(t *testing.T) {
	t.Parallel()
	reg := prometheus.NewRegistry()
	registry := pool.NewRegistry(nil)
	server := NewServer(capacityTestConfig(8), registry, zerolog.Nop(),
		WithCapacityOverClaimMetrics(statsmetrics.New(reg)))
	registerCapacityTestProvider(t, server, registry, 2)

	payload := []byte(`{"type":"state_update","state":"ready","metrics_snapshot":{"slots_free":9999,"slots_total":9999}}`)
	server.handleStateUpdate("provider-a", "assigned-a", payload)

	// Audit R1 (security): the reference is the provider's LIVE clamped cap
	// (2), not the global ceiling (8) — otherwise a max-2 provider could hold
	// slots_total=8 via state_update until the next heartbeat, which is real
	// over-admission for HTTP-forwarding providers with no relay limiter.
	snap := registry.Snapshot()
	if snap[0].SlotsTotal != 2 || snap[0].SlotsFree != 2 {
		t.Fatalf("state_update slots = (total %d, free %d), want (2, 2) — the provider's live cap, not the ceiling", snap[0].SlotsTotal, snap[0].SlotsFree)
	}
	if got := capacityOverClaimMetricValue(t, reg, capacityPhaseStateUpdate); got != 1 {
		t.Fatalf("state_update tripwire = %v, want 1", got)
	}
}

// Audit R1 (security lane HIGH): a NEGATIVE max_concurrency claim must not
// pass through the clamp — the relay admission guard only enforces its cap
// when MaxConcurrency > 0, so an untouched -1 would disable concurrency
// admission entirely while inflated slots absorb routing.
func TestNegativeMaxConcurrencyClaimIsFloored(t *testing.T) {
	t.Parallel()
	reg := prometheus.NewRegistry()
	registry := pool.NewRegistry(nil)
	server := NewServer(capacityTestConfig(8), registry, zerolog.Nop(),
		WithCapacityOverClaimMetrics(statsmetrics.New(reg)))
	registerCapacityTestProvider(t, server, registry, 2)

	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":-1,"slots_free":9999,"slots_total":9999,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)

	snap := registry.Snapshot()
	if snap[0].MaxConcurrency != 1 {
		t.Fatalf("negative claim produced MaxConcurrency=%d, want floor 1 (relay cap must stay armed)", snap[0].MaxConcurrency)
	}
	if snap[0].SlotsTotal > 1 || snap[0].SlotsFree > 1 {
		t.Fatalf("negative claim slots = (total %d, free %d), want both <= 1", snap[0].SlotsTotal, snap[0].SlotsFree)
	}
	if got := capacityOverClaimMetricValue(t, reg, capacityPhaseHeartbeat); got < 1 {
		t.Fatalf("heartbeat tripwire = %v, want >= 1 for a nonsense claim", got)
	}
}

// A zero ceiling restores pre-#764 behavior exactly: no clamp, no tripwire.
func TestZeroCeilingDisablesClampAndTripwire(t *testing.T) {
	t.Parallel()
	reg := prometheus.NewRegistry()
	registry := pool.NewRegistry(nil)
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithCapacityOverClaimMetrics(statsmetrics.New(reg)))
	registerCapacityTestProvider(t, server, registry, 9999)

	if snap := registry.Snapshot(); snap[0].MaxConcurrency != 9999 {
		t.Fatalf("max_concurrency with ceiling 0 = %d, want the raw 9999", snap[0].MaxConcurrency)
	}
	if got := capacityOverClaimMetricValue(t, reg, capacityPhaseHello); got != 0 {
		t.Fatalf("hello tripwire with ceiling 0 = %v, want 0", got)
	}
}
