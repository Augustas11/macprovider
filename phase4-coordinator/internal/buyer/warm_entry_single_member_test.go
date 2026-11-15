package buyer_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// registerSingleOrLegacy registers provider id serving model-a with one
// seat; with single set its handshake carries a warm set of exactly one
// member (every new CLI sends warm_models, also with one model).
// With settle set it carries the verified identity and receipt key a settled
// dispatch needs.
func registerSingleOrLegacy(registry *pool.Registry, id, endpointURL string, path pool.InferencePath, single, settle bool) {
	now := time.Now().UTC()
	p := &pool.Provider{
		ProviderID: id, AssignedID: id + "-session", Hostname: id + ".local", ModelID: "model-a",
		ModelParamsB: 7, RAMGB: 16, MaxContextTokens: 20000, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1,
		ThroughputTPSEstimate: 50, EndpointURL: endpointURL, Tier: pool.TierPinned, InferencePath: path,
		State: pool.StateReady, LastHeartbeatAt: now, ConnectedAt: now, BinaryVersion: "0.1.0",
	}
	if settle {
		p.ModelHash, p.ModelHashAlgorithm = buyerTestHash, modelidentity.SnapshotManifestV1
		p.ExpectedModelHash, p.HashStatus = buyerTestHash, pool.HashStatusVerified
		p.ReceiptPubkey = bytes.Repeat([]byte{0x82}, 32)
	}
	if single {
		p.WarmModels = []pool.WarmModel{warmMember("model-a", true, 1)}
	}
	registry.Register(p, nil)
	slotsFree := 1
	registry.ApplyStateUpdate(id, id+"-session", pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: now})
}

type rawDispatch struct {
	body   []byte
	header http.Header
}

// An HTTP dispatch to a one-member provider is byte-identical to the one a
// legacy provider gets: same body, no served-model header.
func TestWarmSetOfOneHTTPDispatchIsLegacy(t *testing.T) {
	dispatch := func(single bool, stream bool) rawDispatch {
		var mu sync.Mutex
		var got rawDispatch
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(r.Body)
			mu.Lock()
			got = rawDispatch{body: body, header: r.Header.Clone()}
			mu.Unlock()
			var req struct {
				Stream bool `json:"stream"`
			}
			_ = json.Unmarshal(body, &req)
			if req.Stream {
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"))
				return
			}
			writeProviderOK(w)
		}))
		defer up.Close()
		registry := pool.NewRegistry(nil)
		registerSingleOrLegacy(registry, "pw", up.URL, pool.InferencePathHTTPForwarding, single, false)
		server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithGatewayServiceToken("operator-key"))
		body := `{"model":"model-a","messages":[{"role":"user","content":"hi"}]`
		if stream {
			body += `,"stream":true`
		}
		if rr := postChat(t, server, []byte(body+"}"), http.Header{}); rr.Code != http.StatusOK {
			t.Fatalf("single=%v status=%d body=%s", single, rr.Code, rr.Body.String())
		}
		mu.Lock()
		defer mu.Unlock()
		return got
	}
	for _, stream := range []bool{false, true} {
		legacy, single := dispatch(false, stream), dispatch(true, stream)
		if !bytes.Equal(legacy.body, single.body) {
			t.Fatalf("stream=%v body differs:\nlegacy %s\nsingle %s", stream, legacy.body, single.body)
		}
		if _, has := single.header[http.CanonicalHeaderKey("X-MacProvider-Served-Model")]; has {
			t.Fatalf("stream=%v one-member provider got a served-model header", stream)
		}
		for _, h := range []http.Header{legacy.header, single.header} {
			h.Del("X-Request-Id")
			h.Del("X-Macprovider-Request-Id")
		}
		if len(legacy.header) != len(single.header) {
			t.Fatalf("stream=%v headers differ: legacy %v single %v", stream, legacy.header, single.header)
		}
	}
}

// The route snapshot of a one-member provider's dispatch is not a served
// model dispatch (flag 0), so SPEC-022 R-16.2 keeps the provider-wide hold
// predicate exactly as for a legacy provider.
func TestWarmSetOfOneRouteSnapshotFlagIsZero(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "single-member-catalog", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{ObserveEnabled: true, CatalogPath: writeRouteSnapshotCatalog(t, raw), CatalogPublicKey: pubkey}, zerolog.Nop()); err != nil {
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
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeProviderOK(w) }))
	defer upstream.Close()
	registry := pool.NewRegistry(nil)
	registerSingleOrLegacy(registry, "p1", upstream.URL, pool.InferencePathHTTPForwarding, true, true)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog), buyer.WithBilling(billingStore, cfg), buyer.WithBillingSnapshotID(snapshotID))
	if rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil); rr.Code != http.StatusOK {
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

type notLoadedOutcome struct {
	Status   int
	Provider string
	Body     string
	State    pool.State
	Eligible bool
}

func notLoadedOutcomeOf(t *testing.T, server *buyer.Server, registry *pool.Registry, stream bool) notLoadedOutcome {
	t.Helper()
	body := `{"model":"model-a","messages":[{"role":"user","content":"hi"}]`
	if stream {
		body += `,"stream":true`
	}
	rr := postChat(t, server, []byte(body+"}"), http.Header{})
	session, _ := registry.Resolve("pw", "pw-session")
	return notLoadedOutcome{Status: rr.Code, Provider: rr.Header().Get("X-MacProvider-Provider"), Body: rr.Body.String(), State: session.State, Eligible: session.RoutingEligible()}
}

// HTTP-forwarded model_not_loaded from a one-member provider takes the legacy
// path (breaker fault, retry budget), with the same buyer answer.
func TestWarmSetOfOneHTTPModelNotLoadedIsLegacy(t *testing.T) {
	run := func(single bool) notLoadedOutcome {
		notLoaded := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":{"message":"Model not loaded","type":"server_error","code":"model_not_loaded"}}`))
		}))
		defer notLoaded.Close()
		ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeProviderOK(w) }))
		defer ok.Close()
		registry := pool.NewRegistry(nil)
		registerSingleOrLegacy(registry, "pw", notLoaded.URL, pool.InferencePathHTTPForwarding, single, false)
		registerWithEndpoint(registry, "p2", "p2-session", "model-a", pool.StateReady, 20000, 1, ok.URL, 10)
		server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithBreakerConfig(1, time.Minute))
		return notLoadedOutcomeOf(t, server, registry, false)
	}
	legacy, single := run(false), run(true)
	if !reflect.DeepEqual(legacy, single) {
		t.Fatalf("one-member HTTP model_not_loaded = %+v, legacy %+v", single, legacy)
	}
}

// WS-tunneled model_not_loaded from a one-member provider takes the legacy
// path, streaming and not, and the relay never names a served model.
func TestWarmSetOfOneWSModelNotLoadedIsLegacy(t *testing.T) {
	for _, stream := range []bool{false, true} {
		run := func(single bool) (notLoadedOutcome, int32) {
			registry := pool.NewRegistry(nil)
			registerSingleOrLegacy(registry, "pw", "", pool.InferencePathWSTunneled, single, false)
			registerWithPath(registry, "p2", "p2-session", "model-a", pool.StateReady, 20000, 1, "", 10, pool.TierPinned, pool.InferencePathWSTunneled)
			evicted := &atomic.Bool{}
			evicted.Store(true)
			dispatches := &atomic.Int32{}
			var named atomic.Int32
			relay := func(ctx context.Context, provider pool.Provider, reqID string, body []byte, stream bool) (*providerws.RelayStream, error) {
				if provider.ServedModelID != "" {
					named.Add(1)
				}
				if provider.ProviderID == "pw" {
					dispatches.Add(1)
					chunks := make(chan providerws.InferenceResponseChunk)
					done := make(chan providerws.InferenceResponseEnd, 1)
					done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: reqID, Status: "error_model_not_loaded", Error: "model not loaded"}
					return &providerws.RelayStream{RequestID: reqID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}, nil
				}
				return warmNotLoadedRelay(evicted, dispatches)(ctx, provider, reqID, body, stream)
			}
			server, _ := warmBillingServer(t, registry, relay)
			return notLoadedOutcomeOf(t, server, registry, stream), named.Load()
		}
		legacy, _ := run(false)
		single, named := run(true)
		if named != 0 {
			t.Fatalf("stream=%v relay named a served model %d times", stream, named)
		}
		if !reflect.DeepEqual(legacy, single) {
			t.Fatalf("stream=%v one-member WS model_not_loaded = %+v, legacy %+v", stream, single, legacy)
		}
	}
}
