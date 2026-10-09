package buyer

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func selectOrderProvider(id string, slotsFree int) pool.Provider {
	state := pool.StateReady
	if slotsFree == 0 {
		state = pool.StateBusy
	}
	return pool.Provider{ProviderID: id, AssignedID: "session-" + id, ModelID: "model-a", SlotsFree: slotsFree, SlotsTotal: 1, State: state, AuthState: pool.AuthBearerValidated, InferencePath: pool.InferencePathWSTunneled}
}

func selectOrderIDs(s *Server, providers []pool.Provider, key string) []string {
	order := s.orderRelayBlindCandidates(providers, key)
	ids := make([]string, len(order))
	for i, index := range order {
		ids[i] = providers[index].ProviderID
	}
	return ids
}

// A busy provider first in session order must not take a reservation while
// another provider has a free slot.
func TestRelayBlindCandidatesPreferFreeSlot(t *testing.T) {
	s := &Server{relayBlind: &relayBlindService{}}
	got := selectOrderIDs(s, []pool.Provider{selectOrderProvider("b", 1), selectOrderProvider("a", 0)}, "m")
	if got[0] != "b" || got[1] != "a" {
		t.Fatalf("order=%v, want the free provider first", got)
	}
}

// Concurrent reservations spread across equally ranked providers instead of
// all binding the first one in session order.
func TestRelayBlindCandidatesRotateWithinTier(t *testing.T) {
	s := &Server{relayBlind: &relayBlindService{}}
	firsts := map[string]int{}
	for range 6 {
		providers := []pool.Provider{selectOrderProvider("a", 1), selectOrderProvider("b", 1), selectOrderProvider("c", 1), selectOrderProvider("d", 0)}
		got := selectOrderIDs(s, providers, "m")
		if got[3] != "d" {
			t.Fatalf("order=%v, want the busy provider last", got)
		}
		firsts[got[0]]++
	}
	for _, id := range []string{"a", "b", "c"} {
		if firsts[id] != 2 {
			t.Fatalf("first-choice counts=%v, want each free provider twice", firsts)
		}
	}
}

// A free slot already claimed by a queued or reserved waiter is not free for
// a new reservation.
func TestRelayBlindCandidatesTreatClaimedSlotAsBusy(t *testing.T) {
	queue := newSlotQueue(8)
	if !queue.reserveProvider("a", 1) {
		t.Fatal("could not claim the slot")
	}
	s := &Server{relayBlind: &relayBlindService{}, slotQueue: queue}
	got := selectOrderIDs(s, []pool.Provider{selectOrderProvider("a", 1), selectOrderProvider("b", 1)}, "m")
	if got[0] != "b" {
		t.Fatalf("order=%v, want the unclaimed provider first", got)
	}
}

// Interleaved reservations for different models each rotate over their own
// providers instead of sharing one counter.
func TestRelayBlindCandidatesRotatePerModel(t *testing.T) {
	s := &Server{relayBlind: &relayBlindService{}}
	x := []pool.Provider{selectOrderProvider("x1", 1), selectOrderProvider("x2", 1)}
	y := []pool.Provider{selectOrderProvider("y1", 1), selectOrderProvider("y2", 1)}
	firsts := map[string]int{}
	for range 4 {
		firsts[selectOrderIDs(s, x, "privacy\x00model-x")[0]]++
		firsts[selectOrderIDs(s, y, "privacy\x00model-y")[0]]++
	}
	for _, id := range []string{"x1", "x2", "y1", "y2"} {
		if firsts[id] != 2 {
			t.Fatalf("first-choice counts=%v, want each provider twice", firsts)
		}
	}
}
