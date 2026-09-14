package buyer

import (
	"context"
	"net/http"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// Test-only bridge: each signed fixture executes exactly one private production
// consumer as its first route observation, without a runtime testing API.
func AssertArtifactRoutePathsForTest(t *testing.T, s *Server, p pool.Provider, want bool, path string) {
	t.Helper()
	AssertArtifactRoutePathsWithEventForTest(t, s, p, providerws.ModelAdmissionEvent{}, want, path)
}

// AssertArtifactRoutePathsWithEventForTest exercises the actual private buyer
// entry points. The event is required only by the direct resolver path.
func AssertArtifactRoutePathsWithEventForTest(t *testing.T, s *Server, p pool.Provider, event providerws.ModelAdmissionEvent, want bool, path string) {
	t.Helper()
	var got bool
	switch path {
	case "direct resolver":
		_, err := s.ResolveModelAdmissionAuthority(context.Background(), p, event)
		got = err == nil
	case "default predicate":
		got = s.byomDefaultPaidRoutingEligible(p)
	case "direct binding":
		material, ok := tier2.SnapshotMaterial(p.ModelID, p.ModelHash)
		if !ok {
			t.Fatal("reference fixture missing")
		}
		_, found, eligible := s.byomRouteSnapshotBinding(context.Background(), p, material)
		if !found {
			t.Error("direct binding did not report the persisted artifact record as found")
		}
		got = eligible
	case "require binding":
		material, ok := tier2.SnapshotMaterial(p.ModelID, p.ModelHash)
		if !ok {
			t.Fatal("reference fixture missing")
		}
		_, err := s.requireBYOMRouteSnapshotBinding(context.Background(), p, material)
		got = err == nil
	case "eligibility context":
		checker := &eligibilityCtx{s: s, model: p.ModelID, tier2Cfg: s.tier2Config(), settlementEnforce: true}
		got = checker.ProviderBYOMSettlementEligible(p)
	case "queue candidates":
		checker := &eligibilityCtx{s: s, model: p.ModelID, tier2Cfg: s.tier2Config(), settlementEnforce: true}
		busy := p
		busy.SlotsFree = 0
		got = len(s.slotQueueCandidates([]pool.Provider{busy}, routing.NewExcluded(0), checker)) == 1
	case "queue poll":
		waiter, ok := s.slotQueue.enter(p.ProviderID)
		if !ok {
			t.Fatal("queue waiter unavailable")
		}
		_, status := s.pollQueuedProvider(waiter, p.ModelID, nil, 0, nil)
		s.slotQueue.leave(waiter)
		s.slotQueue.releaseReservation(p.ProviderID)
		got = status == queuedProviderAvailable
	case "actual selectProvider default", "actual selectProvider pinned":
		headers := http.Header{}
		if path == "actual selectProvider pinned" {
			headers.Set("X-MacProvider-Session", p.AssignedID)
		}
		selected, err := s.selectProvider(context.Background(), "fixture-route", chatRequest{Model: p.ModelID}, headers, "", &forwardState{})
		got = err == nil
		if got && (selected.ProviderID != p.ProviderID || selected.AssignedID != p.AssignedID) {
			t.Errorf("selected tuple = %s/%s, want %s/%s", selected.ProviderID, selected.AssignedID, p.ProviderID, p.AssignedID)
			got = false
		}
		if want && err != nil {
			t.Logf("select error: %+v", err)
		}
	default:
		t.Fatalf("unknown route path %q", path)
	}
	if got != want {
		t.Errorf("%s eligible=%v want=%v", path, got, want)
	}
}
