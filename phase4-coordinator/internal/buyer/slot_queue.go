package buyer

import "sync"

type slotQueue struct {
	mu         sync.Mutex
	maxPending int
	queues     map[string][]*slotWaiter
	reserved   map[string]int
}

type slotWaiter struct {
	providerID string
}

type poolQueueCandidate struct {
	providerID string
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
	q.mu.Lock()
	defer q.mu.Unlock()
	queue := q.queues[providerID]
	if len(queue) >= q.maxPending {
		return nil, false
	}
	waiter := &slotWaiter{providerID: providerID}
	q.queues[providerID] = append(queue, waiter)
	return waiter, true
}

func (q *slotQueue) enterBest(candidates []poolQueueCandidate, tried map[string]struct{}) (*slotWaiter, bool) {
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
		if queueLen >= q.maxPending {
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
	waiter := &slotWaiter{providerID: bestProviderID}
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

func (q *slotQueue) blocksProvider(providerID string, slotsFree int) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.queues[providerID])+q.reserved[providerID] >= slotsFree
}

func (q *slotQueue) reserveHead(waiter *slotWaiter, slotsFree int) bool {
	if waiter == nil {
		return false
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	queue := q.queues[waiter.providerID]
	if len(queue) == 0 || queue[0] != waiter {
		return false
	}
	if slotsFree-q.reserved[waiter.providerID] <= 0 {
		return false
	}
	q.reserved[waiter.providerID]++
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
