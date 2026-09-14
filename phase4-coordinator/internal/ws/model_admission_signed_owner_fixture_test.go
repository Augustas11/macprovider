package ws_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Local signed fixtures mirrored from buyer admission tests; all keys are ephemeral.
func ownerPrimaryAdmissionFixture(t *testing.T, registryOut ...**pool.Registry) (*buyer.Server, pool.Provider, providerws.ModelAdmissionEvent, buyer.AutotuneFeeds, config.RewardsConfig, *billing.Store, config.Tier2Config) {
	t.Helper()
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	now := time.Now().UTC()
	generated := now.Add(-time.Hour).Format(time.RFC3339)
	pub, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	candidates := []byte(strings.Replace(string(ownerValidCandidateFeed("fixture-primary")), "2026-07-10T00:00:00Z", generated, 1))
	digest := sha256.Sum256(candidates)
	candidateSHA := hex.EncodeToString(digest[:])
	artifacts := ownerValidCatalogArtifactsFeed("fixture-primary", generated, "autotune-policy-v1", candidateSHA)
	rateRow := map[string]any{"prompt_rate_per_mtok": 700000, "prompt_cache_hit_rate_per_mtok": 130000, "completion_rate_per_mtok": 1700000, "provider_share_bps": 8300, "global_multiplier_ppm": 1200000}
	rows := map[string]any{"default": rateRow, "test-model": rateRow}
	projection, _ := json.Marshal(map[string]any{"global_multiplier_ppm": 1200000, "provider_share_bps": 8300, "rows": rows, "usd_per_million_credits": 1})
	rateDigest := sha256.Sum256(projection)
	rateBody, _ := json.Marshal(map[string]any{"version": hex.EncodeToString(rateDigest[:]), "generated_at": generated, "policy_version": "autotune-policy-v1", "usd_per_million_credits": 1, "rows": rows})
	dir := t.TempDir()
	cfg := config.AutotuneFeedsConfig{PublicKeys: map[string]string{"test-key": base64.StdEncoding.EncodeToString(pub)}}
	cfg.AutotuneCandidatesPath, cfg.AutotuneCandidatesSigPath = ownerWriteSignedFeedPair(t, dir, "candidates", candidates, "test-key", private)
	cfg.CatalogArtifactsPath, cfg.CatalogArtifactsSigPath = ownerWriteSignedFeedPair(t, dir, "artifacts", artifacts, "test-key", private)
	cfg.RateCardPath, cfg.RateCardSigPath = ownerWriteSignedFeedPair(t, dir, "rates", rateBody, "test-key", private)
	cfg.DemandRankPath, cfg.DemandRankSigPath = ownerWriteSignedFeedPair(t, dir, "demand", ownerValidDemandFeedWith("fixture-primary", generated, "autotune-policy-v1"), "test-key", private)
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
	referenceConfig := config.Tier2Config{ObserveEnabled: true, CatalogPath: ownerWriteRouteSnapshotCatalog(t, raw), CatalogPublicKey: base64.RawURLEncoding.EncodeToString(referencePub), RequireHashVerified: true}
	if err := tier2.Configure(referenceConfig, zerolog.Nop()); err != nil {
		t.Fatal(err)
	}
	reqLog, _ := ownerOpenBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatal(err)
	}
	ownerSetSettlementModeForTest(store, billing.RouteSnapshotModeEnforce)
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
	p := pool.Provider{ProviderID: "fixture-provider", AssignedID: "fixture-session", ModelID: "mlx-community/Test-Model-4bit", InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, MaxContextTokens: 100000,
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
	return server, p, event, feeds, rewards, store, referenceConfig
}
func ownerValidCandidateFeed(version string) []byte {
	return []byte(fmt.Sprintf(
		`{"version":%q,"policy_version":"autotune-policy-v1","generated_at":"2026-07-10T00:00:00Z","source":"operator_curated_autotune_candidate_catalog","rows":{"test-model":{"model_id":"mlx-community/Test-Model-4bit","model_revision":"%s","model_sha256":"%s","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000,"provenance":{"source":"legacy_unverified","notes":"test fixture"}},"runtime_status":"recommendable","notes":"fixture"}}}`,
		version,
		strings.Repeat("1", 40),
		strings.Repeat("2", 64),
	))
}
func ownerValidDemandFeedWith(version, generatedAt, policyVersion string) []byte {
	return []byte(fmt.Sprintf(
		`{"version":%q,"policy_version":%q,"generated_at":%q,"source":"openrouter_completion_token_rank_operator_curated","cold_start_floor":0.15,"diversification_band":0.85,"rows":{"test-model":{"demand_weight":0.5,"rank":1,"recommendable":true,"min_provider_target":1}}}`,
		version,
		policyVersion,
		generatedAt,
	))
}
func ownerWriteSignedFeedPair(
	t *testing.T,
	dir, name string,
	raw []byte,
	keyID string,
	privateKey ed25519.PrivateKey,
) (string, string) {
	t.Helper()
	jsonPath := filepath.Join(dir, name+".json")
	sigPath := jsonPath + ".sig"
	sidecar, err := json.Marshal(map[string]string{
		"key_id":    keyID,
		"alg":       "ed25519",
		"signature": base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, raw)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(jsonPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sigPath, sidecar, 0o600); err != nil {
		t.Fatal(err)
	}
	return jsonPath, sigPath
}
func ownerArtifactModelJSON(extraArtifacts string) string {
	return fmt.Sprintf(
		`{"artifacts":{"mlx-4bit":{"allowed_runtime_sources":["mlx_cache"],"hash":%q,"hash_algorithm":"macprovider.snapshot-manifest.v1","min_ram_gb":4,"quantization":"4bit","runtime_format":"mlx_safetensors","size_bytes":123456,"source_ref":{"kind":"huggingface_revision","repo_id":"mlx-community/Test-Model-4bit","revision":%q},"verification_status":"verified","verified_at":"2026-09-01"}%s},"primary_artifact_id":"mlx-4bit","rate_class":"class-8b"}`,
		strings.Repeat("2", 64), strings.Repeat("1", 40), extraArtifacts,
	)
}
func ownerCatalogArtifactsFeedWithModels(version, generatedAt, policyVersion, candidateSHA256, models string) []byte {
	return []byte(fmt.Sprintf(
		`{"candidate_catalog_sha256":%q,"generated_at":%q,"models":{%s},"policy_version":%q,"release_id":%q,"source":"operator_curated_autotune_artifact_catalog","version":%q}`,
		candidateSHA256, generatedAt, models, policyVersion, version, version,
	))
}
func ownerValidCatalogArtifactsFeed(version, generatedAt, policyVersion, candidateSHA256 string) []byte {
	return ownerCatalogArtifactsFeedWithModels(version, generatedAt, policyVersion, candidateSHA256, `"test-model":`+ownerArtifactModelJSON(""))
}
func ownerSetSettlementModeForTest(store *billing.Store, mode string) {
	cfg := config.Default().Settlement
	cfg.VerifiedModelSettlementMode = mode
	store.SetSettlementConfig(cfg)
}
func ownerWriteRouteSnapshotCatalog(t *testing.T, raw []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "catalog.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	return path
}
func ownerOpenBuyerRequestLog(t *testing.T) (*requestlog.Store, string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open request log: %v", err)
	}
	return store, dbPath
}

func ownerReplacementFeeds(t *testing.T, original buyer.AutotuneFeeds) buyer.AutotuneFeeds {
	t.Helper()
	pub, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	replace := func(raw []byte) []byte {
		return []byte(strings.ReplaceAll(string(raw), "fixture-primary", "replacement-primary"))
	}
	candidates := replace(original.AutotuneCandidatesJSON)
	digest := sha256.Sum256(candidates)
	var artifacts map[string]any
	if err := json.Unmarshal(replace(original.CatalogArtifactsJSON), &artifacts); err != nil {
		t.Fatal(err)
	}
	artifacts["candidate_catalog_sha256"] = hex.EncodeToString(digest[:])
	artifactJSON, _ := json.Marshal(artifacts)
	cfg := config.AutotuneFeedsConfig{PublicKeys: map[string]string{"test-key": base64.StdEncoding.EncodeToString(pub)}}
	dir := t.TempDir()
	cfg.AutotuneCandidatesPath, cfg.AutotuneCandidatesSigPath = ownerWriteSignedFeedPair(t, dir, "candidates", candidates, "test-key", private)
	cfg.CatalogArtifactsPath, cfg.CatalogArtifactsSigPath = ownerWriteSignedFeedPair(t, dir, "artifacts", artifactJSON, "test-key", private)
	cfg.DemandRankPath, cfg.DemandRankSigPath = ownerWriteSignedFeedPair(t, dir, "demand", replace(original.DemandRankJSON), "test-key", private)
	cfg.RateCardPath, cfg.RateCardSigPath = ownerWriteSignedFeedPair(t, dir, "rates", original.RateCardJSON, "test-key", private)
	result, err := buyer.LoadAutotuneFeeds(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return result
}
