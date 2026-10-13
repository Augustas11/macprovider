package buyer

import (
	"context"
	"net/http"

	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

// privacyRejectRank orders the SPEC-049-R030 per-candidate reasons by how
// many SPEC-049-R013 checks a candidate passed before failing. When no
// candidate is eligible, the request reports the reason of the candidate
// that came closest to serving it.
var privacyRejectRank = map[string]int{
	relayblind.PrivacyRejectModelNotServed:         0,
	relayblind.PrivacyRejectModelNotPrivateCapable: 1,
	relayblind.PrivacyRejectLiveSessionUnavailable: 2,
	relayblind.PrivacyRejectSettlementPrerequisite: 3,
	relayblind.PrivacyRejectProviderQuarantined:    4,
	relayblind.PrivacyRejectProviderNotEnrolled:    5,
	relayblind.PrivacyRejectPostureUnverified:      6,
	relayblind.PrivacyRejectKeyNotInPosture:        7,
	relayblind.PrivacyRejectPostureExpired:         8,
	relayblind.PrivacyRejectCodeIdentityUnapproved: 9,
	relayblind.PrivacyRejectKillSwitch:             10,
	relayblind.PrivacyRejectKeyStaleOrRevoked:      11,
	relayblind.PrivacyRejectKeyAttestationMismatch: 12,
	relayblind.PrivacyRejectRelayBlindUnavailable:  13,
	relayblind.PrivacyRejectStoreUnavailable:       14,
}

// closerPrivacyReject returns the reason that ranks closer to serving.
func closerPrivacyReject(current, candidate string) string {
	if current == "" {
		return candidate
	}
	currentRank, ok := privacyRejectRank[current]
	if !ok {
		currentRank = -1
	}
	if candidateRank, ok := privacyRejectRank[candidate]; ok && candidateRank > currentRank {
		return candidate
	}
	return current
}

// notePrivacyRouteRejection records one refused privacy-class request
// (SPEC-049-R030): one log line and one metric with closed labels, and the
// internal reason header for an authenticated gateway. The buyer error body,
// code, and status are unchanged, and the gateway drops the header.
func (s *Server) notePrivacyRouteRejection(w http.ResponseWriter, r *http.Request, phase, code, reason string) {
	if s == nil {
		return
	}
	reason = relayblind.NormalizePrivacyRejectReason(reason)
	// Fixed categories only: no provider, session, key, account, or request
	// identifier, and no raw store error.
	s.log.Info().Str("event", "privacy_route_rejected").Str("phase", phase).Str("code", code).Str("reason", reason).Msg("privacy request refused")
	s.privacyAuthority.ObserveRouteRejection(phase, reason)
	if w != nil && r != nil && s.requireGatewayContext && s.internalBearerAuthorizedRemote(r.Header, r.RemoteAddr) {
		w.Header().Set(relayblind.PrivacyRejectReasonHeader, reason)
	}
}

// writePrivacyRouteError records the rejection and writes the unchanged
// SPEC-049 §4.9 error.
func (s *Server) writePrivacyRouteError(w http.ResponseWriter, r *http.Request, phase, code, reason string) {
	s.writePrivacyRouteErrorMessage(w, r, phase, code, reason, "")
}

// writePrivacyRouteErrorMessage is writePrivacyRouteError with the existing
// buyer message of that site.
func (s *Server) writePrivacyRouteErrorMessage(w http.ResponseWriter, r *http.Request, phase, code, reason, message string) {
	s.notePrivacyRouteRejection(w, r, phase, code, reason)
	writePrivacyClassError(w, code, message)
}

// privacyConflictReason is the SPEC-049-R030 reason of a privacyClassConflict
// code: a marker mismatch, or the cause of the disabled class.
func (s *Server) privacyConflictReason(ctx context.Context, code string) string {
	if code == privacyClassDisabled {
		if reason := s.privacyDisabledReason(ctx); reason != "" {
			return reason
		}
		return relayblind.PrivacyRejectKillSwitch
	}
	return relayblind.PrivacyRejectMarkerMismatch
}
