package buyer

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// A pre-commit error_context_exceeded on a stream is the buyer's request
// exceeding the provider's context, as on the non-streaming path: 413
// context_exceeds_capacity, not a retryable, breaker-qualifying 502.
func TestStreamingPreCommitContextExceededIsNonRetryableNonFaulting(t *testing.T) {
	for _, tc := range []struct {
		name string
		run  func(s *Server, w http.ResponseWriter, r *http.Request, provider pool.Provider, relay *providerws.RelayStream) (wsForwardResult, requestLogAttempt)
	}{
		{"incremental", func(s *Server, w http.ResponseWriter, r *http.Request, provider pool.Provider, relay *providerws.RelayStream) (wsForwardResult, requestLogAttempt) {
			return s.forwardWSStreaming(w, r, "req-ctx", provider, relay, nil, 1)
		}},
		{"buffered", func(s *Server, w http.ResponseWriter, r *http.Request, provider pool.Provider, relay *providerws.RelayStream) (wsForwardResult, requestLogAttempt) {
			return s.forwardWSStreamingBuffered(w, r, "req-ctx", provider, relay, streamingModeBufferedKillSwitch, "", nil, 1)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			at := time.Unix(1716768000, 0).UTC()
			s := NewServer(pool.NewRegistry(nil), zerolog.Nop(), at)
			done := make(chan providerws.InferenceResponseEnd, 1)
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-ctx", Status: "error_context_exceeded"}
			relay := &providerws.RelayStream{RequestID: "req-ctx", Chunks: make(chan providerws.InferenceResponseChunk), Done: done, Errors: make(chan error, 1)}
			r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			w := httptest.NewRecorder()

			result, attempt := tc.run(s, w, r, pool.Provider{ProviderID: "p1", AssignedID: "s1"}, relay)

			if result != wsForwardContextExceeded {
				t.Fatalf("result = %v, want %v", result, wsForwardContextExceeded)
			}
			if attempt.Status != http.StatusRequestEntityTooLarge || attempt.ErrorCode != "error_context_exceeded" {
				t.Fatalf("attempt = %+v, want 413/error_context_exceeded", attempt)
			}
			if attempt.FaultFlag != "" {
				t.Fatalf("fault flag = %q, want none: the request, not the provider, is at fault", attempt.FaultFlag)
			}
			if w.Body.Len() != 0 {
				t.Fatalf("forward wrote %q before the core rendered the terminal", w.Body.String())
			}
			tr := classifyStreamResult(result, statusForForwardResult(result), attempt)
			if tr.retryable || tr.failoverEligible || tr.markBusy || tr.committed || tr.status != http.StatusRequestEntityTooLarge {
				t.Fatalf("transport result = %+v, want non-retryable 413", tr)
			}
		})
	}
}

func TestWriteStreamForwardErrorContextExceededIs413(t *testing.T) {
	rr := httptest.NewRecorder()
	writeStreamForwardError(rr, wsForwardContextExceeded)
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413", rr.Code)
	}
	var body struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body: %v; body=%s", err, rr.Body.String())
	}
	if body.Error.Code != "context_exceeds_capacity" {
		t.Fatalf("code = %q, want context_exceeds_capacity; body=%s", body.Error.Code, rr.Body.String())
	}
}

// End to end: the first provider's stream rejects the request as over its
// context. The buyer gets 413 and no second provider is tried.
func TestChatCompletionsStreamingContextExceededDoesNotRetryOrFailover(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWSStreamingTestProvider(registry, "p1", "s1", "model-a")
	registerWSStreamingTestProvider(registry, "p2", "s2", "model-a")
	calls := map[string]int{}
	s := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			calls[provider.ProviderID]++
			done := make(chan providerws.InferenceResponseEnd, 1)
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "error_context_exceeded"}
			return &providerws.RelayStream{RequestID: requestID, Chunks: make(chan providerws.InferenceResponseChunk), Done: done, Errors: make(chan error, 1)}, nil
		}, 10*time.Second),
	)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader([]byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`)))
	req.Header.Set("X-MacProvider-Retry", "1")
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d body=%s, want 413", rr.Code, rr.Body.String())
	}
	var body struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil || body.Error.Code != "context_exceeds_capacity" {
		t.Fatalf("body = %s (err %v), want context_exceeds_capacity", rr.Body.String(), err)
	}
	if total := calls["p1"] + calls["p2"]; total != 1 {
		t.Fatalf("relay calls = %v, want exactly one provider tried", calls)
	}
	for _, p := range registry.Snapshot() {
		if p.State != pool.StateReady {
			t.Fatalf("provider %s state = %v, want ready (no busy/degrade on a buyer context error)", p.ProviderID, p.State)
		}
	}
}
