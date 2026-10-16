package buyer

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// SPEC-002-R005: a whole JSON completion the coordinator converts to SSE
// arrives at once, so it has no first-token time and gives no TTFT or decode
// sample.
func TestWSStreamingJSONConversionHasNoFirstToken(t *testing.T) {
	requestID := "req-ws-json-convert"
	chunks := make(chan providerws.InferenceResponseChunk, 1)
	done := make(chan providerws.InferenceResponseEnd, 1)
	chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0,
		Data: `{"id":"c1","object":"chat.completion","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"` + strings.Repeat("x", 400) + `"},"finish_reason":"stop"}]}`}
	go func() {
		time.Sleep(20 * time.Millisecond)
		done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
	}()
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}
	state := &forwardState{}
	state.phaseTiming.markProviderDispatchStart(time.Now(), "session-a")
	w := httptest.NewRecorder()
	(&Server{}).forwardWSStreaming(w, httptest.NewRequest("POST", "/v1/chat/completions", nil), requestID, pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}, relay, state, 0)
	if !strings.Contains(w.Body.String(), "xxxx") {
		t.Fatalf("converted body not delivered: %q", w.Body.String())
	}
	if !state.phaseTiming.snapshot().providerFirstToken.IsZero() {
		t.Fatal("a whole JSON completion marked a first token")
	}
}

// SPEC-002-R005: an attempt recorded before its body is written enters the
// store only once the whole body reached the buyer.
func TestHeldPerformanceNeedsDelivery(t *testing.T) {
	s, _ := phaseTestServer(t)
	record := func(model string) *forwardState {
		state := &forwardState{estimatedTokens: 300, routingEstimatedTokens: 300}
		state.phaseTiming.markProviderDispatchStart(phaseTestNow, "s-fast")
		state.phaseTiming.markProviderDispatchDone(phaseTestNow)
		state.phaseTiming.markProviderDone(phaseTestNow.Add(4 * time.Second))
		holdPerformance(state)
		rec := &billingRecorder{server: s, state: state, model: model}
		output := settlementOutputForContent(strings.Repeat("x", 800), nil, nil, "normal_done")
		_ = rec.recordRow("s-fast", "fast", "", http.StatusOK, nil, nil, nil, "", "", 0, nil, "none", output)
		if _, ok := s.perf.Lookup("fast", model); ok {
			t.Fatalf("%s: a held observation entered the store before the write", model)
		}
		return state
	}
	failed := record("undelivered")
	s.releasePerformance(failed, false)
	if _, ok := s.perf.Lookup("fast", "undelivered"); ok || failed.perfHold || failed.pendingPerf != nil {
		t.Fatal("an undelivered body was observed")
	}
	delivered := record("delivered")
	s.releasePerformance(delivered, true)
	if e, ok := s.perf.Lookup("fast", "delivered"); !ok || e.ServiceTPS != 50 || delivered.perfHold {
		t.Fatalf("delivered body: %+v ok=%v", e, ok)
	}
}

// SPEC-002-R005 through the WS legacy (record-before-write) path: the
// observation enters the store only when the whole body was written and
// flushed to the buyer.
func TestWSNonStreamingLegacyObservesOnlyDeliveredBody(t *testing.T) {
	for _, tc := range []struct {
		name      string
		w         http.ResponseWriter
		wantStore bool
	}{
		{"flush fails", failingFlushWriter{httptest.NewRecorder()}, false},
		{"delivered", httptest.NewRecorder(), true},
	} {
		s, _ := phaseTestServer(t)
		requestID := "req-ws-legacy-" + strings.ReplaceAll(tc.name, " ", "-")
		chunks := make(chan providerws.InferenceResponseChunk, 1)
		done := make(chan providerws.InferenceResponseEnd, 1)
		chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0,
			Data: `{"id":"c1","object":"chat.completion","model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"` + strings.Repeat("x", 800) + `"},"finish_reason":"stop"}]}`}
		go func() {
			time.Sleep(20 * time.Millisecond)
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
		}()
		relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}
		state := &forwardState{estimatedTokens: 300, routingEstimatedTokens: 300}
		state.phaseTiming.markProviderDispatchStart(phaseTestNow.Add(-4*time.Second), "s-fast")
		rec := &billingRecorder{server: s, state: state, model: "model-a"}
		logSuccess := func(a requestLogAttempt) error {
			return rec.recordRow("s-fast", "fast", "", http.StatusOK, nil, nil, nil, "", "", 0, nil, "none", a.SettlementOutput)
		}
		result, attempt := s.forwardWSNonStreaming(tc.w, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), requestID, pool.Provider{ProviderID: "fast", AssignedID: "s-fast"}, relay, logSuccess, nil, state, 0)
		if tc.wantStore && result != wsForwardComplete {
			t.Fatalf("%s: result = %v attempt=%+v body=%v", tc.name, result, attempt, tc.w)
		}
		e, ok := s.perf.Lookup("fast", "model-a")
		if ok != tc.wantStore || (ok && e.ServiceTPS != 50) {
			t.Fatalf("%s: evidence = %+v ok=%v", tc.name, e, ok)
		}
	}
}
