package router

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

// Both adapters consume this fixture: updates must preserve the local/gateway
// subset rather than silently widening one surface's compatibility claim.
func TestLocalResponsesSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../test/fixtures/local-responses-contract.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Requests []struct {
			Name      string
			Request   json.RawMessage
			Chat      map[string]any
			ErrorCode string `json:"error_code"`
		}
		Streams []struct {
			Name       string
			Chunks     []json.RawMessage
			Terminal   string
			DeltaType  string `json:"delta_type"`
			Delta      string
			EventTypes []string `json:"event_types"`
			Response   map[string]any
		}
		Nonstream []struct {
			Name         string
			Request      json.RawMessage
			ChatResponse json.RawMessage `json:"chat_response"`
			Response     map[string]any
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Requests) == 0 || len(fixture.Streams) == 0 || len(fixture.Nonstream) == 0 {
		t.Fatal("empty shared contract")
	}
	for _, tc := range fixture.Requests {
		t.Run("request/"+tc.Name, func(t *testing.T) {
			a := newResponsesAdapter(httptest.NewRecorder(), "contract", nil)
			raw, failure := a.translateRequest(tc.Request)
			if tc.ErrorCode != "" {
				if failure == nil || failure.code != tc.ErrorCode {
					t.Fatalf("error=%v want %s", failure, tc.ErrorCode)
				}
				return
			}
			if failure != nil {
				t.Fatal(failure)
			}
			var got map[string]any
			if err := json.Unmarshal(raw, &got); err != nil {
				t.Fatal(err)
			}
			for key, want := range tc.Chat {
				if !reflect.DeepEqual(got[key], want) {
					t.Errorf("%s=%#v want %#v", key, got[key], want)
				}
			}
		})
	}
	for _, tc := range fixture.Streams {
		t.Run("stream/"+tc.Name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			a := newResponsesAdapter(recorder, "contract", nil)
			if _, failure := a.translateRequest([]byte(`{"model":"test-model","input":"hello","store":false,"stream":true}`)); failure != nil {
				t.Fatal(failure)
			}
			for _, chunk := range tc.Chunks {
				var compact bytes.Buffer
				if err := json.Compact(&compact, chunk); err != nil {
					t.Fatal(err)
				}
				if _, err := a.Write([]byte("data: " + compact.String() + "\n\n")); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := a.Write([]byte("data: [DONE]\n\n")); err != nil {
				t.Fatal(err)
			}
			a.finish()
			var delta strings.Builder
			terminal := ""
			sequence := float64(0)
			var eventTypes []string
			for _, line := range strings.Split(recorder.Body.String(), "\n") {
				if !strings.HasPrefix(line, "data: {") {
					continue
				}
				var event map[string]any
				if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event); err != nil {
					t.Fatal(err)
				}
				seq, ok := event["sequence_number"].(float64)
				if !ok || seq != sequence+1 {
					t.Fatalf("non-monotonic sequence: %#v", event)
				}
				sequence = seq
				typ, _ := event["type"].(string)
				eventTypes = append(eventTypes, typ)
				if typ == tc.DeltaType {
					text, _ := event["delta"].(string)
					delta.WriteString(text)
				}
				if typ == "response.completed" || typ == "response.failed" || typ == "response.incomplete" {
					if terminal != "" {
						t.Fatalf("multiple terminal events: %s then %s", terminal, typ)
					}
					terminal = typ
					assertLocalResponsesSubset(t, event["response"], tc.Response, "response")
				}
			}
			if !reflect.DeepEqual(eventTypes, tc.EventTypes) {
				t.Errorf("events=%v want %v", eventTypes, tc.EventTypes)
			}
			if terminal != tc.Terminal {
				t.Errorf("terminal=%s want %s", terminal, tc.Terminal)
			}
			if delta.String() != tc.Delta {
				t.Errorf("delta=%q want %q", delta.String(), tc.Delta)
			}
		})
	}
	for _, tc := range fixture.Nonstream {
		t.Run("nonstream/"+tc.Name, func(t *testing.T) {
			a := newResponsesAdapter(httptest.NewRecorder(), "contract", nil)
			if _, failure := a.translateRequest(tc.Request); failure != nil {
				t.Fatal(failure)
			}
			raw, err := a.translateNonStreamingResponse(tc.ChatResponse)
			if err != nil {
				t.Fatal(err)
			}
			var got any
			if err := json.Unmarshal(raw, &got); err != nil {
				t.Fatal(err)
			}
			assertLocalResponsesSubset(t, got, tc.Response, "response")
		})
	}

}

// Dictionaries are subsets so generated IDs/timestamps stay implementation-owned;
// arrays are exact in length and order, preserving tool and text item semantics.
func assertLocalResponsesSubset(t *testing.T, got, want any, path string) {
	t.Helper()
	switch expected := want.(type) {
	case map[string]any:
		actual, ok := got.(map[string]any)
		if !ok {
			t.Fatalf("%s: expected object, got %#v", path, got)
		}
		for key, value := range expected {
			item, exists := actual[key]
			if !exists {
				t.Errorf("%s.%s absent", path, key)
				continue
			}
			assertLocalResponsesSubset(t, item, value, path+"."+key)
		}
	case []any:
		actual, ok := got.([]any)
		if !ok || len(actual) != len(expected) {
			t.Fatalf("%s: array=%#v want %#v", path, got, want)
		}
		for i, value := range expected {
			assertLocalResponsesSubset(t, actual[i], value, fmt.Sprintf("%s[%d]", path, i))
		}
	default:
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s=%#v want %#v", path, got, want)
		}
	}
}
