package buyer

import (
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// forwardState collects the per-request state that the three transport
// loops mutate as they advance through retry attempts. M2-1c (this PR)
// threads this through three sequence-helper methods on *Server
// (forwardStreamSequence, forwardWSNonStreamSequence,
// forwardHTTPSequence) that share retry/failover/busy-marking
// decisions driven off transportResult flags + *forwardState. The
// three pre-refactor loop bodies at handleChatCompletions:1085-1170 /
// :1172-1257 / :1264-1356 collapse into thin dispatchers that call
// the appropriate sequence helper.
//
// Final-shape note: the M2-1B_DESIGN.md sketch referred to a single
// `forwardWithFailover` helper; M2-1c lands three transport-typed
// sequence helpers instead, because success/error/SSE rendering is
// genuinely different per transport (HTTP body read+write, SSE
// streaming, WS-tunneled bridge). The three helpers DO share the
// retry/failover/busy decision tree through *forwardState +
// transportResult flags — every retry-semantics edit now touches a
// single helper per transport, not three near-duplicate inline loop
// bodies. See audits/2026-06-10/REMAINING_WORK.md ARCH-1/CODE-1 for
// the "RESOLVED_DIFFERENTLY" status disposition.
//
// Shape locked in audits/2026-06-10/M2-1B_DESIGN.md §forwardState for retry
// state. SPEC-024 adds typed sticky outcome fields because cache billing must
// validate provider reports against the actual per-attempt sticky decision.
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

	// queueWait records coordinator-side slot-queue wait time for the
	// active provider attempt. Queue delay is buyer-visible routing
	// latency, not provider billable work; request_log writes it
	// separately from token settlement so expired queued requests
	// remain non-billable.
	queueWait time.Duration

	// phaseTiming carries per-request spans that the gateway copies into
	// its completion log. It is kept with forwardState because retries and
	// failover already mutate the active route through this struct.
	phaseTiming requestPhaseTiming

	// queuedSlotProviderID is set when the slot queue reserves a
	// recovered provider slot for this request. It is released when
	// the request leaves that active route.
	queuedSlotProviderID string

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

	// dailyKey is the UTC YYYY-MM-DD bucket snapshot captured ONCE at
	// request start (handleChatCompletions, derived from startedAt
	// for atomic snapshot at the UTC-midnight boundary) and reused by
	// every retry attempt's seedForRequest derivation. This preserves
	// FR-SR-17 reproducibility for requests that span UTC midnight:
	// the daily-key component of (request_id, daily_key) → seed stays
	// sticky to the request, not to wall-clock time at the per-attempt
	// derivation point. (Each retry attempt's request_id IS distinct
	// — advanceToNextProvider rolls a fresh uuid per advance — so the
	// per-attempt seed values differ; what survives midnight is the
	// daily-key bucket each derivation consumes.) The bucket value
	// is NOT emitted as its own log field; downstream auditors
	// reproduce the seed by reading the request_log row's start
	// timestamp (which uses the same UTC date) and feeding it back
	// through seedForRequestWithKey alongside the per-attempt
	// request_id. Issue #266 T1 safety/correctness item.
	dailyKey string

	// estimatedTokens is the prompt-token estimate captured ONCE at
	// request start. The retry routing-decision log's PreflightResult
	// field is derived from this (vs s.preflightThreshold + whether
	// s.preflight is wired): when preflight ran, the just-selected
	// provider was accepted by it (else selectProviderExcluding would
	// have returned an error before afterAdvance fired); when
	// preflight was skipped (low estimate OR no preflight func), the
	// label is "not_applicable". Issue #266 T1 R1 audit MEDIUM fix.
	estimatedTokens int

	stickyResult     string
	stickyMissReason string
}
