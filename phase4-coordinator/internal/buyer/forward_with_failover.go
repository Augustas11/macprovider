package buyer

import (
	"net/http"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/google/uuid"
)

// forwardWithFailover is the shared failover state machine for the three
// transport sequences (HTTP / SSE streaming / WS-tunneled non-streaming).
// M2-1e (issue #94) extraction — the architect's named close-out for
// ARCH-1 / CODE-1 on top of the M2-1c three-helper landing.
//
// The core owns the decision tree: dispatch → classify → branch on
// transportResult flags (committed / success / failoverEligible / retryable
// / terminal) → failoverCandidate → advanceToNextProvider → loop.
//
// The FOUR INTENTIONAL per-transport divergences flagged by the
// 2026-06-10 audit (3 named on PR #93, +1 caught by the M2-1e cap=1
// test sweep) live in the `tx` callbacks, NOT flattened into the
// core:
//
//  1. HTTP per-attempt context.WithTimeout(...) — lives inside the HTTP
//     dispatch callback; never visible at this level for other transports.
//  2. WS-non-streaming `failoverEligible` carries `retryable=false` in the
//     classifier; the WS-non-streaming `onFailoverMiss` returns
//     handled=true (fast-fail + 502 rendered). Streaming carries
//     `retryable=true`; its `onFailoverMiss` returns handled=false (fall
//     through to shouldRetry).
//  3. Streaming committed early-exit (pre-first-chunk vs post-first-chunk
//     semantics) — `renderCommitted` callback fires only on the streaming
//     path; the other two leave it nil.
//  4. WS-non-streaming queue-full bypasses the shouldRetry budget gate
//     (always advances when a candidate exists) — `skipRetryBudgetCheck`
//     callback returns true for wsForwardQueueFull. Streaming and HTTP
//     never set the callback so the gate fires normally. Preserves the
//     M2-1d-baseline behaviour pinned by forward_loop_test scenario
//     TestM2_1D_RowSequence_WSNonStreamingQueueFullThroughAdvance.
//
// Money-path invariant: attempt_n numbering + logAttempt row sequence MUST
// stay byte-identical to the PR #91 baseline pinned by
// forward_loop_test.go (11 row-sequence scenarios). The core implements
// the same mutation order as the prior inline branches:
// `excluded[routeKey]++ → faultedRoutes[routeKey]++ → MarkState (if
// markBusy) → failoverCandidate → state.provider = next (on hit)` or
// `shouldRetry → logAttempt → advanceToNextProvider →
// excluded[routeKey]++`. The advance helper continues to be the single
// owner of explicitRetries++ / faultedProviders++.
//
// The returned `shouldFallThroughToHTTP` is the WS-non-streaming-only
// signal that the loop's "advance picked a non-WS provider" path fired;
// the caller (handleChatCompletions) drives the HTTP fallback loop on
// `state.provider` when this returns true. For streaming and HTTP
// callers the return is always false (their callback bundles' afterHop
// callbacks return false).
func (s *Server) forwardWithFailover(
	w http.ResponseWriter,
	r *http.Request,
	req chatRequest,
	requestID, originalRequestID string,
	startedAt time.Time,
	state *forwardState,
	excluded map[string]struct{},
	rec *billingRecorder,
	tx transportCallbacks,
) (shouldFallThroughToHTTP bool) {
	failoverAttempted := false
	for {
		// Reset the per-attempt dispatched flag before every attempt so the
		// item-18 no-charge marker reflects only THIS attempt's dispatch
		// (providerCredited separately carries billed credit from prior
		// attempts). Must precede tx.dispatch, which may write a terminal
		// response (route_snapshot_failed, provider_failed) synchronously.
		rec.beginDispatchAttempt()
		// Dispatch — per-transport. The callback runs one attempt and
		// returns the classified result. HTTP's callback also owns its
		// per-attempt context.WithTimeout setup and the cancelAttempt
		// cleanup on EVERY exit path (success, terminal, retry-advance).
		dispatched, ok := tx.dispatch(w, r, req, requestID, originalRequestID, startedAt, state, rec)
		if !ok {
			// Dispatch reported a terminal pre-classification error
			// (dispatchBodyForProvider failure, request construction
			// failure, etc.). The callback already rendered the error
			// response and the request_log row; we just return.
			return false
		}
		tr := dispatched.tr

		// Committed early-exit (streaming only — see invariant 3 above).
		// Streaming's callback handles both wsForwardProviderDisconnected
		// Committed and wsForwardCancelled (with the shouldLogAttempt
		// gating on cancelled). HTTP / WS-non-streaming leave this nil.
		if tr.committed && tx.renderCommitted != nil {
			if tx.renderCommitted(w, r, dispatched, state) {
				return false
			}
		}

		// Terminal short-circuits before the failover/retry tree —
		// WS-non-streaming's classify returns Cancelled / Failed /
		// Unavailable here without going through the rest of the tree.
		// HTTP doesn't classify those into transportResult kinds; its
		// terminal path is the shouldRetry-exhausted branch below.
		// Streaming covers cancelled via tr.committed above.
		if tx.handleNonRetryableTerminal != nil {
			if handled := tx.handleNonRetryableTerminal(w, dispatched, state); handled {
				return false
			}
		}

		// Success — per-transport rendering. HTTP writes body + headers;
		// streaming does logAttempt + stickyStore-if-WS; WS-non-streaming
		// does logAttempt + stickyStore. Each callback returns whether
		// the loop is done (always true for success today, but the
		// signature lets future success-with-continue cases plug in
		// without revisiting the core).
		if dispatched.success {
			tx.renderSuccess(w, r, req, dispatched, state)
			return false
		}

		// Mark fault state — shared across all transports. The mutation
		// order matches the pre-refactor inline blocks exactly:
		// excluded → faultedRoutes → (markBusy MarkState if set).
		excluded[state.provider.SortKey()] = struct{}{}
		state.faultedRoutes[state.provider.SortKey()] = struct{}{}
		if tr.markBusy {
			s.pool.MarkState(state.provider.ProviderID, state.provider.AssignedID, pool.StateBusy)
		}

		// Failover branch — the unified failover state machine. The
		// failoverCandidate call + state.provider mutation that used to
		// be inlined in each helper now lives here exactly once. The
		// "what to do on miss" divergence (fast-fail vs fall-through-to-
		// retry) is the onFailoverMiss callback's call: WS-non-streaming
		// returns handled=true (the callback rendered the 502 + logged
		// fast_fail), streaming returns handled=false (fall through to
		// shouldRetry below). HTTP never sets failoverEligible so this
		// branch is dead code for it; its callback may leave the
		// failover callbacks nil.
		if tr.failoverEligible && tx.onFailoverHit != nil && tx.onFailoverMiss != nil {
			if !failoverAttempted && !hasPinnedRoute(r.Header) {
				priorQueueWait := state.queueWait
				s.releaseQueuedSlotReservation(state)
				next, hit := s.failoverCandidate(r.Context(), uuid.NewString(), req, r.Header, state.provider, excluded, state.dailyKey, state)
				if hit {
					nextQueueWait := state.queueWait
					nextQueuedSlotProviderID := state.queuedSlotProviderID
					state.queueWait = priorQueueWait
					state.queuedSlotProviderID = ""
					tx.onFailoverHit(originalRequestID, requestID, dispatched, state, next)
					failoverAttempted = true
					state.queueWait = nextQueueWait
					state.queuedSlotProviderID = nextQueuedSlotProviderID
					state.provider = next
					state.phaseTiming.markCoordRoutingDone(phaseTimingNow(s))
					if tx.afterFailoverHit != nil {
						if fallThrough := tx.afterFailoverHit(state); fallThrough {
							return true
						}
					}
					continue
				}
				state.queueWait = priorQueueWait
				s.releaseQueuedSlotReservation(state)
			}
			if handled := tx.onFailoverMiss(w, r, dispatched, state); handled {
				return false
			}
		}

		// Retry budget — shared shouldRetry gate. On exhaustion the
		// per-transport renderRetryExhausted callback writes the final
		// error response and logs the attempt row with the
		// transport-specific message.
		//
		// One transport opts OUT of this gate: WS-non-streaming's
		// queue-full branch goes straight to advance without consulting
		// shouldRetry — that bypass is the M2-1d-preserved behaviour the
		// byte-identical contract pins via forward_loop_test scenario
		// TestM2_1D_RowSequence_WSNonStreamingQueueFullThroughAdvance.
		// The callback returns true to skip the gate for that branch
		// only; other transports + other branches leave the callback
		// nil so the gate fires as usual.
		if tx.skipRetryBudgetCheck == nil || !tx.skipRetryBudgetCheck(dispatched) {
			if !s.shouldRetry(r, startedAt, state.explicitRetries, state.faultedProviders, tr.status, tr.err) {
				tx.renderRetryExhausted(w, dispatched, state)
				return false
			}
		}

		// Per-retry log + advance — the streaming/WS paths call
		// logAttempt before advancing; HTTP calls logProviderRow with a
		// transport-specific message. The advance call is shared and
		// owns explicitRetries++ + faultedProviders++ + state.provider
		// = next (NOT the failover same-attempt re-route mutation
		// above).
		tx.logRetryAttempt(dispatched, state)
		nextRouteID, ok := s.advanceToNextProvider(w, r, req, state, excluded, rec)
		if !ok {
			return false
		}
		excluded[state.provider.SortKey()] = struct{}{}

		// afterAdvance — WS-non-streaming returns true (caller falls
		// through to the HTTP loop on state.provider) when the new
		// provider is not WS-tunneled. Streaming + HTTP return false
		// here. Per issue #266 T1, ALL THREE transports now emit the
		// per-attempt SPEC-004 §7 routing-decision log via
		// logRoutingDecisionRetry inside their afterAdvance callback —
		// the pre-#266 asymmetry where WS-non-streaming skipped the
		// emission was the FR-SR-17 audit-explainability gap closed
		// here.
		if tx.afterAdvance != nil {
			if fallThrough := tx.afterAdvance(state, nextRouteID); fallThrough {
				return true
			}
		}
	}
}

// transportCallbacks bundles the per-transport divergence points the
// forwardWithFailover core defers to. Each helper (HTTP, streaming, WS-
// non-streaming) constructs one of these and passes it to the core. The
// shape isolates the FOUR audit-flagged INTENTIONAL differences (the
// three named on PR #93 plus the M2-1e-discovered queue-full retry-
// budget bypass; see the `forwardWithFailover` doc block above) so they
// remain visibly per-transport in the callback bundles rather than
// flattened into the shared decision tree.
type transportCallbacks struct {
	// dispatch runs one provider attempt. Returns the dispatched payload
	// (carries the classified transportResult plus per-transport extras
	// like nativeResult for streaming) and ok=true on classification
	// success. Returns ok=false ONLY when the callback rendered a
	// terminal pre-classification error itself (e.g. dispatchBodyFor-
	// Provider failure, HTTP request-construction failure); the core
	// just returns in that case.
	//
	// HTTP-specific: the callback sets up context.WithTimeout against
	// r.Context() and calls cancelAttempt on every exit path. Streaming
	// / WS use r.Context() directly.
	dispatch func(
		w http.ResponseWriter,
		r *http.Request,
		req chatRequest,
		requestID, originalRequestID string,
		startedAt time.Time,
		state *forwardState,
		rec *billingRecorder,
	) (dispatched dispatchedAttempt, ok bool)

	// renderCommitted handles the streaming-only committed-path early
	// return (post-first-chunk disconnect, cancelled). Nil for HTTP /
	// WS-non-streaming. Returns true when handled (the core returns).
	renderCommitted func(
		w http.ResponseWriter,
		r *http.Request,
		dispatched dispatchedAttempt,
		state *forwardState,
	) (handled bool)

	// handleNonRetryableTerminal handles the WS-non-streaming-only
	// short-circuit on Cancelled / Failed / Unavailable. Nil for HTTP /
	// streaming. Returns true when handled.
	handleNonRetryableTerminal func(
		w http.ResponseWriter,
		dispatched dispatchedAttempt,
		state *forwardState,
	) (handled bool)

	// renderSuccess runs the 200-success render. HTTP writes the body
	// and copies receipt headers; streaming + WS log the attempt and
	// stickyStore. The core's `dispatched.success` field is set by the
	// per-transport dispatch callback to gate this.
	renderSuccess func(
		w http.ResponseWriter,
		r *http.Request,
		req chatRequest,
		dispatched dispatchedAttempt,
		state *forwardState,
	)

	// onFailoverHit runs after the core picks a failover candidate and
	// is about to mutate state.provider. WS paths log the
	// logWSDeadMidRequest "failover" event; HTTP leaves this nil. The
	// state.provider mutation is performed by the CORE, not the
	// callback — keeps the same-attempt-re-route policy in one place.
	onFailoverHit func(
		originalRequestID, requestID string,
		dispatched dispatchedAttempt,
		state *forwardState,
		next pool.Provider,
	)

	// afterFailoverHit runs immediately after the core's state.provider
	// = next on a hit. WS-non-streaming returns true when the new
	// provider is not WS (signals fallthrough to HTTP). Streaming
	// returns false. Nil for HTTP.
	afterFailoverHit func(state *forwardState) (fallThrough bool)

	// onFailoverMiss runs when failoverEligible fires but no candidate
	// is available. WS-non-streaming returns handled=true (renders 502
	// + logs fast_fail). Streaming returns handled=false (falls through
	// to shouldRetry in the core). HTTP leaves this nil (never reached
	// — HTTP doesn't set failoverEligible).
	onFailoverMiss func(
		w http.ResponseWriter,
		r *http.Request,
		dispatched dispatchedAttempt,
		state *forwardState,
	) (handled bool)

	// skipRetryBudgetCheck returns true when the core should bypass the
	// shouldRetry gate for this dispatched attempt and proceed directly
	// to advanceToNextProvider. WS-non-streaming sets this for
	// wsForwardQueueFull to preserve the M2-1d-baseline bypass; other
	// transports leave it nil. Optional.
	skipRetryBudgetCheck func(dispatched dispatchedAttempt) bool

	// renderRetryExhausted is the shouldRetry-returns-false render.
	// Each transport has its own error envelope: HTTP disambiguates
	// timeout vs error, streaming uses writeStreamForwardError, WS-non-
	// streaming uses writeError with the WS-specific message.
	renderRetryExhausted func(
		w http.ResponseWriter,
		dispatched dispatchedAttempt,
		state *forwardState,
	)

	// logRetryAttempt logs the per-retry row before advanceToNextProvider.
	// HTTP uses logProviderRow with a custom message; streaming + WS use
	// logAttempt with the classifier-populated attempt fields.
	logRetryAttempt func(
		dispatched dispatchedAttempt,
		state *forwardState,
	)

	// afterAdvance runs after a successful advanceToNextProvider call.
	// HTTP + streaming emit logRoutingDecision and return false.
	// WS-non-streaming inspects state.provider.IsWSTunneled() and
	// returns true when the new provider is NOT WS (signals
	// fallthrough). Optional — the core skips it when nil (all current
	// transports supply one, but the design preserves the option).
	afterAdvance func(state *forwardState, nextRouteID string) (fallThrough bool)
}

// dispatchedAttempt is the per-transport dispatch result the callbacks
// pass to the core's decision branches. Carrying the native
// wsForwardResult preserves the streaming committed-path's need to
// dispatch logWSDeadMidRequest on the precise sub-kind
// (wsForwardProviderDisconnectedCommitted vs wsForwardCancelled), which
// transportResult flags alone don't disambiguate.
type dispatchedAttempt struct {
	// tr is the classifier output (status, attempt, retryable,
	// failoverEligible, markBusy, committed, cancelled, err). The core
	// branches on these.
	tr transportResult

	// nativeResult is the wsForwardResult kind for streaming + WS
	// dispatches; unset for HTTP. Callbacks that need to dispatch on
	// the precise kind (logWSDeadMidRequest "stream_terminal" vs
	// "failover" vs "fast_fail"; writeStreamForwardError's
	// status-keyed table) read this directly.
	nativeResult wsForwardResult

	// success is the per-transport "this attempt was a 200" verdict —
	// set by the dispatch callback because the HTTP path detects it
	// via resp.StatusCode == 200 (and runs token extraction + body
	// read inside dispatch), while streaming / WS detect it via
	// nativeResult == wsForwardComplete. Centralising the flag at
	// dispatch keeps the core's success-branch shape trivial.
	success bool

	// extra carries per-transport scratch state the dispatch callback
	// captured for downstream render callbacks (HTTP response body,
	// HTTP response headers, prompt/completion token pointers, the
	// HTTP attempt's cancelAttempt closure for callbacks that run on
	// terminal exits). Type-asserted by the renderSuccess / render-
	// RetryExhausted callbacks that need it.
	extra any
}
