package ws

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

// SPEC-010 1.14 R009 / SPEC-047 v0.2.3 (#1690 M9): oMLX served as
// omlx_loopback binds a catalog MLX row exactly as mlxlm_loopback does, by the
// snapshot-manifest pair, only when the release-bound artifact allows
// omlx_loopback itself, and only through the pool route-time derivation.
// Allowing one MLX-snapshot class never admits the other.

func TestSPEC010R009OMLXCandidateRowAdmissibility(t *testing.T) {
	row := strings.Repeat("9", 64)
	omlx := mlxlmIdentitySet(t, "mlx_cache,omlx_loopback")
	mlxlmOnly := mlxlmIdentitySet(t, "mlx_cache,mlxlm_loopback")
	for name, tc := range map[string]struct {
		set    *artifactidentity.Index
		source string
		want   bool
	}{
		"omlx, primary allows omlx":         {omlx, "omlx_loopback", true},
		"omlx, no feed":                     {nil, "omlx_loopback", false},
		"omlx, primary allows only mlxlm":   {mlxlmOnly, "omlx_loopback", false},
		"mlxlm, primary allows only omlx":   {omlx, "mlxlm_loopback", false},
		"gguf class never binds a row pair": {omlx, "lmstudio_loopback", false},
	} {
		if got := candidateRowAllowsRuntimeSource(tc.set, "small", row, tc.source); got != tc.want {
			t.Errorf("%s: got %v, want %v", name, got, tc.want)
		}
	}
}

func TestSPEC010R009OfferMatchAdmitsOMLXOnlyWhenPrimaryAllows(t *testing.T) {
	f := newBindingFixture(t)
	members := bindingMembers(f.gguf, "")
	members[0].AllowedRuntimeSources = "mlx_cache,omlx_loopback"
	allowing := bindingIndex(t, f.catalog, strings.Repeat("a", 64), f.now, members)
	hashes := map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash}
	match := matchRuntimeOfferArtifactHashes(f.catalog, allowing, false, "omlx_loopback", "", hashes)
	if match.State != modelAdmissionCatalogMatched || len(match.Members) != 1 || match.Members[0].Source != modelAdmissionMemberSourceCandidateRow {
		t.Fatalf("omlx offer of the row pair must match the candidate_row member: %+v", match)
	}
	if m := matchRuntimeOfferArtifactHashes(f.catalog, allowing, false, "mlxlm_loopback", "", hashes); m.State == modelAdmissionCatalogMatched {
		t.Fatalf("a primary that allows only omlx must not admit mlxlm: %+v", m)
	}
	gguf := map[string]string{modelidentity.GGUFFileV1: f.gguf}
	if m := matchRuntimeOfferArtifactHashes(f.catalog, allowing, false, "omlx_loopback", "", gguf); m.State == modelAdmissionCatalogMatched {
		t.Fatalf("an omlx offer carrying a GGUF pair must not match: %+v", m)
	}
}

func TestSPEC010R009PoolRouteDerivesOMLXRowMember(t *testing.T) {
	provider, event, predicate := mlxlmPoolRouteFixture()
	provider.RuntimeSource = "omlx_loopback"
	event.RuntimeSource = "omlx_loopback"
	event.ServedModelRef = "omlx:model-a"
	predicate.ServedModelRef = event.ServedModelRef
	member, ok := PoolRouteSessionBoundMember(provider, event)
	if !ok || member.Source != modelAdmissionMemberSourceCandidateRow {
		t.Fatalf("omlx primary-pinned session must derive the row member: %+v %v", member, ok)
	}
	binding, ok := ModelAdmissionPoolSettlementBindingForRouteSnapshot(event, predicate)
	if !ok || binding.ArtifactDerived() {
		t.Fatalf("omlx row binding must bind with no six values: %+v %v", binding, ok)
	}
	if algorithm, ok := poolRuntimeMemberAlgorithm("omlx_loopback"); !ok || algorithm != modelidentity.SnapshotManifestV1 {
		t.Fatalf("omlx_loopback member algorithm = %q %v", algorithm, ok)
	}
	if !IsBYOMLoopbackRuntimeSource("omlx_loopback") || !validModelAdmissionRuntimeSource("omlx_loopback") {
		t.Fatal("omlx_loopback must be a loopback runtime (global paid routing stays closed)")
	}
}
