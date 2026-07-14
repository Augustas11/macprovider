package buyer

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestStreamingStructuredOutputMirrorValidatorRuns(t *testing.T) {
	body := strings.Replace(validStructuredOutputRequest(true), `"type":"number"`, `"type":"string","minimum":0`, 1)
	_, status, code, _ := validateChatRequest([]byte(body))
	if status != http.StatusBadRequest || code != "json_schema_unsupported_keyword" {
		t.Fatalf("status=%d code=%s, want 400 json_schema_unsupported_keyword", status, code)
	}
}

func TestStreamingStructuredOutputRejectsDenormalMultipleOf(t *testing.T) {
	body := requestWithSchema(`{"type":"object","properties":{"age":{"type":"number","multipleOf":1e-300}},"required":["age"],"additionalProperties":false}`)
	_, status, code, _ := validateChatRequest([]byte(body))
	if status != http.StatusBadRequest || code != "json_schema_unsupported_keyword" {
		t.Fatalf("status=%d code=%s, want 400 json_schema_unsupported_keyword", status, code)
	}
}

func TestStreamingStructuredOutputSSEErrorCarriesRequestAndSettlement(t *testing.T) {
	rr := httptest.NewRecorder()
	writeSSEError(rr, "structured output failed", "json_schema_validation_failed", "req-structured")

	var envelope struct {
		Error struct {
			Code          string `json:"code"`
			RequestID     string `json:"request_id"`
			SettlementRan bool   `json:"settlement_ran"`
			InferenceRan  bool   `json:"inference_ran"`
		} `json:"error"`
	}
	line := strings.TrimPrefix(strings.Split(rr.Body.String(), "\n\n")[0], "data: ")
	if err := json.Unmarshal([]byte(line), &envelope); err != nil {
		t.Fatalf("decode SSE envelope: %v body=%s", err, rr.Body.String())
	}
	if envelope.Error.Code != "json_schema_validation_failed" ||
		envelope.Error.RequestID != "req-structured" ||
		!envelope.Error.SettlementRan ||
		!envelope.Error.InferenceRan {
		t.Fatalf("unexpected envelope: %#v", envelope.Error)
	}
}

// TestStreamingSSEErrorHonorsProviderRetryableOverride is the streaming
// counterpart to the non-streaming writeProviderStructuredOutputError override
// (runbook item 20 / SPEC-019 §5): a provider-supplied end.Retryable on a
// synthesized terminal SSE error must reach the buyer, and must agree with the
// non-streaming transport for the same (code, override) pair. A nil override
// leaves the static spec018Retryable default untouched. This exercises the
// writeSSEErrorWithRetryable helper mechanics; the real forwardWSStreaming
// routing + scope guard is covered by TestForwardWSStreamingHonorsScopedRetryableOverride.
// Cases use only override-ELIGIBLE codes (both statically true) so a false
// override proves a real flip.
func TestStreamingSSEErrorHonorsProviderRetryableOverride(t *testing.T) {
	tr := func(b bool) *bool { return &b }
	cases := []struct {
		name     string
		code     string
		override *bool
		want     bool
	}{
		// nil override → static default is preserved.
		{"nil_keeps_default_malformed", "malformed_json_response", nil, spec018Retryable("malformed_json_response")},
		{"nil_keeps_default_schema", "json_schema_validation_failed", nil, spec018Retryable("json_schema_validation_failed")},
		// override:false flips a statically-true code to false.
		{"override_false_flips_malformed", "malformed_json_response", tr(false), false},
		{"override_false_flips_schema", "json_schema_validation_failed", tr(false), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Streaming SSE synthesis.
			sse := httptest.NewRecorder()
			writeSSEErrorWithRetryable(sse, "detail", tc.code, tc.override, "req-1")
			var sseEnv struct {
				Error struct {
					Retryable bool `json:"retryable"`
				} `json:"error"`
			}
			line := strings.TrimPrefix(strings.Split(sse.Body.String(), "\n\n")[0], "data: ")
			if err := json.Unmarshal([]byte(line), &sseEnv); err != nil {
				t.Fatalf("decode SSE envelope: %v body=%s", err, sse.Body.String())
			}
			if sseEnv.Error.Retryable != tc.want {
				t.Fatalf("streaming retryable=%v, want %v (code=%s override=%v)", sseEnv.Error.Retryable, tc.want, tc.code, tc.override)
			}

			// Non-streaming JSON envelope must agree for the same inputs.
			js := httptest.NewRecorder()
			writeProviderStructuredOutputError(js, http.StatusBadGateway, tc.code, "detail", tc.override)
			var jsEnv struct {
				Error struct {
					Retryable bool `json:"retryable"`
				} `json:"error"`
			}
			if err := json.Unmarshal(js.Body.Bytes(), &jsEnv); err != nil {
				t.Fatalf("decode JSON envelope: %v body=%s", err, js.Body.String())
			}
			if jsEnv.Error.Retryable != sseEnv.Error.Retryable {
				t.Fatalf("transport divergence: streaming=%v non-streaming=%v (code=%s override=%v)", sseEnv.Error.Retryable, jsEnv.Error.Retryable, tc.code, tc.override)
			}
		})
	}
}

func TestStreamingStructuredOutputTerminalSSEErrorDetected(t *testing.T) {
	line := []byte(`data: {"error":{"code":"malformed_json_response"}}` + "\n")
	if code := terminalSSEErrorCodeFromLine(line); code != "malformed_json_response" {
		t.Fatalf("code=%q", code)
	}
	if !isSpec019TerminalSSEErrorCode("provider_timeout") || isSpec019TerminalSSEErrorCode("stream_malformed") {
		t.Fatal("terminal code classifier drifted")
	}
}
