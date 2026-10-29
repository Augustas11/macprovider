package router

import (
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestStreamingFinishFollowsLateToolAndContent(t *testing.T) {
	lines := []string{
		`data: {"id":"chatcmpl_order","choices":[{"index":0,"delta":{"content":"before"},"finish_reason":"stop"}]}`,
		`data: {"id":"chatcmpl_order","choices":[{"index":0,"delta":{"content":"after"}}]}`,
		`data: {"id":"chatcmpl_order","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_order","type":"function","function":{"name":"lookup","arguments":"{}"}}]}}]}`,
		`data: [DONE]`, "",
	}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		resp := responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream"}}, strings.Join(lines, "\n\n"))
		resp.Body = io.NopCloser(&orderingFragmentReader{reader: strings.NewReader(strings.Join(lines, "\n\n"))})
		return resp, nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		c.Coordinator.BuyerURL = "http://coordinator.test"
		c.Features.ResponsesAPIEnabled = true
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_order")
	resp := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":100,"messages":[{"role":"user","content":"x"}]}`, nil)
	body := resp.Body.String()
	finish := strings.Index(body, `"finish_reason":"tool_calls"`)
	tool := strings.Index(body, `"name":"lookup"`)
	if resp.Code != 200 || tool < 0 || finish < tool || strings.Index(body, `"content":"after"`) < 0 || strings.Index(body, `"content":"after"`) > finish {
		t.Fatalf("finish must follow preserved content and tools with tool_calls reason: %s", body)
	}

	responses := postResponses(t, h, key, `{"model":"llama","stream":true,"max_output_tokens":100,"input":"x"}`, nil)
	rbody := responses.Body.String()
	terminal := strings.Index(rbody, "event: response.completed")
	toolDone := strings.Index(rbody, "event: response.function_call_arguments.done")
	if responses.Code != http.StatusOK || terminal < 0 || toolDone < 0 || toolDone > terminal || !strings.Contains(rbody, `"delta":"after"`) || strings.Contains(rbody[terminal:], ".delta") {
		t.Fatalf("Responses must preserve late data before completed: %s", rbody)
	}

}

func TestResponsesTerminalIsLastDespiteLateProviderData(t *testing.T) {
	body := runResponsesStream(t,
		`data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}`,
		`data: [DONE]`,
		`data: {"choices":[{"delta":{"content":"late"}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_late","function":{"name":"lookup","arguments":"{}"}}]}}]}`,
	)
	terminal := strings.Index(body, "event: response.completed")
	if terminal < 0 || strings.Contains(body[terminal:], ".delta") || strings.Contains(body[terminal:], "output_item.added") {
		t.Fatalf("output emitted after terminal: %s", body)
	}
}

func TestStreamOrderingPreservesUsageAndRejectsAmbiguousTerminals(t *testing.T) {
	var ordering streamOrdering
	first, err := ordering.observe([]byte(`data: {"choices":[{"index":0,"delta":{"content":"x"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}` + "\n"))
	if err != nil || len(first) != 0 {
		t.Fatalf("initial=%s err=%v", first, err)
	}
	done, err := ordering.observe([]byte("data: [DONE]\n"))
	if err != nil || len(done) != 2 || !strings.Contains(string(done[0]), `"usage"`) || !strings.Contains(string(done[0]), `"finish_reason":"stop"`) {
		t.Fatalf("terminal=%s err=%v", done, err)
	}
	if _, err = ordering.observe([]byte(`data: {"choices":[{"delta":{"content":"late"}}]}`)); err == nil {
		t.Fatal("post-DONE data must fail explicitly")
	}
	for _, input := range []string{
		`data: {"choices":[{"finish_reason":"stop"},{"finish_reason":"stop"}]}`,
		`data: {"choices":[{"finish_reason":true}]}`,
		`data: {"choices":[{"finish_reason":""}]}`,
	} {
		var s streamOrdering
		if _, err := s.observe([]byte(input)); err == nil {
			t.Fatal("ambiguous choices must fail")
		}
	}
	var duplicate streamOrdering
	finish := []byte(`data: {"choices":[{"delta":{},"finish_reason":"stop"}]}`)
	_, _ = duplicate.observe(finish)
	if _, err := duplicate.observe(finish); err == nil {
		t.Fatal("duplicate finish must fail")
	}
	var failed streamOrdering
	_, _ = failed.observe(finish)
	_, _ = failed.observe([]byte(`data: {"error":{"code":"provider_error"}}`))
	flushed, err := failed.flush()
	if err != nil || len(flushed) != 0 {
		t.Fatalf("error must discard pending successful finish: %s %v", flushed, err)
	}
}

func TestStreamOrderingEOFFlushesFinishAfterTool(t *testing.T) {
	var s streamOrdering
	_, err := s.observe([]byte(`data: {"choices":[{"delta":{},"finish_reason":"stop"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.observe([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"lookup","arguments":"{}"}}]}}]}`))
	if err != nil {
		t.Fatal(err)
	}
	lines, err := s.flush()
	if err != nil || len(lines) != 1 || !strings.Contains(string(lines[0]), `"finish_reason":"tool_calls"`) {
		t.Fatalf("EOF finish=%s err=%v", lines, err)
	}
	if next, _ := s.flush(); len(next) != 0 {
		t.Fatal("finish emitted twice")
	}
}

// Force SSE JSON frames and separators across transport reads.
type orderingFragmentReader struct{ reader *strings.Reader }

func (r *orderingFragmentReader) Read(p []byte) (int, error) {
	if len(p) > 7 {
		p = p[:7]
	}
	return r.reader.Read(p)
}

func TestStreamOrderingDoesNotPromoteTruncatedTools(t *testing.T) {
	for _, reason := range []string{"length", "content_filter"} {
		for _, messages := range []bool{false, true} {
			s := streamOrdering{preserveIncompleteTools: messages}
			_, err := s.observe([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_short","type":"function","function":{"name":"lookup","arguments":"{}"}}]}}]}`))
			if err != nil {
				t.Fatal(err)
			}
			_, err = s.observe([]byte(`data: {"choices":[{"delta":{},"finish_reason":"` + reason + `"}]}`))
			if err != nil {
				t.Fatal(err)
			}
			terminal, err := s.flush()
			if !messages {
				if err == nil {
					t.Fatalf("OpenAI truncated tool must fail explicitly: %s", terminal)
				}
				continue
			}
			if err != nil || len(terminal) != 1 || !strings.Contains(string(terminal[0]), `"finish_reason":"`+reason+`"`) {
				t.Fatalf("Messages truncation changed: %s %v", terminal, err)
			}
		}
	}
}

func TestStreamOrderingRejectsDuplicateKeysBeforeFinishRewrite(t *testing.T) {
	for _, frame := range []string{
		`data: {"choices":[{"delta":{"content":"hidden","content":"shown"},"finish_reason":"stop"}]}`,
		`data: {"choices":[{"delta":{},"finish_reason":"length","finish_reason":"stop"}]}`,
		`data: {"choices":[{"delta":{},"finish_reason":"length"}],"choices":[{"delta":{},"finish_reason":"stop"}]}`,
	} {
		var s streamOrdering
		if _, err := s.observe([]byte(frame)); err == nil {
			t.Fatalf("duplicate erased: %s", frame)
		}
	}
}

func TestStreamingTruncatedToolsFailChatAndResponses(t *testing.T) {
	for _, reason := range []string{"length", "content_filter"} {
		t.Run(reason, func(t *testing.T) {
			stream := `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_short","type":"function","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":"` + reason + `"}]}` + "\n\ndata: [DONE]\n\n"
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return responseWithBody(200, http.Header{"Content-Type": []string{"text/event-stream"}}, stream), nil
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Coordinator.BuyerURL = "http://coordinator.test"
				c.Features.ResponsesAPIEnabled = true
			}, WithHTTPClient(client))
			key := createAccountAndKey(t, store, cfg, "acct_truncated_"+reason)
			chat := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":100,"messages":[{"role":"user","content":"x"}]}`, nil).Body.String()
			if !strings.Contains(chat, `"code":"stream_malformed"`) || strings.Contains(chat, `"finish_reason":"tool_calls"`) {
				t.Fatalf("truncated chat succeeded: %s", chat)
			}
			responses := postResponses(t, h, key, `{"model":"llama","stream":true,"max_output_tokens":100,"input":"x"}`, nil).Body.String()
			if !strings.Contains(responses, "event: response.failed") || strings.Contains(responses, "event: response.completed") {
				t.Fatalf("truncated Responses succeeded: %s", responses)
			}
		})
	}
}

func TestStreamOrderingRawTerminalIsBoundedAndUnchanged(t *testing.T) {
	var s streamOrdering
	raw := []byte("data: { \"choices\": [{\"delta\":{\"content\":\"ok\"}, \"finish_reason\":\"stop\"}] }\r\n")
	_, err := s.observe(raw)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.observe([]byte("\r\n"))
	if err != nil {
		t.Fatal(err)
	}
	flushed, err := s.flush()
	if err != nil || len(flushed) != 1 || string(flushed[0]) != string(raw)+"\r\n" {
		t.Fatalf("ordinary terminal bytes changed: %q %v", flushed, err)
	}
	_, _ = s.observe(raw)
	_, err = s.observe([]byte(strings.Repeat(" ", maxStreamingLineBytes) + "\n"))
	if err == nil {
		t.Fatal("cumulative pending terminal must stay bounded")
	}
}
