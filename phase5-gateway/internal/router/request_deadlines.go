package router

import (
	"context"
	"errors"
	"fmt"
	"math"
	"sync"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// Per-phase request deadlines (issue #760 / seam finding P0-2).
//
// Before this file the chat proxy ran on ONE flat wall —
// `context.WithTimeout(r.Context(), CoordinatorTimeout())` — that spanned
// admission, first token, and the entire decode. A healthy stream that kept
// emitting tokens was still cut at 300s, surfacing as a 5xx against our public
// error rate even though nothing had actually stalled.
//
// The replacement keeps exactly ONE cancel funnel (so every existing
// cancelUpstream/cancelCoordinator call site is unchanged) and decomposes the
// wall into phases that are armed and re-armed as the request advances:
//
//	admission       gateway first byte -> coordinator response headers
//	first_token     response headers   -> first content-bearing delta
//	stream_ceiling  gateway first byte -> hard max_tokens-derived safety bound
//	non_stream_wall gateway first byte -> full buffered response (flat, legacy)
//
// Decode progress between tokens is NOT a phase: it stays on the existing
// streaming idle timer, which #760 converts from "any byte" to "content
// progress" (see readStreamingLineWithIdleTimeout).
//
// Cancellation carries a CAUSE. Callers must therefore ask
// phaseDeadlineExceeded(ctx) rather than errors.Is(ctx.Err(),
// context.DeadlineExceeded): a cause-cancelled context reports
// context.Canceled from Err(), so the legacy DeadlineExceeded checks would
// silently stop matching.
const (
	deadlinePhaseAdmission     = "admission"
	deadlinePhaseFirstToken    = "first_token"
	deadlinePhaseStreamCeiling = "stream_ceiling"
	deadlinePhaseNonStreamWall = "non_stream_wall"
	// deadlineReasonDecodeIdle is not a requestDeadlines phase (the idle
	// timer lives in the read loop) but shares the deadline_phase log field
	// so operators see one vocabulary for every timeout terminal.
	deadlineReasonDecodeIdle = "decode_idle"
)

// spec019StructuredStreamingCeiling is the structured-output streaming budget
// SPEC-019 v0.2.4 pins normatively (§AC-V2-9: "300s from gateway first byte of
// request to provider terminal SSE frame").
//
// TODO(#760): the max_tokens-derived ceiling below can legitimately exceed
// 300s for large generations, and OpenRouter traffic routinely carries
// response_format. Raising the structured bound is a SPEC-019 amendment
// (contract_change: yes) and is deliberately NOT taken in this PR, so
// structured streams keep the pinned 300s sub-ceiling and the contract is
// unchanged. Revisit together with the SPEC-019 §AC-V2-9 amendment decision.
const spec019StructuredStreamingCeiling = 300 * time.Second

// phaseDeadlineError is the cancellation cause recorded when a phase budget
// expires. It carries the phase so the terminal path can log WHICH clock ran
// out without widening any buyer-visible error code.
type phaseDeadlineError struct {
	Phase string
}

func (e *phaseDeadlineError) Error() string {
	return fmt.Sprintf("request phase deadline exceeded: %s", e.Phase)
}

// requestDeadlines owns the upstream request context and the timers that can
// cancel it. Exactly one phase timer is armed at a time (it is re-armed as the
// request advances); the ceiling timer is armed at most once and is never
// re-armed, so a stream can never extend its own hard bound.
type requestDeadlines struct {
	ctx    context.Context
	cancel context.CancelCauseFunc

	// startedAt is real wall-clock time at handler entry, deliberately NOT
	// the injectable s.now() clock: tests pin s.now() to a constant, and
	// these are timer budgets, not billing timestamps. SPEC-019 AC-V2-9
	// makes gateway first-byte-of-request the zero point, so phases that
	// bound the whole request are armed *from start* and pre-upstream
	// gateway time counts against them.
	startedAt time.Time

	mu      sync.Mutex
	stopped bool
	phase   *time.Timer
	ceiling *time.Timer
	// reason is an explicitly recorded terminal clock that has no
	// cancellation cause of its own — today only the decode-idle timer,
	// which cancels the upstream itself and reports via a sentinel error.
	reason string
}

func newRequestDeadlines(parent context.Context) *requestDeadlines {
	ctx, cancel := context.WithCancelCause(parent)
	return &requestDeadlines{ctx: ctx, cancel: cancel, startedAt: time.Now()}
}

// Context returns the upstream context every coordinator request is built on.
func (d *requestDeadlines) Context() context.Context { return d.ctx }

// Cancel is the single cancel funnel handed to the streaming read loop as
// cancelUpstream. It records a plain cancellation, so a phase cause already
// latched by an expiring timer wins (context.CancelCauseFunc keeps the first
// cause) and the terminal path still reports the phase that fired.
func (d *requestDeadlines) Cancel() { d.cancel(context.Canceled) }

// Stop releases the timers and cancels the context. Safe to call twice; the
// handler defers it exactly where `defer cancelUpstream()` used to sit.
func (d *requestDeadlines) Stop() {
	d.mu.Lock()
	d.stopped = true
	if d.phase != nil {
		d.phase.Stop()
		d.phase = nil
	}
	if d.ceiling != nil {
		d.ceiling.Stop()
		d.ceiling = nil
	}
	d.mu.Unlock()
	d.Cancel()
}

// armPhase (re-)arms the single phase timer for budget measured from now,
// replacing whatever phase was armed before.
func (d *requestDeadlines) armPhase(phase string, budget time.Duration) {
	d.armPhaseAt(phase, budget)
}

// armPhaseFromStart (re-)arms the phase timer for budget measured from
// gateway first byte of request, so slow request-body reads and pre-upstream
// gateway work count against the budget (SPEC-019 AC-V2-9).
func (d *requestDeadlines) armPhaseFromStart(phase string, budget time.Duration) {
	d.armPhaseAt(phase, budget-time.Since(d.startedAt))
}

func (d *requestDeadlines) armPhaseAt(phase string, remaining time.Duration) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.stopped {
		return
	}
	if d.phase != nil {
		d.phase.Stop()
	}
	if remaining <= 0 {
		d.phase = nil
		d.cancel(&phaseDeadlineError{Phase: phase})
		return
	}
	d.phase = time.AfterFunc(remaining, func() {
		d.cancel(&phaseDeadlineError{Phase: phase})
	})
}

// disarmPhase drops the phase timer without touching the ceiling. Called once
// the stream is demonstrably producing content: from there on, decode progress
// is policed by the idle timer and the total by the ceiling.
func (d *requestDeadlines) disarmPhase() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.phase != nil {
		d.phase.Stop()
		d.phase = nil
	}
}

// armCeiling arms the hard streaming bound, measured from gateway first byte
// of request. It is armed at most once and never re-armed, so no amount of
// upstream progress can push the ceiling out.
func (d *requestDeadlines) armCeiling(budget time.Duration) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.stopped || d.ceiling != nil {
		return
	}
	remaining := budget - time.Since(d.startedAt)
	if remaining <= 0 {
		d.cancel(&phaseDeadlineError{Phase: deadlinePhaseStreamCeiling})
		return
	}
	d.ceiling = time.AfterFunc(remaining, func() {
		d.cancel(&phaseDeadlineError{Phase: deadlinePhaseStreamCeiling})
	})
}

// noteReason records a terminal clock that is not a cancellation cause.
func (d *requestDeadlines) noteReason(reason string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.reason == "" {
		d.reason = reason
	}
}

// expiredPhase reports the clock that ended the request, or "". Used by the
// per-request log defer to stamp deadline_phase. An explicitly noted reason
// wins over the cancellation cause, because the idle timer cancels the
// upstream itself and would otherwise be masked by a plain cancellation.
func (d *requestDeadlines) expiredPhase() string {
	d.mu.Lock()
	reason := d.reason
	d.mu.Unlock()
	if reason != "" {
		return reason
	}
	phase, _ := phaseDeadlineExceeded(d.ctx)
	return phase
}

// phaseDeadlineExceeded reports whether ctx was cancelled by an expiring phase
// budget, and which phase.
//
// This REPLACES errors.Is(ctx.Err(), context.DeadlineExceeded) at every call
// site: the upstream context is now cancel-with-cause, so Err() reports
// context.Canceled and the legacy check would never match again.
func phaseDeadlineExceeded(ctx context.Context) (string, bool) {
	var deadline *phaseDeadlineError
	if errors.As(context.Cause(ctx), &deadline) {
		return deadline.Phase, true
	}
	return "", false
}

// streamCeiling derives the hard streaming bound from the request's max_tokens:
//
//	clamp(floor + max_tokens*per_token, >= coordinator_request_seconds, <= max)
//
// max_tokens is never absent here — handleChatCompletions substitutes the
// configured per-request cap and rejects anything above it before this runs.
//
// The lower clamp is a monotonicity invariant: the ceiling must never be
// SHORTER than the flat wall it replaces, so decomposing the wall can only
// ever let a request live longer, never cut one that survives today.
// effectiveStreamCeiling is streamCeiling plus the SPEC-019 sub-ceiling that
// still binds structured-output streams. See spec019StructuredStreamingCeiling
// for why the pinned 300s is not raised in this change.
func (s *Server) effectiveStreamCeiling(maxTokens int64, structuredStreaming bool) time.Duration {
	ceiling := streamCeiling(maxTokens, s.cfg)
	if structuredStreaming && ceiling > spec019StructuredStreamingCeiling {
		return spec019StructuredStreamingCeiling
	}
	return ceiling
}

func streamCeiling(maxTokens int64, cfg config.Config) time.Duration {
	totalMS := int64(cfg.Timeouts.StreamCeilingFloorSeconds) * 1000
	perTokenMS := int64(cfg.Timeouts.StreamCeilingPerTokenMS)
	maxMS := int64(cfg.Timeouts.StreamCeilingMaxSeconds) * 1000
	if maxTokens > 0 && perTokenMS > 0 {
		// Saturate instead of overflowing: max_tokens is operator-configurable
		// (limits.max_tokens_per_request) and the clamp below discards the
		// saturated value anyway.
		if maxTokens > (math.MaxInt64-totalMS)/perTokenMS {
			totalMS = math.MaxInt64
		} else {
			totalMS += maxTokens * perTokenMS
		}
	}
	if totalMS > maxMS {
		totalMS = maxMS
	}
	if minMS := int64(cfg.Timeouts.CoordinatorRequestSeconds) * 1000; totalMS < minMS {
		totalMS = minMS
	}
	return time.Duration(totalMS) * time.Millisecond
}
