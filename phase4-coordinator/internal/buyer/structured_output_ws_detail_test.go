package buyer

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

func TestSpec019ProviderWSDetailCodesSurviveToSSE(t *testing.T) {
	for _, code := range []string{
		"malformed_json_response",
		"json_schema_validation_failed",
		"response_byte_cap_exceeded",
		"provider_timeout",
	} {
		t.Run(code, func(t *testing.T) {
			if !isSpec019ProviderDetailCode(code) {
				t.Fatalf("isSpec019ProviderDetailCode(%q)=false", code)
			}
			if got := spec001EndStatus(code); got != code {
				t.Fatalf("spec001EndStatus(%q)=%q, want literal code", code, got)
			}

			rr := httptest.NewRecorder()
			writeSSEError(rr, "Provider failed during inference", code, "req-structured")

			var envelope struct {
				Error struct {
					Code          string `json:"code"`
					SettlementRan bool   `json:"settlement_ran"`
				} `json:"error"`
			}
			line := strings.TrimPrefix(strings.Split(rr.Body.String(), "\n\n")[0], "data: ")
			if err := json.Unmarshal([]byte(line), &envelope); err != nil {
				t.Fatalf("decode SSE envelope: %v body=%s", err, rr.Body.String())
			}
			if envelope.Error.Code != code {
				t.Fatalf("SSE code=%q, want %q", envelope.Error.Code, code)
			}
			if !envelope.Error.SettlementRan {
				t.Fatalf("SSE settlement_ran=false for %q", code)
			}
		})
	}
}

func TestForwardWSStreamingMapsResponseByteCapExceededToSSE(t *testing.T) {
	assertForwardWSStreamingMapsDetailCodeToSSE(t, "response_byte_cap_exceeded")
}

func TestForwardWSStreamingMapsProviderTimeoutToSSE(t *testing.T) {
	assertForwardWSStreamingMapsDetailCodeToSSE(t, "provider_timeout")
}

func TestForwardWSStreamingSanitizesCachedPromptTokensInBuyerSSE(t *testing.T) {
	requestID := "req-cache-ws-stream"
	chunks := make(chan providerws.InferenceResponseChunk)
	done := make(chan providerws.InferenceResponseEnd)
	errs := make(chan error, 1)
	go func() {
		chunks <- providerws.InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: requestID,
			Seq:       0,
			Data:      `data: {"choices":[{"delta":{"content":"ok"}}],"usage":{"prompt_tokens":10,"cached_prompt_tokens":4,"completion_tokens":2,"total_tokens":12}}` + "\n\n",
		}
		close(chunks)
		done <- providerws.InferenceResponseEnd{
			Type:       "inference_response_end",
			RequestID:  requestID,
			Status:     "complete",
			ChunksSent: 1,
		}
	}()

	server := &Server{}
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rr := httptest.NewRecorder()

	result, attempt := server.forwardWSStreaming(rr, req, requestID, provider, relay, &forwardState{}, 0)
	if result != wsForwardComplete {
		t.Fatalf("result=%q, want %q", result, wsForwardComplete)
	}
	if attempt.CachedPromptTokens == nil || *attempt.CachedPromptTokens != 4 {
		t.Fatalf("attempt cached_prompt_tokens=%v, want raw 4 for billing quarantine", attempt.CachedPromptTokens)
	}
	if !strings.Contains(rr.Body.String(), `"cached_prompt_tokens":0`) {
		t.Fatalf("buyer SSE did not sanitize cached_prompt_tokens to 0: %s", rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), `"cached_prompt_tokens":4`) {
		t.Fatalf("buyer SSE leaked raw cached_prompt_tokens: %s", rr.Body.String())
	}
}

func TestForwardWSStreamingBufferedSanitizesCachedPromptTokensInBuyerSSE(t *testing.T) {
	requestID := "req-cache-ws-buffered"
	chunks := make(chan providerws.InferenceResponseChunk)
	done := make(chan providerws.InferenceResponseEnd)
	errs := make(chan error, 1)
	go func() {
		chunks <- providerws.InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: requestID,
			Seq:       0,
			Data:      `data: {"choices":[{"delta":{"content":"ok"}}],"usage":{"prompt_tokens":10,"cached_prompt_tokens":4,"completion_tokens":2,"total_tokens":12}}` + "\n\n",
		}
		close(chunks)
		done <- providerws.InferenceResponseEnd{
			Type:       "inference_response_end",
			RequestID:  requestID,
			Status:     "complete",
			ChunksSent: 1,
		}
	}()

	server := &Server{}
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rr := httptest.NewRecorder()

	result, attempt := server.forwardWSStreamingBuffered(rr, req, requestID, provider, relay, streamingModeBufferedKillSwitch, "buyer-a", &forwardState{}, 0)
	if result != wsForwardComplete {
		t.Fatalf("result=%q, want %q", result, wsForwardComplete)
	}
	if attempt.CachedPromptTokens == nil || *attempt.CachedPromptTokens != 4 {
		t.Fatalf("attempt cached_prompt_tokens=%v, want raw 4 for billing quarantine", attempt.CachedPromptTokens)
	}
	if !strings.Contains(rr.Body.String(), `"cached_prompt_tokens":0`) {
		t.Fatalf("buyer SSE did not sanitize cached_prompt_tokens to 0: %s", rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), `"cached_prompt_tokens":4`) {
		t.Fatalf("buyer SSE leaked raw cached_prompt_tokens: %s", rr.Body.String())
	}
}

func TestForwardWSStreamingLatchesInvalidCachedPromptTokensAfterLaterValidUsage(t *testing.T) {
	requestID := "req-cache-ws-invalid-then-valid"
	chunks := make(chan providerws.InferenceResponseChunk)
	done := make(chan providerws.InferenceResponseEnd)
	errs := make(chan error, 1)
	go func() {
		chunks <- providerws.InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: requestID,
			Seq:       0,
			Data:      `data: {"choices":[{"delta":{"content":"ok"}}],"usage":{"prompt_tokens":3,"cached_prompt_tokens":4,"completion_tokens":0,"total_tokens":3}}` + "\n\n",
		}
		chunks <- providerws.InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: requestID,
			Seq:       1,
			Data:      `data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"cached_prompt_tokens":0,"completion_tokens":1,"total_tokens":4}}` + "\n\n",
		}
		close(chunks)
		done <- providerws.InferenceResponseEnd{
			Type:       "inference_response_end",
			RequestID:  requestID,
			Status:     "complete",
			ChunksSent: 2,
		}
	}()

	server := &Server{}
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rr := httptest.NewRecorder()

	result, attempt := server.forwardWSStreaming(rr, req, requestID, provider, relay, &forwardState{}, 0)
	if result != wsForwardComplete {
		t.Fatalf("result=%q, want %q", result, wsForwardComplete)
	}
	if attempt.CachedPromptTokens == nil || *attempt.CachedPromptTokens != -1 {
		t.Fatalf("attempt cached_prompt_tokens=%v, want invalid sentinel", attempt.CachedPromptTokens)
	}
	if strings.Contains(rr.Body.String(), `"cached_prompt_tokens":4`) {
		t.Fatalf("buyer SSE leaked invalid cached_prompt_tokens: %s", rr.Body.String())
	}
}

func TestForwardWSStreamingBufferedLatchesInvalidCachedPromptTokensAfterLaterValidUsage(t *testing.T) {
	requestID := "req-cache-ws-buffered-invalid-then-valid"
	chunks := make(chan providerws.InferenceResponseChunk)
	done := make(chan providerws.InferenceResponseEnd)
	errs := make(chan error, 1)
	go func() {
		chunks <- providerws.InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: requestID,
			Seq:       0,
			Data:      `data: {"choices":[{"delta":{"content":"ok"}}],"usage":{"prompt_tokens":3,"cached_prompt_tokens":4,"completion_tokens":0,"total_tokens":3}}` + "\n\n",
		}
		chunks <- providerws.InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: requestID,
			Seq:       1,
			Data:      `data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"cached_prompt_tokens":0,"completion_tokens":1,"total_tokens":4}}` + "\n\n",
		}
		close(chunks)
		done <- providerws.InferenceResponseEnd{
			Type:       "inference_response_end",
			RequestID:  requestID,
			Status:     "complete",
			ChunksSent: 2,
		}
	}()

	server := &Server{}
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rr := httptest.NewRecorder()

	result, attempt := server.forwardWSStreamingBuffered(rr, req, requestID, provider, relay, streamingModeBufferedKillSwitch, "buyer-a", &forwardState{}, 0)
	if result != wsForwardComplete {
		t.Fatalf("result=%q, want %q", result, wsForwardComplete)
	}
	if attempt.CachedPromptTokens == nil || *attempt.CachedPromptTokens != -1 {
		t.Fatalf("attempt cached_prompt_tokens=%v, want invalid sentinel", attempt.CachedPromptTokens)
	}
	if strings.Contains(rr.Body.String(), `"cached_prompt_tokens":4`) {
		t.Fatalf("buyer SSE leaked invalid cached_prompt_tokens: %s", rr.Body.String())
	}
}

// TestForwardWSStreamingHonorsScopedRetryableOverride is the routing-path
// regression for runbook item 20: it drives the REAL forwardWSStreaming call
// site (not writeSSEErrorWithRetryable directly) with an InferenceResponseEnd
// carrying an explicit Retryable, and asserts the synthesized SSE `retryable`
// reflects the override ONLY for the two override-eligible codes
// (malformed_json_response / json_schema_validation_failed), matching the
// non-streaming scope. A future edit that drops end.Retryable at the call site,
// OR widens the scope to a cap/timeout code, fails this test.
func TestForwardWSStreamingHonorsScopedRetryableOverride(t *testing.T) {
	tr := func(b bool) *bool { return &b }
	cases := []struct {
		name          string
		code          string
		override      *bool
		wantRetryable bool
	}{
		// Override-eligible: json_schema_validation_failed static default is
		// true; a provider override:false must flip it through the routing path.
		{"eligible_override_false_flips", "json_schema_validation_failed", tr(false), false},
		{"eligible_nil_keeps_default_true", "json_schema_validation_failed", nil, true},
		// NOT override-eligible: response_byte_cap_exceeded static default is
		// false; a provider override:true must be IGNORED at the routing site
		// (scope guard), so the buyer still sees false. This is the security
		// invariant — a provider cannot flip a non-retryable cap failure.
		{"scoped_out_override_true_ignored", "response_byte_cap_exceeded", tr(true), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			requestID := "req-override"
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{
				Type:      "inference_response_chunk",
				RequestID: requestID,
				Seq:       0,
				Data:      "data: {\"choices\":[{\"delta\":{\"content\":\"prefix\"}}]}\n\n",
			}
			close(chunks)
			done <- providerws.InferenceResponseEnd{
				Type:      "inference_response_end",
				RequestID: requestID,
				Status:    tc.code,
				Retryable: tc.override,
			}

			server := &Server{}
			provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
			relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}
			req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
			req.RemoteAddr = "127.0.0.1:12345"
			rr := httptest.NewRecorder()

			result, _ := server.forwardWSStreaming(rr, req, requestID, provider, relay, &forwardState{}, 0)
			if result != wsForwardComplete {
				t.Fatalf("result=%q, want %q", result, wsForwardComplete)
			}
			var envelope struct {
				Error struct {
					Code      string `json:"code"`
					Retryable bool   `json:"retryable"`
				} `json:"error"`
			}
			// The body streams the prefix content chunk first, then the
			// synthesized error frame; find the segment carrying error.code.
			var errLine string
			for _, seg := range strings.Split(rr.Body.String(), "\n\n") {
				payload := strings.TrimPrefix(strings.TrimSpace(seg), "data: ")
				if strings.Contains(payload, `"error"`) {
					errLine = payload
					break
				}
			}
			if errLine == "" {
				t.Fatalf("no SSE error frame in body: %s", rr.Body.String())
			}
			if err := json.Unmarshal([]byte(errLine), &envelope); err != nil {
				t.Fatalf("decode SSE envelope: %v line=%s", err, errLine)
			}
			if envelope.Error.Code != tc.code {
				t.Fatalf("SSE code=%q, want %q", envelope.Error.Code, tc.code)
			}
			if envelope.Error.Retryable != tc.wantRetryable {
				t.Fatalf("routing-path retryable=%v, want %v (code=%s override=%v)", envelope.Error.Retryable, tc.wantRetryable, tc.code, tc.override)
			}
		})
	}
}

// TestSpec019RetryableOverrideScope pins the override allow-list to exactly the
// two codes the non-streaming writeWSEndError routes through
// writeProviderStructuredOutputError.
func TestSpec019RetryableOverrideScope(t *testing.T) {
	for _, code := range []string{"malformed_json_response", "json_schema_validation_failed"} {
		if !isSpec019RetryableOverrideCode(code) {
			t.Errorf("isSpec019RetryableOverrideCode(%q)=false, want true", code)
		}
	}
	for _, code := range []string{"response_byte_cap_exceeded", "provider_timeout", "provider_error", ""} {
		if isSpec019RetryableOverrideCode(code) {
			t.Errorf("isSpec019RetryableOverrideCode(%q)=true, want false", code)
		}
	}
}

func assertForwardWSStreamingMapsDetailCodeToSSE(t *testing.T, code string) {
	t.Helper()
	requestID := "req-structured"
	chunks := make(chan providerws.InferenceResponseChunk, 1)
	done := make(chan providerws.InferenceResponseEnd, 1)
	errs := make(chan error, 1)
	chunks <- providerws.InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: requestID,
		Seq:       0,
		Data:      "data: {\"choices\":[{\"delta\":{\"content\":\"prefix\"}}]}\n\n",
	}
	close(chunks)
	done <- providerws.InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  requestID,
		Status:     code,
		ChunksSent: 1,
	}

	server := &Server{}
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	relay := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rr := httptest.NewRecorder()

	result, attempt := server.forwardWSStreaming(rr, req, requestID, provider, relay, &forwardState{}, 0)
	if result != wsForwardComplete {
		t.Fatalf("result=%q, want %q", result, wsForwardComplete)
	}
	if attempt.ErrorCode != code {
		t.Fatalf("attempt error code=%q, want %q", attempt.ErrorCode, code)
	}

	body := rr.Body.String()
	for _, want := range []string{
		`"code":"` + code + `"`,
		`"settlement_ran":true`,
		`"request_id":"` + requestID + `"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("SSE body missing %s: %s", want, body)
		}
	}
}
