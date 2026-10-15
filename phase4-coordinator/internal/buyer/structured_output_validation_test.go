package buyer

import (
	"encoding/json"
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

func TestValidateChatRequestAcceptsStreamingStructuredOutput(t *testing.T) {
	for _, typ := range []string{"json_object", "json_schema"} {
		body := strings.Replace(validStructuredOutputRequest(true), `"json_schema"`, `"`+typ+`"`, 1)
		if typ == "json_object" {
			body = `{"model":"m","messages":[{"role":"user","content":"hi"}],"stream":true,"response_format":{"type":"json_object"}}`
		}
		if _, status, code, msg := validateChatRequest([]byte(body)); status != 0 {
			t.Fatalf("%s status=%d code=%s msg=%s", typ, status, code, msg)
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

func TestValidateResponseFormatRejectsUnsupportedKeywords(t *testing.T) {
	keywords := []string{"oneOf", "anyOf", "allOf", "not", "$ref", "$defs", "pattern", "format", "minItems", "maxItems", "uniqueItems"}
	for _, keyword := range keywords {
		t.Run(keyword, func(t *testing.T) {
			body := strings.Replace(validStructuredOutputRequest(false), `"additionalProperties":false`, `"additionalProperties":false,"`+keyword+`":[]`, 1)
			_, status, code, msg := validateChatRequest([]byte(body))
			if status != http.StatusBadRequest || code != "json_schema_unsupported_keyword" {
				t.Fatalf("status=%d code=%s msg=%s", status, code, msg)
			}
		})
	}
}

func TestValidateResponseFormatAcceptsTopLevelSchemaAndNumericBounds(t *testing.T) {
	schema := `{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"age":{"type":"integer","minimum":0,"maximum":10,"multipleOf":2}},"required":["age"],"additionalProperties":false}`
	if _, status, code, msg := validateChatRequest([]byte(requestWithSchema(schema))); status != 0 {
		t.Fatalf("status=%d code=%s msg=%s", status, code, msg)
	}
}

func TestValidateResponseFormatRejectsInvalidNumericBounds(t *testing.T) {
	cases := []string{
		`{"type":"string","minimum":0}`,
		`{"type":"number","multipleOf":0}`,
		`{"type":"number","minimum":"0"}`,
		`{"type":"number","minimum":5,"maximum":4}`,
		`{"type":"object","properties":{"age":{"type":"integer","$schema":"nested"}},"required":["age"],"additionalProperties":false}`,
	}
	for _, schema := range cases {
		t.Run(schema, func(t *testing.T) {
			_, status, code, msg := validateChatRequest([]byte(requestWithSchema(schema)))
			if status != http.StatusBadRequest || code != "json_schema_unsupported_keyword" {
				t.Fatalf("status=%d code=%s msg=%s", status, code, msg)
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

func TestValidateResponseFormatNameRegexParity(t *testing.T) {
	cases := []struct {
		name       string
		schemaName string
		wantStatus int
	}{
		{"dash accepted", "person-v1", 0},
		{"dot rejected", "person.v1", http.StatusBadRequest},
		{"unicode rejected", "Café", http.StatusBadRequest},
		{"long rejected", strings.Repeat("a", 65), http.StatusBadRequest},
		{"newline rejected", "name\nINJECT", http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			quotedName, err := json.Marshal(tc.schemaName)
			if err != nil {
				t.Fatalf("marshal schema name: %v", err)
			}
			body := strings.Replace(validStructuredOutputRequest(false), `"person-v1"`, string(quotedName), 1)
			_, status, code, msg := validateChatRequest([]byte(body))
			if status != tc.wantStatus {
				t.Fatalf("status=%d code=%s msg=%s, want %d", status, code, msg, tc.wantStatus)
			}
			if tc.wantStatus != 0 && code != "json_schema_invalid_name" {
				t.Fatalf("code=%s want json_schema_invalid_name", code)
			}
		})
	}
}

func TestIntegerSchemaScalarConformanceRejectsDoubleDrift(t *testing.T) {
	if !jsonSchemaScalarConforms(json.RawMessage(`1`), "integer") {
		t.Fatal("integer literal should conform to integer schema")
	}
	if jsonSchemaScalarConforms(json.RawMessage(`1.0`), "integer") {
		t.Fatal("decimal literal should not conform to integer schema")
	}
}

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

func requestWithStrictField(strictField, schema string) string {
	return `{"model":"m","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"person-v1"` + strictField + `,"schema":` + schema + `}}}`
}

// SPEC-019 v0.3.0 §1a: strict is tri-state and the effective mode is a pure
// function of the raw body.
func TestValidateResponseFormatNonStrictModes(t *testing.T) {
	subset := `{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}`
	// OpenAI/Pydantic-shaped schema outside the strict subset: optional
	// property, no additionalProperties, anyOf, $defs.
	openAIShaped := `{"type":"object","properties":{"name":{"type":"string"},"nick":{"anyOf":[{"type":"string"},{"type":"null"}]}},"required":["name"],"$defs":{"x":{"type":"string","format":"email"}}}`
	cases := []struct {
		name   string
		body   string
		status int
		code   string
	}{
		{"strict false subset", requestWithStrictField(`,"strict":false`, subset), 0, ""},
		{"strict false openai shaped", requestWithStrictField(`,"strict":false`, openAIShaped), 0, ""},
		{"absent subset", requestWithStrictField(``, subset), 0, ""},
		{"absent openai shaped", requestWithStrictField(``, openAIShaped), 0, ""},
		{"strict true openai shaped stays 400", requestWithStrictField(`,"strict":true`, openAIShaped), http.StatusBadRequest, "json_schema_unsupported_keyword"},
		{"strict true missing additionalProperties stays 400", requestWithStrictField(`,"strict":true`, `{"type":"object","properties":{},"required":[]}`), http.StatusBadRequest, "json_schema_strict_requires_additional_properties_false"},
		{"strict null is absent", requestWithStrictField(`,"strict":null`, openAIShaped), 0, ""},
		{"strict non boolean", requestWithStrictField(`,"strict":"no"`, subset), http.StatusBadRequest, "invalid_request"},
		{"strict number", requestWithStrictField(`,"strict":1`, subset), http.StatusBadRequest, "invalid_request"},
		{"strict number zero", requestWithStrictField(`,"strict":0`, openAIShaped), http.StatusBadRequest, "invalid_request"},
		{"strict false array schema", requestWithStrictField(`,"strict":false`, `[]`), http.StatusBadRequest, "json_schema_missing_schema"},
		{"absent string schema", requestWithStrictField(``, `"x"`), http.StatusBadRequest, "json_schema_missing_schema"},
		{"strict false null schema", requestWithStrictField(`,"strict":false`, `null`), http.StatusBadRequest, "json_schema_missing_schema"},
		{"strict false too deep", requestWithStrictField(`,"strict":false`, strings.Repeat(`{"a":`, 65)+`1`+strings.Repeat(`}`, 65)), http.StatusBadRequest, "json_schema_too_deep"},
		{"strict false depth cap", requestWithStrictField(`,"strict":false`, strings.Repeat(`{"a":`, 63)+`{}`+strings.Repeat(`}`, 63)), 0, ""},
		{"strict false too large", requestWithStrictField(`,"strict":false`, `{"description":"`+strings.Repeat("x", maxJSONSchemaBytes)+`"}`), http.StatusRequestEntityTooLarge, "json_schema_too_large"},
		{"strict false missing name", `{"model":"m","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"strict":false,"schema":{}}}}`, http.StatusBadRequest, "json_schema_missing_name"},
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
