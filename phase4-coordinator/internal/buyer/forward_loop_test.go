package buyer_test

// M2-1c regression suite — pins the attempt_n / logAttempt row sequence
// in the four scenarios called out in audits/2026-06-10/REPO_AUDIT.md
// §3.1 item 3 (ARCH-1 / CODE-1) as the highest-risk billing-ledger
// invariants for the strangler refactor that collapses the three
// transport loops into three transport-typed sequence helpers
// (forwardStreamSequence, forwardWSNonStreamSequence,
// forwardHTTPSequence) sharing transportResult + *forwardState.
//
// Scope: this suite pins ROW SEQUENCE invariants (count, provider
// assignment, status code, retried column) — not full byte-identity
// across every request_log column. Routing_ms, billing attempt_n,
// stream/buyer_ip/error column content remain covered by the broader
// buyer test suite (TestRequestLogBuyerMultiAttemptRows et al.). Any
// drift here means the billing-ledger row sequence or retry
// accounting has shifted under the refactor — orchestrator MUST STOP
// and review.
//
// The four scenarios:
//
//  1. HTTP success on first attempt — one row, status=200, retried=0.
//  2. HTTP 502 → advanceToNextProvider → HTTP 200 — two rows,
//     (502, retried=0) then (200, retried=1). The HTTP retry pattern
//     bumps explicitRetries; the success row reflects the bumped value.
//  3. Streaming first-chunk received → provider disconnects — one row,
//     status=200, committed semantics (no retry attempt logged).
//  4. WS-non-streaming wsForwardProviderDisconnected → failoverCandidate
//     → success on a second WS provider. Two rows: (502, retried=0 —
//     failover does NOT bump explicitRetries because failoverCandidate
//     is a same-attempt re-route, not a retry) then (200, retried=0).
//     This pins the audit-cited failoverEligible-only-WS-non-streaming
//     path: the classifier sets failoverEligible=true + retryable=false,
//     the unified loop branches on the flag pair to enter the failover
//     branch and skip the explicitRetries++ that advanceToNextProvider
//     would have done.

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

func assertTimingHeaderPresent(t *testing.T, h http.Header, name string) int64 {
	t.Helper()
	raw := h.Get(name)
	if raw == "" {
		t.Fatalf("%s missing", name)
	}
	value, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		t.Fatalf("%s = %q, want integer milliseconds", name, raw)
	}
	if value < 0 {
		t.Fatalf("%s = %d, want non-negative milliseconds", name, value)
	}
	return value
}

func assertTimingHeaderBelow(t *testing.T, h http.Header, name string, maxExclusive int64) {
	t.Helper()
	if value := assertTimingHeaderPresent(t, h, name); value >= maxExclusive {
		t.Fatalf("%s = %d, want below %d to prove final-attempt timing did not include the failed first attempt", name, value, maxExclusive)
	}
}

func assertTimingHeaderAtLeast(t *testing.T, h http.Header, name string, minInclusive int64) {
	t.Helper()
	if value := assertTimingHeaderPresent(t, h, name); value < minInclusive {
		t.Fatalf("%s = %d, want at least %d", name, value, minInclusive)
	}
}

// Scenario 1: HTTP success on first attempt. One row, retried=0.
func TestM2_1C_RowSequence_HTTPSuccessFirstAttempt(t *testing.T) {
	const requestID = "aaaaaaaa-1111-4111-8111-111111111111"
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		time.Sleep(120 * time.Millisecond)
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "ok", "s1", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:       1,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
		"X-Request-ID": []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	assertTimingHeaderAtLeast(t, rr.Header(), "X-MacProvider-Timing-Provider-Prefill-Ms", 80)
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("request_log rows = %d, want 1: %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusOK {
		t.Fatalf("rows[0].Status = %d, want 200", rows[0].Status)
	}
	if rows[0].Retried != 0 {
		t.Fatalf("rows[0].Retried = %d, want 0", rows[0].Retried)
	}
	if rows[0].ProviderAssignedID.String != "s1" {
		t.Fatalf("rows[0].ProviderAssignedID = %q, want s1", rows[0].ProviderAssignedID.String)
	}
}

// Scenario 2: HTTP 502 → advance → HTTP 200. Two rows with explicit
// retried-column assertions. Sister to TestRequestLogBuyerMultiAttemptRows
// but framed against the M2-1c invariants explicitly.
func TestM2_1C_RowSequence_HTTPRetryToSuccess(t *testing.T) {
	const requestID = "bbbbbbbb-2222-4222-8222-222222222222"
	failUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}))
	defer failUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(10 * time.Millisecond)
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "fail", EndpointURL: failUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "fail", "s1", "model-a", pool.StateReady, 20000, 1, failUpstream.URL, 30)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 1,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
		"X-MacProvider-Retry": []string{"1"},
		"X-Request-ID":        []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	assertTimingHeaderBelow(t, rr.Header(), "X-MacProvider-Timing-Provider-Dispatch-Ms", 150)
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2: %#v", len(rows), rows)
	}
	// Pin: row 0 = failed provider with 502 and retried=0 (HTTP failure
	// row is logged BEFORE advanceToNextProvider bumps explicitRetries).
	if rows[0].ProviderAssignedID.String != "s1" {
		t.Fatalf("rows[0].ProviderAssignedID = %q, want s1", rows[0].ProviderAssignedID.String)
	}
	if rows[0].Status != http.StatusBadGateway {
		t.Fatalf("rows[0].Status = %d, want 502", rows[0].Status)
	}
	if rows[0].Retried != 0 {
		t.Fatalf("rows[0].Retried = %d, want 0", rows[0].Retried)
	}
	// Pin: row 1 = success provider with 200 and retried=1 (success row
	// is logged AFTER advanceToNextProvider bumped explicitRetries to 1).
	if rows[1].ProviderAssignedID.String != "s2" {
		t.Fatalf("rows[1].ProviderAssignedID = %q, want s2", rows[1].ProviderAssignedID.String)
	}
	if rows[1].Status != http.StatusOK {
		t.Fatalf("rows[1].Status = %d, want 200", rows[1].Status)
	}
	if rows[1].Retried != 1 {
		t.Fatalf("rows[1].Retried = %d, want 1", rows[1].Retried)
	}
}

// Scenario 3: Streaming first-chunk received → provider disconnects.
// One row only, status=200. Committed early-exit semantics: classifier
// sets committed=true, the loop returns without advancing — even though
// the provider died, no retry/failover is attempted because the buyer
// has already received bytes on the wire.
func TestM2_1C_RowSequence_StreamingCommittedSingleRow(t *testing.T) {
	const requestID = "cccccccc-3333-4333-8333-333333333333"
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()

	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "ws", "s1", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:       1,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
		}),
		// Mirrors TestChatCompletionsWSTunneledStreamingDeadProvider-
		// AfterFirstByteTerminatesSSE: deliver the chunk on a buffered
		// channel first, then sleep briefly before sending ErrRelayClosed
		// on an unbuffered channel. Without the sleep there's a race
		// where the select picks the error first (pre-commit) and we
		// hit wsForwardProviderDisconnected instead of *Committed.
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, reqID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd)
			errs := make(chan error)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: reqID, Seq: 0, Data: `data: {"choices":[{"delta":{"content":"partial"}}]}` + "\n\n"}
			go func() {
				time.Sleep(10 * time.Millisecond)
				errs <- providerws.ErrRelayClosed
			}()
			return &providerws.RelayStream{RequestID: reqID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, 5*time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{
		"X-Request-ID": []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	// One chunk emitted before the relay closes; the buyer must have
	// written it (committed=true) before the disconnect was observed.
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"partial"`)) {
		t.Fatalf("body missing committed chunk; body=%s", rr.Body.String())
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("committed-stream rows = %d, want 1 (no retry, no failover): %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusOK {
		t.Fatalf("rows[0].Status = %d, want 200 (committed = OK)", rows[0].Status)
	}
	if rows[0].Retried != 0 {
		t.Fatalf("rows[0].Retried = %d, want 0 (committed → no advance)", rows[0].Retried)
	}
	if rows[0].ProviderAssignedID.String != "s1" {
		t.Fatalf("rows[0].ProviderAssignedID = %q, want s1", rows[0].ProviderAssignedID.String)
	}
}

// Scenario 4: WS-non-streaming wsForwardProviderDisconnected →
// failoverCandidate → success on a second WS provider. Two rows.
//
// CRITICAL pin: failover does NOT bump explicitRetries. Both rows have
// retried=0. This is the most subtle invariant of the M2-1c refactor.
// Pre-1c the failoverCandidate path at server.go:1217-1237 set
// `failoverAttempted = true; provider = next` without any
// explicitRetries++; post-1c the classifyWSResult flags
// failoverEligible=true with retryable=false, and the unified loop's
// failover branch must do the same — re-route in-attempt without
// bumping the retry counter. The success row's retried=0 is the
// observable byte-identity check for this invariant.
func TestM2_1C_RowSequence_WSNonStreamingFailoverDoesNotBumpRetried(t *testing.T) {
	const requestID = "dddddddd-4444-4444-8444-444444444444"
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()

	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 2, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithFailoverConfig(true, 50*time.Millisecond),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:       1,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, reqID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 2)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" {
				// Drive into wsForwardProviderDisconnected — pre-commit.
				time.Sleep(200 * time.Millisecond)
				return nil, providerws.ErrRelayClosed
			}
			go func() {
				chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: reqID, Seq: 0, Data: ""}
				time.Sleep(120 * time.Millisecond)
				chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: reqID, Seq: 1, Data: `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`}
				done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: reqID, Status: "complete", ChunksSent: 2}
			}()
			return &providerws.RelayStream{RequestID: reqID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
		"X-Request-ID": []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("provider = %q, want p2 (after failover)", rr.Header().Get("X-MacProvider-Provider"))
	}
	assertTimingHeaderBelow(t, rr.Header(), "X-MacProvider-Timing-Provider-Dispatch-Ms", 150)
	assertTimingHeaderAtLeast(t, rr.Header(), "X-MacProvider-Timing-Provider-Prefill-Ms", 80)
	assertTimingHeaderBelow(t, rr.Header(), "X-MacProvider-Timing-Provider-Decode-Ms", 150)
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2 (failover-disconnect then success): %#v", len(rows), rows)
	}
	// Pin: row 0 = p1 disconnect with 502, retried=0 (pre-failover).
	if rows[0].ProviderAssignedID.String != "s1" {
		t.Fatalf("rows[0].ProviderAssignedID = %q, want s1", rows[0].ProviderAssignedID.String)
	}
	if rows[0].Status != http.StatusBadGateway {
		t.Fatalf("rows[0].Status = %d, want 502", rows[0].Status)
	}
	if rows[0].Retried != 0 {
		t.Fatalf("rows[0].Retried = %d, want 0", rows[0].Retried)
	}
	// CRITICAL: row 1 = p2 success with 200 and retried=0.
	// failoverCandidate is a same-attempt re-route — it MUST NOT bump
	// explicitRetries. If this fires with retried=1, the M2-1c unified
	// loop has accidentally treated failover as a retry, drifting from
	// pre-refactor behaviour at server.go:1230-1233. Billing-ledger
	// fault attribution depends on this being 0.
	if rows[1].ProviderAssignedID.String != "s2" {
		t.Fatalf("rows[1].ProviderAssignedID = %q, want s2", rows[1].ProviderAssignedID.String)
	}
	if rows[1].Status != http.StatusOK {
		t.Fatalf("rows[1].Status = %d, want 200", rows[1].Status)
	}
	if rows[1].Retried != 0 {
		t.Fatalf("rows[1].Retried = %d, want 0 (failover ≠ retry — must not bump explicitRetries)", rows[1].Retried)
	}
}

// Scenario 6 (issue #92): HTTP-streaming provider returns 200 OK then
// disconnects with zero body bytes. PRE-FIX (server.go:2086 WriteHeader
// before first read) this returned wsForwardProviderDisconnectedCommitted
// → classifier set committed=true → terminal exit, no failover, buyer
// observed 200 + empty body. Revenue-gaming surface: provider could
// collect attribution credit for doing zero work.
//
// POST-FIX: forwardStreaming peeks the first body byte before WriteHeader.
// Zero-body upstream returns wsForwardProviderDisconnected (classifier
// sets retryable=true + failoverEligible=true), unified loop advances
// to a healthy provider, buyer sees a normal SSE stream from provider #2.
//
// Pins:
//   - 2 logAttempt rows (zero-body then success)
//   - row 0 status = 502 (NOT 200 — Committed-with-zero-body is the bug)
//   - row 1 served by the second provider with retried=1
func TestM92_RowSequence_HTTPStreamingZeroBodyTriggersFailover(t *testing.T) {
	const requestID = "ffffffff-9292-4292-8292-929292929292"
	badUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Send 200 OK with no body bytes. Handler returns immediately;
		// net/http closes the response with Content-Length: 0, the
		// buyer's resp.Body EOFs on first read.
		w.WriteHeader(http.StatusOK)
	}))
	defer badUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte("data: {\"id\":\"ok\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1,\"total_tokens\":3}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "bad", EndpointURL: badUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "bad", "s1", "model-a", pool.StateReady, 20000, 1, badUpstream.URL, 30)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 5,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{
		"X-MacProvider-Retry": []string{"1"},
		"X-Request-ID":        []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "ok" {
		t.Fatalf("provider = %q, want ok (after failover from zero-body provider)", rr.Header().Get("X-MacProvider-Provider"))
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"ok"`)) {
		t.Fatalf("body missing failover provider's stream; body=%s", rr.Body.String())
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2 (zero-body then success): %#v", len(rows), rows)
	}
	// Row 0: bad provider returned 200-with-zero-body. POST-FIX this is
	// logged as 502 (Disconnected, not Committed/200). If this is 200, the
	// fix has regressed and revenue-gaming is back.
	if rows[0].ProviderAssignedID.String != "s1" {
		t.Fatalf("rows[0].ProviderAssignedID = %q, want s1", rows[0].ProviderAssignedID.String)
	}
	if rows[0].Status != http.StatusBadGateway {
		t.Fatalf("rows[0].Status = %d, want 502 (zero-body MUST NOT be logged as 200 Committed)", rows[0].Status)
	}
	if rows[0].Retried != 0 {
		t.Fatalf("rows[0].Retried = %d, want 0", rows[0].Retried)
	}
	// Row 1: ok provider served the actual stream after the buyer's
	// failover/retry. retried=1 because zero-body Disconnected (retryable=true)
	// goes through advanceToNextProvider → explicitRetries++.
	if rows[1].ProviderAssignedID.String != "s2" {
		t.Fatalf("rows[1].ProviderAssignedID = %q, want s2", rows[1].ProviderAssignedID.String)
	}
	if rows[1].Status != http.StatusOK {
		t.Fatalf("rows[1].Status = %d, want 200", rows[1].Status)
	}
	if rows[1].Retried != 1 {
		t.Fatalf("rows[1].Retried = %d, want 1 (zero-body Disconnected = retryable; advance bumps retries)", rows[1].Retried)
	}
}

// Scenario 7 (issue #92 codex audit MAJOR): HTTP-streaming provider sends
// exactly 1 byte then EOFs. The initial #92 fix (Peek(1)) considered this
// "first byte received" and committed 200 OK + sticky to the provider,
// which let the provider collect attribution credit for ~zero work. The
// final fix requires a complete first SSE event (\n\n terminator after at
// least one non-blank line) before commit. The 1-byte body fails the
// non-blank-then-blank check and triggers failover.
func TestM92_RowSequence_HTTPStreamingOneBytePartialTriggersFailover(t *testing.T) {
	const requestID = "11111111-9201-4201-8201-111111111111"
	// Distinctive sentinel — a regex-unfriendly two-byte payload that cannot
	// appear in the legitimate failover stream below, so the body assertion
	// can be a clean unconditional "sentinel must not leak".
	const badSentinel = "\xfb\xad"
	badUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte(badSentinel))
	}))
	defer badUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte("data: {\"id\":\"ok\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1,\"total_tokens\":3}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "bad", EndpointURL: badUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "bad", "s1", "model-a", pool.StateReady, 20000, 1, badUpstream.URL, 30)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 5,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{
		"X-MacProvider-Retry": []string{"1"},
		"X-Request-ID":        []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "ok" {
		t.Fatalf("provider = %q, want ok (after failover from 1-byte-EOF provider)", rr.Header().Get("X-MacProvider-Provider"))
	}
	if bytes.Contains(rr.Body.Bytes(), []byte(badSentinel)) {
		t.Fatalf("buyer body leaked the malicious pre-commit sentinel %q; body=%q", badSentinel, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"ok"`)) {
		t.Fatalf("body missing failover provider's stream; body=%q", rr.Body.String())
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2 (1-byte then success): %#v", len(rows), rows)
	}
	if rows[0].ProviderAssignedID.String != "s1" || rows[0].Status != http.StatusBadGateway || rows[0].Retried != 0 {
		t.Fatalf("rows[0] = %+v, want s1/502/retried=0 (1-byte body MUST NOT be Committed)", rows[0])
	}
	if rows[1].ProviderAssignedID.String != "s2" || rows[1].Status != http.StatusOK || rows[1].Retried != 1 {
		t.Fatalf("rows[1] = %+v, want s2/200/retried=1", rows[1])
	}
}

// Scenario 8 (issue #92): POSITIVE COVERAGE — legitimate provider sends
// its first SSE event after a brief delay. This is not a revert-sensitive
// regression test (a slow-but-valid stream also succeeded pre-fix); kept
// to assert that the protocol-aware threshold does NOT accidentally fail
// over legitimate slow providers. The real revert-sensitive coverage for
// the protocol-aware threshold lives in Scenarios 9 and 10.
func TestM92_RowSequence_HTTPStreamingSlowFirstEventCommits(t *testing.T) {
	const requestID = "22222222-9202-4202-8202-222222222222"
	slowUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		time.Sleep(50 * time.Millisecond)
		_, _ = w.Write([]byte("data: {\"id\":\"slow\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1,\"total_tokens\":3}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer slowUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "slow", EndpointURL: slowUpstream.URL},
	})
	registerWithEndpoint(registry, "slow", "s1", "model-a", pool.StateReady, 20000, 1, slowUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 5,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{
		"X-Request-ID": []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"hi"`)) {
		t.Fatalf("body missing slow provider's stream; body=%s", rr.Body.String())
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("slow-first-event rows = %d, want 1 (no failover, single committed success): %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusOK || rows[0].Retried != 0 || rows[0].ProviderAssignedID.String != "s1" {
		t.Fatalf("rows[0] = %+v, want s1/200/retried=0", rows[0])
	}
}

// Scenario 9 (issue #92 codex r2 MAJOR): SSE-comment-only provider. Sends
// `:\n\n` (a single SSE keep-alive comment + event terminator) then EOFs.
// Pre-r2 fix this committed as success because the threshold was "first
// non-blank line followed by blank line" — a comment line is non-blank.
// Post-r2 fix the threshold is "first commit-worthy data: chunk" — comment
// lines don't qualify, so this fails over to a healthy provider.
func TestM92_RowSequence_HTTPStreamingCommentOnlyTriggersFailover(t *testing.T) {
	const requestID = "33333333-9203-4203-8203-333333333333"
	badUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte(":\n\n"))
	}))
	defer badUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte("data: {\"id\":\"ok\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1,\"total_tokens\":3}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "bad", EndpointURL: badUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "bad", "s1", "model-a", pool.StateReady, 20000, 1, badUpstream.URL, 30)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 5,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{
		"X-MacProvider-Retry": []string{"1"},
		"X-Request-ID":        []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "ok" {
		t.Fatalf("provider = %q, want ok (after failover from comment-only provider)", rr.Header().Get("X-MacProvider-Provider"))
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2 (comment-only then success): %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusBadGateway || rows[0].Retried != 0 {
		t.Fatalf("rows[0] = %+v, want 502/retried=0 (comment-only MUST NOT be Committed)", rows[0])
	}
	if rows[1].Status != http.StatusOK || rows[1].Retried != 1 {
		t.Fatalf("rows[1] = %+v, want 200/retried=1", rows[1])
	}
}

// Scenario 10 (issue #92 codex r2 MAJOR): terminator-literal-only provider.
// Sends `data: [DONE]\n\n` (OpenAI stream-end marker, no preceding content
// chunk) then EOFs. Pre-r2 fix this committed because the line is non-blank
// and JSON-shape isn't validated. Post-r2 fix isCommitWorthyDataLine rejects
// the literal `[DONE]` payload, so this fails over.
func TestM92_RowSequence_HTTPStreamingDoneOnlyTriggersFailover(t *testing.T) {
	const requestID = "44444444-9204-4204-8204-444444444444"
	badUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer badUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte("data: {\"id\":\"ok\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1,\"total_tokens\":3}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "bad", EndpointURL: badUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "bad", "s1", "model-a", pool.StateReady, 20000, 1, badUpstream.URL, 30)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 5,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{
		"X-MacProvider-Retry": []string{"1"},
		"X-Request-ID":        []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "ok" {
		t.Fatalf("provider = %q, want ok (after failover from [DONE]-only provider)", rr.Header().Get("X-MacProvider-Provider"))
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2 ([DONE]-only then success): %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusBadGateway || rows[0].Retried != 0 {
		t.Fatalf("rows[0] = %+v, want 502/retried=0 (data: [DONE] alone MUST NOT be Committed)", rows[0])
	}
	if rows[1].Status != http.StatusOK || rows[1].Retried != 1 {
		t.Fatalf("rows[1] = %+v, want 200/retried=1", rows[1])
	}
}

func TestSpec018_HTTPStreamingMalformedToolCallsThenContentTriggersFailover(t *testing.T) {
	const requestID = "55555555-1818-4818-8818-555555555555"
	badUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{}]}}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"must-not-commit\"}}]}\n\n"))
	}))
	defer badUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte("data: {\"id\":\"ok\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1,\"total_tokens\":3}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "bad", EndpointURL: badUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "bad", "s1", "model-a", pool.StateReady, 20000, 1, badUpstream.URL, 30)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 5,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{
		"X-MacProvider-Retry": []string{"1"},
		"X-Request-ID":        []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "ok" {
		t.Fatalf("provider = %q, want ok (after failover from malformed tool_calls provider)", rr.Header().Get("X-MacProvider-Provider"))
	}
	if bytes.Contains(rr.Body.Bytes(), []byte("must-not-commit")) {
		t.Fatalf("malformed pre-commit provider bytes reached buyer: %s", rr.Body.String())
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2 (malformed tool_calls then success): %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusBadGateway || rows[0].Retried != 0 {
		t.Fatalf("rows[0] = %+v, want 502/retried=0 (malformed pre-commit tool_calls MUST NOT be Committed)", rows[0])
	}
	if rows[1].Status != http.StatusOK || rows[1].Retried != 1 {
		t.Fatalf("rows[1] = %+v, want 200/retried=1", rows[1])
	}
}

// Scenario 11 (issue #92 codex r4 MINOR): legitimate provider first event
// is a usage-only chunk (OpenAI shape when stream_options.include_usage=true
// is set with no content chunks beforehand — rare but valid). The commit
// predicate's `usage` branch must accept this, the pre-commit flow must
// commit, and the buyer must see one successful row. Locks the security
// boundary against future tightening that accidentally rejects the
// legitimate usage-only path.
func TestM92_RowSequence_HTTPStreamingUsageOnlyFirstChunkCommits(t *testing.T) {
	const requestID = "55555555-9205-4205-8205-555555555555"
	usageUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"total_tokens\":6}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer usageUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "usage", EndpointURL: usageUpstream.URL},
	})
	registerWithEndpoint(registry, "usage", "s1", "model-a", pool.StateReady, 20000, 1, usageUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 5,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{
		"X-Request-ID": []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("usage-only-first-chunk rows = %d, want 1 (no failover, single committed success): %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusOK || rows[0].Retried != 0 || rows[0].ProviderAssignedID.String != "s1" {
		t.Fatalf("rows[0] = %+v, want s1/200/retried=0", rows[0])
	}
}

// Scenario 5 (M2-1d): WS-non-streaming queue-full → advance → success.
//
// Pins the Q3 close-out from the post-merge architect verification of
// PR #91. Pre-M2-1d the queue-full branch at server.go:1357-1367
// inline-mutated state.explicitRetries / state.faultedProviders and
// called selectProviderExcluding directly — bypassing the shared
// advanceToNextProvider helper that M2-1a (PR #48) hoisted exactly to
// centralize this mutation. M2-1d routes queue-full through
// advanceToNextProvider; this test pins the resulting row sequence.
//
// CRITICAL pins (byte-identical to PR #91 baseline):
//   - 2 logAttempt rows: (503 queue-full row, retried=0) then
//     (200 success row, retried=1). Status 503 comes from
//     wsEndHTTPStatus("error_queue_full") → ServiceUnavailable
//     populated into attempt.Status at server.go:1669; logAttempt's
//     "use attempt.Status when non-zero, else fallback" rule means
//     the 502 fallback passed by the helper is overridden. This is
//     identical to PR #91 baseline behaviour.
//   - Queue-full IS treated as an explicit retry — explicitRetries
//     bumps from 0 to 1 across the advance. This matches the pre-M2-1d
//     behaviour at the removed server.go:1364-1365 inline
//     state.explicitRetries++ / state.faultedProviders++ pair. Q3 is
//     a structural/routing fix, NOT a semantic change — the billing
//     ledger row sequence stays identical.
//   - p1 must be marked StateBusy (queue-full classifier sets
//     markBusy=true; the helper calls pool.MarkState before advancing).
func TestM2_1D_RowSequence_WSNonStreamingQueueFullThroughAdvance(t *testing.T) {
	const requestID = "eeeeeeee-5555-4555-8555-555555555555"
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()

	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 2, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:       1,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, reqID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" {
				// Drive into wsForwardQueueFull via end.Status="error_queue_full".
				done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: reqID, Status: "error_queue_full"}
				return &providerws.RelayStream{RequestID: reqID, Chunks: chunks, Done: done, Errors: errs}, nil
			}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: reqID, Seq: 0, Data: `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: reqID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: reqID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
		"X-Request-ID": []string{requestID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("provider = %q, want p2 (after queue-full advance)", rr.Header().Get("X-MacProvider-Provider"))
	}
	// p1 must have been MarkState(Busy) before the advance — markBusy=true
	// classifier flag drives pool.MarkState in the queue-full helper branch.
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateBusy {
		t.Fatalf("p1 state = %v ok=%v, want StateBusy after queue-full", p1.State, ok)
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2 (queue-full then success): %#v", len(rows), rows)
	}
	// Pin: row 0 = p1 queue-full with 502 and retried=0
	// (queue-full row is logged BEFORE advanceToNextProvider bumps
	// explicitRetries — matches pre-M2-1d row order at server.go:1354).
	if rows[0].ProviderAssignedID.String != "s1" {
		t.Fatalf("rows[0].ProviderAssignedID = %q, want s1", rows[0].ProviderAssignedID.String)
	}
	if rows[0].Status != http.StatusServiceUnavailable {
		t.Fatalf("rows[0].Status = %d, want 503 (wsEndHTTPStatus(error_queue_full))", rows[0].Status)
	}
	if rows[0].Retried != 0 {
		t.Fatalf("rows[0].Retried = %d, want 0 (pre-advance)", rows[0].Retried)
	}
	// CRITICAL: row 1 = p2 success with 200 and retried=1.
	// Queue-full IS an explicit retry — advanceToNextProvider bumps
	// state.explicitRetries from 0 to 1, and the success row carries
	// the bumped value. This is byte-identical to the pre-M2-1d
	// inline state.explicitRetries++ at the removed server.go:1364.
	// If this row has retried=0, the Q3 fix has accidentally treated
	// queue-full as failover (no retry-bump) — billing ledger drift.
	if rows[1].ProviderAssignedID.String != "s2" {
		t.Fatalf("rows[1].ProviderAssignedID = %q, want s2", rows[1].ProviderAssignedID.String)
	}
	if rows[1].Status != http.StatusOK {
		t.Fatalf("rows[1].Status = %d, want 200", rows[1].Status)
	}
	if rows[1].Retried != 1 {
		t.Fatalf("rows[1].Retried = %d, want 1 (queue-full = explicit retry; must bump explicitRetries)", rows[1].Retried)
	}
}
