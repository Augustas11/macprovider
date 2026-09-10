package billing

import (
	"context"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

func artifactRouteSnapshot() RouteSnapshot {
	snap := testRouteSnapshot()
	ggufHash := strings.Repeat("c", 64)
	snap.ProviderReportedModelHash = ggufHash
	snap.ProviderReportedModelHashAlgorithm = modelidentity.GGUFFileV1
	snap.ExpectedCatalogModelHash = ggufHash
	snap.ExpectedCatalogModelHashAlgorithm = modelidentity.GGUFFileV1
	snap.ArtifactFeedSHA256 = strings.Repeat("a", 64)
	snap.ArtifactID = "gguf-q4"
	snap.ArtifactHash = ggufHash
	snap.ArtifactHashAlgorithm = modelidentity.GGUFFileV1
	snap.ArtifactFeedSignerKeyID = "streamvc-autotune-static-v4"
	snap.ArtifactCandidateCatalogSHA256 = strings.Repeat("b", 64)
	return snap
}

// SPEC-010 v1.7 R007(d) / SPEC-047-R003 / AC-CAT-20: the six values are bound
// into the immutable route-time record, recovered on the settlement recompute
// path, and a snapshot whose evidence is missing, partial, or changed never
// validates — without consulting any current feed.
func TestRouteSnapshotArtifactEvidenceDigestBindingAndRoundTrip(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	snap := artifactRouteSnapshot()
	value := snap.Value()
	for _, key := range []string{"artifact_feed_sha256", "artifact_id", "artifact_hash", "artifact_hash_algorithm", "artifact_feed_signer_key_id", "artifact_candidate_catalog_sha256"} {
		if _, ok := value[key]; !ok {
			t.Fatalf("missing artifact route snapshot key %q", key)
		}
	}
	digest, err := store.InsertRouteSnapshot(context.Background(), snap)
	if err != nil {
		t.Fatal(err)
	}
	for name, mutate := range map[string]func(*RouteSnapshot){
		"feed digest": func(r *RouteSnapshot) { r.ArtifactFeedSHA256 = strings.Repeat("f", 64) },
		"signer":      func(r *RouteSnapshot) { r.ArtifactFeedSignerKeyID = "other-key" },
		"artifact id": func(r *RouteSnapshot) { r.ArtifactID = "gguf-q8" },
		"release":     func(r *RouteSnapshot) { r.ArtifactCandidateCatalogSHA256 = strings.Repeat("e", 64) },
	} {
		mutated := snap
		mutate(&mutated)
		mutatedDigest, _, err := mutated.Digest()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if mutatedDigest == digest {
			t.Fatalf("%s must change the route snapshot digest", name)
		}
	}
	conn, err := store.db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	loaded, loadedDigest, err := loadSettlementRouteSnapshotConn(context.Background(), conn, SettlementReceiptIdentity{
		AccountScope: snap.AccountScope, RequestID: snap.RequestID, AttemptN: snap.AttemptN, ProviderID: snap.ProviderID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if loadedDigest != digest {
		t.Fatalf("recompute digest %q != insert digest %q", loadedDigest, digest)
	}
	if loaded.ArtifactID != "gguf-q4" || loaded.ArtifactHash != snap.ArtifactHash || loaded.ArtifactFeedSignerKeyID != snap.ArtifactFeedSignerKeyID ||
		loaded.ArtifactFeedSHA256 != snap.ArtifactFeedSHA256 || loaded.ArtifactCandidateCatalogSHA256 != snap.ArtifactCandidateCatalogSHA256 ||
		loaded.ArtifactHashAlgorithm != modelidentity.GGUFFileV1 {
		t.Fatalf("loader did not recover artifact evidence: %+v", loaded)
	}
}

func TestRouteSnapshotArtifactEvidenceIsAllSixOrNoneAndNamesTheExpectedPair(t *testing.T) {
	valid := artifactRouteSnapshot()
	if err := valid.Validate(); err != nil {
		t.Fatalf("complete evidence must validate: %v", err)
	}
	// Missing: a GGUF expected identity can only be a feed member.
	missing := artifactRouteSnapshot()
	missing.ArtifactFeedSHA256, missing.ArtifactID, missing.ArtifactHash, missing.ArtifactHashAlgorithm, missing.ArtifactFeedSignerKeyID, missing.ArtifactCandidateCatalogSHA256 = "", "", "", "", "", ""
	if err := missing.Validate(); err == nil {
		t.Fatal("gguf expected identity without artifact evidence must fail closed")
	}
	// Partial: any one value present requires all six.
	for name, mutate := range map[string]func(*RouteSnapshot){
		"no feed digest":        func(r *RouteSnapshot) { r.ArtifactFeedSHA256 = "" },
		"no artifact id":        func(r *RouteSnapshot) { r.ArtifactID = "" },
		"no hash":               func(r *RouteSnapshot) { r.ArtifactHash = "" },
		"no algorithm":          func(r *RouteSnapshot) { r.ArtifactHashAlgorithm = "" },
		"no signer":             func(r *RouteSnapshot) { r.ArtifactFeedSignerKeyID = "" },
		"no candidate digest":   func(r *RouteSnapshot) { r.ArtifactCandidateCatalogSHA256 = "" },
		"hash != expected":      func(r *RouteSnapshot) { r.ArtifactHash = strings.Repeat("d", 64) },
		"algorithm != expected": func(r *RouteSnapshot) { r.ArtifactHashAlgorithm = modelidentity.SnapshotManifestV1 },
		"unnamed algorithm": func(r *RouteSnapshot) {
			r.ArtifactHashAlgorithm, r.ExpectedCatalogModelHashAlgorithm, r.ProviderReportedModelHashAlgorithm = "sha256", "sha256", "sha256"
		},
	} {
		snap := artifactRouteSnapshot()
		mutate(&snap)
		if err := snap.Validate(); err == nil {
			t.Fatalf("%s must fail validation", name)
		}
	}
	// A primary member bound through the feed carries the six values too.
	primary := testRouteSnapshot()
	primary.ArtifactFeedSHA256 = strings.Repeat("a", 64)
	primary.ArtifactID = "mlx-4bit"
	primary.ArtifactHash = primary.ExpectedCatalogModelHash
	primary.ArtifactHashAlgorithm = modelidentity.SnapshotManifestV1
	primary.ArtifactFeedSignerKeyID = "k1"
	primary.ArtifactCandidateCatalogSHA256 = strings.Repeat("b", 64)
	if err := primary.Validate(); err != nil {
		t.Fatalf("feed-derived primary: %v", err)
	}
	// The row-bound primary path is byte-for-byte v1.6: no artifact keys.
	if _, ok := testRouteSnapshot().Value()["artifact_id"]; ok {
		t.Fatal("row-bound snapshot must carry no artifact keys")
	}
	// Reported and expected algorithms must agree.
	split := testRouteSnapshot()
	split.ProviderReportedModelHashAlgorithm = modelidentity.GGUFFileV1
	if err := split.Validate(); err == nil {
		t.Fatal("reported/expected algorithm split must fail")
	}
}
