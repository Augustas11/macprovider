package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var (
	testMDAOIDOSVersion = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 1}
	testMDAOIDFreshness = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 11, 1}
)

func TestMakeAndCheckArtifactWithCoordinatorVerification(t *testing.T) {
	dir := t.TempDir()
	now := time.Unix(1716768000, 0).UTC()
	challenge := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, 32))
	providerECDH := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x24}, 32))

	rootPEM, leafPEM, csrPEM := testMDAEvidence(t, now, challenge)
	rootPath := filepath.Join(dir, "root.pem")
	leafPath := filepath.Join(dir, "leaf.pem")
	csrPath := filepath.Join(dir, "leaf.csr")
	artifactPath := filepath.Join(dir, "mda.json")
	writeTestFile(t, rootPath, rootPEM)
	writeTestFile(t, leafPath, leafPEM)
	writeTestFile(t, csrPath, csrPEM)

	var makeOut bytes.Buffer
	if err := run([]string{
		"make",
		"--cert", leafPath,
		"--csr", csrPath,
		"--out", artifactPath,
	}, &makeOut, ioDiscard{}); err != nil {
		t.Fatalf("make artifact: %v", err)
	}
	if !strings.Contains(makeOut.String(), `"certificate_chain_count": 1`) {
		t.Fatalf("make summary missing chain count: %s", makeOut.String())
	}

	var contractOut bytes.Buffer
	if err := run([]string{
		"check",
		"--artifact", artifactPath,
	}, &contractOut, ioDiscard{}); err != nil {
		t.Fatalf("contract-only check: %v", err)
	}
	if !strings.Contains(contractOut.String(), `"coordinator_verified": false`) {
		t.Fatalf("contract-only summary should not claim coordinator verification: %s", contractOut.String())
	}

	if err := run([]string{
		"check",
		"--artifact", artifactPath,
		"--root", rootPath,
		"--challenge", challenge,
		"--provider-id", "provider-a",
		"--provider-ecdh-public-key", providerECDH,
		"--now", now.Format(time.RFC3339),
	}, ioDiscard{}, ioDiscard{}); err == nil || !strings.Contains(err.Error(), `coordinator verifier returned "attestation_failed"`) {
		t.Fatalf("full check err=%v, want fail-closed without binding signature", err)
	}
}

func TestCheckArtifactRejectsMismatchedFreshnessChallenge(t *testing.T) {
	dir := t.TempDir()
	now := time.Unix(1716768000, 0).UTC()
	challenge := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, 32))
	wrongChallenge := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x43}, 32))
	providerECDH := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x24}, 32))

	rootPEM, leafPEM, csrPEM := testMDAEvidence(t, now, challenge)
	rootPath := filepath.Join(dir, "root.pem")
	leafPath := filepath.Join(dir, "leaf.pem")
	csrPath := filepath.Join(dir, "leaf.csr")
	artifactPath := filepath.Join(dir, "mda.json")
	writeTestFile(t, rootPath, rootPEM)
	writeTestFile(t, leafPath, leafPEM)
	writeTestFile(t, csrPath, csrPEM)
	if err := run([]string{
		"make",
		"--cert", leafPath,
		"--csr", csrPath,
		"--out", artifactPath,
	}, ioDiscard{}, ioDiscard{}); err != nil {
		t.Fatalf("make artifact: %v", err)
	}

	err := run([]string{
		"check",
		"--artifact", artifactPath,
		"--root", rootPath,
		"--challenge", wrongChallenge,
		"--provider-id", "provider-a",
		"--provider-ecdh-public-key", providerECDH,
		"--now", now.Format(time.RFC3339),
	}, ioDiscard{}, ioDiscard{})
	if err == nil {
		t.Fatal("expected mismatched freshness challenge to fail")
	}
	if !strings.Contains(err.Error(), `coordinator verifier returned "attestation_failed"`) {
		t.Fatalf("unexpected error: %v", err)
	}
}

type ioDiscard struct{}

func (ioDiscard) Write(p []byte) (int, error) { return len(p), nil }

func testMDAEvidence(t *testing.T, now time.Time, challenge string) ([]byte, []byte, []byte) {
	t.Helper()
	rootPub, rootPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate root key: %v", err)
	}
	root := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Apple Enterprise Attestation Root CA"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		IsCA:                  true,
		BasicConstraintsValid: true,
	}
	rootDER, err := x509.CreateCertificate(rand.Reader, root, root, rootPub, rootPriv)
	if err != nil {
		t.Fatalf("create root certificate: %v", err)
	}

	leafPriv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate leaf key: %v", err)
	}
	freshness := sha256.Sum256([]byte(challenge))
	leaf := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "Managed Device Attestation Leaf"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		ExtraExtensions: []pkix.Extension{
			{Id: testMDAOIDFreshness, Value: freshness[:]},
			{Id: testMDAOIDOSVersion, Value: []byte("macOS 14.5")},
		},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, root, leafPriv.Public(), rootPriv)
	if err != nil {
		t.Fatalf("create leaf certificate: %v", err)
	}
	csrDER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject: pkix.Name{CommonName: "Managed Device Attestation CSR"},
	}, leafPriv)
	if err != nil {
		t.Fatalf("create CSR: %v", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: rootDER}),
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER}),
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: csrDER})
}

func writeTestFile(t *testing.T, path string, body []byte) {
	t.Helper()
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
