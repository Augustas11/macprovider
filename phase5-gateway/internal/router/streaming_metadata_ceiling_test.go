package router

import (
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// honestPerTokenFrame is one per-token chunk as every lab engine emits it:
// about 230 bytes of JSON around one content byte.
const honestPerTokenFrame = `data: {"id":"chatcmpl-0123456789abcdef","object":"chat.completion.chunk","created":1790000000,"model":"mlx-community/Qwen2.5-0.5B-Instruct-4bit","system_fingerprint":"fp_lab","choices":[{"index":0,"delta":{"content":"x"},"logprobs":null,"finish_reason":null}]}`

func postMetadataCeilingStream(t *testing.T, accountID, body string, frames []string) string {
	t.Helper()
	payload := strings.Join(append(frames, `data: [DONE]`, ``), "\n\n")
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	resp := postChat(t, h, fullKey, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	return resp.Body.String()
}

// E2E-F2: a 400-token honest per-token stream (about 92 KiB of frame
// metadata) under max_tokens 700 reaches the buyer whole. Before the fix the
// fixed 64 KiB metadata ceiling cut it at about 280 frames with
// stream_output_exceeded, and the delivered part was free.
func TestStreamingMetadataCeilingScalesWithCompletionBudget(t *testing.T) {
	frames := make([]string, 0, 402)
	for i := 0; i < 400; i++ {
		frames = append(frames, honestPerTokenFrame)
	}
	frames = append(frames,
		`data: {"id":"chatcmpl-0123456789abcdef","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`,
		`data: {"id":"chatcmpl-0123456789abcdef","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":400,"total_tokens":409}}`,
	)
	body := `{"model":"llama","stream":true,"max_tokens":700,"messages":[{"role":"user","content":"count"}]}`
	got := postMetadataCeilingStream(t, "acct_metadata_ceiling_honest", body, frames)
	if strings.Contains(got, "stream_output_exceeded") {
		t.Fatalf("honest per-token stream was truncated: %d bytes, %d frames forwarded", len(got), strings.Count(got, `"content":"x"`))
	}
	if n := strings.Count(got, `"content":"x"`); n != 400 {
		t.Fatalf("forwarded %d content frames, want 400", n)
	}
	if !strings.HasSuffix(got, "data: [DONE]\n\n") {
		t.Fatalf("stream missing DONE terminator")
	}
}

// The ceiling still stops metadata padding: frames whose JSON is inflated
// far past what the completion budget allows are cut with
// stream_output_exceeded, as before.
func TestStreamingMetadataCeilingStillStopsPadding(t *testing.T) {
	padded := `data: {"id":"` + strings.Repeat("p", 16<<10) + `","choices":[{"index":0,"delta":{"content":"x"}}]}`
	frames := make([]string, 0, 8)
	for i := 0; i < 8; i++ {
		frames = append(frames, padded)
	}
	body := `{"model":"llama","stream":true,"max_tokens":10,"messages":[{"role":"user","content":"count"}]}`
	got := postMetadataCeilingStream(t, "acct_metadata_ceiling_padded", body, frames)
	if !strings.Contains(got, "stream_output_exceeded") {
		t.Fatalf("padded stream (8 x 16 KiB metadata, max_tokens 10) was not truncated")
	}
	if n := strings.Count(got, `"content":"x"`); n >= 8 {
		t.Fatalf("forwarded all %d padded frames", n)
	}
}
