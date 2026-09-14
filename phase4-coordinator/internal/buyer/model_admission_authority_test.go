package buyer_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// All keys and feeds here are local fixtures, never operator authority.
func primaryAdmissionFixture(t *testing.T, registryOut ...**pool.Registry) (*buyer.Server, pool.Provider, providerws.ModelAdmissionEvent, buyer.AutotuneFeeds, config.RewardsConfig, *billing.Store) {
	t.Helper()
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	now := time.Now().UTC()
	generated := now.Add(-time.Hour).Format(time.RFC3339)
	pub, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	candidates := []byte(strings.Replace(string(validCandidateFeed("fixture-primary")), "2026-07-10T00:00:00Z", generated, 1))
	digest := sha256.Sum256(candidates)
	candidateSHA := hex.EncodeToString(digest[:])
	artifacts := validCatalogArtifactsFeed("fixture-primary", generated, "autotune-policy-v1", candidateSHA)
	rateRow := map[string]any{"prompt_rate_per_mtok": 700000, "prompt_cache_hit_rate_per_mtok": 130000, "completion_rate_per_mtok": 1700000, "provider_share_bps": 8300, "global_multiplier_ppm": 1200000}
	rows := map[string]any{"default": rateRow, "test-model": rateRow}
	projection, _ := json.Marshal(map[string]any{"global_multiplier_ppm": 1200000, "provider_share_bps": 8300, "rows": rows, "usd_per_million_credits": 1})
	rateDigest := sha256.Sum256(projection)
	rateBody, _ := json.Marshal(map[string]any{"version": hex.EncodeToString(rateDigest[:]), "generated_at": generated, "policy_version": "autotune-policy-v1", "usd_per_million_credits": 1, "rows": rows})
	dir := t.TempDir()
	cfg := config.AutotuneFeedsConfig{PublicKeys: map[string]string{"test-key": base64.StdEncoding.EncodeToString(pub)}}
	cfg.AutotuneCandidatesPath, cfg.AutotuneCandidatesSigPath = writeSignedFeedPair(t, dir, "candidates", candidates, "test-key", private)
	cfg.CatalogArtifactsPath, cfg.CatalogArtifactsSigPath = writeSignedFeedPair(t, dir, "artifacts", artifacts, "test-key", private)
	cfg.RateCardPath, cfg.RateCardSigPath = writeSignedFeedPair(t, dir, "rates", rateBody, "test-key", private)
	cfg.DemandRankPath, cfg.DemandRankSigPath = writeSignedFeedPair(t, dir, "demand", validDemandFeedWith("fixture-primary", generated, "autotune-policy-v1"), "test-key", private)
	feeds, err := buyer.LoadAutotuneFeeds(cfg)
	if err != nil {
		t.Fatal(err)
	}
	// Independent Tier2 signing key and catalog body, with exact session hash.
	referencePub, referencePrivate, _ := ed25519.GenerateKey(rand.Reader)
	reference := map[string]any{"catalog_id": "fixture-independent-tier2", "expires_at": now.Add(time.Hour).Format(time.RFC3339), "issued_at": generated, "version": 1, "models": []map[string]any{{"model_id": "mlx-community/Test-Model-4bit", "sha256": strings.Repeat("2", 64), "artifact_kind": "mlx_weight_file", "hash_scope": "primary_weight_file", "source": "operator-curated"}}}
	canonical, _ := json.Marshal(reference)
	reference["signature"] = map[string]any{"alg": "Ed25519", "key_id": "fixture-tier2", "sig": base64.RawURLEncoding.EncodeToString(ed25519.Sign(referencePrivate, canonical))}
	raw, _ := json.Marshal(reference)
	if err := tier2.Configure(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeRouteSnapshotCatalog(t, raw), CatalogPublicKey: base64.RawURLEncoding.EncodeToString(referencePub), RequireHashVerified: true}, zerolog.Nop()); err != nil {
		t.Fatal(err)
	}
	reqLog, _ := openBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatal(err)
	}
	setSettlementModeForTest(store, billing.RouteSnapshotModeEnforce)
	rate := config.RateCardEntry{PromptCreditsPerMtok: 700000, CompletionCreditsPerMtok: 1700000}
	rate.SetPromptCacheHitCreditsPerMtok(130000)
	rewards := config.RewardsConfig{ProviderShare: 0.83, GlobalMultiplier: 1.2, RateCard: map[string]config.RateCardEntry{"test-model": rate}}
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), rewards, now)
	if err != nil {
		t.Fatal(err)
	}
	catalog, err := autotune.ParseCatalog(candidates)
	if err != nil {
		t.Fatal(err)
	}
	rowIdentity, _ := catalog.RowIdentity("test-model")
	p := pool.Provider{ProviderID: "fixture-provider", AssignedID: "fixture-session", ModelID: "mlx-community/Test-Model-4bit", InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1,
		ModelHash: strings.Repeat("2", 64), ExpectedModelHash: strings.Repeat("2", 64), ModelHashAlgorithm: modelidentity.SnapshotManifestV1,
		CatalogAdmissionMode: "current", CatalogReleaseID: "fixture-primary", CatalogPolicyVersion: "autotune-policy-v1", CandidateCatalogSHA256: candidateSHA, CatalogSignerKeyID: "test-key", CandidateRowIdentity: rowIdentity, ReceiptPubkey: pub}
	event := providerws.ModelAdmissionEvent{ProviderID: p.ProviderID, CandidateID: "byom_" + strings.Repeat("a", 52), ServedModelRef: p.ModelID, CatalogModelKey: "test-model", RuntimeSource: "mlx_cache", DiscoveryDigestSHA256: strings.Repeat("8", 64), EvaluationDigestSHA256: strings.Repeat("9", 64), State: "network_admitted_unsettled"}
	registry := pool.NewRegistry(nil)
	if len(registryOut) > 0 {
		*registryOut[0] = registry
	}
	serverConn, providerConn := net.Pipe()
	t.Cleanup(func() { serverConn.Close(); providerConn.Close() })
	registry.Register(&p, serverConn)
	registry.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: now})
	p, _ = registry.Resolve(p.ProviderID, p.AssignedID)
	server := buyer.NewServer(registry, zerolog.Nop(), now, buyer.WithModelAdmissionTransport(func(id, session string) bool { _, err := registry.Conn(id, session); return err == nil }, func(string, string, string) error { return nil }), buyer.WithAutotuneFeeds(feeds), buyer.WithBilling(store, rewards), buyer.WithBillingSnapshotID(snapshotID))
	return server, p, event, feeds, rewards, store
}

func TestPrimaryArtifactAdmissionAuthorityMatrix(t *testing.T) {
	server, p, event, feeds, rewards, store := primaryAdmissionFixture(t)
	authority, err := server.ResolveModelAdmissionAuthority(context.Background(), p, event)
	if err != nil {
		t.Fatal(err)
	}
	if authority.ArtifactAdmissionEvidence == nil || authority.ArtifactAdmissionEvidence.CandidateCatalogSHA256 == authority.CatalogBodyDigest {
		t.Fatal("candidate/Tier2 authorities missing or conflated")
	}
	for name, mutate := range map[string]func(*pool.Provider, *providerws.ModelAdmissionEvent){
		"provider-model": func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { e.ServedModelRef = "invented" },
		"provider-key":   func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { e.CatalogModelKey = "invented" },
		"runtime":        func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { e.RuntimeSource = "ollama_loopback" },
		"legacy-record":  func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { e.RuntimeSource = "" },
		"hash":           func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { p.ModelHash = strings.Repeat("3", 64) },
		"algorithm": func(p *pool.Provider, e *providerws.ModelAdmissionEvent) {
			p.ModelHashAlgorithm = "macprovider.gguf-file.v1"
		},
		"session-release":     func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { p.CatalogReleaseID = "old-release" },
		"previous-session":    func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { p.CatalogAdmissionMode = "previous" },
		"receipt-key":         func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { p.ReceiptPubkey = nil },
		"receipt-key-pending": func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { p.PendingReceiptPubkey = p.ReceiptPubkey },
		"row-identity":        func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { p.CandidateRowIdentity = "other" },
		"not-ready":           func(p *pool.Provider, e *providerws.ModelAdmissionEvent) { p.State = pool.StateUnavailable },
	} {
		t.Run(name, func(t *testing.T) {
			changedP, changedE := p, event
			mutate(&changedP, &changedE)
			if _, err := server.ResolveModelAdmissionAuthority(context.Background(), changedP, changedE); err == nil {
				t.Fatal("invalid authority promoted")
			}
		})
	}
	for _, field := range []string{"prompt", "cache", "completion", "share", "multiplier", "default"} {
		t.Run("rate-"+field, func(t *testing.T) {
			changed := rewards
			changed.RateCard = map[string]config.RateCardEntry{"test-model": rewards.RateCard["test-model"]}
			rate := changed.RateCard["test-model"]
			switch field {
			case "prompt":
				rate.PromptCreditsPerMtok++
			case "cache":
				rate.SetPromptCacheHitCreditsPerMtok(999)
			case "completion":
				rate.CompletionCreditsPerMtok++
			case "share":
				changed.ProviderShare = 0.8
			case "multiplier":
				changed.GlobalMultiplier = 1
			case "default":
				delete(changed.RateCard, "test-model")
				changed.RateCard["default"] = rate
			}
			if field != "default" {
				changed.RateCard["test-model"] = rate
			}
			server.SetBillingConfig(changed, authority.ArtifactAdmissionEvidence.ConfigSnapshotID, 1)
			if _, err := server.ResolveModelAdmissionAuthority(context.Background(), p, event); err == nil {
				t.Fatal("incorrect rates accepted")
			}
		})
	}
	server.SetBillingConfig(rewards, authority.ArtifactAdmissionEvidence.ConfigSnapshotID, 1)
	changed := feeds
	changed.CatalogArtifactsVerification.KeyID = "another-trusted-key"
	server.SetAutotuneFeeds(changed)
	if _, err := server.ResolveModelAdmissionAuthority(context.Background(), p, event); err == nil {
		t.Fatal("cross signer accepted")
	}
	changed = feeds
	changed.CatalogArtifactsVerification.GeneratedAt = time.Now().Add(-15 * 24 * time.Hour)
	server.SetAutotuneFeeds(changed)
	if _, err := server.ResolveModelAdmissionAuthority(context.Background(), p, event); err == nil {
		t.Fatal("stale artifact accepted")
	}
	server.SetAutotuneFeeds(feeds)
	setSettlementModeForTest(store, billing.RouteSnapshotModeObserve)
	if _, err := server.ResolveModelAdmissionAuthority(context.Background(), p, event); err == nil {
		t.Fatal("observe settlement promoted")
	}
	setSettlementModeForTest(store, billing.RouteSnapshotModeEnforce)
	tier2.ResetForTest()
	if _, err := server.ResolveModelAdmissionAuthority(context.Background(), p, event); err == nil {
		t.Fatal("missing independent reference accepted")
	}
}

func TestPrimaryArtifactRouteRechecksAuthorityAndRevokesDrift(t *testing.T) {
	for _, scenario := range []string{"current", "probe-expired", "feed-changed", "effective-rate-changed"} {
		t.Run(scenario, func(t *testing.T) {
			server, p, event, feeds, rewards, _ := primaryAdmissionFixture(t)
			store := providerws.NewMemoryModelAdmissionStore()
			buyer.WithModelAdmissionStore(store)(server)
			event.RequestID = "offer-fixture"
			event.Nonce = "offer-fixture"
			event.PayloadDigestSHA256 = strings.Repeat("d", 64)
			submitted, _, err := store.AppendModelAdmissionOffer(context.Background(), event)
			if err != nil {
				t.Fatal(err)
			}
			authority, err := server.ResolveModelAdmissionAuthority(context.Background(), p, submitted)
			if err != nil {
				t.Fatal(err)
			}
			if scenario == "probe-expired" {
				buyer.WithModelAdmissionStore(expiredAdmissionRouteStore{ModelAdmissionStore: store})(server)
			}
			authority.ExpectedCurrentEventID = submitted.CoordinatorEventID
			authority.State = "catalog_priced"
			authority.RequestID = "priced-fixture"
			authority.Nonce = "priced-fixture"
			authority.PayloadDigestSHA256 = strings.Repeat("e", 64)
			priced, err := store.(interface {
				AppendGuardedModelAdmissionDecision(context.Context, providerws.ModelAdmissionEvent, providerws.ModelAdmissionCommitGuard) (providerws.ModelAdmissionEvent, error)
			}).AppendGuardedModelAdmissionDecision(context.Background(), authority, func() (func(), error) { return func() {}, nil })
			if err != nil {
				t.Fatal(err)
			}
			authority = priced
			authority.ExpectedCurrentEventID = priced.CoordinatorEventID
			authority.State = "settlement_capable"
			authority.RequestID = "settle-fixture"
			authority.Nonce = "settle-fixture"
			authority.PayloadDigestSHA256 = strings.Repeat("f", 64)
			if _, err := store.(interface {
				AppendGuardedModelAdmissionDecision(context.Context, providerws.ModelAdmissionEvent, providerws.ModelAdmissionCommitGuard) (providerws.ModelAdmissionEvent, error)
			}).AppendGuardedModelAdmissionDecision(context.Background(), authority, func() (func(), error) { return func() {}, nil }); err != nil {
				t.Fatal(err)
			}
			switch scenario {
			case "feed-changed":
				feeds.CatalogArtifactsVerification.KeyID = "changed"
				server.SetAutotuneFeeds(feeds)
			case "effective-rate-changed":
				rewards.ProviderShare = 0.8
				server.SetBillingConfig(rewards, authority.ArtifactAdmissionEvidence.ConfigSnapshotID, 1)
			}
			response := httptest.NewRecorder()
			server.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
			if response.Code != http.StatusOK {
				t.Fatalf("models %d %s", response.Code, response.Body.String())
			}
			var models struct {
				Data []map[string]any `json:"data"`
			}
			if err := json.Unmarshal(response.Body.Bytes(), &models); err != nil {
				t.Fatal(err)
			}
			latest, _, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, event.CandidateID)
			if err != nil {
				t.Fatal(err)
			}
			if scenario == "current" {
				if len(models.Data) == 0 || latest.State != "settlement_capable" {
					t.Fatalf("current exact served artifact not routable: %s %+v", response.Body.String(), latest)
				}
			} else {
				if len(models.Data) != 0 || latest.State != "revoked" {
					t.Fatalf("drift still routable: %s %+v", response.Body.String(), latest)
				}
			}
		})
	}
}

func TestPrimaryArtifactRejectsNewLiveExclusionAfterSelection(t *testing.T) {
	for _, gate := range []string{"stale", "sandboxed", "ceiling", "benchmark"} {
		t.Run(gate, func(t *testing.T) {
			var registry *pool.Registry
			server, selected, event, _, _, _ := primaryAdmissionFixture(t, &registry)
			if _, err := server.ResolveModelAdmissionAuthority(context.Background(), selected, event); err != nil {
				t.Fatal(err)
			}
			switch gate {
			case "stale":
				registry.SetAdmissionEvidenceStale(selected.ProviderID, selected.AssignedID, true)
			case "sandboxed":
				registry.SetAdmissionSandboxed(selected.ProviderID, selected.AssignedID, true)
			case "ceiling":
				registry.SetAdmissionCeilingExcluded(selected.ProviderID, selected.AssignedID, true)
			case "benchmark":
				registry.SetBenchmarkQuarantine(selected.ProviderID, selected.AssignedID, true)
			}
			if _, err := server.ResolveModelAdmissionAuthority(context.Background(), selected, event); err == nil {
				t.Fatal("stale selection bypassed live exclusion")
			}
		})
	}
}

// A deterministic historical expired-row read, without sleeping or changing a
// runtime clock. CAS revocation still reaches the real underlying store.
type expiredAdmissionRouteStore struct{ providerws.ModelAdmissionStore }

func (s expiredAdmissionRouteStore) LatestModelAdmissionRouteStatus(ctx context.Context, p, model, key string) (providerws.ModelAdmissionEvent, bool, error) {
	e, found, err := s.ModelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p, model, key)
	if e.ArtifactAdmissionEvidence != nil {
		copy := *e.ArtifactAdmissionEvidence
		copy.ProbeExpiresAtUnixMS = time.Now().Add(-time.Second).UnixMilli()
		e.ArtifactAdmissionEvidence = &copy
	}
	return e, found, err
}
