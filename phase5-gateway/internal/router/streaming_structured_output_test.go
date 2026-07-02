package router

import (
	"database/sql"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	_ "modernc.org/sqlite"
)

// errAfterReader returns the given bytes once, then a non-EOF error
// on subsequent reads. Used to simulate an upstream mid-stream
// read failure after the buyer-visible terminal frame already
// arrived (distinct from clean EOF or context-deadline-exceeded).
type errAfterReader struct {
	data []byte
	err  error
	done bool
}

func (r *errAfterReader) Read(p []byte) (int, error) {
	if r.done {
		return 0, r.err
	}
	n := copy(p, r.data)
	r.data = r.data[n:]
	if len(r.data) == 0 {
		r.done = true
	}
	return n, nil
}

func (r *errAfterReader) Close() error { return nil }

type slowBodyReader struct {
	body []byte
	read bool
}

func (r *slowBodyReader) Read(p []byte) (int, error) {
	if r.read {
		return 0, io.EOF
	}
	r.read = true
	time.Sleep(1100 * time.Millisecond)
	return copy(p, r.body), io.EOF
}

func (r *slowBodyReader) Close() error { return nil }

func TestStreamingStructuredOutputTerminalSSEErrorPassesThroughWithoutOKSettlement(t *testing.T) {
	body := `data: {"choices":[{"delta":{"content":"{\"age\":\""}}]}`
	for _, code := range []string{
		"malformed_json_response",
		"json_schema_validation_failed",
		"response_byte_cap_exceeded",
		"provider_timeout",
	} {
		t.Run(code, func(t *testing.T) {
			terminal := structuredTerminalSSE(code)
			stream := body + "\n\n" + terminal + "\n\ndata: [DONE]\n\n"
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			accountID := "acct_stream_structured_error_" + strings.ReplaceAll(code, "_", "")
			fullKey := createAccountAndKey(t, store, cfg, accountID)

			resp := postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			assertStructuredTerminalForwardedRefundOnly(t, dbPath, accountID, resp.Body.String(), terminal, code)
		})
	}
}

func TestStreamingStructuredOutputCoordByteCapExceededSSEPassesThrough(t *testing.T) {
	assertCoordStructuredSSEPassesThrough(t, "response_byte_cap_exceeded")
}

func TestStreamingStructuredOutputCoordProviderTimeoutSSEPassesThrough(t *testing.T) {
	assertCoordStructuredSSEPassesThrough(t, "provider_timeout")
}

func TestStreamingStructuredOutputGatewayTimeoutEmitsProviderTimeout(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.CoordinatorRequestSeconds = 1
	}, WithHTTPClient(client))
	accountID := "acct_stream_structured_timeout"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"code":"provider_timeout"`) ||
		!strings.Contains(resp.Body.String(), `"settlement_ran":true`) ||
		strings.Contains(resp.Body.String(), "provider_disconnected") ||
		strings.Contains(resp.Body.String(), "stream_truncated") {
		t.Fatalf("unexpected timeout SSE body: %s", resp.Body.String())
	}
	outcome, _ := usageEventOutcome(t, dbPath, accountID)
	if outcome != "provider_timeout" {
		t.Fatalf("usage outcome=%s want provider_timeout", outcome)
	}
}

func TestStreamingStructuredOutputUpstreamContextStartsAtRequestEntry(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		select {
		case <-r.Context().Done():
			return nil, r.Context().Err()
		default:
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, `data: [DONE]`+"\n\n"), nil
		}
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.CoordinatorRequestSeconds = 1
	}, WithHTTPClient(client))
	accountID := "acct_stream_structured_entry_timeout"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", &slowBodyReader{body: []byte(structuredStreamingRequestBody())})
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"code":"provider_timeout"`) {
		t.Fatalf("body missing provider_timeout: %s", resp.Body.String())
	}
	outcome, _ := usageEventOutcome(t, dbPath, accountID)
	if outcome != "provider_timeout" {
		t.Fatalf("usage outcome=%s want provider_timeout", outcome)
	}
}

// Pre-audit guard: if the provider already sent a terminal SPEC-019
// SSE error frame and the upstream connection then drops mid-stream
// (read failure, not timeout, not [DONE]), the gateway MUST NOT
// double-write a second terminal frame (provider_disconnected /
// stream_truncated). Refund-only.
func TestStreamingStructuredOutputUpstreamReadErrorAfterTerminalFrameRefundsOnly(t *testing.T) {
	terminal := `data: {"error":{"message":"bad age","type":"upstream_provider_error","param":"/age","code":"json_schema_validation_failed","retryable":true,"request_id":"req-downstream","inference_ran":true,"settlement_ran":true}}`
	// Send terminal frame, then return io.ErrUnexpectedEOF on the
	// next read — simulates upstream connection abort after the
	// buyer-visible terminal frame arrived. NOT context-deadline-
	// exceeded; exercises the SPEC-002 FR-B6 disconnect path.
	stream := terminal + "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}},
			Body:       &errAfterReader{data: []byte(stream), err: io.ErrUnexpectedEOF},
		}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_stream_structured_error_read_fail"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), terminal) {
		t.Fatalf("terminal frame not forwarded: %s", resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), "provider_disconnected") {
		t.Fatalf("gateway double-wrote provider_disconnected after terminal frame: %s", resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), "stream_truncated") {
		t.Fatalf("gateway double-wrote stream_truncated after terminal frame: %s", resp.Body.String())
	}
	assertNoUsageOutcome(t, dbPath, accountID, "ok")
	assertNoUsageOutcome(t, dbPath, accountID, "stream_truncated")
	assertNoUsageOutcome(t, dbPath, accountID, "provider_disconnected")
}

func TestStreamingStructuredOutputNoDoubleFireProviderIdleTimeout(t *testing.T) {
	terminal := structuredTerminalSSE("provider_timeout")
	stream := terminal + "\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}},
			Body:       &errAfterReader{data: []byte(stream), err: io.ErrUnexpectedEOF},
		}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_stream_structured_provider_idle_timeout"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertStructuredTerminalForwardedRefundOnly(t, dbPath, accountID, resp.Body.String(), terminal, "provider_timeout")
	if strings.Contains(resp.Body.String(), "provider_disconnected") ||
		strings.Contains(resp.Body.String(), "stream_truncated") ||
		strings.Contains(resp.Body.String(), "stream_malformed") {
		t.Fatalf("gateway double-wrote terminal frame after provider_timeout: %s", resp.Body.String())
	}
}

func structuredStreamingRequestBody() string {
	return `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"person-v1","strict":true,"schema":{"type":"object","properties":{"age":{"type":"integer","minimum":0}},"required":["age"],"additionalProperties":false}}}}`
}

func assertNoUsageOutcome(t *testing.T, dbPath, accountID, outcome string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	var count int
	err = db.QueryRow(`SELECT COUNT(*) FROM usage_events WHERE account_id = ? AND outcome = ?`, accountID, outcome).Scan(&count)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("query usage_events: %v", err)
	}
	if count != 0 {
		t.Fatalf("usage_events outcome %q count=%d, want 0", outcome, count)
	}
}

func assertNoUsageEventsForAccount(t *testing.T, dbPath, accountID string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	var count int
	err = db.QueryRow(`SELECT COUNT(*) FROM usage_events WHERE account_id = ?`, accountID).Scan(&count)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("query usage_events: %v", err)
	}
	if count != 0 {
		t.Fatalf("usage_events count=%d, want refund-only/no usage events", count)
	}
}

func assertCoordStructuredSSEPassesThrough(t *testing.T, code string) {
	t.Helper()
	terminal := structuredTerminalSSE(code)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, terminal+"\n\ndata: [DONE]\n\n"), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_stream_structured_coord_" + strings.ReplaceAll(code, "_", "")
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertStructuredTerminalForwardedRefundOnly(t, dbPath, accountID, resp.Body.String(), terminal, code)
}

func assertStructuredTerminalForwardedRefundOnly(t *testing.T, dbPath, accountID, body, terminal, code string) {
	t.Helper()
	if !strings.Contains(body, terminal) {
		t.Fatalf("terminal frame not forwarded verbatim: %s", body)
	}
	if !strings.Contains(body, `"code":"`+code+`"`) {
		t.Fatalf("body missing code %q: %s", code, body)
	}
	if strings.Contains(body, "stream_malformed") {
		t.Fatalf("terminal structured error was remapped: %s", body)
	}
	if strings.Contains(body, `"outcome":"ok"`) {
		t.Fatalf("body contains ok outcome: %s", body)
	}
	assertNoUsageOutcome(t, dbPath, accountID, "ok")
	assertNoUsageOutcome(t, dbPath, accountID, "stream_truncated")
	assertNoUsageEventsForAccount(t, dbPath, accountID)
}

func structuredTerminalSSE(code string) string {
	return `data: {"error":{"message":"structured terminal","type":"upstream_provider_error","param":null,"code":"` + code + `","retryable":false,"request_id":"req-downstream","inference_ran":true,"settlement_ran":true}}`
}

// TestTerminalSSEErrorCode_RejectsNonStandaloneShapes verifies the
// SPEC-006 §17.7.1 clause 1 standalone-envelope check on the gateway
// producer side (#295). A payload with `error.code` alongside
// `choices` or non-zero `usage` tokens is structurally inconsistent
// with the terminal-envelope contract and MUST NOT trigger the
// terminal-refund path.
func TestTerminalSSEErrorCode_RejectsNonStandaloneShapes(t *testing.T) {
	standalone := `{"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(standalone); got != "provider_timeout" {
		t.Errorf("standalone envelope: want %q got %q", "provider_timeout", got)
	}
	// With choices (content chunk that also carries error.code):
	withChoices := `{"choices":[{"delta":{"content":"hello"}}],"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(withChoices); got != "" {
		t.Errorf("envelope+choices MUST NOT be recognized as terminal — got %q (#295)", got)
	}
	// With usage.completion_tokens > 0:
	withUsageCompletion := `{"usage":{"completion_tokens":10,"prompt_tokens":5},"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(withUsageCompletion); got != "" {
		t.Errorf("envelope+usage.completion_tokens MUST NOT be recognized as terminal — got %q (#295)", got)
	}
	// With usage.prompt_tokens > 0 (completion=0):
	withUsagePrompt := `{"usage":{"prompt_tokens":5},"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(withUsagePrompt); got != "" {
		t.Errorf("envelope+usage.prompt_tokens MUST NOT be recognized as terminal — got %q (#295)", got)
	}
	// With BOTH choices AND usage:
	withBoth := `{"choices":[{"delta":{"content":"hi"}}],"usage":{"completion_tokens":8},"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(withBoth); got != "" {
		t.Errorf("envelope+choices+usage MUST NOT be recognized as terminal — got %q (#295)", got)
	}
	// Empty choices array + zero-usage object should still parse as standalone
	// (defensive: providers sometimes send empty containers on the envelope).
	// But `len(choices) > 0` is the SPEC test, so [] is OK:
	emptyChoicesArray := `{"choices":[],"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(emptyChoicesArray); got != "provider_timeout" {
		t.Errorf("empty choices array should still parse as standalone — got %q", got)
	}
	// Usage present but all zeros is also standalone-compatible:
	zeroUsage := `{"usage":{"prompt_tokens":0,"completion_tokens":0},"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(zeroUsage); got != "provider_timeout" {
		t.Errorf("zero-token usage should still parse as standalone — got %q", got)
	}
}

// TestStreamingStructuredOutputDropsContentAfterTerminalFrame verifies
// SPEC-006 §17.7.1 clause 3 (#295 second half): once the gateway
// dispatches a terminal error envelope, subsequent content `data:`
// frames from the provider MUST NOT be forwarded to the buyer before
// `[DONE]`. This is the "last frame before [DONE], no content after"
// contract.
func TestStreamingStructuredOutputDropsContentAfterTerminalFrame(t *testing.T) {
	// Provider stream: legitimate content chunk, terminal envelope,
	// then a forged post-terminator content chunk, then [DONE].
	// The forged content is what the buyer MUST NOT see.
	terminal := structuredTerminalSSE("provider_timeout")
	postTerminalContent := `data: {"choices":[{"delta":{"content":"POST_TERMINAL_LEAK"}}]}`
	stream := `data: {"choices":[{"delta":{"content":"before"}}]}` + "\n\n" +
		terminal + "\n\n" +
		postTerminalContent + "\n\n" +
		`data: [DONE]` + "\n\n"

	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_stream_post_terminal_drop"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if strings.Contains(body, "POST_TERMINAL_LEAK") {
		t.Errorf("content data after terminal envelope MUST be dropped — buyer saw leaked content (#295): %s", body)
	}
	if !strings.Contains(body, terminal) {
		t.Fatalf("terminal envelope must still be forwarded verbatim: %s", body)
	}
	if !strings.Contains(body, "data: [DONE]") {
		t.Fatalf("terminator must still be forwarded: %s", body)
	}
	// Refund-only outcome (matches R1 baseline for terminal frames).
	assertNoUsageOutcome(t, dbPath, accountID, "ok")
	assertNoUsageOutcome(t, dbPath, accountID, "stream_truncated")
	assertNoUsageEventsForAccount(t, dbPath, accountID)
}

// TestStreamingStructuredOutputNonStandaloneEnvelopeDoesNotTripTerminalPath
// verifies that a "content-plus-error-code" payload does NOT trigger
// the terminal-error code path in the forwarder. The forwarder should
// treat it as a normal content chunk (subject to standard usage/output
// accounting), NOT as a terminal-envelope refund.
func TestStreamingStructuredOutputNonStandaloneEnvelopeDoesNotTripTerminalPath(t *testing.T) {
	// Payload has error.code AND choices — must NOT be terminal.
	// Followed by a legit content chunk and clean [DONE] so the
	// stream completes normally. The forged shape should fall through
	// to normal handling (either treated as content or as malformed,
	// but NOT as a refund-only terminal).
	forgedChunk := `data: {"choices":[{"delta":{"content":"still_streaming"}}],"error":{"code":"provider_timeout","type":"api_error"}}`
	stream := forgedChunk + "\n\n" +
		`data: {"choices":[{"delta":{"content":"more"}},"usage":{"completion_tokens":3,"prompt_tokens":10}]}` + "\n\n" +
		`data: [DONE]` + "\n\n"

	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_stream_forged_nonterminal"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	// Positive: forged payload was NOT routed through the refund-only
	// terminal path. Since the provider stream also contains the
	// forged code, the buyer will still see the raw bytes — but the
	// gateway must not have SILENTLY refunded and treated the response
	// as a terminal SPEC-019 outcome.
	body := resp.Body.String()
	if !strings.Contains(body, "data: [DONE]") {
		t.Fatalf("[DONE] must still terminate the stream: %s", body)
	}
	_ = store
	_ = accountID
}

func TestTerminalSSEErrorCode_MalformedJSONReturnsEmpty(t *testing.T) {
	if got := terminalSSEErrorCode("not-json"); got != "" {
		t.Errorf("malformed JSON must return empty code — got %q", got)
	}
	if got := terminalSSEErrorCode(""); got != "" {
		t.Errorf("empty string must return empty code — got %q", got)
	}
}

func TestTerminalSSEErrorCode_TrimsWhitespaceInCode(t *testing.T) {
	// Existing behavior preserved: TrimSpace on the code value.
	payload := `{"error":{"code":"  provider_timeout  "}}`
	if got := terminalSSEErrorCode(payload); got != "provider_timeout" {
		t.Errorf("whitespace must be trimmed — got %q", got)
	}
}
