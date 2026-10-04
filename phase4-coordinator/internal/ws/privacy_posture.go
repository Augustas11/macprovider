package ws

import (
	"context"
	"encoding/json"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

// runPrivacyPostureLoop probes sessions that hold fresh privacy keys.
// Eligibility is entirely in the authority; this loop only delivers challenges.
func (s *Server) runPrivacyPostureLoop() {
	ticker := time.NewTicker(s.privacyAuthority.ChallengeInterval())
	defer ticker.Stop()
	for range ticker.C {
		s.runPrivacyPostureSweep()
	}
}

func (s *Server) runPrivacyPostureSweep() {
	if s == nil || s.privacyAuthority == nil || s.pool == nil {
		return
	}
	sessions, err := s.privacyAuthority.CandidateSessions(context.Background(), s.now())
	if err != nil {
		s.log.Warn().Err(err).Msg("privacy posture: candidate lookup failed")
		return
	}
	live := make(map[string]pool.Provider, len(sessions))
	for _, provider := range s.pool.Snapshot() {
		live[sessionKey(provider.ProviderID, provider.AssignedID)] = provider
	}
	for _, session := range sessions {
		provider, ok := live[sessionKey(session.ProviderID, session.AssignedSession)]
		if !ok {
			continue
		}
		s.schedulePrivacyPostureProbe(provider)
	}
}

func (s *Server) schedulePrivacyPostureProbe(provider pool.Provider) {
	if s == nil || s.privacyAuthority == nil {
		return
	}
	key := sessionKey(provider.ProviderID, provider.AssignedID)
	if _, loaded := s.privacyPostureInFlight.LoadOrStore(key, struct{}{}); loaded {
		return
	}
	go func() {
		defer s.privacyPostureInFlight.Delete(key)
		s.runPrivacyPostureProbe(provider)
	}()
}

// runPrivacyPostureProbe challenges one session. BeginChallenge runs only
// after the live session exists. Send and timeout failures clear eligibility
// without quarantine. The authority re-parses the original response bytes.
func (s *Server) runPrivacyPostureProbe(provider pool.Provider) {
	if s == nil || s.privacyAuthority == nil {
		return
	}
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return
	}
	now := s.now()
	nonce, issued, err := s.privacyAuthority.BeginChallenge(provider.ProviderID, provider.AssignedID, now)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Msg("privacy posture: challenge begin failed")
		return
	}
	raw, err := json.Marshal(PrivacyPostureChallenge{
		Type:         "privacy_posture_challenge",
		Version:      1,
		Nonce:        nonce,
		IssuedAtUnix: issued,
	})
	ch := make(chan []byte, 1)
	pendingKey := sessionKey(provider.ProviderID, provider.AssignedID)
	s.privacyPostureChans.Store(pendingKey, ch)
	defer s.privacyPostureChans.Delete(pendingKey)
	if err != nil {
		s.privacyAuthority.NoteChallengeTimeout(provider.ProviderID, provider.AssignedID)
		s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Msg("privacy posture: challenge marshal failed")
		return
	}
	if err := session.send(raw); err != nil {
		s.privacyAuthority.NoteChallengeTimeout(provider.ProviderID, provider.AssignedID)
		s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Msg("privacy posture: challenge send failed")
		return
	}
	timer := time.NewTimer(s.privacyAuthority.ResponseTimeout())
	defer timer.Stop()
	select {
	case payload := <-ch:
		if err := s.privacyAuthority.VerifyPosture(context.Background(), provider.ProviderID, provider.AssignedID, nonce, payload, provider.SEPublicKey, s.now()); err != nil {
			s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Msg("privacy posture: response rejected")
		}
	case <-timer.C:
		s.privacyAuthority.NoteChallengeTimeout(provider.ProviderID, provider.AssignedID)
		s.log.Warn().Str("provider_id", provider.ProviderID).Msg("privacy posture: response timed out")
	}
}

func (s *Server) handlePrivacyPostureResponse(providerID, assignedID string, payload []byte) {
	if len(payload) == 0 || len(payload) > relayblind.MaxPrivacyPostureResponseBytes {
		s.log.Warn().Str("provider_id", providerID).Msg("privacy posture: response size rejected")
		return
	}
	s.deliverPrivacyPostureResponse(providerID, assignedID, append([]byte(nil), payload...))
}

func (s *Server) deliverPrivacyPostureResponse(providerID, assignedID string, payload []byte) {
	v, ok := s.privacyPostureChans.Load(sessionKey(providerID, assignedID))
	if !ok {
		s.log.Debug().Str("provider_id", providerID).Msg("privacy posture: unexpected response")
		return
	}
	ch, ok := v.(chan []byte)
	if !ok {
		return
	}
	select {
	case ch <- payload:
	default:
	}
}

// acceptHeartbeatPrivacyKeys applies a heartbeat's privacy_key_records
// before session state changes. An absent field leaves records nil and is
// a no-op. An empty array revokes. Parse or state failures do not touch
// the authority, matching the gate that used to sit beside relay-blind
// key acceptance.
func (s *Server) acceptHeartbeatPrivacyKeys(providerID, assignedID string, payload []byte) {
	hb, _, _, err := ParseHeartbeat(payload)
	if err != nil {
		return
	}
	if !validState(pool.State(hb.Status)) {
		return
	}
	s.acceptPrivacyKeyRecords(providerID, assignedID, hb.PrivacyKeyRecords)
}

func (s *Server) acceptPrivacyKeyRecords(providerID, assignedID string, records []relayblind.PrivacyKeyRecord) {
	if s == nil || s.privacyAuthority == nil || records == nil {
		return
	}
	if err := s.privacyAuthority.AcceptPrivacyKeys(context.Background(), providerID, assignedID, records, s.now()); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("privacy key advertisement rejected")
		return
	}
	if len(records) == 0 {
		return
	}
	provider, ok := s.pool.Resolve(providerID, assignedID)
	if !ok {
		return
	}
	s.schedulePrivacyPostureProbe(provider)
}

func (s *Server) dropPrivacyPosture(providerID, assignedID string) {
	if s == nil || s.privacyAuthority == nil {
		return
	}
	s.privacyAuthority.DropSession(providerID, assignedID)
}
