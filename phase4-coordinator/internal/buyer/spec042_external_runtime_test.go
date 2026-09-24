package buyer_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// SPEC-042-R004/R005/R013, SPEC-047-R003(iv) pool route-time clause,
// SPEC-032-R004, SPEC-022-R012.1, SPEC-015 §N.12 (#1690 M4): route-time
// selection of an external-runtime (loopback) member session on a Trusted
// Pool, and the fail-closed set around it.

const (
	externalRuntimePoolAccount = "acct_gateway"
	externalRuntimeCreator     = "creator-a"
	externalRuntimeGeneration  = 7
)

type externalRuntimeFixture struct {
	// runtime sources and allowlists
	helloSource      string
	offerSource      string
	allowedSources   string
	runtimeAllowlist []string
	// membership
	member    bool
	delegated bool
	// candidate binding
	recordMember bool
	// durable pool authority verdict (nil = supports the claim)
	authorityErr error
}

func defaultExternalRuntimeFixture() externalRuntimeFixture {
	return externalRuntimeFixture{
		helloSource:      "llamacpp_loopback",
		offerSource:      "llamacpp_loopback",
		allowedSources:   "llamacpp_loopback,ollama_loopback",
		runtimeAllowlist: []string{"llamacpp_loopback"},
		member:           true,
		recordMember:     true,
	}
}

type externalRuntimeHarness struct {
	server    *buyer.Server
	dbPath    string
	poolID    string
	registry  *pool.Registry
	event     providerws.ModelAdmissionEvent
	binding   *artifactidentity.Binding
	mu        sync.Mutex
	metadata  []string
	authority *externalRuntimeAuthority
}

// externalRuntimeAuthority stands in for the trust-pool durable records
// (trustpool.Store.VerifyPoolOperatorAttestation, tested in its package).
type externalRuntimeAuthority struct {
	mu    sync.Mutex
	err   error
	calls []billing.PoolOperatorAttestationClaim
}

func (a *externalRuntimeAuthority) VerifyPoolOperatorAttestation(_ context.Context, claim billing.PoolOperatorAttestationClaim) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.calls = append(a.calls, claim)
	return a.err
}

type externalRuntimeLedgerRow struct {
	usageSource string
	gross       int64
	provider    int64
	quarantined int64
	reason      string
}

func externalRuntimeLedger(t *testing.T, dbPath string) externalRuntimeLedgerRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var row externalRuntimeLedgerRow
	var reason sql.NullString
	if err := db.QueryRow(`SELECT sao.usage_source, lrc.gross_credits, lrc.provider_credits, lrc.quarantined, lrc.quarantine_reason
  FROM settlement_attempt_outputs sao JOIN ledger_request_credits lrc
    ON lrc.request_id = sao.request_id AND lrc.attempt_n = sao.attempt_n AND lrc.provider_id = sao.provider_id`).
		Scan(&row.usageSource, &row.gross, &row.provider, &row.quarantined, &reason); err != nil {
		t.Fatalf("query attempt ledger: %v", err)
	}
	row.reason = reason.String
	return row
}

func (h *externalRuntimeHarness) settlementMetadata() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.metadata...)
}

func newExternalRuntimeHarness(t *testing.T, fx externalRuntimeFixture) *externalRuntimeHarness {
	t.Helper()
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "spec042-external-runtime", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeRouteSnapshotCatalog(t, raw), CatalogPublicKey: pubkey, RequireHashVerified: true}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	h := &externalRuntimeHarness{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.mu.Lock()
		h.metadata = append(h.metadata, r.Header.Get("X-MacProvider-Settlement-Metadata"))
		h.mu.Unlock()
		writeProviderOK(w)
	}))
	t.Cleanup(upstream.Close)

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x79}, 32))
	provider := byomAdmissionProvider(t, registry.Snapshot()[0])
	binding := ggufArtifactBinding()
	binding.Member.AllowedRuntimeSources = fx.allowedSources
	store := providerws.NewMemoryModelAdmissionStore()

	// Offer, then a catalog_priced decision whose signed runtime_source is
	// the coordinator-recorded runtime class and whose member set records
	// the GGUF feed member. No candidate ever reaches settlement_capable.
	rowProvider := provider
	rowProvider.ModelHash = buyerTestHash
	rowProvider.ModelHashAlgorithm = modelidentity.SnapshotManifestV1
	rowProvider.ModelAdmissionCatalogModelKey = binding.Member.ModelKey
	offer := seedBYOMAdmissionState(t, store, rowProvider, "offer_submitted")
	material, ok := tier2.SnapshotMaterial(provider.ModelID, buyerTestHash)
	if !ok {
		t.Fatal("missing trusted catalog material")
	}
	decision := offer
	decision.State = "catalog_priced"
	decision.RuntimeSource = fx.offerSource
	decision.RequestID = "decision-catalog-priced-external-runtime"
	decision.Nonce = "nonce-catalog-priced-external-runtime"
	decision.PayloadDigestSHA256 = strings.Repeat("f", 64)
	decision.CreatedAt = time.Unix(1800000010, 0).UTC()
	decision.CatalogID = material.CatalogID
	decision.CatalogBodyDigest = material.CatalogBodyDigest
	decision.CatalogSignatureKeyID = material.CatalogSignatureKeyID
	decision.CatalogSignaturePubkeyFingerprint = material.CatalogSignaturePubkeyFingerprint
	decision.ExpectedCatalogModelHash = buyerTestHash
	decision.ExpectedCatalogModelHashAlgorithm = modelidentity.SnapshotManifestV1
	decision.CatalogMembers = []providerws.ModelAdmissionCatalogMember{{
		Source: "candidate_row", HashAlgorithm: modelidentity.SnapshotManifestV1, Hash: buyerTestHash,
	}}
	if fx.recordMember {
		decision.CatalogMembers = append(decision.CatalogMembers, providerws.ModelAdmissionCatalogMember{
			Source:                         "artifact_feed",
			HashAlgorithm:                  binding.Member.HashAlgorithm,
			Hash:                           binding.Member.Hash,
			ArtifactID:                     binding.Member.ArtifactID,
			ArtifactFeedSHA256:             binding.Provenance.FeedSHA256,
			ArtifactFeedSignerKeyID:        binding.Provenance.SignerKeyID,
			ArtifactCandidateCatalogSHA256: binding.Provenance.CandidateCatalogSHA256,
		})
	}
	event, err := store.AppendModelAdmissionDecision(context.Background(), decision)
	if err != nil {
		t.Fatalf("AppendModelAdmissionDecision(catalog_priced): %v", err)
	}

	routeProvider := bindBYOMSession(clearBYOMAdmissionFields(provider), event)
	routeProvider.ModelHash = binding.Member.Hash
	routeProvider.ModelHashAlgorithm = binding.Member.HashAlgorithm
	routeProvider.ExpectedModelHash = buyerTestHash
	routeProvider.HashStatus = pool.HashStatusVerified
	routeProvider.ArtifactIdentity = binding
	routeProvider.IdentityPin = &pool.IdentityPin{Member: binding.Member}
	routeProvider.RuntimeSource = fx.helloSource
	routeProvider.TrustedPoolV1 = true
	routeProvider.AdmissionSandboxed = true // SPEC-032 FR-HG8: the hello sandbox stays set.
	registry.Register(&routeProvider, nil)

	reqLog, dbPath := openBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeEnforce)
	h.authority = &externalRuntimeAuthority{err: fx.authorityErr}
	billingStore.SetPoolOperatorAttestationAuthority(h.authority)
	rewards := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), rewards, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}
	poolID := trustedPoolLayer2CandidateManifest(t).PoolID
	members := []string{}
	if fx.member {
		members = append(members, "p1")
	}
	var delegated []string
	if fx.delegated {
		delegated = []string{"p1"}
	}
	trustPools := trustpool.NewRegistry()
	loadTrustedPoolLayer2Snapshot(t, trustPools, 1, trustpool.RouteableSnapshot{
		PoolID:             poolID,
		CreatorAccountID:   externalRuntimeCreator,
		Members:            members,
		DelegatedMembers:   delegated,
		BuyerAccounts:      []string{externalRuntimePoolAccount},
		SettlementMode:     billing.RouteSnapshotModeEnforce,
		RuntimeAllowlist:   fx.runtimeAllowlist,
		Routeable:          true,
		Generation:         externalRuntimeGeneration,
		RouteableUntilUTC:  time.Now().UTC().Add(time.Hour),
		ManifestVersion:    5,
		ManifestCoreDigest: strings.Repeat("d", 64),
		LaunchEnvironment:  "candidate",
	})
	h.server = buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0).UTC(),
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
	)
	h.dbPath = dbPath
	h.poolID = poolID
	h.registry = registry
	h.event = event
	h.binding = binding
	return h
}

var externalRuntimeBody = []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`)

func globalRouteHeaders() http.Header {
	return http.Header{
		"Authorization":         {"Bearer gateway-secret"},
		"X-MacProvider-Account": {externalRuntimePoolAccount},
	}
}

// Acceptance (SPEC-047-R003(iv) pool route-time member derivation): a
// catalog_priced llama-server GGUF session on its pool route produces a route
// snapshot with the derived member, all six values, and the R012 members, and
// the provider receives the §N.12 authorization bound to that attempt.
func TestSPEC042ExternalRuntimePoolRouteDerivesMemberAndSnapshot(t *testing.T) {
	h := newExternalRuntimeHarness(t, defaultExternalRuntimeFixture())
	rec := postChat(t, h.server, externalRuntimeBody, trustedPoolLayer2Headers(externalRuntimePoolAccount, h.poolID))
	if rec.Code != http.StatusOK {
		t.Fatalf("pool route status=%d body=%s", rec.Code, rec.Body.String())
	}
	snapshot := queryRouteSnapshotBYOMBinding(t, h.dbPath)
	want := map[string]any{
		"pool_id":                                h.poolID,
		"runtime_source":                         "llamacpp_loopback",
		"pool_generation":                        float64(externalRuntimeGeneration),
		"pool_operator_account_id":               externalRuntimeCreator,
		"manifest_version":                       float64(5),
		"manifest_core_digest":                   strings.Repeat("d", 64),
		"model_admission_coordinator_event_id":   h.event.CoordinatorEventID,
		"provider_reported_model_hash":           h.binding.Member.Hash,
		"expected_catalog_model_hash":            h.binding.Member.Hash,
		"expected_catalog_model_hash_algorithm":  modelidentity.GGUFFileV1,
		"provider_reported_model_hash_algorithm": modelidentity.GGUFFileV1,
		"artifact_feed_sha256":                   h.binding.Provenance.FeedSHA256,
		"artifact_id":                            "gguf-q4",
		"artifact_hash":                          h.binding.Member.Hash,
		"artifact_hash_algorithm":                modelidentity.GGUFFileV1,
		"artifact_feed_signer_key_id":            h.binding.Provenance.SignerKeyID,
		"artifact_candidate_catalog_sha256":      h.binding.Provenance.CandidateCatalogSHA256,
		"route_snapshot_mode":                    billing.RouteSnapshotModeEnforce,
	}
	for key, value := range want {
		if got := snapshot[key]; got != value {
			t.Fatalf("route snapshot %s=%v (%T) want %v", key, got, got, value)
		}
	}
	// SPEC-015 §N.12: the authorization equals the snapshot's digested values
	// and binds this request attempt, provider, and route snapshot digest.
	metas := h.settlementMetadata()
	if len(metas) != 1 || metas[0] == "" {
		t.Fatalf("settlement metadata headers=%v", metas)
	}
	raw, err := base64.RawURLEncoding.DecodeString(metas[0])
	if err != nil {
		t.Fatalf("decode settlement metadata: %v", err)
	}
	var meta providerws.SettlementReceiptMetadata
	if err := json.Unmarshal(raw, &meta); err != nil {
		t.Fatalf("unmarshal settlement metadata: %v", err)
	}
	auth := meta.PoolRuntimeAuthorization
	if auth == nil || auth.PoolID != h.poolID || auth.ManifestCoreDigest != strings.Repeat("d", 64) ||
		auth.RuntimeSource != "llamacpp_loopback" || auth.RequestID != meta.RequestID || auth.AttemptN != meta.AttemptN ||
		auth.ProviderID != meta.ProviderID || auth.RouteSnapshotDigest != meta.RouteSnapshotDigest || auth.RouteSnapshotDigest == "" {
		t.Fatalf("pool_runtime_authorization=%+v meta=%+v", auth, meta)
	}
	// SPEC-042-R005 site (5) / SPEC-022-R012: the attempt is recorded
	// pool_operator_attested from the digested snapshot values and carries
	// ledger credit; it becomes payable only through a verified receipt.
	ledger := externalRuntimeLedger(t, h.dbPath)
	if ledger.usageSource != billing.UsageSourcePoolOperatorAttested || ledger.quarantined != 0 || ledger.gross == 0 || ledger.provider == 0 {
		t.Fatalf("attested attempt ledger=%+v", ledger)
	}
	if len(h.authority.calls) == 0 || h.authority.calls[0].PoolGeneration != externalRuntimeGeneration ||
		h.authority.calls[0].PoolOperatorAccountID != externalRuntimeCreator || h.authority.calls[0].RuntimeSource != "llamacpp_loopback" {
		t.Fatalf("durable authority claims=%+v", h.authority.calls)
	}
	// SPEC-032-R004: selection does not clear the sandbox flag.
	if p, ok := h.registry.Resolve("p1", ""); !ok || !p.AdmissionSandboxed {
		t.Fatalf("pool selection cleared admission_sandboxed: %+v", p)
	}
}

// SPEC-042-R013 fail-closed set, route-time half: each case gets no pool
// selection, so no route snapshot, no provider call, and nothing billable.
func TestSPEC042ExternalRuntimeFailClosedSet(t *testing.T) {
	cases := map[string]struct {
		mutate func(*externalRuntimeFixture)
		global bool
	}{
		"pool-admitted loopback member on a global route": {global: true},
		"non-member loopback session":                     {mutate: func(fx *externalRuntimeFixture) { fx.member = false }},
		"runtime not in the allowlist": {mutate: func(fx *externalRuntimeFixture) {
			fx.runtimeAllowlist = []string{"ollama_loopback"}
		}},
		"v1 core or empty allowlist":           {mutate: func(fx *externalRuntimeFixture) { fx.runtimeAllowlist = nil }},
		"member not owned by the pool creator": {mutate: func(fx *externalRuntimeFixture) { fx.delegated = true }},
		"spoofed hello differs from the derived class": {mutate: func(fx *externalRuntimeFixture) {
			fx.helloSource = "ollama_loopback"
			fx.runtimeAllowlist = []string{"llamacpp_loopback", "ollama_loopback"}
		}},
		"native-claiming hello on a GGUF member": {mutate: func(fx *externalRuntimeFixture) { fx.helloSource = "mlx_cache" }},
		"allowlisted hello whose candidate binding fails (pin names no recorded member)": {mutate: func(fx *externalRuntimeFixture) {
			fx.recordMember = false
		}},
		"member does not allow the recorded runtime": {mutate: func(fx *externalRuntimeFixture) {
			fx.allowedSources = "ollama_loopback"
		}},
	}
	for name, tc := range cases {
		tc := tc
		t.Run(name, func(t *testing.T) {
			fx := defaultExternalRuntimeFixture()
			if tc.mutate != nil {
				tc.mutate(&fx)
			}
			h := newExternalRuntimeHarness(t, fx)
			headers := trustedPoolLayer2Headers(externalRuntimePoolAccount, h.poolID)
			if tc.global {
				headers = globalRouteHeaders()
			}
			rec := postChat(t, h.server, externalRuntimeBody, headers)
			if rec.Code == http.StatusOK {
				t.Fatalf("external runtime selected: status=%d body=%s", rec.Code, rec.Body.String())
			}
			if rows := queryRouteSnapshotBYOMBindings(t, h.dbPath); len(rows) != 0 {
				t.Fatalf("route snapshot written: %#v", rows)
			}
			if got := len(h.settlementMetadata()); got != 0 {
				t.Fatalf("provider called %d times", got)
			}
			if got := ledgerCreditCount(t, h.dbPath); got != 0 {
				t.Fatalf("ledger credits=%d want 0", got)
			}
		})
	}
}

// SPEC-022-R012.3 at recording: when the durable pool records do not support
// the claim (non-member at the generation, non-creator, no v2 allowlist), the
// selected attempt is recorded byte_estimated with zero billable usage and a
// zero, quarantined ledger row.
func TestSPEC042ExternalRuntimeRecordedByteEstimatedWhenDurableRecordsReject(t *testing.T) {
	fx := defaultExternalRuntimeFixture()
	fx.authorityErr = errors.New("durable records reject")
	h := newExternalRuntimeHarness(t, fx)
	rec := postChat(t, h.server, externalRuntimeBody, trustedPoolLayer2Headers(externalRuntimePoolAccount, h.poolID))
	if rec.Code != http.StatusOK {
		t.Fatalf("pool route status=%d body=%s", rec.Code, rec.Body.String())
	}
	ledger := externalRuntimeLedger(t, h.dbPath)
	if ledger.usageSource != billing.UsageSourceByteEstimated || ledger.gross != 0 || ledger.provider != 0 ||
		ledger.quarantined != 1 || ledger.reason != billing.LoopbackRuntimeNotSettlementEligible {
		t.Fatalf("rejected attempt ledger=%+v", ledger)
	}
}
