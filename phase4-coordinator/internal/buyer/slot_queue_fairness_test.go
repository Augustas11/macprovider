package buyer

import "testing"

// SPEC-049-R029: the slot queue keeps a plaintext lane and a pinned lane per
// provider. Each lane is FIFO; while both wait, grants alternate.

// grantNext gives one freed seat on provider to whichever waiter the queue
// says is next, then frees the seat again, and returns that waiter.
func grantNext(t *testing.T, queue *slotQueue, provider string, waiters []*slotWaiter) *slotWaiter {
	t.Helper()
	for _, waiter := range waiters {
		if waiter == nil || !queue.head(waiter) {
			continue
		}
		if !queue.reserveHead(waiter, fixedSlots(1)) {
			t.Fatal("next waiter could not take a free seat")
		}
		queue.releaseReservation(provider)
		return waiter
	}
	return nil
}

func TestSlotQueueAlternatesLanesWhenBothWait(t *testing.T) {
	queue := newSlotQueue(8)
	var all []*slotWaiter
	var standard, pinned []*slotWaiter
	for range 4 {
		waiter, ok := queue.enter("p")
		if !ok {
			t.Fatal("plaintext waiter rejected")
		}
		standard = append(standard, waiter)
		all = append(all, waiter)
	}
	for range 2 {
		waiter, ok := queue.enterPinned("p", 4)
		if !ok {
			t.Fatal("pinned waiter rejected")
		}
		pinned = append(pinned, waiter)
		all = append(all, waiter)
	}
	want := []*slotWaiter{pinned[0], standard[0], pinned[1], standard[1], standard[2], standard[3]}
	for i, expected := range want {
		got := grantNext(t, queue, "p", all)
		if got != expected {
			t.Fatalf("grant %d went to the wrong waiter (pinned=%v)", i, got != nil && got.pinned())
		}
	}
	if grantNext(t, queue, "p", all) != nil {
		t.Fatal("queue granted past its waiters")
	}
	queue.mu.Lock()
	defer queue.mu.Unlock()
	if len(queue.lastPinned) != 0 || len(queue.grants) != 0 || len(queue.queues) != 0 {
		t.Fatalf("lane state leaked after drain: lastPinned=%v grants=%v", queue.lastPinned, queue.grants)
	}
}

// Sustained plaintext load: the plaintext lane is refilled to its cap after
// every grant, and pinned waiters keep arriving. Every pinned waiter is
// served within two grants per position it held on arrival, and plaintext
// still takes at least every other grant.
func TestSlotQueueSustainedPlaintextLoadGivesPinnedFairShare(t *testing.T) {
	const laneCap = 8
	queue := newSlotQueue(laneCap)
	pinnedCap := relayBlindPinnedLaneCap(laneCap, 8)
	arrivedAt := map[*slotWaiter]int{}
	bound := map[*slotWaiter]int{}
	var live []*slotWaiter
	refill := func() {
		for {
			waiter, ok := queue.enter("p")
			if !ok {
				return
			}
			live = append(live, waiter)
		}
	}
	plainGrants, pinnedGrants, pinnedServed := 0, 0, 0
	for grant := range 2000 {
		queue.mu.Lock()
		queuedPinned := queue.laneLenLocked("p", slotWaiterPinned)
		queue.mu.Unlock()
		// A pinned request arrives on two of every three grants: more than
		// its half share, so the pinned lane stays saturated.
		if grant%3 != 0 && queuedPinned < pinnedCap {
			waiter, ok := queue.enterPinned("p", pinnedCap)
			if !ok {
				t.Fatal("pinned waiter rejected below the lane cap")
			}
			arrivedAt[waiter] = grant
			bound[waiter] = 2 * (queuedPinned + 1)
			live = append(live, waiter)
		}
		refill()
		got := grantNext(t, queue, "p", live)
		if got == nil {
			t.Fatal("no waiter took the freed seat")
		}
		if got.pinned() {
			pinnedGrants++
			pinnedServed++
			if waited := grant - arrivedAt[got] + 1; waited > bound[got] {
				t.Fatalf("pinned waiter took %d grants, bound %d", waited, bound[got])
			}
		} else {
			plainGrants++
		}
	}
	if pinnedServed == 0 || plainGrants < pinnedGrants {
		t.Fatalf("plaintext grants=%d pinned grants=%d, want plaintext at least half", plainGrants, pinnedGrants)
	}
	if pinnedGrants < 900 {
		t.Fatalf("pinned grants=%d of 2000, want close to half under saturation", pinnedGrants)
	}
}

// Sustained pinned load never starves plaintext: a plaintext waiter is
// served within two grants of reaching the head of its lane.
func TestSlotQueueSustainedPinnedLoadDoesNotStarvePlaintext(t *testing.T) {
	queue := newSlotQueue(4)
	var live []*slotWaiter
	for range 2 {
		waiter, _ := queue.enterPinned("p", 2)
		live = append(live, waiter)
	}
	plain, ok := queue.enter("p")
	if !ok {
		t.Fatal("plaintext waiter rejected")
	}
	live = append(live, plain)
	for grant := 0; ; grant++ {
		if grant >= 2 {
			t.Fatal("plaintext waiter not served within two grants")
		}
		got := grantNext(t, queue, "p", live)
		if got == plain {
			break
		}
		// Keep the pinned lane full.
		waiter, ok := queue.enterPinned("p", 2)
		if !ok {
			t.Fatal("pinned lane refill rejected")
		}
		live = append(live, waiter)
	}
}

// Each lane has its own cap: a full plaintext lane does not keep pinned
// waiters out, and pinned waiters never take plaintext positions.
func TestSlotQueueLanesHaveSeparateCaps(t *testing.T) {
	queue := newSlotQueue(2)
	for range 2 {
		if _, ok := queue.enter("p"); !ok {
			t.Fatal("plaintext waiter rejected below cap")
		}
	}
	if _, ok := queue.enter("p"); ok {
		t.Fatal("plaintext lane accepted past its cap")
	}
	if _, ok := queue.enterPinned("p", 1); !ok {
		t.Fatal("full plaintext lane kept the pinned waiter out")
	}
	if _, ok := queue.enterPinned("p", 1); ok {
		t.Fatal("pinned lane accepted past its cap")
	}

	other := newSlotQueue(2)
	for range 2 {
		if _, ok := other.enterPinned("p", 2); !ok {
			t.Fatal("pinned waiter rejected below cap")
		}
	}
	candidates := []poolQueueCandidate{{providerID: "p", slotsTotal: 1}}
	for range 2 {
		if _, ok := other.enterBest(candidates, nil); !ok {
			t.Fatal("pinned waiters took plaintext positions")
		}
	}
	if _, ok := other.enterBest(candidates, nil); ok {
		t.Fatal("plaintext lane accepted past its cap")
	}
}

func TestRelayBlindPinnedLaneCap(t *testing.T) {
	for _, tc := range []struct{ maxPending, slotsTotal, want int }{
		{1, 1, 1}, {4, 1, 2}, {4, 8, 4}, {4, 32, 16}, {0, 0, 1},
	} {
		if got := relayBlindPinnedLaneCap(tc.maxPending, tc.slotsTotal); got != tc.want {
			t.Fatalf("relayBlindPinnedLaneCap(%d, %d)=%d, want %d", tc.maxPending, tc.slotsTotal, got, tc.want)
		}
	}
}

func TestSlotQueueGrantCountTracksProgress(t *testing.T) {
	queue := newSlotQueue(4)
	pinned, _ := queue.enterPinned("p", 2)
	plain, _ := queue.enter("p")
	if queue.grantCount("p") != 0 {
		t.Fatal("grant count before any grant")
	}
	if grantNext(t, queue, "p", []*slotWaiter{pinned, plain}) != pinned || queue.grantCount("p") != 1 {
		t.Fatalf("grant count=%d after one grant", queue.grantCount("p"))
	}
	if grantNext(t, queue, "p", []*slotWaiter{plain}) != plain || queue.grantCount("p") != 0 {
		t.Fatalf("grant count=%d after the queue emptied, want reset", queue.grantCount("p"))
	}
}
