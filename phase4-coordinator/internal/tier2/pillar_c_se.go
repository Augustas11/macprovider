package tier2

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const (
	seAttestationFormat = "macprovider-se-p256-v1"
	// rawP256PubkeyBytes is the expected length of an uncompressed P-256 point
	// without the 0x04 prefix (x || y, 32 bytes each).
	rawP256PubkeyBytes = 64
)

// SignedSEAttestation is the JSON structure encoded as the `token` field
// (base64url bytes) of an attestation_token with format macprovider-se-p256-v1.
type SignedSEAttestation struct {
	// Attestation is the signed body. Canonical JSON (sorted keys) is the
	// pre-image for the ES256 signature below.
	Attestation map[string]interface{} `json:"attestation"`
	// Signature is a base64-encoded DER ECDSA signature over the canonical
	// JSON re-encoding of Attestation, computed with the SE P-256 key.
	Signature string `json:"signature"`
}

// SEAttestationResult carries the verified SE public key extracted from a
// successfully validated macprovider-se-p256-v1 token. Callers store the
// key on the pool.Provider entry and set AttestationTier = "self_signed".
type SEAttestationResult struct {
	// SEPublicKey is the raw 64-byte uncompressed P-256 point (x || y,
	// WITHOUT the 0x04 prefix), matching the runbook §1.1.C field format.
	SEPublicKey []byte
	// SerialNumber is the optional hardware serial from the signed attestation
	// blob (used by Phase 3 live MDA to look up the enrolled MicroMDM device).
	SerialNumber string
}

// verifySEAttestationToken verifies a macprovider-se-p256-v1 attestation token.
//
// Verification steps:
//  1. Decode token.Token (base64url) → SignedSEAttestation JSON
//  2. Re-encode Attestation with sorted keys → canonical JSON
//  3. Verify ES256 signature over canonical JSON with the SE public key
//  4. Verify encryptionPublicKey in attestation matches key_binding.provider_ecdh_public_key
//  5. Verify binding signature (SPEC-008 shape) using the SE public key
//
// Returns (AttestationStatusAttested, *SEAttestationResult) on success.
// Returns (AttestationStatusFailed, nil) on any cryptographic or structural failure.
// Returns (AttestationStatusStale, nil) when the challenge does not match
// (upstream VerifyAttestationToken already handles this, but guard defensively).
func verifySEAttestationToken(token AttestationToken, challenge []byte, authAttemptID string) (pool.AttestationStatus, *SEAttestationResult) {
	// 1. Decode base64url token field → SignedSEAttestation JSON bytes.
	tokenBytes, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(token.Token))
	if err != nil {
		return pool.AttestationStatusFailed, nil
	}

	var signed SignedSEAttestation
	if err := json.Unmarshal(tokenBytes, &signed); err != nil {
		return pool.AttestationStatusFailed, nil
	}
	if signed.Attestation == nil {
		return pool.AttestationStatusFailed, nil
	}

	// 2. Canonical JSON: json.Marshal on map[string]interface{} sorts keys.
	canonicalAttestation, err := json.Marshal(signed.Attestation)
	if err != nil {
		return pool.AttestationStatusFailed, nil
	}

	// 3. Extract and reconstruct the SE public key.
	pubKeyB64, _ := signed.Attestation["publicKey"].(string)
	if strings.TrimSpace(pubKeyB64) == "" {
		return pool.AttestationStatusFailed, nil
	}
	pubKeyRaw, err := decodeFlexBase64(pubKeyB64)
	if err != nil || len(pubKeyRaw) != rawP256PubkeyBytes {
		return pool.AttestationStatusFailed, nil
	}
	sePub, err := rawP256ToECDSA(pubKeyRaw)
	if err != nil {
		return pool.AttestationStatusFailed, nil
	}

	// 4. Verify ES256 signature over canonical attestation JSON.
	sigBytes, err := decodeFlexBase64(strings.TrimSpace(signed.Signature))
	if err != nil {
		return pool.AttestationStatusFailed, nil
	}
	digest := sha256.Sum256(canonicalAttestation)
	if !ecdsa.VerifyASN1(sePub, digest[:], sigBytes) {
		return pool.AttestationStatusFailed, nil
	}

	// 5. Verify encryptionPublicKey matches ECDH key in key_binding.
	encPubKey, _ := signed.Attestation["encryptionPublicKey"].(string)
	if strings.TrimSpace(encPubKey) == "" || encPubKey != token.KeyBinding.ProviderECDHPublicKey {
		return pool.AttestationStatusFailed, nil
	}

	// 6. Verify binding signature using SE pubkey (SPEC-008 payload shape).
	if reason := verifyAttestationBindingSignatureWithECDSA(sePub, token, authAttemptID); reason != "" {
		return pool.AttestationStatusFailed, nil
	}

	serial, _ := signed.Attestation["serialNumber"].(string)
	return pool.AttestationStatusAttested, &SEAttestationResult{
		SEPublicKey:  pubKeyRaw,
		SerialNumber: strings.TrimSpace(serial),
	}
}

// verifyAttestationBindingSignatureWithECDSA verifies the SPEC-008
// attestation binding signature using a bare *ecdsa.PublicKey (no certificate).
// Only ES256 is accepted for SE tokens.
func verifyAttestationBindingSignatureWithECDSA(pub *ecdsa.PublicKey, token AttestationToken, authAttemptID string) string {
	sig, ok := parseAttestationBindingSignature(token.Signature)
	if !ok {
		return "attestation_binding_signature_missing"
	}
	if sig.Alg != "ES256" {
		return "attestation_binding_signature_alg_unsupported"
	}
	payload, err := attestationBindingPayload(token, authAttemptID)
	if err != nil {
		return "attestation_binding_payload_invalid"
	}
	signature, err := base64.RawURLEncoding.DecodeString(sig.Signature)
	if err != nil {
		return "attestation_binding_signature_invalid"
	}
	digest := sha256.Sum256(payload)
	if !ecdsa.VerifyASN1(pub, digest[:], signature) {
		return "attestation_binding_signature_mismatch"
	}
	return ""
}

// rawP256ToECDSA reconstructs an *ecdsa.PublicKey from 64 raw bytes (x || y,
// uncompressed P-256 point without the 0x04 prefix).
func rawP256ToECDSA(raw []byte) (*ecdsa.PublicKey, error) {
	if len(raw) != rawP256PubkeyBytes {
		return nil, fmt.Errorf("se pubkey: expected %d bytes, got %d", rawP256PubkeyBytes, len(raw))
	}
	x := new(big.Int).SetBytes(raw[:32])
	y := new(big.Int).SetBytes(raw[32:])
	curve := elliptic.P256()
	if !curve.IsOnCurve(x, y) {
		return nil, fmt.Errorf("se pubkey: point not on P-256")
	}
	return &ecdsa.PublicKey{Curve: curve, X: x, Y: y}, nil
}

// decodeFlexBase64 tries standard then URL-safe base64, with and without padding.
func decodeFlexBase64(s string) ([]byte, error) {
	for _, enc := range []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	} {
		if b, err := enc.DecodeString(s); err == nil {
			return b, nil
		}
	}
	return nil, fmt.Errorf("not valid base64")
}

