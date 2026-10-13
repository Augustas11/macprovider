package buyer

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-036 FR-25: a suspended model binds no relay-blind or privacy work.
func TestRelayBlindBindableExcludesComputeIntegritySuspended(t *testing.T) {
	p := pool.Provider{ProviderID: "p", AssignedID: "a", ModelID: "m", State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1}
	if !relayBlindBindable(p) {
		t.Fatal("baseline provider must be bindable")
	}
	p.ComputeIntegritySuspended = true
	if relayBlindBindable(p) {
		t.Fatal("a compute-integrity suspended provider must not be bindable")
	}
}
