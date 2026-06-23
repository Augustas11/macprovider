package canon

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestKnownSwiftPromptVectors(t *testing.T) {
	tests := []struct {
		name string
		req  map[string]any
		hash string
	}{
		{
			name: "sixteen committed keys",
			req:  fixturePromptRequest(),
			hash: "a762aef8cf64fd65f05096e7f98010804a1c4e8fb07f0a1ea7616f1cde2663cd",
		},
		{
			name: "absent committed fields null",
			req: map[string]any{
				"model": "fixture-model",
				"messages": []any{
					map[string]any{"role": "user", "content": "hello"},
				},
			},
			hash: "f3847a19a490e8d60bcab1109efb66cb8b2c2ef9c38c3a7397705d585dd2b65a",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			canonical, hash, err := CanonicalPrompt(tc.req)
			if err != nil {
				t.Fatalf("CanonicalPrompt() error = %v", err)
			}
			if got := hex.EncodeToString(hash[:]); got != tc.hash {
				t.Fatalf("hash = %s, want %s\ncanonical=%s", got, tc.hash, canonical)
			}
		})
	}
}

func TestPromptOptionalFieldTypesAndAbsentNull(t *testing.T) {
	req := map[string]any{
		"model":    "fixture-model",
		"messages": []any{map[string]any{"role": "user", "content": "hello"}},
		"tools": []any{
			map[string]any{
				"type": "function",
				"function": map[string]any{
					"name":        "lookup",
					"description": nil,
					"parameters": map[string]any{
						"type":       "object",
						"properties": map[string]any{"city": map[string]any{"type": "string"}},
					},
				},
			},
		},
		"temperature":       0.25,
		"top_p":             json.Number("1.0"),
		"max_tokens":        64,
		"stop":              []any{"END", map[string]any{"nested": true}},
		"seed":              nil,
		"response_format":   map[string]any{"type": "json_object"},
		"tool_choice":       "auto",
		"presence_penalty":  -0.5,
		"frequency_penalty": 0,
		"logit_bias":        map[string]any{"123": -1},
		"logprobs":          true,
		"top_logprobs":      2,
		"n":                 1,
	}

	canonical, _, err := CanonicalPrompt(req)
	if err != nil {
		t.Fatalf("CanonicalPrompt() error = %v", err)
	}
	got := string(canonical)
	for _, want := range []string{
		`"temperature":0.25`,
		`"top_p":1`,
		`"max_tokens":64`,
		`"stop":["END",{"nested":true}]`,
		`"seed":null`,
		`"response_format":{"type":"json_object"}`,
		`"tool_choice":"auto"`,
		`"presence_penalty":-0.5`,
		`"frequency_penalty":0`,
		`"logit_bias":{"123":-1}`,
		`"logprobs":true`,
		`"top_logprobs":2`,
		`"n":1`,
		`"tools":[{"function":{"description":null,"name":"lookup","parameters":{"properties":{"city":{"type":"string"}},"type":"object"}},"type":"function"}]`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("canonical missing %s\n%s", want, got)
		}
	}
}

func TestMultiContentMessageCanonicalizesAllPartTypes(t *testing.T) {
	canonical, _, err := CanonicalPrompt(fixturePromptRequest())
	if err != nil {
		t.Fatalf("CanonicalPrompt() error = %v", err)
	}
	got := string(canonical)
	for _, want := range []string{
		`{"text":"Hello\nworld","type":"text"}`,
		`{"image_url":{"detail":"low","url":"data:image/png;base64,AAAA"},"type":"image_url"}`,
		`{"input_audio":{"data":"QUJD","format":"wav"},"type":"input_audio"}`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("canonical missing content part %s\n%s", want, got)
		}
	}
}

func TestToolCallArgumentsPreserveRawWhitespaceAndUnicode(t *testing.T) {
	compact := toolCallPrompt(`{"b":2,"a":"Café"}`)
	spaced := toolCallPrompt(`{"b":2, "a":"Café"}`)
	precomposed := toolCallPrompt(`{"b":2,"a":"Café"}`)

	compactBytes, compactHash, err := CanonicalPrompt(compact)
	if err != nil {
		t.Fatalf("CanonicalPrompt(compact) error = %v", err)
	}
	_, spacedHash, err := CanonicalPrompt(spaced)
	if err != nil {
		t.Fatalf("CanonicalPrompt(spaced) error = %v", err)
	}
	_, precomposedHash, err := CanonicalPrompt(precomposed)
	if err != nil {
		t.Fatalf("CanonicalPrompt(precomposed) error = %v", err)
	}
	if bytes.Equal(compactHash[:], spacedHash[:]) {
		t.Fatalf("raw argument whitespace was normalized")
	}
	if bytes.Equal(compactHash[:], precomposedHash[:]) {
		t.Fatalf("raw argument Unicode was NFC-normalized")
	}
	if !strings.Contains(string(compactBytes), `"arguments":"{\"b\":2,\"a\":\"Café\"}"`) {
		t.Fatalf("canonical compact arguments lost raw bytes: %s", compactBytes)
	}
}

func TestPromptLineEndingNormalizationHashesSame(t *testing.T) {
	inputs := []string{"Cafe\u0301\r\nline\r", "Café\nline\n", "Cafe\u0301\nline\n"}
	var first [32]byte
	for i, input := range inputs {
		_, hash, err := CanonicalPrompt(map[string]any{
			"model":    "fixture-model",
			"messages": []any{map[string]any{"role": "user", "content": input}},
		})
		if err != nil {
			t.Fatalf("CanonicalPrompt(%d) error = %v", i, err)
		}
		if i == 0 {
			first = hash
			continue
		}
		if hash != first {
			t.Fatalf("hash %d = %x, want %x", i, hash, first)
		}
	}
}

func TestInvalidPromptShapesReturnTypedErrors(t *testing.T) {
	base := map[string]any{"model": "fixture-model", "messages": []any{map[string]any{"role": "user", "content": "hello"}}}

	cases := []struct {
		name string
		req  map[string]any
		want error
	}{
		{"invalid content", clonePrompt(base, func(req map[string]any) {
			req["messages"] = []any{map[string]any{"role": "user", "content": 7}}
		}), ErrInvalidContent},
		{"invalid content part type", clonePrompt(base, func(req map[string]any) {
			req["messages"] = []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "file"}}}}
		}), ErrInvalidContentPartType},
		{"invalid tools", clonePrompt(base, func(req map[string]any) {
			req["tools"] = map[string]any{"type": "function"}
		}), ErrInvalidTools},
		{"invalid tool calls", clonePrompt(base, func(req map[string]any) {
			req["messages"] = []any{map[string]any{"role": "assistant", "content": nil, "tool_calls": map[string]any{}}}
		}), ErrInvalidToolCalls},
		{"expected object", clonePrompt(base, func(req map[string]any) {
			req["messages"] = []any{"not-object"}
		}), ErrExpectedObject},
		{"expected string", clonePrompt(base, func(req map[string]any) {
			req["model"] = 12
		}), ErrExpectedString},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, _, err := CanonicalPrompt(tc.req)
			if !errors.Is(err, tc.want) {
				t.Fatalf("CanonicalPrompt() error = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestKnownSwiftOutputVectors(t *testing.T) {
	response := map[string]any{
		"choices": []any{map[string]any{
			"message": map[string]any{
				"content": "Line 1\r\nCafe\u0301\rLine 3",
				"tool_calls": []any{map[string]any{
					"id": "call_1",
					"function": map[string]any{
						"name":      "lookup",
						"arguments": `{"b":2, "a":1}`,
					},
				}},
			},
			"finish_reason": "tool_calls",
		}},
	}
	_, hash, err := CanonicalOutput(response)
	if err != nil {
		t.Fatalf("CanonicalOutput() error = %v", err)
	}
	if got, want := hex.EncodeToString(hash[:]), "9693532507cf1a58e91969588a3d987d8715e8a25dc1037b1f8d6e6980ed43c3"; got != want {
		t.Fatalf("hash = %s, want %s", got, want)
	}
}

func TestOutputFinishReasonEnum(t *testing.T) {
	for _, reason := range []string{"stop", "length", "tool_calls", "content_filter", "error"} {
		t.Run(reason, func(t *testing.T) {
			_, _, err := CanonicalOutput(responseWithContent("ok", reason))
			if err != nil {
				t.Fatalf("CanonicalOutput() error = %v", err)
			}
		})
	}
	_, _, err := CanonicalOutput(responseWithContent("ok", "stop_streaming"))
	if !errors.Is(err, ErrInvalidFinishReason) {
		t.Fatalf("CanonicalOutput() error = %v, want ErrInvalidFinishReason", err)
	}
}

func TestOutputEmptyAndMissingContentCanonicalizeToEmptyString(t *testing.T) {
	missing := map[string]any{"choices": []any{map[string]any{"message": map[string]any{}, "finish_reason": "stop"}}}
	null := map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": nil}, "finish_reason": "stop"}}}

	missingBytes, missingHash, err := CanonicalOutput(missing)
	if err != nil {
		t.Fatalf("CanonicalOutput(missing) error = %v", err)
	}
	nullBytes, nullHash, err := CanonicalOutput(null)
	if err != nil {
		t.Fatalf("CanonicalOutput(null) error = %v", err)
	}
	if !bytes.Equal(missingBytes, nullBytes) || missingHash != nullHash {
		t.Fatalf("missing and null content diverged:\nmissing %s\nnull %s", missingBytes, nullBytes)
	}
	if !strings.Contains(string(missingBytes), `"content":""`) {
		t.Fatalf("content did not canonicalize to empty string: %s", missingBytes)
	}
}

func TestOutputChoicesErrors(t *testing.T) {
	_, _, err := CanonicalOutput(map[string]any{})
	if !errors.Is(err, ErrMissingChoices) {
		t.Fatalf("missing choices error = %v", err)
	}
	_, _, err = CanonicalOutput(map[string]any{"choices": []any{}})
	if !errors.Is(err, ErrEmptyChoices) {
		t.Fatalf("empty choices error = %v", err)
	}
}

func TestOutputLineEndingNormalizationHashesSame(t *testing.T) {
	var first [32]byte
	for i, content := range []string{"Line 1\r\nCafe\u0301\r", "Line 1\nCafé\n", "Line 1\nCafe\u0301\n"} {
		_, hash, err := CanonicalOutput(responseWithContent(content, "stop"))
		if err != nil {
			t.Fatalf("CanonicalOutput(%d) error = %v", i, err)
		}
		if i == 0 {
			first = hash
			continue
		}
		if hash != first {
			t.Fatalf("hash %d = %x, want %x", i, hash, first)
		}
	}
}

func TestPrettyPrintedAndMinifiedJSONProduceSameCanonicalPrompt(t *testing.T) {
	minified := `{"model":"fixture-model","messages":[{"role":"user","content":"hello"}],"temperature":0.25,"stream":false}`
	pretty := `{
	  "stream": false,
	  "temperature": 0.25,
	  "messages": [
	    {
	      "content": "hello",
	      "role": "user"
	    }
	  ],
	  "model": "fixture-model"
	}`

	minReq := decodeMap(t, minified)
	prettyReq := decodeMap(t, pretty)
	minBytes, minHash, err := CanonicalPrompt(minReq)
	if err != nil {
		t.Fatalf("CanonicalPrompt(minified) error = %v", err)
	}
	prettyBytes, prettyHash, err := CanonicalPrompt(prettyReq)
	if err != nil {
		t.Fatalf("CanonicalPrompt(pretty) error = %v", err)
	}
	if !bytes.Equal(minBytes, prettyBytes) || minHash != prettyHash {
		t.Fatalf("pretty/minified diverged:\nmin=%s\npretty=%s", minBytes, prettyBytes)
	}
}

func decodeMap(t *testing.T, raw string) map[string]any {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.UseNumber()
	var out map[string]any
	if err := dec.Decode(&out); err != nil {
		t.Fatalf("decode JSON: %v", err)
	}
	return out
}

func responseWithContent(content, finishReason string) map[string]any {
	return map[string]any{
		"choices": []any{map[string]any{
			"message":       map[string]any{"content": content},
			"finish_reason": finishReason,
		}},
	}
}

func fixturePromptRequest() map[string]any {
	return map[string]any{
		"model": "fixture-model",
		"messages": []any{
			map[string]any{
				"role":    "system",
				"content": "Use Cafe\u0301\r\nrules",
				"name":    "sys",
			},
			map[string]any{
				"role": "user",
				"content": []any{
					map[string]any{"type": "text", "text": "Hello\rworld"},
					map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64,AAAA", "detail": "low"}},
					map[string]any{"type": "input_audio", "input_audio": map[string]any{"data": "QUJD", "format": "wav"}},
				},
			},
			map[string]any{
				"role":    "assistant",
				"content": nil,
				"tool_calls": []any{map[string]any{
					"id": "call_1",
					"function": map[string]any{
						"name":      "lookup",
						"arguments": `{"city":"Vilnius"}`,
					},
				}},
			},
			map[string]any{
				"role":         "tool",
				"tool_call_id": "call_1",
				"content":      "15 C",
			},
		},
		"tools": []any{map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        "lookup",
				"description": "Weather lookup",
				"parameters": map[string]any{
					"type":       "object",
					"properties": map[string]any{"city": map[string]any{"type": "string"}},
					"required":   []any{"city"},
				},
			},
		}},
		"temperature":       0.25,
		"top_p":             0.9,
		"max_tokens":        64,
		"stop":              []any{"END"},
		"seed":              42,
		"response_format":   map[string]any{"type": "json_object"},
		"tool_choice":       map[string]any{"type": "function", "function": map[string]any{"name": "lookup"}},
		"presence_penalty":  0.1,
		"frequency_penalty": -0.2,
		"logit_bias":        map[string]any{"123": -1},
		"logprobs":          true,
		"top_logprobs":      2,
		"n":                 1,
	}
}

func toolCallPrompt(arguments string) map[string]any {
	return map[string]any{
		"model": "fixture-model",
		"messages": []any{map[string]any{
			"role":    "assistant",
			"content": nil,
			"tool_calls": []any{map[string]any{
				"id": "call_1",
				"function": map[string]any{
					"name":      "lookup",
					"arguments": arguments,
				},
			}},
		}},
	}
}

func clonePrompt(in map[string]any, mutate func(map[string]any)) map[string]any {
	out := make(map[string]any, len(in))
	for key, value := range in {
		out[key] = value
	}
	mutate(out)
	return out
}
