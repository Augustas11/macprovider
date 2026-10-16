package router

import (
	"bytes"
	"encoding/json"
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
			Name      string
			Chunks    []json.RawMessage
			Terminal  string
			DeltaType string `json:"delta_type"`
			Delta     string
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Requests) == 0 || len(fixture.Streams) == 0 {
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
			sequence := float64(-1)
			for _, line := range strings.Split(recorder.Body.String(), "\n") {
				if !strings.HasPrefix(line, "data: {") {
					continue
				}
				var event map[string]any
				if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event); err != nil {
					t.Fatal(err)
				}
				seq, ok := event["sequence_number"].(float64)
				if !ok || seq <= sequence {
					t.Fatalf("non-monotonic sequence: %#v", event)
				}
				sequence = seq
				typ, _ := event["type"].(string)
				if typ == tc.DeltaType {
					text, _ := event["delta"].(string)
					delta.WriteString(text)
				}
				if typ == "response.completed" || typ == "response.failed" || typ == "response.incomplete" {
					if terminal != "" {
						t.Fatalf("multiple terminal events: %s then %s", terminal, typ)
					}
					terminal = typ
				}
			}
			if terminal != tc.Terminal {
				t.Errorf("terminal=%s want %s", terminal, tc.Terminal)
			}
			if delta.String() != tc.Delta {
				t.Errorf("delta=%q want %q", delta.String(), tc.Delta)
			}
		})
	}
}
