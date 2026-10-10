package buyer

import "sync"

// slotQueue holds two lanes per provider in one slice: plaintext waiters
// (standard and reservation overflow) and pinned waiters (relay-blind and
// privacy-class reservations, which cannot move to another provider). Each
// lane is FIFO. When both lanes wait, queue grants alternate between them
// (SPEC-049-R029), so neither class can hold more than every other freed seat
// while the other waits.
type slotQueue struct {
	mu         sync.Mutex
	maxPending int
	queues     map[string][]*slotWaiter
	reserved   map[string]int
	// lastPinned is true when the provider's last queue grant went to the
	// pinned lane. It is dropped when the provider's queue empties.
	lastPinned map[string]bool
	// grants counts queue grants per provider while it has waiters, so a
	// pinned waiter can tell a moving queue from a stalled one.
	grants map[string]uint64
}

type slotWaiterKind int

const (
	slotWaiterStandard slotWaiterKind = iota
	slotWaiterReservationOverflow
	// slotWaiterPinned is a relay-blind or privacy-class reservation bound to
	// one provider session.
	slotWaiterPinned
)

type slotWaiter struct {
	providerID string
	kind       slotWaiterKind
}

type poolQueueCandidate struct {
	providerID string
	// slotsTotal raises this provider's waiter cap to its advertised seat
	// count, so a node serving more seats than maxPending can hold one
	// waiter per seat while a completion frees capacity (#1906).
	slotsTotal int
}

func newSlotQueue(maxPending int) *slotQueue {
	if maxPending <= 0 {
		maxPending = 1
	}
	return &slotQueue{
		maxPending: maxPending,
		queues:     map[string][]*slotWaiter{},
		reserved:   map[string]int{},
		lastPinned: map[string]bool{},
		grants:     map[string]uint64{},
	}
}

func (w *slotWaiter) pinned() bool {
	return w.kind == slotWaiterPinned
}

// laneLenLocked counts the waiters on providerID in the lane of kind.
func (q *slotQueue) laneLenLocked(providerID string, kind slotWaiterKind) int {
	pinned := kind == slotWaiterPinned
	n := 0
	for _, waiter := range q.queues[providerID] {
		if waiter.pinned() == pinned {
			n++
		}
	}
	return n
}

// nextLocked is the waiter the next free seat on providerID belongs to: the
// head of the only waiting lane, or, when both lanes wait, the head of the
// lane that did not take the previous grant.
func (q *slotQueue) nextLocked(providerID string) *slotWaiter {
	var standard, pinned *slotWaiter
	for _, waiter := range q.queues[providerID] {
		if waiter.pinned() {
			if pinned == nil {
				pinned = waiter
			}
		} else if standard == nil {
			standard = waiter
		}
		if standard != nil && pinned != nil {
			break
		}
	}
	switch {
	case pinned == nil:
		return standard
	case standard == nil:
		return pinned
	case q.lastPinned[providerID]:
		return standard
	default:
		return pinned
	}
}

// removeLocked drops waiter from its provider's queue and the provider's
// lane state once the queue is empty.
func (q *slotQueue) removeLocked(waiter *slotWaiter) {
	queue := q.queues[waiter.providerID]
	for i, queued := range queue {
		if queued != waiter {
			continue
		}
		copy(queue[i:], queue[i+1:])
		queue = queue[:len(queue)-1]
		if len(queue) == 0 {
			delete(q.queues, waiter.providerID)
			delete(q.lastPinned, waiter.providerID)
			delete(q.grants, waiter.providerID)
			return
		}
		q.queues[waiter.providerID] = queue
		return
	}
}

// enterPinned queues a pinned waiter on providerID if the pinned lane holds
// fewer than limit waiters. The plaintext lane's cap is unaffected.
func (q *slotQueue) enterPinned(providerID string, limit int) (*slotWaiter, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if providerID == "" || q.laneLenLocked(providerID, slotWaiterPinned) >= limit {
		return nil, false
	}
	waiter := &slotWaiter{providerID: providerID, kind: slotWaiterPinned}
	q.queues[providerID] = append(q.queues[providerID], waiter)
	return waiter, true
}

// grantCount is the number of queue grants on providerID since its queue
// was last empty.
func (q *slotQueue) grantCount(providerID string) uint64 {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.grants[providerID]
}

func (q *slotQueue) enter(providerID string) (*slotWaiter, bool) {
	return q.enterWithKind(providerID, slotWaiterStandard)
}

func (q *slotQueue) enterWithKind(providerID string, kind slotWaiterKind) (*slotWaiter, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.laneLenLocked(providerID, kind) >= q.maxPending {
		return nil, false
	}
	waiter := &slotWaiter{providerID: providerID, kind: kind}
	q.queues[providerID] = append(q.queues[providerID], waiter)
	return waiter, true
}

func (q *slotQueue) enterBest(candidates []poolQueueCandidate, tried map[string]struct{}) (*slotWaiter, bool) {
	return q.enterBestWithKind(candidates, tried, slotWaiterStandard)
}

func (q *slotQueue) enterBestWithKind(candidates []poolQueueCandidate, tried map[string]struct{}, kind slotWaiterKind) (*slotWaiter, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	bestProviderID := ""
	bestLen := 0
	for _, candidate := range candidates {
		providerID := candidate.providerID
		if _, skip := tried[providerID]; skip {
			continue
		}
		queueLen := len(q.queues[providerID])
		maxPending := q.maxPending
		if candidate.slotsTotal > maxPending {
			maxPending = candidate.slotsTotal
		}
		// The cap counts this lane only; pinned waiters never take
		// plaintext positions. queueLen still counts both lanes, so the
		// shortest total queue wins.
		if q.laneLenLocked(providerID, kind) >= maxPending {
			continue
		}
		if bestProviderID == "" || queueLen < bestLen {
			bestProviderID = providerID
			bestLen = queueLen
		}
	}
	if bestProviderID == "" {
		return nil, false
	}
	waiter := &slotWaiter{providerID: bestProviderID, kind: kind}
	q.queues[bestProviderID] = append(q.queues[bestProviderID], waiter)
	return waiter, true
}

func (q *slotQueue) leave(waiter *slotWaiter) {
	if waiter == nil {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.removeLocked(waiter)
}

func (q *slotQueue) head(waiter *slotWaiter) bool {
	if waiter == nil {
		return false
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.nextLocked(waiter.providerID) == waiter
}

// blocksProvider, reserveProvider and reserveHead read the provider's
// slots_free through slotsFree while holding the queue lock (lock order:
// queue, then pool), so a check or reservation never acts on a seat count
// that releaseReservationAfter changed after the caller's snapshot (#1906).
func (q *slotQueue) blocksProvider(providerID string, slotsFree func() int) bool {
	return q.blocksProviderWith(providerID, slotsFree, 0)
}

// blocksProviderWith is blocksProvider with extra seats of demand the queue
// does not hold (relay-blind reservations not yet dispatched).
func (q *slotQueue) blocksProviderWith(providerID string, slotsFree func() int, extra int) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.queues[providerID])+q.reserved[providerID]+extra >= slotsFree()
}

func (q *slotQueue) hasWaiters(providerID string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.queues[providerID]) > 0
}

// hasStandardWaiters reports waiters admitted during a zero-slot
// observation: standard and pinned waiters, not reservation overflow. A
// pinned waiter was standard before the lanes split, so plaintext still
// joins a queue that is draining pinned waiters.
func (q *slotQueue) hasStandardWaiters(providerID string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, waiter := range q.queues[providerID] {
		if waiter.kind != slotWaiterReservationOverflow {
			return true
		}
	}
	return false
}

// claims is the coordinator-local demand on providerID: queued waiters plus
// seat reservations.
func (q *slotQueue) claims(providerID string) int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.queues[providerID]) + q.reserved[providerID]
}

func (q *slotQueue) reserveProvider(providerID string, slotsFree func() int) bool {
	reserved, _ := q.reserveProviderLive(providerID, slotsFree)
	return reserved
}

// reserveProviderLive is reserveProvider with slots_free read under the
// queue lock, so the check and the reservation see one consistent count with
// releaseReservationAfter. busy reports a failed reservation whose live count
// had no free seat at all (full or safety hold), as opposed to free seats
// already claimed by reservations and waiters.
func (q *slotQueue) reserveProviderLive(providerID string, slotsFree func() int) (reserved, busy bool) {
	if providerID == "" {
		return false, false
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	free := slotsFree()
	if free <= 0 {
		return false, true
	}
	if len(q.queues[providerID])+q.reserved[providerID] >= free {
		return false, false
	}
	q.reserved[providerID]++
	return true, false
}

func (q *slotQueue) reserveHead(waiter *slotWaiter, slotsFree func() int) bool {
	if waiter == nil {
		return false
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.nextLocked(waiter.providerID) != waiter {
		return false
	}
	if slotsFree()-q.reserved[waiter.providerID] <= 0 {
		return false
	}
	q.reserved[waiter.providerID]++
	q.lastPinned[waiter.providerID] = waiter.pinned()
	q.grants[waiter.providerID]++
	// Leave the queue in the same critical section: a waiter counted as both
	// queued demand and a reservation reads as overflow to sibling selectors.
	q.removeLocked(waiter)
	return true
}

func (q *slotQueue) releaseReservation(providerID string) {
	if providerID == "" {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.reserved[providerID] <= 1 {
		delete(q.reserved, providerID)
		return
	}
	q.reserved[providerID]--
}

// releaseReservationAfter runs consume and then drops one reservation for
// providerID while holding the queue lock. Selectors read slots_free from the
// pool and the reservation count from here; serializing the pair against the
// queue lock keeps an accepted chat from being counted twice in between.
// consume receives the number of other reservations still held on
// providerID.
func (q *slotQueue) releaseReservationAfter(providerID string, consume func(otherReserved int)) {
	q.mu.Lock()
	defer q.mu.Unlock()
	otherReserved := 0
	if providerID != "" && q.reserved[providerID] > 1 {
		otherReserved = q.reserved[providerID] - 1
	}
	consume(otherReserved)
	if providerID == "" {
		return
	}
	if q.reserved[providerID] <= 1 {
		delete(q.reserved, providerID)
		return
	}
	q.reserved[providerID]--
}
