package onboarding

import (
	"context"
	"crypto/x509"
	"errors"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest"
)

// AppleAppAttestVerifier verifies an Apple App Attest attestation object with
// internal/appattest under the production policy (SPEC-033 §5.7.2): the pinned
// Apple App Attestation Root CA, Apple's nonce extension, the production
// AAGUID, keyId = SHA-256(leaf key), and the SIP + Full Security ACL.
type AppleAppAttestVerifier struct {
	Config AppAttestConfig
	// Root overrides the pinned Apple root. Tests only; nil uses
	// appattest.AppleRoot(), which refuses a root whose fingerprint differs.
	Root *x509.Certificate
	Now  func() time.Time
}

// Verify returns (true, nil) for an attestation that passes every check,
// (false, nil) for a genuine Apple key that fails only the SIP/Full Security
// ACL policy, ErrAppAttestBinding for any other verification failure, and
// ErrAppAttestTransient when the verifier itself cannot run (missing pins,
// unusable root, cancelled context).
func (v AppleAppAttestVerifier) Verify(ctx context.Context, evidence AppAttestEvidence) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, ErrAppAttestTransient
	}
	teamID := strings.TrimSpace(v.Config.TeamID)
	bundleID := strings.TrimSpace(v.Config.BundleID)
	if teamID == "" || bundleID == "" {
		return false, ErrAppAttestTransient
	}
	root := v.Root
	if root == nil {
		pinned, err := appattest.AppleRoot()
		if err != nil {
			return false, ErrAppAttestTransient
		}
		root = pinned
	}
	now := time.Now()
	if v.Now != nil {
		now = v.Now()
	}
	_, err := appattest.VerifyAttestation(appattest.AttestationInput{
		Attestation:    evidence.Object,
		KeyID:          evidence.KeyID,
		ClientDataHash: evidence.ClientDataHash[:],
		AppID:          teamID + "." + bundleID,
		Now:            now,
		Root:           root,
	})
	switch {
	case err == nil:
		return true, nil
	case errors.Is(err, appattest.ErrACLMismatch):
		return false, nil
	default:
		return false, ErrAppAttestBinding
	}
}
