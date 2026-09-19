package buyer

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

const streamingToolsChatBody = `{"model":"model-a","stream":true,"messages":[{"role":"user","content":"run echo hello"}],"tools":[{"type":"function","function":{"name":"bash","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}}]}`

const providerCompleteToolJSON = `{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo hello\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":12,"completion_tokens":8,"total_tokens":20}}`

func TestRewriteJSONBoolFieldStreamFalse(t *testing.T) {
	got, err := rewriteJSONBoolField([]byte(`{"model":"m","stream":true,"messages":[]}`), "stream", false)
	if err != nil {
		t.Fatalf("rewriteJSONBoolField: %v", err)
	}
	if string(got) != `{"model":"m","stream":false,"messages":[]}` {
		t.Fatalf("rewritten body = %s", got)
	}
}

func TestChatRequestDeclaresTools(t *testing.T) {
	if !chatRequestDeclaresTools([]byte(streamingToolsChatBody)) {
		t.Fatal("expected tools to be declared")
	}
	if chatRequestDeclaresTools([]byte(`{"model":"m","messages":[{"role":"user","content":"hi"}],"stream":true}`)) {
		t.Fatal("plain chat must not declare tools")
	}
}

func TestChatCompletionJSONToSSEConcatenatesCompleteToolArguments(t *testing.T) {
	sse, err := chatCompletionJSONToSSE([]byte(providerCompleteToolJSON))
	if err != nil {
		t.Fatalf("chatCompletionJSONToSSE: %v", err)
	}
	got := concatSSEToolArguments(t, sse)
	if got != `{"command":"echo hello"}` {
		t.Fatalf("concatenated arguments = %q", got)
	}
	if bytes.Contains(sse, []byte(`{}{"command"`)) {
		t.Fatalf("SSE glued empty object onto arguments: %s", sse)
	}
}

func TestStreamingToolsWSCoalescesFleetEmptyObject(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWSStreamingTestProvider(registry, "provider-x", "session-1", "model-a")

	var providerStream bool
	var bodyStream any
	relayCalled := false
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			relayCalled = true
			providerStream = stream
			var req map[string]any
			if err := json.Unmarshal(body, &req); err != nil {
				t.Fatalf("provider body json: %v", err)
			}
			bodyStream = req["stream"]
			chunks := make(chan providerws.InferenceResponseChunk)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			go sendFleetStreamingToolSSE(chunks, done, requestID)
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postRawChat(t, server, []byte(streamingToolsChatBody))
	if !relayCalled {
		t.Fatal("expected provider relay to be invoked")
	}
	if !providerStream {
		t.Fatal("provider envelope stream must stay true so the Mac can flush role/name-open")
	}
	if bodyStream != true {
		t.Fatalf("provider body stream = %v, want true", bodyStream)
	}
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Header().Get("Content-Type"), "text/event-stream") {
		t.Fatalf("content-type = %q, want SSE", rr.Header().Get("Content-Type"))
	}
	if !strings.Contains(rr.Body.String(), `"name":"bash"`) {
		t.Fatalf("buyer SSE missing name-open: %s", rr.Body.String())
	}
	got := concatSSEToolArguments(t, rr.Body.Bytes())
	if got != `{"command":"echo hello"}` {
		t.Fatalf("buyer concatenated arguments = %q body=%s", got, rr.Body.String())
	}
	if strings.Contains(got, "{}{") {
		t.Fatalf("Pi concat glued empty object onto arguments: %s", rr.Body.String())
	}
}

func TestStreamingWithoutToolsKeepsProviderStream(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWSStreamingTestProvider(registry, "provider-x", "session-1", "model-a")

	var providerStream bool
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			providerStream = stream
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{
				Type:      "inference_response_chunk",
				RequestID: requestID,
				Seq:       0,
				Data:      "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n",
			}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postRawChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"stream":true}`))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rr.Code, rr.Body.String())
	}
	if !providerStream {
		t.Fatal("plain streaming chat must keep provider stream=true")
	}
}

func TestStreamingToolsHTTPCoalescesFleetEmptyObject(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("upstream json: %v", err)
		}
		if req["stream"] != true {
			t.Fatalf("upstream stream = %v, want true", req["stream"])
		}
		w.Header().Set("Content-Type", "text/event-stream")
		for _, data := range fleetStreamingToolSSE("req-http") {
			_, _ = w.Write([]byte(data))
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
		}
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "provider-x", EndpointURL: upstream.URL}})
	registerStreamingTestProvider(registry, "provider-x", "session-1", "model-a", upstream.URL)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postRawChat(t, server, []byte(streamingToolsChatBody))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Header().Get("Content-Type"), "text/event-stream") {
		t.Fatalf("content-type = %q, want SSE", rr.Header().Get("Content-Type"))
	}
	got := concatSSEToolArguments(t, rr.Body.Bytes())
	if got != `{"command":"echo hello"}` {
		t.Fatalf("buyer concatenated arguments = %q body=%s", got, rr.Body.String())
	}
}

func TestStreamingToolsBufferedKillSwitchCoalescesFleetEmptyObject(t *testing.T) {
	t.Setenv("COORDINATOR_STREAMING_FORCE_BUFFERED", "1")
	registry := pool.NewRegistry(nil)
	registerWSStreamingTestProvider(registry, "provider-x", "session-1", "model-a")
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			go sendFleetStreamingToolSSE(chunks, done, requestID)
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)
	rr := postRawChat(t, server, []byte(streamingToolsChatBody))
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get(streamingModeHeader) != streamingModeBufferedKillSwitch {
		t.Fatalf("streaming mode = %q, want %s", rr.Header().Get(streamingModeHeader), streamingModeBufferedKillSwitch)
	}
	got := concatSSEToolArguments(t, rr.Body.Bytes())
	if got != `{"command":"echo hello"}` {
		t.Fatalf("buffered concat arguments=%q body=%s", got, rr.Body.String())
	}
}

func TestStreamingToolsHTTPJSONFallbackStillMaterializes(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(providerCompleteToolJSON))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "provider-x", EndpointURL: upstream.URL}})
	registerStreamingTestProvider(registry, "provider-x", "session-1", "model-a", upstream.URL)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postRawChat(t, server, []byte(streamingToolsChatBody))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rr.Code, rr.Body.String())
	}
	got := concatSSEToolArguments(t, rr.Body.Bytes())
	if got != `{"command":"echo hello"}` {
		t.Fatalf("buyer concatenated arguments = %q body=%s", got, rr.Body.String())
	}
}

const piShapedStreamingToolsBody = `{
  "model":"model-a",
  "stream":true,
  "stream_options":{"include_usage":true},
  "enable_thinking":false,
  "tool_choice":"required",
  "messages":[{"role":"user","content":"Run bash with command echo hello. Do not explain."}],
  "tools":[{
    "type":"function",
    "function":{
      "name":"bash",
      "description":"Run a shell command",
      "strict":false,
      "parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
    }
  }]
}`

func TestToolChoiceRequiredRewrittenToAuto(t *testing.T) {
	got := neutralizeUnsupportedToolChoice([]byte(`{"model":"m","tool_choice":"required","messages":[]}`))
	if string(got) != `{"model":"m","tool_choice":"auto","messages":[]}` {
		t.Fatalf("rewritten = %s", got)
	}
	unchanged := neutralizeUnsupportedToolChoice([]byte(`{"model":"m","tool_choice":"auto","messages":[]}`))
	if string(unchanged) != `{"model":"m","tool_choice":"auto","messages":[]}` {
		t.Fatalf("auto rewritten unexpectedly: %s", unchanged)
	}
}

func TestEmptyObjectIsCompleteJSONForPiClient(t *testing.T) {
	// Pi openai-completions concatenates function.arguments and calls
	// parseStreamingJson. JSON.parse("{}") succeeds, so an opening empty
	// object is treated as a finished tool call (bash with no command).
	var obj map[string]any
	if err := json.Unmarshal([]byte("{}"), &obj); err != nil {
		t.Fatalf("Pi would not treat {} as complete JSON: %v", err)
	}
	if len(obj) != 0 {
		t.Fatalf("expected empty object, got %#v", obj)
	}
	concat := `{}{"command":"echo hello"}`
	if json.Valid([]byte(concat)) {
		t.Fatal("concat of {} plus a second object must stay invalid JSON")
	}
}

func TestPiShapedStreamingToolRequestIsAdmittedAndCoalescesArgs(t *testing.T) {
	_, status, code, msg := validateChatRequest([]byte(piShapedStreamingToolsBody))
	if status != 0 {
		t.Fatalf("Pi-shaped request rejected status=%d code=%s msg=%s", status, code, msg)
	}

	registry := pool.NewRegistry(nil)
	registerWSStreamingTestProvider(registry, "provider-x", "session-1", "model-a")
	var providerStream bool
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			providerStream = stream
			var req map[string]any
			if err := json.Unmarshal(body, &req); err != nil {
				t.Fatalf("provider body json: %v", err)
			}
			if req["stream"] != true {
				t.Fatalf("provider body stream=%v want true", req["stream"])
			}
			if req["tool_choice"] != "auto" {
				t.Fatalf("provider tool_choice=%v want auto (required is rewritten)", req["tool_choice"])
			}
			if _, ok := req["stream_options"]; !ok {
				t.Fatal("stream_options must be forwarded")
			}
			if _, ok := req["tools"]; !ok {
				t.Fatal("tools must be forwarded")
			}
			chunks := make(chan providerws.InferenceResponseChunk)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			go sendFleetStreamingToolSSE(chunks, done, requestID)
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postRawChat(t, server, []byte(piShapedStreamingToolsBody))
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !providerStream {
		t.Fatal("Pi always streams; coordinator must keep provider stream=true")
	}
	got := concatSSEToolArguments(t, rr.Body.Bytes())
	if got != `{"command":"echo hello"}` {
		t.Fatalf("Pi-concatenated arguments=%q body=%s", got, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"usage"`) {
		t.Fatalf("Pi requested stream_options.include_usage; buyer SSE missing usage: %s", rr.Body.String())
	}
}

const providerLeakedQwenXMLJSON = `{
  "id":"chatcmpl-test",
  "object":"chat.completion",
  "created":1716768000,
  "model":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
  "choices":[{
    "index":0,
    "message":{
      "role":"assistant",
      "content":"Let me look at the issue to understand what needs to be inspected:\n\n<tool_call>\n<function=bash>\n<parameter=command>\necho hello\n</parameter>\n</function>\n<tool_call>"
    },
    "finish_reason":"stop"
  }],
  "usage":{"prompt_tokens":12,"completion_tokens":57,"total_tokens":69}
}`

func TestStreamingToolsWSRecoversLeakedQwenFunctionXML(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWSStreamingTestProvider(registry, "provider-x", "session-1", "model-a")

	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{
				Type:      "inference_response_chunk",
				RequestID: requestID,
				Seq:       0,
				Data:      providerLeakedQwenXMLJSON,
			}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postRawChat(t, server, []byte(streamingToolsChatBody))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rr.Code, rr.Body.String())
	}
	got := concatSSEToolArguments(t, rr.Body.Bytes())
	if got != `{"command":"echo hello"}` {
		t.Fatalf("buyer concatenated arguments = %q body=%s", got, rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), "<function=") {
		t.Fatalf("native function-XML leaked to buyer SSE: %s", rr.Body.String())
	}
}

func TestPiMultiTurnToolResultReplay(t *testing.T) {
	turn2, err := json.Marshal(map[string]any{
		"model":          "model-a",
		"stream":         true,
		"stream_options": map[string]any{"include_usage": true},
		"messages": []map[string]any{
			{"role": "user", "content": "Run bash with command echo hello."},
			{
				"role":    "assistant",
				"content": nil,
				"tool_calls": []map[string]any{{
					"id":   "call_0123456789abcdef",
					"type": "function",
					"function": map[string]any{
						"name":      "bash",
						"arguments": `{"command":"echo hello"}`,
					},
				}},
			},
			{
				"role":         "tool",
				"tool_call_id": "call_0123456789abcdef",
				"name":         "bash",
				"content":      "hello\n",
			},
		},
		"tools": []map[string]any{{
			"type": "function",
			"function": map[string]any{
				"name":       "bash",
				"parameters": map[string]any{"type": "object", "properties": map[string]any{"command": map[string]any{"type": "string"}}},
			},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, status, code, msg := validateChatRequest(turn2)
	if status != 0 {
		t.Fatalf("turn-2 Pi replay rejected status=%d code=%s msg=%s", status, code, msg)
	}

	registry := pool.NewRegistry(nil)
	registerWSStreamingTestProvider(registry, "provider-x", "session-1", "model-a")
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			if !stream {
				t.Fatal("turn-2 still declares tools; provider stream must stay true")
			}
			chunks := make(chan providerws.InferenceResponseChunk, 2)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{
				Type:      "inference_response_chunk",
				RequestID: requestID,
				Seq:       0,
				Data:      `data: {"id":"chatcmpl-turn2","choices":[{"index":0,"delta":{"role":"assistant","content":"hello"},"finish_reason":null}]}` + "\n\n",
			}
			chunks <- providerws.InferenceResponseChunk{
				Type:      "inference_response_chunk",
				RequestID: requestID,
				Seq:       1,
				Data:      `data: {"id":"chatcmpl-turn2","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}` + "\n\ndata: [DONE]\n\n",
			}
			close(chunks)
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 2}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)
	rr := postRawChat(t, server, turn2)
	if rr.Code != http.StatusOK {
		t.Fatalf("turn-2 status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Header().Get("Content-Type"), "text/event-stream") {
		t.Fatalf("turn-2 content-type=%q", rr.Header().Get("Content-Type"))
	}
	if !strings.Contains(rr.Body.String(), `"content":"hello"`) {
		t.Fatalf("turn-2 missing assistant content: %s", rr.Body.String())
	}
}

func TestStreamingToolsWSFlushesNameOpenBeforeFinish(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWSStreamingTestProvider(registry, "provider-x", "session-1", "model-a")

	releaseRest := make(chan struct{})
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 8)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{
				Type: "inference_response_chunk", RequestID: requestID, Seq: 0,
				Data: `data: {"id":"chatcmpl-test","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}` + "\n\n",
			}
			chunks <- providerws.InferenceResponseChunk{
				Type: "inference_response_chunk", RequestID: requestID, Seq: 1,
				Data: `data: {"id":"chatcmpl-test","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":"{}"}}]},"finish_reason":null}]}` + "\n\n",
			}
			go func() {
				<-releaseRest
				chunks <- providerws.InferenceResponseChunk{
					Type: "inference_response_chunk", RequestID: requestID, Seq: 2,
					Data: `data: {"id":"chatcmpl-test","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"echo hello\"}"}}]},"finish_reason":null}]}` + "\n\n",
				}
				chunks <- providerws.InferenceResponseChunk{
					Type: "inference_response_chunk", RequestID: requestID, Seq: 3,
					Data: `data: {"id":"chatcmpl-test","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}` + "\n\ndata: [DONE]\n\n",
				}
				close(chunks)
				done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 4}
			}()
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader([]byte(streamingToolsChatBody)))
	firstWrite := make(chan struct{})
	w := &firstWriteRecorder{ResponseRecorder: httptest.NewRecorder(), firstWrite: firstWrite}
	done := make(chan struct{})
	go func() {
		server.Handler().ServeHTTP(w, req)
		close(done)
	}()
	select {
	case <-firstWrite:
	case <-time.After(2 * time.Second):
		t.Fatal("buyer received no SSE bytes until the Mac finished generating")
	}
	close(releaseRest)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("request did not complete after remaining chunks")
	}
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), `"name":"bash"`) {
		t.Fatalf("missing name-open: %s", w.Body.String())
	}
	got := concatSSEToolArguments(t, w.Body.Bytes())
	if got != `{"command":"echo hello"}` {
		t.Fatalf("concatenated arguments=%q body=%s", got, w.Body.String())
	}
}

type firstWriteRecorder struct {
	*httptest.ResponseRecorder
	firstWrite chan struct{}
	once       sync.Once
}

func (w *firstWriteRecorder) Write(p []byte) (int, error) {
	n, err := w.ResponseRecorder.Write(p)
	if n > 0 {
		w.once.Do(func() { close(w.firstWrite) })
	}
	return n, err
}

func (w *firstWriteRecorder) Flush() {}

func sendFleetStreamingToolSSE(chunks chan providerws.InferenceResponseChunk, done chan providerws.InferenceResponseEnd, requestID string) {
	for i, data := range fleetStreamingToolSSE(requestID) {
		chunks <- providerws.InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: requestID,
			Seq:       i,
			Data:      data,
		}
	}
	done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 5}
}

func fleetStreamingToolSSE(requestID string) []string {
	_ = requestID
	return []string{
		`data: {"id":"chatcmpl-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}` + "\n\n",
		`data: {"id":"chatcmpl-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":"{}"}}]},"finish_reason":null}]}` + "\n\n",
		`data: {"id":"chatcmpl-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"echo hello\"}"}}]},"finish_reason":null}]}` + "\n\n",
		`data: {"id":"chatcmpl-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":12,"completion_tokens":8,"total_tokens":20}}` + "\n\n",
		"data: [DONE]\n\n",
	}
}

func registerWSStreamingTestProvider(registry *pool.Registry, providerID, assignedID, modelID string) {
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               modelID,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathWSTunneled,
		State:                 pool.StateReady,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		BinaryVersion:         "0.2.0",
	}, nil)
}

func postRawChat(t *testing.T, server *Server, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}

func concatSSEToolArguments(t *testing.T, raw []byte) string {
	t.Helper()
	var out strings.Builder
	for _, line := range bytes.Split(raw, []byte("\n")) {
		trimmed := bytes.TrimSpace(line)
		if !bytes.HasPrefix(trimmed, []byte("data:")) {
			continue
		}
		payload := bytes.TrimSpace(trimmed[len("data:"):])
		if len(payload) == 0 || bytes.Equal(payload, []byte("[DONE]")) {
			continue
		}
		var event struct {
			Choices []struct {
				Delta struct {
					ToolCalls []struct {
						Function struct {
							Arguments *string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal(payload, &event); err != nil {
			t.Fatalf("sse json: %v payload=%s", err, payload)
		}
		for _, choice := range event.Choices {
			for _, call := range choice.Delta.ToolCalls {
				if call.Function.Arguments != nil {
					out.WriteString(*call.Function.Arguments)
				}
			}
		}
	}
	return out.String()
}
