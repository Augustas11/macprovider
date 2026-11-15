package pool

import (
	"reflect"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
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

// SPEC-036 FR-25 per entry: a suspended (provider, model) key closes the
// entry serving that model only, whichever member serves it.
func TestComputeIntegritySuspensionIsPerEntry(t *testing.T) {
	at := time.Now()
	registry := NewRegistry(nil)
	registerWarmHeartbeatProvider(t, registry, at)

	// A suspended further member leaves the primary and the session routable.
	registry.SetComputeIntegritySuspended("p1", "MODEL-B", true)
	if b := warmEntry(t, registry, "model-b"); !b.ComputeIntegritySuspended || b.RoutingEligible() {
		t.Fatalf("suspended member routable: suspended=%v", b.ComputeIntegritySuspended)
	}
	if a := warmEntry(t, registry, "model-a"); a.ComputeIntegritySuspended || !a.RoutingEligible() {
		t.Fatal("member suspension closed the primary entry")
	}

	// Promotion: model-b becomes primary, then model-a is promoted back while
	// model-b stays a member; model-b stays suspended throughout.
	b := WarmModel{ModelID: "model-b", State: WarmModelWarm, Primary: true, SlotsTotal: 2, SlotsFree: 2}
	if _, _, ok := registry.ApplyHeartbeat("p1", "current", warmHeartbeatUpdate(at.Add(time.Second), []WarmModel{b, warmTestMember("model-a", WarmModelWarm, 2, 2)})); !ok {
		t.Fatal("heartbeat failed")
	}
	if entry := warmEntry(t, registry, "model-b"); !entry.ComputeIntegritySuspended || entry.RoutingEligible() {
		t.Fatal("suspended model routable after its promotion")
	}
	if entry := warmEntry(t, registry, "model-a"); entry.ComputeIntegritySuspended || !entry.RoutingEligible() {
		t.Fatal("healthy member closed by the suspended primary")
	}
	if _, _, ok := registry.ApplyHeartbeat("p1", "current", warmHeartbeatUpdate(at.Add(2*time.Second), warmTestMembers("model-a", warmTestMember("model-b", WarmModelWarm, 2, 2)))); !ok {
		t.Fatal("heartbeat failed")
	}
	if entry := warmEntry(t, registry, "model-b"); !entry.ComputeIntegritySuspended || entry.RoutingEligible() {
		t.Fatal("suspended model routable again after demotion to a further member")
	}
	if session, _ := registry.Resolve("p1", "current"); session.ComputeIntegritySuspended {
		t.Fatal("a member's suspension reached the session")
	}

	// Reverse: a suspended primary does not close a healthy member.
	registry.SetComputeIntegritySuspended("p1", "model-b", false)
	registry.SetComputeIntegritySuspended("p1", "model-a", true)
	if a := warmEntry(t, registry, "model-a"); !a.ComputeIntegritySuspended || a.RoutingEligible() {
		t.Fatal("suspended primary entry routable")
	}
	if b := warmEntry(t, registry, "model-b"); b.ComputeIntegritySuspended || !b.RoutingEligible() {
		t.Fatalf("suspended primary closed a healthy member: suspended=%v state=%s", b.ComputeIntegritySuspended, b.State)
	}
}

// SPEC-010-R007(b)(c) per member: a further member that verifies as one feed
// identity and later reports another becomes hash_mismatch exactly as the
// primary does; the pin resets only when the member leaves the warm set.
func TestWarmMemberIdentityPin(t *testing.T) {
	resolver := WithModelIdentityResolver(func(req ModelIdentityRequest) ModelIdentityVerdict {
		switch req.ReportedHash {
		case "h1", "h2":
			return ModelIdentityVerdict{Status: HashStatusVerified, Artifact: &artifactidentity.Binding{Member: artifactidentity.Member{ModelID: req.ModelID, ArtifactID: "art-" + req.ReportedHash, Hash: req.ReportedHash}}}
		}
		return ModelIdentityVerdict{Status: HashStatusUncatalogued}
	})
	at := time.Now()
	registry := NewRegistry(nil, resolver)
	registerHeartbeatProvider(t, registry, "model-a", "h1", HashStatusVerified, at)
	member := func(hash string) WarmModel {
		m := warmTestMember("model-b", WarmModelWarm, 1, 1)
		m.ModelHash = hash
		return m
	}
	beat := func(i int, primaryHash string, members ...WarmModel) {
		t.Helper()
		update := warmHeartbeatUpdate(at.Add(time.Duration(i)*time.Second), warmTestMembers("model-a", members...))
		update.ModelHash, update.ModelHashPresent = primaryHash, true
		if _, _, ok := registry.ApplyHeartbeat("p1", "current", update); !ok {
			t.Fatal("heartbeat failed")
		}
	}
	beat(1, "h1", member("h1"))
	if b := warmEntry(t, registry, "model-b"); b.HashStatus != HashStatusVerified || b.IdentityPin == nil {
		t.Fatalf("member first verdict = %s pin=%v", b.HashStatus, b.IdentityPin)
	}
	// Both the primary and the member switch to another verified identity.
	beat(2, "h2", member("h2"))
	session, _ := registry.Resolve("p1", "current")
	if session.HashStatus != HashStatusMismatch {
		t.Fatalf("primary identity change = %s, want hash_mismatch", session.HashStatus)
	}
	if b := warmEntry(t, registry, "model-b"); b.HashStatus != HashStatusMismatch {
		t.Fatalf("member identity change = %s, want hash_mismatch like the primary", b.HashStatus)
	}
	// A release refresh keeps the member's pin.
	registry.UpdateModelIdentities(func(p Provider) ModelIdentityVerdict {
		return ModelIdentityVerdict{Status: HashStatusVerified, Artifact: &artifactidentity.Binding{Member: artifactidentity.Member{ModelID: p.ModelID, ArtifactID: "art-" + p.ModelHash, Hash: p.ModelHash}}}
	})
	if b := warmEntry(t, registry, "model-b"); b.HashStatus != HashStatusMismatch {
		t.Fatalf("member after refresh = %s, want hash_mismatch (pin kept)", b.HashStatus)
	}
	// Leaving the warm set resets the member's pin.
	beat(3, "h2")
	beat(4, "h2", member("h2"))
	if b := warmEntry(t, registry, "model-b"); b.HashStatus != HashStatusVerified {
		t.Fatalf("member back in the warm set = %s, want verified with a fresh pin", b.HashStatus)
	}
}
