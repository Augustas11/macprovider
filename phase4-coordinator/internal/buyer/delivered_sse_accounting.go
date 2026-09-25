package buyer

import (
	"bytes"
	"encoding/json"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// maxDeliveredSSEBuffer caps each partial buffer the accounting holds (a
// provider line awaiting its "\n", accepted bytes awaiting an event
// terminator) at the stream byte limit. Past it the accounting stops at the
// last delivered event, and nothing after it bills.
const maxDeliveredSSEBuffer = int(maxUpstreamResponseBodyBytes)

// deliveredSSEAccounting is the single source of truth for what an SSE
// attempt delivered to the buyer and may bill, on every SSE path (HTTP
// incremental, HTTP buffered, WS incremental, WS buffered, tool-call
// materialization, and JSON-to-SSE tool-call rendering). SPEC-015
// delivered-prefix rule, SPEC-022 R-5.6.
//
// It sees two streams:
//   - provider: the provider's ORIGINAL SSE bytes, before any buyer-facing
//     rewrite. Usage is taken from here, and only from events the provider
//     terminated with a blank line; an unterminated tail never counts.
//   - rendered/written: the buyer-facing bytes the path queued and the bytes
//     the buyer writer accepted. An event is delivered only once its
//     blank-line terminator ("\n" or "\r\n" framed) was accepted.
//
// Each terminated provider usage is pinned to the rendered event that carries
// usage, in stream order, in the next rendering queued at or after it; a
// rendering that carries no usage pins it to its last complete event. It
// counts once the buyer received through that event's terminator. Delivered
// usage accumulates in stream order and is never cleared by a later tail.
// Once content was delivered, a prompt count is kept as soon as the buyer
// received any byte of the event it is pinned to, even if that event's
// terminator never arrived: the prompt was consumed either way. The
// completion follows delivery only.
type deliveredSSEAccounting struct {
	// provider side
	providerLine  []byte     // partial provider line awaiting its "\n"
	providerEvent sseUsage   // usage of the provider event not yet terminated
	unassigned    []sseUsage // terminated event usages awaiting a rendering
	staged        []stagedSSEUsage

	// buyer side
	queued        int    // rendered bytes queued for the buyer
	lastBoundary  int    // queued offset of the last event terminator
	renderedUsage bool   // the open rendered event carries usage
	pending       []byte // accepted bytes after the last delivered event boundary
	delivered     int    // accepted bytes through the last delivered event boundary
	usage         sseUsage
	reached       sseUsage // prompt of pinned events the buyer began to receive
	overflow      bool     // a buffer passed maxDeliveredSSEBuffer
	tracker       *settlementStreamOutputTracker
}

type sseUsage struct {
	prompt, cached, completion *int64
}

func (u sseUsage) empty() bool {
	return u.prompt == nil && u.cached == nil && u.completion == nil
}

func (u sseUsage) merge(next sseUsage) sseUsage {
	p, c, o := mergeStreamUsagePointers(u.prompt, u.cached, u.completion, next.prompt, next.cached, next.completion)
	return sseUsage{prompt: p, cached: c, completion: o}
}

type stagedSSEUsage struct {
	usage  sseUsage
	start  int // queued offset where the pinned event begins
	offset int // queued offset just past the pinned event's terminator
}

func newDeliveredSSEAccounting() *deliveredSSEAccounting {
	return &deliveredSSEAccounting{tracker: newSettlementStreamOutputTracker()}
}

// provider records original provider bytes.
func (a *deliveredSSEAccounting) provider(original []byte) {
	for len(original) > 0 && !a.overflow {
		i := bytes.IndexByte(original, '\n')
		take := i + 1
		if i < 0 {
			take = len(original)
		}
		if len(a.providerLine)+take > maxDeliveredSSEBuffer {
			a.overflow = true
			return
		}
		a.providerLine = append(a.providerLine, original[:take]...)
		original = original[take:]
		if i < 0 {
			return
		}
		line := a.providerLine
		a.providerLine = nil
		if isSSEBlankLine(line) {
			if !a.providerEvent.empty() {
				a.unassigned = append(a.unassigned, a.providerEvent)
			}
			a.providerEvent = sseUsage{}
			continue
		}
		if p, cached, c := tokenPointersFromSSE(line); p != nil || cached != nil || c != nil {
			a.providerEvent = a.providerEvent.merge(sseUsage{prompt: p, cached: cached, completion: c})
		}
	}
}

// validate reports whether rendered would parse as settlement output.
func (a *deliveredSSEAccounting) validate(rendered []byte) error {
	return a.tracker.validateBlock(rendered)
}

// render queues buyer-facing bytes, before they are written.
func (a *deliveredSSEAccounting) render(rendered []byte) {
	if len(rendered) == 0 || a.overflow {
		return
	}
	var carriers []stagedSSEUsage // complete rendered events that carry usage
	last := stagedSSEUsage{offset: -1}
	start, offset := a.lastBoundary, a.queued
	for _, line := range bytes.SplitAfter(rendered, []byte("\n")) {
		offset += len(line)
		if isSSEBlankLine(line) {
			event := stagedSSEUsage{start: start, offset: offset}
			if a.renderedUsage {
				carriers = append(carriers, event)
			}
			last, start, a.renderedUsage = event, offset, false
			continue
		}
		if p, cached, c := tokenPointersFromSSE(line); p != nil || cached != nil || c != nil {
			a.renderedUsage = true
		}
	}
	a.queued += len(rendered)
	if last.offset < 0 {
		return
	}
	// The i-th terminated provider usage rides the i-th usage-carrying
	// rendered event; extra usages (a rendering that merged several) ride
	// the last one. A rendered event is never earlier than the provider
	// event whose usage it carries, so this never bills ahead of delivery.
	for i, u := range a.unassigned {
		target := last
		if len(carriers) > 0 {
			target = carriers[min(i, len(carriers)-1)]
		}
		target.usage = u
		a.staged = append(a.staged, target)
	}
	a.unassigned = nil
	a.lastBoundary = last.offset
}

// written records buyer-facing bytes the buyer writer accepted.
func (a *deliveredSSEAccounting) written(accepted []byte) {
	if a.overflow {
		return
	}
	if len(a.pending)+len(accepted) > maxDeliveredSSEBuffer {
		a.overflow = true
		return
	}
	a.pending = append(a.pending, accepted...)
	received := a.delivered + len(a.pending)
	for _, s := range a.staged {
		if received > s.start && s.usage.prompt != nil {
			a.reached = a.reached.merge(sseUsage{prompt: s.usage.prompt, cached: s.usage.cached})
		}
	}
	end := completeSSEEventsLen(a.pending)
	if end == 0 {
		return
	}
	_ = a.tracker.observeBlock(a.pending[:end])
	a.delivered += end
	a.pending = append(a.pending[:0], a.pending[end:]...)
	kept := a.staged[:0]
	for _, s := range a.staged {
		if s.offset <= a.delivered {
			a.usage = a.usage.merge(s.usage)
			continue
		}
		kept = append(kept, s)
	}
	a.staged = kept
}

// deliveredBytes is the byte basis of every estimate: delivered events only.
func (a *deliveredSSEAccounting) deliveredBytes() int {
	return a.delivered
}

func (a *deliveredSSEAccounting) contentDelivered() bool {
	return a.tracker.content != "" || len(a.tracker.toolCalls) > 0
}

// billableUsage is the usage a delivered prefix may bill: usage carried by
// delivered events, plus, once content was delivered, the prompt of a pinned
// event the buyer began to receive.
func (a *deliveredSSEAccounting) billableUsage() sseUsage {
	u := a.usage
	if u.prompt == nil && a.contentDelivered() && a.reached.prompt != nil {
		u.prompt, u.cached = a.reached.prompt, a.reached.cached
	}
	return u
}

// fullyDelivered reports whether everything the provider terminated and the
// path queued reached the buyer as complete events, with no provider tail.
func (a *deliveredSSEAccounting) fullyDelivered() bool {
	return !a.overflow && len(a.providerLine) == 0 && a.providerEvent.empty() && len(a.unassigned) == 0 &&
		len(a.staged) == 0 && len(a.pending) == 0 && a.delivered == a.queued
}

// completionUsage is the usage a completed attempt bills. A provider end
// frame's usage is used only when the stream was fully delivered.
func (a *deliveredSSEAccounting) completionUsage(endUsage json.RawMessage) sseUsage {
	u := a.billableUsage()
	if !a.fullyDelivered() {
		return u
	}
	if p, cached, c := tokenPointersFromUsageObject(endUsage); p != nil || cached != nil || c != nil {
		u = u.merge(sseUsage{prompt: p, cached: cached, completion: c})
	}
	return u
}

// output is the settlement evidence of the delivered events.
func (a *deliveredSSEAccounting) output(terminalState string) *billing.SettlementOutput {
	return a.tracker.output(terminalState)
}

func (a *deliveredSSEAccounting) outputAt(terminalState string, terminalStateTSUnixMS int64) *billing.SettlementOutput {
	return a.tracker.outputAt(terminalState, terminalStateTSUnixMS)
}

// applyUsage fills an attempt's usage fields; the byte estimate covers the
// completion only when no delivered completion count exists.
func (a *deliveredSSEAccounting) applyUsage(s *Server, attempt *requestLogAttempt, u sseUsage) {
	attempt.PromptTokens, attempt.CachedPromptTokens, attempt.CompletionTokens = u.prompt, u.cached, u.completion
	if u.completion == nil {
		attempt.EstimatedCompTokens = s.estimatedCompletionTokensFromBytes(a.delivered)
	}
}
