package main

import (
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/pem"
	"fmt"
)

//go:embed Apple_App_Attestation_Root_CA.crt
var appleRootPEM []byte

// Pinned SHA-256 of the Apple App Attestation Root CA DER, fetched from
// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.crt
// on 2026-10-04. The test locks this so a substituted file fails closed.
const appleRootFingerprint = "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932"

func loadAppleRoot() (*x509.Certificate, error) {
	block, rest := pem.Decode(appleRootPEM)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("apple root PEM did not contain a certificate")
	}
	if len(bytesTrimSpace(rest)) != 0 {
		return nil, fmt.Errorf("apple root PEM has trailing data")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse apple root: %w", err)
	}
	if !cert.IsCA || !cert.BasicConstraintsValid {
		return nil, fmt.Errorf("apple root is not a CA certificate")
	}
	if err := cert.CheckSignatureFrom(cert); err != nil {
		return nil, fmt.Errorf("apple root is not self-signed: %w", err)
	}
	if got := fingerprint(cert); got != appleRootFingerprint {
		return nil, fmt.Errorf("apple root fingerprint %s does not match the pinned fingerprint", got)
	}
	return cert, nil
}

func fingerprint(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.Raw)
	return fmt.Sprintf("%x", sum[:])
}

func bytesTrimSpace(in []byte) []byte {
	start := 0
	for start < len(in) {
		switch in[start] {
		case ' ', '\n', '\r', '\t':
			start++
		default:
			return in[start:]
		}
	}
	return nil
}
