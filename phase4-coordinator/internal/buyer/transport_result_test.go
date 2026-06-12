package buyer

import (
	"errors"
	"net/http"
	"testing"
)

// These tests pin the M2-1b classifier behaviour. They are documentation
// of the audit-confirmed per-transport differences: failoverEligible is
// WS-only (both classifyWSResult on non-streaming disconnect AND
// classifyStreamResult on streaming pre-first-chunk disconnect — never
// HTTP); committed is streaming-only; the HTTP path uses retryable for
// every non-200, etc. M2-1c's unified loop will lean on these flags,
// so any future flattening becomes a test failure.

func TestClassifyWSResultBehaviourFlags(t *testing.T) {
	cases := []struct {
		name             string
		result           wsForwardResult
		wantStatus       int
		wantRetryable    bool
		wantFailover     bool
		wantMarkBusy     bool
		wantCancelled    bool
		wantCommitted    bool
	}{
		{"complete", wsForwardComplete, http.StatusOK, false, false, false, false, false},
		{"timed_out", wsForwardTimedOut, http.StatusGatewayTimeout, true, false, false, false, false},
		{"queue_full", wsForwardQueueFull, statusForForwardResult(wsForwardQueueFull), true, false, true, false, false},
		// Non-streaming WS disconnect: failoverEligible=true, but
		// retryable=FALSE. The WS-tunneled loop fast-fails with 502
		// when failover misses (server.go:1217-1228) — never falls
		// through to shouldRetry/advanceToNextProvider. Streaming
		// pre-chunk disconnect has retryable=true (see
		// TestClassifyStreamResult_DisconnectIsAlsoRetryable).
		{"provider_disconnected", wsForwardProviderDisconnected, statusForForwardResult(wsForwardProviderDisconnected), false, true, false, false, false},
		{"cancelled", wsForwardCancelled, statusForForwardResult(wsForwardCancelled), false, false, false, true, false},
		{"failed", wsForwardFailed, statusForForwardResult(wsForwardFailed), false, false, false, false, false},
		{"unavailable", wsForwardUnavailable, statusForForwardResult(wsForwardUnavailable), false, false, false, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := classifyWSResult(tc.result, requestLogAttempt{})
			if got.status != tc.wantStatus {
				t.Errorf("status = %d, want %d", got.status, tc.wantStatus)
			}
			if got.retryable != tc.wantRetryable {
				t.Errorf("retryable = %v, want %v", got.retryable, tc.wantRetryable)
			}
			if got.failoverEligible != tc.wantFailover {
				t.Errorf("failoverEligible = %v, want %v", got.failoverEligible, tc.wantFailover)
			}
			if got.markBusy != tc.wantMarkBusy {
				t.Errorf("markBusy = %v, want %v", got.markBusy, tc.wantMarkBusy)
			}
			if got.cancelled != tc.wantCancelled {
				t.Errorf("cancelled = %v, want %v", got.cancelled, tc.wantCancelled)
			}
			if got.committed != tc.wantCommitted {
				t.Errorf("committed = %v, want %v", got.committed, tc.wantCommitted)
			}
			if got.kind != tc.result {
				t.Errorf("kind = %s, want %s", got.kind, tc.result)
			}
		})
	}
}

func TestClassifyStreamResultCommitsAfterFirstChunk(t *testing.T) {
	// Streaming-specific: provider disconnect AFTER first chunk
	// (Committed variant) finalizes the request — NOT retryable,
	// committed=true, status=200.
	tr := classifyStreamResult(wsForwardProviderDisconnectedCommitted, http.StatusBadGateway, requestLogAttempt{})
	if !tr.committed || tr.retryable || tr.status != http.StatusOK {
		t.Errorf("ProviderDisconnectedCommitted got = %+v, want committed=true retryable=false status=200", tr)
	}

	// Buyer cancelled mid-stream: committed (partial output already
	// flushed), cancelled=true, status=200.
	tr = classifyStreamResult(wsForwardCancelled, 0, requestLogAttempt{})
	if !tr.committed || !tr.cancelled || tr.status != http.StatusOK {
		t.Errorf("Cancelled got = %+v, want committed+cancelled status=200", tr)
	}
}

// TestClassifyStreamResult_DisconnectIsAlsoRetryable pins the
// per-transport semantic difference flagged by the M2-1b audit: the
// streaming pre-first-chunk disconnect path tries failoverCandidate
// AND falls through to shouldRetry/advanceToNextProvider at
// server.go:1130 if failover misses. That's why streaming sets BOTH
// failoverEligible=true and retryable=true — vs WS-non-streaming
// which sets only failoverEligible=true (see
// TestClassifyWSResultBehaviourFlags / provider_disconnected case).
func TestClassifyStreamResult_DisconnectIsAlsoRetryable(t *testing.T) {
	tr := classifyStreamResult(wsForwardProviderDisconnected, 0, requestLogAttempt{})
	if !tr.retryable || !tr.failoverEligible || tr.committed {
		t.Errorf("streaming pre-chunk disconnect got = %+v, want retryable+failoverEligible, NOT committed", tr)
	}
}

// TestClassifyStreamResultCoverage pins the full stream-classifier
// table the M2-1b audit asked for: every wsForwardResult must land on
// an expected (status, retryable, failoverEligible, markBusy,
// committed, cancelled) shape so M2-1c's wired loop cannot drift.
func TestClassifyStreamResultCoverage(t *testing.T) {
	cases := []struct {
		name          string
		result        wsForwardResult
		inStatus      int
		wantStatus    int
		wantRetryable bool
		wantFailover  bool
		wantMarkBusy  bool
		wantCommitted bool
		wantCancelled bool
	}{
		// Success: normalize to 200 regardless of caller-supplied
		// status — the streaming path logs OK on completion.
		{"complete_zero_in", wsForwardComplete, 0, http.StatusOK, false, false, false, false, false},
		{"complete_200_in", wsForwardComplete, http.StatusOK, http.StatusOK, false, false, false, false, false},
		// Queue-full preserves the M1-2 / PR #36 markBusy+retryable
		// fix on the streaming path. Status falls through (the
		// streaming loop reads from forwardStreaming's returned
		// status when logging).
		{"queue_full", wsForwardQueueFull, http.StatusBadGateway, http.StatusBadGateway, true, false, true, false, false},
		// Timed-out / failed / unavailable: retryable (the streaming
		// loop calls shouldRetry then advances at server.go:1156-1169).
		{"timed_out", wsForwardTimedOut, http.StatusGatewayTimeout, http.StatusGatewayTimeout, true, false, false, false, false},
		{"failed", wsForwardFailed, http.StatusBadGateway, http.StatusBadGateway, true, false, false, false, false},
		{"unavailable", wsForwardUnavailable, http.StatusBadGateway, http.StatusBadGateway, true, false, false, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := classifyStreamResult(tc.result, tc.inStatus, requestLogAttempt{})
			if got.status != tc.wantStatus {
				t.Errorf("status = %d, want %d", got.status, tc.wantStatus)
			}
			if got.retryable != tc.wantRetryable {
				t.Errorf("retryable = %v, want %v", got.retryable, tc.wantRetryable)
			}
			if got.failoverEligible != tc.wantFailover {
				t.Errorf("failoverEligible = %v, want %v", got.failoverEligible, tc.wantFailover)
			}
			if got.markBusy != tc.wantMarkBusy {
				t.Errorf("markBusy = %v, want %v", got.markBusy, tc.wantMarkBusy)
			}
			if got.committed != tc.wantCommitted {
				t.Errorf("committed = %v, want %v", got.committed, tc.wantCommitted)
			}
			if got.cancelled != tc.wantCancelled {
				t.Errorf("cancelled = %v, want %v", got.cancelled, tc.wantCancelled)
			}
		})
	}
}

func TestClassifyHTTPResultEncodesPerTransportShape(t *testing.T) {
	// 200 success.
	tr := classifyHTTPResult(&http.Response{StatusCode: http.StatusOK}, nil, requestLogAttempt{})
	if tr.retryable || tr.status != http.StatusOK {
		t.Errorf("HTTP 200 got = %+v, want non-retryable status=200", tr)
	}

	// Network error (no response): retryable=true, err preserved,
	// status normalized to 502 — the existing HTTP loop at
	// server.go:1335-1341 logs 502 for nil-response errors. The
	// classifier contract promises canonical log/return status; pin
	// 502 so a wired M2-1c never writes attempt rows with status=0.
	wantErr := errors.New("dial tcp: connection refused")
	tr = classifyHTTPResult(nil, wantErr, requestLogAttempt{})
	if !tr.retryable || tr.err == nil || tr.status != http.StatusBadGateway {
		t.Errorf("HTTP dial-error got = %+v, want retryable + err non-nil + status=502", tr)
	}

	// Upstream 502.
	tr = classifyHTTPResult(&http.Response{StatusCode: http.StatusBadGateway}, nil, requestLogAttempt{})
	if !tr.retryable || tr.status != http.StatusBadGateway {
		t.Errorf("HTTP 502 got = %+v, want retryable status=502", tr)
	}
}

// TestPerTransportDifferencesArePreserved is the audit-verifier's
// belt-and-suspenders check on the cross-classifier matrix: the HTTP
// classifier must NEVER set failoverEligible (that path is WS-only,
// shared between non-streaming and streaming pre-first-chunk
// disconnects), and the WS-non-streaming classifier must NEVER set
// committed (that flag is streaming-only). Note: failoverEligible is
// set by BOTH classifyWSResult (non-streaming disconnect) AND
// classifyStreamResult (streaming pre-chunk disconnect) — they share
// the same failoverCandidate code at server.go:1120 / :1223. The
// retryable flag is what diverges between them.
func TestPerTransportDifferencesArePreserved(t *testing.T) {
	// failoverEligible never via HTTP forward (the failoverCandidate
	// path is WS-only).
	tr := classifyHTTPResult(&http.Response{StatusCode: http.StatusBadGateway}, nil, requestLogAttempt{})
	if tr.failoverEligible {
		t.Error("HTTP classifier set failoverEligible — that path is WS-only")
	}

	// committed never via WS non-streaming (it's a streaming
	// first-chunk concept).
	tr = classifyWSResult(wsForwardCancelled, requestLogAttempt{})
	if tr.committed {
		t.Error("WS non-streaming classifier set committed — that flag is streaming-only")
	}

	// HTTP classifier must never set committed either — the HTTP
	// non-streaming path has no first-chunk concept; success is
	// observed atomically on the response.
	tr = classifyHTTPResult(&http.Response{StatusCode: http.StatusOK}, nil, requestLogAttempt{})
	if tr.committed {
		t.Error("HTTP classifier set committed — that flag is streaming-only")
	}
}
