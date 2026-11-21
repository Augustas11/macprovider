package stats

import "time"

// WithNowForTest pins the mux clock so tests that compare two responses
// (GET vs HEAD) are not split by a wall-clock second boundary.
func (m *Mux) WithNowForTest(now func() time.Time) *Mux {
	m.h.Now = now
	return m
}
