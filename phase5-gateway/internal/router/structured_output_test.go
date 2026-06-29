package router

import "testing"

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

func TestStructuredOutputProviderErrorsPassThroughWithoutGatewaySettlement(t *testing.T) {
	for _, code := range []string{"malformed_json_response", "json_schema_validation_failed"} {
		body := []byte(`{"error":{"code":"` + code + `"}}`)
		if !isNullUsageProviderError(body) {
			t.Fatalf("%s should use receipt-eligible pass-through path", code)
		}
	}
}
