package ws

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

var errPrivacySessionReplaced = errors.New("privacy posture: session replaced before verification")

// runPrivacyPostureLoop probes sessions that hold fresh privacy keys.
// Eligibility is entirely in the authority; this loop only delivers challenges.
func (s *Server) runPrivacyPostureLoop() {
	ticker := time.NewTicker(s.privacyAuthority.ChallengeInterval())
	defer ticker.Stop()
	lastRelease := ""
	for range ticker.C {
		// SPEC-049-R027: release-derived approvals reload on the challenge
		// cadence. A change in the loaded state is logged by file name only.
		load := s.privacyAuthority.RefreshReleaseIdentities()
		if load.Configured {
			state := fmt.Sprintf("%d|%s|%v", load.Identities, strings.Join(load.Rejected, ","), load.Err)
			if state != lastRelease {
				lastRelease = state
				event := s.log.Info()
				if load.Err != nil || len(load.Rejected) > 0 {
					event = s.log.Warn().Err(load.Err).Strs("rejected_files", load.Rejected)
				}
				event.Int("approved_identities", load.Identities).Msg("privacy class release-derived code identities loaded")
			}
		}
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
	if s.privacyPostureChallengeSent != nil {
		s.privacyPostureChallengeSent()
	}
	timer := time.NewTimer(s.privacyAuthority.ResponseTimeout())
	defer timer.Stop()
	select {
	case payload := <-ch:
		// Session replacement holds the provider section, so verifying (and
		// possibly enrolling) inside it with a current-session check means a
		// replaced session can never write an enrollment (SPEC-049-R025).
		var err error
		s.withProviderSection(provider.ProviderID, func(*providerSection) {
			if _, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID); !ok {
				s.privacyAuthority.NoteChallengeTimeout(provider.ProviderID, provider.AssignedID)
				err = errPrivacySessionReplaced
				return
			}
			err = s.privacyAuthority.VerifyPosture(context.Background(), provider.ProviderID, provider.AssignedID, nonce, payload, provider.SEPublicKey, s.now())
		})
		if err != nil {
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
// key acceptance. Re-advertising an unchanged key set does not challenge:
// runPrivacyPostureLoop is the SPEC-049-R005 challenge cadence.
func (s *Server) acceptHeartbeatPrivacyKeys(providerID, assignedID string, payload []byte) {
	hb, _, _, err := ParseHeartbeat(payload)
	if err != nil {
		return
	}
	if !validState(pool.State(hb.Status)) {
		return
	}
	s.acceptPrivacyKeys(providerID, assignedID, hb.PrivacyKeyRecords, hb.PrivacyEnrollment, false)
}

// acceptPrivacyKeyRecords is the handshake path: accepted keys are always
// challenged once, right away.
func (s *Server) acceptPrivacyKeyRecords(providerID, assignedID string, records []relayblind.PrivacyKeyRecord, claim *relayblind.PrivacyEnrollmentClaim) {
	s.acceptPrivacyKeys(providerID, assignedID, records, claim, true)
}

func (s *Server) acceptPrivacyKeys(providerID, assignedID string, records []relayblind.PrivacyKeyRecord, claim *relayblind.PrivacyEnrollmentClaim, alwaysProbe bool) {
	if s == nil || s.privacyAuthority == nil || records == nil {
		return
	}
	key := sessionKey(providerID, assignedID)
	// AcceptPrivacyKeys revokes omitted keys provider-wide, so a replaced
	// session must not reach it. Session replacement holds the provider
	// section, so checking the current session inside it is race-free.
	var (
		provider pool.Provider
		accepted bool
	)
	s.withProviderSection(providerID, func(*providerSection) {
		current, ok := s.pool.Resolve(providerID, assignedID)
		if !ok {
			return
		}
		if err := s.privacyAuthority.AcceptPrivacyKeysWithClaim(context.Background(), providerID, assignedID, records, claim, s.now()); err != nil {
			s.privacyAdvertised.Delete(key)
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("privacy key advertisement rejected")
			return
		}
		provider, accepted = current, true
	})
	if !accepted {
		return
	}
	if len(records) == 0 {
		s.privacyAdvertised.Delete(key)
		return
	}
	set := privacyKeyDigestSet(records)
	previous, seen := s.privacyAdvertised.Swap(key, set)
	if !alwaysProbe && seen && previous == set {
		return
	}
	s.schedulePrivacyPostureProbe(provider)
}

// privacyKeyDigestSet identifies an advertised key set; a new or rotated
// record changes its key record digest.
func privacyKeyDigestSet(records []relayblind.PrivacyKeyRecord) string {
	digests := make([]string, 0, len(records))
	for _, record := range records {
		digests = append(digests, record.KeyRecord.KeyRecordDigest)
	}
	sort.Strings(digests)
	return strings.Join(digests, ",")
}

func (s *Server) dropPrivacyPosture(providerID, assignedID string) {
	if s == nil || s.privacyAuthority == nil {
		return
	}
	s.privacyAdvertised.Delete(sessionKey(providerID, assignedID))
	s.privacyAuthority.DropSession(providerID, assignedID)
}
