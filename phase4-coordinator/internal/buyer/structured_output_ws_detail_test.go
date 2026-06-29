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

	result, attempt := server.forwardWSStreaming(rr, req, requestID, provider, relay)
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
