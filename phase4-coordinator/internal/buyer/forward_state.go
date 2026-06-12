package buyer

import (
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// forwardState collects the per-request state that the three transport
// loops mutate as they advance through retry attempts. M2-1c (this PR)
// threads this through the single failover skeleton in
// forwardWithFailover (replacing the three transport-specific loop
// bodies at handleChatCompletions:1085-1170 / :1172-1257 / :1264-1356
// with one driven by transportResult flags + forwardState).
//
// Shape locked in audits/2026-06-10/M2-1B_DESIGN.md §forwardState — five
// fields, no per-loop scratch (excluded, failoverAttempted). The
// per-loop scratch intentionally stays in the unified loop's local
// scope because each call into forwardWithFailover handles exactly one
// transport sequence; scratch does not survive transport boundaries.
//
// Audit refs: REPO_AUDIT.md §3.1 item 3 (ARCH-1 / CODE-1),
// REMAINING_WORK.md M2-1.
type forwardState struct {
	// routingDone is the wall-clock at which the current provider was
	// selected. Updated on every advanceToNextProvider so the
	// request_log.routing_ms column reflects the latest routing
	// decision, not the original one (the audit-cited invariant —
	// the billing ledger keys routing_ms off the last selection).
	routingDone time.Time

	// explicitRetries is the retry counter the request_log.retried
	// column and the shouldRetry caps key off. Incremented by
	// advanceToNextProvider exactly once per advance; failover
	// (failoverCandidate) does NOT bump it — failover is a same-
	// attempt re-route, not a retry, per server.go pre-refactor
	// behaviour at lines 1119-1143 and 1217-1237.
	explicitRetries int

	// faultedProviders is the count of providers we've moved off due
	// to a transport-level fault (timeout, disconnect, queue full,
	// HTTP error). shouldRetry's fault-cap branch keys off this.
	// Bumped by advanceToNextProvider; failover does NOT bump it.
	faultedProviders int

	// faultedRoutes tracks the cross-loop "this route already failed
	// in an earlier loop" set. The HTTP loop seeds its `excluded`
	// from this so a WS loop that exhausted its options doesn't
	// re-pick the same WS routes in the HTTP fallback path. Pre-1a
	// behaviour at server.go:1083-1084 / :1108 / :1190 / :1216 /
	// :1260-1262 — preserved here verbatim.
	faultedRoutes map[string]struct{}

	// provider is the currently-active provider. Mutates on every
	// advance (failover or retry). The three forwardFn closures read
	// state.provider to drive their dispatch.
	provider pool.Provider
}
