package buyer

// SlotQueueHasWaitersForTest reports whether a request is parked in the
// provider's slot queue, so a test can free a slot only after the request
// is actually waiting instead of guessing with a sleep.
func (s *Server) SlotQueueHasWaitersForTest(providerID string) bool {
	return s.slotQueue != nil && s.slotQueue.hasWaiters(providerID)
}
