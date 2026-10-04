package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"strings"
	"time"
)

// Apple's attestation nonce extension. The value is
// SEQUENCE { [1] EXPLICIT OCTET STRING } and the octet string is
// SHA256(authData || clientDataHash).
var oidAttestNonce = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}

// aclBlob, the macOS key access-control extension. Apple's published sample
// leaf wraps the policy as SEQUENCE { [3] EXPLICIT OCTET STRING }; Apple's
// text only says "a sequence with a single octet string", so extraction
// accepts the octet string directly or under one explicit context tag.
var oidAttestACL = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 6}

// aclFullSecurityB64 is the aclBlob octet string Apple documents for a key
// attested on macOS with SIP and Full Security both enabled. Apple: "Attested
// keys on macOS should only be trusted for this exact hash value."
const aclFullSecurityB64 = "MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB"

// ACLPolicy decides what a missing or non-matching aclBlob does.
type ACLPolicy string

const (
	// ACLRequire fails unless the aclBlob octet string equals aclFullSecurityB64.
	ACLRequire ACLPolicy = "require"
	// ACLRecord reports the aclBlob without failing on it.
	ACLRecord ACLPolicy = "record"
)

func parseACLPolicy(value string) (ACLPolicy, error) {
	switch ACLPolicy(value) {
	case ACLRequire, ACLRecord:
		return ACLPolicy(value), nil
	default:
		return "", fmt.Errorf("acl must be require or record")
	}
}

const (
	authFlagAT     = 0x40
	attestTimeSkew = 5 * time.Minute
	attestFmt      = "apple-appattest"
)

// Production aaguid is the 8 bytes "appattest" followed by 7 zero bytes.
// Development aaguid is the 16 bytes "appattestdevelop".
var (
	aaguidProduction  = [16]byte{'a', 'p', 'p', 'a', 't', 't', 'e', 's', 't'}
	aaguidDevelopment = [16]byte{'a', 'p', 'p', 'a', 't', 't', 'e', 's', 't', 'd', 'e', 'v', 'e', 'l', 'o', 'p'}
)

// Environment selects the App Attest aaguid and the default validation category.
type Environment string

const (
	EnvProduction  Environment = "production"
	EnvDevelopment Environment = "development"
)

func parseEnvironment(value string) (Environment, error) {
	switch Environment(value) {
	case EnvProduction, EnvDevelopment:
		return Environment(value), nil
	default:
		return "", fmt.Errorf("env must be production or development")
	}
}

func (e Environment) aaguid() ([16]byte, error) {
	switch e {
	case EnvProduction:
		return aaguidProduction, nil
	case EnvDevelopment:
		return aaguidDevelopment, nil
	default:
		return [16]byte{}, fmt.Errorf("env must be production or development")
	}
}

// defaultCategory is the apple_validation_category_01 value Apple documents
// for this spike's signing identity: 6 Developer ID, 3 development identity.
func (e Environment) defaultCategory() uint32 {
	if e == EnvDevelopment {
		return 3
	}
	return 6
}

// CategoryPolicy decides how apple_validation_category_01 is checked.
// Categories 0, 7, 8, and 9 are always rejected. Any records the value.
// Otherwise Value must match.
type CategoryPolicy struct {
	Any   bool
	Value uint32
}

// AttestInput is one server-side attestation check.
// ClientDataHash is the exact value the app passed to attestKey. The spike app
// passes SHA-256 of its one-time nonce; the CLI computes that from nonce_b64.
type AttestInput struct {
	Attestation    []byte
	KeyID          []byte
	ClientDataHash []byte
	Team           string
	Bundle         string
	Env            Environment
	Category       CategoryPolicy
	BundleVersion  string
	ACL            ACLPolicy
	Now            time.Time
	Root           *x509.Certificate
}

// AttestReport is the public result of an attestation check.
// PublicKey is returned for assertion verification; callers must not print it.
type AttestReport struct {
	AppID                 string
	RPIDHash              []byte
	AAGUID                string
	Counter               uint32
	Flags                 byte
	Leaf                  *x509.Certificate
	PublicKey             *ecdsa.PublicKey
	PublicKeySHA256       []byte
	ValidationCategory    uint32
	HasCategory           bool
	BundleVersion         string
	ACLPresent            bool
	ACLRaw                []byte
	ACLDump               string
	ACLInner              []byte
	ACLInnerDump          string
	ACLFullSecurity       bool
	ReceiptLen            int
	ReceiptSequencePrefix bool
	CertCount             int
}

type authInfo struct {
	RPIDHash      []byte
	Flags         byte
	Counter       uint32
	AAGUID        []byte
	CredentialID  []byte
	COSE          Value
	HasCredential bool
	Extensions    Value
	HasExtensions bool
}

func appID(team, bundle string) (string, error) {
	if team == "" || bundle == "" {
		return "", fmt.Errorf("team and bundle are required")
	}
	if strings.ContainsAny(team, " \t\r\n\"") || strings.ContainsAny(bundle, " \t\r\n\"") {
		return "", fmt.Errorf("team or bundle contains whitespace or quotes")
	}
	return team + "." + bundle, nil
}

// VerifyAttestation performs Apple's documented attestation checks against
// the supplied trust anchor. Receipt fraud-metric calls are out of scope;
// the receipt only has to be present.
func VerifyAttestation(in AttestInput) (AttestReport, error) {
	var report AttestReport
	if in.Now.IsZero() {
		in.Now = time.Now()
	}
	if in.Root == nil {
		return report, fmt.Errorf("trust anchor is required")
	}
	id, err := appID(in.Team, in.Bundle)
	if err != nil {
		return report, err
	}
	report.AppID = id
	if len(in.ClientDataHash) == 0 {
		return report, fmt.Errorf("clientDataHash is empty")
	}
	if in.ACL == "" {
		in.ACL = ACLRequire
	}
	if _, err := parseACLPolicy(string(in.ACL)); err != nil {
		return report, err
	}
	if len(in.KeyID) == 0 {
		return report, fmt.Errorf("key id is empty")
	}

	obj, err := Decode(in.Attestation)
	if err != nil {
		return report, fmt.Errorf("attestation cbor: %w", err)
	}
	if obj.Kind != KindMap {
		return report, fmt.Errorf("attestation object is not a map")
	}
	fmtValue, ok := obj.TextKey("fmt")
	if !ok || fmtValue.Kind != KindText || fmtValue.Text != attestFmt {
		return report, fmt.Errorf("fmt is not %s", attestFmt)
	}
	authRaw, ok := obj.TextKey("authData")
	if !ok || authRaw.Kind != KindBytes {
		return report, fmt.Errorf("authData is missing")
	}
	stmt, ok := obj.TextKey("attStmt")
	if !ok || stmt.Kind != KindMap {
		return report, fmt.Errorf("attStmt is missing")
	}
	x5c, ok := stmt.TextKey("x5c")
	if !ok || x5c.Kind != KindArray || len(x5c.Array) < 2 {
		return report, fmt.Errorf("x5c must contain the leaf and at least one intermediate")
	}
	receipt, ok := stmt.TextKey("receipt")
	if !ok || receipt.Kind != KindBytes || len(receipt.Bytes) == 0 {
		return report, fmt.Errorf("receipt is missing")
	}
	report.ReceiptLen = len(receipt.Bytes)
	report.ReceiptSequencePrefix = receipt.Bytes[0] == 0x30

	leaf, intermediates, err := parseX5C(x5c.Array)
	if err != nil {
		return report, err
	}
	report.CertCount = 1 + len(intermediates)
	report.Leaf = leaf
	if err := verifyChain(leaf, intermediates, in.Root, in.Now); err != nil {
		return report, err
	}
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return report, fmt.Errorf("leaf public key is not ECDSA P-256")
	}
	report.PublicKey = pub
	keyHash, err := publicKeyHash(pub)
	if err != nil {
		return report, err
	}
	report.PublicKeySHA256 = keyHash

	info, err := parseAuthData(authRaw.Bytes)
	if err != nil {
		return report, err
	}
	report.RPIDHash = info.RPIDHash
	report.Flags = info.Flags
	report.Counter = info.Counter
	report.AAGUID = printableAAGUID(info.AAGUID)
	if info.Flags&authFlagAT == 0 || !info.HasCredential {
		return report, fmt.Errorf("authenticator data has no attested credential")
	}
	if info.Counter != 0 {
		return report, fmt.Errorf("attestation counter is %d, want 0", info.Counter)
	}
	wantAAGUID, err := in.Env.aaguid()
	if err != nil {
		return report, err
	}
	if len(info.AAGUID) != len(wantAAGUID) || !bytesEqual(info.AAGUID, wantAAGUID[:]) {
		return report, fmt.Errorf("aaguid is %q, want %q", report.AAGUID, printableAAGUID(wantAAGUID[:]))
	}
	if !bytesEqual(info.CredentialID, keyHash) || !bytesEqual(in.KeyID, keyHash) {
		return report, fmt.Errorf("key id does not match SHA-256 of the uncompressed leaf public key")
	}
	rp := sha256.Sum256([]byte(id))
	if !bytesEqual(info.RPIDHash, rp[:]) {
		return report, fmt.Errorf("rpIdHash does not match %s", id)
	}
	if err := coseMatches(info.COSE, pub); err != nil {
		return report, err
	}

	nonceInput := make([]byte, 0, len(authRaw.Bytes)+len(in.ClientDataHash))
	nonceInput = append(nonceInput, authRaw.Bytes...)
	nonceInput = append(nonceInput, in.ClientDataHash...)
	nonce := sha256.Sum256(nonceInput)
	ext, ok := findExtension(leaf, oidAttestNonce)
	if !ok {
		return report, fmt.Errorf("leaf is missing nonce extension %s", oidAttestNonce)
	}
	gotNonce, err := explicitOctet(ext.Value, 1)
	if err != nil {
		return report, fmt.Errorf("nonce extension: %w", err)
	}
	if !bytesEqual(gotNonce, nonce[:]) {
		return report, fmt.Errorf("nonce extension does not match SHA-256(authData || clientDataHash)")
	}

	// Real macOS 27 Developer ID attestations (2026-10-04, Studio) carry no
	// authenticator extensions. With --expect-category any that is recorded,
	// not failed; every other mode still requires the extensions map.
	if !info.HasExtensions && in.Category.Any {
		goto acl
	}
	if !info.HasExtensions {
		return report, fmt.Errorf("authenticator data is missing the extensions map")
	}
	{
		category, err := validationCategory(info.Extensions)
		if err != nil {
			return report, err
		}
		report.ValidationCategory = category
		report.HasCategory = true
		version, err := extensionBundleVersion(info.Extensions)
		if err != nil {
			return report, err
		}
		report.BundleVersion = version
		if err := checkCategory(category, in.Category); err != nil {
			return report, err
		}
		if in.BundleVersion != "" && version != in.BundleVersion {
			return report, fmt.Errorf("apple_bundle_version_01 is %q, want %q", version, in.BundleVersion)
		}
	}

acl:

	if acl, ok := findExtension(leaf, oidAttestACL); ok {
		report.ACLPresent = true
		report.ACLRaw = append([]byte(nil), acl.Value...)
		dump, dumpErr := dumpDER(acl.Value)
		if dumpErr != nil {
			report.ACLDump = "der parse failed: " + dumpErr.Error()
		} else {
			report.ACLDump = dump
		}
		if inner, innerErr := singleOctet(acl.Value); innerErr == nil {
			report.ACLInner = inner
			if innerDump, err := dumpDER(inner); err == nil {
				report.ACLInnerDump = innerDump
			}
			want, _ := base64.StdEncoding.DecodeString(aclFullSecurityB64)
			report.ACLFullSecurity = bytesEqual(inner, want)
		}
	}
	if in.ACL == ACLRequire {
		if !report.ACLPresent {
			return report, fmt.Errorf("leaf is missing aclBlob extension %s", oidAttestACL)
		}
		if !report.ACLFullSecurity {
			return report, fmt.Errorf("aclBlob is not the documented SIP + Full Security value")
		}
	}
	return report, nil
}

func parseX5C(values []Value) (*x509.Certificate, []*x509.Certificate, error) {
	certs := make([]*x509.Certificate, 0, len(values))
	for i, value := range values {
		if value.Kind != KindBytes {
			return nil, nil, fmt.Errorf("x5c[%d] is not a byte string", i)
		}
		cert, err := x509.ParseCertificate(value.Bytes)
		if err != nil {
			return nil, nil, fmt.Errorf("x5c[%d]: %w", i, err)
		}
		certs = append(certs, cert)
	}
	return certs[0], certs[1:], nil
}

func verifyChain(leaf *x509.Certificate, intermediates []*x509.Certificate, root *x509.Certificate, now time.Time) error {
	if leaf == nil || root == nil {
		return fmt.Errorf("missing certificate")
	}
	if len(intermediates) == 0 {
		return fmt.Errorf("x5c is missing the intermediate")
	}
	if !root.IsCA || !root.BasicConstraintsValid {
		return fmt.Errorf("trust anchor is not a CA")
	}
	if err := checkValidity(root, now); err != nil {
		return fmt.Errorf("root: %w", err)
	}
	if leaf.IsCA {
		return fmt.Errorf("leaf certificate is a CA")
	}
	parent := root
	for i := len(intermediates) - 1; i >= 0; i-- {
		inter := intermediates[i]
		if inter == nil || !inter.IsCA || !inter.BasicConstraintsValid {
			return fmt.Errorf("intermediate %d is not a CA", i)
		}
		if err := checkValidity(inter, now); err != nil {
			return fmt.Errorf("intermediate %d: %w", i, err)
		}
		if err := inter.CheckSignatureFrom(parent); err != nil {
			return fmt.Errorf("intermediate %d was not signed by its parent: %w", i, err)
		}
		parent = inter
	}
	if err := checkValidity(leaf, now); err != nil {
		return fmt.Errorf("leaf: %w", err)
	}
	if err := leaf.CheckSignatureFrom(parent); err != nil {
		return fmt.Errorf("leaf was not signed by the intermediate: %w", err)
	}
	return nil
}

func checkValidity(cert *x509.Certificate, now time.Time) error {
	if now.Add(attestTimeSkew).Before(cert.NotBefore) {
		return fmt.Errorf("not yet valid")
	}
	if now.Add(-attestTimeSkew).After(cert.NotAfter) {
		return fmt.Errorf("expired")
	}
	return nil
}

func publicKeyHash(pub *ecdsa.PublicKey) ([]byte, error) {
	raw, err := pub.Bytes()
	if err != nil {
		return nil, fmt.Errorf("encode public key: %w", err)
	}
	if len(raw) != 65 || raw[0] != 0x04 {
		return nil, fmt.Errorf("public key is not an uncompressed P-256 point")
	}
	sum := sha256.Sum256(raw)
	out := make([]byte, len(sum))
	copy(out, sum[:])
	return out, nil
}

func parseAuthData(data []byte) (authInfo, error) {
	if len(data) < 37 {
		return authInfo{}, fmt.Errorf("authenticator data is shorter than 37 bytes")
	}
	info := authInfo{
		RPIDHash: append([]byte(nil), data[:32]...),
		Flags:    data[32],
		Counter:  binary.BigEndian.Uint32(data[33:37]),
	}
	rest := data[37:]
	// Real macOS 27 assertions keep the AT flag set but carry only the 37-byte
	// header; attested credential data is parsed only when bytes follow.
	if info.Flags&authFlagAT != 0 && len(rest) > 0 {
		if len(rest) < 18 {
			return authInfo{}, fmt.Errorf("attested credential data is truncated")
		}
		info.AAGUID = append([]byte(nil), rest[:16]...)
		credLen := int(binary.BigEndian.Uint16(rest[16:18]))
		rest = rest[18:]
		if credLen < 0 || credLen > len(rest) {
			return authInfo{}, fmt.Errorf("credentialId is truncated")
		}
		info.CredentialID = append([]byte(nil), rest[:credLen]...)
		rest = rest[credLen:]
		cose, n, err := DecodePrefix(rest)
		if err != nil {
			return authInfo{}, fmt.Errorf("credential public key: %w", err)
		}
		info.COSE = cose
		info.HasCredential = true
		rest = rest[n:]
	}
	if len(rest) == 0 {
		return info, nil
	}
	ext, n, err := DecodePrefix(rest)
	if err != nil {
		return authInfo{}, fmt.Errorf("extensions: %w", err)
	}
	if n != len(rest) {
		return authInfo{}, fmt.Errorf("authenticator data has %d trailing bytes", len(rest)-n)
	}
	if ext.Kind != KindMap {
		return authInfo{}, fmt.Errorf("extensions are not a CBOR map")
	}
	info.Extensions = ext
	info.HasExtensions = true
	return info, nil
}

func coseMatches(cose Value, pub *ecdsa.PublicKey) error {
	if cose.Kind != KindMap {
		return fmt.Errorf("credential public key is not a CBOR map")
	}
	kty, ok := cose.IntKey(1)
	if !ok || kty.Kind != KindUint || kty.Uint != 2 {
		return fmt.Errorf("cose kty is not EC2")
	}
	alg, ok := cose.IntKey(3)
	if !ok || alg.Kind != KindNeg || alg.Neg != -7 {
		return fmt.Errorf("cose alg is not ES256")
	}
	crv, ok := cose.IntKey(-1)
	if !ok || crv.Kind != KindUint || crv.Uint != 1 {
		return fmt.Errorf("cose crv is not P-256")
	}
	x, okX := cose.IntKey(-2)
	y, okY := cose.IntKey(-3)
	if !okX || !okY || x.Kind != KindBytes || y.Kind != KindBytes {
		return fmt.Errorf("cose key is missing coordinates")
	}
	xb := pub.X.FillBytes(make([]byte, 32))
	yb := pub.Y.FillBytes(make([]byte, 32))
	if !bytesEqual(x.Bytes, xb) || !bytesEqual(y.Bytes, yb) {
		return fmt.Errorf("cose key does not match the leaf public key")
	}
	return nil
}

func validationCategory(ext Value) (uint32, error) {
	raw, ok := ext.TextKey("apple_validation_category_01")
	if !ok {
		return 0, fmt.Errorf("missing apple_validation_category_01")
	}
	switch raw.Kind {
	case KindUint:
		if raw.Uint > 0xffffffff {
			return 0, fmt.Errorf("validation category overflows uint32")
		}
		return uint32(raw.Uint), nil
	case KindBytes:
		// The published attestation sample encodes this UInt32 as a 4-byte
		// little-endian byte string, not as a CBOR unsigned integer.
		if len(raw.Bytes) != 4 {
			return 0, fmt.Errorf("validation category byte string is %d bytes", len(raw.Bytes))
		}
		return binary.LittleEndian.Uint32(raw.Bytes), nil
	default:
		return 0, fmt.Errorf("validation category is not an integer or a 4-byte string")
	}
}

func extensionBundleVersion(ext Value) (string, error) {
	raw, ok := ext.TextKey("apple_bundle_version_01")
	if !ok {
		return "", fmt.Errorf("missing apple_bundle_version_01")
	}
	if raw.Kind != KindText {
		return "", fmt.Errorf("apple_bundle_version_01 is not text")
	}
	return raw.Text, nil
}

func checkCategory(value uint32, policy CategoryPolicy) error {
	switch value {
	case 0, 7, 8, 9:
		return fmt.Errorf("validation category %d is not acceptable", value)
	}
	if policy.Any {
		return nil
	}
	if value != policy.Value {
		return fmt.Errorf("validation category %d, want %d", value, policy.Value)
	}
	return nil
}

func findExtension(cert *x509.Certificate, oid asn1.ObjectIdentifier) (pkix.Extension, bool) {
	for _, ext := range cert.Extensions {
		if ext.Id.Equal(oid) {
			return ext, true
		}
	}
	return pkix.Extension{}, false
}

func printableAAGUID(aaguid []byte) string {
	end := len(aaguid)
	for end > 0 && aaguid[end-1] == 0 {
		end--
	}
	for _, b := range aaguid[:end] {
		if b < 0x20 || b > 0x7e {
			return fmt.Sprintf("%x", aaguid)
		}
	}
	if end == 0 {
		return ""
	}
	return string(aaguid[:end])
}
