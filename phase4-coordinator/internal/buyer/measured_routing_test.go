package buyer

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

// SPEC-002-R005: the min_provider_throughput_tps floor compares routed
// throughput. phaseTestServer registers "slow" (estimate 500) and "fast"
// (estimate 10), both serving model-a.
func TestThroughputFloorUsesRoutedThroughput(t *testing.T) {
	s, registry := phaseTestServer(t)
	s.minProviderThroughput = 50
	slow, _ := registry.Resolve("slow", "s-slow")
	fast, _ := registry.Resolve("fast", "s-fast")
	if !s.providerMeetsRoutingQuality(slow) || s.providerMeetsRoutingQuality(fast) {
		t.Fatal("without evidence the floor must read the estimate")
	}
	// slow measures 20 tok/s decode, fast 200 tok/s.
	warmProvider(s, "slow", 50, 5000)
	warmProvider(s, "fast", 50, 500)
	if s.providerMeetsRoutingQuality(slow) {
		t.Fatal("a fresh measured decode below the floor must exclude")
	}
	if !s.providerMeetsRoutingQuality(fast) {
		t.Fatal("a fresh measured decode above the floor must admit")
	}
	state := &forwardState{}
	p, routeErr := s.selectProviderExcluding(context.Background(), "rid-floor", streamChatReq(), http.Header{"Authorization": []string{"Bearer gateway-secret"}, "X-Macprovider-Account": []string{"acct-1"}}, nil, "2026-10-13", state)
	if routeErr != nil || p.ProviderID != "fast" {
		t.Fatalf("buyer path chose %q err=%+v", p.ProviderID, routeErr)
	}
	// The slot-queue re-check runs the same floor at poll time.
	w, ok := s.slotQueue.enter(slow.ProviderID)
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	if _, status := s.pollQueuedProvider(w, "model-a", nil, 100, nil); status != queuedProviderTerminal {
		t.Fatalf("slot-queue poll status = %v, want terminal", status)
	}
	s.slotQueue.leave(w)
	// Excluded, slow gets no traffic; once its decode signal is stale it is
	// judged on its estimate again, and fast falls back to its estimate.
	s.now = func() time.Time { return phaseTestNow.Add(routing.PerfFreshMaxAge + time.Minute) }
	if !s.providerMeetsRoutingQuality(slow) || s.providerMeetsRoutingQuality(fast) {
		t.Fatal("stale evidence must fall back to the estimate")
	}
}

// SPEC-002-R005: the record is keyed by the dispatched session's served
// model, case-folded, whatever string the buyer requested (alias, catalog
// key, casing or class name).
func TestServedPerformanceKeyedByDispatchedModel(t *testing.T) {
	s, _ := phaseTestServer(t)
	for _, requested := range []string{"model-a", "MODEL-A", "my-alias", "class:fast-chat", "catalog/model-a@v1"} {
		state := &forwardState{estimatedTokens: 300, routingEstimatedTokens: 300}
		state.phaseTiming.markProviderDispatchStart(phaseTestNow, pool.Provider{AssignedID: "s-fast", ProviderID: "fast", ModelID: "Model-A"})
		state.phaseTiming.markProviderFirstToken(phaseTestNow.Add(50 * time.Millisecond))
		state.phaseTiming.markProviderDone(phaseTestNow.Add(1050 * time.Millisecond))
		rec := &billingRecorder{server: s, state: state, model: requested, stream: true}
		output := settlementOutputForContent(strings.Repeat("x", 404), nil, nil, "normal_done")
		_ = rec.recordRow("s-fast", "fast", "", http.StatusOK, nil, nil, nil, "", "", 0, nil, "none", output)
	}
	if s.perf.Len() != 1 {
		t.Fatalf("records = %d, want one shared record", s.perf.Len())
	}
	if e, ok := s.perf.Lookup("fast", "model-a"); !ok || e.DecodeSamples != 5 {
		t.Fatalf("evidence = %+v ok=%v", e, ok)
	}
}

// The selection's routing-decision view carries the measured weights, so the
// sort, cohorts and log of one selection read the same routed values; with
// one fresh candidate nothing moves.
func TestSortCandidatesMeasuredView(t *testing.T) {
	s, registry := phaseTestServer(t)
	slow, _ := registry.Resolve("slow", "s-slow")
	fast, _ := registry.Resolve("fast", "s-fast")
	warmProvider(s, "fast", 50, 100)
	one := []pool.Provider{fast, slow}
	view := s.sortCandidates(one, "fast")
	if one[0].ProviderID != "slow" || len(view.weights.Measured) != 1 {
		t.Fatalf("one fresh: order %s,%s measured=%v", one[0].ProviderID, one[1].ProviderID, view.weights.Measured)
	}
	warmProvider(s, "slow", 50, 5000)
	two := []pool.Provider{slow, fast}
	view = s.sortCandidates(two, "fast")
	if two[0].ProviderID != "fast" || len(view.weights.Measured) != 2 {
		t.Fatalf("two fresh: order %s,%s measured=%v", two[0].ProviderID, two[1].ProviderID, view.weights.Measured)
	}
	if got := view.routingWeights(s).Measured[fast.SortKey()]; got <= 0 {
		t.Fatalf("view weights lost measured value: %v", got)
	}
	var nilView *objectiveView
	if nilView.routingWeights(s).Measured != nil || nilView.balancedScores() != nil {
		t.Fatal("a nil view must read estimates only")
	}
}

// streamedAttempt records one streamed attempt for provider "fast": first
// token 50 ms after dispatch, done at doneMs, 404 delivered bytes (101
// tokens). between runs while the decode window is open.
func streamedAttempt(s *Server, headers http.Header, doneMs int, between func(state *forwardState)) {
	state := &forwardState{estimatedTokens: 300, routingEstimatedTokens: 300}
	state.perfPinned = hasPinnedRoute(headers)
	state.phaseTiming.markProviderDispatchStart(phaseTestNow, pool.Provider{AssignedID: "s-fast", ProviderID: "fast", ModelID: "model-a"})
	state.phaseTiming.markProviderFirstToken(phaseTestNow.Add(50 * time.Millisecond))
	if between != nil {
		between(state)
	}
	state.phaseTiming.markProviderDone(phaseTestNow.Add(time.Duration(doneMs) * time.Millisecond))
	rec := &billingRecorder{server: s, state: state, model: "model-a", stream: true}
	output := settlementOutputForContent(strings.Repeat("x", 404), nil, nil, "normal_done")
	_ = rec.recordRow("s-fast", "fast", "", http.StatusOK, nil, nil, nil, "", "", 0, nil, "none", output)
}

// SPEC-002-R005: a request that pins its provider records nothing, in any
// phase signal.
func TestPinnedRequestRecordsNoPerformance(t *testing.T) {
	for _, header := range []string{"X-MacProvider-Provider", "X-MacProvider-Session"} {
		s, _ := phaseTestServer(t)
		headers := http.Header{}
		headers.Set(header, "fast")
		streamedAttempt(s, headers, 1050, nil)
		if s.perf.Len() != 0 {
			t.Fatalf("%s: pinned attempt was recorded", header)
		}
	}
}

// blockingWriter is a buyer that reads slowly: every write blocks.
type blockingWriter struct {
	*httptest.ResponseRecorder
	delay time.Duration
}

func (w blockingWriter) Write(b []byte) (int, error) {
	time.Sleep(w.delay)
	return w.ResponseRecorder.Write(b)
}

// SPEC-002-R005: the decode window leaves out the time the coordinator was
// blocked writing to the buyer, so a slow reader cannot lower a fast
// provider's rate; a mostly buyer-limited window gives no decode sample; a
// non-blocking buyer gives exactly the unadjusted sample, and the bytes
// reach the buyer unchanged and in order.
func TestBuyerBlockedTimeLeavesDecodeAtProviderPace(t *testing.T) {
	chunks := []string{"data: a\n\n", "data: bb\n\n", "data: ccc\n\n"}
	write := func(state *forwardState, underlying http.ResponseWriter) {
		w := &phaseTimingResponseWriter{ResponseWriter: underlying, state: state, now: func() time.Time { return phaseTestNow }}
		for _, c := range chunks {
			_, _ = w.Write([]byte(c))
			w.Flush()
		}
	}
	// Non-blocking buyer: 100 tokens over the 1000 ms window, as before.
	s, _ := phaseTestServer(t)
	plain := httptest.NewRecorder()
	streamedAttempt(s, http.Header{}, 1050, func(state *forwardState) { write(state, plain) })
	if e, _ := s.perf.Lookup("fast", "model-a"); e.DecodeTPS != 100 || e.DecodeSamples != 1 {
		t.Fatalf("non-blocking: %+v", e)
	}
	if plain.Body.String() != strings.Join(chunks, "") {
		t.Fatalf("bytes changed: %q", plain.Body.String())
	}
	// Slow buyer: three writes of at least 40 ms each inside a 1000 ms
	// window. Without the adjustment the rate would be 100 tok/s; with it
	// the provider's pace is higher, never lower.
	s, _ = phaseTestServer(t)
	slow := blockingWriter{ResponseRecorder: httptest.NewRecorder(), delay: 40 * time.Millisecond}
	streamedAttempt(s, http.Header{}, 1050, func(state *forwardState) { write(state, slow) })
	e, _ := s.perf.Lookup("fast", "model-a")
	if e.DecodeSamples != 1 || e.DecodeTPS <= 100 {
		t.Fatalf("slow buyer lowered or lost the decode sample: %+v", e)
	}
	if slow.Body.String() != strings.Join(chunks, "") {
		t.Fatalf("bytes changed: %q", slow.Body.String())
	}
	// Buyer-limited: 900 ms of the 1000 ms window blocked on the buyer.
	s, _ = phaseTestServer(t)
	streamedAttempt(s, http.Header{}, 1050, func(state *forwardState) { state.phaseTiming.addBuyerWrite(900 * time.Millisecond) })
	e, _ = s.perf.Lookup("fast", "model-a")
	if e.DecodeSamples != 0 || e.TTFTSamples != 1 {
		t.Fatalf("buyer-limited attempt kept a decode sample: %+v", e)
	}
	// Writes outside the window and sub-millisecond writes do not count.
	state := &forwardState{}
	state.phaseTiming.addBuyerWrite(time.Second)
	state.phaseTiming.markProviderFirstToken(phaseTestNow)
	state.phaseTiming.addBuyerWrite(routing.PerfBuyerWriteMin - time.Nanosecond)
	if got := state.phaseTiming.snapshot().buyerBlocked; got != 0 {
		t.Fatalf("buyerBlocked = %v", got)
	}
}

// SPEC-004 §7: the slot-queue and retry routing-decision logs name the
// measured source of a decode-fresh candidate.
func TestSlotQueueAndRetryLogsCarryMeasuredSource(t *testing.T) {
	s, registry := phaseTestServer(t)
	var buf bytes.Buffer
	s.log = zerolog.New(&buf)
	warmProvider(s, "fast", 50, 500)
	fast, _ := registry.Resolve("fast", "s-fast")
	state := newForwardState(phaseTestNow)
	_, routeErr, ok := s.trySelectQueuedProvider(context.Background(), "rid-queue", "model-a", []pool.Provider{fast}, http.Header{}, nil, "2026-10-13", 100, state, slotWaiterStandard)
	if !ok || routeErr != nil {
		t.Fatalf("queued selection ok=%v err=%+v", ok, routeErr)
	}
	if !strings.Contains(buf.String(), `slot_queue_`) || !strings.Contains(buf.String(), `"throughput_source":"measured"`) {
		t.Fatalf("slot-queue log: %s", buf.String())
	}
	buf.Reset()
	s.logRoutingDecisionRetry("rid-retry", []pool.Provider{fast}, "fast", "fast", "retry", retryDecisionAttrs{AttemptIndex: 2})
	if !strings.Contains(buf.String(), `"throughput_source":"measured"`) {
		t.Fatalf("retry log: %s", buf.String())
	}
}

// Two decode-fresh candidates with equal estimates and different measured
// decode: sticky on the slower one is outside the epsilon cohort, and the
// random tiebreak cohort holds only the faster one.
func TestStickyAndTiebreakCompareMeasuredValues(t *testing.T) {
	s, registry := phaseTestServer(t)
	s.stickyEnabled = true
	s.tiebreakRandomize = true
	s.tiebreakEpsilon = 0.05
	warmProvider(s, "slow", 50, 5000) // 20 tok/s
	warmProvider(s, "fast", 50, 500)  // 200 tok/s
	slow, _ := registry.Resolve("slow", "s-slow")
	fast, _ := registry.Resolve("fast", "s-fast")
	slow.ThroughputTPSEstimate, fast.ThroughputTPSEstimate = 100, 100
	candidates := []pool.Provider{slow, fast}
	view := s.sortCandidates(candidates, "fast")
	if candidates[0].ProviderID != "fast" {
		t.Fatalf("order = %s,%s", candidates[0].ProviderID, candidates[1].ProviderID)
	}
	var buf bytes.Buffer
	s.log = zerolog.New(&buf)
	headers := http.Header{}
	headers.Set("X-MacProvider-Internal-Conv", "conv:measured-sticky")
	s.stickyMap.Update("conv:measured-sticky", "acct-1", "slow", "model-a")
	_, result, reason := s.applySticky("rid-sticky", headers, "model-a", nil, candidates, view)
	if result != "miss" || reason != "outside_epsilon" || !strings.Contains(buf.String(), "sticky_outside_epsilon") {
		t.Fatalf("sticky result=%q reason=%q log=%s", result, reason, buf.String())
	}
	_, _, _, tiebreak := s.applyRandomTiebreak("rid-tiebreak", candidates, "fast", "2026-10-13", view)
	if tiebreak != "deterministic" {
		t.Fatalf("tiebreak = %q, want deterministic (cohort of one)", tiebreak)
	}
	// With estimates only, the two are one cohort.
	if _, _, _, estimateOnly := s.applyRandomTiebreak("rid-tiebreak", candidates, "fast", "2026-10-13", nil); estimateOnly != "randomized" {
		t.Fatalf("estimate-only tiebreak = %q", estimateOnly)
	}
}

// The floor cycle on the buyer path: excluded on fresh measured decode,
// readmitted on the estimate once the record is stale, and excluded again by
// the first new decode sample, which refreshes the record with its average.
func TestThroughputFloorReadmissionCycle(t *testing.T) {
	s, registry := phaseTestServer(t)
	s.minProviderThroughput = 50
	headers := http.Header{"Authorization": []string{"Bearer gateway-secret"}, "X-Macprovider-Account": []string{"acct-1"}}
	slow, _ := registry.Resolve("slow", "s-slow")
	warmProvider(s, "slow", 50, 5000) // 20 tok/s against an estimate of 500
	warmProvider(s, "fast", 50, 500)  // 200 tok/s against an estimate of 10
	if s.providerMeetsRoutingQuality(slow) {
		t.Fatal("fresh measured decode below the floor must exclude")
	}
	p, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", streamChatReq(), headers, nil, "2026-10-13", &forwardState{})
	if routeErr != nil || p.ProviderID == "slow" {
		t.Fatalf("buyer path chose %q err=%+v", p.ProviderID, routeErr)
	}
	later := phaseTestNow.Add(routing.PerfFreshMaxAge + time.Minute)
	s.now = func() time.Time { return later }
	if !s.providerMeetsRoutingQuality(slow) {
		t.Fatal("stale record must readmit on the estimate")
	}
	s.perf.Observe(routing.PerfObservation{ProviderID: "slow", Model: "model-a", PromptTokens: 200, CompletionTokens: 101, TTFTMs: 50, DecodeMs: 5000, At: later})
	if s.providerMeetsRoutingQuality(slow) {
		t.Fatal("the first new decode sample must make the record fresh and exclude again")
	}
}
