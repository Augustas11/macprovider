package onboarding

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"math/big"
	"testing"
	"time"
)

func TestAppleAppAttestVerifierAcceptsValidObject(t *testing.T) {
	fixture := newAppAttestFixture(t)
	ok, err := fixture.verifier.Verify(t.Context(), fixture.evidence)
	if err != nil {
		t.Fatalf("Verify error: %v", err)
	}
	if !ok {
		t.Fatal("Verify returned false")
	}
}

func TestAppleAppAttestationRootPEMParses(t *testing.T) {
	cert, err := parseSinglePEMCert([]byte(appleAppAttestationRootCAPEM))
	if err != nil {
		t.Fatalf("parse Apple App Attestation Root CA: %v", err)
	}
	if cert.Subject.CommonName != "Apple App Attestation Root CA" || !cert.IsCA {
		t.Fatalf("unexpected root certificate subject=%q isCA=%v", cert.Subject.CommonName, cert.IsCA)
	}
}

func TestAppleAppAttestVerifierRejectsBindingFailures(t *testing.T) {
	fixture := newAppAttestFixture(t)
	for _, tc := range []struct {
		name   string
		mutate func(*AppAttestEvidence, *AppleAppAttestVerifier)
	}{
		{
			name: "key id mismatch",
			mutate: func(e *AppAttestEvidence, v *AppleAppAttestVerifier) {
				e.KeyID = bytes.Repeat([]byte{0x99}, 32)
			},
		},
		{
			name: "client data hash mismatch",
			mutate: func(e *AppAttestEvidence, v *AppleAppAttestVerifier) {
				e.ClientDataHash = sha256.Sum256([]byte("different request binding"))
			},
		},
		{
			name: "app id hash mismatch",
			mutate: func(e *AppAttestEvidence, v *AppleAppAttestVerifier) {
				v.Config.TeamID = "OTHERTEAM"
			},
		},
		{
			name: "malformed cbor",
			mutate: func(e *AppAttestEvidence, v *AppleAppAttestVerifier) {
				e.Object = []byte{0xbf}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			evidence := fixture.evidence
			evidence.Object = append([]byte(nil), evidence.Object...)
			evidence.KeyID = append([]byte(nil), evidence.KeyID...)
			verifier := fixture.verifier
			tc.mutate(&evidence, &verifier)
			ok, err := verifier.Verify(t.Context(), evidence)
			if ok || !errors.Is(err, ErrAppAttestBinding) {
				t.Fatalf("Verify ok=%v err=%v, want binding failure", ok, err)
			}
		})
	}
}

func TestAppAttestCBORRejectsDepthNine(t *testing.T) {
	raw := cborText("leaf")
	for i := 0; i < cborMaxDepth+1; i++ {
		raw = cborArray(raw)
	}
	if _, _, err := newCBORDecoder(raw).parse(); err == nil {
		t.Fatal("depth-9 CBOR parsed successfully")
	}
}

type appAttestFixture struct {
	verifier AppleAppAttestVerifier
	evidence AppAttestEvidence
}

func newAppAttestFixture(t *testing.T) appAttestFixture {
	t.Helper()
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	rootKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate root key: %v", err)
	}
	rootTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Test App Attestation Root"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	rootDER, err := x509.CreateCertificate(rand.Reader, rootTemplate, rootTemplate, &rootKey.PublicKey, rootKey)
	if err != nil {
		t.Fatalf("create root cert: %v", err)
	}
	attestKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate attest key: %v", err)
	}
	keyID := bytes.Repeat([]byte{0x42}, 32)
	clientHash := sha256.Sum256([]byte("SPEC-026 request binding"))
	authData := buildTestAuthData(t, "TEAM12345.tech.malibu.app", keyID, attestKey)
	nonceInput := append(append([]byte(nil), authData...), clientHash[:]...)
	nonce := sha256.Sum256(nonceInput)
	nonceDER, err := asn1.Marshal(nonce[:])
	if err != nil {
		t.Fatalf("marshal nonce extension: %v", err)
	}
	leafTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "Test App Attestation Leaf"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{
			{Id: appleAppAttestNonceOID, Value: nonceDER},
		},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, rootTemplate, &attestKey.PublicKey, rootKey)
	if err != nil {
		t.Fatalf("create leaf cert: %v", err)
	}
	object := cborMap(
		cborText("fmt"), cborText("apple-appattest"),
		cborText("authData"), cborBytes(authData),
		cborText("attStmt"), cborMap(
			cborText("x5c"), cborArray(cborBytes(leafDER)),
		),
	)
	rootPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: rootDER})
	return appAttestFixture{
		verifier: AppleAppAttestVerifier{
			Config: AppAttestConfig{
				TeamID:   "TEAM12345",
				BundleID: "tech.malibu.app",
			},
			RootCertPEM: rootPEM,
			Now: func() time.Time {
				return now
			},
		},
		evidence: AppAttestEvidence{
			Object:         object,
			KeyID:          keyID,
			ClientDataHash: clientHash,
		},
	}
}

func buildTestAuthData(t *testing.T, appID string, keyID []byte, key *ecdsa.PrivateKey) []byte {
	t.Helper()
	appIDHash := sha256.Sum256([]byte(appID))
	coseKey := cborMap(
		cborInt(1), cborInt(2),
		cborInt(3), cborInt(-7),
		cborInt(-1), cborInt(1),
		cborInt(-2), cborBytes(leftPad32(key.X.Bytes())),
		cborInt(-3), cborBytes(leftPad32(key.Y.Bytes())),
	)
	out := make([]byte, 0, 37+16+2+len(keyID)+len(coseKey))
	out = append(out, appIDHash[:]...)
	out = append(out, authDataFlagAttestedCredential)
	out = append(out, 0, 0, 0, 0)
	out = append(out, []byte("appattest")...)
	out = append(out, make([]byte, 7)...)
	lenBuf := make([]byte, 2)
	binary.BigEndian.PutUint16(lenBuf, uint16(len(keyID)))
	out = append(out, lenBuf...)
	out = append(out, keyID...)
	out = append(out, coseKey...)
	return out
}

func leftPad32(in []byte) []byte {
	out := make([]byte, 32)
	copy(out[32-len(in):], in)
	return out
}

func cborMap(parts ...[]byte) []byte {
	out := cborTypeLen(5, uint64(len(parts)/2))
	for _, part := range parts {
		out = append(out, part...)
	}
	return out
}

func cborArray(parts ...[]byte) []byte {
	out := cborTypeLen(4, uint64(len(parts)))
	for _, part := range parts {
		out = append(out, part...)
	}
	return out
}

func cborText(s string) []byte {
	return append(cborTypeLen(3, uint64(len(s))), []byte(s)...)
}

func cborBytes(b []byte) []byte {
	return append(cborTypeLen(2, uint64(len(b))), b...)
}

func cborInt(n int64) []byte {
	if n >= 0 {
		return cborTypeLen(0, uint64(n))
	}
	return cborTypeLen(1, uint64(-1-n))
}

func cborTypeLen(major byte, n uint64) []byte {
	prefix := major << 5
	switch {
	case n <= 23:
		return []byte{prefix | byte(n)}
	case n <= 0xff:
		return []byte{prefix | 24, byte(n)}
	case n <= 0xffff:
		out := []byte{prefix | 25, 0, 0}
		binary.BigEndian.PutUint16(out[1:], uint16(n))
		return out
	case n <= 0xffffffff:
		out := []byte{prefix | 26, 0, 0, 0, 0}
		binary.BigEndian.PutUint32(out[1:], uint32(n))
		return out
	default:
		out := []byte{prefix | 27, 0, 0, 0, 0, 0, 0, 0, 0}
		binary.BigEndian.PutUint64(out[1:], n)
		return out
	}
}
