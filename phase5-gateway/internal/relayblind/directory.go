package relayblind

import (
	"bytes"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"time"
)

// SPEC-049 v0.2 automatic enrollment: the provider enrollment claim and the
// operator-signed identity directory. This file is byte-identical in the
// coordinator and gateway relay-blind packages (scripts/test-relay-blind-parity.sh).
const (
	PrivacyEnrollmentVersion           = "privacy-enrollment-v1"
	IdentityDirectoryVersion           = "privacy-identity-directory-v1"
	IdentityDirectoryEnvelopeVersion   = "privacy-identity-directory-envelope-v1"
	IdentityDirectoryDomain            = "macprovider/spec049/identity-directory/v1"
	IdentityDirectorySourceEnrolled    = "enrolled"
	IdentityDirectorySourceOperatorPin = "operator_pin"

	MaxIdentityDirectoryBytes      = 1 << 20
	MaxIdentityDirectoryEntries    = 4096
	MinIdentityDirectoryTTL        = 60 * time.Second
	MaxIdentityDirectoryTTL        = 3600 * time.Second
	MaxIdentityDirectoryFutureSkew = 60 * time.Second
)

var ErrInvalidDirectory = errors.New("relayblind: invalid identity directory")

// PrivacyEnrollmentClaim is the SPEC-049 §4.10 public key claim a privacy-mode
// provider advertises beside its privacy key records. It is never trusted on
// its own: the coordinator only enrolls it after a fully verified posture.
type PrivacyEnrollmentClaim struct {
	Version           string `json:"version"`
	IdentityPublicKey string `json:"identity_public_key"`
	SEPublicKey       string `json:"se_public_key"`
}

func ParsePrivacyEnrollmentClaim(raw []byte) (PrivacyEnrollmentClaim, error) {
	var claim PrivacyEnrollmentClaim
	if err := decodeClosed(raw, &claim, []string{"version", "identity_public_key", "se_public_key"}); err != nil {
		return PrivacyEnrollmentClaim{}, err
	}
	if err := claim.Validate(); err != nil {
		return PrivacyEnrollmentClaim{}, err
	}
	return claim, nil
}

func (c PrivacyEnrollmentClaim) Validate() error {
	if c.Version != PrivacyEnrollmentVersion {
		return fmt.Errorf("%w: enrollment claim version", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(c.IdentityPublicKey, ed25519.PublicKeySize); err != nil {
		return fmt.Errorf("%w: enrollment identity key", ErrInvalidPrivacy)
	}
	if _, err := DecodeSEPublicKey(c.SEPublicKey); err != nil {
		return fmt.Errorf("%w: enrollment secure enclave key", ErrInvalidPrivacy)
	}
	return nil
}

// DecodeSEPublicKey decodes canonical standard base64 of a raw 64-byte P-256
// X||Y point and requires the point to be on the curve.
func DecodeSEPublicKey(encoded string) ([]byte, error) {
	decoded, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || len(decoded) != 64 || base64.StdEncoding.EncodeToString(decoded) != encoded {
		return nil, ErrInvalidPrivacy
	}
	x := new(big.Int).SetBytes(decoded[:32])
	y := new(big.Int).SetBytes(decoded[32:])
	if !elliptic.P256().IsOnCurve(x, y) {
		return nil, ErrInvalidPrivacy
	}
	return decoded, nil
}

// PublicKeyFingerprint is canonical base64url SHA-256 of raw public key bytes,
// the SPEC-041-R002 fingerprint form.
func PublicKeyFingerprint(raw []byte) string {
	digest := sha256.Sum256(raw)
	return encodeBase64URL(digest[:])
}

type IdentityDirectoryEntry struct {
	IdentityPublicKey      string `json:"identity_public_key"`
	Fingerprint            string `json:"fingerprint"`
	SEPublicKeyFingerprint string `json:"se_public_key_fingerprint"`
	Source                 string `json:"source"`
	EnrolledAtUnix         int64  `json:"enrolled_at_unix"`
	Revoked                bool   `json:"revoked"`
}

type IdentityDirectory struct {
	Version       string                   `json:"version"`
	PrivacyClass  string                   `json:"privacy_class"`
	IssuedAtUnix  int64                    `json:"issued_at_unix"`
	ExpiresAtUnix int64                    `json:"expires_at_unix"`
	Entries       []IdentityDirectoryEntry `json:"entries"`
}

type IdentityDirectoryEnvelope struct {
	Version   string `json:"version"`
	KeyID     string `json:"key_id"`
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

func (e IdentityDirectoryEntry) validate() error {
	pub, err := decodeBase64URLFixed(e.IdentityPublicKey, ed25519.PublicKeySize)
	if err != nil {
		return fmt.Errorf("%w: entry identity key", ErrInvalidDirectory)
	}
	if _, err := decodeBase64URLFixed(e.Fingerprint, sha256.Size); err != nil || subtle.ConstantTimeCompare([]byte(e.Fingerprint), []byte(PublicKeyFingerprint(pub))) != 1 {
		return fmt.Errorf("%w: entry fingerprint", ErrInvalidDirectory)
	}
	if _, err := decodeBase64URLFixed(e.SEPublicKeyFingerprint, sha256.Size); err != nil {
		return fmt.Errorf("%w: entry secure enclave fingerprint", ErrInvalidDirectory)
	}
	if e.Source != IdentityDirectorySourceEnrolled && e.Source != IdentityDirectorySourceOperatorPin {
		return fmt.Errorf("%w: entry source", ErrInvalidDirectory)
	}
	if e.EnrolledAtUnix < 0 {
		return fmt.Errorf("%w: entry enrollment time", ErrInvalidDirectory)
	}
	return nil
}

// Validate checks the closed §4.11 payload rules other than signing-time
// freshness, which VerifyIdentityDirectory applies against the caller's clock.
func (d IdentityDirectory) Validate() error {
	if d.Version != IdentityDirectoryVersion || d.PrivacyClass != PrivacyClassV1 {
		return fmt.Errorf("%w: version", ErrInvalidDirectory)
	}
	ttl := d.ExpiresAtUnix - d.IssuedAtUnix
	if d.IssuedAtUnix < 0 || ttl < int64(MinIdentityDirectoryTTL/time.Second) || ttl > int64(MaxIdentityDirectoryTTL/time.Second) {
		return fmt.Errorf("%w: validity window", ErrInvalidDirectory)
	}
	if d.Entries == nil || len(d.Entries) > MaxIdentityDirectoryEntries {
		return fmt.Errorf("%w: entry count", ErrInvalidDirectory)
	}
	for i, entry := range d.Entries {
		if err := entry.validate(); err != nil {
			return err
		}
		if i > 0 && d.Entries[i-1].Fingerprint >= entry.Fingerprint {
			return fmt.Errorf("%w: entries not strictly sorted", ErrInvalidDirectory)
		}
	}
	return nil
}

// Lookup returns the entry whose fingerprint equals the key record identity
// fingerprint. Entries are sorted, but the set is small enough to scan.
func (d IdentityDirectory) Lookup(fingerprint string) (IdentityDirectoryEntry, bool) {
	for _, entry := range d.Entries {
		if subtle.ConstantTimeCompare([]byte(entry.Fingerprint), []byte(fingerprint)) == 1 {
			return entry, true
		}
	}
	return IdentityDirectoryEntry{}, false
}

// PinForRecord turns the directory entry for record's identity into the
// in-memory SPEC-041-R002 pin. The pin carries the record's own model scope,
// which must include model, and the directory's validity window.
func (d IdentityDirectory) PinForRecord(record KeyRecord, model string) (IdentityPin, error) {
	entry, ok := d.Lookup(record.IdentityFingerprint)
	if !ok {
		return IdentityPin{}, fmt.Errorf("%w: provider identity is not in the signed directory", ErrInvalidPin)
	}
	if entry.Revoked {
		return IdentityPin{}, fmt.Errorf("%w: provider identity is revoked in the signed directory", ErrInvalidPin)
	}
	if !contains(record.Models, model) {
		return IdentityPin{}, fmt.Errorf("%w: key record does not cover the requested model", ErrInvalidPin)
	}
	pin := IdentityPin{
		Version:           PinVersion,
		IdentityPublicKey: entry.IdentityPublicKey,
		Fingerprint:       entry.Fingerprint,
		Models:            append([]string(nil), record.Models...),
		EndpointFamilies:  []string{EndpointChatCompletions},
		NotBeforeUnix:     d.IssuedAtUnix,
		ExpiresAtUnix:     d.ExpiresAtUnix,
	}
	if err := pin.validateStructure(); err != nil {
		return IdentityPin{}, err
	}
	return pin, nil
}

func identityDirectorySigningInput(payload []byte) ([]byte, error) {
	var buf bytes.Buffer
	if err := writeFrame(&buf, []byte(IdentityDirectoryDomain)); err != nil {
		return nil, err
	}
	if err := writeFrame(&buf, payload); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// SignIdentityDirectory validates d and returns the exact §4.11 envelope bytes.
func SignIdentityDirectory(d IdentityDirectory, privateKey ed25519.PrivateKey) ([]byte, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("%w: signing key", ErrInvalidDirectory)
	}
	if err := d.Validate(); err != nil {
		return nil, err
	}
	payload, err := json.Marshal(d)
	if err != nil {
		return nil, err
	}
	input, err := identityDirectorySigningInput(payload)
	if err != nil {
		return nil, err
	}
	envelope := IdentityDirectoryEnvelope{
		Version:   IdentityDirectoryEnvelopeVersion,
		KeyID:     PublicKeyFingerprint(privateKey.Public().(ed25519.PublicKey)),
		Payload:   encodeBase64URL(payload),
		Signature: encodeBase64URL(ed25519.Sign(privateKey, input)),
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		return nil, err
	}
	if len(raw) > MaxIdentityDirectoryBytes {
		return nil, fmt.Errorf("%w: envelope too large", ErrInvalidDirectory)
	}
	return raw, nil
}

// VerifyIdentityDirectory checks the closed envelope, the pinned directory
// key, the signature over the exact payload bytes, the closed payload, and
// freshness at now. JSON is never re-serialized for verification.
func VerifyIdentityDirectory(raw []byte, publicKey ed25519.PublicKey, now time.Time) (IdentityDirectory, error) {
	if len(publicKey) != ed25519.PublicKeySize {
		return IdentityDirectory{}, fmt.Errorf("%w: directory public key", ErrInvalidDirectory)
	}
	if len(raw) == 0 || len(raw) > MaxIdentityDirectoryBytes {
		return IdentityDirectory{}, fmt.Errorf("%w: envelope size", ErrInvalidDirectory)
	}
	var envelope IdentityDirectoryEnvelope
	if err := decodeClosed(raw, &envelope, []string{"version", "key_id", "payload", "signature"}); err != nil {
		return IdentityDirectory{}, fmt.Errorf("%w: envelope", ErrInvalidDirectory)
	}
	if envelope.Version != IdentityDirectoryEnvelopeVersion {
		return IdentityDirectory{}, fmt.Errorf("%w: envelope version", ErrInvalidDirectory)
	}
	if subtle.ConstantTimeCompare([]byte(envelope.KeyID), []byte(PublicKeyFingerprint(publicKey))) != 1 {
		return IdentityDirectory{}, fmt.Errorf("%w: directory key id does not match the pinned key", ErrInvalidDirectory)
	}
	payload, err := decodeBase64URL(envelope.Payload)
	if err != nil || len(payload) == 0 {
		return IdentityDirectory{}, fmt.Errorf("%w: payload encoding", ErrInvalidDirectory)
	}
	signature, err := decodeBase64URLFixed(envelope.Signature, ed25519.SignatureSize)
	if err != nil {
		return IdentityDirectory{}, fmt.Errorf("%w: signature encoding", ErrInvalidDirectory)
	}
	input, err := identityDirectorySigningInput(payload)
	if err != nil || !ed25519.Verify(publicKey, input, signature) {
		return IdentityDirectory{}, fmt.Errorf("%w: signature", ErrInvalidDirectory)
	}
	directory, err := parseIdentityDirectoryPayload(payload)
	if err != nil {
		return IdentityDirectory{}, err
	}
	nowUnix := now.Unix()
	if directory.IssuedAtUnix > nowUnix+int64(MaxIdentityDirectoryFutureSkew/time.Second) {
		return IdentityDirectory{}, fmt.Errorf("%w: issued in the future", ErrInvalidDirectory)
	}
	if nowUnix >= directory.ExpiresAtUnix {
		return IdentityDirectory{}, fmt.Errorf("%w: expired", ErrInvalidDirectory)
	}
	return directory, nil
}

func parseIdentityDirectoryPayload(payload []byte) (IdentityDirectory, error) {
	var wire struct {
		Version       string            `json:"version"`
		PrivacyClass  string            `json:"privacy_class"`
		IssuedAtUnix  int64             `json:"issued_at_unix"`
		ExpiresAtUnix int64             `json:"expires_at_unix"`
		Entries       []json.RawMessage `json:"entries"`
	}
	if err := decodeClosed(payload, &wire, []string{"version", "privacy_class", "issued_at_unix", "expires_at_unix", "entries"}); err != nil {
		return IdentityDirectory{}, fmt.Errorf("%w: payload", ErrInvalidDirectory)
	}
	if wire.Entries == nil || len(wire.Entries) > MaxIdentityDirectoryEntries {
		return IdentityDirectory{}, fmt.Errorf("%w: entry count", ErrInvalidDirectory)
	}
	directory := IdentityDirectory{
		Version:       wire.Version,
		PrivacyClass:  wire.PrivacyClass,
		IssuedAtUnix:  wire.IssuedAtUnix,
		ExpiresAtUnix: wire.ExpiresAtUnix,
		Entries:       make([]IdentityDirectoryEntry, 0, len(wire.Entries)),
	}
	for _, rawEntry := range wire.Entries {
		var entry IdentityDirectoryEntry
		if err := decodeClosed(rawEntry, &entry, []string{"identity_public_key", "fingerprint", "se_public_key_fingerprint", "source", "enrolled_at_unix", "revoked"}); err != nil {
			return IdentityDirectory{}, fmt.Errorf("%w: entry", ErrInvalidDirectory)
		}
		directory.Entries = append(directory.Entries, entry)
	}
	if err := directory.Validate(); err != nil {
		return IdentityDirectory{}, err
	}
	return directory, nil
}
