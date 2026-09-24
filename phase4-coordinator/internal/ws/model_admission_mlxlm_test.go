package ws

import (
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-010-R009 / SPEC-047 v0.2.1 (#1690 M8): mlx_lm.server served as
// mlxlm_loopback binds a catalog MLX row by the row's own snapshot-manifest
// pair, only when the release-bound primary artifact allows mlxlm_loopback,
// and only through the pool route-time derivation.

func mlxlmIdentitySet(t *testing.T, primarySources string) *artifactidentity.Index {
	t.Helper()
	set, err := artifactidentity.New(artifactidentity.Provenance{
		FeedSHA256: strings.Repeat("a", 64), SignerKeyID: "k", ReleaseID: "r1",
		CandidateCatalogSHA256: strings.Repeat("b", 64), FeedGeneratedAt: time.Now(),
	}, []artifactidentity.Member{
		{ModelKey: "small", ModelID: "model-a", ArtifactID: "mlx-4bit", HashAlgorithm: modelidentity.SnapshotManifestV1,
			Hash: strings.Repeat("9", 64), IsPrimary: true, RuntimeStatus: "recommendable", AllowedRuntimeSources: primarySources},
		{ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1,
			Hash: strings.Repeat("c", 64), RuntimeStatus: "recommendable", AllowedRuntimeSources: "llamacpp_loopback,ollama_loopback"},
	})
	if err != nil {
		t.Fatal(err)
	}
	return set
}

func TestSPEC010R009CandidateRowAdmissibility(t *testing.T) {
	row := strings.Repeat("9", 64)
	allowing := mlxlmIdentitySet(t, "mlx_cache,mlxlm_loopback")
	nativeOnly := mlxlmIdentitySet(t, "mlx_cache")
	for name, tc := range map[string]struct {
		set    *artifactidentity.Index
		key    string
		hash   string
		source string
		want   bool
	}{
		"native, no feed":              {nil, "small", row, "mlx_cache", true},
		"mlxlm, primary allows":        {allowing, "small", row, "mlxlm_loopback", true},
		"mlxlm, no feed":               {nil, "small", row, "mlxlm_loopback", false},
		"mlxlm, primary native-only":   {nativeOnly, "small", row, "mlxlm_loopback", false},
		"mlxlm, other row key":         {allowing, "other", row, "mlxlm_loopback", false},
		"mlxlm, pair not the primary":  {allowing, "small", strings.Repeat("c", 64), "mlxlm_loopback", false},
		"gguf class never binds a row": {allowing, "small", row, "llamacpp_loopback", false},
		"ollama never binds a row":     {allowing, "small", row, "ollama_loopback", false},
	} {
		if got := candidateRowAllowsRuntimeSource(tc.set, tc.key, tc.hash, tc.source); got != tc.want {
			t.Errorf("%s: got %v, want %v", name, got, tc.want)
		}
	}
}

func TestSPEC010R009OfferMatchAdmitsMLXLMOnlyWhenPrimaryAllows(t *testing.T) {
	f := newBindingFixture(t)
	members := bindingMembers(f.gguf, "")
	members[0].AllowedRuntimeSources = "mlx_cache,mlxlm_loopback"
	allowing := bindingIndex(t, f.catalog, strings.Repeat("a", 64), f.now, members)
	hashes := map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash}
	match := matchRuntimeOfferArtifactHashes(f.catalog, allowing, false, "mlxlm_loopback", "", hashes)
	if match.State != modelAdmissionCatalogMatched || len(match.Members) != 1 || match.Members[0].Source != modelAdmissionMemberSourceCandidateRow {
		t.Fatalf("mlxlm offer of the row pair must match the candidate_row member: %+v", match)
	}
	for name, set := range map[string]*artifactidentity.Index{"no feed": nil, "native-only feed": f.index} {
		if m := matchRuntimeOfferArtifactHashes(f.catalog, set, false, "mlxlm_loopback", "", hashes); m.State == modelAdmissionCatalogMatched {
			t.Errorf("%s: mlxlm offer matched: %+v", name, m)
		}
	}
	gguf := map[string]string{modelidentity.GGUFFileV1: f.gguf}
	if m := matchRuntimeOfferArtifactHashes(f.catalog, allowing, false, "mlxlm_loopback", "", gguf); m.State == modelAdmissionCatalogMatched {
		t.Fatalf("an mlxlm offer carrying a GGUF pair must not match: %+v", m)
	}

	// The reload sweep re-checks the same rule: a release whose primary no
	// longer allows mlxlm_loopback disallows the recorded candidate.
	candidate := ModelAdmissionEvent{
		CatalogMatchState: modelAdmissionCatalogMatched, CatalogModelKey: "small", CatalogRowModelID: "model-a",
		CatalogRowModelSHA256: bindingRowHash, RuntimeSource: "mlxlm_loopback", CatalogMembers: match.Members,
	}
	f.server.artifactIdentitySets.sets[f.catalog.SHA256] = f.index
	if got := f.server.evaluateCatalogPreconditionsLocked(candidate, f.catalog); got.decisionCode != "runtime_source_not_allowed" {
		t.Fatalf("native-only release must disallow mlxlm: %+v", got)
	}
	f.server.artifactIdentitySets.sets[f.catalog.SHA256] = allowing
	if got := f.server.evaluateCatalogPreconditionsLocked(candidate, f.catalog); got.decisionCode == "runtime_source_not_allowed" || got.decisionCode == "catalog_match_stale" {
		t.Fatalf("allowing release must keep mlxlm admissible: %+v", got)
	}
}

func mlxlmPoolRouteFixture() (pool.Provider, ModelAdmissionEvent, ModelAdmissionSettlementPredicate) {
	row := strings.Repeat("9", 64)
	event, predicate := poolRouteFixture()
	event.RuntimeSource = "mlxlm_loopback"
	event.ServedModelRef = "mlxlm:model-a"
	event.CatalogRowModelSHA256 = row
	event.CatalogMembers = []ModelAdmissionCatalogMember{
		{Source: modelAdmissionMemberSourceCandidateRow, HashAlgorithm: modelidentity.SnapshotManifestV1, Hash: row},
	}
	predicate.ServedModelRef = event.ServedModelRef
	predicate.ExpectedCatalogModelHash = row
	predicate.ExpectedCatalogModelHashAlgorithm = modelidentity.SnapshotManifestV1
	predicate.ArtifactFeedSHA256, predicate.ArtifactID, predicate.ArtifactHash = "", "", ""
	predicate.ArtifactHashAlgorithm, predicate.ArtifactFeedSignerKeyID, predicate.ArtifactCandidateCatalogSHA256 = "", "", ""
	provider := pool.Provider{
		HashStatus:         pool.HashStatusVerified,
		IdentityPin:        &pool.IdentityPin{Primary: true},
		ModelHashAlgorithm: modelidentity.SnapshotManifestV1,
		ModelHash:          row,
		RuntimeSource:      "mlxlm_loopback",
	}
	return provider, event, predicate
}

func TestSPEC010R009PoolRouteDerivesMLXLMRowMember(t *testing.T) {
	provider, event, predicate := mlxlmPoolRouteFixture()
	member, ok := PoolRouteSessionBoundMember(provider, event)
	if !ok || member.Source != modelAdmissionMemberSourceCandidateRow {
		t.Fatalf("mlxlm primary-pinned session must derive the row member: %+v %v", member, ok)
	}
	binding, ok := ModelAdmissionPoolSettlementBindingForRouteSnapshot(event, predicate)
	if !ok || binding.ArtifactDerived() {
		t.Fatalf("mlxlm row binding must bind with no six values: %+v %v", binding, ok)
	}

	gguf := event
	gguf.RuntimeSource = "llamacpp_loopback"
	if _, ok := PoolRouteSessionBoundMember(provider, gguf); ok {
		t.Fatal("a GGUF loopback class must never bind the row pair")
	}
	if _, ok := ModelAdmissionPoolSettlementBindingForRouteSnapshot(gguf, predicate); ok {
		t.Fatal("a GGUF loopback class must never settle a snapshot-manifest pair")
	}
	withFeed := provider
	withFeed.ArtifactIdentity = &artifactidentity.Binding{Member: artifactidentity.Member{ArtifactID: "mlx-4bit"}}
	if _, ok := PoolRouteSessionBoundMember(withFeed, event); ok {
		t.Fatal("a row member must not bind a session that carries a feed binding")
	}
	for name, mutate := range map[string]func(*ModelAdmissionEvent, *ModelAdmissionSettlementPredicate){
		"expected pair is not the row": func(_ *ModelAdmissionEvent, p *ModelAdmissionSettlementPredicate) {
			p.ExpectedCatalogModelHash = strings.Repeat("8", 64)
		},
		"gguf algorithm": func(_ *ModelAdmissionEvent, p *ModelAdmissionSettlementPredicate) {
			p.ExpectedCatalogModelHashAlgorithm = modelidentity.GGUFFileV1
		},
		"partial six values": func(_ *ModelAdmissionEvent, p *ModelAdmissionSettlementPredicate) { p.ArtifactID = "mlx-4bit" },
		"native class":       func(e *ModelAdmissionEvent, _ *ModelAdmissionSettlementPredicate) { e.RuntimeSource = "mlx_cache" },
	} {
		_, e, p := mlxlmPoolRouteFixture()
		mutate(&e, &p)
		if _, ok := ModelAdmissionPoolSettlementBindingForRouteSnapshot(e, p); ok {
			t.Errorf("%s: pool binding accepted", name)
		}
	}
}

// A hello that claims mlxlm_loopback while its verified pair is a GGUF member
// fails closed: the derived class (snapshot-manifest) disagrees with the
// member's format.
func TestSPEC010R009MLXLMClaimServingGGUFFailsClosed(t *testing.T) {
	member := artifactidentity.Member{
		ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1,
		Hash: strings.Repeat("c", 64), RuntimeStatus: "recommendable", AllowedRuntimeSources: "llamacpp_loopback,mlxlm_loopback",
	}
	provider := pool.Provider{
		HashStatus:       pool.HashStatusVerified,
		ArtifactIdentity: &artifactidentity.Binding{Member: member},
		IdentityPin:      &pool.IdentityPin{Member: member},
		RuntimeSource:    "mlxlm_loopback",
	}
	event, _ := poolRouteFixture()
	event.RuntimeSource = "mlxlm_loopback"
	event.CatalogMembers = []ModelAdmissionCatalogMember{
		{Source: modelAdmissionMemberSourceArtifactFeed, HashAlgorithm: member.HashAlgorithm, Hash: member.Hash, ArtifactID: member.ArtifactID},
	}
	if _, ok := PoolRouteSessionBoundMember(provider, event); ok {
		t.Fatal("mlxlm_loopback serving a GGUF member must not bind, even if an artifact lists it")
	}
	if !IsBYOMLoopbackRuntimeSource("mlxlm_loopback") {
		t.Fatal("mlxlm_loopback must be a loopback runtime (global paid routing stays closed)")
	}
}
