package buyer

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
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
