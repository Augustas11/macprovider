package ws

import (
	"context"
	"encoding/json"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

// PrivacyKeyRotationChallenge is the SPEC-049 §4.12 rotation nonce.
type PrivacyKeyRotationChallenge struct {
	Type         string `json:"type"`
	Version      int    `json:"version"`
	Nonce        string `json:"nonce"`
	IssuedAtUnix int64  `json:"issued_at_unix"`
}

// PrivacyKeyRotationResult answers a rotation request. Nonce is "" when no
// challenge was issued.
type PrivacyKeyRotationResult struct {
	Type    string `json:"type"`
	Version int    `json:"version"`
	Nonce   string `json:"nonce"`
	Status  string `json:"status"`
	Reason  string `json:"reason"`
}

// handlePrivacyKeyRotationRequest starts one SPEC-049-R031 rotation exchange
// for the session. A coordinator without the privacy class ignores it, so
// the provider keeps its enrolled key.
func (s *Server) handlePrivacyKeyRotationRequest(providerID, assignedID string, payload []byte) {
	if s == nil || s.privacyAuthority == nil {
		return
	}
	var request struct {
		Type    string `json:"type"`
		Version int    `json:"version"`
	}
	if err := json.Unmarshal(payload, &request); err != nil || request.Version != 1 {
		return
	}
	provider, ok := s.pool.Resolve(providerID, assignedID)
	if !ok {
		return
	}
	key := sessionKey(providerID, assignedID)
	if _, loaded := s.privacyRotationInFlight.LoadOrStore(key, struct{}{}); loaded {
		return
	}
	go func() {
		defer s.privacyRotationInFlight.Delete(key)
		s.runPrivacyKeyRotation(provider)
	}()
}

// runPrivacyKeyRotation issues the nonce, waits for the signed rotation, and
// verifies it inside the provider section, where session replacement is
// serialized, then answers with the result.
func (s *Server) runPrivacyKeyRotation(provider pool.Provider) {
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return
	}
	reply := func(nonce, reason string) {
		status := "rejected"
		if reason == relayblind.RotationAccepted {
			status = "accepted"
		}
		raw, err := json.Marshal(PrivacyKeyRotationResult{Type: "privacy_key_rotation_result", Version: 1, Nonce: nonce, Status: status, Reason: reason})
		if err == nil {
			_ = session.send(raw)
		}
	}
	var (
		nonce  string
		issued int64
		reason string
	)
	s.withProviderSection(provider.ProviderID, func(*providerSection) {
		if _, live := s.pool.Resolve(provider.ProviderID, provider.AssignedID); !live {
			reason = relayblind.RotationStale
			return
		}
		nonce, issued, reason = s.privacyAuthority.BeginRotationChallenge(context.Background(), provider.ProviderID, provider.AssignedID, s.now())
	})
	if reason != "" {
		reply("", reason)
		return
	}
	key := sessionKey(provider.ProviderID, provider.AssignedID)
	ch := make(chan []byte, 1)
	s.privacyRotationChans.Store(key, ch)
	defer s.privacyRotationChans.Delete(key)
	raw, err := json.Marshal(PrivacyKeyRotationChallenge{Type: "privacy_key_rotation_challenge", Version: 1, Nonce: nonce, IssuedAtUnix: issued})
	if err != nil || session.send(raw) != nil {
		s.privacyAuthority.NoteRotationTimeout(provider.ProviderID, provider.AssignedID)
		return
	}
	timer := s.newPrivacyRotationTimer()
	defer timer.Stop()
	select {
	case payload := <-ch:
		var verifyErr error
		s.withProviderSection(provider.ProviderID, func(*providerSection) {
			if _, live := s.pool.Resolve(provider.ProviderID, provider.AssignedID); !live {
				s.privacyAuthority.NoteRotationTimeout(provider.ProviderID, provider.AssignedID)
				reason = relayblind.RotationStale
				return
			}
			reason, verifyErr = s.privacyAuthority.VerifyRotation(context.Background(), provider.ProviderID, provider.AssignedID, nonce, payload, provider.SEPublicKey, s.now())
		})
		if verifyErr != nil {
			s.log.Warn().Err(verifyErr).Str("provider_id", provider.ProviderID).Msg("privacy key rotation rejected")
		} else {
			s.privacyAdvertised.Delete(key)
			s.log.Info().Str("provider_id", provider.ProviderID).Msg("privacy key rotation accepted")
		}
		reply(nonce, reason)
	case <-timer.C:
		s.privacyAuthority.NoteRotationTimeout(provider.ProviderID, provider.AssignedID)
		s.log.Warn().Str("provider_id", provider.ProviderID).Msg("privacy key rotation timed out")
		reply(nonce, relayblind.RotationStale)
	}
}

func (s *Server) handlePrivacyKeyRotation(providerID, assignedID string, payload []byte) {
	if s == nil || s.privacyAuthority == nil || len(payload) == 0 || len(payload) > relayblind.MaxPrivacyKeyRotationBytes {
		return
	}
	v, ok := s.privacyRotationChans.Load(sessionKey(providerID, assignedID))
	if !ok {
		return
	}
	ch, ok := v.(chan []byte)
	if !ok {
		return
	}
	select {
	case ch <- append([]byte(nil), payload...):
	default:
	}
}

func (s *Server) newPrivacyRotationTimer() *time.Timer {
	return time.NewTimer(s.privacyAuthority.ResponseTimeout())
}
