package ws

import (
	"net"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	gobwas "github.com/gobwas/ws"
)

// AdmissionTransportSessionForTest is an opaque handle to the exact accepted
// WS session used by cross-package buyer composition tests.
type AdmissionTransportSessionForTest struct {
	session *providerSession
}

func CaptureAdmissionTransportSessionForTest(s *Server, p pool.Provider) (*AdmissionTransportSessionForTest, bool) {
	ps, ok := s.storedSessionFor(p.ProviderID, p.AssignedID)
	if !ok || ps.providerID != p.ProviderID || ps.assignedID != p.AssignedID {
		return nil, false
	}
	return &AdmissionTransportSessionForTest{session: ps}, true
}

type admissionCapturedTimers struct {
	mu     sync.Mutex
	timers []func()
}

func (c *admissionCapturedTimers) capture(_ time.Duration, fn func()) {
	c.mu.Lock()
	c.timers = append(c.timers, fn)
	c.mu.Unlock()
}

func (c *admissionCapturedTimers) requireArmed(t *testing.T, producer string) {
	t.Helper()
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.timers) == 0 {
		t.Fatalf("%s did not arm a held timer", producer)
	}
}

func (c *admissionCapturedTimers) fireAll() {
	for {
		c.mu.Lock()
		if len(c.timers) == 0 {
			c.mu.Unlock()
			return
		}
		fn := c.timers[0]
		c.timers = c.timers[1:]
		c.mu.Unlock()
		fn()
	}
}

// TriggerCloseSessionHeldForTest runs the real graceful producer while holding
// its captured hard-close timer for the caller-controlled interleaving.
func TriggerCloseSessionHeldForTest(t *testing.T, s *Server, p pool.Provider) func() {
	t.Helper()
	ps, ok := s.storedSessionFor(p.ProviderID, p.AssignedID)
	if !ok {
		t.Fatal("accepted session missing")
	}
	timers := &admissionCapturedTimers{}
	s.modelAdmissionAfterFunc = timers.capture
	s.closeSession(ps, gobwas.StatusNormalClosure, "buyer composition")
	timers.requireArmed(t, "closeSession")
	if ps.isOpen() {
		t.Fatal("closeSession did not publish closing")
	}
	return timers.fireAll
}

// TriggerTrustClosureHeldForTest runs the real scheduled hardware-trust
// producer. A ready revival deliberately exercises monotonic closing.
func TriggerTrustClosureHeldForTest(t *testing.T, s *Server, p pool.Provider, reviveReady bool) func() {
	t.Helper()
	ps, ok := s.storedSessionFor(p.ProviderID, p.AssignedID)
	if !ok {
		t.Fatal("accepted session missing")
	}
	timers := &admissionCapturedTimers{}
	s.modelAdmissionAfterFunc = timers.capture
	s.disconnectProviderForTrustRevocation(p.ProviderID, "buyer-composition")
	timers.requireArmed(t, "trust closure")
	if reviveReady {
		s.pool.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: time.Now()})
	}
	if ps.isOpen() {
		t.Fatal("scheduled trust closure did not publish closing")
	}
	return timers.fireAll
}

// ReplaceAdmissionTransportSessionForTest installs a real new session while an
// old captured timer remains available to the caller.
func ReplaceAdmissionTransportSessionForTest(t *testing.T, s *Server, p pool.Provider) pool.Provider {
	t.Helper()
	conn, peer := net.Pipe()
	t.Cleanup(func() { _ = peer.Close() })
	replacement := p
	replacement.AssignedID = p.AssignedID + "-replacement"
	replacement.State = pool.StateReady
	ps, refusal := s.registerProviderSession(conn, &replacement)
	if ps == nil || refusal != pool.RegisterRefusalNone {
		_ = conn.Close()
		t.Fatalf("replacement registration refused: %q", refusal)
	}
	t.Cleanup(func() {
		ps.closeTransport()
		ps.close()
		s.deleteProviderSession(sessionKey(replacement.ProviderID, replacement.AssignedID))
	})
	resolved, ok := s.pool.Resolve(replacement.ProviderID, replacement.AssignedID)
	if !ok {
		t.Fatal("replacement registry session missing")
	}
	return resolved
}

// SetAdmissionTransportStateForTest applies one exact callback-table state to a
// fresh accepted-session fixture.
func SetAdmissionTransportStateForTest(t *testing.T, s *Server, p pool.Provider, state string) {
	t.Helper()
	ps, ok := s.storedSessionFor(p.ProviderID, p.AssignedID)
	if !ok {
		t.Fatal("accepted session missing")
	}
	switch state {
	case "exact":
	case "absent-map":
		s.deleteProviderSession(sessionKey(p.ProviderID, p.AssignedID))
	case "closing":
		ps.beginClosing()
	case "terminal-closed":
		ps.close()
	default:
		t.Fatalf("unknown admission transport state %q", state)
	}
}
