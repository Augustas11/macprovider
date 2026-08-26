package router

import "time"

// enforcePoolRejectionTimingFloor holds the response until the SPEC-043-R007
// active timing floor elapses. Call immediately before writing a pool-selection
// rejection so unknown/unauthorized/disabled/unavailable paths cannot be
// distinguished by response-commitment latency.
func (s *Server) enforcePoolRejectionTimingFloor(startedAt time.Time) {
	if s == nil || startedAt.IsZero() {
		return
	}
	floor := s.cfg.Features.TrustedPools.RejectionTimingFloor()
	if floor <= 0 {
		return
	}
	remaining := floor - s.now().Sub(startedAt)
	if remaining > 0 {
		time.Sleep(remaining)
	}
}
