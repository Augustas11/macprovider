package buyer_test

import (
	"context"
	"crypto/ed25519"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// SPEC-042-R015/R016, SPEC-047-R011, SPEC-005-R015, SPEC-022-R013,
// SPEC-006-R018 (#1816): a pool route for a pool/<pool_id>/<slug> model id
// selects the member bound to that signed entry, prices the attempt from the
// entry, records a pool_manifest route snapshot, and discloses the model as
// pool-attested; every other route treats the id as unknown.

const (
	poolModelSnapshotHash = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
	poolModelGGUFHash     = "fedcbafedcbafedcbafedcbafedcbafedcbafedcbafedcbafedcbafedcbafedc"
	poolModelDigest       = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	poolModelVersion      = 5
)

type poolModelFixture struct {
	runtime    string // "" (native mlx_cache) or a loopback class
	delegated  bool   // the member is delegated and serves under R016
	attested   bool   // the delegated member's owner account is attested
	noBounds   bool   // no configured pricing bounds
	staleEvent bool   // the binding is for an older manifest version
	routeErr   error  // the durable pool_manifest verdict (nil = supported)
	// midFlight runs while the provider holds the dispatched request
	// (between routing and settlement, #1816 F2).
	midFlight func(*poolModelHarness)
}

type poolModelHarness struct {
	server    *buyer.Server
	dbPath    string
	poolID    string
	modelID   string
	entry     poolmanifest.PoolModelEntry
	event     providerws.ModelAdmissionEvent
	authority *poolModelAuthority
	// trustPools and routeable are the pool registry and the snapshot it
	// was loaded with, so a test can rotate the manifest mid-flight.
	trustPools *trustpool.Registry
	routeable  trustpool.RouteableSnapshot
}

// poolModelAuthority stands in for trustpool.Store (tested in its package):
// it supports every pool_operator_attested and native pool_manifest claim.
type poolModelAuthority struct {
	mu          sync.Mutex
	attested    []billing.PoolOperatorAttestationClaim
	manifest    []billing.PoolOperatorAttestationClaim
	attestedErr error
	routeErr    error
	fenceErr    error
}

func (a *poolModelAuthority) PoolRouteFenceHolds(context.Context, billing.PoolFenceQueryer, billing.PoolOperatorAttestationClaim) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.fenceErr
}

func (a *poolModelAuthority) VerifyPoolOperatorAttestation(_ context.Context, claim billing.PoolOperatorAttestationClaim) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.attested = append(a.attested, claim)
	return a.attestedErr
}

func (a *poolModelAuthority) VerifyPoolManifestRoute(_ context.Context, claim billing.PoolOperatorAttestationClaim) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.manifest = append(a.manifest, claim)
	return a.routeErr
}

func newPoolModelHarness(t *testing.T, fx poolModelFixture) *poolModelHarness {
	t.Helper()
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "spec1816-pool-model", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeRouteSnapshotCatalog(t, raw), CatalogPublicKey: pubkey, RequireHashVerified: true}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	_, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	h := &poolModelHarness{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if fx.midFlight != nil {
			fx.midFlight(h)
		}
		if meta := decodeSettlementMetadataHeader(r.Header.Get("X-MacProvider-Settlement-Metadata")); meta != nil {
			terminalTS := time.Now().UTC().UnixMilli()
			w.Header().Set("X-MacProvider-Receipt-Terminal-State-TS-Unix-MS", strconv.FormatInt(terminalTS, 10))
			w.Header().Set("X-MacProvider-Receipt", signedNormalDoneReceipt(t, key, meta, "ok", 1, 1, terminalTS))
		}
		writeProviderOK(w)
	}))
	t.Cleanup(upstream.Close)

	poolID := trustedPoolLayer2CandidateManifest(t).PoolID
	native := fx.runtime == ""
	entry := poolmanifest.PoolModelEntry{
		PoolModelID: "pool/" + poolID + "/creator-model", ArtifactHashAlgorithm: modelidentity.SnapshotManifestV1,
		ArtifactHash: poolModelSnapshotHash, AllowedRuntimeSources: []string{"mlx_cache"}, License: "Apache-2.0", PaidServingAttested: true,
		Pricing:         poolmanifest.PoolModelPricing{PromptRatePerMtok: 3000000, PromptCacheHitRatePerMtok: 300000, CompletionRatePerMtok: 7000000},
		DisclosureClass: poolmanifest.PoolModelDisclosureClass, MaxContextTokens: 32768,
	}
	if !native {
		entry.ArtifactHashAlgorithm, entry.ArtifactHash = modelidentity.GGUFFileV1, poolModelGGUFHash
		entry.AllowedRuntimeSources = []string{fx.runtime}
	}

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, key.Public().(ed25519.PublicKey))
	provider, _ := registry.Resolve("p1", "")

	store := providerws.NewMemoryModelAdmissionStore()
	candidate := "byom_" + strings.Repeat("p", 52)
	offer, _, err := store.AppendModelAdmissionOffer(context.Background(), providerws.ModelAdmissionEvent{
		ProviderID: "p1", CandidateID: candidate, ServedModelRef: "creator-model",
		DiscoveryDigestSHA256: strings.Repeat("b", 64), EvaluationDigestSHA256: strings.Repeat("c", 64),
		RequestedDisclosureClass: "network_admitted_unsettled", RequestID: "offer-pool-model", Nonce: "nonce-offer-pool-model",
		PayloadDigestSHA256: strings.Repeat("d", 64), SignatureDigestSHA256: strings.Repeat("e", 64), CreatedAt: time.Unix(1800000000, 0).UTC(),
		RuntimeSource: fx.runtime, OfferedArtifactHashes: map[string]string{entry.ArtifactHashAlgorithm: entry.ArtifactHash},
	})
	if err != nil {
		t.Fatalf("offer: %v", err)
	}
	account := externalRuntimeCreator
	if fx.delegated {
		account = "acct-member"
	}
	version := uint64(poolModelVersion)
	if fx.staleEvent {
		version = poolModelVersion - 1
	}
	bind := offer
	bind.State = "catalog_priced"
	bind.ReasonCode = providerws.ModelAdmissionReasonPoolManifestBound
	bind.RequestID, bind.Nonce = "pool-bind", "pool-bind-nonce"
	bind.PayloadDigestSHA256 = strings.Repeat("f", 64)
	bind.CreatedAt = time.Unix(1800000010, 0).UTC()
	bind.OfferedArtifactHashes = nil
	bind.ExpectedCatalogModelHash, bind.ExpectedCatalogModelHashAlgorithm = entry.ArtifactHash, entry.ArtifactHashAlgorithm
	bind.BindingScope = providerws.ModelAdmissionBindingScopePool
	bind.PoolID, bind.PoolModelID = poolID, entry.PoolModelID
	bind.PoolManifestVersion, bind.PoolManifestCoreDigest = version, poolModelDigest
	bind.PoolPromptRatePerMtok = int64(entry.Pricing.PromptRatePerMtok)
	bind.PoolPromptCacheHitRatePerMtok = int64(entry.Pricing.PromptCacheHitRatePerMtok)
	bind.PoolCompletionRatePerMtok = int64(entry.Pricing.CompletionRatePerMtok)
	bind.PoolDisclosureClass = entry.DisclosureClass
	bind.PoolMaxContextTokens = entry.MaxContextTokens
	bind.PoolProviderAccountID = account
	bind.Actor = providerws.PoolManifestActor(poolID, version, poolModelDigest)
	event, err := store.AppendModelAdmissionDecision(context.Background(), bind)
	if err != nil {
		t.Fatalf("pool bind: %v", err)
	}

	provider.ModelID = "creator-model"
	provider.RuntimeSource = fx.runtime
	provider.ModelHash, provider.ModelHashAlgorithm = entry.ArtifactHash, entry.ArtifactHashAlgorithm
	provider.ExpectedModelHash = ""
	provider.HashStatus = pool.HashStatusUncatalogued
	provider.AdmissionSandboxed = true
	provider.TrustedPoolV1 = true
	provider.ModelAdmissionCandidateID = event.CandidateID
	provider.ModelAdmissionCoordinatorEventID = event.CoordinatorEventID
	provider.ModelAdmissionServedModelRef = event.ServedModelRef
	provider.ModelAdmissionDiscoveryDigestSHA256 = event.DiscoveryDigestSHA256
	provider.ModelAdmissionEvaluationDigestSHA256 = event.EvaluationDigestSHA256
	provider.ModelAdmissionPoolID, provider.ModelAdmissionPoolModelID = poolID, entry.PoolModelID
	provider.ModelAdmissionValidatedReleaseGeneration = 1
	registry.Register(&provider, nil)

	reqLog, dbPath := openBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatal(err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeEnforce)
	authority := &poolModelAuthority{routeErr: fx.routeErr}
	billingStore.SetPoolOperatorAttestationAuthority(authority)
	rewards := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), rewards, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	trustPools := trustpool.NewRegistry()
	billingStore.SetSettlementPoolLabelSource(func(poolID string) (uint64, string, bool) {
		snap := trustPools.Snapshot(poolID)
		return snap.ManifestVersion, snap.ManifestCoreDigest, snap.Exists
	})
	routeable := trustpool.RouteableSnapshot{
		PoolID: poolID, CreatorAccountID: externalRuntimeCreator, Members: []string{"p1"},
		BuyerAccounts: []string{externalRuntimePoolAccount}, SettlementMode: billing.RouteSnapshotModeEnforce,
		ModelEntries: []poolmanifest.PoolModelEntry{entry}, Routeable: true, Generation: externalRuntimeGeneration,
		RouteableUntilUTC: time.Now().UTC().Add(time.Hour), ManifestVersion: poolModelVersion, ManifestCoreDigest: poolModelDigest,
		LaunchEnvironment: "candidate",
	}
	if !native {
		routeable.RuntimeAllowlist = []string{fx.runtime}
	}
	if fx.delegated {
		routeable.DelegatedMembers = []string{"p1"}
		trustPools.SetProviderOwnerAccounts(map[string][]string{"acct-member": {"p1"}})
		if fx.attested {
			routeable.AttestedMembers = []poolmanifest.AttestedMember{{ProviderAccountID: "acct-member", RuntimeClasses: []string{fx.runtime}}}
		}
	}
	loadTrustedPoolLayer2Snapshot(t, trustPools, 0, routeable)
	bounds := &poolmanifest.PoolModelPricingBounds{MaxPromptRatePerMtok: 1 << 40, MaxPromptCacheHitRatePerMtok: 1 << 40, MaxCompletionRatePerMtok: 1 << 40}
	if fx.noBounds {
		bounds = nil
	}
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0).UTC(),
		buyer.WithGatewayServiceToken("gateway-secret"),
		buyer.WithRequireGatewayContext(true),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithPoolMembership(trustPools),
		buyer.WithTrustPoolStatusStore(openBuyerTrustPoolStore(t)),
		buyer.WithRoutingConfig(config.RoutingConfig{MaxRetries: 0}),
		buyer.WithModelAdmissionStore(store),
		buyer.WithModelAdmissionRouteGuard(testRouteGuard{registry: registry, store: store}),
		buyer.WithPoolModelPricingBounds(func() *poolmanifest.PoolModelPricingBounds { return bounds }),
	)
	h.server, h.dbPath, h.poolID, h.modelID, h.entry, h.event, h.authority = server, dbPath, poolID, entry.PoolModelID, entry, event, authority
	h.trustPools, h.routeable = trustPools, routeable
	return h
}

func (h *poolModelHarness) body() []byte {
	return []byte(`{"model":"` + h.modelID + `","messages":[{"role":"user","content":"hi"}]}`)
}

type poolModelLedger struct {
	usageSource string
	gross       int64
	provider    int64
	quarantined int64
	reason      string
	promptRate  int64
	compRate    int64
}

func queryPoolModelLedger(t *testing.T, dbPath string) poolModelLedger {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var row poolModelLedger
	var reason sql.NullString
	if err := db.QueryRow(`SELECT sao.usage_source, lrc.gross_credits, lrc.provider_credits, lrc.quarantined, lrc.quarantine_reason,
       lrc.prompt_rate_per_mtok, lrc.completion_rate_per_mtok
  FROM settlement_attempt_outputs sao JOIN ledger_request_credits lrc
    ON lrc.request_id = sao.request_id AND lrc.attempt_n = sao.attempt_n AND lrc.provider_id = sao.provider_id`).
		Scan(&row.usageSource, &row.gross, &row.provider, &row.quarantined, &reason, &row.promptRate, &row.compRate); err != nil {
		t.Fatalf("query ledger: %v", err)
	}
	row.reason = reason.String
	return row
}

func TestSPEC1816PoolModelRoutesSettlesAndDiscloses(t *testing.T) {
	for name, fx := range map[string]poolModelFixture{
		"native mlx_cache entry":         {},
		"creator-owned llama.cpp entry":  {runtime: "llamacpp_loopback"},
		"R016-attested delegated member": {runtime: "llamacpp_loopback", delegated: true, attested: true},
	} {
		t.Run(name, func(t *testing.T) {
			h := newPoolModelHarness(t, fx)
			rec := postChat(t, h.server, h.body(), externalRuntimePoolHeaders(h.poolID))
			if rec.Code != http.StatusOK {
				t.Fatalf("pool-model route status=%d body=%s", rec.Code, rec.Body.String())
			}
			if rec.Header().Get("X-MacProvider-Model-Disclosure") != "pool_attested_unverified" ||
				rec.Header().Get("X-MacProvider-Pool-Manifest-Core-Digest") != poolModelDigest {
				t.Fatalf("disclosure headers = %v", rec.Header())
			}
			snapshot := queryRouteSnapshotBYOMBinding(t, h.dbPath)
			generation := float64(externalRuntimeGeneration)
			if fx.delegated {
				generation++ // installing the owner-account map advances the fence
			}
			for key, want := range map[string]any{
				"expected_model_hash_source":                billing.ExpectedModelHashSourcePoolManifest,
				"pool_model_id":                             h.modelID,
				"pool_id":                                   h.poolID,
				"manifest_version":                          float64(poolModelVersion),
				"manifest_core_digest":                      poolModelDigest,
				"expected_catalog_model_hash":               h.entry.ArtifactHash,
				"expected_catalog_model_hash_algorithm":     h.entry.ArtifactHashAlgorithm,
				"pool_model_prompt_rate_per_mtok":           float64(3000000),
				"pool_model_prompt_cache_hit_rate_per_mtok": float64(300000),
				"pool_model_completion_rate_per_mtok":       float64(7000000),
				"pool_generation":                           generation,
				"model_admission_coordinator_event_id":      h.event.CoordinatorEventID,
			} {
				if got := snapshot[key]; got != want {
					t.Fatalf("route snapshot %s=%v want %v", key, got, want)
				}
			}
			if key, _ := snapshot["model_admission_catalog_model_key"].(string); key != "" {
				t.Fatalf("pool snapshot laundered a catalog key: %q", key)
			}
			ledger := queryPoolModelLedger(t, h.dbPath)
			// 1 prompt token * 3e6 + 1 completion token * 7e6, per million = 10.
			if ledger.quarantined != 0 || ledger.gross != 10 || ledger.provider == 0 || ledger.promptRate != 3000000 || ledger.compRate != 7000000 {
				t.Fatalf("pool-model ledger = %+v", ledger)
			}
			wantSource := billing.UsageSourceCoordinatorObserved
			if fx.runtime != "" {
				wantSource = billing.UsageSourcePoolOperatorAttested
				claim := h.authority.attested[0]
				if claim.PoolModelID != h.modelID || claim.ExpectedModelHash != h.entry.ArtifactHash || claim.ExpectedModelHashSource != billing.ExpectedModelHashSourcePoolManifest {
					t.Fatalf("attestation claim = %+v", claim)
				}
				if fx.delegated && claim.PoolMemberAccountID != "acct-member" {
					t.Fatalf("R016 claim lacks the member account: %+v", claim)
				}
			} else if len(h.authority.manifest) == 0 || h.authority.manifest[0].PoolModelID != h.modelID {
				t.Fatalf("native pool_manifest claim = %+v", h.authority.manifest)
			}
			if ledger.usageSource != wantSource {
				t.Fatalf("usage source = %q want %q", ledger.usageSource, wantSource)
			}
		})
	}
}

// A pool/ id answers as an unknown model on a global route and on another
// pool's route, and the same pool-bound session never serves globally.
func TestSPEC1816PoolModelExcludedOutsideItsPool(t *testing.T) {
	h := newPoolModelHarness(t, poolModelFixture{})
	if rec := postChat(t, h.server, h.body(), globalRouteHeaders()); rec.Code != http.StatusNotFound {
		t.Fatalf("global pool-model request status=%d body=%s", rec.Code, rec.Body.String())
	}
	other := "pool/AAAAAAAAAAAAAAAAAAAAAA/creator-model"
	body := []byte(`{"model":"` + other + `","messages":[{"role":"user","content":"hi"}]}`)
	if rec := postChat(t, h.server, body, externalRuntimePoolHeaders(h.poolID)); rec.Code != http.StatusNotFound {
		t.Fatalf("other pool's model on this pool status=%d", rec.Code)
	}
	// The pool-bound session's own served name is not a paid global route.
	global := []byte(`{"model":"creator-model","messages":[{"role":"user","content":"hi"}]}`)
	if rec := postChat(t, h.server, global, globalRouteHeaders()); rec.Code == http.StatusOK {
		t.Fatalf("pool-bound session served a global request: %s", rec.Body.String())
	}
	if rows := queryRouteSnapshotBYOMBindings(t, h.dbPath); len(rows) != 0 {
		t.Fatalf("route snapshots recorded outside the pool: %v", rows)
	}
}

// Fail-closed: missing bounds, an unrebound binding, or an unattested
// delegated member selects no session and records nothing.
func TestSPEC1816PoolModelFailClosed(t *testing.T) {
	for name, fx := range map[string]poolModelFixture{
		"no pricing bounds":           {noBounds: true},
		"binding at an older version": {staleEvent: true},
		"delegated, no attestation":   {runtime: "llamacpp_loopback", delegated: true},
	} {
		t.Run(name, func(t *testing.T) {
			h := newPoolModelHarness(t, fx)
			if rec := postChat(t, h.server, h.body(), externalRuntimePoolHeaders(h.poolID)); rec.Code == http.StatusOK {
				t.Fatalf("pool-model route served: %s", rec.Body.String())
			}
			if rows := queryRouteSnapshotBYOMBindings(t, h.dbPath); len(rows) != 0 {
				t.Fatalf("route snapshot recorded: %v", rows)
			}
		})
	}
}

// SPEC-006-R018: the default /v1/models never lists a pool model; the
// authorized pool view lists the entry with the closed disclosure object.
func TestSPEC1816PoolModelListing(t *testing.T) {
	h := newPoolModelHarness(t, poolModelFixture{})
	get := func(headers http.Header) (int, map[string]any) {
		req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
		for k, values := range headers {
			for _, v := range values {
				req.Header.Add(k, v)
			}
		}
		rr := httptest.NewRecorder()
		h.server.Handler().ServeHTTP(rr, req)
		var body map[string]any
		_ = json.Unmarshal(rr.Body.Bytes(), &body)
		return rr.Code, body
	}
	_, global := get(nil)
	for _, m := range global["data"].([]any) {
		if strings.HasPrefix(m.(map[string]any)["id"].(string), "pool/") {
			t.Fatalf("default /v1/models lists a pool model: %v", m)
		}
	}
	code, view := get(trustedPoolLayer2Headers(externalRuntimePoolAccount, h.poolID))
	if code != http.StatusOK {
		t.Fatalf("pool view status=%d", code)
	}
	var found map[string]any
	for _, m := range view["data"].([]any) {
		if m.(map[string]any)["id"] == h.modelID {
			found = m.(map[string]any)["macprovider_pool_model"].(map[string]any)
		}
	}
	if found == nil || found["disclosure_class"] != "pool_attested_unverified" || found["disclosure_text"] != "Pool-attested, not network-verified" ||
		found["price_source"] != "pool_creator_signed" || found["artifact_hash"] != poolModelSnapshotHash || found["manifest_core_digest"] != poolModelDigest || len(found) != 12 {
		t.Fatalf("pool view entry = %v", found)
	}
	price := found["price"].(map[string]any)
	if price["prompt_rate_per_mtok"] != float64(3000000) || price["completion_rate_per_mtok"] != float64(7000000) || len(price) != 4 {
		t.Fatalf("pool view price = %v", price)
	}
	if code, _ := get(trustedPoolLayer2Headers("acct_unauthorized", h.poolID)); code == http.StatusOK {
		t.Fatalf("unauthorized pool view answered %d", code)
	}
}

// A native pool-model attempt whose durable pool_manifest re-verification
// fails is served but zero-billed and byte_estimated (no buyer-final debit,
// no provider credit).
func TestSPEC1816PoolModelUnverifiedRouteZeroBills(t *testing.T) {
	h := newPoolModelHarness(t, poolModelFixture{routeErr: fmt.Errorf("%w: entry removed", billing.ErrPoolOperatorAttestationRejected)})
	if rec := postChat(t, h.server, h.body(), externalRuntimePoolHeaders(h.poolID)); rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	ledger := queryPoolModelLedger(t, h.dbPath)
	if ledger.gross != 0 || ledger.provider != 0 || ledger.quarantined != 1 || ledger.reason != billing.PoolManifestRouteNotSettlementEligible ||
		ledger.usageSource != billing.UsageSourceByteEstimated {
		t.Fatalf("unverified pool-model ledger = %+v", ledger)
	}
}
