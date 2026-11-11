package pool

import (
	"testing"
	"time"
)

func registerCoverProvider(t *testing.T, mutate func(*Provider)) (*Registry, *Provider) {
	t.Helper()
	r := NewRegistry(nil)
	p := quarantineTestProvider()
	if mutate != nil {
		mutate(p)
	}
	if _, ok := r.RegisterAt(p, nil, time.Now().UTC()); !ok {
		t.Fatal("register failed")
	}
	return r, p
}

func TestShardMemberAdmissibleExclusions(t *testing.T) {
	t.Parallel()
	if !quarantineTestProvider().ShardMemberAdmissible() {
		t.Fatal("baseline ready provider must be admissible")
	}
	cases := map[string]func(*Provider){
		"bearerless":  func(p *Provider) { p.AuthState = AuthBearerlessDuplicate },
		"self-minted": func(p *Provider) { p.AuthState = AuthSelfMinted },
		"legacy":      func(p *Provider) { p.CatalogAdmissionMode = "legacy" },
		"bridge":      func(p *Provider) { p.CatalogAdmissionMode = "update_bridge" },
		"pending-key": func(p *Provider) { p.PendingReceiptPubkey = []byte{1} },
		"quarantine":  func(p *Provider) { p.BenchmarkQuarantined = true },
		"integrity":   func(p *Provider) { p.ComputeIntegritySuspended = true },
		"scorer":      func(p *Provider) { p.ComputeScoreReference = true },
		"ceiling":     func(p *Provider) { p.AdmissionCeilingExcluded = true },
		"stale":       func(p *Provider) { p.AdmissionEvidenceStale = true },
		"sandboxed":   func(p *Provider) { p.AdmissionSandboxed = true },
		"recheck":     func(p *Provider) { p.CatalogRecheckPending = true },
		"ack-pending": func(p *Provider) { p.HandshakeAckPending = true },
		"safety-hold": func(p *Provider) { p.capacitySafetyHold = true },
		"offline":     func(p *Provider) { p.State = StateDegraded },
	}
	for name, mutate := range cases {
		p := quarantineTestProvider()
		mutate(p)
		if p.ShardMemberAdmissible() {
			t.Errorf("%s: provider must not be an admissible shard member", name)
		}
	}
	busy := quarantineTestProvider()
	busy.State = StateBusy
	if !busy.ShardMemberAdmissible() {
		t.Error("busy provider must stay admissible")
	}
}

func TestIsWSTunneledAndSortKey(t *testing.T) {
	t.Parallel()
	p := Provider{ProviderID: "pid", AssignedID: "aid", InferencePath: InferencePathWSTunneled}
	if !p.IsWSTunneled() {
		t.Fatal("ws_tunneled path must report tunneled")
	}
	p.HTTPForwardingOnly = true
	if p.IsWSTunneled() {
		t.Fatal("http-forwarding-only must not report tunneled")
	}
	if got := p.SortKey(); got != "pid/aid" {
		t.Fatalf("SortKey = %q", got)
	}
}

func TestRegistrySessionGuardedMutators(t *testing.T) {
	t.Parallel()
	r, _ := registerCoverProvider(t, func(p *Provider) {
		p.CatalogRecheckPending = true
		p.HashStatus = HashStatus("")
	})
	if r.MarkHTTPForwardingOnly("provider-a", "other") || r.MarkCompatibilityUpdateOnly("provider-a", "other") ||
		r.FenceCompatibilityPolicy("provider-a", "other") || r.MarkHashStatusIfSession("provider-a", "other", HashStatus("x")) {
		t.Fatal("mismatched assigned ID must not mutate")
	}
	if r.MarkHTTPForwardingOnly("missing", "assigned-a") {
		t.Fatal("unknown provider must report false")
	}
	if r.ClearCatalogRecheckPending("provider-a", "other") {
		t.Fatal("clear for another session must be refused")
	}
	if !r.ClearCatalogRecheckPending("provider-a", "assigned-a") {
		t.Fatal("first clear must transition")
	}
	if r.ClearCatalogRecheckPending("provider-a", "assigned-a") {
		t.Fatal("repeat clear must not transition")
	}
	if !r.MarkHTTPForwardingOnly("provider-a", "assigned-a") {
		t.Fatal("matching session must be marked")
	}
	if !r.MarkHashStatusIfSession("provider-a", "assigned-a", HashStatus("zz")) {
		t.Fatal("hash mark failed")
	}
	if !r.MarkCompatibilityUpdateOnly("provider-a", "assigned-a") {
		t.Fatal("update-only mark failed")
	}
	got, _ := r.Resolve("provider-a", "assigned-a")
	if !got.HTTPForwardingOnly || got.HashStatus != HashStatus("zz") || got.CatalogAdmissionMode != "update_bridge" {
		t.Fatalf("state not stored: %+v", got)
	}
	if got.RoutingEligible() {
		t.Fatal("update-only session must not be routable")
	}

	r2, _ := registerCoverProvider(t, nil)
	if !r2.FenceCompatibilityPolicy("provider-a", "assigned-a") {
		t.Fatal("fence failed")
	}
	if g, _ := r2.Resolve("provider-a", "assigned-a"); g.RoutingEligible() {
		t.Fatal("fenced session must be unroutable")
	}
}

func TestRegistryRemoveIfSessionStateAndLookups(t *testing.T) {
	t.Parallel()
	r, _ := registerCoverProvider(t, nil)
	if r.Count() != 1 {
		t.Fatalf("Count = %d", r.Count())
	}
	if _, err := r.Conn("provider-a", "assigned-a"); err == nil {
		t.Fatal("session without a conn must error")
	}
	if n, ok := r.CurrentMaxConcurrency("provider-a"); !ok || n != 1 {
		t.Fatalf("CurrentMaxConcurrency = %d,%v", n, ok)
	}
	if _, ok := r.CurrentMaxConcurrency("nope"); ok {
		t.Fatal("unknown provider must report false")
	}
	if r.RemoveIfSessionState("provider-a", "assigned-a", StateBusy) {
		t.Fatal("state mismatch must not remove")
	}
	if r.RemoveIfSessionState("provider-a", "other", StateReady) {
		t.Fatal("assigned mismatch must not remove")
	}
	if !r.RemoveIfSessionState("provider-a", "assigned-a", StateReady) {
		t.Fatal("matching remove failed")
	}
	if r.Count() != 0 {
		t.Fatal("provider must be gone")
	}
	if _, ok := r.Resolve("", "assigned-a"); ok {
		t.Fatal("session index must be cleared")
	}
}

func TestRoutableSlotsFree(t *testing.T) {
	t.Parallel()
	r, _ := registerCoverProvider(t, func(p *Provider) { p.SlotsTotal, p.SlotsFree, p.MaxConcurrency = 4, 3, 4 })
	if n, ok := r.RoutableSlotsFree("provider-a", "assigned-a"); !ok || n != 3 {
		t.Fatalf("slots = %d,%v", n, ok)
	}
	if _, ok := r.RoutableSlotsFree("provider-a", "other"); ok {
		t.Fatal("mismatched session must report not found")
	}
	if _, ok := r.RoutableSlotsFree("nope", ""); ok {
		t.Fatal("unknown provider must report not found")
	}
	r.mu.Lock()
	r.providers["provider-a"].SlotsFree = -2
	r.mu.Unlock()
	if n, ok := r.RoutableSlotsFree("provider-a", ""); !ok || n != 0 {
		t.Fatalf("negative slots must clamp to 0, got %d,%v", n, ok)
	}
}

func TestBuyerServingProviderIDsAndSuccessStamp(t *testing.T) {
	t.Parallel()
	r, _ := registerCoverProvider(t, nil)
	other := quarantineTestProvider()
	other.ProviderID, other.AssignedID, other.ModelID = "provider-b", "assigned-b", "model-b"
	if _, ok := r.RegisterAt(other, nil, time.Now().UTC()); !ok {
		t.Fatal("register b failed")
	}
	ids := r.BuyerServingProviderIDsForModel("MODEL-A")
	if len(ids) != 1 || ids[0] != "provider-a" {
		t.Fatalf("ids = %v", ids)
	}
	r.SetBuyerServingPredicate(func(Provider) bool { return false })
	if ids := r.BuyerServingProviderIDsForModel("model-a"); len(ids) != 0 {
		t.Fatalf("predicate false must exclude: %v", ids)
	}

	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.FixedZone("x", 3600))
	r.NoteBuyerSuccess("provider-a", at)
	if got := r.LastBuyerSuccessAt("provider-a"); !got.Equal(at) || got.Location() != time.UTC {
		t.Fatalf("stamp = %v", got)
	}
	r.NoteBuyerSuccess("  ", at)
	r.NoteBuyerSuccess("missing", at)
	if got := r.LastBuyerSuccessAt("provider-b"); !got.IsZero() {
		t.Fatalf("unstamped provider = %v", got)
	}
	if got := r.LastBuyerSuccessAt("missing"); !got.IsZero() {
		t.Fatalf("unknown provider = %v", got)
	}
	r.NoteBuyerSuccess("provider-b", time.Time{})
	if got := r.LastBuyerSuccessAt("provider-b"); got.IsZero() {
		t.Fatal("zero time must default to now")
	}
}

func TestSetShardGroupState(t *testing.T) {
	t.Parallel()
	r, _ := registerCoverProvider(t, func(p *Provider) { p.ShardGroupHeadV1 = true })
	members := []ShardGroupMemberView{{ProviderID: "m1", AssignedID: "s1"}}
	if r.SetShardGroupState("provider-a", "other", true, 1, "pool", members) {
		t.Fatal("mismatched session must not change")
	}
	if !r.SetShardGroupState("provider-a", "assigned-a", true, 1, "pool", members) {
		t.Fatal("first set must change")
	}
	if r.SetShardGroupState("provider-a", "assigned-a", true, 1, "pool", members) {
		t.Fatal("identical set must not report a change")
	}
	if !r.SetShardGroupState("provider-a", "assigned-a", true, 1, "pool", []ShardGroupMemberView{{ProviderID: "m2"}}) {
		t.Fatal("member change must report change")
	}
	if !r.SetShardGroupState("provider-a", "assigned-a", false, 1, "pool", members) {
		t.Fatal("unavailable must report change")
	}
	got, _ := r.Resolve("provider-a", "assigned-a")
	if got.ShardGroupAvailable || len(got.ShardGroupMembers) != 0 {
		t.Fatalf("unavailable group must drop members: %+v", got)
	}
	r2, _ := registerCoverProvider(t, nil)
	if r2.SetShardGroupState("provider-a", "assigned-a", true, 1, "pool", members) {
		t.Fatal("non-head must refuse")
	}
}

func TestUpdateHashStatusesAndSetTierAndEngineProfile(t *testing.T) {
	t.Parallel()
	r, _ := registerCoverProvider(t, nil)
	n := r.UpdateHashStatuses(func(Provider) HashStatus { return HashStatus("new") })
	if n != 1 {
		t.Fatalf("updated = %d", n)
	}
	if n := r.UpdateHashStatuses(func(Provider) HashStatus { return HashStatus("new") }); n != 0 {
		t.Fatalf("unchanged refresh updated = %d", n)
	}
	if g, _ := r.Resolve("provider-a", ""); g.HashStatus != HashStatus("new") {
		t.Fatalf("status = %q", g.HashStatus)
	}
	if _, ok := r.SetTier("missing", TierTrusted); ok {
		t.Fatal("unknown provider must report false")
	}
	if cp, ok := r.SetTier("provider-a", TierTrusted); !ok || cp.Tier != TierTrusted {
		t.Fatalf("SetTier = %+v,%v", cp, ok)
	}

	prof := &EngineProfile{}
	r.SetEngineProfile("provider-a", prof)
	r.SetEngineProfile("missing", prof)
	g, _ := r.Resolve("provider-a", "")
	if g.EngineProfile == nil || g.EngineProfile == prof {
		t.Fatal("engine profile must be stored as a copy")
	}
	r.SetEngineProfile("provider-a", nil)
	if g, _ := r.Resolve("provider-a", ""); g.EngineProfile != nil {
		t.Fatal("nil profile must clear")
	}
}
