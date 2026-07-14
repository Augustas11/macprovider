package auth

import "time"

// AdmissionIdentityRecoveryAuthorization is the exact, dual-controlled,
// one-shot authority for replacing a provider's durable admission key.
// Public keys are represented only by lowercase SHA-256 digests.
type AdmissionIdentityRecoveryAuthorization struct {
	PendingID                      string
	ProviderID                     string
	CandidatePublicKeySHA256       string
	ExpectedCurrentPublicKeySHA256 string
	ExpectedGeneration             int
	RequestedBy                    string
	ApprovedBy                     string
	RequestedUntil                 time.Time
	Reason                         string
	IncidentID                     string
}
