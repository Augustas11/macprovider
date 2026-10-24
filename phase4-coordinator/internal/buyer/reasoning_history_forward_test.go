package buyer

import (
	"encoding/json"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// Assistant-history reasoning_content (from a Responses `reasoning` item or a
// Chat Completions client) reaches the provider body unchanged, both when the
// request is forwarded verbatim and when message normalization re-encodes it.
func TestValidatedChatRequestForwardsAssistantReasoningContent(t *testing.T) {
	for name, userContent := range map[string]string{
		"verbatim":   `"q"`,
		"normalized": `[{"type":"text","text":"q"}]`,
	} {
		t.Run(name, func(t *testing.T) {
			body := `{"model":"m","messages":[
				{"role":"user","content":` + userContent + `},
				{"role":"assistant","content":null,"reasoning_content":"look first","tool_calls":[{"id":"call_aaaaaaaaaaaaaaaa","type":"function","function":{"name":"exec","arguments":"{}"}}]},
				{"role":"tool","tool_call_id":"call_aaaaaaaaaaaaaaaa","content":"ok"}
			],"tools":[{"type":"function","function":{"name":"exec","parameters":{"type":"object"}}}]}`
			req, status, code, msg, _ := validateChatRequestDetailed([]byte(body))
			if status != 0 {
				t.Fatalf("status=%d code=%s msg=%s", status, code, msg)
			}
			forwarded, err := dispatchBodyForProvider(req, pool.Provider{ModelID: "provider/m"})
			if err != nil {
				t.Fatal(err)
			}
			var got struct {
				Messages []map[string]any `json:"messages"`
			}
			if err := json.Unmarshal(forwarded, &got); err != nil {
				t.Fatal(err)
			}
			if r := got.Messages[1]["reasoning_content"]; r != "look first" {
				t.Fatalf("forwarded assistant reasoning_content=%v body=%s", r, forwarded)
			}
		})
	}
}
