package buyer

import "sync"

type slotQueue struct {
	mu         sync.Mutex
	maxPending int
	queues     map[string][]*slotWaiter
	reserved   map[string]int
}

type slotWaiterKind int

const (
	slotWaiterStandard slotWaiterKind = iota
	slotWaiterReservationOverflow
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
	}
}

func (q *slotQueue) enter(providerID string) (*slotWaiter, bool) {
	return q.enterWithKind(providerID, slotWaiterStandard)
}

func (q *slotQueue) enterWithKind(providerID string, kind slotWaiterKind) (*slotWaiter, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	queue := q.queues[providerID]
	if len(queue) >= q.maxPending {
		return nil, false
	}
	waiter := &slotWaiter{providerID: providerID, kind: kind}
	q.queues[providerID] = append(queue, waiter)
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
		if queueLen >= maxPending {
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
	queue := q.queues[waiter.providerID]
	for i, queued := range queue {
		if queued != waiter {
			continue
		}
		copy(queue[i:], queue[i+1:])
		queue = queue[:len(queue)-1]
		if len(queue) == 0 {
			delete(q.queues, waiter.providerID)
			return
		}
		q.queues[waiter.providerID] = queue
		return
	}
}

func (q *slotQueue) head(waiter *slotWaiter) bool {
	if waiter == nil {
		return false
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	queue := q.queues[waiter.providerID]
	return len(queue) > 0 && queue[0] == waiter
}

// blocksProvider, reserveProvider and reserveHead read the provider's
// slots_free through slotsFree while holding the queue lock (lock order:
// queue, then pool), so a check or reservation never acts on a seat count
// that releaseReservationAfter changed after the caller's snapshot (#1906).
func (q *slotQueue) blocksProvider(providerID string, slotsFree func() int) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.queues[providerID])+q.reserved[providerID] >= slotsFree()
}

func (q *slotQueue) hasWaiters(providerID string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.queues[providerID]) > 0
}

func (q *slotQueue) hasStandardWaiters(providerID string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, waiter := range q.queues[providerID] {
		if waiter.kind == slotWaiterStandard {
			return true
		}
	}
	return false
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
	queue := q.queues[waiter.providerID]
	if len(queue) == 0 || queue[0] != waiter {
		return false
	}
	if slotsFree()-q.reserved[waiter.providerID] <= 0 {
		return false
	}
	q.reserved[waiter.providerID]++
	// Leave the queue in the same critical section: a waiter counted as both
	// queued demand and a reservation reads as overflow to sibling selectors.
	copy(queue, queue[1:])
	queue = queue[:len(queue)-1]
	if len(queue) == 0 {
		delete(q.queues, waiter.providerID)
	} else {
		q.queues[waiter.providerID] = queue
	}
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
func (q *slotQueue) releaseReservationAfter(providerID string, consume func()) {
	q.mu.Lock()
	defer q.mu.Unlock()
	consume()
	if providerID == "" {
		return
	}
	if q.reserved[providerID] <= 1 {
		delete(q.reserved, providerID)
		return
	}
	q.reserved[providerID]--
}
