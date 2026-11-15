package pool

import (
	"reflect"
	"testing"
	"time"
)

// registerTwin registers the same session on a legacy registry (no warm set)
// and on one whose handshake carries a warm set of exactly one member.
func registerTwin(t *testing.T, at time.Time) (legacy, single *Registry) {
	t.Helper()
	base := func(warm []WarmModel) *Provider {
		return &Provider{
			ProviderID: "p1", AssignedID: "current", ModelID: "model-a", State: StateReady,
			SlotsFree: 2, SlotsTotal: 2, MaxConcurrency: 2, MaxContextTokens: 20000, ThroughputTPSEstimate: 20,
			LastHeartbeatAt: at, LastActivityAt: at, WarmModels: warm,
		}
	}
	legacy, single = NewRegistry(nil), NewRegistry(nil)
	legacy.Register(base(nil), nil)
	single.Register(base(warmTestMembers("model-a")), nil)
	return legacy, single
}

// A warm set of exactly one member is a legacy session: no entry view, no
// served model, legacy sort key, no entry model_not_loaded mark.
func TestWarmSetOfOneIsALegacySession(t *testing.T) {
	at := time.Now()
	legacy, single := registerTwin(t, at)
	check := func(stage string) {
		t.Helper()
		want, _ := legacy.Resolve("p1", "current")
		got, _ := single.Resolve("p1", "current")
		if got.WarmModels != nil {
			t.Fatalf("%s: one-member warm set kept: %+v", stage, got.WarmModels)
		}
		if !reflect.DeepEqual(single.EntrySnapshot(), legacy.EntrySnapshot()) || !reflect.DeepEqual(got, want) {
			t.Fatalf("%s: one-member session differs from legacy:\n%+v\n%+v", stage, got, want)
		}
		entry, ok := single.ResolveEntry("p1", "current", "model-a")
		if !ok || entry.ServedModelID != "" || entry.SortKey() != "p1/current" {
			t.Fatalf("%s: entry = %q %q", stage, entry.ServedModelID, entry.SortKey())
		}
		if single.MarkEntryNotLoaded("p1", "current", "model-a") {
			t.Fatalf("%s: a one-member session took an entry model_not_loaded mark", stage)
		}
	}
	check("register")
	update := heartbeatUpdateAt("model-a", at.Add(time.Second))
	update.MaxConcurrency, update.SlotsTotal, update.SlotsFree = 2, 2, 2
	legacy.ApplyHeartbeat("p1", "current", update)
	update.WarmModels = warmTestMembers("model-a")
	single.ApplyHeartbeat("p1", "current", update)
	check("heartbeat")
}

// A SPEC-011 warm swap A to B on a one-member session keeps the legacy swap
// handling: the in-flight count and occupancy guards are the session's.
func TestWarmSetOfOneSwapKeepsLegacyHandling(t *testing.T) {
	at := time.Now()
	legacy, single := registerTwin(t, at)
	for _, r := range []*Registry{legacy, single} {
		if ok, _ := r.ConsumeForwardedSlotFor("p1", "current", ""); !ok {
			t.Fatal("consume failed")
		}
		r.mu.Lock()
		p := r.providers["p1"]
		p.awaitingReadyOccupancy = true
		p.queueFullHold = true
		p.capacitySafetyHold = true
		r.mu.Unlock()
	}
	update := heartbeatUpdateAt("model-b", at.Add(time.Second))
	update.MaxConcurrency, update.SlotsTotal, update.SlotsFree = 2, 2, 2
	legacy.ApplyHeartbeat("p1", "current", update)
	swap := warmTestMembers("model-b")
	update.WarmModels = swap
	single.ApplyHeartbeat("p1", "current", update)

	legacy.mu.RLock()
	single.mu.RLock()
	want, got := legacy.providers["p1"], single.providers["p1"]
	if got.forwardedInFlight != 1 || got.forwardedInFlight != want.forwardedInFlight ||
		got.awaitingReadyOccupancy != want.awaitingReadyOccupancy || got.queueFullHold != want.queueFullHold ||
		got.capacitySafetyHold != want.capacitySafetyHold || got.SlotsFree != want.SlotsFree {
		t.Fatalf("one-member swap: in_flight=%d awaiting=%v qfh=%v hold=%v free=%d; legacy %d %v %v %v %d",
			got.forwardedInFlight, got.awaitingReadyOccupancy, got.queueFullHold, got.capacitySafetyHold, got.SlotsFree,
			want.forwardedInFlight, want.awaitingReadyOccupancy, want.queueFullHold, want.capacitySafetyHold, want.SlotsFree)
	}
	single.mu.RUnlock()
	legacy.mu.RUnlock()
}

// Promotion runs when the incoming primary was a further member, also when
// the new warm set has one member; a primary from outside the set does not
// promote.
func TestWarmPromotionOnlyFromAFurtherMember(t *testing.T) {
	at := time.Now()
	registry := NewRegistry(nil)
	registerWarmHeartbeatProvider(t, registry, at)
	registry.ConsumeForwardedSlotFor("p1", "current", "model-a")
	registry.ConsumeForwardedSlotFor("p1", "current", "model-b")
	registry.ConsumeForwardedSlotFor("p1", "current", "model-b")
	promoted := WarmModel{ModelID: "model-b", State: WarmModelWarm, Primary: true, SlotsTotal: 2, SlotsFree: 0}
	if _, _, ok := registry.ApplyHeartbeat("p1", "current", warmHeartbeatUpdate(at.Add(time.Second), []WarmModel{promoted})); !ok {
		t.Fatal("heartbeat failed")
	}
	session, _ := registry.Resolve("p1", "current")
	if session.WarmModels != nil || session.ModelID != "model-b" || registry.ForwardedInFlight("p1", "current") != 2 {
		t.Fatalf("promotion to a one-member set: model=%s in_flight=%d warm=%v", session.ModelID, registry.ForwardedInFlight("p1", "current"), session.WarmModels)
	}

	// A swap to a model outside the warm set keeps the session's count.
	registry = NewRegistry(nil)
	registerWarmHeartbeatProvider(t, registry, at)
	registry.ConsumeForwardedSlotFor("p1", "current", "model-a")
	outside := warmTestMembers("model-z", warmTestMember("model-b", WarmModelWarm, 2, 2))
	if _, _, ok := registry.ApplyHeartbeat("p1", "current", warmHeartbeatUpdate(at.Add(time.Second), outside)); !ok {
		t.Fatal("heartbeat failed")
	}
	if n := registry.ForwardedInFlight("p1", "current"); n != 1 {
		t.Fatalf("swap from outside the warm set moved the session count: %d", n)
	}
}
