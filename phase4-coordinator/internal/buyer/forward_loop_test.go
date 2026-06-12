package buyer_test

// M2-1c regression suite — pins the attempt_n / logAttempt row sequence
// in the four scenarios called out in audits/2026-06-10/REPO_AUDIT.md
// §3.1 item 3 (ARCH-1 / CODE-1) as the byte-identity gate for the
// strangler refactor that collapses the three transport loops into
// forwardWithFailover. Any drift here means the billing ledger format
// has shifted under the refactor — orchestrator must STOP and review.
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
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// Scenario 1: HTTP success on first attempt. One row, retried=0.
func TestM2_1C_RowSequence_HTTPSuccessFirstAttempt(t *testing.T) {
	const requestID = "aaaaaaaa-1111-4111-8111-111111111111"
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}))
	defer failUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: reqID, Seq: 0, Data: "data: partial\n\n"}
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
	if !bytes.Contains(rr.Body.Bytes(), []byte("data: partial")) {
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
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" {
				// Drive into wsForwardProviderDisconnected — pre-commit.
				errs <- providerws.ErrRelayClosed
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
		t.Fatalf("provider = %q, want p2 (after failover)", rr.Header().Get("X-MacProvider-Provider"))
	}
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
