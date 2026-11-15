package relayblind

// SPEC-049-R030: the closed set of privacy routing reject reasons. A reason
// labels operator logs and metrics only. It never reaches the buyer and never
// names a provider, session, key, account, or request.

// PrivacyRejectReasonHeader is the internal coordinator-to-gateway header that
// carries the reason on a refused privacy-class request. The gateway never
// forwards it.
const PrivacyRejectReasonHeader = "X-MacProvider-Privacy-Reject-Reason"

// Phases of a privacy-class request at which a refusal is recorded.
const (
	PrivacyRejectPhaseReservation = "reservation"
	PrivacyRejectPhaseConsume     = "consume"
	PrivacyRejectPhaseDispatch    = "dispatch"
)

// Reject reasons.
const (
	PrivacyRejectClassNotConfigured       = "class_not_configured"
	PrivacyRejectKillSwitch               = "kill_switch_disabled"
	PrivacyRejectStoreUnavailable         = "store_unavailable"
	PrivacyRejectRelayBlindUnavailable    = "relay_blind_unavailable"
	PrivacyRejectModelNotServed           = "model_not_served"
	PrivacyRejectModelNotPrivateCapable   = "model_not_private_capable"
	PrivacyRejectLiveSessionUnavailable   = "live_session_unavailable"
	PrivacyRejectSettlementPrerequisite   = "settlement_prerequisite_missing"
	PrivacyRejectProviderQuarantined      = "provider_quarantined"
	PrivacyRejectProviderNotEnrolled      = "provider_not_enrolled"
	PrivacyRejectPostureUnverified        = "posture_unverified"
	PrivacyRejectKeyNotInPosture          = "key_not_in_posture"
	PrivacyRejectPostureExpired           = "posture_expired"
	PrivacyRejectCodeIdentityUnapproved   = "code_identity_unapproved"
	PrivacyRejectKeyStaleOrRevoked        = "key_stale_or_revoked"
	PrivacyRejectKeyAttestationMismatch   = "key_attestation_mismatch"
	PrivacyRejectReservationRejected      = "reservation_rejected"
	PrivacyRejectReservationExpired       = "reservation_expired"
	PrivacyRejectSessionLost              = "session_lost"
	PrivacyRejectSlotUnavailable          = "slot_unavailable"
	PrivacyRejectProviderQuotaUnavailable = "provider_quota_unavailable"
	PrivacyRejectBuyerCancelled           = "buyer_cancelled"
	PrivacyRejectSettlementSnapshotFailed = "settlement_snapshot_failed"
	PrivacyRejectDispatchUnavailable      = "dispatch_unavailable"
	PrivacyRejectMarkerMismatch           = "marker_mismatch"
	PrivacyRejectPoolScopedRequest        = "pool_scoped_request"
	PrivacyRejectPoolNoEligibleMember     = "pool_no_eligible_member"
	PrivacyRejectPoolStateStale           = "pool_state_stale"
	PrivacyRejectProviderRejected         = "provider_rejected"
	PrivacyRejectCapabilityUnsupported    = "capability_unsupported"
	// PrivacyRejectAssuranceUnavailable: the request required
	// code_bound_attested and the posture is not code-bound (SPEC-049-R034).
	PrivacyRejectAssuranceUnavailable = "assurance_unavailable"
	PrivacyRejectOther                = "other"
)

var privacyRejectReasons = map[string]struct{}{
	PrivacyRejectClassNotConfigured: {}, PrivacyRejectKillSwitch: {}, PrivacyRejectStoreUnavailable: {},
	PrivacyRejectRelayBlindUnavailable: {}, PrivacyRejectModelNotServed: {}, PrivacyRejectModelNotPrivateCapable: {},
	PrivacyRejectLiveSessionUnavailable: {}, PrivacyRejectSettlementPrerequisite: {}, PrivacyRejectProviderQuarantined: {},
	PrivacyRejectProviderNotEnrolled: {}, PrivacyRejectPostureUnverified: {}, PrivacyRejectKeyNotInPosture: {},
	PrivacyRejectPostureExpired: {}, PrivacyRejectCodeIdentityUnapproved: {}, PrivacyRejectKeyStaleOrRevoked: {},
	PrivacyRejectKeyAttestationMismatch: {}, PrivacyRejectReservationRejected: {}, PrivacyRejectReservationExpired: {},
	PrivacyRejectSessionLost: {}, PrivacyRejectSlotUnavailable: {}, PrivacyRejectProviderQuotaUnavailable: {},
	PrivacyRejectBuyerCancelled: {}, PrivacyRejectSettlementSnapshotFailed: {}, PrivacyRejectDispatchUnavailable: {},
	PrivacyRejectMarkerMismatch: {}, PrivacyRejectPoolScopedRequest: {}, PrivacyRejectProviderRejected: {},
	PrivacyRejectCapabilityUnsupported: {}, PrivacyRejectPoolNoEligibleMember: {}, PrivacyRejectPoolStateStale: {},
	PrivacyRejectAssuranceUnavailable: {}, PrivacyRejectOther: {},
}

// PrivacyRejectReasons returns the closed reason set.
func PrivacyRejectReasons() []string {
	out := make([]string, 0, len(privacyRejectReasons))
	for reason := range privacyRejectReasons {
		out = append(out, reason)
	}
	return out
}

// NormalizePrivacyRejectReason returns reason when it is in the closed set and
// "other" otherwise, so no unvetted string becomes a log field or label.
func NormalizePrivacyRejectReason(reason string) string {
	if _, ok := privacyRejectReasons[reason]; ok {
		return reason
	}
	return PrivacyRejectOther
}

// PrivacyRejectPhaseKnown reports a phase from the closed set.
func PrivacyRejectPhaseKnown(phase string) bool {
	switch phase {
	case PrivacyRejectPhaseReservation, PrivacyRejectPhaseConsume, PrivacyRejectPhaseDispatch:
		return true
	default:
		return false
	}
}
