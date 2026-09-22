package ws

import (
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestProvisionalLoopbackHTTPEndpointRejectsUserinfoSSRF(t *testing.T) {
	t.Parallel()
	okCases := []string{
		"http://127.0.0.1:18083",
		"http://localhost:18083",
		"http://[::1]:18083",
	}
	for _, raw := range okCases {
		got, ok := provisionalLoopbackHTTPEndpoint(raw)
		if !ok {
			t.Fatalf("%q rejected, want loopback HTTP endpoint", raw)
		}
		if got == "" {
			t.Fatalf("%q accepted with empty endpoint", raw)
		}
	}
	bad := []string{
		"http://127.0.0.1:80@169.254.169.254/latest/meta-data",
		"http://127.0.0.1:18083@evil.example",
		"http://127.0.0.1:18083/v1/chat",
		"http://127.0.0.1:18083/?x=1",
		"https://127.0.0.1:18083",
		"http://example.com:18083",
		"http://127.0.0.1",
		"not-a-url",
	}
	for _, raw := range bad {
		if got, ok := provisionalLoopbackHTTPEndpoint(raw); ok {
			t.Fatalf("%q accepted as %q, want reject", raw, got)
		}
	}
	if got, ok := admitProvisionalLoopbackHTTP(false, "http://127.0.0.1:18083"); ok {
		t.Fatalf("disabled loopback HTTP admitted %q", got)
	}
	if _, ok := admitProvisionalLoopbackHTTP(true, "http://127.0.0.1:18083"); !ok {
		t.Fatal("enabled loopback HTTP rejected 127.0.0.1:18083")
	}
}

func TestWSIngressDelayedBusyHeldUntilReadyAndThermalBlocksRestore(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	var nowMu sync.Mutex
	now := time.Now().UTC()
	server := NewServer(capacityTestConfig(8), registry, zerolog.Nop(),
		WithNow(func() time.Time {
			nowMu.Lock()
			defer nowMu.Unlock()
			return now
		}))
	registerCapacityTestProvider(t, server, registry, 4)

	for i := 0; i < 4; i++ {
		if !registry.ConsumeForwardedSlot("provider-a", "assigned-a") {
			t.Fatal("ConsumeForwardedSlot returned false")
		}
	}
	for i := 0; i < 4; i++ {
		if !registry.RestoreForwardedSlot("provider-a", "assigned-a") {
			t.Fatal("RestoreForwardedSlot returned false")
		}
	}
	got, ok := registry.Resolve("provider-a", "assigned-a")
	if !ok {
		t.Fatal("provider missing after restore")
	}
	if got.SlotsFree != 4 {
		t.Fatalf("after restore slots_free=%d, want 4", got.SlotsFree)
	}

	// Production stamps At with s.now() at handle time. A delayed
	// slots_free=0 handled just after restore must not wipe the seats.
	busy := []byte(`{"type":"heartbeat","status":"busy","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":4,"slots_free":0,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", busy)
	got, ok = registry.Resolve("provider-a", "assigned-a")
	if !ok {
		t.Fatal("provider missing after delayed heartbeat")
	}
	if got.SlotsFree != 4 || got.State != pool.StateReady {
		t.Fatalf("after delayed WS busy heartbeat = state %q slots_free %d, want ready/4", got.State, got.SlotsFree)
	}

	stateBusy := []byte(`{"type":"state_update","state":"busy","metrics_snapshot":{"slots_free":0,"slots_total":4}}`)
	server.handleStateUpdate("provider-a", "assigned-a", stateBusy)
	got, ok = registry.Resolve("provider-a", "assigned-a")
	if !ok {
		t.Fatal("provider missing after delayed state_update")
	}
	if got.SlotsFree != 4 || got.State != pool.StateReady {
		t.Fatalf("after delayed WS busy state_update = state %q slots_free %d, want ready/4", got.State, got.SlotsFree)
	}

	nowMu.Lock()
	now = now.Add(10 * time.Second)
	nowMu.Unlock()
	server.handleHeartbeat(nil, "provider-a", "assigned-a", busy)
	got, ok = registry.Resolve("provider-a", "assigned-a")
	if !ok {
		t.Fatal("provider missing after late busy heartbeat")
	}
	if got.SlotsFree != 4 || got.State != pool.StateReady {
		t.Fatalf("after late WS busy heartbeat = state %q slots_free %d, want ready/4", got.State, got.SlotsFree)
	}
	thermal := []byte(`{"type":"state_update","state":"busy","reason":"thermal_throttled","metrics_snapshot":{"slots_free":0,"slots_total":4}}`)
	server.handleStateUpdate("provider-a", "assigned-a", thermal)
	registry.RestoreForwardedSlot("provider-a", "assigned-a")
	got, _ = registry.Resolve("provider-a", "assigned-a")
	if got.SlotsFree != 0 || got.RoutingEligible() {
		t.Fatalf("thermal WS state_update reopened capacity: state %q slots_free %d", got.State, got.SlotsFree)
	}
	ready := []byte(`{"type":"state_update","state":"ready","reason":"request_capacity_available","metrics_snapshot":{"slots_free":4,"slots_total":4}}`)
	server.handleStateUpdate("provider-a", "assigned-a", ready)
	got, _ = registry.Resolve("provider-a", "assigned-a")
	if got.SlotsFree != 4 || !got.RoutingEligible() {
		t.Fatalf("ready WS state_update failed to reopen capacity: state %q slots_free %d", got.State, got.SlotsFree)
	}
}

func TestWSIngressInFlightBusyDoesNotZeroRestoredSeat(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	var nowMu sync.Mutex
	now := time.Now().UTC()
	server := NewServer(capacityTestConfig(8), registry, zerolog.Nop(),
		WithNow(func() time.Time {
			nowMu.Lock()
			defer nowMu.Unlock()
			return now
		}))
	registerCapacityTestProvider(t, server, registry, 8)

	for i := 0; i < 8; i++ {
		if !registry.ConsumeForwardedSlot("provider-a", "assigned-a") {
			t.Fatal("ConsumeForwardedSlot returned false")
		}
	}
	if !registry.RestoreForwardedSlot("provider-a", "assigned-a") {
		t.Fatal("RestoreForwardedSlot returned false")
	}
	got, ok := registry.Resolve("provider-a", "assigned-a")
	if !ok {
		t.Fatal("provider missing after restore")
	}
	if got.SlotsFree != 1 {
		t.Fatalf("after one restore slots_free=%d, want 1", got.SlotsFree)
	}

	nowMu.Lock()
	now = now.Add(10 * time.Second)
	nowMu.Unlock()
	busy := []byte(`{"type":"heartbeat","status":"busy","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":8,"slots_free":0,"slots_total":8,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", busy)
	got, ok = registry.Resolve("provider-a", "assigned-a")
	if !ok {
		t.Fatal("provider missing after in-flight busy heartbeat")
	}
	if got.SlotsFree != 1 || got.State != pool.StateReady {
		t.Fatalf("after in-flight WS busy heartbeat = state %q slots_free %d, want ready/1", got.State, got.SlotsFree)
	}
}

func TestWSIngressMetricsFreeBusyStateUpdateDoesNotFlipRestoredSeat(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	var nowMu sync.Mutex
	now := time.Now().UTC()
	server := NewServer(capacityTestConfig(4), registry, zerolog.Nop(),
		WithNow(func() time.Time {
			nowMu.Lock()
			defer nowMu.Unlock()
			return now
		}))
	registerCapacityTestProvider(t, server, registry, 4)
	for i := 0; i < 4; i++ {
		if !registry.RestoreForwardedSlot("provider-a", "assigned-a") {
			t.Fatal("RestoreForwardedSlot returned false")
		}
	}
	got, ok := registry.Resolve("provider-a", "assigned-a")
	if !ok {
		t.Fatal("provider missing after restore")
	}
	if got.SlotsFree != 4 || got.State != pool.StateReady {
		t.Fatalf("after restore = state %q slots_free %d, want ready/4", got.State, got.SlotsFree)
	}
	bareBusy := []byte(`{"type":"state_update","state":"busy"}`)
	server.handleStateUpdate("provider-a", "assigned-a", bareBusy)
	got, ok = registry.Resolve("provider-a", "assigned-a")
	if !ok {
		t.Fatal("provider missing after metrics-free busy state_update")
	}
	if got.SlotsFree != 4 || got.State != pool.StateReady {
		t.Fatalf("after metrics-free busy state_update = state %q slots_free %d, want ready/4", got.State, got.SlotsFree)
	}
}
