package buyer_test

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

func ggufArtifactBinding() *artifactidentity.Binding {
	return &artifactidentity.Binding{
		Member: artifactidentity.Member{
			ModelKey: "model-a-key", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1,
			Hash: strings.Repeat("c", 64), RuntimeStatus: "recommendable",
		},
		Provenance: artifactidentity.Provenance{
			FeedSHA256: strings.Repeat("a", 64), SignerKeyID: "streamvc-autotune-static-v4",
			ReleaseID: "test-release", CandidateCatalogSHA256: strings.Repeat("b", 64),
			// The buyer server verifies freshness against the real clock.
			FeedGeneratedAt: time.Now().UTC().Add(-24 * time.Hour),
		},
	}
}

// seedBYOMArtifactSettlementState is seedBYOMAdmissionState with the
// decision events' expected identity set to the artifact member (what the
// coordinator records when the session resolved through the feed).
func seedBYOMArtifactSettlementState(t *testing.T, store providerws.ModelAdmissionStore, provider pool.Provider, binding *artifactidentity.Binding, state string) providerws.ModelAdmissionEvent {
	t.Helper()
	rowProvider := provider
	rowProvider.ModelHash = buyerTestHash
	rowProvider.ModelHashAlgorithm = modelidentity.SnapshotManifestV1
	// A decision that resolved the member records the member's row KEY as
	// the catalog key — a namespace distinct from the row's model id
	// ("model-a-key" vs "model-a" in these fixtures), which the route-time
	// lookup and predicate must reproduce.
	rowProvider.ModelAdmissionCatalogModelKey = binding.Member.ModelKey
	offer := seedBYOMAdmissionState(t, store, rowProvider, "offer_submitted")
	material, ok := tier2.SnapshotMaterial(provider.ModelID, buyerTestHash)
	if !ok {
		t.Fatal("missing trusted catalog material")
	}
	decision := offer
	decision.State = "catalog_priced"
	decision.RequestID = "decision-catalog-priced-artifact"
	decision.Nonce = "nonce-catalog-priced-artifact"
	decision.PayloadDigestSHA256 = strings.Repeat("f", 64)
	decision.CreatedAt = time.Unix(1800000010, 0).UTC()
	decision.CatalogID = material.CatalogID
	decision.CatalogBodyDigest = material.CatalogBodyDigest
	decision.CatalogSignatureKeyID = material.CatalogSignatureKeyID
	decision.CatalogSignaturePubkeyFingerprint = material.CatalogSignaturePubkeyFingerprint
	decision.ExpectedCatalogModelHash = binding.Member.Hash
	decision.ExpectedCatalogModelHashAlgorithm = binding.Member.HashAlgorithm
	stored, err := store.AppendModelAdmissionDecision(context.Background(), decision)
	if err != nil {
		t.Fatalf("AppendModelAdmissionDecision(catalog_priced): %v", err)
	}
	if state == "catalog_priced" {
		return stored
	}
	settlement := stored
	settlement.State = state
	settlement.RequestID = "decision-artifact-" + state
	settlement.Nonce = "nonce-artifact-" + state
	settlement.PayloadDigestSHA256 = strings.Repeat("1", 64)
	settlement.CreatedAt = time.Unix(1800000020, 0).UTC()
	// SPEC-047-R003 v0.1.5: a settlement_capable decision binds the session's
	// feed member as the settlement identity with its six values.
	settlement.BoundMemberSource = "artifact_feed"
	settlement.ArtifactID = binding.Member.ArtifactID
	settlement.ArtifactHash = binding.Member.Hash
	settlement.ArtifactHashAlgorithm = binding.Member.HashAlgorithm
	settlement.ArtifactFeedSHA256 = binding.Provenance.FeedSHA256
	settlement.ArtifactFeedSignerKeyID = binding.Provenance.SignerKeyID
	settlement.ArtifactCandidateCatalogSHA256 = binding.Provenance.CandidateCatalogSHA256
	stored, err = store.AppendModelAdmissionDecision(context.Background(), settlement)
	if err != nil {
		t.Fatalf("AppendModelAdmissionDecision(%s): %v", state, err)
	}
	return stored
}

func artifactSettlementServer(t *testing.T, provider pool.Provider, registry *pool.Registry, store providerws.ModelAdmissionStore) (*buyer.Server, string) {
	t.Helper()
	reqLog, dbPath := openBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeEnforce)
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}
	return buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithModelAdmissionStore(store),
		buyer.WithModelAdmissionRouteGuard(testRouteGuard{registry: registry, store: store}),
	), dbPath
}

// SPEC-010 v1.7 R007(d) / SPEC-047-R003 / AC-CAT-7(iii): a session whose GGUF
// pair resolved through the release-bound feed settles with the six values
// in the immutable route-time record and the member as the expected identity.
func TestBYOMArtifactMemberSettlesWithSixValueEvidence(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "byom-artifact-settlement-catalog", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeRouteSnapshotCatalog(t, raw), CatalogPublicKey: pubkey, RequireHashVerified: true}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeProviderOK(w) }))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x79}, 32))
	provider := byomAdmissionProvider(t, registry.Snapshot()[0])
	binding := ggufArtifactBinding()
	store := providerws.NewMemoryModelAdmissionStore()
	event := seedBYOMArtifactSettlementState(t, store, provider, binding, "settlement_capable")

	routeProvider := bindBYOMSession(clearBYOMAdmissionFields(provider), event)
	routeProvider.ModelHash = binding.Member.Hash
	routeProvider.ModelHashAlgorithm = binding.Member.HashAlgorithm
	routeProvider.ExpectedModelHash = buyerTestHash // the admitted ROW stays session authority (R004)
	routeProvider.HashStatus = pool.HashStatusVerified
	routeProvider.ArtifactIdentity = binding
	registry.Register(&routeProvider, nil)
	server, dbPath := artifactSettlementServer(t, routeProvider, registry, store)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	snapshot := queryRouteSnapshotBYOMBinding(t, dbPath)
	if snapshot["model_admission_coordinator_event_id"] != event.CoordinatorEventID {
		t.Fatalf("route snapshot missing the BYOM binding: %#v", snapshot)
	}
	want := map[string]string{
		"provider_reported_model_hash":           binding.Member.Hash,
		"provider_reported_model_hash_algorithm": modelidentity.GGUFFileV1,
		"expected_catalog_model_hash":            binding.Member.Hash,
		"expected_catalog_model_hash_algorithm":  modelidentity.GGUFFileV1,
		"artifact_feed_sha256":                   binding.Provenance.FeedSHA256,
		"artifact_id":                            "gguf-q4",
		"artifact_hash":                          binding.Member.Hash,
		"artifact_hash_algorithm":                modelidentity.GGUFFileV1,
		"artifact_feed_signer_key_id":            binding.Provenance.SignerKeyID,
		"artifact_candidate_catalog_sha256":      binding.Provenance.CandidateCatalogSHA256,
		"spec008_hash_status":                    string(pool.HashStatusVerified),
	}
	for key, value := range want {
		if got := snapshot[key]; got != value {
			t.Fatalf("route snapshot %s=%v want %s", key, got, value)
		}
	}
	if got := ledgerCreditCount(t, dbPath); got != 1 {
		t.Fatalf("ledger credits=%d want 1 for an artifact-member settlement", got)
	}
}

// Without the verified binding a GGUF pair is unverified: no route snapshot
// binding, no settlement — SPEC-010-R007(b) fails closed, never approximately.
func TestBYOMGGUFPairWithoutArtifactBindingNeverSettles(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "byom-artifact-unbound-catalog", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeRouteSnapshotCatalog(t, raw), CatalogPublicKey: pubkey, RequireHashVerified: true}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeProviderOK(w) }))
	defer upstream.Close()

	staleBinding := ggufArtifactBinding()
	staleBinding.Provenance.FeedGeneratedAt = time.Now().UTC().Add(-15 * 24 * time.Hour)
	for name, arrange := range map[string]func(*pool.Provider){
		"no binding at all":                func(p *pool.Provider) { p.ArtifactIdentity = nil },
		"binding but heartbeat unverified": func(p *pool.Provider) { p.HashStatus = pool.HashStatusMismatch },
		"binding hash differs from report": func(p *pool.Provider) { p.ModelHash = strings.Repeat("d", 64) },
		"binding from a stale feed (14d+)": func(p *pool.Provider) { p.ArtifactIdentity = staleBinding },
	} {
		t.Run(name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x79}, 32))
			provider := byomAdmissionProvider(t, registry.Snapshot()[0])
			binding := ggufArtifactBinding()
			store := providerws.NewMemoryModelAdmissionStore()
			event := seedBYOMArtifactSettlementState(t, store, provider, binding, "settlement_capable")
			routeProvider := bindBYOMSession(clearBYOMAdmissionFields(provider), event)
			routeProvider.ModelHash = binding.Member.Hash
			routeProvider.ModelHashAlgorithm = binding.Member.HashAlgorithm
			routeProvider.ExpectedModelHash = buyerTestHash
			routeProvider.HashStatus = pool.HashStatusVerified
			routeProvider.ArtifactIdentity = binding
			arrange(&routeProvider)
			registry.Register(&routeProvider, nil)
			server, dbPath := artifactSettlementServer(t, routeProvider, registry, store)
			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
			if got := ledgerCreditCount(t, dbPath); got != 0 {
				t.Fatalf("ledger credits=%d want 0 (status=%d body=%s)", got, rr.Code, rr.Body.String())
			}
		})
	}
}

// SPEC-023 §3.7.4 / AC-CAT-7(iii) and SPEC-010-R007(c) at route time: a
// `listed` row's member stops at network_visible_unpriced whatever its
// admission state says, a member of another row (model id) never settles for
// this session, and an asserted key that disagrees with the member fails
// closed — each while the same session with a recommendable, row-matching
// member DOES settle (TestBYOMArtifactMemberSettlesWithSixValueEvidence).
func TestBYOMArtifactMemberRouteTimeGatesFailClosed(t *testing.T) {
	for name, mutate := range map[string]func(*pool.Provider){
		"listed row": func(p *pool.Provider) { p.ArtifactIdentity.Member.RuntimeStatus = "listed" },
		"other row":  func(p *pool.Provider) { p.ArtifactIdentity.Member.ModelID = "model-b" },
		"asserted key disagrees": func(p *pool.Provider) {
			p.ModelAdmissionCatalogModelKey = "some-other-key"
		},
	} {
		t.Run(name, func(t *testing.T) {
			tier2.ResetForTest()
			t.Cleanup(tier2.ResetForTest)
			raw, pubkey := routeSnapshotCatalogFixture(t, "byom-gate-"+strings.ReplaceAll(name, " ", "-"), time.Now().UTC().Add(time.Hour))
			if err := tier2.Configure(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeRouteSnapshotCatalog(t, raw), CatalogPublicKey: pubkey, RequireHashVerified: true}, zerolog.Nop()); err != nil {
				t.Fatalf("tier2.Configure: %v", err)
			}
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeProviderOK(w) }))
			defer upstream.Close()
			registry := pool.NewRegistry(nil)
			registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x79}, 32))
			provider := byomAdmissionProvider(t, registry.Snapshot()[0])
			binding := ggufArtifactBinding()
			store := providerws.NewMemoryModelAdmissionStore()
			event := seedBYOMArtifactSettlementState(t, store, provider, binding, "settlement_capable")
			routeProvider := bindBYOMSession(clearBYOMAdmissionFields(provider), event)
			routeProvider.ModelHash = binding.Member.Hash
			routeProvider.ModelHashAlgorithm = binding.Member.HashAlgorithm
			routeProvider.ExpectedModelHash = buyerTestHash
			routeProvider.HashStatus = pool.HashStatusVerified
			routeProvider.ArtifactIdentity = binding
			mutate(&routeProvider)
			registry.Register(&routeProvider, nil)
			server, dbPath := artifactSettlementServer(t, routeProvider, registry, store)
			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
			if rr.Code == http.StatusOK {
				t.Fatalf("%s: must not settle: status=%d body=%s", name, rr.Code, rr.Body.String())
			}
			if got := ledgerCreditCount(t, dbPath); got != 0 {
				t.Fatalf("%s: ledger credits=%d want 0", name, got)
			}
		})
	}
}

// SPEC-010-R007(d) on every routing fallback: a member-bound session whose
// model has no tier-2 material and whose admission store holds nothing is
// excluded from default routing rather than dispatched to fail at the
// snapshot.
func TestArtifactBoundSessionWithoutMaterialIsExcludedFromRouting(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "byom-no-material-catalog", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeRouteSnapshotCatalog(t, raw), CatalogPublicKey: pubkey, RequireHashVerified: true}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeProviderOK(w) }))
	defer upstream.Close()
	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x79}, 32))
	provider := registry.Snapshot()[0]
	binding := ggufArtifactBinding()
	binding.Member.ModelID = "model-x"
	provider.ModelID = "model-x" // not in the tier-2 catalog: no material
	provider.ModelHash = binding.Member.Hash
	provider.ModelHashAlgorithm = binding.Member.HashAlgorithm
	provider.ExpectedModelHash = buyerTestHash
	provider.HashStatus = pool.HashStatusVerified
	provider.ArtifactIdentity = binding
	registry.Register(&provider, nil)
	server, dbPath := artifactSettlementServer(t, provider, registry, providerws.NewMemoryModelAdmissionStore())
	rr := postChat(t, server, []byte(`{"model":"model-x","messages":[{"role":"user","content":"hi"}]}`), nil)
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("member-bound session without material must be excluded: status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := ledgerCreditCount(t, dbPath); got != 0 {
		t.Fatalf("ledger credits=%d want 0", got)
	}
}

// SPEC-010-R007(d): a secondary snapshot-manifest member is feed-derived too.
// Without a BYOM admission binding there is no source for the six values, so
// the recorder fails closed rather than writing a member hash with no
// provenance (which would be indistinguishable from the row-bound primary).
func TestSecondaryMLXMemberWithoutAdmissionEvidenceNeverSettles(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "byom-secondary-mlx-catalog", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeRouteSnapshotCatalog(t, raw), CatalogPublicKey: pubkey, RequireHashVerified: true}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeProviderOK(w) }))
	defer upstream.Close()
	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x79}, 32))
	provider := registry.Snapshot()[0]
	secondary := ggufArtifactBinding()
	secondary.Member = artifactidentity.Member{
		ModelKey: "model-a-key", ModelID: "model-a", ArtifactID: "mlx-8bit", HashAlgorithm: modelidentity.SnapshotManifestV1,
		Hash: strings.Repeat("e", 64), RuntimeStatus: "recommendable",
	}
	provider.ModelHash = secondary.Member.Hash
	provider.ModelHashAlgorithm = modelidentity.SnapshotManifestV1
	provider.ExpectedModelHash = buyerTestHash
	provider.HashStatus = pool.HashStatusVerified
	provider.ArtifactIdentity = secondary
	registry.Register(&provider, nil)
	// No admission store at all: the legacy (non-BYOM) routing path.
	server, dbPath := artifactSettlementServer(t, provider, registry, nil)
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
	// Excluded from routing (no capacity), never dispatched to fail at the
	// snapshot: the buyer sees the same outcome as for a mismatched session.
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("secondary member without evidence must be excluded from routing: status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rows := queryRouteSnapshotBYOMBindings(t, dbPath); len(rows) != 0 {
		t.Fatalf("no route snapshot may be written without the six values: %#v", rows)
	}
	if got := ledgerCreditCount(t, dbPath); got != 0 {
		t.Fatalf("ledger credits=%d want 0", got)
	}
}
