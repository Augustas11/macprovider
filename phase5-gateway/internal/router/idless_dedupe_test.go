package router

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// Issue #762 (seam finding P1-1) — bill each request once when the retry
// carries no id.
//
// The behavior under test has two halves that must be kept apart:
//
//   - The MONEY invariant is the durable (account_id, request_id) primary key
//     on quota_reservations. Every test here that asserts "billed once" is
//     asserting that key still holds.
//   - The REPLAY cache is a UX layer on top of it. When it misses, the retry
//     adopts attempt 1's id and gets the existing duplicate_request_id 409 —
//     degraded, never a second bill.
//
// Tests are therefore paired: one asserts the replay actually happens, its
// sibling asserts the bypass/miss path still bills once (or, for the opt-outs,
// that nothing changed at all).

const idlessDedupeBody = `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`

// ---- helpers ---------------------------------------------------------------

// distinctRequestID stamps a unique client-supplied UUID X-Request-ID onto a
// header set, opting the request OUT of the #762 id-less dedupe path.
//
// Tests about concurrency, request-rate, or quota caps deliberately drive many
// byte-identical bodies through one account. Before #762 those were distinct
// requests by definition; now an id-less pair is a retry of one intent. Giving
// each attempt its own id keeps those tests testing what they were written to
// test — the dedupe behavior itself is covered in this file.
func distinctRequestID(base map[string]string) map[string]string {
	headers := make(map[string]string, len(base)+1)
	for key, value := range base {
		headers[key] = value
	}
	headers["X-Request-ID"] = newUUID()
	return headers
}

// idlessJSONUpstream answers the chat path with a fixed non-streaming 200 and
// counts dispatches. extra headers (if any) are merged into the response so a
// test can prove which upstream headers survive to the buyer.
func idlessJSONUpstream(completion string, hits *atomic.Int32, extra http.Header) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		hits.Add(1)
		header := http.Header{"Content-Type": []string{"application/json"}}
		for key, values := range extra {
			for _, value := range values {
				header.Add(key, value)
			}
		}
		return responseWithBody(http.StatusOK, header, completion), nil
	})}
}

// idlessStreamingUpstream is seamStreamingUpstream with a dispatch counter.
func idlessStreamingUpstream(hits *atomic.Int32, onWrite func(pw *io.PipeWriter)) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		hits.Add(1)
		pr, pw := io.Pipe()
		go onWrite(pw)
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}},
			Body:       pr,
		}, nil
	})}
}

func idlessMetric(t *testing.T, h http.Handler, name string) int64 {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("GET /metrics status=%d", resp.Code)
	}
	for _, line := range strings.Split(resp.Body.String(), "\n") {
		if !strings.HasPrefix(line, name+" ") {
			continue
		}
		value, err := strconv.ParseInt(strings.TrimSpace(strings.TrimPrefix(line, name+" ")), 10, 64)
		if err != nil {
			t.Fatalf("parse metric %s from %q: %v", name, line, err)
		}
		return value
	}
	t.Fatalf("metric %s missing from /metrics", name)
	return 0
}

func waitForIdlessMetric(t *testing.T, h http.Handler, name string, want int64) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if idlessMetric(t, h, name) >= want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("metric %s never reached %d", name, want)
}

func recvResponse(t *testing.T, ch <-chan *httptest.ResponseRecorder, what string) *httptest.ResponseRecorder {
	t.Helper()
	select {
	case resp := <-ch:
		return resp
	case <-time.After(10 * time.Second):
		t.Fatalf("%s never returned", what)
		return nil
	}
}

func assertNoDedupeReplay(t *testing.T, resp *httptest.ResponseRecorder, what string) {
	t.Helper()
	if got := resp.Header().Get(idlessDedupeHeader); got != "" {
		t.Fatalf("%s: unexpected %s=%q (this attempt must not be a replay)", what, idlessDedupeHeader, got)
	}
}

func translatedResponsesChatBodyForDedupeTest(t *testing.T, responsesBody string) string {
	t.Helper()
	adapter := newResponsesAdapter(httptest.NewRecorder(), newUUID(), nil)
	translated, err := adapter.translateRequest([]byte(responsesBody))
	if err != nil {
		t.Fatalf("translate Responses request for collision fixture: %v", err)
	}
	return string(translated)
}

// ---- replay + coalesce (the fix) -------------------------------------------

// Two byte-identical id-less requests overlapping in time must coalesce onto
// ONE dispatch: the second parks on the first (holding no reservation and no
// concurrency lease) and replays its answer.
func TestIdlessDedupe_ConcurrentIdenticalRequestsBillOnce(t *testing.T) {
	var hits atomic.Int32
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		hits.Add(1)
		entered <- struct{}{}
		<-release
		return responseWithBody(http.StatusOK,
			http.Header{"Content-Type": []string{"application/json"}}, seamCompletionJSON), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_concurrent")

	firstCh := make(chan *httptest.ResponseRecorder, 1)
	go func() { firstCh <- postChat(t, h, key, idlessDedupeBody, nil) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		close(release)
		t.Fatal("upstream never received the first dispatch")
	}

	secondCh := make(chan *httptest.ResponseRecorder, 1)
	go func() { secondCh <- postChat(t, h, key, idlessDedupeBody, nil) }()
	// Deterministic: the second attempt is provably parked on the first
	// before the first is allowed to finish.
	waitForIdlessMetric(t, h, "gateway_idless_dedupe_inflight_wait_total", 1)
	close(release)

	first := recvResponse(t, firstCh, "first attempt")
	second := recvResponse(t, secondCh, "second attempt")
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("statuses first=%d second=%d, want 200/200 (second=%s)", first.Code, second.Code, second.Body.String())
	}
	if got := second.Header().Get(idlessDedupeHeader); got != idlessDedupeHeaderValue {
		t.Fatalf("coalesced attempt %s=%q want %q", idlessDedupeHeader, got, idlessDedupeHeaderValue)
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("upstream dispatches=%d want 1 (the second attempt re-dispatched instead of coalescing)", got)
	}
	if first.Body.String() != second.Body.String() {
		t.Fatalf("coalesced body differs:\n first=%s\nsecond=%s", first.Body.String(), second.Body.String())
	}
	if used := billedTokens(t, h, key); used != 20 {
		t.Fatalf("billed %v want 20", used)
	}
	state := gatewaySettlementSnapshot(t, dbPath, "acct_idless_concurrent")
	if state.settledRows != 1 || state.activeRows != 0 {
		t.Fatalf("reservations %+v; want exactly one settled row and no active hold", state)
	}
}

func TestIdlessDedupe_StreamingRetryReplays(t *testing.T) {
	var hits atomic.Int32
	sse := `data: {"id":"c","choices":[{"delta":{"content":"hello"}}]}` + "\n\n" +
		`data: {"id":"c","usage":{"prompt_tokens":8,"completion_tokens":2,"total_tokens":10},"choices":[{"delta":{},"finish_reason":"stop"}]}` + "\n\n" +
		`data: [DONE]` + "\n\n"
	client := idlessStreamingUpstream(&hits, func(pw *io.PipeWriter) {
		_, _ = io.WriteString(pw, sse)
		_ = pw.Close()
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_stream")

	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	first := postChat(t, h, key, body, nil)
	if first.Code != http.StatusOK || !strings.Contains(first.Body.String(), "data: [DONE]") {
		t.Fatalf("attempt 1 status=%d body=%.300q", first.Code, first.Body.String())
	}
	billedAfterFirst := billedTokens(t, h, key)

	second := postChat(t, h, key, body, nil)
	if second.Code != http.StatusOK {
		t.Fatalf("attempt 2 status=%d body=%s", second.Code, second.Body.String())
	}
	if got := second.Header().Get(idlessDedupeHeader); got != idlessDedupeHeaderValue {
		t.Fatalf("streaming retry %s=%q want %q", idlessDedupeHeader, got, idlessDedupeHeaderValue)
	}
	if !strings.Contains(second.Body.String(), "data: [DONE]") {
		t.Fatalf("replayed stream is not terminated: %.300q", second.Body.String())
	}
	if first.Body.String() != second.Body.String() {
		t.Fatalf("replayed stream differs:\n first=%.300q\nsecond=%.300q", first.Body.String(), second.Body.String())
	}
	if got := second.Header().Get("Content-Type"); !strings.HasPrefix(got, "text/event-stream") {
		t.Fatalf("replayed Content-Type=%q want text/event-stream", got)
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("upstream dispatches=%d want 1", got)
	}
	if used := billedTokens(t, h, key); used != billedAfterFirst {
		t.Fatalf("streaming replay billed again: %v -> %v", billedAfterFirst, used)
	}
}

// A replay must not echo attempt 1's per-attempt headers. Only the whitelist
// (Content-Type, X-Provider-Id, X-Request-ID, the dedupe marker) plus freshly
// recomputed rate-limit headers may cross.
func TestIdlessDedupe_ReplayEmitsNoSettlementHeaders(t *testing.T) {
	var hits atomic.Int32
	client := idlessJSONUpstream(seamCompletionJSON, &hits, http.Header{
		"X-Upstream-Trace":                 []string{"attempt-1"},
		"X-MacProvider-Provider":           []string{"peer-a"},
		"X-MacProvider-Settlement-Outcome": []string{"settled"},
		"Retry-After":                      []string{"7"},
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_headers")

	first := postChat(t, h, key, idlessDedupeBody, nil)
	if first.Code != http.StatusOK {
		t.Fatalf("attempt 1 status=%d body=%s", first.Code, first.Body.String())
	}
	attemptOneID := first.Header().Get("X-Request-ID")
	if attemptOneID == "" {
		t.Fatal("attempt 1 emitted no X-Request-ID")
	}
	if got := first.Header().Get("X-Upstream-Trace"); got != "attempt-1" {
		t.Fatalf("attempt 1 X-Upstream-Trace=%q want attempt-1 (test would be vacuous otherwise)", got)
	}

	second := postChat(t, h, key, idlessDedupeBody, nil)
	if got := second.Header().Get(idlessDedupeHeader); got != idlessDedupeHeaderValue {
		t.Fatalf("attempt 2 %s=%q want %q", idlessDedupeHeader, got, idlessDedupeHeaderValue)
	}
	// The replay is built from a whitelist, not from attempt 1's header map:
	// a passthrough header that attempt 1 carried must NOT reappear.
	if got := second.Header().Get("X-Upstream-Trace"); got != "" {
		t.Fatalf("replay echoed attempt 1's passthrough header X-Upstream-Trace=%q", got)
	}
	for name := range second.Header() {
		if strings.HasPrefix(strings.ToLower(name), "x-macprovider-settlement-") {
			t.Fatalf("replay carries settlement header %s (it describes attempt 1's billing transaction)", name)
		}
	}
	if got := second.Header().Get("Retry-After"); got != "" {
		t.Fatalf("replay carries Retry-After=%q", got)
	}
	// X-Request-ID is attempt 1's, because attempt 1 is the request that was
	// actually billed and logged.
	if got := second.Header().Get("X-Request-ID"); got != attemptOneID {
		t.Fatalf("replay X-Request-ID=%q want attempt 1's %q", got, attemptOneID)
	}
	if got := second.Header().Get("X-Provider-Id"); got != "peer-a" {
		t.Fatalf("replay X-Provider-Id=%q want peer-a", got)
	}
	for _, name := range []string{"X-RateLimit-Limit", "X-RateLimit-Remaining", "X-RateLimit-Reset"} {
		if second.Header().Get(name) == "" {
			t.Fatalf("replay is missing recomputed %s", name)
		}
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("upstream dispatches=%d want 1", got)
	}
}

// The gateway's over-report bound (INV-7) is attempt 1's property; replaying
// its response must not add a second usage row or reopen a hold.
func TestIdlessDedupe_ReplayPreservesBoundedToDelivered(t *testing.T) {
	var hits atomic.Int32
	sse := `data: {"id":"c","choices":[{"delta":{"content":"ok"}}]}` + "\n\n" +
		`data: {"id":"c","usage":{"prompt_tokens":8,"completion_tokens":100000,"total_tokens":100008},"choices":[{"delta":{},"finish_reason":"stop"}]}` + "\n\n" +
		`data: [DONE]` + "\n\n"
	client := idlessStreamingUpstream(&hits, func(pw *io.PipeWriter) {
		_, _ = io.WriteString(pw, sse)
		_ = pw.Close()
	})
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_bounded")

	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	if r := postChat(t, h, key, body, nil); r.Code != http.StatusOK {
		t.Fatalf("attempt 1 status=%d body=%s", r.Code, r.Body.String())
	}
	billedAfterFirst := billedTokens(t, h, key)
	if billedAfterFirst >= 1000 {
		t.Fatalf("INV-7 precondition broken: attempt 1 billed %v (over-report was accepted)", billedAfterFirst)
	}

	second := postChat(t, h, key, body, nil)
	if got := second.Header().Get(idlessDedupeHeader); got != idlessDedupeHeaderValue {
		t.Fatalf("attempt 2 %s=%q want %q", idlessDedupeHeader, got, idlessDedupeHeaderValue)
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("upstream dispatches=%d want 1", got)
	}
	if used := billedTokens(t, h, key); used != billedAfterFirst {
		t.Fatalf("replay changed the bill: %v -> %v", billedAfterFirst, used)
	}
	state := gatewaySettlementSnapshot(t, dbPath, "acct_idless_bounded")
	if state.usageRows != 1 || state.settledRows != 1 || state.activeRows != 0 {
		t.Fatalf("reservations/usage %+v; want usageRows=1 settledRows=1 activeRows=0", state)
	}
}

// The replay cache is bounded, so it must have a safe overflow. Past the
// waiter cap an attempt does NOT get its own dispatch: it adopts attempt 1's
// request id and lands on the durable duplicate_request_id 409 — the same
// answer a cache miss after a restart or an eviction produces. Degraded UX,
// still exactly one bill.
func TestIdlessDedupe_OverWaiterCapFallsThroughToDurable409(t *testing.T) {
	var hits atomic.Int32
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		hits.Add(1)
		entered <- struct{}{}
		<-release
		return responseWithBody(http.StatusOK,
			http.Header{"Content-Type": []string{"application/json"}}, seamCompletionJSON), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_overcap")

	ownerCh := make(chan *httptest.ResponseRecorder, 1)
	go func() { ownerCh <- postChat(t, h, key, idlessDedupeBody, nil) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		close(release)
		t.Fatal("upstream never received the owner's dispatch")
	}

	waiters := make(chan *httptest.ResponseRecorder, idlessDedupeMaxWaiters)
	for i := 0; i < idlessDedupeMaxWaiters; i++ {
		go func() { waiters <- postChat(t, h, key, idlessDedupeBody, nil) }()
	}
	waitForIdlessMetric(t, h, "gateway_idless_dedupe_inflight_wait_total", int64(idlessDedupeMaxWaiters))

	// One more identical attempt: the waiter slots are full, so this one must
	// resolve immediately rather than park.
	overCap := postChat(t, h, key, idlessDedupeBody, nil)
	if overCap.Code != http.StatusConflict {
		t.Fatalf("over-cap attempt status=%d want 409; body=%s", overCap.Code, overCap.Body.String())
	}
	assertErrorCode(t, overCap.Body.String(), "duplicate_request_id")
	assertNoDedupeReplay(t, overCap, "over-cap attempt")
	if got := idlessMetric(t, h, "gateway_idless_dedupe_conflict_total"); got < 1 {
		t.Fatalf("conflict_total=%d want >= 1", got)
	}

	close(release)
	owner := recvResponse(t, ownerCh, "owner attempt")
	if owner.Code != http.StatusOK {
		t.Fatalf("owner status=%d body=%s", owner.Code, owner.Body.String())
	}
	// The 409 must name the id the buyer's request was folded onto, not the
	// fresh id the middleware minted for this attempt.
	if got, want := overCap.Header().Get("X-Request-ID"), owner.Header().Get("X-Request-ID"); got != want {
		t.Fatalf("over-cap 409 X-Request-ID=%q want the adopted %q", got, want)
	}
	for i := 0; i < idlessDedupeMaxWaiters; i++ {
		resp := recvResponse(t, waiters, "parked waiter")
		if resp.Code != http.StatusOK {
			t.Fatalf("parked waiter status=%d body=%s", resp.Code, resp.Body.String())
		}
		if got := resp.Header().Get(idlessDedupeHeader); got != idlessDedupeHeaderValue {
			t.Fatalf("parked waiter %s=%q want %q", idlessDedupeHeader, got, idlessDedupeHeaderValue)
		}
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("upstream dispatches=%d want 1", got)
	}
	if used := billedTokens(t, h, key); used != 20 {
		t.Fatalf("billed %v want 20 (six identical id-less attempts, one intent)", used)
	}
	state := gatewaySettlementSnapshot(t, dbPath, "acct_idless_overcap")
	if state.settledRows != 1 || state.activeRows != 0 {
		t.Fatalf("reservations %+v; want exactly one settled row", state)
	}
}

// ---- the bounds: what must NOT be swallowed --------------------------------

// The window is the executable bound on the one real false positive (a
// deliberate re-roll at temperature > 0). Past it, an identical id-less
// request is a NEW request and bills again.
func TestIdlessDedupe_OutsideWindowNotSwallowed(t *testing.T) {
	var hits atomic.Int32
	now := fixedNow()
	client := idlessJSONUpstream(seamCompletionJSON, &hits, nil)
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Quotas.IdlessDedupeWindowSeconds = 60
	}, WithNow(func() time.Time { return now }), WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_window")

	if r := postChat(t, h, key, idlessDedupeBody, nil); r.Code != http.StatusOK {
		t.Fatalf("attempt 1 status=%d body=%s", r.Code, r.Body.String())
	}
	now = now.Add(61 * time.Second)

	second := postChat(t, h, key, idlessDedupeBody, nil)
	if second.Code != http.StatusOK {
		t.Fatalf("attempt 2 status=%d body=%s", second.Code, second.Body.String())
	}
	assertNoDedupeReplay(t, second, "outside-window resend")
	if got := hits.Load(); got != 2 {
		t.Fatalf("upstream dispatches=%d want 2 (a resend past the window must re-generate)", got)
	}
	if used := billedTokens(t, h, key); used != 40 {
		t.Fatalf("billed %v want 40 (two distinct requests)", used)
	}
}

// A 200 stream that ended in an error frame is not an answer. Replaying it
// would hand the retry a worse result than a fresh dispatch.
func TestIdlessDedupe_TruncatedStreamNotReplayed(t *testing.T) {
	var hits atomic.Int32
	client := idlessStreamingUpstream(&hits, func(pw *io.PipeWriter) {
		_, _ = io.WriteString(pw, `data: {"id":"c","choices":[{"delta":{"content":"partial"}}]}`+"\n\n")
		_ = pw.CloseWithError(errors.New("injected mid-stream upstream failure"))
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_truncated")

	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	first := postChat(t, h, key, body, nil)
	if first.Code != http.StatusOK {
		t.Fatalf("attempt 1 status=%d body=%s", first.Code, first.Body.String())
	}
	if !strings.Contains(first.Body.String(), "provider_disconnected") {
		t.Fatalf("attempt 1 did not emit the mid-stream error envelope: %.300q", first.Body.String())
	}

	second := postChat(t, h, key, body, nil)
	assertNoDedupeReplay(t, second, "retry after a truncated stream")
	if got := hits.Load(); got != 2 {
		t.Fatalf("upstream dispatches=%d want 2 (a truncated 200 must not be cached)", got)
	}
}

// An error terminal is dropped, not cached: the retry re-dispatches exactly as
// it does today.
func TestIdlessDedupe_ErrorAttemptNotReplayed(t *testing.T) {
	var hits atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		hits.Add(1)
		return responseWithBody(http.StatusServiceUnavailable,
			http.Header{"Content-Type": []string{"application/json"}},
			`{"error":{"code":"no_provider_available","message":"No provider available","param":null,"type":"service_unavailable"}}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		// Keep the 503 ladder out of the dispatch count: this test is about
		// caching, not about retry_503.
		cfg.Retry503.Enabled = false
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_error")

	first := postChat(t, h, key, idlessDedupeBody, nil)
	if first.Code != http.StatusServiceUnavailable {
		t.Fatalf("attempt 1 status=%d want 503 body=%s", first.Code, first.Body.String())
	}
	afterFirst := hits.Load()

	second := postChat(t, h, key, idlessDedupeBody, nil)
	if second.Code != http.StatusServiceUnavailable {
		t.Fatalf("attempt 2 status=%d want 503 body=%s", second.Code, second.Body.String())
	}
	assertNoDedupeReplay(t, second, "retry after an error terminal")
	if got := hits.Load(); got <= afterFirst {
		t.Fatalf("upstream dispatches did not increase (%d -> %d): the error terminal was cached", afterFirst, got)
	}
	if used := billedTokens(t, h, key); used != 0 {
		t.Fatalf("billed %v for two refunded errors, want 0", used)
	}
	state := gatewaySettlementSnapshot(t, dbPath, "acct_idless_error")
	if state.activeRows != 0 {
		t.Fatalf("reservations %+v; want no active hold after two refunded errors", state)
	}
}

// Byte-identity of the raw body is the key. Anything that changes the bytes —
// a trailing space, the stream flag — or the sticky conversation tag is a
// different request.
func TestIdlessDedupe_DifferentBodyNotDeduped(t *testing.T) {
	cases := []struct {
		name         string
		first        string
		second       string
		firstHeader  map[string]string
		secondHeader map[string]string
	}{
		{
			name:   "trailing whitespace in content",
			first:  `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`,
			second: `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi "}]}`,
		},
		{
			name:   "stream flag flipped",
			first:  `{"model":"llama","stream":false,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`,
			second: `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`,
		},
		{
			name:         "different conversation tag",
			first:        idlessDedupeBody,
			second:       idlessDedupeBody,
			firstHeader:  map[string]string{"X-MacProvider-Conversation": "thread-1"},
			secondHeader: map[string]string{"X-MacProvider-Conversation": "thread-2"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var hits atomic.Int32
			// Both shapes are answered non-streaming; the "stream flag" case
			// only needs the two attempts to be distinguishable, and the
			// gateway's streaming reader tolerates a JSON body being absent
			// from the cache either way.
			client := idlessStreamingUpstream(&hits, func(pw *io.PipeWriter) {
				_, _ = io.WriteString(pw,
					`data: {"id":"c","usage":{"prompt_tokens":8,"completion_tokens":2,"total_tokens":10},"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}`+
						"\n\n"+`data: [DONE]`+"\n\n")
				_ = pw.Close()
			})
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			key := createAccountAndKey(t, store, cfg, "acct_idless_distinct")

			if r := postChat(t, h, key, tc.first, tc.firstHeader); r.Code != http.StatusOK {
				t.Fatalf("attempt 1 status=%d body=%s", r.Code, r.Body.String())
			}
			second := postChat(t, h, key, tc.second, tc.secondHeader)
			if second.Code != http.StatusOK {
				t.Fatalf("attempt 2 status=%d body=%s", second.Code, second.Body.String())
			}
			assertNoDedupeReplay(t, second, tc.name)
			if got := hits.Load(); got != 2 {
				t.Fatalf("upstream dispatches=%d want 2", got)
			}
		})
	}
}

func TestIdlessDedupe_ResponsesThenChatDoNotShareFingerprint(t *testing.T) {
	var hits atomic.Int32
	var firstUpstreamBody string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		raw, _ := io.ReadAll(r.Body)
		if hits.Load() == 0 {
			firstUpstreamBody = string(raw)
		}
		hits.Add(1)
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_cross_endpoint",
			"object":"chat.completion",
			"created":1782864000,
			"model":"llama",
			"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8},
			"choices":[{"index":0,"message":{"role":"assistant","content":"cross endpoint answer"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_responses_then_chat")
	responsesBody := `{"model":"llama","input":"hi","max_output_tokens":20,"store":false}`

	first := postResponses(t, h, key, responsesBody, nil)
	if first.Code != http.StatusOK {
		t.Fatalf("Responses attempt status=%d body=%s", first.Code, first.Body.String())
	}
	if firstUpstreamBody == "" {
		t.Fatal("Responses attempt did not reach upstream")
	}
	second := postChat(t, h, key, firstUpstreamBody, nil)
	if second.Code != http.StatusOK {
		t.Fatalf("chat attempt status=%d body=%s", second.Code, second.Body.String())
	}
	assertNoDedupeReplay(t, second, "chat after Responses")
	if got := hits.Load(); got != 2 {
		t.Fatalf("upstream dispatches=%d want 2", got)
	}
	var payload map[string]any
	if err := json.Unmarshal(second.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode chat response: %v body=%s", err, second.Body.String())
	}
	if payload["object"] != "chat.completion" {
		t.Fatalf("chat response object=%v want chat.completion body=%s", payload["object"], second.Body.String())
	}
}

func TestIdlessDedupe_ChatThenResponsesDoNotShareFingerprint(t *testing.T) {
	var hits atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		hits.Add(1)
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_cross_endpoint",
			"object":"chat.completion",
			"created":1782864000,
			"model":"llama",
			"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8},
			"choices":[{"index":0,"message":{"role":"assistant","content":"cross endpoint answer"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_chat_then_responses")
	responsesBody := `{"model":"llama","input":"hi","max_output_tokens":20,"store":false}`
	chatBody := translatedResponsesChatBodyForDedupeTest(t, responsesBody)

	first := postChat(t, h, key, chatBody, nil)
	if first.Code != http.StatusOK {
		t.Fatalf("chat attempt status=%d body=%s", first.Code, first.Body.String())
	}
	second := postResponses(t, h, key, responsesBody, nil)
	if second.Code != http.StatusOK {
		t.Fatalf("Responses attempt status=%d body=%s", second.Code, second.Body.String())
	}
	assertNoDedupeReplay(t, second, "Responses after chat")
	if got := hits.Load(); got != 2 {
		t.Fatalf("upstream dispatches=%d want 2", got)
	}
	var payload map[string]any
	if err := json.Unmarshal(second.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode Responses response: %v body=%s", err, second.Body.String())
	}
	if payload["object"] != "response" {
		t.Fatalf("Responses object=%v want response body=%s", payload["object"], second.Body.String())
	}
	if strings.Contains(second.Body.String(), `"choices"`) {
		t.Fatalf("Responses endpoint returned chat wire format: %s", second.Body.String())
	}
}

// ---- opt-outs: higher-precedence dedupe owns the request -------------------

// A client-supplied UUID X-Request-ID already deduped durably (harness H5b).
// #762 must not touch that path: the second attempt still 409s rather than
// silently replaying.
func TestIdlessDedupe_ClientSuppliedIDBypasses(t *testing.T) {
	var hits atomic.Int32
	client := idlessJSONUpstream(seamCompletionJSON, &hits, nil)
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_clientid")

	headers := map[string]string{"X-Request-ID": "11111111-1111-4111-8111-111111111111"}
	if r := postChat(t, h, key, idlessDedupeBody, headers); r.Code != http.StatusOK {
		t.Fatalf("attempt 1 status=%d body=%s", r.Code, r.Body.String())
	}
	second := postChat(t, h, key, idlessDedupeBody, headers)
	if second.Code != http.StatusConflict {
		t.Fatalf("attempt 2 status=%d want 409 body=%s", second.Code, second.Body.String())
	}
	assertErrorCode(t, second.Body.String(), "duplicate_request_id")
	assertNoDedupeReplay(t, second, "client-supplied id")
	if got := hits.Load(); got != 1 {
		t.Fatalf("upstream dispatches=%d want 1", got)
	}
	if used := billedTokens(t, h, key); used != 20 {
		t.Fatalf("billed %v want 20", used)
	}
}

// A buyer-supplied Idempotency-Key is the coordinator's dedupe contract
// (issue #200). The gateway forwards it and passes the coordinator's replay
// verdict through untouched, refunding the attempt.
func TestIdlessDedupe_IdempotencyKeyBypasses(t *testing.T) {
	var hits atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		if r.Header.Get("Idempotency-Key") == "" {
			return responseWithBody(http.StatusBadRequest, nil, `{"error":{"code":"missing_idempotency_key"}}`), nil
		}
		if hits.Add(1) == 1 {
			return responseWithBody(http.StatusOK,
				http.Header{"Content-Type": []string{"application/json"}}, seamCompletionJSON), nil
		}
		return responseWithBody(http.StatusConflict,
			http.Header{"Content-Type": []string{"application/json"}},
			`{"error":{"code":"idempotency_key_replayed","message":"Idempotency key already used","param":null,"type":"invalid_request_error"}}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_idempotency")

	headers := map[string]string{"Idempotency-Key": "idem-762"}
	if r := postChat(t, h, key, idlessDedupeBody, headers); r.Code != http.StatusOK {
		t.Fatalf("attempt 1 status=%d body=%s", r.Code, r.Body.String())
	}
	second := postChat(t, h, key, idlessDedupeBody, headers)
	if second.Code != http.StatusConflict {
		t.Fatalf("attempt 2 status=%d want the coordinator's 409 passthrough; body=%s", second.Code, second.Body.String())
	}
	assertErrorCode(t, second.Body.String(), "idempotency_key_replayed")
	assertNoDedupeReplay(t, second, "idempotency-key request")
	if got := hits.Load(); got != 2 {
		t.Fatalf("upstream dispatches=%d want 2 (the gateway must not shortcut the coordinator's dedupe)", got)
	}
	if used := billedTokens(t, h, key); used != 20 {
		t.Fatalf("billed %v want 20 (the replayed attempt must be refunded)", used)
	}
	state := gatewaySettlementSnapshot(t, dbPath, "acct_idless_idempotency")
	if state.activeRows != 0 {
		t.Fatalf("reservations %+v; want no active hold", state)
	}
}

// The operator kill switch restores the pre-#762 behavior exactly.
func TestIdlessDedupe_DisabledByZeroWindow(t *testing.T) {
	var hits atomic.Int32
	client := idlessJSONUpstream(seamCompletionJSON, &hits, nil)
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Quotas.IdlessDedupeWindowSeconds = 0
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_disabled")

	if r := postChat(t, h, key, idlessDedupeBody, nil); r.Code != http.StatusOK {
		t.Fatalf("attempt 1 status=%d body=%s", r.Code, r.Body.String())
	}
	second := postChat(t, h, key, idlessDedupeBody, nil)
	if second.Code != http.StatusOK {
		t.Fatalf("attempt 2 status=%d body=%s", second.Code, second.Body.String())
	}
	assertNoDedupeReplay(t, second, "kill-switched gateway")
	if got := hits.Load(); got != 2 {
		t.Fatalf("upstream dispatches=%d want 2", got)
	}
	if used := billedTokens(t, h, key); used != 40 {
		t.Fatalf("billed %v want 40 (kill switch must restore the pre-#762 behavior)", used)
	}
}

// ---- index unit tests ------------------------------------------------------

func TestIdlessDedupeIndex_OnlyClaimWinnerPublishesOrDrops(t *testing.T) {
	index := newIdlessDedupeIndex()
	now := fixedNow()
	window := time.Minute

	entry, adopted := index.claim("fp", "req-owner", now, window)
	if adopted {
		t.Fatal("first claim must win the fingerprint")
	}
	if _, adopted := index.claim("fp", "req-second", now, window); !adopted {
		t.Fatal("second claim must adopt the owner's entry")
	}

	// A non-owner cannot publish...
	index.publish("fp", "req-second", http.StatusOK, "application/json", "peer", []byte("intruder"), now)
	if _, ok := index.replaySnapshot(entry, now, window); ok {
		t.Fatal("a non-owner published a response")
	}
	// ...nor drop.
	index.drop("fp", "req-second")
	if index.entries["fp"] != entry {
		t.Fatal("a non-owner dropped the owner's entry")
	}

	index.publish("fp", "req-owner", http.StatusOK, "application/json", "peer", []byte("answer"), now)
	snapshot, ok := index.replaySnapshot(entry, now, window)
	if !ok {
		t.Fatal("owner publish did not make the entry replayable")
	}
	if snapshot.requestID != "req-owner" || string(snapshot.body) != "answer" || snapshot.status != http.StatusOK {
		t.Fatalf("snapshot=%+v", snapshot)
	}
	select {
	case <-entry.done:
	default:
		t.Fatal("publish did not wake parked waiters")
	}

	// Publishing twice must not double-count bytes or reopen the entry.
	before := index.totalBytes
	index.publish("fp", "req-owner", http.StatusOK, "application/json", "peer", []byte("second answer"), now)
	if index.totalBytes != before {
		t.Fatalf("republish changed totalBytes %d -> %d", before, index.totalBytes)
	}
}

func TestIdlessDedupeIndex_DropWakesWaitersAndClearsMapping(t *testing.T) {
	index := newIdlessDedupeIndex()
	now := fixedNow()
	entry, _ := index.claim("fp", "req-owner", now, time.Minute)

	index.drop("fp", "req-owner")
	if _, exists := index.entries["fp"]; exists {
		t.Fatal("drop left the fingerprint mapped")
	}
	select {
	case <-entry.done:
	default:
		t.Fatal("drop did not wake parked waiters")
	}
	if !index.awaitTerminal(context.Background(), entry) {
		t.Fatal("awaitTerminal must return immediately for a dropped entry")
	}
	if _, ok := index.replaySnapshot(entry, now, time.Minute); ok {
		t.Fatal("a dropped entry must never be replayable")
	}
	if got := index.uncacheableTotal.Load(); got != 1 {
		t.Fatalf("uncacheable_total=%d want 1", got)
	}
}

// Memory pressure costs the cached BODY, never the fingerprint→requestID
// mapping: the retry must still adopt attempt 1's id and hit the durable 409.
func TestIdlessDedupeIndex_EvictedBodyKeepsMapping(t *testing.T) {
	index := newIdlessDedupeIndex()
	now := fixedNow()
	window := time.Minute
	entry, _ := index.claim("fp", "req-owner", now, window)
	index.publish("fp", "req-owner", http.StatusOK, "application/json", "peer", []byte("answer"), now)

	index.mu.Lock()
	index.totalBytes = idlessDedupeMaxTotalBytes + 1
	index.evictBodiesLocked()
	index.mu.Unlock()

	mapped, adopted := index.claim("fp", "req-retry", now, window)
	if !adopted {
		t.Fatal("body eviction also dropped the fingerprint mapping")
	}
	if mapped.requestID != "req-owner" {
		t.Fatalf("adopted requestID=%q want the owner's req-owner", mapped.requestID)
	}
	if _, ok := index.replaySnapshot(entry, now, window); ok {
		t.Fatal("an evicted body must not be replayable")
	}
}

func TestIdlessDedupeIndex_ExpiredEntryIsReclaimedFresh(t *testing.T) {
	index := newIdlessDedupeIndex()
	now := fixedNow()
	window := time.Minute
	index.claim("fp", "req-owner", now, window)
	index.publish("fp", "req-owner", http.StatusOK, "application/json", "peer", []byte("answer"), now)

	entry, adopted := index.claim("fp", "req-retry", now.Add(2*time.Minute), window)
	if adopted {
		t.Fatal("a resend past the window must claim a fresh entry")
	}
	if entry.requestID != "req-retry" {
		t.Fatalf("fresh entry requestID=%q want req-retry", entry.requestID)
	}
	if index.totalBytes != 0 {
		t.Fatalf("expired entry leaked %d cached bytes", index.totalBytes)
	}
}

// Body pressure must spend BODIES, never window-valid mappings. A tenant
// churning unique fingerprints past the body cap may cost everyone their
// cached responses; it must not cost anyone their dedupe (and therefore their
// second bill).
func TestIdlessDedupeIndex_BodyPressureKeepsWindowValidMappings(t *testing.T) {
	index := newIdlessDedupeIndex()
	base := fixedNow()
	window := time.Hour

	// The oldest entry: published first, never touched again, so it is the
	// LRU victim for every body eviction that follows.
	index.claim("victim", "req-victim", base, window)
	index.publish("victim", "req-victim", http.StatusOK, "application/json", "", []byte("answer"), base)

	// Churn well past the body cap with unique fingerprints.
	for i := 0; i < idlessDedupeMaxBodies+64; i++ {
		fp := "churn-" + strconv.Itoa(i)
		at := base.Add(time.Duration(i+1) * time.Millisecond)
		index.claim(fp, "req-"+strconv.Itoa(i), at, window)
		index.publish(fp, "req-"+strconv.Itoa(i), http.StatusOK, "application/json", "", []byte("a"), at)
	}

	if got := index.bodyCount; got > idlessDedupeMaxBodies {
		t.Fatalf("bodyCount=%d exceeds the body cap %d", got, idlessDedupeMaxBodies)
	}
	// The mapping — the money-bearing half — survived.
	entry, adopted := index.claim("victim", "req-retry", base.Add(time.Second), window)
	if !adopted {
		t.Fatal("body pressure deleted a window-valid mapping: an id-less retry would now double-bill")
	}
	if entry.requestID != "req-victim" {
		t.Fatalf("adopted requestID=%q want req-victim", entry.requestID)
	}
	if entry.body != nil {
		t.Fatal("the victim kept its body; the test never exercised body eviction")
	}
	if got := index.mappingPressureEvictions.Load(); got != 0 {
		t.Fatalf("mapping_pressure_evictions=%d want 0 (body pressure must not delete mappings)", got)
	}
}

// Only exhausting the far larger MAPPING cap may delete a window-valid
// mapping, and when it does it is counted as the documented residual.
func TestIdlessDedupeIndex_MappingPressureEvictsOldestAndCounts(t *testing.T) {
	index := newIdlessDedupeIndex()
	base := fixedNow()
	window := time.Hour

	for i := 0; i < idlessDedupeMaxMappings; i++ {
		fp := "m-" + strconv.Itoa(i)
		at := base.Add(time.Duration(i) * time.Millisecond)
		index.claim(fp, "req-"+strconv.Itoa(i), at, window)
		// No body: this is purely mapping-table pressure.
		index.publish(fp, "req-"+strconv.Itoa(i), http.StatusOK, "application/json", "", nil, at)
	}
	if got := len(index.entries); got != idlessDedupeMaxMappings {
		t.Fatalf("entries=%d want %d", got, idlessDedupeMaxMappings)
	}
	index.claim("newcomer", "req-new", base.Add(time.Hour/2), window)
	if got := len(index.entries); got > idlessDedupeMaxMappings {
		t.Fatalf("entries=%d exceeds the mapping cap %d", got, idlessDedupeMaxMappings)
	}
	if _, exists := index.entries["m-0"]; exists {
		t.Fatal("the least recently seen mapping survived eviction")
	}
	if got := index.mappingPressureEvictions.Load(); got < 1 {
		t.Fatalf("mapping_pressure_evictions=%d want >= 1 (the residual must be observable)", got)
	}
}

// In-flight entries are never evicted — a parked waiter would be stranded and
// its owner's publish would silently vanish. The in-flight cap is what bounds
// that map instead.
func TestIdlessDedupeIndex_InFlightNeverEvictedAndCapped(t *testing.T) {
	index := newIdlessDedupeIndex()
	base := fixedNow()
	window := time.Hour

	for i := 0; i < idlessDedupeMaxInFlight; i++ {
		if entry, _ := index.claim("inflight-"+strconv.Itoa(i), "req-"+strconv.Itoa(i), base, window); entry == nil {
			t.Fatalf("claim %d was refused below the in-flight cap", i)
		}
	}
	if got := len(index.entries); got != idlessDedupeMaxInFlight {
		t.Fatalf("in-flight entries=%d want %d (an in-flight owner was evicted)", got, idlessDedupeMaxInFlight)
	}
	entry, adopted := index.claim("over-cap", "req-over", base, window)
	if entry != nil || adopted {
		t.Fatalf("claim past the in-flight cap returned (%v, %v); want (nil, false) = skip dedupe", entry, adopted)
	}
	if got := index.inflightCapSkips.Load(); got != 1 {
		t.Fatalf("inflight_cap_skip_total=%d want 1", got)
	}
	// A terminal frees a slot.
	index.publish("inflight-0", "req-0", http.StatusOK, "application/json", "", []byte("a"), base)
	if index.inFlight != idlessDedupeMaxInFlight-1 {
		t.Fatalf("inFlight=%d want %d after one terminal", index.inFlight, idlessDedupeMaxInFlight-1)
	}
	if entry, _ := index.claim("after-terminal", "req-after", base, window); entry == nil {
		t.Fatal("a freed in-flight slot was not reusable")
	}
	// Dropping an in-flight entry frees its slot too.
	index.drop("inflight-1", "req-1")
	if index.inFlight != idlessDedupeMaxInFlight-1 {
		t.Fatalf("inFlight=%d after a drop; the slot was not released", index.inFlight)
	}
}

func TestIdlessDedupeIndex_WaiterCapAndContextExpiry(t *testing.T) {
	index := newIdlessDedupeIndex()
	now := fixedNow()
	entry, _ := index.claim("fp", "req-owner", now, time.Minute)

	// Fill the waiter slots with parked goroutines.
	parked := make(chan bool, idlessDedupeMaxWaiters)
	for i := 0; i < idlessDedupeMaxWaiters; i++ {
		go func() { parked <- index.awaitTerminal(context.Background(), entry) }()
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		index.mu.Lock()
		waiters := entry.waiters
		index.mu.Unlock()
		if waiters == idlessDedupeMaxWaiters {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("only %d of %d waiters parked", waiters, idlessDedupeMaxWaiters)
		}
		time.Sleep(time.Millisecond)
	}
	if index.awaitTerminal(context.Background(), entry) {
		t.Fatal("a waiter over the cap must be rejected, not parked")
	}

	// An expiring request context releases a parked waiter.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if index.awaitTerminal(ctx, entry) {
		t.Fatal("awaitTerminal must report failure when the request context is done")
	}

	index.publish("fp", "req-owner", http.StatusOK, "application/json", "", []byte("a"), now)
	for i := 0; i < idlessDedupeMaxWaiters; i++ {
		if !<-parked {
			t.Fatal("a parked waiter did not observe the owner's terminal")
		}
	}
	if got := index.inflightWaitTotal.Load(); got < int64(idlessDedupeMaxWaiters) {
		t.Fatalf("inflight_wait_total=%d want >= %d", got, idlessDedupeMaxWaiters)
	}
}

func TestIdlessRequestFingerprintIsKeyedOnEveryPart(t *testing.T) {
	base := idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "demo-hash", "thread-1", "", []byte(`{"a":1}`))
	cases := map[string]string{
		"same inputs":            idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "demo-hash", "thread-1", "", []byte(`{"a":1}`)),
		"other entrypoint":       idlessRequestFingerprint(idlessDedupeEntrypointResponses, "acct", "demo-hash", "thread-1", "", []byte(`{"a":1}`)),
		"messages entrypoint":    idlessRequestFingerprint(idlessDedupeEntrypointMessages, "acct", "demo-hash", "thread-1", "", []byte(`{"a":1}`)),
		"other account":       idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct2", "demo-hash", "thread-1", "", []byte(`{"a":1}`)),
		"other demo token":    idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "demo-hash-2", "thread-1", "", []byte(`{"a":1}`)),
		"other conversation":  idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "demo-hash", "thread-2", "", []byte(`{"a":1}`)),
		"retry hint present":  idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "demo-hash", "thread-1", "1", []byte(`{"a":1}`)),
		"other retry hint":    idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "demo-hash", "thread-1", "2", []byte(`{"a":1}`)),
		"other body":          idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "demo-hash", "thread-1", "", []byte(`{"a":2}`)),
		"whitespace in body":  idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "demo-hash", "thread-1", "", []byte(`{"a": 1}`)),
		"field-shifted parts": idlessRequestFingerprint(idlessDedupeEntrypointChat, "acc", "tdemo-hash", "thread-1", "", []byte(`{"a":1}`)),
	}
	for name, got := range cases {
		if name == "same inputs" {
			if got != base {
				t.Fatalf("%s: fingerprint is not stable", name)
			}
			continue
		}
		if got == base {
			t.Fatalf("%s: fingerprint collided with the base request", name)
		}
	}
	if cases["retry hint present"] == cases["other retry hint"] {
		t.Fatal("two different X-MacProvider-Retry values produced the same fingerprint")
	}
}

// failingAfterWriter is an http.ResponseWriter whose underlying writes start
// failing after allowBytes bytes have been accepted — the buyer's socket
// dying mid-stream while the handler is still emitting.
type failingAfterWriter struct {
	*httptest.ResponseRecorder
	allowBytes int
	written    int
}

func (f *failingAfterWriter) Write(b []byte) (int, error) {
	if f.written >= f.allowBytes {
		return 0, errors.New("injected buyer write failure")
	}
	n := len(b)
	if f.written+n > f.allowBytes {
		n = f.allowBytes - f.written
	}
	_, _ = f.ResponseRecorder.Write(b[:n])
	f.written += n
	if n < len(b) {
		return n, errors.New("injected buyer write failure")
	}
	return n, nil
}

func (f *failingAfterWriter) Flush() {}

// Audit R1 (security+code HIGH, finding 2): a mid-stream buyer write failure
// after the 200 commit must poison the capture — the buyer never received the
// full response, so publishing it would replay a partial/not-delivered stream
// to the retry. The retry must re-dispatch.
func TestIdlessDedupe_BuyerWriteFailureNotReplayed(t *testing.T) {
	var hits atomic.Int32
	client := idlessStreamingUpstream(&hits, func(pw *io.PipeWriter) {
		_, _ = io.WriteString(pw, `data: {"id":"c","choices":[{"delta":{"content":"hello world"}}]}`+"\n\n")
		_, _ = io.WriteString(pw, `data: {"id":"c","choices":[{"delta":{"content":"more"}}]}`+"\n\n")
		_, _ = io.WriteString(pw, `data: [DONE]`+"\n\n")
		_ = pw.Close()
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_writefail")

	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	// Accept only the first few bytes, then fail every buyer write.
	fw := &failingAfterWriter{ResponseRecorder: httptest.NewRecorder(), allowBytes: 10}
	h.ServeHTTP(fw, req)

	second := postChat(t, h, key, body, nil)
	assertNoDedupeReplay(t, second, "retry after a buyer write failure")
	if second.Code != http.StatusOK {
		t.Fatalf("retry status=%d body=%s", second.Code, second.Body.String())
	}
	if got := hits.Load(); got != 2 {
		t.Fatalf("upstream dispatches=%d want 2 (a partially-delivered 200 must not be cached)", got)
	}
}

// panicWriter panics on the second buyer write — a mid-handler panic in the
// handler goroutine after the 200 commit (the statusWriter methods run on the
// handler goroutine, unlike upstream Body reads, which #760 moved to a reader
// goroutine where a panic would be process-fatal for any request).
type panicWriter struct {
	*httptest.ResponseRecorder
	writes int
}

func (p *panicWriter) Write(b []byte) (int, error) {
	p.writes++
	// Panic exactly once, on the second buyer write - later writes (the
	// recovery middleware error body) must succeed or the middleware own
	// recover would re-crash.
	if p.writes == 2 {
		panic("injected mid-handler panic")
	}
	return p.ResponseRecorder.Write(b)
}

func (p *panicWriter) Flush() {}

// Audit R1 (architect LOW, finding 5): a mid-handler panic after the 200
// commit unwinds through the owner's publish defer. The defer must DROP the
// entry (never publish the partial capture) and re-panic so the recovery
// middleware still handles it. The retry must re-dispatch.
func TestIdlessDedupe_HandlerPanicDropsEntryAndRepanics(t *testing.T) {
	var hits atomic.Int32
	client := idlessStreamingUpstream(&hits, func(pw *io.PipeWriter) {
		_, _ = io.WriteString(pw, `data: {"id":"c","choices":[{"delta":{"content":"one"}}]}`+"\n\n")
		_, _ = io.WriteString(pw, `data: {"id":"c","choices":[{"delta":{"content":"two"}}]}`+"\n\n")
		_, _ = io.WriteString(pw, `data: [DONE]`+"\n\n")
		_ = pw.Close()
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_panic")

	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	pw := &panicWriter{ResponseRecorder: httptest.NewRecorder()}
	// The dedupe defer must recover, drop, and re-panic; the recovery
	// middleware then swallows it, so ServeHTTP returns normally.
	h.ServeHTTP(pw, req)

	second := postChat(t, h, key, body, nil)
	assertNoDedupeReplay(t, second, "retry after a mid-handler panic")
	if !strings.Contains(second.Body.String(), "data: [DONE]") {
		t.Fatalf("retry did not stream a fresh completion: %.300q", second.Body.String())
	}
	if got := hits.Load(); got != 2 {
		t.Fatalf("upstream dispatches=%d want 2 (a panicked attempt must be dropped, not cached)", got)
	}
}

// Audit R2 (code HIGH): a COMPLETE, delivered, billed 2xx whose body merely
// exceeded the 1 MiB replay cap must keep its fp->request_id mapping as a
// body-less stub — the identical id-less retry adopts the id and lands on the
// durable 409 (billed once). Dropping the mapping would let the retry mint a
// fresh id, re-dispatch, and bill again.
func TestIdlessDedupe_OversizedDelivered2xxKeepsMappingStub(t *testing.T) {
	big := strings.Repeat("x", (1<<20)+4096) // > replay cap, < upstream body cap
	bodyJSON := `{"id":"chatcmpl_big","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"` + big + `"},"finish_reason":"stop"}]}`
	var hits atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		hits.Add(1)
		return responseWithBody(http.StatusOK,
			http.Header{"Content-Type": []string{"application/json"}}, bodyJSON), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_idless_oversize")

	body := `{"model":"llama","stream":false,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	first := postChat(t, h, key, body, nil)
	if first.Code != http.StatusOK {
		t.Fatalf("attempt 1 status=%d", first.Code)
	}

	second := postChat(t, h, key, body, nil)
	if second.Code != http.StatusConflict {
		t.Fatalf("retry of an oversized delivered 2xx must hit the durable 409 via the "+
			"mapping stub, got %d body=%.200q", second.Code, second.Body.String())
	}
	assertErrorCode(t, second.Body.String(), "duplicate_request_id")
	if got := hits.Load(); got != 1 {
		t.Fatalf("upstream dispatches=%d want 1 (the mapping stub must prevent re-dispatch)", got)
	}
	if outcome, _ := usageEventOutcome(t, dbPath, "acct_idless_oversize"); outcome != "ok" {
		t.Fatalf("usage outcome=%q want ok (billed exactly once, by attempt 1)", outcome)
	}
}
