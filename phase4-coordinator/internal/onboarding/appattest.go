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
	_, attested, err := v.VerifyKey(ctx, evidence)
	return attested, err
}

// VerifyKey is Verify that also returns the attested 65-byte uncompressed
// P-256 public key when the attestation passes every check, so the recorder
// can keep it with the key id (SPEC-033-R004).
func (v AppleAppAttestVerifier) VerifyKey(ctx context.Context, evidence AppAttestEvidence) ([]byte, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, false, ErrAppAttestTransient
	}
	teamID := strings.TrimSpace(v.Config.TeamID)
	bundleID := strings.TrimSpace(v.Config.BundleID)
	if teamID == "" || bundleID == "" {
		return nil, false, ErrAppAttestTransient
	}
	root := v.Root
	if root == nil {
		pinned, err := appattest.AppleRoot()
		if err != nil {
			return nil, false, ErrAppAttestTransient
		}
		root = pinned
	}
	now := time.Now()
	if v.Now != nil {
		now = v.Now()
	}
	key, err := appattest.VerifyAttestation(appattest.AttestationInput{
		Attestation:    evidence.Object,
		KeyID:          evidence.KeyID,
		ClientDataHash: evidence.ClientDataHash[:],
		AppID:          teamID + "." + bundleID,
		Now:            now,
		Root:           root,
	})
	switch {
	case err == nil:
		return append([]byte(nil), key.PublicKey...), true, nil
	case errors.Is(err, appattest.ErrACLMismatch):
		return nil, false, nil
	default:
		return nil, false, ErrAppAttestBinding
	}
}
