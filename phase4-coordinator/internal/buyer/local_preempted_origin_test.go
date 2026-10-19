package buyer_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/rs/zerolog"
)

func TestHTTPNonStreamingLocalPreemptedRetriesWithOriginMarker(t *testing.T) {
	testHTTPLocalPreemptedRetriesWithOriginMarker(t, false)
}

func TestHTTPStreamingLocalPreemptedRetriesWithOriginMarker(t *testing.T) {
	testHTTPLocalPreemptedRetriesWithOriginMarker(t, true)
}

// A provider that answers 503 local_preempted to a coordinator dispatch is a
// retryable provider failure: the attempt advances, the provider is not
// degraded, and every dispatch (here with no settlement metadata, as in
// observe mode) carries the coordinator origin marker.
func testHTTPLocalPreemptedRetriesWithOriginMarker(t *testing.T, stream bool) {
	t.Helper()
	var preemptedCalls, okCalls, unmarked atomic.Int64
	marked := func(r *http.Request) {
		if r.Header.Get(providerhttp.OriginHeader) != providerhttp.OriginCoordinatorValue {
			unmarked.Add(1)
		}
	}
	preempting := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		preemptedCalls.Add(1)
		marked(r)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":{"message":"Local request was stopped","type":"server_error","code":"local_preempted","retryable":true}}`))
	}))
	defer preempting.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		okCalls.Add(1)
		marked(r)
		if stream {
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = w.Write([]byte("data: {\"id\":\"ok\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"))
			return
		}
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "preempting", EndpointURL: preempting.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	pubkey := bytes.Repeat([]byte{0x63}, 32)
	registerWithEndpointReceiptPubkey(registry, "preempting", "s1", "model-a", pool.StateReady, 20000, 1, preempting.URL, 30, pubkey)
	registerWithEndpointReceiptPubkey(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20, pubkey)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 5,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`)
	if stream {
		body = []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`)
	}
	rr := postChat(t, server, body, http.Header{"X-MacProvider-Retry": []string{"1"}})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s, want retried success", rr.Code, rr.Body.String())
	}
	if bytes.Contains(rr.Body.Bytes(), []byte("local_preempted")) {
		t.Fatalf("local_preempted leaked to buyer: %s", rr.Body.String())
	}
	if preemptedCalls.Load() != 1 || okCalls.Load() != 1 {
		t.Fatalf("calls preempting=%d ok=%d, want 1/1", preemptedCalls.Load(), okCalls.Load())
	}
	if unmarked.Load() != 0 {
		t.Fatalf("%d provider dispatches lacked %s", unmarked.Load(), providerhttp.OriginHeader)
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("rows=%d: %#v", len(rows), rows)
	}
	if rows[0].ProviderAssignedID.String != "s1" || rows[0].Status != http.StatusBadGateway || rows[0].ErrorCode.String != "local_preempted" {
		t.Fatalf("row[0]=%+v, want s1/502/local_preempted", rows[0])
	}
	for _, provider := range registry.Snapshot() {
		if provider.State != pool.StateReady {
			t.Fatalf("provider %s state=%s, want ready after local_preempted", provider.ProviderID, provider.State)
		}
	}
}
