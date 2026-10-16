package buyer

import (
	"strings"
	"testing"
	"time"

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

// SPEC-036 FR-20: verification accounts are a small per-provider set; each
// retires after its random lifetime and is replaced, and a provider whose
// accounts all retired is forgotten.
func TestComputeIntegrityProbeAccountsRecurAndRetire(t *testing.T) {
	var a computeIntegrityProbeAccounts
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		id, err := a.account("p1", t0)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(id, ComputeIntegrityAccountPrefix) {
			t.Fatalf("account %q lacks the reserved prefix", id)
		}
		seen[id] = true
	}
	if len(seen) > computeIntegrityProbeAccountsPerProvider {
		t.Fatalf("%d distinct accounts, want at most %d", len(seen), computeIntegrityProbeAccountsPerProvider)
	}
	if _, err := a.account("p2", t0); err != nil {
		t.Fatal(err)
	}
	later := t0.Add(computeIntegrityProbeAccountMaxLife + time.Hour)
	id, err := a.account("p2", later)
	if err != nil {
		t.Fatal(err)
	}
	if seen[id] {
		t.Fatal("a retired account must not be reused")
	}
	a.mu.Lock()
	_, kept := a.byProvider["p1"]
	a.mu.Unlock()
	if kept {
		t.Fatal("a provider whose accounts all retired must be forgotten")
	}
}
