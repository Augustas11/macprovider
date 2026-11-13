package buyer

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

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
