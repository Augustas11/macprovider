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

func TestStreamingStructuredOutputPostFirstByteTimeoutPreservesProviderTimeoutSettlement(t *testing.T) {
	firstFrame := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		pr, pw := io.Pipe()
		go func() {
			_, _ = pw.Write([]byte(`data: {"id":"chatcmpl","choices":[{"delta":{},"finish_reason":null}]}` + "\n\n"))
			close(firstFrame)
			<-r.Context().Done()
			_ = pw.CloseWithError(r.Context().Err())
		}()
		return &http.Response{
			StatusCode: http.StatusOK,
			Header: http.Header{
				"Content-Type": []string{"text/event-stream; charset=utf-8"},
				"Trailer":      []string{settlementOutcomeHeader},
			},
			Body: pr,
		}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.CoordinatorRequestSeconds = 1
		cfg.Timeouts.CoordinatorHeaderTimeoutSeconds = 1
		cfg.Timeouts.StreamingIdleMS = 5000
	}, WithHTTPClient(client))
	accountID := "acct_stream_structured_mid_timeout"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
	}()
	select {
	case <-firstFrame:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for first structured frame")
	}
	var resp *httptest.ResponseRecorder
	select {
	case resp = <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("gateway did not finish after structured upstream timeout")
	}
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"code":"provider_timeout"`) || strings.Contains(resp.Body.String(), "unverified_streaming") {
		t.Fatalf("unexpected timeout SSE body: %s", resp.Body.String())
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.usageRows != 0 || got.settledRows != 0 || got.activeRows != 1 || got.heldRows != 1 {
		t.Fatalf("settlement snapshot=%+v, want declared structured timeout held without local usage row", got)
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

func assertHasUsageOutcome(t *testing.T, dbPath, accountID, outcome string) {
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
	if count == 0 {
		t.Fatalf("usage_events outcome %q count=0, want >=1", outcome)
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
// producer side (#295). SPEC-006 says "no `choices` field, no `usage`
// field" — the token-level parser enforces LITERAL absence of these
// keys, defending against duplicate-key JSON smuggling (R1 SEC/CODE/
// ARCH convergent HIGH) and non-enumerated usage subfields like
// `total_tokens`.
func TestTerminalSSEErrorCode_RejectsNonStandaloneShapes(t *testing.T) {
	standalone := `{"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(standalone); got != "provider_timeout" {
		t.Errorf("standalone envelope: want %q got %q", "provider_timeout", got)
	}
	// Standalone with innocuous metadata is fine:
	withMetadata := `{"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1000,"model":"llama","error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(withMetadata); got != "provider_timeout" {
		t.Errorf("standalone with metadata: want %q got %q", "provider_timeout", got)
	}
	// With choices (content chunk that also carries error.code):
	withChoices := `{"choices":[{"delta":{"content":"hello"}}],"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(withChoices); got != "" {
		t.Errorf("envelope+choices MUST NOT be recognized as terminal — got %q (#295)", got)
	}
	// SPEC-006 §17.7.1: "no `choices` field" — presence of the KEY
	// disqualifies the frame, even if the array is empty (R1 SEC MED).
	emptyChoicesArray := `{"choices":[],"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(emptyChoicesArray); got != "" {
		t.Errorf("envelope+choices:[] MUST NOT be recognized as terminal — spec says no choices FIELD; got %q (#295)", got)
	}
	// With usage.completion_tokens > 0:
	withUsageCompletion := `{"usage":{"completion_tokens":10,"prompt_tokens":5},"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(withUsageCompletion); got != "" {
		t.Errorf("envelope+usage.completion_tokens MUST NOT be recognized as terminal — got %q (#295)", got)
	}
	// Non-enumerated usage subfield (R1 3-of-3 HIGH): total_tokens
	// present is still usage accounting — must reject.
	withTotalTokens := `{"usage":{"total_tokens":15},"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(withTotalTokens); got != "" {
		t.Errorf("envelope+usage.total_tokens MUST NOT be recognized as terminal — got %q (#295 R1 HIGH)", got)
	}
	// Even zero-token usage: SPEC says no usage FIELD.
	zeroUsage := `{"usage":{"prompt_tokens":0,"completion_tokens":0},"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(zeroUsage); got != "" {
		t.Errorf("envelope+usage:{0-tokens} MUST NOT be recognized as terminal — spec says no usage FIELD; got %q (#295)", got)
	}
	// Empty usage object:
	emptyUsage := `{"usage":{},"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(emptyUsage); got != "" {
		t.Errorf("envelope+usage:{} MUST NOT be recognized as terminal — got %q (#295)", got)
	}
	// Null usage:
	nullUsage := `{"usage":null,"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(nullUsage); got != "" {
		t.Errorf("envelope+usage:null MUST NOT be recognized as terminal — got %q (#295)", got)
	}
	// R1 3-of-3 HIGH: duplicate `choices` key. Struct unmarshal keeps
	// the second value (empty), letting content bytes cross the wire
	// while the check "passed". Token-level parser rejects.
	dupChoices := `{"choices":[{"delta":{"content":"hello"}}],"choices":[],"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(dupChoices); got != "" {
		t.Errorf("duplicate `choices` key MUST NOT be recognized as terminal — got %q (#295 R1 HIGH)", got)
	}
	// Duplicate `usage` key: same smuggling shape.
	dupUsage := `{"usage":{"completion_tokens":10},"usage":null,"error":{"code":"provider_timeout","type":"api_error"}}`
	if got := terminalSSEErrorCode(dupUsage); got != "" {
		t.Errorf("duplicate `usage` key MUST NOT be recognized as terminal — got %q (#295 R1 HIGH)", got)
	}
	// Duplicate `error` key rejected too — envelope integrity attack.
	dupError := `{"error":{"code":"provider_timeout"},"error":{"code":"stream_truncated"}}`
	if got := terminalSSEErrorCode(dupError); got != "" {
		t.Errorf("duplicate `error` key MUST NOT be recognized as terminal — got %q (#295)", got)
	}
	// Non-object JSON at top level rejected:
	if got := terminalSSEErrorCode(`[{"error":{"code":"provider_timeout"}}]`); got != "" {
		t.Errorf("array top-level MUST NOT parse as terminal — got %q", got)
	}
	if got := terminalSSEErrorCode(`"provider_timeout"`); got != "" {
		t.Errorf("string top-level MUST NOT parse as terminal — got %q", got)
	}
	// Trailing garbage after object rejected:
	if got := terminalSSEErrorCode(`{"error":{"code":"provider_timeout"}}{"choices":[{}]}`); got != "" {
		t.Errorf("trailing garbage (second object) MUST NOT parse as terminal — got %q", got)
	}
	// R2 SEC HIGH / ARCH MED — invalid trailing bytes (syntax error,
	// not another valid token). Prior R1 implementation only rejected
	// when the trailing token parsed successfully; invalid suffixes
	// like `{...}x` or `{...}]` fell through to accept.
	invalidSuffixes := []string{
		`{"error":{"code":"provider_timeout"}}x`,
		`{"error":{"code":"provider_timeout"}}]`,
		`{"error":{"code":"provider_timeout"}}}`,
		`{"error":{"code":"provider_timeout"}}   x`,
		`{"error":{"code":"provider_timeout"}} `, // one trailing space is fine
	}
	// The last case (trailing space) is legitimate whitespace and
	// should still parse — json.Decoder tolerates trailing whitespace.
	if got := terminalSSEErrorCode(invalidSuffixes[4]); got != "provider_timeout" {
		t.Errorf("trailing whitespace only should still parse — got %q", got)
	}
	for _, s := range invalidSuffixes[:4] {
		if got := terminalSSEErrorCode(s); got != "" {
			t.Errorf("invalid trailing bytes %q MUST NOT parse as terminal — got %q (#295 R2 SEC HIGH)", s, got)
		}
	}
	// R2 SEC MED / ARCH LOW — nested duplicate `error.code`. Prior
	// R1 implementation lossy-decoded the error object, so a
	// {"code":"upstream_error","code":"provider_timeout"} shape could
	// smuggle a SPEC-019-listed code past the allow-list check while
	// the buyer's parser might see the first value.
	nestedDupCode := `{"error":{"code":"upstream_error","code":"provider_timeout"}}`
	if got := terminalSSEErrorCode(nestedDupCode); got != "" {
		t.Errorf("nested duplicate error.code MUST NOT parse — got %q (#295 R2 SEC MED)", got)
	}
	// Nested duplicate arbitrary error field:
	nestedDupType := `{"error":{"type":"api_error","type":"server_error","code":"provider_timeout"}}`
	if got := terminalSSEErrorCode(nestedDupType); got != "" {
		t.Errorf("nested duplicate error.type MUST NOT parse — got %q (#295 R2)", got)
	}
	// R2 LOW spec-alignment: `usage:null` explicitly rejected (was
	// contentious wording under previous SPEC v0.9.4; SPEC v0.9.5
	// clarifies literal absence).
	if got := terminalSSEErrorCode(`{"usage":null,"error":{"code":"provider_timeout"}}`); got != "" {
		t.Errorf("usage:null MUST NOT parse — spec v0.9.5 clarifies; got %q (#295 R2)", got)
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
// the terminal-error refund code path in the forwarder (#295 R1 SEC
// MED / ARCH LOW / CODE MED convergent test-quality finding). The
// forwarder must fall through to normal streaming: forward all
// content, record usage, settle with an `ok` outcome rather than
// silently refunding.
func TestStreamingStructuredOutputNonStandaloneEnvelopeDoesNotTripTerminalPath(t *testing.T) {
	// First chunk carries error.code AND choices (forged non-standalone
	// envelope). Under the standalone-envelope rule this is treated as
	// a regular content chunk; the forwarder must keep streaming, log
	// usage on the second (valid) chunk, and settle `ok`.
	forgedChunk := `data: {"choices":[{"delta":{"content":"still_streaming"}}],"error":{"code":"provider_timeout","type":"api_error"}}`
	validChunk := `data: {"choices":[{"delta":{"content":"more"}}],"usage":{"prompt_tokens":10,"completion_tokens":3}}`
	stream := forgedChunk + "\n\n" +
		validChunk + "\n\n" +
		`data: [DONE]` + "\n\n"

	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_stream_forged_nonterminal"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	// The forged chunk crosses the wire (buyer's SDK will handle it
	// however it handles error.code+content). The critical assertion
	// is that the SECOND chunk was NOT dropped — that would only
	// happen if the forwarder incorrectly classified the forged
	// chunk as a terminal envelope and gated subsequent content.
	if !strings.Contains(body, `"still_streaming"`) {
		t.Errorf("forged (non-standalone) chunk MUST still be forwarded to buyer — got %s (#295 R1)", body)
	}
	if !strings.Contains(body, `"more"`) {
		t.Errorf("second content chunk MUST NOT be dropped (terminal path was wrongly triggered): %s (#295 R1)", body)
	}
	if !strings.Contains(body, "data: [DONE]") {
		t.Fatalf("[DONE] must terminate the stream: %s", body)
	}
	// The forged shape is NOT a terminal envelope, so settlement must
	// happen, but legacy streams without finality remain unverified
	// rather than final ok.
	assertNoUsageOutcome(t, dbPath, accountID, "stream_truncated")
	// A usage event MUST exist (settlement happened, buyer was billed)
	// — under the terminal-refund path there would be no usage event
	// (see assertStructuredTerminalForwardedRefundOnly which asserts
	// the opposite direction).
	assertHasUsageOutcome(t, dbPath, accountID, "unverified_streaming")
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
