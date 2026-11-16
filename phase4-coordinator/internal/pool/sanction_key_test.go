package pool

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
)

// catalogAliases is a SanctionResolver for one signed row reachable as its
// model_id "model-b" and its row key "public-b".
func catalogAliases(key string) (string, bool) {
	switch key {
	case "model-b", "public-b":
		return "model-b", true
	}
	return "", false
}

// SPEC-036 FR-25 / SPEC-002-R011: every name of one catalog row is one
// sanction key; an id no row carries keeps its ModelKey.
func TestSanctionKeyResolvesCatalogRowNames(t *testing.T) {
	registry := NewRegistry(nil, WithSanctionResolver(catalogAliases))
	for _, name := range []string{"model-b", "Public-B", " public-b"} {
		if got := registry.SanctionKey(name); got != "model-b" {
			t.Fatalf("SanctionKey(%q) = %q, want model-b", name, got)
		}
	}
	if got := registry.SanctionKey("BYOM/Local-Model"); got != ModelKey("BYOM/Local-Model") {
		t.Fatalf("uncatalogued id = %q, want its ModelKey", got)
	}
	var unwired *Registry
	if got := unwired.SanctionKey("Public-B"); got != "public-b" {
		t.Fatalf("no resolver = %q, want the ModelKey", got)
	}
	if got := NewRegistry(nil).SanctionKey("Public-B"); got != "public-b" {
		t.Fatalf("registry without a resolver = %q, want the ModelKey", got)
	}
}

// A model suspended under one name of its catalog row and declared as a
// warm member under the other stays suspended, and keeps its not-loaded
// strikes; lifting it under either name lifts it.
func TestCatalogAliasMemberKeepsSuspensionAndStrikes(t *testing.T) {
	at := time.Now()
	registry := NewRegistry(nil, WithSanctionResolver(catalogAliases))
	registerWarmHeartbeatProvider(t, registry, at)
	registry.SetComputeIntegritySuspended("p1", "model-b", true)
	if registry.SetComputeIntegritySuspended("p1", "public-b", true) {
		t.Fatal("the row's other name made a second suspension")
	}
	if n, ok := registry.RecordEntryNotLoaded("p1", "current", "model-b", at.Add(time.Second), 2*time.Minute); !ok || n != 1 {
		t.Fatalf("first strike = %d ok=%v", n, ok)
	}
	if _, _, ok := registry.ApplyHeartbeat("p1", "current", warmHeartbeatUpdate(at.Add(2*time.Second), warmTestMembers("model-a", warmTestMember("public-b", WarmModelWarm, 2, 2)))); !ok {
		t.Fatal("heartbeat failed")
	}
	entry := warmEntry(t, registry, "public-b")
	if !entry.ComputeIntegritySuspended || entry.RoutingEligible() {
		t.Fatalf("member under the row key escaped its suspension: suspended=%v", entry.ComputeIntegritySuspended)
	}
	if n, ok := registry.RecordEntryNotLoaded("p1", "current", "public-b", at.Add(3*time.Second), 2*time.Minute); !ok || n != 2 {
		t.Fatalf("strikes under the row key = %d ok=%v, want 2", n, ok)
	}
	if !registry.SetComputeIntegritySuspended("p1", "public-b", false) {
		t.Fatal("lifting under the other name changed nothing")
	}
	if entry := warmEntry(t, registry, "public-b"); entry.ComputeIntegritySuspended {
		t.Fatal("suspension not lifted")
	}
	// The passing set follows the row too (SPEC-022 R-16.2a input).
	registry.SetComputeIntegrityPassing("p1", "model-b", true)
	if entry := warmEntry(t, registry, "public-b"); !entry.ComputeIntegrityPassing {
		t.Fatal("passing verification not applied under the row key")
	}
}

// A one-model provider switching its model id between the two names of one
// row keeps its suspension and its identity pin; a switch to another model
// resets the pin as before.
func TestCatalogAliasPrimarySwitchKeepsSuspensionAndPin(t *testing.T) {
	// The feed member a verdict names is the row's whatever name the session
	// used, as the release-bound artifact feed resolves it.
	resolver := WithModelIdentityResolver(func(req ModelIdentityRequest) ModelIdentityVerdict {
		switch req.ReportedHash {
		case "h1", "h2":
			return ModelIdentityVerdict{Status: HashStatusVerified, Artifact: &artifactidentity.Binding{Member: artifactidentity.Member{ModelID: "model-b", ArtifactID: "art-" + req.ReportedHash, Hash: req.ReportedHash}}}
		}
		return ModelIdentityVerdict{Status: HashStatusUncatalogued}
	})
	at := time.Now()
	registry := NewRegistry(nil, resolver, WithSanctionResolver(catalogAliases))
	registerHeartbeatProvider(t, registry, "model-b", "", HashStatusUncatalogued, at)
	beat := func(i int, model, hash string) Provider {
		t.Helper()
		update := heartbeatUpdateAt(model, at.Add(time.Duration(i)*time.Second))
		update.ModelHash, update.ModelHashPresent = hash, true
		p, _, ok := registry.ApplyHeartbeat("p1", "current", update)
		if !ok {
			t.Fatal("heartbeat failed")
		}
		return *p
	}
	if p := beat(1, "model-b", "h1"); p.HashStatus != HashStatusVerified || p.IdentityPin == nil {
		t.Fatalf("first verdict = %s pin=%v", p.HashStatus, p.IdentityPin)
	}
	registry.SetComputeIntegritySuspended("p1", "model-b", true)
	p := beat(2, "public-b", "h1")
	if !p.ComputeIntegritySuspended || p.RoutingEligible() {
		t.Fatal("primary switched to the row key escaped its suspension")
	}
	if p.HashStatus != HashStatusVerified {
		t.Fatalf("same identity under the row key = %s", p.HashStatus)
	}
	// The pin was carried: another verified identity of the same row under
	// the other name is a mismatch, exactly as under one name.
	if p := beat(3, "public-b", "h2"); p.HashStatus != HashStatusMismatch {
		t.Fatalf("other identity under the row key = %s, want hash_mismatch (pin carried)", p.HashStatus)
	}
	// A real model change still resets the pin.
	if p := beat(4, "model-other", "h2"); p.HashStatus != HashStatusVerified || p.ComputeIntegritySuspended {
		t.Fatalf("another model = %s suspended=%v, want verified with a fresh pin", p.HashStatus, p.ComputeIntegritySuspended)
	}
}

// A further member's identity pin follows the row across its names.
func TestCatalogAliasMemberKeepsIdentityPin(t *testing.T) {
	resolver := WithModelIdentityResolver(func(req ModelIdentityRequest) ModelIdentityVerdict {
		if req.ModelID == "model-a" {
			return ModelIdentityVerdict{Status: HashStatusVerified}
		}
		switch req.ReportedHash {
		case "h1", "h2":
			return ModelIdentityVerdict{Status: HashStatusVerified, Artifact: &artifactidentity.Binding{Member: artifactidentity.Member{ModelID: "model-b", ArtifactID: "art-" + req.ReportedHash, Hash: req.ReportedHash}}}
		}
		return ModelIdentityVerdict{Status: HashStatusUncatalogued}
	})
	at := time.Now()
	registry := NewRegistry(nil, resolver, WithSanctionResolver(catalogAliases))
	registerHeartbeatProvider(t, registry, "model-a", "h1", HashStatusVerified, at)
	beat := func(i int, name, hash string) {
		t.Helper()
		m := warmTestMember(name, WarmModelWarm, 1, 1)
		m.ModelHash = hash
		update := warmHeartbeatUpdate(at.Add(time.Duration(i)*time.Second), warmTestMembers("model-a", m))
		update.ModelHash, update.ModelHashPresent = "h1", true
		if _, _, ok := registry.ApplyHeartbeat("p1", "current", update); !ok {
			t.Fatal("heartbeat failed")
		}
	}
	beat(1, "model-b", "h1")
	if b := warmEntry(t, registry, "model-b"); b.HashStatus != HashStatusVerified || b.IdentityPin == nil {
		t.Fatalf("member first verdict = %s pin=%v", b.HashStatus, b.IdentityPin)
	}
	// Re-declared under the row key with another identity: the pin applies,
	// the member mismatches and the session is legacy.
	beat(2, "public-b", "h2")
	if _, ok := registry.ResolveEntry("p1", "current", "public-b"); ok {
		t.Fatal("member re-declared under the row key got a fresh pin")
	}
	// Under the row key with its pinned identity it verifies.
	beat(3, "public-b", "h1")
	if b := warmEntry(t, registry, "public-b"); b.HashStatus != HashStatusVerified {
		t.Fatalf("pinned identity under the row key = %s", b.HashStatus)
	}
}

// An uncatalogued id keeps today's ModelKey behaviour: another spelling
// shares its sanctions, another id does not.
func TestUncataloguedModelSanctionsUnchanged(t *testing.T) {
	at := time.Now()
	registry := NewRegistry(nil, WithSanctionResolver(catalogAliases))
	registerWarmHeartbeatProvider(t, registry, at)
	registry.SetComputeIntegritySuspended("p1", "MODEL-A", true)
	if a := warmEntry(t, registry, "model-a"); !a.ComputeIntegritySuspended {
		t.Fatal("spelling variant of an uncatalogued id lost its suspension")
	}
	if b := warmEntry(t, registry, "model-b"); b.ComputeIntegritySuspended {
		t.Fatal("suspension of an uncatalogued id reached another model")
	}
}
