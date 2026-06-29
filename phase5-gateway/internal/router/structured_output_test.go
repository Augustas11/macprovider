package router

import (
	"bytes"
	"net/http"
	"testing"
)

func TestContentEncodingSupportedForSpec019(t *testing.T) {
	for _, values := range [][]string{
		nil,
		{"identity"},
		{"\tidentity "},
		{"IDENTITY"},
	} {
		if !contentEncodingSupported(values) {
			t.Fatalf("expected accepted content-encoding values %#v", values)
		}
	}
	for _, values := range [][]string{
		{"gzip"},
		{"deflate"},
		{"br"},
		{"identity, gzip"},
		{"   "},
		{"\u00a0identity"},
	} {
		if contentEncodingSupported(values) {
			t.Fatalf("expected rejected content-encoding values %#v", values)
		}
	}
}

func TestStreamingStructuredOutputRejectEnvelopePassesThrough(t *testing.T) {
	for _, code := range []string{"streaming_json_schema_unsupported", "streaming_json_object_unsupported"} {
		t.Run(code, func(t *testing.T) {
			body := `{"error":{"message":"v0.1.0 does not stream structured output; resend with stream:false.","type":"invalid_request_error","param":"stream","code":"` + code + `","retryable":false,"request_id":null,"inference_ran":false,"settlement_ran":false}}`
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return responseWithBody(http.StatusBadRequest, http.Header{"Content-Type": []string{"application/json"}}, body), nil
			})}
			h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(client))
			fullKey := createAccountAndKey(t, store, cfg, "acct_streaming_reject_"+code)

			resp := postChat(t, h, fullKey, `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"person-v1","strict":true,"schema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}}}}`, nil)

			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			if !bytes.Equal(resp.Body.Bytes(), []byte(body)) {
				t.Fatalf("body=%s want byte-identical %s", resp.Body.String(), body)
			}
		})
	}
}

func TestStructuredOutputProviderErrorsPassThroughWithoutGatewaySettlement(t *testing.T) {
	for _, code := range []string{"malformed_json_response", "json_schema_validation_failed"} {
		body := []byte(`{"error":{"code":"` + code + `"}}`)
		if !isNullUsageProviderError(body) {
			t.Fatalf("%s should use receipt-eligible pass-through path", code)
		}
	}
}
