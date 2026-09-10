package ws

import (
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-010 v1.7 R007(b)(c): a pair that is not the admitted row's own is
// verified only through the artifact feed release-bound to the provider's
// admitted candidate catalog, by exact pair equality, for the session's
// admitted key; everything else stays the v1.6 verdict.
func TestArtifactFeedIdentityVerifiesExactMemberForTheAdmittedRelease(t *testing.T) {
	const rowHash = "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a"
	ggufHash := strings.Repeat("c", 64)
	catalog, err := autotune.ParseCatalog([]byte(`{
		"version":"test",
		"policy_version":"test-v1",
		"generated_at":"2026-07-18T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{"small":{
			"model_id":"model-a",
			"model_revision":"revision-a",
			"model_sha256":"` + rowHash + `",
			"min_ram_gb":4,
			"min_bandwidth_tier":"C",
			"bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},
			"runtime_status":"recommendable"
		}}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	index, err := artifactidentity.New(artifactidentity.Provenance{
		FeedSHA256: strings.Repeat("a", 64), SignerKeyID: "k1", ReleaseID: "test", CandidateCatalogSHA256: catalog.SHA256,
	}, []artifactidentity.Member{
		{ModelKey: "small", ArtifactID: "mlx-4bit", HashAlgorithm: modelidentity.SnapshotManifestV1, Hash: rowHash, IsPrimary: true, RuntimeStatus: "recommendable"},
		{ModelKey: "small", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: ggufHash, RuntimeStatus: "recommendable"},
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Default()
	cfg.Tier2.ObserveEnabled = true
	now := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	server := &Server{cfg: cfg, tier2: cfg.Tier2, autotuneCatalog: catalog, artifactIdentityIndex: index, now: func() time.Time { return now }}

	base := pool.ModelIdentityRequest{ModelID: "model-a", ExpectedHash: rowHash, CandidateCatalogSHA256: catalog.SHA256, CatalogModelKey: "small"}

	// Primary-row path unchanged: verified with no artifact binding.
	primary := base
	primary.ReportedHash, primary.ReportedAlgorithm = rowHash, modelidentity.SnapshotManifestV1
	if v := server.verifyModelIdentity(primary); v.Status != pool.HashStatusVerified || v.Artifact != nil {
		t.Fatalf("primary row path: %+v", v)
	}

	// GGUF member: verified, with the member and the feed provenance bound.
	gguf := base
	gguf.ReportedHash, gguf.ReportedAlgorithm = ggufHash, modelidentity.GGUFFileV1
	v := server.verifyModelIdentity(gguf)
	if v.Status != pool.HashStatusVerified || v.Artifact == nil || v.Artifact.Member.ArtifactID != "gguf-q4" ||
		v.Artifact.Provenance.CandidateCatalogSHA256 != catalog.SHA256 || v.Artifact.Provenance.SignerKeyID != "k1" {
		t.Fatalf("gguf member: %+v", v)
	}

	// Algorithm is half of the pair.
	wrongAlg := gguf
	wrongAlg.ReportedAlgorithm = modelidentity.SnapshotManifestV1
	if v := server.verifyModelIdentity(wrongAlg); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("gguf hash under the snapshot algorithm must not resolve: %+v", v)
	}
	// A pair that is in no set is unverified, never approximately matched.
	unknown := gguf
	unknown.ReportedHash = strings.Repeat("d", 64)
	if v := server.verifyModelIdentity(unknown); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("unknown pair: %+v", v)
	}
	// The feed must be release-bound to THIS provider's admitted catalog.
	otherRelease := gguf
	otherRelease.CandidateCatalogSHA256 = strings.Repeat("e", 64)
	if v := server.verifyModelIdentity(otherRelease); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("feed of another release must not supply the identity: %+v", v)
	}
	// The resolved member's key must be the session's admitted key.
	otherKey := gguf
	otherKey.CatalogModelKey = "other-model"
	if v := server.verifyModelIdentity(otherKey); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("member of another key must fail closed: %+v", v)
	}
	// Without an admitted key the served model id (normalized) is the key;
	// "model-a" is not the catalog key "small".
	noKey := gguf
	noKey.CatalogModelKey = ""
	if v := server.verifyModelIdentity(noKey); v.Status != pool.HashStatusMismatch {
		t.Fatalf("model id is not the catalog key: %+v", v)
	}
	// No index (rate-card-bound release): v1.6 verdicts exactly.
	server.artifactIdentityIndex = nil
	if v := server.verifyModelIdentity(gguf); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("no feed: %+v", v)
	}
	// An unnamed algorithm is invalid regardless of the feed.
	bad := gguf
	bad.ReportedAlgorithm = "sha256"
	if v := server.verifyModelIdentity(bad); v.Status != pool.HashStatusInvalid {
		t.Fatalf("unnamed algorithm: %+v", v)
	}
}
