package routing_test

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

func makeKeyer() func(pool.Provider) string {
	// Mirror the buyer-package routeKey shape: (provider_id, assigned_id)
	return func(p pool.Provider) string {
		return p.ProviderID + "|" + p.AssignedID
	}
}

func TestExcluded_AddAndHas(t *testing.T) {
	t.Parallel()
	ex := routing.NewExcluded(4)
	key := makeKeyer()
	a := pool.Provider{ProviderID: "p-1", AssignedID: "s-1"}
	b := pool.Provider{ProviderID: "p-2", AssignedID: "s-2"}
	ex.Add(a, key)
	if !ex.Has(key(a)) {
		t.Fatalf("after Add(a), Has(key(a)): want true")
	}
	if ex.Has(key(b)) {
		t.Fatalf("Has(key(b)) before Add(b): want false")
	}
}

func TestExcluded_AddKeyAvoidsKeyerCallback(t *testing.T) {
	t.Parallel()
	ex := routing.NewExcluded(2)
	ex.AddKey("precomputed-key")
	if !ex.Has("precomputed-key") {
		t.Fatalf("AddKey should make Has return true")
	}
}

func TestExcluded_DistinguishesAssignedIDs(t *testing.T) {
	// Two admissions of the same peer (e.g., provider reconnected
	// with a new assigned_id) are distinct entries; excluding one
	// MUST NOT silently exclude the other.
	t.Parallel()
	ex := routing.NewExcluded(2)
	key := makeKeyer()
	first := pool.Provider{ProviderID: "p-1", AssignedID: "s-1"}
	second := pool.Provider{ProviderID: "p-1", AssignedID: "s-2"}
	ex.Add(first, key)
	if !ex.Has(key(first)) {
		t.Fatalf("first admission excluded as expected")
	}
	if ex.Has(key(second)) {
		t.Fatalf("second admission (different assigned_id) should NOT be excluded")
	}
}

func TestExcluded_LenCountsDistinctKeys(t *testing.T) {
	t.Parallel()
	ex := routing.NewExcluded(4)
	key := makeKeyer()
	ex.Add(pool.Provider{ProviderID: "p-1", AssignedID: "s-1"}, key)
	ex.Add(pool.Provider{ProviderID: "p-1", AssignedID: "s-1"}, key) // dup
	ex.Add(pool.Provider{ProviderID: "p-2", AssignedID: "s-2"}, key)
	if got := ex.Len(); got != 2 {
		t.Fatalf("Len after 2 distinct + 1 dup: want 2, got %d", got)
	}
}

func TestExcluded_ZeroValueIsSafe(t *testing.T) {
	// A zero Excluded{} (nil-map) MUST not panic on Add / Has / Len.
	// This protects callers that forget NewExcluded; the
	// money-path posture is "no exclusion" rather than panic.
	t.Parallel()
	var ex routing.Excluded
	key := makeKeyer()
	a := pool.Provider{ProviderID: "p-1", AssignedID: "s-1"}
	ex.Add(a, key) // must not panic
	if ex.Has(key(a)) {
		t.Fatalf("zero-value Add is a no-op: Has must return false")
	}
	if ex.Len() != 0 {
		t.Fatalf("zero-value Len: want 0")
	}
}
