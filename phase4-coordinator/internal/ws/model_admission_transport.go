package ws

import (
	"net"
	"time"
)

// Closing invalidates admission without shutting down the graceful frame writer.
func (ps *providerSession) beginClosingLocked() {
	if !ps.closing {
		ps.closing = true
		if ps.closingCh != nil {
			close(ps.closingCh)
		}
	}
}

func (ps *providerSession) beginClosing() {
	if ps == nil {
		return
	}
	if ps.beforeClosing != nil {
		ps.beforeClosing()
	}
	ps.writeMu.Lock()
	ps.beginClosingLocked()
	ps.writeMu.Unlock()
}

func (ps *providerSession) closeTransport() {
	ps.beginClosing()
	if ps.conn != nil {
		_ = ps.conn.Close()
	}
}

func (s *Server) storeProviderSession(key, value any) {
	s.sessionPublicationMu.Lock()
	s.sessions.Store(key, value)
	s.sessionPublicationMu.Unlock()
}

func (s *Server) deleteProviderSession(key any) {
	s.sessionPublicationMu.Lock()
	s.sessions.Delete(key)
	s.sessionPublicationMu.Unlock()
}

// ModelAdmissionSessionAvailable observes this exact assigned session. It does
// not retain locks through routing or substitute a same-provider replacement.
func (s *Server) ModelAdmissionSessionAvailable(providerID, assignedID string) bool {
	if providerID == "" || assignedID == "" {
		return false
	}
	if _, ok := s.pool.Resolve(providerID, assignedID); !ok {
		return false
	}
	ps, ok := s.storedSessionFor(providerID, assignedID)
	return ok && ps.providerID == providerID && ps.assignedID == assignedID && ps.isOpen()
}

// CloseModelAdmissionTransport publishes invalidation before any socket IO.
func (s *Server) CloseModelAdmissionTransport(providerID, assignedID, _ string) error {
	if providerID == "" || assignedID == "" {
		return ErrRelayClosed
	}
	ps, ok := s.storedSessionFor(providerID, assignedID)
	if !ok || ps.providerID != providerID || ps.assignedID != assignedID {
		return ErrRelayClosed
	}
	ps.closeTransport()
	return nil
}

// Captures post-registration ack failures even when handshake return IDs are
// empty. Registration has finished before handleConn's deferred close runs.
func (s *Server) closeConnection(conn net.Conn) {
	if value, ok := s.registeredSessions.LoadAndDelete(conn); ok {
		value.(*providerSession).beginClosing()
	}
	_ = conn.Close()
}

func (s *Server) scheduleSessionClosure(ps *providerSession, delay time.Duration, closeFn func()) {
	ps.beginClosing()
	if s.modelAdmissionAfterFunc != nil {
		s.modelAdmissionAfterFunc(delay, closeFn)
		return
	}
	time.AfterFunc(delay, closeFn)
}

func (s *Server) heartbeatTicks(delay time.Duration) (<-chan time.Time, func()) {
	if s.modelAdmissionHeartbeatTicks != nil {
		return s.modelAdmissionHeartbeatTicks(delay)
	}
	ticker := time.NewTicker(delay)
	return ticker.C, ticker.Stop
}

func (ps *providerSession) writeProbeTimer(delay time.Duration) (<-chan time.Time, func()) {
	if ps.probeTimer != nil {
		return ps.probeTimer(delay)
	}
	timer := time.NewTimer(delay)
	return timer.C, func() { timer.Stop() }
}
