package ws

import (
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestWSIngressDelayedBusyAfterRestoreDoesNotZeroSeats(t *testing.T) {
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
	now = now.Add(pool.OccupancySettleWindow + time.Second)
	nowMu.Unlock()
	server.handleHeartbeat(nil, "provider-a", "assigned-a", busy)
	got, ok = registry.Resolve("provider-a", "assigned-a")
	if !ok {
		t.Fatal("provider missing after thermal heartbeat")
	}
	if got.SlotsFree != 0 || got.State != pool.StateBusy {
		t.Fatalf("after thermal WS busy heartbeat = state %q slots_free %d, want busy/0", got.State, got.SlotsFree)
	}
}

func TestWSIngressInFlightBusyAfterSettleWindowDoesNotZeroRestoredSeat(t *testing.T) {
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
	now = now.Add(pool.OccupancySettleWindow + time.Second)
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
