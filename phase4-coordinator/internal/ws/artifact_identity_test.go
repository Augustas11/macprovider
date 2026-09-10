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
	now := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	index, err := artifactidentity.New(artifactidentity.Provenance{
		FeedSHA256: strings.Repeat("a", 64), SignerKeyID: "k1", ReleaseID: "test", CandidateCatalogSHA256: catalog.SHA256,
		FeedGeneratedAt: now.Add(-24 * time.Hour),
	}, []artifactidentity.Member{
		{ModelKey: "small", ArtifactID: "mlx-4bit", HashAlgorithm: modelidentity.SnapshotManifestV1, Hash: rowHash, IsPrimary: true, RuntimeStatus: "recommendable"},
		{ModelKey: "small", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: ggufHash, RuntimeStatus: "recommendable"},
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Default()
	cfg.Tier2.ObserveEnabled = true
	clock := now
	server := &Server{cfg: cfg, tier2: cfg.Tier2, autotuneCatalog: catalog, artifactIdentityIndex: index, now: func() time.Time { return clock }}

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
	// SPEC-023 §3.7.6 rules 4–5: 14 days after the feed's stamp the artifact
	// leg goes dark while the primary-row path is untouched.
	clock = now.Add(14 * 24 * time.Hour)
	if v := server.verifyModelIdentity(gguf); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("stale feed must not authorize an artifact identity: %+v", v)
	}
	if v := server.verifyModelIdentity(primary); v.Status != pool.HashStatusVerified || v.Artifact != nil {
		t.Fatalf("primary row path survives a stale feed: %+v", v)
	}
	clock = now
	// A catalog swap carries its own index (or none): the boot index never
	// outlives its release.
	server.SetAutotuneCatalog(catalog)
	if v := server.verifyModelIdentity(gguf); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("swap without an index must drop artifact authority: %+v", v)
	}
	server.SetAutotuneCatalogWithArtifactIndex(catalog, index)
	if v := server.verifyModelIdentity(gguf); v.Status != pool.HashStatusVerified || v.Artifact == nil {
		t.Fatalf("swap with its index restores artifact authority: %+v", v)
	}
	// The SIGHUP lifecycle: catalog swap (index dropped), then the feed publish
	// observer installs the index rebuilt from the published feeds.
	server.SetAutotuneCatalog(catalog)
	server.SetArtifactIdentityIndex(index)
	if v := server.verifyModelIdentity(gguf); v.Status != pool.HashStatusVerified || v.Artifact == nil {
		t.Fatalf("published index restores artifact authority: %+v", v)
	}
	server.SetArtifactIdentityIndex(nil)
	if v := server.verifyModelIdentity(gguf); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("a failed rebuild leaves no artifact authority: %+v", v)
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

// SPEC-010-R007(d): a GGUF expected identity can only be an artifact-feed
// member, so a binding predicate with none of the six values fails closed —
// the eligibility contract agrees with the billing snapshot contract.
func TestGGUFAdmissionPredicateRequiresCompleteArtifactEvidence(t *testing.T) {
	hash := strings.Repeat("c", 64)
	event := ModelAdmissionEvent{
		ProviderID: "p1", CandidateID: "byom_" + strings.Repeat("a", 52), ServedModelRef: "ollama:test", CatalogModelKey: "small",
		CatalogID: "catalog", CatalogBodyDigest: strings.Repeat("4", 64), CatalogSignatureKeyID: "k", CatalogSignaturePubkeyFingerprint: "ed25519-sha256:" + strings.Repeat("5", 64),
		ExpectedCatalogModelHash: hash, ExpectedCatalogModelHashAlgorithm: modelidentity.GGUFFileV1,
		DiscoveryDigestSHA256: strings.Repeat("b", 64), EvaluationDigestSHA256: strings.Repeat("d", 64),
		CoordinatorEventID: strings.Repeat("e", 64), State: "settlement_capable",
	}
	base := ModelAdmissionSettlementPredicate{
		ProviderID: event.ProviderID, CandidateID: event.CandidateID, ServedModelRef: event.ServedModelRef, CatalogModelKey: event.CatalogModelKey,
		DiscoveryDigestSHA256: event.DiscoveryDigestSHA256, EvaluationDigestSHA256: event.EvaluationDigestSHA256,
		CatalogID: event.CatalogID, CatalogBodyDigest: event.CatalogBodyDigest, CatalogSignatureKeyID: event.CatalogSignatureKeyID,
		CatalogSignaturePubkeyFingerprint: event.CatalogSignaturePubkeyFingerprint,
		ExpectedCatalogModelHash:          hash, ExpectedCatalogModelHashAlgorithm: modelidentity.GGUFFileV1,
	}
	if _, ok := ModelAdmissionSettlementBindingForRouteSnapshot(event, base); ok {
		t.Fatal("gguf identity with no artifact evidence must not bind")
	}
	complete := base
	complete.ArtifactFeedSHA256 = strings.Repeat("a", 64)
	complete.ArtifactID = "gguf-q4"
	complete.ArtifactHash = hash
	complete.ArtifactHashAlgorithm = modelidentity.GGUFFileV1
	complete.ArtifactFeedSignerKeyID = "k"
	complete.ArtifactCandidateCatalogSHA256 = strings.Repeat("b", 64)
	binding, ok := ModelAdmissionSettlementBindingForRouteSnapshot(event, complete)
	if !ok || !binding.ArtifactDerived() || binding.ArtifactID != "gguf-q4" {
		t.Fatalf("complete evidence must bind: %+v %v", binding, ok)
	}
	partial := complete
	partial.ArtifactFeedSignerKeyID = ""
	if _, ok := ModelAdmissionSettlementBindingForRouteSnapshot(event, partial); ok {
		t.Fatal("partial evidence must not bind")
	}
	mismatched := complete
	mismatched.ArtifactHash = strings.Repeat("d", 64)
	if _, ok := ModelAdmissionSettlementBindingForRouteSnapshot(event, mismatched); ok {
		t.Fatal("evidence naming another hash must not bind")
	}
}
