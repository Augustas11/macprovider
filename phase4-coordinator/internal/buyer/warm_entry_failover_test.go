package buyer_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// registerWarmWSProvider registers a WS-tunneled session with primary
// model-a and warm member model-b, one seat each.
func registerWarmWSProvider(registry *pool.Registry, providerID string, throughput float64) {
	verifyWarmMemberHashes(registry)
	now := time.Now().UTC()
	primary := warmMember("model-a", true, 1)
	member := warmMember("model-b", false, 1)
	member.ThroughputTPSEstimate = throughput
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            providerID + "-session",
		Hostname:              providerID + ".local",
		ModelID:               "model-a",
		ModelHash:             warmMemberHash("model-a"),
		HashStatus:            pool.HashStatusVerified,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: throughput,
		Tier:                  pool.TierProvisional,
		InferencePath:         pool.InferencePathWSTunneled,
		State:                 pool.StateReady,
		LastHeartbeatAt:       now,
		ConnectedAt:           now,
		BinaryVersion:         "0.1.0",
		SupportedModels:       []string{"model-a", "model-b"},
		WarmModels:            []pool.WarmModel{primary, member},
	}, nil)
}

// warmNotLoadedRelay answers model_not_loaded for the warm entry while
// evicted is set and completes every other dispatch.
func warmNotLoadedRelay(evicted *atomic.Bool, dispatches *atomic.Int32) buyer.RelayFunc {
	return func(_ context.Context, provider pool.Provider, reqID string, _ []byte, stream bool) (*providerws.RelayStream, error) {
		chunks := make(chan providerws.InferenceResponseChunk, 2)
		done := make(chan providerws.InferenceResponseEnd, 1)
		errs := make(chan error, 1)
		dispatches.Add(1)
		if provider.ProviderID == "pw" && provider.ServedModelID == "model-b" && evicted.Load() {
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: reqID, Status: "error_model_not_loaded", Error: "model not loaded"}
			return &providerws.RelayStream{RequestID: reqID, Chunks: chunks, Done: done, Errors: errs}, nil
		}
		data := `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`
		if stream {
			data = `data: {"id":"ok","choices":[{"delta":{"content":"ok"}}]}` + "\n\n"
		}
		chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: reqID, Seq: 0, Data: data}
		done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: reqID, Status: "complete", ChunksSent: 1, Usage: json.RawMessage(`{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}`)}
		return &providerws.RelayStream{RequestID: reqID, Chunks: chunks, Done: done, Errors: errs}, nil
	}
}

func warmBillingServer(t *testing.T, registry *pool.Registry, relay buyer.RelayFunc) (*buyer.Server, string) {
	t.Helper()
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
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
		// One breaker fault would trip the session: a recorded fault shows
		// as a degraded session.
		buyer.WithBreakerConfig(1, time.Minute),
		buyer.WithRelay(relay, time.Second),
	)
	return server, dbPath
}

func ledgerCreditsFor(t *testing.T, dbPath, providerID string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = ?`, providerID).Scan(&count); err != nil {
		t.Fatalf("count ledger credits: %v", err)
	}
	return count
}

func assertSessionUntouched(t *testing.T, registry *pool.Registry, providerID string) {
	t.Helper()
	session, ok := registry.Resolve(providerID, providerID+"-session")
	if !ok || session.State != pool.StateReady || !session.RoutingEligible() {
		t.Fatalf("session after model_not_loaded = %s ok=%v, want ready (no breaker fault, no session hold)", session.State, ok)
	}
	if primary, ok := registry.ResolveEntry(providerID, providerID+"-session", "model-a"); !ok || primary.State != pool.StateReady {
		t.Fatalf("primary entry after model_not_loaded = %s ok=%v", primary.State, ok)
	}
}

// SPEC-002-R011: a warm entry evicted between heartbeat and dispatch answers
// model_not_loaded; the request fails over to another provider's entry, the
// entry is closed until its next heartbeat, and the attempt is neither a
// breaker fault nor a settlement.
func TestWarmEntryModelNotLoadedFailsOver(t *testing.T) {
	for _, stream := range []bool{false, true} {
		registry := pool.NewRegistry(nil)
		registerWarmWSProvider(registry, "pw", 50)
		registerWithPath(registry, "p2", "p2-session", "model-b", pool.StateReady, 20000, 1, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
		evicted := &atomic.Bool{}
		evicted.Store(true)
		dispatches := &atomic.Int32{}
		server, dbPath := warmBillingServer(t, registry, warmNotLoadedRelay(evicted, dispatches))

		body := `{"model":"model-b","messages":[{"role":"user","content":"hi"}]`
		if stream {
			body += `,"stream":true`
		}
		rr := postChat(t, server, []byte(body+"}"), http.Header{})
		if rr.Code != http.StatusOK {
			t.Fatalf("stream=%v status=%d body=%s", stream, rr.Code, rr.Body.String())
		}
		if got := rr.Header().Get("X-MacProvider-Provider"); got != "p2" {
			t.Fatalf("stream=%v provider=%q, want p2 after failover", stream, got)
		}
		if dispatches.Load() != 2 {
			t.Fatalf("stream=%v dispatches=%d, want 2", stream, dispatches.Load())
		}
		rows := queryAllRequestLogRows(t, dbPath)
		if len(rows) != 2 || rows[0].ProviderAssignedID.String != "pw-session" || rows[0].Status != http.StatusServiceUnavailable || rows[0].ErrorCode.String != "error_model_not_loaded" {
			t.Fatalf("stream=%v request log rows=%#v, want pw 503 error_model_not_loaded then p2", stream, rows)
		}
		if rows[0].PromptTokens.Valid || rows[0].CompletionTokens.Valid {
			t.Fatalf("stream=%v model_not_loaded attempt carries usage: %#v", stream, rows[0])
		}
		if rows[1].ProviderAssignedID.String != "p2-session" || rows[1].Status != http.StatusOK {
			t.Fatalf("stream=%v success row=%#v", stream, rows[1])
		}
		if n := ledgerCreditsFor(t, dbPath, "pw"); n != 0 {
			t.Fatalf("stream=%v ledger credits for the refusing provider=%d, want 0", stream, n)
		}
		assertSessionUntouched(t, registry, "pw")
		member, ok := registry.ResolveEntry("pw", "pw-session", "model-b")
		if !ok || member.State != pool.StateUnavailable || member.RoutingEligible() {
			t.Fatalf("stream=%v member after model_not_loaded = %s ok=%v, want unavailable", stream, member.State, ok)
		}

		// The next heartbeat listing the member warm makes it routable again.
		evicted.Store(false)
		primary := warmMember("model-a", true, 1)
		reloaded := warmMember("model-b", false, 1)
		reloaded.ThroughputTPSEstimate = 50
		if _, _, ok := registry.ApplyHeartbeat("pw", "pw-session", pool.HeartbeatUpdate{
			Status:                pool.StateReady,
			ModelID:               "model-a",
			MaxContextTokens:      20000,
			MaxConcurrency:        1,
			SlotsFree:             1,
			SlotsTotal:            1,
			ThroughputTPSEstimate: 50,
			ModelHash:             warmMemberHash("model-a"),
			ModelHashPresent:      true,
			WarmModels:            []pool.WarmModel{primary, reloaded},
			At:                    time.Now().UTC(),
		}); !ok {
			t.Fatal("heartbeat rejected")
		}
		if member, _ := registry.ResolveEntry("pw", "pw-session", "model-b"); !member.RoutingEligible() {
			t.Fatalf("stream=%v member after heartbeat = %s, want routable", stream, member.State)
		}
		rr = postChat(t, server, []byte(body+"}"), http.Header{})
		if rr.Code != http.StatusOK || rr.Header().Get("X-MacProvider-Provider") != "pw" {
			t.Fatalf("stream=%v after heartbeat status=%d provider=%q, want 200 from pw", stream, rr.Code, rr.Header().Get("X-MacProvider-Provider"))
		}
	}
}

// With every entry for the model exhausted the buyer gets the answer it gets
// today when no provider can serve the model.
func TestWarmEntryModelNotLoadedExhaustionMatchesNoProvider(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWarmWSProvider(registry, "pw", 50)
	evicted := &atomic.Bool{}
	evicted.Store(true)
	dispatches := &atomic.Int32{}
	server, dbPath := warmBillingServer(t, registry, warmNotLoadedRelay(evicted, dispatches))

	first := postChat(t, server, []byte(`{"model":"model-b","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
	// The entry is now closed: this request finds no provider for the model
	// without any dispatch, which is today's answer.
	second := postChat(t, server, []byte(`{"model":"model-b","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
	if first.Code != http.StatusServiceUnavailable || first.Code != second.Code {
		t.Fatalf("status first=%d second=%d, want 503 both", first.Code, second.Code)
	}
	var a, b struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(first.Body.Bytes(), &a); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(second.Body.Bytes(), &b); err != nil {
		t.Fatal(err)
	}
	if a.Error.Code != "no_provider_available" || a.Error.Code != b.Error.Code || a.Error.Message != b.Error.Message {
		t.Fatalf("exhausted=%+v no-provider=%+v, want the same no_provider_available answer", a.Error, b.Error)
	}
	if dispatches.Load() != 1 {
		t.Fatalf("dispatches=%d, want 1", dispatches.Load())
	}
	if n := ledgerCreditsFor(t, dbPath, "pw"); n != 0 {
		t.Fatalf("ledger credits=%d, want 0", n)
	}
	assertSessionUntouched(t, registry, "pw")
}

// HTTP-forwarded: the provider's 503 model_not_loaded envelope fails over the
// same way, outside the buyer retry budget.
func TestWarmEntryHTTPModelNotLoadedFailsOver(t *testing.T) {
	notLoaded := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":{"message":"Model not loaded","type":"server_error","code":"model_not_loaded"}}`))
	}))
	defer notLoaded.Close()
	okUp := &servedModelCapture{}
	ok := httptest.NewServer(okUp.handler())
	defer ok.Close()

	registry := pool.NewRegistry(nil)
	fast := warmMember("model-b", false, 1)
	fast.ThroughputTPSEstimate = 50
	registerWarmHTTPProvider(registry, "pw", notLoaded.URL, warmMember("model-a", true, 1), fast, buyerTestHash, nil)
	registerWithEndpoint(registry, "p2", "p2-session", "model-b", pool.StateReady, 20000, 1, ok.URL, 10)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithBreakerConfig(1, time.Minute))

	rr := postChat(t, server, []byte(`{"model":"model-b","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
	if rr.Code != http.StatusOK || rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("status=%d provider=%q body=%s, want 200 from p2", rr.Code, rr.Header().Get("X-MacProvider-Provider"), rr.Body.String())
	}
	if hit := okUp.last(t); hit.hasHeader {
		t.Fatalf("legacy provider got X-MacProvider-Served-Model %q", hit.header)
	}
	assertSessionUntouched(t, registry, "pw")
	if member, _ := registry.ResolveEntry("pw", "pw-session", "model-b"); member.RoutingEligible() {
		t.Fatalf("member after model_not_loaded = %s, want unavailable", member.State)
	}
}
