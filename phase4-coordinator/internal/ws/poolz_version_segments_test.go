package ws

import (
	"testing"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/pow"
)

// Issue #764 AC: per-backend TTFT/TPS must be segmentable.
func TestPoolzVersionSegmentsSeparatesBackendLatency(t *testing.T) {
	t.Parallel()
	providers := []pool.Provider{
		{
			ProviderID: "fast-1", BinaryVersion: "1.8.48", ModelID: "model-a",
			State: pool.StateReady, SlotsTotal: 2, SlotsFree: 2,
			CanaryLastTTFTMS: 800, CanaryLastSustainedTPS: 20, ThroughputTPSEstimate: 21,
		},
		{
			ProviderID: "fast-2", BinaryVersion: "1.8.48", ModelID: "model-b",
			State: pool.StateReady, SlotsTotal: 2, SlotsFree: 0,
			CanaryLastTTFTMS: 1200, CanaryLastSustainedTPS: 10, ThroughputTPSEstimate: 11,
		},
		{
			ProviderID: "slow-1", BinaryVersion: "1.8.40", ModelID: "model-a",
			State: pool.StateReady, SlotsTotal: 1, SlotsFree: 1,
			CanaryLastTTFTMS: 9000, CanaryLastSustainedTPS: 2, ThroughputTPSEstimate: 19,
		},
		{
			// Never probed and no version: contributes to counts only.
			ProviderID: "unprobed", ModelID: "model-a",
			State: pool.StateReady, SlotsTotal: 1, SlotsFree: 1,
		},
	}
	segments := poolzVersionSegments(providers)
	if len(segments) != 3 {
		t.Fatalf("segments = %d, want 3 (1.8.48, 1.8.40, unknown)", len(segments))
	}

	fast := segments["1.8.48"]
	if fast.Providers != 2 || fast.RoutingEligible != 1 || fast.SlotsTotal != 4 || fast.SlotsFree != 2 {
		t.Fatalf("1.8.48 counts = %+v", fast)
	}
	if fast.CanaryTTFTMSAvg == nil || *fast.CanaryTTFTMSAvg != 1000 {
		t.Fatalf("1.8.48 ttft avg = %v, want 1000", fast.CanaryTTFTMSAvg)
	}
	if fast.CanaryTTFTMSMax == nil || *fast.CanaryTTFTMSMax != 1200 {
		t.Fatalf("1.8.48 ttft max = %v, want 1200", fast.CanaryTTFTMSMax)
	}
	if fast.CanaryTPSAvg == nil || *fast.CanaryTPSAvg != 15 {
		t.Fatalf("1.8.48 tps avg = %v, want 15", fast.CanaryTPSAvg)
	}
	if len(fast.Models) != 2 || fast.Models[0] != "model-a" || fast.Models[1] != "model-b" {
		t.Fatalf("1.8.48 models = %v, want sorted [model-a model-b]", fast.Models)
	}

	slow := segments["1.8.40"]
	if slow.CanaryTTFTMSAvg == nil || *slow.CanaryTTFTMSAvg != 9000 {
		t.Fatalf("1.8.40 ttft avg = %v, want 9000 (the slow backend is separable)", slow.CanaryTTFTMSAvg)
	}
	// The reported estimate does NOT expose the regression; the measured value
	// does. Keeping both in one block is the point of the segmentation.
	if slow.ReportedTPSAvg == nil || *slow.ReportedTPSAvg != 19 {
		t.Fatalf("1.8.40 reported tps avg = %v, want 19", slow.ReportedTPSAvg)
	}

	unknown := segments[poolzUnknownBinaryVersion]
	if unknown.Providers != 1 {
		t.Fatalf("unknown providers = %d, want 1", unknown.Providers)
	}
	if unknown.CanaryTTFTSamples != 0 || unknown.CanaryTTFTMSAvg != nil {
		t.Fatalf("unprobed provider must not report a latency average: %+v", unknown)
	}
}

func TestPoolzVersionSegmentsEmptyPool(t *testing.T) {
	t.Parallel()
	if got := poolzVersionSegments(nil); len(got) != 0 {
		t.Fatalf("segments for an empty pool = %v, want empty", got)
	}
}

// Issue #765 wiring: the verdict is applied to the pool only for the two
// decisive values; Unknown must leave the flag exactly as it was.
func TestApplyBenchmarkQuarantineHonoursVerdict(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	server := NewServer(capacityTestConfig(8), registry, zerolog.Nop())
	registerCapacityTestProvider(t, server, registry, 2)
	_, generation := server.telemetryDriftEvaluator()

	quarantined := func() bool { return registry.Snapshot()[0].BenchmarkQuarantined }

	server.applyBenchmarkQuarantine("provider-a", "assigned-a", "model-a", pow.BenchmarkVerdictUnknown, generation)
	if quarantined() {
		t.Fatal("Unknown verdict must not quarantine")
	}
	server.applyBenchmarkQuarantine("provider-a", "assigned-a", "model-a", pow.BenchmarkVerdictMissing, generation)
	if !quarantined() {
		t.Fatal("Missing verdict must quarantine")
	}
	if registry.Snapshot()[0].RoutingEligible() {
		t.Fatal("a quarantined provider must not be routed buyer traffic")
	}
	// A store blip mid-quarantine must not release the provider.
	server.applyBenchmarkQuarantine("provider-a", "assigned-a", "model-a", pow.BenchmarkVerdictUnknown, generation)
	if !quarantined() {
		t.Fatal("Unknown verdict must not release an existing quarantine")
	}
	server.applyBenchmarkQuarantine("provider-a", "assigned-a", "model-a", pow.BenchmarkVerdictVerified, generation)
	if quarantined() {
		t.Fatal("Verified verdict must release the quarantine")
	}
	if !registry.Snapshot()[0].RoutingEligible() {
		t.Fatal("a released provider must be routable again")
	}
}

func TestApplyBenchmarkQuarantineSkipsStaleTelemetryGeneration(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	server := NewServer(capacityTestConfig(8), registry, zerolog.Nop())
	registerCapacityTestProvider(t, server, registry, 2)
	_, staleGeneration := server.telemetryDriftEvaluator()

	server.SetTelemetryDriftEvaluator(nil)
	server.applyBenchmarkQuarantine("provider-a", "assigned-a", "model-a", pow.BenchmarkVerdictMissing, staleGeneration)
	if registry.Snapshot()[0].BenchmarkQuarantined {
		t.Fatal("stale telemetry generation must not reapply benchmark quarantine after reload")
	}
	_, currentGeneration := server.telemetryDriftEvaluator()
	server.applyBenchmarkQuarantine("provider-a", "assigned-a", "model-a", pow.BenchmarkVerdictMissing, currentGeneration)
	if !registry.Snapshot()[0].BenchmarkQuarantined {
		t.Fatal("current telemetry generation must still apply decisive benchmark verdict")
	}
}

// Default posture pin: with no drift evaluator wired (the shipping default) a
// heartbeat never touches the quarantine flag, so routing is unchanged.
func TestHeartbeatWithoutDriftEvaluatorNeverQuarantines(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	cfg := capacityTestConfig(8)
	if cfg.ProofOfWeights.TelemetryDrift.Enabled || cfg.ProofOfWeights.TelemetryDrift.QuarantineMissingBenchmark {
		t.Fatal("config.Default() must keep the drift quarantine dormant")
	}
	server := NewServer(cfg, registry, zerolog.Nop())
	registerCapacityTestProvider(t, server, registry, 2)

	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":2,"slots_free":2,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)

	snap := registry.Snapshot()
	if snap[0].BenchmarkQuarantined {
		t.Fatal("an un-benchmarked provider must stay routable while the gate is off")
	}
	if !snap[0].RoutingEligible() {
		t.Fatal("default posture changed provider routing eligibility")
	}
}
