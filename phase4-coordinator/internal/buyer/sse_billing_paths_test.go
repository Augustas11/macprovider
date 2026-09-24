package buyer

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// Cancel-fix audit R4: every SSE path bills from one delivered-events
// accounting. Each scenario is driven through the HTTP incremental, HTTP
// buffered, WS incremental, and WS buffered paths (the buffered paths also run
// tool-call materialization) in LF and CRLF framing, and must bill identically.

const (
	sseE1   = `data: {"id":"c","choices":[{"delta":{"content":"Hello"}}]}`
	sseE2   = `data: {"id":"c","choices":[{"delta":{"content":" world"},"finish_reason":"stop"}]}`
	sseU52  = `data: {"id":"c","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}`
	sseU53  = `data: {"id":"c","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}`
	sseE1U  = `data: {"id":"c","choices":[{"delta":{"content":"Hello"}}],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}`
	sseE2U  = `data: {"id":"c","choices":[{"delta":{"content":" world"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}`
	sseT1   = `data: {"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"read","arguments":"{\"path\":\"Makefile\"}"}}]}}]}`
	sseTF   = `data: {"id":"c","choices":[{"delta":{},"finish_reason":"tool_calls"}]}`
	sseDONE = `data: [DONE]`
)

type sseBillingScenario struct {
	name     string
	events   []string // terminated provider events
	tail     string   // an unterminated final provider event, if any
	endUsage string   // the WS provider end frame's usage (provider-side)
	stall    bool     // the provider stalls after events; the buyer cancels
	budget   int      // buyer writer byte budget; 0 is unlimited
	// expected billing (identical on every path)
	prompt, completion int64 // -1: none
	// expected settled content per path class
	incrementalContent, bufferedContent string
	toolCalls                           int
}

type sseBillingPath struct {
	name     string
	buffered bool
	run      func(t *testing.T, sc sseBillingScenario, nl string) requestLogAttempt
}

func sseFrame(sc sseBillingScenario, nl string) (events []string, tail string) {
	for _, e := range sc.events {
		events = append(events, e+nl+nl)
	}
	if sc.tail != "" {
		tail = sc.tail + nl
	}
	return events, tail
}

type budgetWriter struct {
	*httptest.ResponseRecorder
	budget int
}

func (w *budgetWriter) Write(p []byte) (int, error) {
	if w.budget < 0 {
		return w.ResponseRecorder.Write(p)
	}
	n := len(p)
	if n > w.budget {
		n = w.budget
	}
	_, _ = w.ResponseRecorder.Write(p[:n])
	w.budget -= n
	if n < len(p) {
		return n, errors.New("buyer connection reset")
	}
	return n, nil
}

func sseBillingWriter(sc sseBillingScenario, nl string) *budgetWriter {
	w := &budgetWriter{ResponseRecorder: httptest.NewRecorder(), budget: -1}
	if sc.budget > 0 {
		// The budget covers exactly the first event as framed.
		w.budget = len(sc.events[0] + nl + nl)
	}
	return w
}

var sseBillingBody = []byte(`{"model":"llama","stream":true,"messages":[{"role":"user","content":"hi"}]}`)

func sseBillingPaths() []sseBillingPath {
	return []sseBillingPath{
		{name: "http-incremental", run: func(t *testing.T, sc sseBillingScenario, nl string) requestLogAttempt {
			events, tail := sseFrame(sc, nl)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(strings.Join(events, "") + tail))
				w.(http.Flusher).Flush()
				if sc.stall {
					_, _ = w.Write([]byte(`data: {"id":"c","choices":[{"delta":{"content":" wor`))
					w.(http.Flusher).Flush()
					<-r.Context().Done()
				}
			}))
			defer upstream.Close()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if sc.stall {
				go func() { time.Sleep(150 * time.Millisecond); cancel() }()
			}
			server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now())
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`)).WithContext(ctx)
			provider := pool.Provider{ProviderID: "provider-1", AssignedID: "route-1", EndpointURL: upstream.URL}
			_, _, attempt := server.forwardStreaming(sseBillingWriter(sc, nl), req, "req-1", sseBillingBody, provider, "llama", 5*time.Second, nil, &forwardState{}, 0)
			return attempt
		}},
		{name: "http-buffered", buffered: true, run: func(t *testing.T, sc sseBillingScenario, nl string) requestLogAttempt {
			events, tail := sseFrame(sc, nl)
			var body io.Reader = strings.NewReader(strings.Join(events, "") + tail)
			if sc.stall {
				// A buffered upstream read that ends with the buyer gone.
				body = io.MultiReader(body, errReader{context.Canceled})
			}
			server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now())
			resp := &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(body), Trailer: http.Header{}}
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			_, _, attempt := server.forwardStreamingBuffered(sseBillingWriter(sc, nl), req, "req-1", resp, pool.Provider{ProviderID: "provider-1"}, "llama", streamingModeBufferedKillSwitch, "buyer", &forwardState{}, 0)
			return attempt
		}},
		{name: "ws-incremental", run: func(t *testing.T, sc sseBillingScenario, nl string) requestLogAttempt {
			relay, ctx, cancel := sseBillingRelay(sc, nl, false)
			defer cancel()
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
			_, attempt := (&Server{}).forwardWSStreaming(sseBillingWriter(sc, nl), req, "req-ws", pool.Provider{ProviderID: "provider-a"}, relay, &forwardState{}, 0)
			return attempt
		}},
		{name: "ws-buffered", buffered: true, run: func(t *testing.T, sc sseBillingScenario, nl string) requestLogAttempt {
			relay, ctx, cancel := sseBillingRelay(sc, nl, true)
			defer cancel()
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
			_, attempt := (&Server{}).forwardWSStreamingBuffered(sseBillingWriter(sc, nl), req, "req-ws", pool.Provider{ProviderID: "provider-a"}, relay, streamingModeBufferedKillSwitch, "buyer", &forwardState{}, 0)
			return attempt
		}},
	}
}

type errReader struct{ err error }

func (r errReader) Read([]byte) (int, error) { return 0, r.err }

func sseBillingRelay(sc sseBillingScenario, nl string, buffered bool) (*providerws.RelayStream, context.Context, context.CancelFunc) {
	events, tail := sseFrame(sc, nl)
	chunks := make(chan providerws.InferenceResponseChunk, len(events)+2)
	done := make(chan providerws.InferenceResponseEnd, 1)
	ctx, cancel := context.WithCancel(context.Background())
	seq := 0
	send := func(data string) {
		chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-ws", Seq: seq, Data: data}
		seq++
	}
	go func() {
		for _, e := range events {
			send(e)
		}
		if tail != "" {
			send(tail)
		}
		if sc.stall {
			time.Sleep(100 * time.Millisecond)
			cancel()
			return
		}
		if buffered {
			close(chunks)
		}
		time.Sleep(50 * time.Millisecond)
		end := providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-ws", Status: "complete", ChunksSent: seq}
		if sc.endUsage != "" {
			end.Usage = []byte(sc.endUsage)
		}
		if !buffered {
			close(chunks)
		}
		done <- end
	}()
	return &providerws.RelayStream{RequestID: "req-ws", Chunks: chunks, Done: done, Errors: make(chan error, 1)}, ctx, cancel
}

func sseBillingScenarios() []sseBillingScenario {
	return []sseBillingScenario{
		{name: "clean completion", events: []string{sseE1, sseE2, sseU52, sseDONE}, endUsage: `{"prompt_tokens":5,"completion_tokens":2}`,
			prompt: 5, completion: 2, incrementalContent: "Hello world", bufferedContent: "Hello world"},
		{name: "cancel mid-event", events: []string{sseE1}, stall: true,
			prompt: -1, completion: -1, incrementalContent: "Hello", bufferedContent: ""},
		{name: "torn write", events: []string{sseE1, sseU52, sseDONE}, budget: 1, endUsage: `{"prompt_tokens":5,"completion_tokens":2}`,
			prompt: -1, completion: -1, incrementalContent: "Hello", bufferedContent: "Hello"},
		{name: "unterminated tail with usage", events: []string{sseE1}, tail: sseE2U, endUsage: `{"prompt_tokens":5,"completion_tokens":3}`,
			prompt: -1, completion: -1, incrementalContent: "Hello", bufferedContent: "Hello"},
		{name: "usage only in the tail", events: []string{sseE1, sseE2}, tail: sseU52, endUsage: `{"prompt_tokens":5,"completion_tokens":2}`,
			prompt: -1, completion: -1, incrementalContent: "Hello world", bufferedContent: "Hello world"},
		{name: "earlier delivered usage then unterminated tail", events: []string{sseE1U}, tail: sseE2U, endUsage: `{"prompt_tokens":5,"completion_tokens":3}`,
			prompt: 5, completion: 1, incrementalContent: "Hello", bufferedContent: "Hello"},
		{name: "tool-call completion", events: []string{sseT1, sseTF, sseU53, sseDONE}, endUsage: `{"prompt_tokens":5,"completion_tokens":3}`,
			prompt: 5, completion: 3, toolCalls: 1},
	}
}

func assertSSEBillingTokens(t *testing.T, what string, got *int64, want int64) {
	t.Helper()
	switch {
	case want < 0 && got != nil:
		t.Errorf("%s=%d, want none", what, *got)
	case want >= 0 && (got == nil || *got != want):
		t.Errorf("%s=%v, want %d", what, got, want)
	}
}

func TestSSEBillingIsIdenticalAcrossPaths(t *testing.T) {
	for _, sc := range sseBillingScenarios() {
		for _, framing := range []struct{ name, nl string }{{"LF", "\n"}, {"CRLF", "\r\n"}} {
			for _, path := range sseBillingPaths() {
				sc, framing, path := sc, framing, path
				t.Run(sc.name+"/"+framing.name+"/"+path.name, func(t *testing.T) {
					attempt := path.run(t, sc, framing.nl)
					assertSSEBillingTokens(t, "prompt_tokens", attempt.PromptTokens, sc.prompt)
					assertSSEBillingTokens(t, "completion_tokens", attempt.CompletionTokens, sc.completion)
					if sc.stall && path.name == "http-buffered" {
						return // a buffered upstream read never reaches the buyer
					}
					out := attempt.SettlementOutput
					if out == nil {
						t.Fatalf("no settlement output")
					}
					want := sc.incrementalContent
					if path.buffered {
						want = sc.bufferedContent
					}
					if out.Content != want {
						t.Errorf("settled content=%q, want %q", out.Content, want)
					}
					if len(out.ToolCalls) != sc.toolCalls {
						t.Errorf("settled tool calls=%d, want %d", len(out.ToolCalls), sc.toolCalls)
					}
				})
			}
		}
	}
}

// Independent review LOW: once content was delivered, the prompt of a usage
// event the buyer began to receive is kept even when its terminator never
// arrived; the completion is not.
func TestDeliveredSSEAccountingKeepsPromptOfPartlyDeliveredUsageEvent(t *testing.T) {
	a := newDeliveredSSEAccounting()
	feed := func(b string, accepted int) {
		a.provider([]byte(b))
		a.render([]byte(b))
		a.written([]byte(b)[:accepted])
	}
	e1 := sseE1 + "\n\n"
	feed(e1, len(e1))
	usageLine := sseU52 + "\n"
	feed(usageLine, len(usageLine))
	feed("\n", 0) // the terminator write fails
	u := a.billableUsage()
	if u.prompt == nil || *u.prompt != 5 {
		t.Fatalf("prompt=%v, want 5", u.prompt)
	}
	if u.completion != nil {
		t.Fatalf("completion=%d, want none: its event was not delivered", *u.completion)
	}
}

// Audit R4 SECURITY M3: tool-call materialization keeps the provider's usage
// event for the buyer.
func TestConsolidatedToolCallSSEKeepsUsageEvent(t *testing.T) {
	raw := strings.Join([]string{sseT1, sseTF, sseU53, sseDONE}, "\n\n") + "\n\n"
	out, err := consolidatedToolCallSSE([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(out, []byte(`"completion_tokens":3`)) {
		t.Fatalf("materialized stream dropped the usage event: %q", out)
	}
}

// A torn SSE line (a provider or buyer cut mid-event) must not hang the
// duplicate-key scan: an unterminated JSON array element consumed nothing
// and the scan looped forever (pre-existing on origin/main).
func TestHasDuplicateJSONKeysReturnsOnTruncatedArray(t *testing.T) {
	done := make(chan bool, 1)
	go func() { done <- hasDuplicateJSONKeys([]byte(`{"id":"c","choices":[{"delta":{"content":" wor`)) }()
	select {
	case dup := <-done:
		if dup {
			t.Fatal("truncated input reported a duplicate key")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("duplicate-key scan did not return on a truncated array")
	}
}
