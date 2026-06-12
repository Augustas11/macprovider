package buyer

import (
	"net/http"
)

// transportResult is the transport-agnostic shape every forward call
// produces. M2-1b (ARCH-1 / CODE-1 sub-PR 2 of 3) unifies the three
// return tuples behind this type so the three transport loops in
// handleChatCompletions can drive retry decisions off the same flags.
// M2-1c will collapse those loops into a single failover skeleton
// driven by this type.
//
// See audits/2026-06-10/M2-1B_DESIGN.md for the design rationale and
// the audit-flagged invariants this struct encodes as data.
type transportResult struct {
	// kind preserves the native forwardResult so transport-specific
	// renderers (writeStreamForwardError, the WS-only logWSDeadMidRequest
	// path) can still dispatch on it where necessary. The unified loop
	// in 1c minimises dependence on this field; for 1b it lets the
	// existing dispatch shape survive without behaviour change.
	kind wsForwardResult

	// status is the canonical HTTP status to log + return. WS forwards
	// map their forwardResult to a status here so attempt logging is
	// uniform across transports.
	status int

	// attempt is the existing billing/log payload, untouched —
	// preserves byte-identical attempt-row format the ledger keys off.
	attempt requestLogAttempt

	// err is the network/dispatch error, where applicable.
	err error

	// Behaviour flags — the AUDIT-CONFIRMED intentional per-transport
	// differences, encoded as data so 1c's unified loop can branch on
	// flags rather than transport-specific if/else.
	//
	// retryable: caller should advance to the next provider via the
	//   normal shouldRetry + advanceToNextProvider path.
	// failoverEligible: WS "failoverCandidate" path is in play. Set
	//   by both non-streaming WS disconnect and streaming pre-first-
	//   chunk disconnect; the two diverge on `retryable` instead
	//   (non-streaming fast-fails when failover misses; streaming
	//   falls through to shouldRetry).
	// markBusy: caller should call s.pool.MarkState(StateBusy) for the
	//   current provider before deciding retry.
	// committed: streaming first-chunk has been received — the attempt
	//   is committed to this provider; never retry, just finalize.
	// cancelled: buyer cancelled the request (ctx.Done). Skip attempt
	//   logging unless the attempt has otherwise-loggable content.
	retryable        bool
	failoverEligible bool
	markBusy         bool
	committed        bool
	cancelled        bool
}

// classifyWSResult converts forwardWS's (wsForwardResult, requestLogAttempt)
// return into the unified transportResult for the WS-tunneled
// NON-STREAMING loop at buyer/server.go:1172-1257.
//
// M2-1b contract: failoverEligible encodes the
// failoverCandidate special-failover path. classifyStreamResult also
// sets it for streaming pre-first-chunk disconnects, since both loops
// run the same failoverCandidate code at server.go:1120 and
// server.go:1223 respectively.
//
// Critical semantic difference vs streaming pre-chunk disconnect:
// the non-streaming WS loop does NOT fall through to normal
// shouldRetry/advanceToNextProvider when failover misses — it
// fast-fails with 502 at server.go:1217-1228. So wsForwardProvider-
// Disconnected here is failoverEligible=true but retryable=FALSE.
// The streaming variant is failoverEligible=true AND retryable=true
// (falls through to shouldRetry at server.go:1130 if failover misses).
// Encoding the divergence as flags is what lets M2-1c's unified loop
// branch correctly without re-introducing the audit's three-copies
// drift.
//
// Status mapping (via statusForForwardResult): wsForwardComplete ->
// 200; queue-full / disconnected / failed -> 502; unavailable -> 503;
// timed-out -> 504; cancelled -> 502 default (unused — cancelled
// caller skips status-keyed logging).
func classifyWSResult(result wsForwardResult, attempt requestLogAttempt) transportResult {
	tr := transportResult{
		kind:    result,
		attempt: attempt,
		status:  statusForForwardResult(result),
	}
	switch result {
	case wsForwardComplete:
		tr.status = http.StatusOK
	case wsForwardTimedOut:
		tr.retryable = true
		tr.status = http.StatusGatewayTimeout
	case wsForwardQueueFull:
		tr.markBusy = true
		tr.retryable = true
	case wsForwardProviderDisconnected:
		// retryable=false: the WS-non-streaming loop fast-fails with
		// 502 when failover misses (server.go:1217-1228) — it does
		// NOT call shouldRetry + advanceToNextProvider. Only
		// failoverEligible drives the next-attempt decision.
		tr.failoverEligible = true
	case wsForwardCancelled:
		tr.cancelled = true
	case wsForwardFailed, wsForwardUnavailable:
		// Non-retryable on this transport (matches existing
		// buyer/server.go:1208-1213 behaviour: failed/unavailable/cancelled
		// short-circuit return without advancing).
	}
	return tr
}

// classifyStreamResult converts forwardStreaming's
// (wsForwardResult, status, requestLogAttempt) return into the unified
// transportResult. M2-1b: streaming first-chunk-received commits the
// attempt — encoded as committed=true on
// wsForwardProviderDisconnectedCommitted. wsForwardCancelled also
// counts as committed (buyer cancelled mid-stream after first chunk).
//
// The status int passed in is the upstream status code observed during
// streaming dispatch; it falls through onto transportResult.status.
func classifyStreamResult(result wsForwardResult, status int, attempt requestLogAttempt) transportResult {
	tr := transportResult{
		kind:    result,
		attempt: attempt,
		status:  status,
	}
	switch result {
	case wsForwardComplete:
		// Success. Normalize to 200 — the streaming loop logs OK on
		// completion at server.go:1102 (WS) and server.go:1147 (HTTP
		// streaming via forwardStreaming's returned status, which is
		// 200 on success per server.go:1824). The caller-provided
		// status may be 0 in unit-test or short-path cases; pin 200
		// as the canonical log/return status the classifier contract
		// promises.
		tr.status = http.StatusOK
	case wsForwardProviderDisconnectedCommitted:
		// First chunk received then provider disconnected. The
		// attempt is committed to this provider — finalize with
		// http.StatusOK to match the existing streaming-loop branch
		// at buyer/server.go:1131-1142.
		tr.committed = true
		tr.status = http.StatusOK
	case wsForwardCancelled:
		// Buyer cancelled mid-stream. Treated like committed because
		// any partial output already went to the buyer.
		tr.committed = true
		tr.cancelled = true
		tr.status = http.StatusOK
	case wsForwardProviderDisconnected:
		// Streaming case where provider disconnected BEFORE first chunk.
		// Retryable, and the failoverCandidate path applies just like
		// non-streaming WS.
		tr.retryable = true
		tr.failoverEligible = true
	case wsForwardQueueFull:
		tr.markBusy = true
		tr.retryable = true
	default:
		// Other failures (failed, unavailable, timed_out): retryable
		// per the existing streaming-loop logic at
		// buyer/server.go:1144-1148 which calls shouldRetry then
		// advances or returns the stream error.
		tr.retryable = true
	}
	return tr
}

// classifyHTTPResult converts the HTTP-forward dispatch tuple
// (*http.Response, error, requestLogAttempt) into the unified
// transportResult. M2-1b: HTTP is the only transport with a
// per-attempt context timeout — that's encoded as a separate code
// path inside this classifier (the caller still wires
// context.WithTimeout per attempt at buyer/server.go:1262 pre-1a),
// not as a transportResult flag, because no other transport has it.
//
// On success (status 200), retryable=false. On error or non-200,
// retryable=true matches the existing HTTP-loop "always advance unless
// shouldRetry says stop" pattern at buyer/server.go:1331.
func classifyHTTPResult(resp *http.Response, err error, attempt requestLogAttempt) transportResult {
	tr := transportResult{
		attempt: attempt,
		err:     err,
	}
	if err == nil && resp != nil && resp.StatusCode == http.StatusOK {
		tr.status = http.StatusOK
		return tr
	}
	tr.retryable = true
	if resp != nil {
		tr.status = resp.StatusCode
	} else {
		// Nil response (dial/network error). The existing HTTP loop
		// normalizes this to 502 before logging/returning at
		// server.go:1335-1336 and server.go:1340-1341. Pin the same
		// canonical log/return status so M2-1c's wired loop never
		// records attempt rows with status=0. shouldRetry's
		// "no-response" branch keys off err, not status, so
		// preserving status=502 here does not change retry semantics.
		tr.status = http.StatusBadGateway
	}
	return tr
}
