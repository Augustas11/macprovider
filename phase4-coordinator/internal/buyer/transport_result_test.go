package buyer

import (
	"errors"
	"net/http"
	"testing"
)

// These tests pin the M2-1b classifier behaviour. They are documentation
// of the audit-confirmed per-transport differences: failoverEligible is
// WS-non-streaming-only, committed is streaming-only, the HTTP path
// uses retryable for every non-200, etc. M2-1c's unified loop will lean
// on these flags, so any future flattening becomes a test failure.

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
		{"provider_disconnected", wsForwardProviderDisconnected, statusForForwardResult(wsForwardProviderDisconnected), true, true, false, false, false},
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

	// Streaming-specific: provider disconnect BEFORE first chunk is
	// still retryable + failover-eligible (same as non-streaming WS).
	tr = classifyStreamResult(wsForwardProviderDisconnected, 0, requestLogAttempt{})
	if !tr.retryable || !tr.failoverEligible || tr.committed {
		t.Errorf("ProviderDisconnected (pre-chunk) got = %+v, want retryable+failoverEligible, NOT committed", tr)
	}

	// Buyer cancelled mid-stream: committed (partial output already
	// flushed), cancelled=true, status=200.
	tr = classifyStreamResult(wsForwardCancelled, 0, requestLogAttempt{})
	if !tr.committed || !tr.cancelled || tr.status != http.StatusOK {
		t.Errorf("Cancelled got = %+v, want committed+cancelled status=200", tr)
	}
}

func TestClassifyHTTPResultEncodesPerTransportShape(t *testing.T) {
	// 200 success.
	tr := classifyHTTPResult(&http.Response{StatusCode: http.StatusOK}, nil, requestLogAttempt{})
	if tr.retryable || tr.status != http.StatusOK {
		t.Errorf("HTTP 200 got = %+v, want non-retryable status=200", tr)
	}

	// Network error (no response).
	wantErr := errors.New("dial tcp: connection refused")
	tr = classifyHTTPResult(nil, wantErr, requestLogAttempt{})
	if !tr.retryable || tr.err == nil {
		t.Errorf("HTTP dial-error got = %+v, want retryable + err non-nil", tr)
	}

	// Upstream 502.
	tr = classifyHTTPResult(&http.Response{StatusCode: http.StatusBadGateway}, nil, requestLogAttempt{})
	if !tr.retryable || tr.status != http.StatusBadGateway {
		t.Errorf("HTTP 502 got = %+v, want retryable status=502", tr)
	}
}

// TestPerTransportDifferencesArePreserved is the audit-verifier's
// belt-and-suspenders check: the flags failoverEligible and committed
// MUST be set by exactly one transport each, never bled into the other
// transport's classifier.
func TestPerTransportDifferencesArePreserved(t *testing.T) {
	// failoverEligible only via WS-disconnect (non-streaming or
	// streaming-pre-first-chunk) — NOT via HTTP forward.
	tr := classifyHTTPResult(&http.Response{StatusCode: http.StatusBadGateway}, nil, requestLogAttempt{})
	if tr.failoverEligible {
		t.Error("HTTP classifier set failoverEligible — that path is WS-only")
	}

	// committed only via streaming first-chunk paths — NOT via WS
	// non-streaming.
	tr = classifyWSResult(wsForwardCancelled, requestLogAttempt{})
	if tr.committed {
		t.Error("WS non-streaming classifier set committed — that flag is streaming-only")
	}
}
