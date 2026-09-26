package buyer

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

const (
	r3Delivered   = "data: {\"id\":\"c\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"
	r3UsageEvent  = "data: {\"id\":\"c\",\"choices\":[{\"delta\":{\"content\":\" and a great deal more\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":400,\"total_tokens\":405}}\n"
	r3Terminated  = r3UsageEvent + "\n"
	r3DoneEvent   = "data: [DONE]\n\n"
	r3FullContent = "Hello and a great deal more"
)

func r3HTTPStream(t *testing.T, stream string) (wsForwardResult, requestLogAttempt) {
	t.Helper()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(stream))
	}))
	defer upstream.Close()
	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now())
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`))
	body := []byte(`{"model":"llama","stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	provider := pool.Provider{ProviderID: "provider-1", AssignedID: "route-1", EndpointURL: upstream.URL}
	result, _, attempt := server.forwardStreaming(httptest.NewRecorder(), req, "req-1", body, provider, "llama", time.Second, nil, &forwardState{}, 0)
	return result, attempt
}

// Audit R3 HIGH: on a clean EOF the direct HTTP SSE path neither settles nor
// bills a final event that never got its blank-line terminator.
func TestForwardStreamingHTTPCleanEOFDropsUnterminatedFinalEvent(t *testing.T) {
	result, attempt := r3HTTPStream(t, r3Delivered+r3UsageEvent)
	if result != wsForwardComplete {
		t.Fatalf("result=%q, want complete", result)
	}
	if attempt.CompletionTokens != nil || attempt.PromptTokens != nil {
		t.Fatalf("usage prompt=%v completion=%v, want none from an undelivered event", attempt.PromptTokens, attempt.CompletionTokens)
	}
	if out := attempt.SettlementOutput; out == nil || out.Content != "Hello" {
		t.Fatalf("settlement output=%+v, want only the delivered %q", out, "Hello")
	}
}

// Audit R3: a normal, fully terminated completion still settles and bills its
// usage on the direct HTTP SSE path.
func TestForwardStreamingHTTPTerminatedCompletionStillSettles(t *testing.T) {
	result, attempt := r3HTTPStream(t, r3Delivered+r3Terminated+r3DoneEvent)
	if result != wsForwardComplete {
		t.Fatalf("result=%q, want complete", result)
	}
	if attempt.CompletionTokens == nil || *attempt.CompletionTokens != 400 || attempt.PromptTokens == nil || *attempt.PromptTokens != 5 {
		t.Fatalf("usage prompt=%v completion=%v, want 5/400", attempt.PromptTokens, attempt.CompletionTokens)
	}
	out := attempt.SettlementOutput
	if out == nil || out.Content != r3FullContent || out.TerminalState != billing.TerminalStateNormalDone {
		t.Fatalf("settlement output=%+v, want normal_done over %q", out, r3FullContent)
	}
}

// Audit R3: the WS incremental path settles only terminated events too.
func TestForwardWSStreamingDropsUnterminatedFinalEvent(t *testing.T) {
	requestID := "req-ws-unterminated"
	chunks := make(chan providerws.InferenceResponseChunk)
	done := make(chan providerws.InferenceResponseEnd, 1)
	go func() {
		chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: r3Delivered}
		chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 1, Data: r3UsageEvent}
		close(chunks)
		done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 2}
	}()
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}
	server := &Server{}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	_, attempt := server.forwardWSStreaming(httptest.NewRecorder(), req, requestID, pool.Provider{ProviderID: "provider-a"}, relay, &forwardState{}, 0)
	if out := attempt.SettlementOutput; out == nil || out.Content != "Hello" {
		t.Fatalf("settlement output=%+v, want only the terminated %q", out, "Hello")
	}
}

// Audit R3: the WS buffered path settles only terminated events.
func TestForwardWSStreamingBufferedDropsUnterminatedFinalEvent(t *testing.T) {
	requestID := "req-ws-buffered-unterminated"
	chunks := make(chan providerws.InferenceResponseChunk, 2)
	chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: r3Delivered}
	chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 1, Data: r3UsageEvent}
	close(chunks)
	done := make(chan providerws.InferenceResponseEnd, 1)
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}
	go func() {
		time.Sleep(50 * time.Millisecond)
		done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 2}
	}()
	server := &Server{}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	_, attempt := server.forwardWSStreamingBuffered(httptest.NewRecorder(), req, requestID, pool.Provider{ProviderID: "provider-a"}, relay, streamingModeBufferedKillSwitch, "buyer", &forwardState{}, 0)
	if out := attempt.SettlementOutput; out == nil || out.Content != "Hello" {
		t.Fatalf("settlement output=%+v, want only the terminated %q", out, "Hello")
	}
}

// Audit R3: the HTTP buffered path neither settles nor bills an unterminated
// final event.
func TestForwardStreamingBufferedHTTPDropsUnterminatedFinalEvent(t *testing.T) {
	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now())
	resp := &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(r3Delivered + r3UsageEvent)), Trailer: http.Header{}}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	result, _, attempt := server.forwardStreamingBuffered(httptest.NewRecorder(), req, "req-1", resp, pool.Provider{ProviderID: "provider-1"}, "llama", streamingModeBufferedKillSwitch, "buyer", &forwardState{}, 0)
	if result != wsForwardComplete {
		t.Fatalf("result=%q, want complete", result)
	}
	if attempt.CompletionTokens != nil {
		t.Fatalf("completion=%v, want none from an undelivered event", *attempt.CompletionTokens)
	}
	if out := attempt.SettlementOutput; out == nil || out.Content != "Hello" {
		t.Fatalf("settlement output=%+v, want only the terminated %q", out, "Hello")
	}
}
