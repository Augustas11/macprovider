// Package appattest verifies Apple App Attest attestation and assertion
// objects for SPEC-049 code-bound posture (SPEC-049-R028, SPEC-049-R031).
// It never contacts Apple and never evaluates the fraud-metric receipt.
package appattest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"time"
)

var (
	// ErrAttestationInvalid covers SPEC-049-R028 steps 2..7.
	ErrAttestationInvalid = errors.New("appattest: attestation invalid")
	// ErrACLMismatch is SPEC-049-R028 step 8: the aclBlob is missing or is
	// not the SIP and Full Security value.
	ErrACLMismatch = errors.New("appattest: aclBlob mismatch")
	// ErrAssertionInvalid covers SPEC-049-R031 steps 1..4.
	ErrAssertionInvalid = errors.New("appattest: assertion invalid")
)

const (
	// AttestationFormat is the only accepted fmt.
	AttestationFormat = "apple-appattest"
	// MaxAttestationBytes is the decoded attestation cap (SPEC-049 §4.11).
	MaxAttestationBytes = 16384
	// MaxAssertionBytes is the decoded assertion cap (SPEC-049 §4.10).
	MaxAssertionBytes = 2048
	// MaxAssertionAuthDataBytes bounds assertion authenticatorData.
	MaxAssertionAuthDataBytes = 512
	// MaxAssertionSignatureBytes bounds the DER ECDSA P-256 signature.
	MaxAssertionSignatureBytes = 72
	// KeyIDBytes is the keyId and credentialId length: SHA-256 of the key.
	KeyIDBytes = 32

	authFlagAT      = 0x40
	authHeaderBytes = 37
	certSkew        = 300 * time.Second
	// Developer ID, per Apple's apple_validation_category_01 table.
	validationCategoryDeveloperID = 6
)

var (
	oidNonce = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}
	oidACL   = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 6}

	// ProductionAAGUID is "appattest" followed by seven zero bytes.
	productionAAGUID = [16]byte{'a', 'p', 'p', 'a', 't', 't', 'e', 's', 't'}

	// requiredACL is the aclBlob octet string Apple documents for a key
	// attested on macOS with SIP and Full Security on (SPEC-049 §4.1).
	requiredACL = mustBase64("MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB")
)

func mustBase64(value string) []byte {
	out, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		panic(err)
	}
	return out
}

// RequiredACLBlob returns a copy of the compiled SIP and Full Security value.
func RequiredACLBlob() []byte { return append([]byte(nil), requiredACL...) }

// AttestationInput is one SPEC-049-R028 steps 2..8 check. ClientDataHash
// is SHA-256 of the recomputed enrollment framing; AppID is
// "<team>.tech.malibu.app".
type AttestationInput struct {
	Attestation    []byte
	KeyID          []byte
	ClientDataHash []byte
	AppID          string
	Now            time.Time
	Root           *x509.Certificate
}

// AttestedKey is the verified credential. PublicKey is the 65-byte
// uncompressed P-256 point, which is public material.
type AttestedKey struct {
	PublicKey []byte
}

// attestPolicy relaxes the two SPEC-049 policy checks that Apple's own
// published sample cannot satisfy. Production always uses strictPolicy.
type attestPolicy struct {
	anyCategory bool
	skipACL     bool
}

var strictPolicy = attestPolicy{}

// VerifyAttestation applies SPEC-049-R028 steps 2..8 and rejects on the
// first failure.
func VerifyAttestation(in AttestationInput) (AttestedKey, error) {
	if len(in.ClientDataHash) != sha256.Size {
		return AttestedKey{}, fmt.Errorf("%w: clientDataHash", ErrAttestationInvalid)
	}
	return verifyAttestation(in, strictPolicy)
}

func attestFail(format string, args ...any) error {
	return fmt.Errorf("%w: "+format, append([]any{ErrAttestationInvalid}, args...)...)
}

func verifyAttestation(in AttestationInput, policy attestPolicy) (AttestedKey, error) {
	if in.Root == nil {
		return AttestedKey{}, attestFail("trust anchor unavailable")
	}
	if in.AppID == "" || len(in.KeyID) != KeyIDBytes || len(in.ClientDataHash) == 0 {
		return AttestedKey{}, attestFail("input")
	}
	if len(in.Attestation) == 0 || len(in.Attestation) > MaxAttestationBytes {
		return AttestedKey{}, attestFail("size")
	}
	if in.Now.IsZero() {
		in.Now = time.Now()
	}
	// Step 2: closed CBOR shape.
	obj, err := decodeCBOR(in.Attestation)
	if err != nil {
		return AttestedKey{}, attestFail("cbor: %v", err)
	}
	if !obj.onlyTextKeys("fmt", "attStmt", "authData") {
		return AttestedKey{}, attestFail("attestation keys")
	}
	fmtValue, _ := obj.textKey("fmt")
	if fmtValue.Kind != kindText || fmtValue.Text != AttestationFormat {
		return AttestedKey{}, attestFail("fmt")
	}
	authRaw, _ := obj.textKey("authData")
	if authRaw.Kind != kindBytes {
		return AttestedKey{}, attestFail("authData")
	}
	stmt, _ := obj.textKey("attStmt")
	if !stmt.onlyTextKeys("x5c", "receipt") {
		return AttestedKey{}, attestFail("attStmt keys")
	}
	x5c, _ := stmt.textKey("x5c")
	if x5c.Kind != kindArray || len(x5c.Array) < 2 {
		return AttestedKey{}, attestFail("x5c")
	}
	receipt, _ := stmt.textKey("receipt")
	if receipt.Kind != kindBytes || len(receipt.Bytes) == 0 {
		return AttestedKey{}, attestFail("receipt")
	}
	// Step 3: chain to the pinned root.
	certs := make([]*x509.Certificate, 0, len(x5c.Array))
	for i, value := range x5c.Array {
		if value.Kind != kindBytes {
			return AttestedKey{}, attestFail("x5c[%d] type", i)
		}
		cert, err := x509.ParseCertificate(value.Bytes)
		if err != nil {
			return AttestedKey{}, attestFail("x5c[%d]: %v", i, err)
		}
		certs = append(certs, cert)
	}
	leaf := certs[0]
	if err := verifyChain(leaf, certs[1:], in.Root, in.Now); err != nil {
		return AttestedKey{}, attestFail("chain: %v", err)
	}
	// Step 4: leaf key and keyId.
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return AttestedKey{}, attestFail("leaf key is not P-256")
	}
	point, err := pub.Bytes()
	if err != nil || len(point) != 65 || point[0] != 0x04 {
		return AttestedKey{}, attestFail("leaf key encoding")
	}
	keyHash := sha256.Sum256(point)
	if subtle.ConstantTimeCompare(keyHash[:], in.KeyID) != 1 {
		return AttestedKey{}, attestFail("keyId does not match the leaf key")
	}
	// Step 5: nonce extension.
	nonceInput := make([]byte, 0, len(authRaw.Bytes)+len(in.ClientDataHash))
	nonceInput = append(nonceInput, authRaw.Bytes...)
	nonceInput = append(nonceInput, in.ClientDataHash...)
	nonce := sha256.Sum256(nonceInput)
	nonceExt, count := findExtension(leaf, oidNonce)
	if count != 1 {
		return AttestedKey{}, attestFail("nonce extension count %d", count)
	}
	gotNonce, err := nonceOctets(nonceExt)
	if err != nil || len(gotNonce) != sha256.Size || !bytes.Equal(gotNonce, nonce[:]) {
		return AttestedKey{}, attestFail("nonce extension")
	}
	// Step 6: authenticator data.
	auth, err := parseAttestationAuthData(authRaw.Bytes)
	if err != nil {
		return AttestedKey{}, attestFail("authData: %v", err)
	}
	rp := sha256.Sum256([]byte(in.AppID))
	if !bytes.Equal(auth.rpIDHash, rp[:]) {
		return AttestedKey{}, attestFail("rpIdHash does not match the App ID")
	}
	if auth.flags&authFlagAT == 0 {
		return AttestedKey{}, attestFail("AT flag")
	}
	if auth.counter != 0 {
		return AttestedKey{}, attestFail("counter is not 0")
	}
	if !bytes.Equal(auth.aaguid, productionAAGUID[:]) {
		return AttestedKey{}, attestFail("aaguid is not production")
	}
	if len(auth.credentialID) != KeyIDBytes || !bytes.Equal(auth.credentialID, in.KeyID) {
		return AttestedKey{}, attestFail("credentialId")
	}
	if err := coseMatches(auth.cose, pub); err != nil {
		return AttestedKey{}, attestFail("%v", err)
	}
	// Step 7: optional extensions map. Real macOS 27 Developer ID
	// attestations carry none.
	if auth.hasExtensions && !policy.anyCategory {
		if raw, ok := auth.extensions.textKey("apple_validation_category_01"); ok {
			category, err := validationCategory(raw)
			if err != nil || category != validationCategoryDeveloperID {
				return AttestedKey{}, attestFail("validation category")
			}
		}
	}
	// Step 8: aclBlob.
	if !policy.skipACL {
		aclExt, count := findExtension(leaf, oidACL)
		if count != 1 {
			return AttestedKey{}, fmt.Errorf("%w: extension count %d", ErrACLMismatch, count)
		}
		got, err := aclOctets(aclExt)
		if err != nil || !bytes.Equal(got, requiredACL) {
			return AttestedKey{}, fmt.Errorf("%w: value", ErrACLMismatch)
		}
	}
	return AttestedKey{PublicKey: point}, nil
}

func verifyChain(leaf *x509.Certificate, intermediates []*x509.Certificate, root *x509.Certificate, now time.Time) error {
	if len(intermediates) == 0 {
		return errors.New("missing intermediate")
	}
	if !root.IsCA || !root.BasicConstraintsValid {
		return errors.New("trust anchor is not a CA")
	}
	if err := checkValidity(root, now); err != nil {
		return fmt.Errorf("root: %w", err)
	}
	if leaf.IsCA {
		return errors.New("leaf is a CA")
	}
	parent := root
	for i := len(intermediates) - 1; i >= 0; i-- {
		inter := intermediates[i]
		if !inter.IsCA || !inter.BasicConstraintsValid {
			return fmt.Errorf("intermediate %d is not a CA", i)
		}
		if err := checkValidity(inter, now); err != nil {
			return fmt.Errorf("intermediate %d: %w", i, err)
		}
		if err := inter.CheckSignatureFrom(parent); err != nil {
			return fmt.Errorf("intermediate %d signature: %w", i, err)
		}
		parent = inter
	}
	if err := checkValidity(leaf, now); err != nil {
		return fmt.Errorf("leaf: %w", err)
	}
	if err := leaf.CheckSignatureFrom(parent); err != nil {
		return fmt.Errorf("leaf signature: %w", err)
	}
	return nil
}

func checkValidity(cert *x509.Certificate, now time.Time) error {
	if now.Add(certSkew).Before(cert.NotBefore) {
		return errors.New("not yet valid")
	}
	if now.Add(-certSkew).After(cert.NotAfter) {
		return errors.New("expired")
	}
	return nil
}

// findExtension returns the first matching extension value and how many
// times the OID occurs.
func findExtension(cert *x509.Certificate, oid asn1.ObjectIdentifier) ([]byte, int) {
	var value []byte
	count := 0
	for _, ext := range cert.Extensions {
		if ext.Id.Equal(oid) {
			if count == 0 {
				value = ext.Value
			}
			count++
		}
	}
	return value, count
}

type attestationAuth struct {
	rpIDHash      []byte
	flags         byte
	counter       uint32
	aaguid        []byte
	credentialID  []byte
	cose          cborValue
	extensions    cborValue
	hasExtensions bool
}

// parseAttestationAuthData requires attested credential data, then at most
// one trailing CBOR extensions map.
func parseAttestationAuthData(data []byte) (attestationAuth, error) {
	if len(data) < authHeaderBytes+18 {
		return attestationAuth{}, errors.New("too short")
	}
	info := attestationAuth{
		rpIDHash: append([]byte(nil), data[:32]...),
		flags:    data[32],
		counter:  binary.BigEndian.Uint32(data[33:37]),
	}
	rest := data[authHeaderBytes:]
	info.aaguid = append([]byte(nil), rest[:16]...)
	credLen := int(binary.BigEndian.Uint16(rest[16:18]))
	rest = rest[18:]
	if credLen > len(rest) {
		return attestationAuth{}, errors.New("credentialId truncated")
	}
	info.credentialID = append([]byte(nil), rest[:credLen]...)
	rest = rest[credLen:]
	cose, n, err := decodeCBORPrefix(rest)
	if err != nil {
		return attestationAuth{}, fmt.Errorf("credential public key: %w", err)
	}
	info.cose = cose
	rest = rest[n:]
	if len(rest) == 0 {
		return info, nil
	}
	ext, err := decodeCBOR(rest)
	if err != nil || ext.Kind != kindMap {
		return attestationAuth{}, errors.New("extensions are not exactly one CBOR map")
	}
	info.extensions = ext
	info.hasExtensions = true
	return info, nil
}

func coseMatches(cose cborValue, pub *ecdsa.PublicKey) error {
	if cose.Kind != kindMap {
		return errors.New("cose key is not a map")
	}
	kty, ok := cose.intKey(1)
	if !ok || kty.Kind != kindUint || kty.Uint != 2 {
		return errors.New("cose kty is not EC2")
	}
	alg, ok := cose.intKey(3)
	if !ok || alg.Kind != kindNeg || alg.Neg != -7 {
		return errors.New("cose alg is not ES256")
	}
	crv, ok := cose.intKey(-1)
	if !ok || crv.Kind != kindUint || crv.Uint != 1 {
		return errors.New("cose crv is not P-256")
	}
	x, okX := cose.intKey(-2)
	y, okY := cose.intKey(-3)
	if !okX || !okY || x.Kind != kindBytes || y.Kind != kindBytes {
		return errors.New("cose coordinates missing")
	}
	if !bytes.Equal(x.Bytes, pub.X.FillBytes(make([]byte, 32))) || !bytes.Equal(y.Bytes, pub.Y.FillBytes(make([]byte, 32))) {
		return errors.New("cose key does not match the leaf key")
	}
	return nil
}

// validationCategory reads apple_validation_category_01, which Apple's
// published sample encodes as a 4-byte little-endian byte string.
func validationCategory(raw cborValue) (uint32, error) {
	switch raw.Kind {
	case kindUint:
		if raw.Uint > 0xffffffff {
			return 0, errors.New("category overflows uint32")
		}
		return uint32(raw.Uint), nil
	case kindBytes:
		if len(raw.Bytes) != 4 {
			return 0, errors.New("category byte string length")
		}
		return binary.LittleEndian.Uint32(raw.Bytes), nil
	default:
		return 0, errors.New("category type")
	}
}
