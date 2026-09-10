package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

const (
	bindingRowHash   = "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a"
	bindingOtherHash = "4a75387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216b"
)

func bindingCatalogJSON(version, smallStatus, smallSHA string) string {
	return `{"version":"` + version + `","policy_version":"test-v1","generated_at":"2026-07-18T00:00:00Z","source":"operator_curated_autotune_candidate_catalog","rows":{` +
		`"small":{"model_id":"model-a","model_revision":"revision-a","model_sha256":"` + smallSHA + `","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"` + smallStatus + `"},` +
		`"other":{"model_id":"model-b","model_revision":"revision-b","model_sha256":"` + bindingOtherHash + `","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommendable"}}}`
}

func bindingCatalog(t *testing.T, version, smallStatus, smallSHA string) *autotune.Catalog {
	t.Helper()
	catalog, err := autotune.ParseCatalog([]byte(bindingCatalogJSON(version, smallStatus, smallSHA)))
	if err != nil {
		t.Fatal(err)
	}
	return catalog
}

func bindingMembers(ggufHash, ggufOther string) []artifactidentity.Member {
	members := []artifactidentity.Member{
		{ModelKey: "small", ModelID: "model-a", ArtifactID: "mlx-4bit", HashAlgorithm: modelidentity.SnapshotManifestV1, Hash: bindingRowHash, IsPrimary: true, RuntimeStatus: "recommendable", AllowedRuntimeSources: "mlx_cache"},
	}
	if ggufHash != "" {
		members = append(members, artifactidentity.Member{ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: ggufHash, RuntimeStatus: "recommendable", AllowedRuntimeSources: "llamacpp_loopback,ollama_loopback"})
	}
	if ggufOther != "" {
		members = append(members, artifactidentity.Member{ModelKey: "other", ModelID: "model-b", ArtifactID: "gguf-b", HashAlgorithm: modelidentity.GGUFFileV1, Hash: ggufOther, RuntimeStatus: "recommendable", AllowedRuntimeSources: "ollama_loopback"})
	}
	return members
}

func bindingIndex(t *testing.T, catalog *autotune.Catalog, feedSHA string, now time.Time, members []artifactidentity.Member) *artifactidentity.Index {
	t.Helper()
	index, err := artifactidentity.New(artifactidentity.Provenance{
		FeedSHA256: feedSHA, SignerKeyID: "k1", ReleaseID: catalog.Version, CandidateCatalogSHA256: catalog.SHA256,
		FeedGeneratedAt: now.Add(-24 * time.Hour),
	}, members)
	if err != nil {
		t.Fatal(err)
	}
	return index
}

// bindingTier2Catalog is a signed Tier-2 catalog whose model-a row material
// names the candidate row's digest (SPEC-010-R004 composite proof).
func bindingTier2Catalog(t *testing.T, catalogID string) *tier2.Catalog {
	t.Helper()
	privateKey := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{7}, ed25519.SeedSize))
	publicKey := privateKey.Public().(ed25519.PublicKey)
	issuedAt := time.Now().UTC().Add(-time.Hour)
	expiresAt := time.Now().UTC().Add(24 * time.Hour)
	type catalogModel struct {
		ArtifactKind string `json:"artifact_kind"`
		HashScope    string `json:"hash_scope"`
		ModelID      string `json:"model_id"`
		SHA256       string `json:"sha256"`
		Source       string `json:"source"`
	}
	models := []catalogModel{{ArtifactKind: "mlx_weight_file", HashScope: "primary_weight_file", ModelID: "model-a", SHA256: bindingRowHash, Source: "operator-curated"}}
	body := struct {
		CatalogID string         `json:"catalog_id"`
		ExpiresAt string         `json:"expires_at"`
		IssuedAt  string         `json:"issued_at"`
		Models    []catalogModel `json:"models"`
		Version   int            `json:"version"`
	}{catalogID, expiresAt.Format(time.RFC3339), issuedAt.Format(time.RFC3339), models, 1}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(privateKey, canonical)
	file := struct {
		CatalogID string         `json:"catalog_id"`
		ExpiresAt string         `json:"expires_at"`
		IssuedAt  string         `json:"issued_at"`
		Models    []catalogModel `json:"models"`
		Signature map[string]any `json:"signature"`
		Version   int            `json:"version"`
	}{body.CatalogID, body.ExpiresAt, body.IssuedAt, models, map[string]any{"alg": "Ed25519", "key_id": "ws-test-key", "sig": base64.RawURLEncoding.EncodeToString(sig)}, 1}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "catalog.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	c := tier2.NewCatalog()
	if err := c.Configure(config.Tier2Config{CatalogPath: path, CatalogPublicKey: base64.RawURLEncoding.EncodeToString(publicKey)}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2 configure: %v", err)
	}
	return c
}

type bindingFixture struct {
	server  *Server
	catalog *autotune.Catalog
	index   *artifactidentity.Index
	now     time.Time
	gguf    string
}

func newBindingFixture(t *testing.T) *bindingFixture {
	t.Helper()
	now := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	catalog := bindingCatalog(t, "release-1", "recommendable", bindingRowHash)
	gguf := strings.Repeat("c", 64)
	index := bindingIndex(t, catalog, strings.Repeat("a", 64), now, bindingMembers(gguf, strings.Repeat("b", 64)))
	cfg := config.Default()
	cfg.Tier2.ObserveEnabled = true
	server := &Server{cfg: cfg, tier2: cfg.Tier2, autotuneCatalog: catalog, now: func() time.Time { return now }, log: zerolog.Nop(),
		modelAdmissions: NewMemoryModelAdmissionStore(), catalog: bindingTier2Catalog(t, "tier2-1")}
	server.artifactIdentitySets.sets = map[string]*artifactidentity.Index{catalog.SHA256: index}
	// Production wiring: the reload stages the catalog and the feed publish
	// installs the identity sets, as one generation.
	server.artifactIdentitySets.staging = true
	server.pool = pool.NewRegistry(nil, pool.WithModelIdentityResolver(server.verifyModelIdentity))
	return &bindingFixture{server: server, catalog: catalog, index: index, now: now, gguf: gguf}
}

// publish is the SIGHUP lifecycle: catalog staged, sets published with it.
func (f *bindingFixture) publish(catalog *autotune.Catalog, sets map[string]*artifactidentity.Index, compatible ...*autotune.Catalog) {
	f.server.SetAutotuneCatalog(catalog, compatible...)
	f.server.SetArtifactIdentitySets(sets)
}

func (f *bindingFixture) registerSession(t *testing.T, providerID, assignedID, modelID string, receiptKey bool) {
	t.Helper()
	entry := &pool.Provider{ProviderID: providerID, AssignedID: assignedID, ModelID: modelID, State: pool.StateReady,
		ModelHash: bindingRowHash, ModelHashAlgorithm: modelidentity.SnapshotManifestV1, ExpectedModelHash: bindingRowHash,
		HashStatus: pool.HashStatusVerified, CandidateCatalogSHA256: f.catalog.SHA256, CatalogAdmissionMode: "current", CatalogReleaseID: f.catalog.Version,
		SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1, LastHeartbeatAt: f.now, LastActivityAt: f.now}
	if receiptKey {
		entry.ReceiptPubkey = bytes.Repeat([]byte{9}, ed25519.PublicKeySize)
	}
	if _, ok, refusal := f.server.pool.RegisterAtDetailed(entry, nil, f.now); !ok {
		t.Fatalf("register refused: %v", refusal)
	}
}

// registerGGUFSession registers a session pinned to the feed's GGUF member
// (hash-verified through the feed), the session a loopback candidate needs.
func (f *bindingFixture) registerGGUFSession(t *testing.T, providerID, assignedID string) {
	t.Helper()
	entry := &pool.Provider{ProviderID: providerID, AssignedID: assignedID, ModelID: "model-a", State: pool.StateReady,
		ModelHash: f.gguf, ModelHashAlgorithm: modelidentity.GGUFFileV1, ExpectedModelHash: bindingRowHash, HashStatus: pool.HashStatusVerified,
		ArtifactIdentity:       &artifactidentity.Binding{Member: artifactidentity.Member{ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: f.gguf, RuntimeStatus: "recommendable", AllowedRuntimeSources: "llamacpp_loopback,ollama_loopback"}},
		CandidateCatalogSHA256: f.catalog.SHA256, CatalogAdmissionMode: "current", CatalogReleaseID: f.catalog.Version,
		ReceiptPubkey: bytes.Repeat([]byte{9}, ed25519.PublicKeySize), SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1, LastHeartbeatAt: f.now, LastActivityAt: f.now}
	if _, ok, refusal := f.server.pool.RegisterAtDetailed(entry, nil, f.now); !ok {
		t.Fatalf("register gguf session refused: %v", refusal)
	}
}

func (f *bindingFixture) offer(t *testing.T, providerID, suffix, runtimeSource string, hashes map[string]string) ModelAdmissionEvent {
	t.Helper()
	candidateID := "byom_" + strings.Repeat(suffix, 52)
	event := ModelAdmissionEvent{
		ProviderID: providerID, CandidateID: candidateID, ServedModelRef: "ref-" + suffix,
		DiscoveryDigestSHA256: strings.Repeat("a", 64), EvaluationDigestSHA256: strings.Repeat("b", 64),
		RequestedDisclosureClass: "catalog_binding_requested", State: modelAdmissionOfferSubmitted, ReasonCode: "provider_offer_submitted",
		RequestID: "request_" + suffix, Nonce: "nonce_" + suffix, PayloadDigestSHA256: strings.Repeat(suffix, 64), SignatureDigestSHA256: strings.Repeat("d", 64), CreatedAt: f.now,
	}
	event = f.server.applyModelAdmissionOfferCatalogMatch(event, modelAdmissionOfferSubmitRequest{RuntimeSource: runtimeSource, ArtifactHashes: hashes})
	stored, replay, err := f.server.appendModelAdmissionEventInSection(context.Background(), providerID, func(ctx context.Context) (ModelAdmissionEvent, bool, error) {
		return f.server.modelAdmissions.AppendModelAdmissionOffer(ctx, event)
	})
	if err != nil || replay {
		t.Fatalf("offer %s: replay=%v err=%v", suffix, replay, err)
	}
	return stored
}

// decide appends an operator decision the way the endpoint does (stage D):
// CAS on the head under the section, the Tier-2 row material bound.
func (f *bindingFixture) decide(t *testing.T, current ModelAdmissionEvent, nextState string) ModelAdmissionEvent {
	t.Helper()
	material, ok := f.server.catalogRef().RouteSnapshotMaterial("model-a", bindingRowHash)
	if !ok {
		t.Fatal("tier2 material missing")
	}
	decision := current
	decision.State = nextState
	decision.Actor = "operator:alice"
	decision.ReasonCode = "operator_test"
	decision.RequestID = "operator_decision_" + current.CandidateID + "_" + nextState
	decision.Nonce = "operator_nonce_" + current.CandidateID + "_" + nextState
	decision.PayloadDigestSHA256 = strings.Repeat("e", 64)
	decision.CreatedAt = f.now
	decision.CatalogID = material.CatalogID
	decision.CatalogBodyDigest = material.CatalogBodyDigest
	decision.CatalogSignatureKeyID = material.CatalogSignatureKeyID
	decision.CatalogSignaturePubkeyFingerprint = material.CatalogSignaturePubkeyFingerprint
	decision.ExpectedCatalogModelHash = bindingRowHash
	decision.ExpectedCatalogModelHashAlgorithm = modelidentity.SnapshotManifestV1
	stored, _, err := f.server.appendModelAdmissionEventInSection(context.Background(), current.ProviderID, func(ctx context.Context) (ModelAdmissionEvent, bool, error) {
		return f.server.modelAdmissions.CASAppendModelAdmissionDecision(ctx, decision, current.CoordinatorEventID)
	})
	if err != nil {
		t.Fatalf("decide %s: %v", nextState, err)
	}
	return stored
}

func (f *bindingFixture) latest(t *testing.T, providerID, candidateID string) ModelAdmissionEvent {
	t.Helper()
	event, found, err := f.server.modelAdmissions.LatestModelAdmissionStatus(context.Background(), providerID, candidateID)
	if err != nil || !found {
		t.Fatalf("latest %s: found=%v err=%v", candidateID, found, err)
	}
	return event
}

// SPEC-047-R001 v0.1.5 "Match" / R008: the two resolution paths, the fixed
// ordering (raw resolution, key spanning, asserted-key disagreement, the
// runtime-source admissibility filter), one runtime format per offer, and
// the recorded reason for every unmatched outcome.
func TestModelAdmissionOfferTimeMatchOrdering(t *testing.T) {
	f := newBindingFixture(t)
	gguf := f.gguf
	snapshot := modelidentity.SnapshotManifestV1
	ggufAlg := modelidentity.GGUFFileV1
	sources := func(members []ModelAdmissionCatalogMember) string {
		parts := make([]string, 0, len(members))
		for _, m := range members {
			parts = append(parts, m.Source+":"+m.ArtifactID)
		}
		return strings.Join(parts, ",")
	}
	for _, tc := range []struct {
		name         string
		index        *artifactidentity.Index
		integrity    bool
		source, key  string
		hashes       map[string]string
		wantState    string
		wantReason   string
		wantKey      string
		wantMembers  string
		wantRowModel string
	}{
		{name: "mlx offer records the primary only", index: f.index, source: "mlx_cache", hashes: map[string]string{snapshot: bindingRowHash, ggufAlg: gguf}, wantState: "catalog_matched", wantReason: "none", wantKey: "small", wantMembers: "candidate_row:", wantRowModel: "model-a"},
		{name: "loopback offer records the gguf member only", index: f.index, source: "ollama_loopback", hashes: map[string]string{snapshot: bindingRowHash, ggufAlg: gguf}, wantState: "catalog_matched", wantReason: "none", wantKey: "small", wantMembers: "artifact_feed:gguf-q4", wantRowModel: "model-a"},
		{name: "row-bound primary with no usable set", index: nil, source: "mlx_cache", hashes: map[string]string{snapshot: bindingRowHash}, wantState: "catalog_matched", wantReason: "none", wantKey: "small", wantMembers: "candidate_row:", wantRowModel: "model-a"},
		{name: "feed pair with no set", index: nil, source: "ollama_loopback", hashes: map[string]string{ggufAlg: gguf}, wantState: "unmatched", wantReason: "no_artifact_match"},
		{name: "feed pair with an integrity-failed set", index: nil, integrity: true, source: "ollama_loopback", hashes: map[string]string{ggufAlg: gguf}, wantState: "unmatched", wantReason: "catalog_artifact_feed_integrity_failure"},
		{name: "raw pairs spanning keys are rejected before admissibility", index: f.index, source: "mlx_cache", hashes: map[string]string{snapshot: bindingRowHash, ggufAlg: strings.Repeat("b", 64)}, wantState: "unmatched", wantReason: "artifact_hashes_span_keys"},
		{name: "asserted key disagreeing with the resolved key", index: f.index, source: "mlx_cache", key: "other", hashes: map[string]string{snapshot: bindingRowHash}, wantState: "unmatched", wantReason: "catalog_model_key_disagrees"},
		{name: "asserted key agreeing is fine", index: f.index, source: "mlx_cache", key: "SMALL", hashes: map[string]string{snapshot: bindingRowHash}, wantState: "catalog_matched", wantReason: "none", wantKey: "small", wantMembers: "candidate_row:", wantRowModel: "model-a"},
		{name: "only resolvable member disallowed for the source", index: f.index, source: "ollama_loopback", hashes: map[string]string{snapshot: bindingRowHash}, wantState: "unmatched", wantReason: "runtime_source_not_allowed"},
		{name: "gguf member under mlx_cache disallowed", index: f.index, source: "mlx_cache", hashes: map[string]string{ggufAlg: gguf}, wantState: "unmatched", wantReason: "runtime_source_not_allowed"},
		{name: "no hashes", index: f.index, source: "mlx_cache", hashes: map[string]string{}, wantState: "unmatched", wantReason: "no_artifact_match"},
		{name: "unknown pair", index: f.index, source: "ollama_loopback", hashes: map[string]string{ggufAlg: strings.Repeat("f", 64)}, wantState: "unmatched", wantReason: "no_artifact_match"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			match := matchOfferArtifactHashes(f.catalog, tc.index, tc.integrity, tc.source, tc.key, tc.hashes)
			if match.State != tc.wantState || match.Reason != tc.wantReason || match.CatalogModelKey != tc.wantKey || sources(match.Members) != tc.wantMembers {
				t.Fatalf("got state=%s reason=%s key=%q members=%q", match.State, match.Reason, match.CatalogModelKey, sources(match.Members))
			}
			if tc.wantState == "catalog_matched" {
				if match.RowModelID != tc.wantRowModel || match.RowModelSHA256 != bindingRowHash || match.ReleaseID != f.catalog.Version || match.CandidateSHA256 != f.catalog.SHA256 {
					t.Fatalf("row/release tuple: %+v", match)
				}
				for _, m := range match.Members {
					feed := m.Source == modelAdmissionMemberSourceArtifactFeed
					if feed != (m.ArtifactID != "" && m.ArtifactFeedSHA256 != "" && m.ArtifactFeedSignerKeyID != "" && m.ArtifactCandidateCatalogSHA256 != "") {
						t.Fatalf("provenance must be non-null exactly for artifact_feed members: %+v", m)
					}
				}
			} else if match.CatalogModelKey != "" || len(match.Members) != 0 {
				t.Fatalf("unmatched offer must store a null key and no members: %+v", match)
			}
		})
	}
	// An ambiguous primary row (two listed rows with one digest) matches
	// nothing; provider-asserted keys never disambiguate.
	ambiguous := bindingCatalog(t, "release-amb", "recommendable", bindingOtherHash)
	match := matchOfferArtifactHashes(ambiguous, nil, false, "mlx_cache", "small", map[string]string{snapshot: bindingOtherHash})
	if match.State != "unmatched" || match.Reason != "primary_row_ambiguous" {
		t.Fatalf("ambiguous primary: %+v", match)
	}
}

// SPEC-047-R003 v0.1.5 / R006(a)(d) / R008: the coordinator-derived session
// binding — derived at offer and hello, nothing bound for unmatched or
// ambiguous candidates, refreshed on every append, cleared on withdrawal,
// model change and disconnect — and the hello/heartbeat drift revocations.
func TestModelAdmissionSessionBindingLifecycleAndDrift(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	ctx := context.Background()
	f.registerSession(t, "p1", "s1", "model-a", true)

	// An unmatched offer binds nothing.
	unmatched := f.offer(t, "p1", "u", "ollama_loopback", map[string]string{})
	if unmatched.CatalogMatchState != "unmatched" || unmatched.CatalogModelKey != "" {
		t.Fatalf("unmatched offer: %+v", unmatched)
	}
	if p, _ := s.pool.Resolve("p1", ""); p.ModelAdmissionCandidateID != "" {
		t.Fatalf("unmatched candidate must not bind: %+v", p.ModelAdmissionCandidateID)
	}
	// A matched offer for the served row binds at offer time.
	a := f.offer(t, "p1", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	p, _ := s.pool.Resolve("p1", "")
	binding, bound := p.ModelAdmissionBinding()
	if !bound || binding.CandidateID != a.CandidateID || binding.CoordinatorEventID != a.CoordinatorEventID || binding.CatalogModelKey != "small" ||
		binding.CatalogRowStatus != "recommendable" || binding.ValidatedReleaseGeneration != s.ReleaseGeneration() {
		t.Fatalf("binding after offer: %+v (gen %d)", binding, s.ReleaseGeneration())
	}
	generationAfterA := s.ModelAdmissionBindingGeneration("p1")
	// A second matched candidate on the same row is ambiguous: nothing bound.
	b := f.offer(t, "p1", "b", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	if p, _ := s.pool.Resolve("p1", ""); p.ModelAdmissionCandidateID != "" {
		t.Fatal("ambiguous candidates must bind nothing")
	}
	if s.ModelAdmissionBindingGeneration("p1") <= generationAfterA {
		t.Fatal("binding generation must advance on every append")
	}
	// Withdrawing B restores the binding to A.
	withdrawal := b
	withdrawal.State = modelAdmissionWithdrawn
	withdrawal.ReasonCode = "provider_requested"
	withdrawal.RequestID, withdrawal.Nonce, withdrawal.PayloadDigestSHA256 = "withdraw_b", "withdraw_nonce_b", strings.Repeat("9", 64)
	if _, _, err := s.appendModelAdmissionEventInSection(ctx, "p1", func(ctx context.Context) (ModelAdmissionEvent, bool, error) {
		return s.modelAdmissions.AppendModelAdmissionWithdrawal(ctx, withdrawal)
	}); err != nil {
		t.Fatal(err)
	}
	if p, _ := s.pool.Resolve("p1", ""); p.ModelAdmissionCandidateID != a.CandidateID {
		t.Fatalf("binding must return to A after withdrawal: %q", p.ModelAdmissionCandidateID)
	}
	// Decisions refresh the binding's head.
	priced := f.decide(t, a, "catalog_priced")
	if p, _ := s.pool.Resolve("p1", ""); p.ModelAdmissionCoordinatorEventID != priced.CoordinatorEventID {
		t.Fatal("decision must refresh the bound head")
	}
	// Heartbeat under which the session serves another model: revoked with
	// runtime_identity_drift, binding cleared.
	prior, _ := p.ModelAdmissionBinding()
	prior.CoordinatorEventID = priced.CoordinatorEventID
	hb := pool.HeartbeatUpdate{Status: pool.StateReady, ModelID: "model-b", ModelHash: bindingOtherHash, ModelHashPresent: true,
		ModelHashAlgorithm: modelidentity.SnapshotManifestV1, ModelHashAlgorithmPresent: true, ExpectedModelHash: bindingOtherHash,
		MaxContextTokens: 8192, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, At: f.now.Add(time.Minute)}
	result := s.pool.ApplyHeartbeatDetailed("p1", "s1", hb)
	if !result.OK || !result.ModelIDChanged {
		t.Fatalf("heartbeat: %+v", result)
	}
	s.evaluateModelAdmissionSessionOnHeartbeat(*result.Provider, prior, true)
	if latest := f.latest(t, "p1", a.CandidateID); latest.State != modelAdmissionRevoked || latest.ReasonCode != "runtime_identity_drift" || latest.Actor != modelAdmissionActorCoordinator {
		t.Fatalf("model change must revoke the bound decided candidate: %+v", latest)
	}
	if p, _ := s.pool.Resolve("p1", ""); p.ModelAdmissionCandidateID != "" {
		t.Fatal("binding must be cleared after model change")
	}

	// Fresh session + candidate; settlement_capable needs the receipt key.
	f.registerSession(t, "p2", "s2", "model-a", false)
	c := f.offer(t, "p2", "c", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	c = f.decide(t, c, "catalog_priced")
	c = f.decide(t, c, "settlement_capable")
	// The registry mirror of a replacement hello without the receipt key:
	// evaluated before the binding is observable, revoked receipt_key_unavailable.
	priorP2, _ := s.pool.Resolve("p2", "")
	f.registerSession(t, "p2", "s2b", "model-a", false)
	s.bindModelAdmissionSessionAtHello("p2", priorP2, true)
	if latest := f.latest(t, "p2", c.CandidateID); latest.State != modelAdmissionRevoked || latest.ReasonCode != "receipt_key_unavailable" {
		t.Fatalf("hello without receipt key must revoke settlement_capable: %+v", latest)
	}
	if p, _ := s.pool.Resolve("p2", ""); p.ModelAdmissionCandidateID != "" {
		t.Fatal("revoked candidate must not be bound")
	}

	// Disconnect clears the binding; the next hello re-derives it.
	f.registerSession(t, "p3", "s3", "model-a", true)
	d := f.offer(t, "p3", "d", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	s.clearModelAdmissionBindingOnDisconnect("p3", "s3")
	if p, _ := s.pool.Resolve("p3", ""); p.ModelAdmissionCandidateID != "" {
		t.Fatal("disconnect must clear the binding")
	}
	s.bindModelAdmissionSessionAtHello("p3", pool.Provider{}, false)
	if p, _ := s.pool.Resolve("p3", ""); p.ModelAdmissionCandidateID != d.CandidateID {
		t.Fatal("hello must re-derive the binding")
	}
	// A hello whose session is not hash_verified for a recorded member
	// (member-pinned GGUF session for a primary-only candidate) is drift for
	// a decided candidate: revoked before the binding is published.
	d = f.decide(t, d, "catalog_priced")
	priorP3, _ := s.pool.Resolve("p3", "")
	entry := &pool.Provider{ProviderID: "p3", AssignedID: "s3b", ModelID: "model-a", State: pool.StateReady,
		ModelHash: f.gguf, ModelHashAlgorithm: modelidentity.GGUFFileV1, ExpectedModelHash: bindingRowHash, HashStatus: pool.HashStatusVerified,
		ArtifactIdentity:       &artifactidentity.Binding{Member: artifactidentity.Member{ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: f.gguf}},
		CandidateCatalogSHA256: f.catalog.SHA256, CatalogAdmissionMode: "current", CatalogReleaseID: f.catalog.Version,
		ReceiptPubkey: bytes.Repeat([]byte{9}, ed25519.PublicKeySize), SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1, LastHeartbeatAt: f.now, LastActivityAt: f.now}
	if _, ok, _ := s.pool.RegisterAtDetailed(entry, nil, f.now); !ok {
		t.Fatal("register")
	}
	s.bindModelAdmissionSessionAtHello("p3", priorP3, true)
	if latest := f.latest(t, "p3", d.CandidateID); latest.State != modelAdmissionRevoked || latest.ReasonCode != "runtime_identity_drift" {
		t.Fatalf("session pinned to a member the candidate never recorded must be drift: %+v", latest)
	}
}

// SPEC-047-R006(b)(c) v0.1.5 / R008: a release RE-STAMP (new release id,
// digest, feed signature; unchanged rows and members) changes nothing —
// no revocation, bindings re-validated under the new generation — while a
// content change per field revokes with the matching code.
func TestModelAdmissionReleaseSweepRevokesOnContentChangeOnly(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	f.registerSession(t, "p1", "s1", "model-a", true)
	rowOnly := f.offer(t, "p1", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	rowOnly = f.decide(t, rowOnly, "catalog_priced")
	f.registerGGUFSession(t, "p2", "s2")
	feed := f.offer(t, "p2", "b", "ollama_loopback", map[string]string{modelidentity.GGUFFileV1: f.gguf})
	if len(feed.CatalogMembers) != 1 || feed.CatalogMembers[0].Source != "artifact_feed" {
		t.Fatalf("feed offer: %+v", feed.CatalogMembers)
	}
	feed = f.decide(t, feed, "catalog_priced")

	// Re-stamp: same rows and members, new release id, digest and feed digest.
	restamped := bindingCatalog(t, "release-2", "recommendable", bindingRowHash)
	before := s.ReleaseGeneration()
	f.publish(restamped, map[string]*artifactidentity.Index{
		restamped.SHA256: bindingIndex(t, restamped, strings.Repeat("e", 64), f.now, bindingMembers(f.gguf, strings.Repeat("b", 64))),
		f.catalog.SHA256: f.index,
	}, f.catalog)
	if s.ReleaseGeneration() <= before {
		t.Fatal("generation must advance")
	}
	for _, c := range []ModelAdmissionEvent{rowOnly, feed} {
		if latest := f.latest(t, c.ProviderID, c.CandidateID); latest.State != "catalog_priced" {
			t.Fatalf("re-stamp must revoke nothing: %+v", latest)
		}
		p, _ := s.pool.Resolve(c.ProviderID, "")
		if p.ModelAdmissionCandidateID != c.CandidateID || p.ModelAdmissionValidatedReleaseGeneration != s.ReleaseGeneration() {
			t.Fatalf("survivor binding must be re-stamped with the new generation: %+v", p.ModelAdmissionValidatedReleaseGeneration)
		}
	}
	// Feed drops the gguf member: only the feed-member candidate is revoked.
	f.publish(restamped, map[string]*artifactidentity.Index{
		restamped.SHA256: bindingIndex(t, restamped, strings.Repeat("f", 64), f.now, bindingMembers("", strings.Repeat("b", 64))),
	}, f.catalog)
	if latest := f.latest(t, "p2", feed.CandidateID); latest.State != modelAdmissionRevoked || latest.ReasonCode != "catalog_artifact_feed_changed" {
		t.Fatalf("member removed from the set: %+v", latest)
	}
	if latest := f.latest(t, "p1", rowOnly.CandidateID); latest.State != "catalog_priced" {
		t.Fatalf("row-only candidate is unaffected by feed state: %+v", latest)
	}
	// Row demoted to listed (unchanged digest): catalog_row_ineligible.
	f.registerSession(t, "p3", "s3", "model-a", true)
	rowB := f.decide(t, f.offer(t, "p3", "c", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash}), "catalog_priced")
	f.publish(bindingCatalog(t, "release-3", "listed", bindingRowHash), nil)
	if latest := f.latest(t, "p1", rowOnly.CandidateID); latest.State != modelAdmissionRevoked || latest.ReasonCode != "catalog_row_ineligible" {
		t.Fatalf("listed row: %+v", latest)
	}
	if latest := f.latest(t, "p3", rowB.CandidateID); latest.State != modelAdmissionRevoked || latest.ReasonCode != "catalog_row_ineligible" {
		t.Fatalf("listed row (second candidate): %+v", latest)
	}
	// Row digest changed: catalog_row_changed.
	f.publish(bindingCatalog(t, "release-4", "recommendable", bindingRowHash), nil)
	f.registerSession(t, "p4", "s4", "model-a", true)
	rowC := f.decide(t, f.offer(t, "p4", "d", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash}), "catalog_priced")
	f.publish(bindingCatalog(t, "release-5", "recommendable", strings.Repeat("1", 64)), nil)
	if latest := f.latest(t, "p4", rowC.CandidateID); latest.State != modelAdmissionRevoked || latest.ReasonCode != "catalog_row_changed" {
		t.Fatalf("row digest changed: %+v", latest)
	}
	// Tier-2 material replaced (row unchanged): the bound catalog identity no
	// longer equals the current material → catalog_row_changed.
	f.publish(bindingCatalog(t, "release-6", "recommendable", bindingRowHash), nil)
	f.registerSession(t, "p5", "s5", "model-a", true)
	rowD := f.decide(t, f.offer(t, "p5", "e", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash}), "catalog_priced")
	s.catalog = bindingTier2Catalog(t, "tier2-2")
	f.publish(bindingCatalog(t, "release-7", "recommendable", bindingRowHash), nil)
	if latest := f.latest(t, "p5", rowD.CandidateID); latest.State != modelAdmissionRevoked || latest.ReasonCode != "catalog_row_changed" {
		t.Fatalf("tier2 material change: %+v", latest)
	}
}
