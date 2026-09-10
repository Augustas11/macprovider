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
		{ModelKey: "small", ModelID: "model-a", ArtifactID: "mlx-4bit", HashAlgorithm: modelidentity.SnapshotManifestV1, Hash: rowHash, IsPrimary: true, RuntimeStatus: "recommendable"},
		{ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: ggufHash, RuntimeStatus: "recommendable"},
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Default()
	cfg.Tier2.ObserveEnabled = true
	clock := now
	server := &Server{cfg: cfg, tier2: cfg.Tier2, autotuneCatalog: catalog, now: func() time.Time { return clock }}
	server.artifactIdentitySets.sets = map[string]*artifactidentity.Index{catalog.SHA256: index}

	base := pool.ModelIdentityRequest{ModelID: "model-a", ExpectedHash: rowHash, CandidateCatalogSHA256: catalog.SHA256, CatalogAdmissionMode: "current", CatalogModelKey: "small"}

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
	// A session-asserted key that disagrees with the resolved key fails closed
	// (SPEC-010-R007(c)).
	otherKey := gguf
	otherKey.CatalogModelKey = "other-model"
	if v := server.verifyModelIdentity(otherKey); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("asserted key disagreeing with the member must fail closed: %+v", v)
	}
	// The production session asserts no key (hello carries the row's
	// model_id, `model_catalog_model_id`): the member is tied to the row by
	// its model id, so the pair resolves for the model the session serves…
	noKey := gguf
	noKey.CatalogModelKey = ""
	if v := server.verifyModelIdentity(noKey); v.Status != pool.HashStatusVerified || v.Artifact == nil || v.Artifact.Member.ModelKey != "small" {
		t.Fatalf("member resolves for the row's model id without an asserted key: %+v", v)
	}
	// …and never for a session serving another model id, key or no key.
	otherModel := noKey
	otherModel.ModelID = "model-b"
	if v := server.verifyModelIdentity(otherModel); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("member of another row must fail closed: %+v", v)
	}
	otherModel.CatalogModelKey = "small"
	if v := server.verifyModelIdentity(otherModel); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("an asserted key never substitutes for the served model id: %+v", v)
	}
	// Only a validated catalog envelope binds a release: a bridge/legacy
	// session's digest never reaches the index (hello and heartbeat legs).
	for _, mode := range []string{"update_bridge", "legacy", "legacy_bridge", "not_required", ""} {
		if got := admittedCandidateCatalogSHA256(mode, catalog.SHA256); got != "" {
			t.Fatalf("mode %q must not bind a release, got %q", mode, got)
		}
	}
	for _, mode := range []string{"current", "previous"} {
		if got := admittedCandidateCatalogSHA256(mode, catalog.SHA256); got != catalog.SHA256 {
			t.Fatalf("mode %q must bind the validated envelope, got %q", mode, got)
		}
	}
	bridge := pool.Provider{ModelID: "model-a", ExpectedModelHash: rowHash, ModelHash: ggufHash, ModelHashAlgorithm: modelidentity.GGUFFileV1,
		CandidateCatalogSHA256: catalog.SHA256, CatalogAdmissionMode: "update_bridge"}
	if v := server.verifyModelIdentity(providerIdentityRequest(bridge)); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("bridge session must not bind artifact identity: %+v", v)
	}
	bridge.CatalogAdmissionMode = "current"
	if v := server.verifyModelIdentity(providerIdentityRequest(bridge)); v.Status != pool.HashStatusVerified || v.Artifact == nil {
		t.Fatalf("validated envelope binds: %+v", v)
	}
	// The gate lives in the resolver, so the REAL registry heartbeat leg —
	// which builds its own request — cannot skip it: a bridge session
	// heartbeating the exact member pair stays unbound; a current one binds.
	// ("previous" is a validated envelope too, but a compatible-previous
	// release's digest is not the one the loaded feed is bound to.)
	for _, tc := range []struct {
		mode string
		sha  string
		want pool.HashStatus
	}{{"update_bridge", catalog.SHA256, pool.HashStatusMismatch}, {"legacy", catalog.SHA256, pool.HashStatusMismatch}, {"current", catalog.SHA256, pool.HashStatusVerified}, {"previous", strings.Repeat("9", 64), pool.HashStatusMismatch}} {
		registry := pool.NewRegistry(nil, pool.WithModelIdentityResolver(server.verifyModelIdentity))
		registry.Register(&pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", State: pool.StateReady,
			CandidateCatalogSHA256: tc.sha, CatalogAdmissionMode: tc.mode, SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1,
			LastHeartbeatAt: now, LastActivityAt: now}, nil)
		heartbeat, _, ok := registry.ApplyHeartbeat("p1", "s1", pool.HeartbeatUpdate{
			Status: pool.StateReady, ModelID: "model-a", ModelHash: ggufHash, ModelHashPresent: true,
			ModelHashAlgorithm: modelidentity.GGUFFileV1, ModelHashAlgorithmPresent: true, ExpectedModelHash: rowHash,
			MaxContextTokens: 8192, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, At: now.Add(time.Minute),
		})
		if !ok || heartbeat.HashStatus != tc.want || (tc.want == pool.HashStatusVerified) != (heartbeat.ArtifactIdentity != nil) {
			t.Fatalf("heartbeat leg, mode %q: ok=%v status=%v artifact=%v", tc.mode, ok, heartbeat.HashStatus, heartbeat.ArtifactIdentity != nil)
		}
	}
	// Operator projections (/poolz, policy readiness) apply the session pin:
	// a session pinned to gguf-q4 now reporting gguf-q8 shows the session's
	// mismatch, never a fresh unpinned "verified".
	ggufB := strings.Repeat("d", 64)
	if err := server.SetArtifactIdentityIndexForTest(catalog, now, []artifactidentity.Member{
		{ModelKey: "small", ModelID: "model-a", ArtifactID: "mlx-4bit", HashAlgorithm: modelidentity.SnapshotManifestV1, Hash: rowHash, IsPrimary: true, RuntimeStatus: "recommendable"},
		{ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: ggufHash, RuntimeStatus: "recommendable"},
		{ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q8", HashAlgorithm: modelidentity.GGUFFileV1, Hash: ggufB, RuntimeStatus: "recommendable"},
	}); err != nil {
		t.Fatal(err)
	}
	pinnedProvider := pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", State: pool.StateReady, ExpectedModelHash: rowHash,
		ModelHash: ggufB, ModelHashAlgorithm: modelidentity.GGUFFileV1, CandidateCatalogSHA256: catalog.SHA256, CatalogAdmissionMode: "current",
		IdentityPin: &pool.IdentityPin{Member: artifactidentity.Member{ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: ggufHash, RuntimeStatus: "recommendable"}},
		SlotsFree:   1, SlotsTotal: 1, MaxConcurrency: 1, LastHeartbeatAt: now, LastActivityAt: now, HashStatus: pool.HashStatusMismatch}
	if v := server.verifyModelIdentity(providerIdentityRequest(pinnedProvider)); v.Status != pool.HashStatusVerified {
		t.Fatalf("unpinned verdict of the other member is verified (fixture sanity): %+v", v)
	}
	if v := pinnedProvider.PinnedVerdict(server.verifyModelIdentity(providerIdentityRequest(pinnedProvider))); v.Status != pool.HashStatusMismatch {
		t.Fatalf("projection must apply the pin: %+v", v)
	}
	strict := cfg.Tier2
	strict.RequireHashVerified = true
	if server.providerTier2PolicyEligible(pinnedProvider, strict) {
		t.Fatal("policy readiness must apply the session pin")
	}
	server.SetArtifactIdentityIndex(index)
	// A compatible-previous release has no loaded artifact feed: such a
	// session keeps the primary-row path only (SPEC-010-R004 as amended).
	previous := gguf
	previous.CandidateCatalogSHA256 = strings.Repeat("9", 64)
	if v := server.verifyModelIdentity(previous); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("compatible-previous release without its feed must be primary-only: %+v", v)
	}
	previousPrimary := primary
	previousPrimary.CandidateCatalogSHA256 = strings.Repeat("9", 64)
	if v := server.verifyModelIdentity(previousPrimary); v.Status != pool.HashStatusVerified || v.Artifact != nil {
		t.Fatalf("primary row path on a compatible-previous release: %+v", v)
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
	// The SIGHUP lifecycle: catalog swap (index dropped), then the feed publish
	// observer installs the index rebuilt from the published feeds.
	server.SetArtifactIdentityIndex(index)
	if v := server.verifyModelIdentity(gguf); v.Status != pool.HashStatusVerified || v.Artifact == nil {
		t.Fatalf("published index restores artifact authority: %+v", v)
	}
	server.SetArtifactIdentityIndex(nil)
	if v := server.verifyModelIdentity(gguf); v.Status != pool.HashStatusMismatch || v.Artifact != nil {
		t.Fatalf("a failed rebuild leaves no artifact authority: %+v", v)
	}
	// No index (rate-card-bound release): v1.6 verdicts exactly.
	server.SetArtifactIdentitySets(nil)
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

// SPEC-047-R002 `artifact_hashes` is keyed by the SPEC-010-R002 algorithm
// name — the CLI posts `macprovider.gguf-file.v1` (SPEC-010 v1.7 R007(a)) —
// so the offer validator accepts exactly the canonical names and nothing
// looser. This is the CLI→coordinator boundary a free-token grammar would
// have closed on every GGUF offer.
func TestModelAdmissionOfferArtifactHashesAreKeyedByCanonicalAlgorithm(t *testing.T) {
	t.Parallel()
	hex := func(c string) string { return strings.Repeat(c, 64) }
	for name, tc := range map[string]struct {
		hashes map[string]string
		ok     bool
	}{
		"gguf":              {map[string]string{modelidentity.GGUFFileV1: hex("c")}, true},
		"snapshot manifest": {map[string]string{modelidentity.SnapshotManifestV1: hex("d")}, true},
		"both":              {map[string]string{modelidentity.GGUFFileV1: hex("c"), modelidentity.SnapshotManifestV1: hex("d")}, true},
		"empty":             {map[string]string{}, true},
		"free token":        {map[string]string{"gguf": hex("c")}, false},
		"generic name":      {map[string]string{"sha256": hex("c")}, false},
		"weights manifest":  {map[string]string{modelidentity.SafetensorsManifestV1: hex("c")}, false},
		"uppercase digest":  {map[string]string{modelidentity.GGUFFileV1: strings.ToUpper(hex("c"))}, false},
	} {
		t.Run(name, func(t *testing.T) {
			maxContext := 2048
			payload := modelAdmissionOfferSubmitRequest{
				Schema: "model_admission_offer_submit.v1", SignatureDomain: "macprovider.model_admission.offer.v1",
				ProviderID: "provider-byom-a", CandidateID: "byom_" + strings.Repeat("a", 52), RuntimeSource: "ollama_loopback",
				ServedModelRef: "ollama:test-model:q4", DiscoveryDigestSHA256: hex("a"), EvaluationDigestSHA256: hex("b"),
				ArtifactHashes:       tc.hashes,
				AdvisoryCapabilities: &modelAdmissionAdvisoryCapabilities{MaxContextTokens: &maxContext},
				FitEvidenceSource:    "local_discovery", LocalReadiness: "ready", RequestedDisclosureClass: "non_earning_provider_asserted",
				Timestamp: time.Now().UTC().Format(time.RFC3339Nano), Nonce: "nonce_1", IdempotencyKey: "request_1",
				SigningKeyDigest: hex("e"), SignatureAlgorithm: "ed25519", ProviderSignature: "AA==", CLIVersion: "1.8.123",
			}
			err := validateModelAdmissionPayload(payload)
			if tc.ok && err != nil {
				t.Fatalf("%s: canonical artifact_hashes must validate: %v", name, err)
			}
			if !tc.ok && err == nil {
				t.Fatalf("%s: non-canonical artifact_hashes must be rejected", name)
			}
		})
	}
}

// SetArtifactIdentityIndexForTest installs an index for the given members
// bound to the catalog's digest and stamped a day before now.
func (s *Server) SetArtifactIdentityIndexForTest(catalog *autotune.Catalog, now time.Time, members []artifactidentity.Member) error {
	index, err := artifactidentity.New(artifactidentity.Provenance{
		FeedSHA256: strings.Repeat("a", 64), SignerKeyID: "k1", ReleaseID: "test", CandidateCatalogSHA256: catalog.SHA256,
		FeedGeneratedAt: now.Add(-24 * time.Hour),
	}, members)
	if err != nil {
		return err
	}
	s.SetArtifactIdentityIndex(index)
	return nil
}

// SPEC-047-R001 v0.1.5 / SPEC-010-R004 v1.8: with release staging on, the
// reload's catalog swap is invisible until the feed publish installs the
// identity sets, and both land as ONE generation; a session admitted on a
// retained previous release resolves in that release's own set.
func TestReleaseStagingPublishesCatalogAndIdentitySetsAsOneGeneration(t *testing.T) {
	const rowHash = "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a"
	ggufOld, ggufNew := strings.Repeat("c", 64), strings.Repeat("d", 64)
	catalogJSON := func(version string) string {
		return `{"version":"` + version + `","policy_version":"test-v1","generated_at":"2026-07-18T00:00:00Z","source":"operator_curated_autotune_candidate_catalog","rows":{"small":{"model_id":"model-a","model_revision":"revision-a","model_sha256":"` + rowHash + `","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommendable"}}}`
	}
	oldCatalog, err := autotune.ParseCatalog([]byte(catalogJSON("old")))
	if err != nil {
		t.Fatal(err)
	}
	newCatalog, err := autotune.ParseCatalog([]byte(catalogJSON("new")))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	setFor := func(catalog *autotune.Catalog, gguf string) *artifactidentity.Index {
		index, err := artifactidentity.New(artifactidentity.Provenance{
			FeedSHA256: strings.Repeat("a", 64), SignerKeyID: "k1", ReleaseID: catalog.Version, CandidateCatalogSHA256: catalog.SHA256, FeedGeneratedAt: now.Add(-24 * time.Hour),
		}, []artifactidentity.Member{{ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: gguf, RuntimeStatus: "recommendable"}})
		if err != nil {
			t.Fatal(err)
		}
		return index
	}
	cfg := config.Default()
	cfg.Tier2.ObserveEnabled = true
	server := &Server{cfg: cfg, tier2: cfg.Tier2, autotuneCatalog: oldCatalog, now: func() time.Time { return now }}
	WithReleaseStaging()(server)
	WithArtifactIdentitySets(map[string]*artifactidentity.Index{oldCatalog.SHA256: setFor(oldCatalog, ggufOld)})(server)
	req := func(catalog *autotune.Catalog, gguf string) pool.ModelIdentityRequest {
		return pool.ModelIdentityRequest{ModelID: "model-a", ExpectedHash: rowHash, ReportedHash: gguf, ReportedAlgorithm: modelidentity.GGUFFileV1,
			CandidateCatalogSHA256: catalog.SHA256, CatalogAdmissionMode: "current"}
	}
	if v := server.verifyModelIdentity(req(oldCatalog, ggufOld)); v.Status != pool.HashStatusVerified {
		t.Fatalf("old release member verifies before the reload: %+v", v)
	}
	// The reload stages the new catalog: nothing changes yet.
	server.SetAutotuneCatalog(newCatalog, oldCatalog)
	if server.currentAutotuneCatalog() != oldCatalog {
		t.Fatal("a staged catalog must not be visible before publication")
	}
	if got := server.ReleaseGeneration(); got != 0 {
		t.Fatalf("no generation before publication, got %d", got)
	}
	// The feed publish installs both releases' sets and publishes everything as one generation.
	gen := server.SetArtifactIdentitySets(map[string]*artifactidentity.Index{newCatalog.SHA256: setFor(newCatalog, ggufNew), oldCatalog.SHA256: setFor(oldCatalog, ggufOld)})
	if gen != 1 || server.ReleaseGeneration() != 1 || server.currentAutotuneCatalog() != newCatalog {
		t.Fatalf("publication: gen=%d catalog=%v", gen, server.currentAutotuneCatalog().Version)
	}
	// A session on the retained previous release resolves in ITS set (re-stamp is a no-op for it);
	// a session on the new release resolves in the new set; neither crosses over.
	if v := server.verifyModelIdentity(req(oldCatalog, ggufOld)); v.Status != pool.HashStatusVerified || v.Artifact == nil {
		t.Fatalf("previous-release session keeps artifact identity: %+v", v)
	}
	if v := server.verifyModelIdentity(req(newCatalog, ggufNew)); v.Status != pool.HashStatusVerified || v.Artifact == nil {
		t.Fatalf("new-release session resolves in the new set: %+v", v)
	}
	if v := server.verifyModelIdentity(req(oldCatalog, ggufNew)); v.Status != pool.HashStatusMismatch {
		t.Fatalf("a session never resolves another release's member: %+v", v)
	}
	// A reload whose feed publish never arrives still publishes the staged
	// catalog at the end-of-reload refresh, keeping the current sets.
	server.SetAutotuneCatalog(oldCatalog)
	server.pool = pool.NewRegistry(nil)
	server.RefreshTier2HashStatuses()
	if server.currentAutotuneCatalog() != oldCatalog || server.ReleaseGeneration() != 2 {
		t.Fatalf("staged catalog must publish at refresh: catalog=%s gen=%d", server.currentAutotuneCatalog().Version, server.ReleaseGeneration())
	}
	if v := server.verifyModelIdentity(req(oldCatalog, ggufOld)); v.Status != pool.HashStatusVerified {
		t.Fatalf("sets survive a catalog-only publication: %+v", v)
	}
	// Without staging (tests, tools) SetAutotuneCatalog publishes immediately and drops the sets.
	plain := &Server{cfg: cfg, tier2: cfg.Tier2, autotuneCatalog: oldCatalog, now: func() time.Time { return now }}
	WithArtifactIdentitySets(map[string]*artifactidentity.Index{oldCatalog.SHA256: setFor(oldCatalog, ggufOld)})(plain)
	plain.SetAutotuneCatalog(newCatalog)
	if plain.currentAutotuneCatalog() != newCatalog || plain.ReleaseGeneration() != 1 {
		t.Fatal("immediate publication without staging")
	}
	if v := plain.verifyModelIdentity(req(oldCatalog, ggufOld)); v.Status != pool.HashStatusMismatch {
		t.Fatalf("a catalog swap without its sets drops artifact authority: %+v", v)
	}
}
