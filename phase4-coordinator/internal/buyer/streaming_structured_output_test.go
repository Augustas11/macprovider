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

func TestStreamingStructuredOutputTerminalSSEErrorDetected(t *testing.T) {
	line := []byte(`data: {"error":{"code":"malformed_json_response"}}` + "\n")
	if code := terminalSSEErrorCodeFromLine(line); code != "malformed_json_response" {
		t.Fatalf("code=%q", code)
	}
	if !isSpec019TerminalSSEErrorCode("provider_timeout") || isSpec019TerminalSSEErrorCode("stream_malformed") {
		t.Fatal("terminal code classifier drifted")
	}
}
