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
	// retryable: caller should advance to the next provider.
	// failoverEligible: WS-non-streaming "failoverCandidate" path is in play.
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
// return into the unified transportResult. M2-1b: the
// failoverCandidate path is WS-non-streaming-only — that's encoded as
// failoverEligible=true on wsForwardProviderDisconnected, never set by
// the other classifiers.
//
// Mirrors the existing dispatch in buyer/server.go's non-streaming WS
// loop. Behaviour is preserved byte-for-byte: a wsForwardComplete is
// retryable=false / committed=false / status=200; a queue-full marks
// busy + retryable; a provider-disconnect is retryable + failover-
// eligible.
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
		tr.retryable = true
		tr.failoverEligible = true
	case wsForwardCancelled:
		tr.cancelled = true
	case wsForwardFailed, wsForwardUnavailable:
		// Non-retryable on this transport (matches existing
		// buyer/server.go:1189 behaviour: failed/unavailable/cancelled
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
		// Success.
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
	}
	return tr
}
