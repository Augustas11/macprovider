package buyer_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

const warmEntryOtherHash = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

type servedModelCapture struct {
	mu   sync.Mutex
	seen []servedModelHit
}

type servedModelHit struct {
	header    string
	hasHeader bool
	bodyModel string
}

func (c *servedModelCapture) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model  string `json:"model"`
			Stream bool   `json:"stream"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		values, has := r.Header[http.CanonicalHeaderKey("X-MacProvider-Served-Model")]
		hit := servedModelHit{hasHeader: has, bodyModel: body.Model}
		if has {
			hit.header = strings.Join(values, ",")
		}
		c.mu.Lock()
		c.seen = append(c.seen, hit)
		c.mu.Unlock()
		if body.Stream {
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`))
	}
}

func (c *servedModelCapture) last(t *testing.T) servedModelHit {
	t.Helper()
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.seen) == 0 {
		t.Fatal("upstream saw no dispatch")
	}
	return c.seen[len(c.seen)-1]
}

func registerWarmHTTPProvider(registry *pool.Registry, providerID, endpointURL string, primary, member pool.WarmModel, primaryHash string, receiptPubkey []byte) {
	now := time.Now().UTC()
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            providerID + "-session",
		Hostname:              providerID + ".local",
		ModelID:               primary.ModelID,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        primary.SlotsTotal,
		SlotsFree:             primary.SlotsFree,
		SlotsTotal:            primary.SlotsTotal,
		ThroughputTPSEstimate: primary.ThroughputTPSEstimate,
		EndpointURL:           endpointURL,
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		LastHeartbeatAt:       now,
		ConnectedAt:           now,
		BinaryVersion:         "0.1.0",
		ModelHash:             primaryHash,
		ModelHashAlgorithm:    modelidentity.SnapshotManifestV1,
		ExpectedModelHash:     primaryHash,
		HashStatus:            pool.HashStatusVerified,
		ReceiptPubkey:         append([]byte(nil), receiptPubkey...),
		SupportedModels:       []string{primary.ModelID, member.ModelID},
		WarmModels:            []pool.WarmModel{primary, member},
	}, nil)
	slotsFree := primary.SlotsFree
	registry.ApplyStateUpdate(providerID, providerID+"-session", pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: now})
}

func warmMember(model string, primary bool, slots int) pool.WarmModel {
	return pool.WarmModel{ModelID: model, State: pool.WarmModelWarm, Primary: primary, Pinned: primary, SlotsTotal: slots, SlotsFree: slots, MaxContextTokens: 20000, ThroughputTPSEstimate: 20}
}

// SPEC-002-R011 / SPEC-001-R016: an HTTP-forwarded dispatch to a warm-set
// entry names it in X-MacProvider-Served-Model and sends that member's model
// in the body; a provider without a warm set gets no header at all.
func TestWarmEntryHTTPDispatchNamesServedModel(t *testing.T) {
	legacyUp := &servedModelCapture{}
	legacy := httptest.NewServer(legacyUp.handler())
	defer legacy.Close()
	warmUp := &servedModelCapture{}
	warm := httptest.NewServer(warmUp.handler())
	defer warm.Close()

	registry := pool.NewRegistry(nil)
	registerWithEndpoint(registry, "legacy", "legacy-session", "model-a", pool.StateReady, 20000, 1, legacy.URL, 20)
	registerWarmHTTPProvider(registry, "warm", warm.URL, warmMember("model-c", true, 1), warmMember("model-b", false, 1), buyerTestHash, nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithGatewayServiceToken("operator-key"))

	for _, tc := range []struct {
		model, provider, header string
		up                      *servedModelCapture
		stream                  bool
	}{
		{model: "model-a", provider: "legacy", up: legacyUp},
		{model: "model-a", provider: "legacy", up: legacyUp, stream: true},
		{model: "model-b", provider: "warm", header: "model-b", up: warmUp},
		{model: "model-b", provider: "warm", header: "model-b", up: warmUp, stream: true},
		{model: "model-c", provider: "warm", header: "model-c", up: warmUp},
	} {
		body := `{"model":"` + tc.model + `","messages":[{"role":"user","content":"hi"}]`
		if tc.stream {
			body += `,"stream":true`
		}
		rr := postChat(t, server, []byte(body+"}"), http.Header{})
		if rr.Code != http.StatusOK {
			t.Fatalf("%s stream=%v: status=%d body=%s", tc.model, tc.stream, rr.Code, rr.Body.String())
		}
		if got := rr.Header().Get("X-MacProvider-Provider"); got != tc.provider {
			t.Fatalf("%s stream=%v: routed to %q, want %q", tc.model, tc.stream, got, tc.provider)
		}
		hit := tc.up.last(t)
		if hit.bodyModel != tc.model {
			t.Fatalf("%s stream=%v: body model %q", tc.model, tc.stream, hit.bodyModel)
		}
		if tc.header == "" && hit.hasHeader {
			t.Fatalf("%s stream=%v: legacy provider got X-MacProvider-Served-Model %q", tc.model, tc.stream, hit.header)
		}
		if tc.header != "" && hit.header != tc.header {
			t.Fatalf("%s stream=%v: served model header %q, want %q", tc.model, tc.stream, hit.header, tc.header)
		}
	}
	for _, model := range []string{"model-b", "model-c"} {
		entry, ok := registry.ResolveEntry("warm", "warm-session", model)
		if !ok || entry.SlotsFree != 1 || registry.ForwardedInFlightFor("warm", "warm-session", model) != 0 {
			t.Fatalf("%s seats after completion: slots_free=%d ok=%v", model, entry.SlotsFree, ok)
		}
	}
}

// SPEC-002-R011 Settlement: the route snapshot of a dispatch to a further
// member carries that member's model id and identity, not the primary's.
func TestWarmEntryRouteSnapshotRecordsServingMember(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "settlement-catalog", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{
		ObserveEnabled:   true,
		CatalogPath:      writeRouteSnapshotCatalog(t, raw),
		CatalogPublicKey: pubkey,
	}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
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
	up := &servedModelCapture{}
	upstream := httptest.NewServer(up.handler())
	defer upstream.Close()

	// The catalog lists model-a only. The primary serves model-z under
	// another hash; the further member model-a carries the catalog hash.
	member := warmMember("model-a", false, 1)
	member.ModelHash = buyerTestHash
	member.ModelHashAlgorithm = modelidentity.SnapshotManifestV1
	member.ExpectedModelHash = buyerTestHash
	registry := pool.NewRegistry(nil)
	registerWarmHTTPProvider(registry, "warm", upstream.URL, warmMember("model-z", true, 1), member, warmEntryOtherHash, bytes.Repeat([]byte{0x73}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{
		"Authorization":         {"Bearer operator-key"},
		"X-MacProvider-Account": {"acct_gateway"},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if hit := up.last(t); hit.header != "model-a" {
		t.Fatalf("served model header %q, want model-a", hit.header)
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var providerID, modelID, reported, expected, status string
	if err := db.QueryRow(`SELECT provider_id, model_id, provider_reported_model_hash, expected_catalog_model_hash, spec008_hash_status FROM settlement_route_snapshots`).Scan(&providerID, &modelID, &reported, &expected, &status); err != nil {
		t.Fatalf("route snapshot: %v", err)
	}
	if providerID != "warm" || modelID != "model-a" || reported != buyerTestHash || expected != buyerTestHash || status != string(pool.HashStatusVerified) {
		t.Fatalf("route snapshot provider=%s model=%s reported=%s expected=%s status=%s, want the model-a member", providerID, modelID, reported, expected, status)
	}
	// SPEC-022 R-16.2a: the snapshot is marked as an entry dispatch.
	var flagged int
	if err := db.QueryRow(`SELECT served_model_dispatch FROM settlement_route_snapshots`).Scan(&flagged); err != nil || flagged != 1 {
		t.Fatalf("served_model_dispatch=%d err=%v, want 1", flagged, err)
	}
}

// A provider without warm_models is never marked as an entry dispatch, so
// its credits keep the provider-wide SPEC-022 R-16.2 hold predicate.
func TestRouteSnapshotWithoutWarmSetIsNotServedModelDispatch(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "legacy-dispatch-catalog", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{
		ObserveEnabled:   true,
		CatalogPath:      writeRouteSnapshotCatalog(t, raw),
		CatalogPublicKey: pubkey,
	}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	reqLog, dbPath := openBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeProviderOK(w)
	}))
	defer upstream.Close()
	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x82}, 32))
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
	)
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var flagged int
	if err := db.QueryRow(`SELECT served_model_dispatch FROM settlement_route_snapshots`).Scan(&flagged); err != nil || flagged != 0 {
		t.Fatalf("served_model_dispatch=%d err=%v, want 0", flagged, err)
	}
}

// SPEC-002-R011: /v1/models lists a model served only by a further warm
// member, counting that entry once with its own slots; a member that is not
// warm is not listed, and a provider without a warm set lists as before.
func TestModelsListsWarmEntries(t *testing.T) {
	models := func(server *buyer.Server) map[string]map[string]any {
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
		if rr.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
		}
		var got struct {
			Data []map[string]any `json:"data"`
		}
		if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		out := map[string]map[string]any{}
		for _, m := range got.Data {
			out[m["id"].(string)] = m
		}
		return out
	}
	registry := pool.NewRegistry(nil)
	registerWithEndpoint(registry, "legacy", "legacy-session", "model-a", pool.StateReady, 20000, 1, "https://legacy.example", 20)
	registerWarmHTTPProvider(registry, "warm", "https://warm.example", warmMember("model-a", true, 1), warmMember("model-b", false, 3), buyerTestHash, nil)
	got := models(buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0)))
	if len(got) != 2 || got["model-a"]["provider_count"] != 2.0 || got["model-a"]["total_slots"] != 2.0 ||
		got["model-b"]["provider_count"] != 1.0 || got["model-b"]["total_slots"] != 3.0 {
		t.Fatalf("models = %v", got)
	}

	loading := warmMember("model-c", false, 2)
	loading.State = pool.WarmModelLoading
	loading.SlotsFree = 0
	registry = pool.NewRegistry(nil)
	registerWarmHTTPProvider(registry, "warm", "https://warm.example", warmMember("model-a", true, 1), loading, buyerTestHash, nil)
	got = models(buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0)))
	if len(got) != 1 || got["model-a"]["provider_count"] != 1.0 {
		t.Fatalf("a loading member must not be listed: %v", got)
	}
}
