package buyer

import (
	"net/http"
	"strings"
	"testing"
)

func TestValidateChatRequestAcceptsJSONSchemaResponseFormat(t *testing.T) {
	_, status, code, msg := validateChatRequest([]byte(validStructuredOutputRequest(false)))
	if status != 0 {
		t.Fatalf("status=%d code=%s msg=%s", status, code, msg)
	}
}

func TestValidateChatRequestRejectsStreamingStructuredOutput(t *testing.T) {
	for _, typ := range []string{"json_object", "json_schema"} {
		body := strings.Replace(validStructuredOutputRequest(true), `"json_schema"`, `"`+typ+`"`, 1)
		if typ == "json_object" {
			body = `{"model":"m","messages":[{"role":"user","content":"hi"}],"stream":true,"response_format":{"type":"json_object"}}`
		}
		_, status, code, _ := validateChatRequest([]byte(body))
		if status != http.StatusBadRequest {
			t.Fatalf("%s status=%d code=%s", typ, status, code)
		}
		want := "streaming_json_schema_unsupported"
		if typ == "json_object" {
			want = "streaming_json_object_unsupported"
		}
		if code != want {
			t.Fatalf("%s code=%s want %s", typ, code, want)
		}
	}
}

func TestValidateResponseFormatSchemaCapsAndSubset(t *testing.T) {
	cases := []struct {
		name   string
		body   string
		status int
		code   string
	}{
		{
			name:   "invalid name",
			body:   strings.Replace(validStructuredOutputRequest(false), `"person-v1"`, `"valid<script>"`, 1),
			status: http.StatusBadRequest,
			code:   "json_schema_invalid_name",
		},
		{
			name:   "unsupported keyword",
			body:   strings.Replace(validStructuredOutputRequest(false), `"additionalProperties":false`, `"additionalProperties":false,"minimum":0`, 1),
			status: http.StatusBadRequest,
			code:   "json_schema_unsupported_keyword",
		},
		{
			name:   "missing additionalProperties",
			body:   strings.Replace(validStructuredOutputRequest(false), `,"additionalProperties":false`, ``, 1),
			status: http.StatusBadRequest,
			code:   "json_schema_strict_requires_additional_properties_false",
		},
		{
			name:   "missing required property",
			body:   strings.Replace(validStructuredOutputRequest(false), `"required":["name","age"]`, `"required":["name"]`, 1),
			status: http.StatusBadRequest,
			code:   "json_schema_strict_requires_all_properties_required",
		},
		{
			name:   "const mismatch",
			body:   strings.Replace(validStructuredOutputRequest(false), `"type":"string"`, `"type":"string","const":42`, 1),
			status: http.StatusBadRequest,
			code:   "json_schema_invalid_const_or_enum_type",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, status, code, msg := validateChatRequest([]byte(tc.body))
			if status != tc.status || code != tc.code {
				t.Fatalf("status=%d code=%s msg=%s, want status=%d code=%s", status, code, msg, tc.status, tc.code)
			}
		})
	}
}

func TestValidateResponseFormatSchemaDepthAndByteCaps(t *testing.T) {
	if _, status, code, _ := validateChatRequest([]byte(requestWithSchema(nestedArraySchemaJSON(32)))); status != 0 {
		t.Fatalf("depth 32 status=%d code=%s", status, code)
	}
	if _, status, code, _ := validateChatRequest([]byte(requestWithSchema(nestedArraySchemaJSON(33)))); status != http.StatusBadRequest || code != "json_schema_too_deep" {
		t.Fatalf("depth 33 status=%d code=%s", status, code)
	}

	overhead := len(`{"type":"object","properties":{},"required":[],"additionalProperties":false,"title":""}`)
	title := strings.Repeat("x", maxJSONSchemaBytes-overhead)
	if _, status, code, _ := validateChatRequest([]byte(requestWithSchema(`{"type":"object","properties":{},"required":[],"additionalProperties":false,"title":"` + title + `"}`))); status != 0 {
		t.Fatalf("byte cap exact status=%d code=%s", status, code)
	}
	if _, status, code, _ := validateChatRequest([]byte(requestWithSchema(`{"type":"object","properties":{},"required":[],"additionalProperties":false,"title":"` + title + `x"}`))); status != http.StatusRequestEntityTooLarge || code != "json_schema_too_large" {
		t.Fatalf("byte cap over status=%d code=%s", status, code)
	}
}

func validStructuredOutputRequest(stream bool) string {
	streamField := ""
	if stream {
		streamField = `,"stream":true`
	}
	return requestWithSchema(`{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"number"}},"required":["name","age"],"additionalProperties":false}`)[:len(requestWithSchema(`{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"number"}},"required":["name","age"],"additionalProperties":false}`))-1] + streamField + `}`
}

func requestWithSchema(schema string) string {
	return `{"model":"m","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"person-v1","strict":true,"schema":` + schema + `}}}`
}

func nestedArraySchemaJSON(depth int) string {
	if depth == 1 {
		return `{"type":"string"}`
	}
	return `{"type":"array","items":` + nestedArraySchemaJSON(depth-1) + `}`
}
