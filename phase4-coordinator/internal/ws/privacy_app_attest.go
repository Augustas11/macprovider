package ws

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"

	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

// SPEC-049 §4.11 App Attest enrollment messages. Every one travels over the
// authenticated provider WebSocket of the live assigned session.
const (
	privacyAppAttestEnrollRequestType   = "privacy_app_attest_enroll_request"
	privacyAppAttestEnrollChallengeType = "privacy_app_attest_enroll_challenge"
	privacyAppAttestEnrollmentType      = "privacy_app_attest_enrollment"
	privacyAppAttestEnrollResultType    = "privacy_app_attest_enroll_result"

	maxPrivacyAppAttestEnrollRequestBytes = 512
)

// PrivacyAppAttestEnrollRequest asks the coordinator to enroll a keyId.
type PrivacyAppAttestEnrollRequest struct {
	Type           string `json:"type"`
	Version        int    `json:"version"`
	AppAttestKeyID string `json:"app_attest_key_id"`
}

// PrivacyAppAttestEnrollChallenge is a single-use enrollment challenge.
type PrivacyAppAttestEnrollChallenge struct {
	Type           string `json:"type"`
	Version        int    `json:"version"`
	AppAttestKeyID string `json:"app_attest_key_id"`
	Challenge      string `json:"challenge"`
	IssuedAtUnix   int64  `json:"issued_at_unix"`
}

// PrivacyAppAttestEnrollResult carries enrolled, reenroll_required,
// unavailable, or rejected.
type PrivacyAppAttestEnrollResult struct {
	Type           string `json:"type"`
	Version        int    `json:"version"`
	AppAttestKeyID string `json:"app_attest_key_id"`
	Status         string `json:"status"`
}

// ParsePrivacyAppAttestEnrollRequest decodes the closed request.
func ParsePrivacyAppAttestEnrollRequest(payload []byte) (PrivacyAppAttestEnrollRequest, error) {
	if len(payload) == 0 || len(payload) > maxPrivacyAppAttestEnrollRequestBytes {
		return PrivacyAppAttestEnrollRequest{}, fmt.Errorf("privacy app attest enroll request size")
	}
	dec := json.NewDecoder(bytes.NewReader(payload))
	dec.DisallowUnknownFields()
	var request PrivacyAppAttestEnrollRequest
	if err := dec.Decode(&request); err != nil {
		return PrivacyAppAttestEnrollRequest{}, err
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return PrivacyAppAttestEnrollRequest{}, fmt.Errorf("privacy app attest enroll request has trailing data")
	}
	if request.Type != privacyAppAttestEnrollRequestType || request.Version != 1 {
		return PrivacyAppAttestEnrollRequest{}, fmt.Errorf("privacy app attest enroll request type")
	}
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(request.AppAttestKeyID)
	if err != nil || len(decoded) != 32 || base64.RawURLEncoding.EncodeToString(decoded) != request.AppAttestKeyID {
		return PrivacyAppAttestEnrollRequest{}, fmt.Errorf("privacy app attest key id")
	}
	return request, nil
}

func (s *Server) handlePrivacyAppAttestEnrollRequest(providerID, assignedID string, payload []byte) {
	if s == nil || s.privacyAuthority == nil {
		return
	}
	request, err := ParsePrivacyAppAttestEnrollRequest(payload)
	if err != nil {
		s.log.Warn().Str("provider_id", providerID).Msg("privacy app attest: enroll request rejected")
		return
	}
	reply := s.privacyAuthority.BeginEnrollment(context.Background(), providerID, assignedID, request.AppAttestKeyID, s.now())
	if reply.Challenge != "" {
		s.sendPrivacyAppAttest(providerID, assignedID, PrivacyAppAttestEnrollChallenge{
			Type: privacyAppAttestEnrollChallengeType, Version: 1, AppAttestKeyID: request.AppAttestKeyID,
			Challenge: reply.Challenge, IssuedAtUnix: reply.IssuedAtUnix,
		})
		return
	}
	s.sendAppAttestResult(providerID, assignedID, request.AppAttestKeyID, reply.Status)
}

// handlePrivacyAppAttestEnrollment passes the original bytes to the
// authority, which applies the closed schema, size cap, and verification.
func (s *Server) handlePrivacyAppAttestEnrollment(providerID, assignedID string, payload []byte) {
	if s == nil || s.privacyAuthority == nil {
		return
	}
	keyID := s.privacyAuthority.PendingEnrollmentKeyID(providerID, assignedID)
	status := s.privacyAuthority.CompleteEnrollment(context.Background(), providerID, assignedID, append([]byte(nil), payload...), s.now())
	if keyID == "" {
		s.log.Warn().Str("provider_id", providerID).Msg("privacy app attest: enrollment without an outstanding challenge")
		return
	}
	if status != relayblind.AppAttestEnrolled {
		s.log.Warn().Str("provider_id", providerID).Str("status", status).Msg("privacy app attest: enrollment not accepted")
	}
	s.sendAppAttestResult(providerID, assignedID, keyID, status)
}

// sendAppAttestResult is also the authority's unsolicited notifier.
func (s *Server) sendAppAttestResult(providerID, assignedID, keyID, status string) {
	s.sendPrivacyAppAttest(providerID, assignedID, PrivacyAppAttestEnrollResult{
		Type: privacyAppAttestEnrollResultType, Version: 1, AppAttestKeyID: keyID, Status: status,
	})
}

func (s *Server) sendPrivacyAppAttest(providerID, assignedID string, message any) {
	session, ok := s.sessionFor(providerID, assignedID)
	if !ok {
		return
	}
	raw, err := json.Marshal(message)
	if err != nil {
		return
	}
	if err := session.send(raw); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("privacy app attest: send failed")
	}
}
