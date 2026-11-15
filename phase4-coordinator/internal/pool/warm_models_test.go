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
	// model-a left the set in the same heartbeat: its open dispatch ending
	// (completion, refusal, drop) never touches model-b's session counts.
	free := session.SlotsFree
	if registry.RestoreForwardedSlotFor("p1", "current", "model-a") || registry.MarkForwardedSlotFullFor("p1", "current", "MODEL-A", true) ||
		registry.DropForwardedInFlightFor("p1", "current", "model-a") {
		t.Fatal("a dispatch on the departed primary resolved to the promoted session")
	}
	if _, ok := registry.ResolveEntry("p1", "current", "model-a"); ok {
		t.Fatal("the departed model resolved to the legacy session")
	}
	if got, _ := registry.Resolve("p1", "current"); registry.ForwardedInFlight("p1", "current") != 2 || got.SlotsFree != free || got.queueFullHold {
		t.Fatalf("departed model's dispatch moved the survivor: in_flight=%d free=%d hold=%v", registry.ForwardedInFlight("p1", "current"), got.SlotsFree, got.queueFullHold)
	}
	if !registry.RestoreForwardedSlotFor("p1", "current", "Model-B") || registry.ForwardedInFlight("p1", "current") != 1 {
		t.Fatalf("the survivor's own dispatch: in_flight=%d, want 1", registry.ForwardedInFlight("p1", "current"))
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

// A further member closed by a refusal reopens on the next ready heartbeat
// reporting free seats, while a long dispatch on it stays open; the lower
// count applies. Without such a report the hold stays.
func TestWarmMemberRefusalHoldLiftedByReadyHeartbeat(t *testing.T) {
	at := time.Now()
	registry := NewRegistry(nil)
	registry.Register(&Provider{
		ProviderID: "p1", AssignedID: "current", ModelID: "model-a", State: StateReady,
		SlotsFree: 2, SlotsTotal: 2, MaxConcurrency: 2, LastHeartbeatAt: at,
		WarmModels: warmTestMembers("model-a", warmTestMember("model-b", WarmModelWarm, 4, 4)),
	}, nil)
	members := func(free int) []WarmModel {
		return warmTestMembers("model-a", warmTestMember("model-b", WarmModelWarm, 4, free))
	}
	// One long dispatch, then a second one the provider refuses.
	for i := 0; i < 2; i++ {
		if ok, _ := registry.ConsumeForwardedSlotFor("p1", "current", "model-b"); !ok {
			t.Fatal("consume failed")
		}
	}
	if !registry.MarkForwardedSlotFullFor("p1", "current", "model-b", true) {
		t.Fatal("mark full failed")
	}
	if free, _ := registry.RoutableSlotsFreeFor("p1", "current", "model-b"); free != 0 {
		t.Fatalf("after refusal routable seats = %d, want 0", free)
	}
	// A busy heartbeat with no free member seat keeps the hold.
	update := warmHeartbeatUpdate(at.Add(time.Second), members(0))
	update.Status = StateBusy
	registry.ApplyHeartbeat("p1", "current", update)
	if b := warmEntry(t, registry, "model-b"); b.SlotsFree != 0 || b.RoutingEligible() {
		t.Fatalf("hold lifted without a free seat: free=%d", b.SlotsFree)
	}
	// The next heartbeat reports three free seats: the member reopens.
	registry.ApplyHeartbeat("p1", "current", warmHeartbeatUpdate(at.Add(2*time.Second), members(3)))
	if free, _ := registry.RoutableSlotsFreeFor("p1", "current", "model-b"); free != 3 {
		t.Fatalf("after ready heartbeat routable seats = %d, want 3", free)
	}
	if b := warmEntry(t, registry, "model-b"); !b.RoutingEligible() || registry.ForwardedInFlightFor("p1", "current", "model-b") != 1 {
		t.Fatalf("member not reopened: state=%s in_flight=%d", b.State, registry.ForwardedInFlightFor("p1", "current", "model-b"))
	}
	// The lower count applies: a report above the coordinator's own count
	// while the dispatch is open does not raise it.
	registry.ApplyHeartbeat("p1", "current", warmHeartbeatUpdate(at.Add(3*time.Second), members(4)))
	if free, _ := registry.RoutableSlotsFreeFor("p1", "current", "model-b"); free != 3 {
		t.Fatalf("stale higher report raised the count to %d", free)
	}
}

// A strike is one heartbeat generation in which an entry advertised warm
// answered model_not_loaded; strikes follow the member while it stays warm
// and reset when it reports another state or leaves the warm set.
func TestWarmEntryNotLoadedStrikes(t *testing.T) {
	at := time.Now()
	registry := NewRegistry(nil)
	registerWarmHeartbeatProvider(t, registry, at)
	record := func(d time.Duration) int {
		t.Helper()
		n, ok := registry.RecordEntryNotLoaded("p1", "current", "model-b", at.Add(d), 2*time.Minute)
		if !ok {
			t.Fatal("record failed")
		}
		return n
	}
	beat := func(d time.Duration, state WarmModelState) {
		t.Helper()
		if _, _, ok := registry.ApplyHeartbeat("p1", "current", warmHeartbeatUpdate(at.Add(d), warmTestMembers("model-a", warmTestMember("model-b", state, 2, 2)))); !ok {
			t.Fatal("heartbeat failed")
		}
	}
	if n := record(time.Second); n != 1 {
		t.Fatalf("first answer strikes = %d", n)
	}
	// A concurrent dispatch answering in the same race is no new strike.
	if n := record(2 * time.Second); n != 1 {
		t.Fatalf("same-generation answer strikes = %d, want 1", n)
	}
	beat(30*time.Second, WarmModelWarm)
	if n := record(31 * time.Second); n != 2 {
		t.Fatalf("answer after a re-advertising heartbeat strikes = %d, want 2", n)
	}
	// Outside the window old strikes no longer count.
	beat(4*time.Minute, WarmModelWarm)
	if n := record(4*time.Minute + time.Second); n != 1 {
		t.Fatalf("strikes after the window = %d, want 1", n)
	}
	// A heartbeat reporting the member loading resets its strikes.
	beat(5*time.Minute, WarmModelLoading)
	beat(5*time.Minute+30*time.Second, WarmModelWarm)
	if n := record(5*time.Minute + 31*time.Second); n != 1 {
		t.Fatalf("strikes after a non-warm report = %d, want 1", n)
	}
}

// A warm set shrinking to its primary makes a legacy session; a dispatch still
// open on the member that left never restores or holds the primary's seats.
func TestWarmShrinkToLegacyIgnoresDepartedMember(t *testing.T) {
	at := time.Now()
	for _, refusal := range []bool{false, true} {
		registry := NewRegistry(nil)
		registerWarmHeartbeatProvider(t, registry, at)
		registry.ConsumeForwardedSlotFor("p1", "current", "model-a")
		if ok, _ := registry.ConsumeForwardedSlotFor("p1", "current", "model-b"); !ok {
			t.Fatal("consume on model-b failed")
		}
		update := warmHeartbeatUpdate(at.Add(time.Second), warmTestMembers("model-a"))
		update.SlotsFree = 1
		if _, _, ok := registry.ApplyHeartbeat("p1", "current", update); !ok {
			t.Fatal("heartbeat failed")
		}
		before, _ := registry.Resolve("p1", "current")
		if before.WarmModels != nil {
			t.Fatal("one-member set kept")
		}
		var resolved bool
		if refusal {
			resolved = registry.MarkForwardedSlotFullFor("p1", "current", "model-b", true)
		} else {
			resolved = registry.RestoreForwardedSlotFor("p1", "current", "model-b")
		}
		if resolved {
			t.Fatalf("refusal=%v: the departed member resolved to the legacy session", refusal)
		}
		after, _ := registry.Resolve("p1", "current")
		if registry.ForwardedInFlight("p1", "current") != 1 || after.SlotsFree != before.SlotsFree || after.queueFullHold || after.capacitySafetyHold {
			t.Fatalf("refusal=%v: primary moved: in_flight=%d free=%d->%d hold=%v/%v", refusal,
				registry.ForwardedInFlight("p1", "current"), before.SlotsFree, after.SlotsFree, after.queueFullHold, after.capacitySafetyHold)
		}
		if free, ok := registry.RoutableSlotsFreeFor("p1", "current", "model-b"); ok || free != 0 {
			t.Fatalf("refusal=%v: departed member routable seats = %d %v", refusal, free, ok)
		}
		// The primary's own dispatch, named or legacy, still restores.
		if !registry.RestoreForwardedSlotFor("p1", "current", "MODEL-A") || registry.ForwardedInFlight("p1", "current") != 0 {
			t.Fatalf("refusal=%v: primary restore: in_flight=%d", refusal, registry.ForwardedInFlight("p1", "current"))
		}
	}
}

// A legacy session serving model-a whose heartbeat names model-b primary and
// keeps model-a as a further member: model-a's open dispatches, made with no
// served model, and its refusal hold move to model-a's member; the session
// (now model-b) starts clean, and each legacy dispatch ends on model-a.
func TestWarmLegacyModelDemotedToFurtherMember(t *testing.T) {
	at := time.Now()
	registry := NewRegistry(nil)
	registry.Register(&Provider{
		ProviderID: "p1", AssignedID: "current", ModelID: "model-a", State: StateReady,
		SlotsFree: 3, SlotsTotal: 3, MaxConcurrency: 3, LastHeartbeatAt: at, LastActivityAt: at,
	}, nil)
	for i := 0; i < 3; i++ {
		if ok, _ := registry.ConsumeForwardedSlotFor("p1", "current", ""); !ok {
			t.Fatal("legacy consume failed")
		}
	}
	// The third legacy dispatch is refused: model-a's seats are held.
	registry.MarkForwardedSlotFullFor("p1", "current", "", true)

	members := []WarmModel{
		{ModelID: "model-b", State: WarmModelWarm, Primary: true, SlotsTotal: 2, SlotsFree: 2},
		warmTestMember("Model-A", WarmModelWarm, 3, 0),
	}
	update := warmHeartbeatUpdate(at.Add(time.Second), members)
	if _, _, ok := registry.ApplyHeartbeat("p1", "current", update); !ok {
		t.Fatal("heartbeat failed")
	}
	session, _ := registry.Resolve("p1", "current")
	if session.WarmModels == nil || session.ModelID != "model-b" {
		t.Fatalf("warm set not applied: model=%s warm=%v", session.ModelID, session.WarmModels)
	}
	if registry.ForwardedInFlight("p1", "current") != 0 || session.queueFullHold || session.capacitySafetyHold || session.SlotsFree != 2 {
		t.Fatalf("new primary inherited model-a's state: in_flight=%d hold=%v/%v free=%d",
			registry.ForwardedInFlight("p1", "current"), session.queueFullHold, session.capacitySafetyHold, session.SlotsFree)
	}
	if n := registry.ForwardedInFlightFor("p1", "current", "model-a"); n != 2 {
		t.Fatalf("model-a in-flight = %d, want its 2 open legacy dispatches", n)
	}
	if free, _ := registry.RoutableSlotsFreeFor("p1", "current", "model-a"); free != 0 {
		t.Fatalf("model-a refusal hold lost: routable seats %d", free)
	}
	// A dispatch on model-b after the flip is the session's.
	if ok, _ := registry.ConsumeForwardedSlotFor("p1", "current", "model-b"); !ok {
		t.Fatal("model-b consume failed")
	}
	// The two legacy dispatches end on model-a, never on model-b.
	if !registry.RestoreForwardedSlotFor("p1", "current", "") {
		t.Fatal("legacy restore failed")
	}
	if !registry.DropForwardedInFlightFor("p1", "current", "") {
		t.Fatal("legacy drop failed")
	}
	if a, b := registry.ForwardedInFlightFor("p1", "current", "model-a"), registry.ForwardedInFlight("p1", "current"); a != 0 || b != 1 {
		t.Fatalf("after legacy ends: model-a=%d model-b=%d, want 0 and 1", a, b)
	}
	// Once they have ended, an empty served model is the primary again.
	if !registry.RestoreForwardedSlotFor("p1", "current", "") || registry.ForwardedInFlight("p1", "current") != 0 {
		t.Fatalf("empty served model after the drain: model-b=%d", registry.ForwardedInFlight("p1", "current"))
	}
}

// Growing a legacy session with its own model kept primary moves nothing.
func TestWarmLegacyGrowthKeepsPrimary(t *testing.T) {
	at := time.Now()
	registry := NewRegistry(nil)
	registry.Register(&Provider{
		ProviderID: "p1", AssignedID: "current", ModelID: "model-a", State: StateReady,
		SlotsFree: 2, SlotsTotal: 2, MaxConcurrency: 2, LastHeartbeatAt: at, LastActivityAt: at,
	}, nil)
	registry.ConsumeForwardedSlotFor("p1", "current", "")
	update := warmHeartbeatUpdate(at.Add(time.Second), warmTestMembers("model-a", warmTestMember("model-b", WarmModelWarm, 2, 2)))
	update.SlotsFree = 1
	registry.ApplyHeartbeat("p1", "current", update)
	if registry.ForwardedInFlight("p1", "current") != 1 || registry.ForwardedInFlightFor("p1", "current", "model-b") != 0 {
		t.Fatalf("growth moved counts: a=%d b=%d", registry.ForwardedInFlight("p1", "current"), registry.ForwardedInFlightFor("p1", "current", "model-b"))
	}
	if !registry.RestoreForwardedSlotFor("p1", "current", "") || registry.ForwardedInFlight("p1", "current") != 0 {
		t.Fatal("legacy dispatch did not end on the primary")
	}
}
