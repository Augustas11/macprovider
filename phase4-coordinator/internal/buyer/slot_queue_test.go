package buyer

import "testing"

func TestSlotQueueEnforcesCapAndFIFOHead(t *testing.T) {
	queue := newSlotQueue(2)
	first, ok := queue.enter("provider/session")
	if !ok {
		t.Fatal("first waiter rejected")
	}
	second, ok := queue.enter("provider/session")
	if !ok {
		t.Fatal("second waiter rejected")
	}
	if _, ok := queue.enter("provider/session"); ok {
		t.Fatal("third waiter accepted past cap")
	}
	if !queue.head(first) {
		t.Fatal("first waiter should be FIFO head")
	}
	if queue.head(second) {
		t.Fatal("second waiter should not be FIFO head before first leaves")
	}
	queue.leave(first)
	if !queue.head(second) {
		t.Fatal("second waiter should become FIFO head after first leaves")
	}
	queue.leave(second)
	if next, ok := queue.enter("provider/session"); !ok || !queue.head(next) {
		t.Fatalf("queue did not accept a fresh waiter after drain: ok=%v", ok)
	}
}

func TestSlotQueueBlocksOnlyWhenQueuedDemandConsumesFreeSlots(t *testing.T) {
	queue := newSlotQueue(4)
	first, ok := queue.enter("provider")
	if !ok {
		t.Fatal("first waiter rejected")
	}
	second, ok := queue.enter("provider")
	if !ok {
		t.Fatal("second waiter rejected")
	}

	if !queue.blocksProvider("provider", 2) {
		t.Fatal("provider should block direct routing when two waiters consume two free slots")
	}
	if queue.blocksProvider("provider", 3) {
		t.Fatal("provider should allow direct routing when free slots exceed queued demand")
	}
	if !queue.reserveHead(first, 3) {
		t.Fatal("first waiter reservation rejected")
	}
	queue.leave(first)
	if !queue.blocksProvider("provider", 2) {
		t.Fatal("provider should block when one reserved plus one queued consume two free slots")
	}
	if queue.blocksProvider("provider", 3) {
		t.Fatal("provider should allow excess free capacity after reservation and queued demand")
	}
	queue.releaseReservation("provider")
	queue.leave(second)
}
