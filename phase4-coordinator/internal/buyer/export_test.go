package buyer

import "time"

// SlotQueueHasWaitersForTest reports whether a request is parked in the
// provider's slot queue, so a test can free a slot only after the request
// is actually waiting instead of guessing with a sleep.
func (s *Server) SlotQueueHasWaitersForTest(providerID string) bool {
	return s.slotQueue != nil && s.slotQueue.hasWaiters(providerID)
}

// SetNowForTest pins the server clock, so a test can place a deadline
// relative to a known clock reading instead of racing wall time.
func (s *Server) SetNowForTest(now func() time.Time) {
	s.now = now
}
