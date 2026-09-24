package buyer

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// The slot queue sees a sandboxed external-runtime member exactly as the
// candidate path does: only a pool route that establishes the external-runtime
// predicate clears the sandbox term; a global route and a non-allowlisted
// runtime keep the global answer.
func TestProviderForRouteMatchesCandidatePathSandboxView(t *testing.T) {
	p := pool.Provider{
		ProviderID:         "p1",
		RuntimeSource:      "llamacpp_loopback",
		State:              pool.StateReady,
		SlotsTotal:         1,
		SlotsFree:          0,
		AdmissionSandboxed: true,
	}
	view := poolRouteView{
		poolID:           "pool-a",
		members:          map[string]bool{"p1": true},
		runtimeAllowlist: []string{"llamacpp_loopback"},
		creatorAccountID: "creator-a",
		creatorOwned:     map[string]bool{"p1": true},
	}
	if p.SlotQueueEligible() {
		t.Fatal("global view: a sandboxed session must not queue")
	}
	if got := providerForRoute(p, poolRouteView{}); got.SlotQueueEligible() {
		t.Fatal("global route cleared the sandbox term")
	}
	if got := providerForRoute(p, view); !got.SlotQueueEligible() {
		t.Fatal("pool route with the external-runtime predicate should let the member wait for a seat")
	}
	if !p.AdmissionSandboxed {
		t.Fatal("providerForRoute must not mutate the caller's provider")
	}
	notAllowlisted := view
	notAllowlisted.runtimeAllowlist = []string{"ollama_loopback"}
	if got := providerForRoute(p, notAllowlisted); got.SlotQueueEligible() {
		t.Fatal("a runtime outside the pool allowlist must keep the sandbox term")
	}
}
