package buyer

import "time"

// SetModelAdmissionClockForTest is available only in the buyer test binary.
// Call between synchronous resolver/guard calls, never during concurrent work.
func SetModelAdmissionClockForTest(s *Server, at time.Time) {
	s.now = func() time.Time { return at }
}
