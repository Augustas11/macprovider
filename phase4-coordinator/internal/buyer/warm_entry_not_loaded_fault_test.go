package buyer_test

import (
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func reAdvertiseWarm(t *testing.T, registry *pool.Registry) {
	t.Helper()
	member := warmMember("model-b", false, 1)
	member.ThroughputTPSEstimate = 50
	if _, _, ok := registry.ApplyHeartbeat("pw", "pw-session", pool.HeartbeatUpdate{
		Status: pool.StateReady, ModelID: "model-a", MaxContextTokens: 20000, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1,
		ThroughputTPSEstimate: 50, WarmModels: []pool.WarmModel{warmMember("model-a", true, 1), member}, At: time.Now().UTC(),
	}); !ok {
		t.Fatal("heartbeat rejected")
	}
}

// A warm entry that answers model_not_loaded once is the genuine race: no
// breaker fault. One that keeps answering it across heartbeats that keep
// advertising it warm gets a breaker fault on its second strike within the
// window, and the answer takes the ordinary failure path.
func TestWarmEntryRepeatedModelNotLoadedIsABreakerFault(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWarmWSProvider(registry, "pw", 50)
	registerWithPath(registry, "p2", "p2-session", "model-b", pool.StateReady, 20000, 1, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
	evicted := &atomic.Bool{}
	evicted.Store(true)
	dispatches := &atomic.Int32{}
	server, _ := warmBillingServer(t, registry, warmNotLoadedRelay(evicted, dispatches))
	body := []byte(`{"model":"model-b","messages":[{"role":"user","content":"hi"}]}`)

	rr := postChat(t, server, body, http.Header{})
	if rr.Code != http.StatusOK || rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("first: status=%d provider=%q", rr.Code, rr.Header().Get("X-MacProvider-Provider"))
	}
	assertSessionUntouched(t, registry, "pw")

	reAdvertiseWarm(t, registry)
	// The second strike takes the ordinary failure path: no failover outside
	// the retry budget (the request carries none), so pw is the only dispatch.
	rr = postChat(t, server, body, http.Header{})
	if rr.Code != http.StatusServiceUnavailable || rr.Header().Get("X-MacProvider-Provider") == "p2" {
		t.Fatalf("second: status=%d provider=%q body=%s", rr.Code, rr.Header().Get("X-MacProvider-Provider"), rr.Body.String())
	}
	if dispatches.Load() != 3 {
		t.Fatalf("dispatches = %d, want 3 (pw, p2, then pw alone)", dispatches.Load())
	}
	// One breaker fault trips this server's breaker: the session leaves
	// routing for every entry.
	session, _ := registry.Resolve("pw", "pw-session")
	if session.RoutingEligible() {
		t.Fatalf("session after a repeated model_not_loaded = %s, want a breaker fault", session.State)
	}
}

// A provider cycling a member warm, refuse one dispatch with
// model_not_loaded, report it loading for one heartbeat, then warm again
// does not clear its strikes: the second refusal is a breaker fault.
func TestWarmEntryNotLoadedCycleThroughLoadingIsABreakerFault(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWarmWSProvider(registry, "pw", 50)
	registerWithPath(registry, "p2", "p2-session", "model-b", pool.StateReady, 20000, 1, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
	evicted := &atomic.Bool{}
	evicted.Store(true)
	dispatches := &atomic.Int32{}
	server, _ := warmBillingServer(t, registry, warmNotLoadedRelay(evicted, dispatches))
	body := []byte(`{"model":"model-b","messages":[{"role":"user","content":"hi"}]}`)

	if rr := postChat(t, server, body, http.Header{}); rr.Code != http.StatusOK || rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("first: status=%d provider=%q", rr.Code, rr.Header().Get("X-MacProvider-Provider"))
	}
	assertSessionUntouched(t, registry, "pw")

	loading := warmMember("model-b", false, 1)
	loading.State, loading.SlotsFree = pool.WarmModelLoading, 0
	if _, _, ok := registry.ApplyHeartbeat("pw", "pw-session", pool.HeartbeatUpdate{
		Status: pool.StateReady, ModelID: "model-a", MaxContextTokens: 20000, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1,
		ThroughputTPSEstimate: 50, WarmModels: []pool.WarmModel{warmMember("model-a", true, 1), loading}, At: time.Now().UTC(),
	}); !ok {
		t.Fatal("heartbeat rejected")
	}
	reAdvertiseWarm(t, registry)
	rr := postChat(t, server, body, http.Header{})
	if rr.Code != http.StatusServiceUnavailable || rr.Header().Get("X-MacProvider-Provider") == "p2" {
		t.Fatalf("second: status=%d provider=%q body=%s", rr.Code, rr.Header().Get("X-MacProvider-Provider"), rr.Body.String())
	}
	if session, _ := registry.Resolve("pw", "pw-session"); session.RoutingEligible() {
		t.Fatalf("session after the warm/refuse/loading cycle = %s, want a breaker fault", session.State)
	}
}
