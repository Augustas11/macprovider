package ws

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-047-R003(iv) pool route-time member derivation (#1690 M4): the pool-only
// sibling binds a catalog_priced loopback candidate's derived GGUF member, and
// the global helper is unchanged (it still requires settlement_capable).
func poolRouteFixture() (ModelAdmissionEvent, ModelAdmissionSettlementPredicate) {
	hash := strings.Repeat("c", 64)
	event := ModelAdmissionEvent{
		ProviderID: "p1", CandidateID: "byom_" + strings.Repeat("a", 52), ServedModelRef: "llamacpp:test", CatalogModelKey: "small",
		CatalogID: "catalog", CatalogBodyDigest: strings.Repeat("4", 64), CatalogSignatureKeyID: "k", CatalogSignaturePubkeyFingerprint: "ed25519-sha256:" + strings.Repeat("5", 64),
		// A catalog_priced event records the row pair, never a bound member.
		ExpectedCatalogModelHash: strings.Repeat("9", 64), ExpectedCatalogModelHashAlgorithm: modelidentity.SnapshotManifestV1,
		DiscoveryDigestSHA256: strings.Repeat("b", 64), EvaluationDigestSHA256: strings.Repeat("d", 64),
		CoordinatorEventID: strings.Repeat("e", 64), State: "catalog_priced", RuntimeSource: "llamacpp_loopback",
	}
	predicate := ModelAdmissionSettlementPredicate{
		ProviderID: event.ProviderID, CandidateID: event.CandidateID, ServedModelRef: event.ServedModelRef, CatalogModelKey: event.CatalogModelKey,
		DiscoveryDigestSHA256: event.DiscoveryDigestSHA256, EvaluationDigestSHA256: event.EvaluationDigestSHA256,
		CatalogID: event.CatalogID, CatalogBodyDigest: event.CatalogBodyDigest, CatalogSignatureKeyID: event.CatalogSignatureKeyID,
		CatalogSignaturePubkeyFingerprint: event.CatalogSignaturePubkeyFingerprint,
		ExpectedCatalogModelHash:          hash, ExpectedCatalogModelHashAlgorithm: modelidentity.GGUFFileV1,
		ArtifactFeedSHA256: strings.Repeat("a", 64), ArtifactID: "gguf-q4", ArtifactHash: hash, ArtifactHashAlgorithm: modelidentity.GGUFFileV1,
		ArtifactFeedSignerKeyID: "k", ArtifactCandidateCatalogSHA256: strings.Repeat("b", 64),
	}
	return event, predicate
}

func TestModelAdmissionPoolSettlementBindingForRouteSnapshot(t *testing.T) {
	event, predicate := poolRouteFixture()
	binding, ok := ModelAdmissionPoolSettlementBindingForRouteSnapshot(event, predicate)
	if !ok || binding.ArtifactID != "gguf-q4" || binding.CoordinatorEventID != event.CoordinatorEventID {
		t.Fatalf("catalog_priced loopback candidate with a derived GGUF member must bind on a pool route: %+v %v", binding, ok)
	}
	if _, ok := ModelAdmissionSettlementBindingForRouteSnapshot(event, predicate); ok {
		t.Fatal("the global helper must keep rejecting a catalog_priced candidate")
	}
	for name, mutate := range map[string]func(*ModelAdmissionEvent, *ModelAdmissionSettlementPredicate){
		"settlement_capable head": func(e *ModelAdmissionEvent, _ *ModelAdmissionSettlementPredicate) { e.State = "settlement_capable" },
		"native runtime class":    func(e *ModelAdmissionEvent, _ *ModelAdmissionSettlementPredicate) { e.RuntimeSource = "mlx_cache" },
		"snapshot-manifest member": func(_ *ModelAdmissionEvent, p *ModelAdmissionSettlementPredicate) {
			p.ExpectedCatalogModelHashAlgorithm = modelidentity.SnapshotManifestV1
		},
		"missing evidence": func(_ *ModelAdmissionEvent, p *ModelAdmissionSettlementPredicate) { p.ArtifactFeedSignerKeyID = "" },
		"evidence names another hash": func(_ *ModelAdmissionEvent, p *ModelAdmissionSettlementPredicate) {
			p.ArtifactHash = strings.Repeat("d", 64)
		},
		"other candidate": func(_ *ModelAdmissionEvent, p *ModelAdmissionSettlementPredicate) {
			p.CandidateID = "byom_" + strings.Repeat("b", 52)
		},
		"other catalog": func(_ *ModelAdmissionEvent, p *ModelAdmissionSettlementPredicate) {
			p.CatalogBodyDigest = strings.Repeat("6", 64)
		},
		"other served ref": func(_ *ModelAdmissionEvent, p *ModelAdmissionSettlementPredicate) { p.ServedModelRef = "ollama:test" },
	} {
		e, p := poolRouteFixture()
		mutate(&e, &p)
		if _, ok := ModelAdmissionPoolSettlementBindingForRouteSnapshot(e, p); ok {
			t.Errorf("%s: pool binding accepted", name)
		}
	}
}

func TestPoolRouteSessionBoundMember(t *testing.T) {
	member := artifactidentity.Member{
		ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1,
		Hash: strings.Repeat("c", 64), RuntimeStatus: "recommendable", AllowedRuntimeSources: "llamacpp_loopback",
	}
	provider := pool.Provider{
		HashStatus:       pool.HashStatusVerified,
		ArtifactIdentity: &artifactidentity.Binding{Member: member},
		IdentityPin:      &pool.IdentityPin{Member: member},
	}
	event, _ := poolRouteFixture()
	event.CatalogMembers = []ModelAdmissionCatalogMember{
		{Source: modelAdmissionMemberSourceCandidateRow, HashAlgorithm: modelidentity.SnapshotManifestV1, Hash: strings.Repeat("9", 64)},
		{Source: modelAdmissionMemberSourceArtifactFeed, HashAlgorithm: member.HashAlgorithm, Hash: member.Hash, ArtifactID: member.ArtifactID},
	}
	got, ok := PoolRouteSessionBoundMember(provider, event)
	if !ok || got.ArtifactID != "gguf-q4" {
		t.Fatalf("pinned GGUF member not derived: %+v %v", got, ok)
	}
	notAllowing := event
	notAllowing.RuntimeSource = "ollama_loopback"
	if _, ok := PoolRouteSessionBoundMember(provider, notAllowing); ok {
		t.Fatal("a member that does not allow the recorded runtime must not bind")
	}
	unrecorded := event
	unrecorded.CatalogMembers = unrecorded.CatalogMembers[:1]
	if _, ok := PoolRouteSessionBoundMember(provider, unrecorded); ok {
		t.Fatal("a pin that names no recorded member must not bind")
	}
	primary := provider
	primary.IdentityPin = &pool.IdentityPin{Primary: true}
	primary.ArtifactIdentity = nil
	primary.ModelHashAlgorithm = modelidentity.SnapshotManifestV1
	primary.ModelHash = strings.Repeat("9", 64)
	event.CatalogRowModelSHA256 = strings.Repeat("9", 64)
	if _, ok := PoolRouteSessionBoundMember(primary, event); ok {
		t.Fatal("a row (snapshot-manifest) pair never binds on the pool path")
	}
}
