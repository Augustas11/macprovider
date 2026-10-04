package appattest

import (
	"bytes"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"sync"
)

// The Apple App Attestation Root CA, fetched from
// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.crt
// on 2026-10-04. It is compiled in (SPEC-049-R028 step 3, SPEC-049-R034) and
// checked against the SPEC-049 §4.1 fingerprint before first use.
//
//go:embed Apple_App_Attestation_Root_CA.crt
var appleRootPEM []byte

// AppleRootFingerprint is SHA-256 of the root's DER encoding (SPEC-049 §4.1).
const AppleRootFingerprint = "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932"

var (
	appleRootOnce sync.Once
	appleRoot     *x509.Certificate
	appleRootErr  error
)

// AppleRoot returns the compiled trust anchor. A substituted or corrupted
// root fails here, and callers must then refuse every attestation.
func AppleRoot() (*x509.Certificate, error) {
	appleRootOnce.Do(func() {
		appleRoot, appleRootErr = parsePinnedRoot(appleRootPEM, AppleRootFingerprint)
	})
	return appleRoot, appleRootErr
}

func parsePinnedRoot(raw []byte, fingerprint string) (*x509.Certificate, error) {
	block, rest := pem.Decode(raw)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("appattest: root PEM did not contain a certificate")
	}
	if len(bytes.TrimSpace(rest)) != 0 {
		return nil, errors.New("appattest: root PEM has trailing data")
	}
	sum := sha256.Sum256(block.Bytes)
	if hex.EncodeToString(sum[:]) != fingerprint {
		return nil, errors.New("appattest: root fingerprint does not match the pinned value")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("appattest: parse root: %w", err)
	}
	if !cert.IsCA || !cert.BasicConstraintsValid {
		return nil, errors.New("appattest: root is not a CA certificate")
	}
	if err := cert.CheckSignatureFrom(cert); err != nil {
		return nil, fmt.Errorf("appattest: root is not self-signed: %w", err)
	}
	return cert, nil
}
