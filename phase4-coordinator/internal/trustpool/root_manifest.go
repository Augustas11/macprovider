package trustpool

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

const (
	RootSignatureAlgorithmP256SHA256 = "ecdsa-p256-sha256"

	rootIssuerFingerprintTag       = "macprovider/spec043/root-issuer-key/v1"
	rootRegistrationSignatureTag   = "macprovider/spec043/root-key-registration-sig/v1"
	manifestAcceptedSignatureTag   = "macprovider/spec043/manifest-accepted-sig/v1"
	RootRegistrationPurposeDefault = "root_issuer_registration"
)

var (
	errRootAlgorithm       = errors.New("trustpool: unsupported root signature algorithm")
	errRootPublicKey       = errors.New("trustpool: malformed root issuer public key")
	errRootPrivateKey      = errors.New("trustpool: root issuer public key contains private key material")
	errRootFingerprint     = errors.New("trustpool: root issuer public key fingerprint mismatch")
	errRootSignature       = errors.New("trustpool: root issuer signature verification failed")
	errRootCanonicalBase64 = errors.New("trustpool: non-canonical base64")
	errRootDigestFormat    = errors.New("trustpool: digest must be lowercase 64-hex")
	errRootNoncePurpose    = errors.New("trustpool: root registration nonce purpose mismatch")
	errManifestSnapshot    = errors.New("trustpool: invalid manifest snapshot")
)

func RootIssuerPublicKeyFingerprint(algorithmID string, publicKeySPKIDER []byte) (string, error) {
	if algorithmID != RootSignatureAlgorithmP256SHA256 {
		return "", errRootAlgorithm
	}
	if len(algorithmID) > int(^uint16(0)) || uint64(len(publicKeySPKIDER)) > uint64(^uint32(0)) {
		return "", errRootPublicKey
	}
	if _, err := parseRootPublicKey(publicKeySPKIDER); err != nil {
		return "", err
	}
	var enc []byte
	enc = append(enc, rootIssuerFingerprintTag...)
	var algLen [2]byte
	binary.BigEndian.PutUint16(algLen[:], uint16(len(algorithmID)))
	enc = append(enc, algLen[:]...)
	enc = append(enc, algorithmID...)
	var keyLen [4]byte
	binary.BigEndian.PutUint32(keyLen[:], uint32(len(publicKeySPKIDER)))
	enc = append(enc, keyLen[:]...)
	enc = append(enc, publicKeySPKIDER...)
	sum := sha256.Sum256(enc)
	return hex.EncodeToString(sum[:]), nil
}

func RootRegistrationSigningMessage(e DurableEvent) ([]byte, error) {
	return taggedCanonicalJSON(rootRegistrationSignatureTag, map[string]any{
		"approval_record_id":                     e.ApprovalRecordID,
		"creator_account_id":                     e.CreatorAccountID,
		"current_approval_version":               e.CurrentApprovalVersion,
		"environment":                            e.RootRegistrationEnvironment,
		"genesis_nonce_digest":                   e.GenesisNonceDigest,
		"intended_pool_display_name_hash":        e.IntendedPoolDisplayNameHash,
		"launch_environment":                     e.LaunchEnvironment,
		"nonce":                                  e.RootRegistrationNonce,
		"nonce_expiry":                           e.RootRegistrationNonceExpiry,
		"purpose":                                e.RootRegistrationPurpose,
		"root_issuer_key_id":                     e.RootIssuerKeyID,
		"root_issuer_public_key_fingerprint":     e.RootIssuerPublicKeyFingerprint,
		"root_signature_algorithm":               e.RootSignatureAlgorithm,
		"manifest_authority_root_key_id":         e.ManifestAuthorityRootKeyID,
		"manifest_authority_root_public_key":     e.ManifestAuthorityRootPublicKey,
		"structured_key_custody_disclosure_hash": e.StructuredKeyCustodyDisclosureHash,
	})
}

func ManifestAcceptanceSigningMessage(e DurableEvent) ([]byte, error) {
	return taggedCanonicalJSON(manifestAcceptedSignatureTag, map[string]any{
		"manifest_core_digest":               e.ManifestCoreDigest,
		"manifest_snapshot_sha256":           manifestSnapshotSHA256(e.ManifestSnapshot),
		"manifest_version_dec":               strconv.FormatUint(e.ManifestVersion, 10),
		"pool_id":                            e.PoolID,
		"root_issuer_key_id":                 e.RootIssuerKeyID,
		"root_issuer_public_key_fingerprint": e.RootIssuerPublicKeyFingerprint,
	})
}

func VerifyRootIssuerRegistrationEvent(e DurableEvent) error {
	if e.RootSignatureAlgorithm != RootSignatureAlgorithmP256SHA256 {
		return errRootAlgorithm
	}
	if err := requireLowerHex64(e.RootIssuerPublicKeyFingerprint); err != nil {
		return err
	}
	for _, digest := range []string{
		e.StructuredKeyCustodyDisclosureHash,
		e.GenesisNonceDigest,
		e.IntendedPoolDisplayNameHash,
	} {
		if err := requireLowerHex64(digest); err != nil {
			return err
		}
	}
	if e.RootRegistrationPurpose != RootRegistrationPurposeDefault || e.RootRegistrationEnvironment != e.LaunchEnvironment {
		return errRootNoncePurpose
	}
	if _, err := time.Parse(time.RFC3339Nano, e.RootRegistrationNonceExpiry); err != nil {
		return fmt.Errorf("trustpool: invalid nonce_expiry: %w", err)
	}
	der, err := canonicalBase64(e.RootIssuerPublicKeyDER)
	if err != nil {
		return err
	}
	pub, err := parseRootPublicKey(der)
	if err != nil {
		return err
	}
	fingerprint, err := RootIssuerPublicKeyFingerprint(e.RootSignatureAlgorithm, der)
	if err != nil {
		return err
	}
	if fingerprint != e.RootIssuerPublicKeyFingerprint {
		return errRootFingerprint
	}
	if e.ManifestAuthorityRootKeyID == "" {
		return errManifestSnapshot
	}
	authorityRoot, err := canonicalBase64(e.ManifestAuthorityRootPublicKey)
	if err != nil {
		return err
	}
	if len(authorityRoot) != ed25519.PublicKeySize {
		return errManifestSnapshot
	}
	sig, err := canonicalBase64(e.RootRegistrationSignature)
	if err != nil {
		return err
	}
	msg, err := RootRegistrationSigningMessage(e)
	if err != nil {
		return err
	}
	return verifyP256Signature(pub, msg, sig)
}

func VerifyManifestAcceptedEvent(e DurableEvent, root ReconstructedRootIssuer) (string, error) {
	if err := requireLowerHex64(e.ManifestCoreDigest); err != nil {
		return "", err
	}
	der, err := canonicalBase64(root.PublicKeyDER)
	if err != nil {
		return "", err
	}
	pub, err := parseRootPublicKey(der)
	if err != nil {
		return "", err
	}
	fingerprint, err := RootIssuerPublicKeyFingerprint(root.SignatureAlgorithm, der)
	if err != nil {
		return "", err
	}
	if fingerprint != root.PublicKeyFingerprint || e.RootIssuerPublicKeyFingerprint != root.PublicKeyFingerprint {
		return "", errRootFingerprint
	}
	prevDigest, err := verifyManifestSnapshot(e, root)
	if err != nil {
		return "", err
	}
	sig, err := canonicalBase64(e.ManifestSignature)
	if err != nil {
		return "", err
	}
	msg, err := ManifestAcceptanceSigningMessage(e)
	if err != nil {
		return "", err
	}
	return prevDigest, verifyP256Signature(pub, msg, sig)
}

func verifyManifestSnapshot(e DurableEvent, root ReconstructedRootIssuer) (string, error) {
	raw, err := canonicalBase64(e.ManifestSnapshot)
	if err != nil {
		return "", err
	}
	snapshot, err := poolmanifest.ParseManifestSnapshot(raw)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errManifestSnapshot, err)
	}
	authorityRoot, err := canonicalBase64(root.ManifestAuthorityRootPublicKey)
	if err != nil {
		return "", err
	}
	if snapshot.IdentityCore.RootIssuerKeyID != root.ManifestAuthorityRootKeyID ||
		snapshot.RootIssuerKey.KeyID != root.ManifestAuthorityRootKeyID ||
		!bytes.Equal(snapshot.RootIssuerKey.PublicKey, ed25519.PublicKey(authorityRoot)) {
		return "", errManifestSnapshot
	}
	genesisDigest := sha256.Sum256(snapshot.IdentityCore.GenesisNonce)
	if hex.EncodeToString(genesisDigest[:]) != root.GenesisNonceDigest {
		return "", errManifestSnapshot
	}
	poolID, err := snapshot.IdentityCore.PoolID()
	if err != nil {
		return "", err
	}
	if poolID != e.PoolID {
		return "", errManifestSnapshot
	}
	reconstructed, err := poolmanifest.ReconstructPool(snapshot)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errManifestSnapshot, err)
	}
	if reconstructed.PolicyHistory.HighestVersion() != e.ManifestVersion {
		return "", errManifestSnapshot
	}
	if len(snapshot.Policies) == 0 {
		return "", errManifestSnapshot
	}
	last := snapshot.Policies[len(snapshot.Policies)-1].SignedCore.Core
	if last.ManifestVersion != e.ManifestVersion {
		return "", errManifestSnapshot
	}
	digest, err := last.ManifestCoreDigest()
	if err != nil {
		return "", err
	}
	if hex.EncodeToString(digest) != e.ManifestCoreDigest {
		return "", errManifestSnapshot
	}
	return hex.EncodeToString(last.PrevManifestCoreHash), nil
}

func taggedCanonicalJSON(tag string, value map[string]any) ([]byte, error) {
	canonical, err := billing.CanonicalJSON(value)
	if err != nil {
		return nil, err
	}
	msg := make([]byte, 0, len(tag)+len(canonical))
	msg = append(msg, tag...)
	msg = append(msg, canonical...)
	return msg, nil
}

func parseRootPublicKey(der []byte) (*ecdsa.PublicKey, error) {
	if containsPrivateKeyMaterial(der) {
		return nil, errRootPrivateKey
	}
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, errRootPublicKey
	}
	pub, ok := parsed.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return nil, errRootPublicKey
	}
	return pub, nil
}

func containsPrivateKeyMaterial(der []byte) bool {
	if _, err := x509.ParseECPrivateKey(der); err == nil {
		return true
	}
	if _, err := x509.ParsePKCS8PrivateKey(der); err == nil {
		return true
	}
	if _, err := x509.ParsePKCS1PrivateKey(der); err == nil {
		return true
	}
	return false
}

func canonicalBase64(v string) ([]byte, error) {
	decoded, err := base64.StdEncoding.Strict().DecodeString(v)
	if err != nil || base64.StdEncoding.EncodeToString(decoded) != v {
		return nil, errRootCanonicalBase64
	}
	return decoded, nil
}

func verifyP256Signature(pub *ecdsa.PublicKey, msg, sig []byte) error {
	digest := sha256.Sum256(msg)
	if !ecdsa.VerifyASN1(pub, digest[:], sig) {
		return errRootSignature
	}
	return nil
}

func manifestSnapshotSHA256(encoded string) string {
	raw, err := canonicalBase64(encoded)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func requireLowerHex64(v string) error {
	if len(v) != 64 || strings.ToLower(v) != v {
		return errRootDigestFormat
	}
	if _, err := hex.DecodeString(v); err != nil {
		return errRootDigestFormat
	}
	return nil
}
