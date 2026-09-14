package ws

import (
	"bytes"
	"crypto/ed25519"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"testing"
	"time"
)

// WSAdmissionMutationForTest shares real owner operations with the signed buyer matrix.
func WSAdmissionMutationForTest(t *testing.T, s *Server, p pool.Provider, mutation string) (func(), func() bool) {
	r := s.pool
	var ps *providerSession
	entered := make(chan struct{})
	mutate := func() {
		if ps == nil {
			ps, _ = s.storedSessionFor(p.ProviderID, p.AssignedID)
		}
		switch mutation {
		case "replacement":
			q := p
			q.AssignedID = "replacement"
			if _, ok := r.Register(&q, ps.conn); !ok {
				t.Error("real registration mutation refused")
			}
		case "registry-removal":
			r.RemoveIfSession(p.ProviderID, p.AssignedID)
		case "session-removal":
			s.deleteProviderSession(sessionKey(p.ProviderID, p.AssignedID))
		case "closing":
			close(entered)
			ps.beginClosing()
		case "not-ready":
			r.MarkState(p.ProviderID, p.AssignedID, pool.StateUnavailable)
		case "pending-key", "receipt-key":
			q := p
			q.ReceiptPubkey = bytes.Repeat([]byte{2}, ed25519.PublicKeySize)
			if _, ok := r.Register(&q, ps.conn); !ok {
				t.Error("real registration mutation refused")
			}
			if mutation == "receipt-key" {
				r.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: time.Now()})
			}
		case "benchmark":
			r.SetBenchmarkQuarantine(p.ProviderID, p.AssignedID, true)
		case "ceiling":
			r.SetAdmissionCeilingExcluded(p.ProviderID, p.AssignedID, true)
		case "stale":
			r.SetAdmissionEvidenceStale(p.ProviderID, p.AssignedID, true)
		case "sandboxed":
			r.SetAdmissionSandboxed(p.ProviderID, p.AssignedID, true)
		case "sanction":
			r.LoadCanarySanctions([]pool.CanarySanctionSnapshot{{ProviderID: p.ProviderID, FailCount: 1}})
		case "resolver":
			_ = s.SetModelAdmissionAuthority(nil)
		}
	}
	pending := func() bool {
		switch mutation {
		case "closing":
			select {
			case <-entered:
				return true
			default:
				return false
			}
		case "session-removal":
			if !s.sessionPublicationMu.TryRLock() {
				return true
			}
			s.sessionPublicationMu.RUnlock()
			return false
		case "resolver":
			if !s.modelAdmissionAuthorityMu.TryRLock() {
				return true
			}
			s.modelAdmissionAuthorityMu.RUnlock()
			return false
		default:
			_, _, release, ok := r.TryPinModelAdmissionProvider(p.ProviderID, p.AssignedID)
			if !ok {
				return true
			}
			release()
			return false
		}
	}
	return mutate, pending
}
