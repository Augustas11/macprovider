package relayblind

import (
	"context"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// SPEC-049-R030: a provider whose keys are only claimed, not enrolled, is
// reported as not enrolled; once its posture enrolls it, a later missing
// posture is reported as unverified.
func TestPrivacyEligibilityReasonSplitsNotEnrolled(t *testing.T) {
	f := newEnrollmentFixture(t, nil)
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	digest := f.record.KeyRecord.KeyRecordDigest
	if _, reason := f.auth.EligibilityReason(f.providerID, f.session, digest, f.now); reason != PrivacyRejectProviderNotEnrolled {
		t.Fatalf("reason before enrollment = %q", reason)
	}
	if _, ok := f.auth.Eligible(f.providerID, f.session, digest, f.now); ok {
		t.Fatal("unenrolled provider eligible")
	}
	if err := f.posture(0); err != nil {
		t.Fatal(err)
	}
	f.auth.NoteChallengeTimeout(f.providerID, f.session)
	if _, reason := f.auth.EligibilityReason(f.providerID, f.session, digest, f.now); reason != PrivacyRejectPostureUnverified {
		t.Fatalf("reason after a missed challenge = %q", reason)
	}
}

// A refused key advertisement leaves its routing reason for selection, and
// an accepted one clears it.
func TestPrivacyAdvertisementRejectionIsRemembered(t *testing.T) {
	f := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.ApprovedCodeIdentities = []config.ApprovedCodeIdentity{approvedIdentity(secondFixtureCDHash)}
	})
	if err := f.auth.AcceptPrivacyKeys(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{f.record}, f.now); err == nil {
		t.Fatal("unapproved code identity accepted")
	}
	if got := f.auth.AdvertisementRejection(f.providerID, f.session); got != PrivacyRejectCodeIdentityUnapproved {
		t.Fatalf("advertisement rejection = %q", got)
	}
	approved := newPrivacyFixture(t, nil)
	if err := approved.auth.AcceptPrivacyKeys(context.Background(), approved.providerID, approved.session, []PrivacyKeyRecord{approved.record}, approved.now); err != nil {
		t.Fatal(err)
	}
	if got := approved.auth.AdvertisementRejection(approved.providerID, approved.session); got != "" {
		t.Fatalf("accepted advertisement left reason %q", got)
	}
	approved.auth.DropSession(approved.providerID, approved.session)
	if got := approved.auth.AdvertisementRejection(approved.providerID, approved.session); got != "" {
		t.Fatalf("dropped session kept reason %q", got)
	}
}

func TestAdvertisementRejectReasonMapping(t *testing.T) {
	for err, want := range map[error]string{
		nil: "",
		privacyReject("posture_unapproved_code_identity"):                                      PrivacyRejectCodeIdentityUnapproved,
		privacyReject("privacy_enrollment_key_in_use"):                                         PrivacyRejectProviderNotEnrolled,
		&privacyRejection{base: ErrPrivacyQuarantined, reason: "posture_denied_code_identity"}: PrivacyRejectProviderQuarantined,
		ErrPrivacyQuarantined: PrivacyRejectProviderQuarantined,
		ErrStoreUnavailable:   PrivacyRejectStoreUnavailable,
		ErrInvalidPin:         PrivacyRejectProviderNotEnrolled,
		ErrInvalidKeyRecord:   PrivacyRejectKeyAttestationMismatch,
	} {
		if got := advertisementRejectReason(err); got != want {
			t.Fatalf("advertisementRejectReason(%v) = %q, want %q", err, got, want)
		}
	}
}
