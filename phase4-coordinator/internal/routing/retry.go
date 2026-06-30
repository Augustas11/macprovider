package routing

import (
	"fmt"
	"math"
	"net/http"
	"strings"
	"time"
)

// RetryHeaderLimit parses the `X-MacProvider-Retry` buyer header
// into a per-request retry budget. Issue #266 T2 refactor —
// byte-identical to pre-extraction `buyer.retryHeaderLimit`:
//
//   - empty / whitespace-only → 0 (no retries requested)
//   - "true" (case-insensitive) → math.MaxInt (buyer accepts any
//     number of retries up to the operator-configured server cap)
//   - positive integer N → N
//   - any other shape (zero, negative, non-numeric) → 0
//
// Returning 0 disables retry entirely for the request, even when
// the operator's `routing.max_retries` is >0. The header is the
// buyer's opt-in; the operator config is the cap.
func RetryHeaderLimit(value string) int {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	if strings.EqualFold(value, "true") {
		return math.MaxInt
	}
	var n int
	if _, err := fmt.Sscanf(value, "%d", &n); err != nil || n <= 0 {
		return 0
	}
	return n
}

// ShouldRetryInput bundles the inputs to ShouldRetry so the call
// site documents WHY each parameter matters without growing a
// long positional signature. Every field is consumed at least
// once by the gate logic; none is optional.
type ShouldRetryInput struct {
	// MaxRetries is the operator-configured `routing.max_retries`
	// cap. When ≤ 0 the request gets zero retries regardless of
	// other inputs.
	MaxRetries int

	// RequestedRetries is the parsed RetryHeaderLimit value (see
	// above). When ≤ 0 the buyer opted out of retries.
	RequestedRetries int

	// HasPinnedRoute is true when the buyer pinned to a specific
	// provider via X-MacProvider-Provider or X-MacProvider-Session.
	// Pinned requests do NOT retry — the failure attribution
	// surface requires the buyer-named provider to be the one
	// that failed.
	HasPinnedRoute bool

	// ContextErr is `r.Context().Err()` at the gate point. When
	// non-nil the request is already cancelled / deadline-exceeded
	// and no further attempts are worth dispatching.
	ContextErr error

	// ExplicitRetries is forwardState.explicitRetries — the count
	// of advances driven by retry (NOT failover) so far. Gated
	// against min(MaxRetries, RequestedRetries).
	ExplicitRetries int

	// FaultedProviders is forwardState.faultedProviders — the
	// count of providers we have marked faulted on this request.
	// Gated against MaxFaultedPerRequest when that is > 0.
	FaultedProviders int

	// MaxFaultedPerRequest is the operator-configured
	// `routing.max_providers_faulted_per_request` cap. When ≤ 0
	// the cap is disabled.
	MaxFaultedPerRequest int

	// Now is the current wall-clock at the gate point; used with
	// StartedAt + RequestTimeout + RetryPerAttemptTimeout to
	// short-circuit when the next attempt would overrun the
	// per-request deadline.
	Now time.Time

	// StartedAt is the wall-clock at which handleChatCompletions
	// began processing this request.
	StartedAt time.Time

	// RequestTimeout is the operator-configured per-request
	// budget. When ≤ 0 the time-budget gate is disabled.
	RequestTimeout time.Duration

	// RetryPerAttemptTimeout is the per-attempt budget reserved
	// for the NEXT attempt if we allow the retry. Added to
	// Now-StartedAt and compared against RequestTimeout to avoid
	// dispatching an attempt that cannot complete before the
	// per-request deadline.
	RetryPerAttemptTimeout time.Duration

	// Status is the HTTP status code from the just-completed
	// attempt (0 when err is non-nil and no status was reached).
	Status int

	// Err is the dispatch-level error from the just-completed
	// attempt, or nil if the attempt produced a status.
	Err error
}

// ShouldRetry reports whether the request is eligible to retry the
// just-failed attempt. Byte-identical to pre-extraction
// `buyer.Server.shouldRetry`, factored as a pure function so the
// retry policy can be unit-tested without spinning up a buyer
// Server. Issue #266 T2 refactor.
//
// Gate order (ALL must pass for retry to fire):
//  1. MaxRetries > 0 AND RequestedRetries > 0 AND !HasPinnedRoute
//  2. ContextErr is nil
//  3. ExplicitRetries < min(MaxRetries, RequestedRetries)
//  4. MaxFaultedPerRequest is 0 OR FaultedProviders < MaxFaultedPerRequest
//  5. RequestTimeout is 0 OR (Now-StartedAt) + RetryPerAttemptTimeout ≤ RequestTimeout
//  6. Err is non-nil OR Status is BadGateway/GatewayTimeout
//
// The order matters for the audit narrative: pin-check first (cheap),
// then context, then explicit-retry cap, then fault cap, then
// time-budget, then status-class. A request that fails the pin
// check never even consults the timeout — the audit row reads as
// "pinned therefore no retry" not "timed out".
func ShouldRetry(in ShouldRetryInput) bool {
	if in.MaxRetries <= 0 || in.RequestedRetries <= 0 || in.HasPinnedRoute {
		return false
	}
	if in.ContextErr != nil {
		return false
	}
	cap := in.MaxRetries
	if in.RequestedRetries < cap {
		cap = in.RequestedRetries
	}
	if in.ExplicitRetries >= cap {
		return false
	}
	if in.MaxFaultedPerRequest > 0 && in.FaultedProviders >= in.MaxFaultedPerRequest {
		return false
	}
	if in.RequestTimeout > 0 && in.Now.Sub(in.StartedAt)+in.RetryPerAttemptTimeout > in.RequestTimeout {
		return false
	}
	if in.Err != nil {
		return true
	}
	return in.Status == http.StatusBadGateway || in.Status == http.StatusGatewayTimeout
}
