package appattest

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"errors"
	"os"
	"testing"
)

// realStudioResult is the public material of the #1840 hardware spike:
// macOS 27.0.1 (26A434), Developer ID Malibu.app, team YF7XNRJUG4.
type realStudioResult struct {
	AttestationB64 string `json:"attestation_b64"`
	KeyID          string `json:"key_id"`
	NonceB64       string `json:"nonce_b64"`
	Assertions     []struct {
		AssertionB64  string `json:"assertion_b64"`
		ClientData    string `json:"client_data"`
		ClientDataB64 string `json:"client_data_b64"`
	} `json:"assertions"`
}

const realStudioAppID = "YF7XNRJUG4.tech.malibu.app"

// TestRealMacOS27Attestation verifies the real hardware attestation under
// the strict production policy: pinned Apple root, production aaguid,
// counter 0, the SIP and Full Security aclBlob, and no extensions map.
func TestRealMacOS27Attestation(t *testing.T) {
	raw, err := os.ReadFile("testdata/macos27-studio-2026-10-04.json")
	if err != nil {
		t.Fatal(err)
	}
	var result realStudioResult
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	attestation := mustStd(t, result.AttestationB64)
	keyID := mustStd(t, result.KeyID)
	nonce := mustStd(t, result.NonceB64)
	if len(nonce) != 32 || len(keyID) != KeyIDBytes {
		t.Fatalf("nonce %d bytes, keyId %d bytes", len(nonce), len(keyID))
	}
	// SpikeApp.swift: clientDataHash = SHA256.hash(data: nonce), over the
	// 32 decoded nonce bytes.
	clientDataHash := sha256.Sum256(nonce)
	root, err := AppleRoot()
	if err != nil {
		t.Fatal(err)
	}
	leaf := realLeaf(t, attestation)
	now := leaf.NotBefore.Add(leaf.NotAfter.Sub(leaf.NotBefore) / 2)
	in := AttestationInput{
		Attestation: attestation, KeyID: keyID, ClientDataHash: clientDataHash[:],
		AppID: realStudioAppID, Now: now, Root: root,
	}
	key, err := VerifyAttestation(in)
	if err != nil {
		t.Fatalf("strict policy rejected the real macOS 27 attestation: %v", err)
	}
	// The real vector carries no authenticator extensions map.
	obj, err := decodeCBOR(attestation)
	if err != nil {
		t.Fatal(err)
	}
	authData, _ := obj.textKey("authData")
	auth, err := parseAttestationAuthData(authData.Bytes)
	if err != nil || auth.hasExtensions {
		t.Fatalf("authData extensions present=%v err=%v", auth.hasExtensions, err)
	}

	if len(result.Assertions) < 2 {
		t.Fatalf("%d assertions", len(result.Assertions))
	}
	var previous uint32
	for i, item := range result.Assertions {
		clientData := mustStd(t, item.ClientDataB64)
		if string(clientData) != item.ClientData {
			t.Fatalf("assertion %d client_data_b64 differs from client_data", i)
		}
		hash := sha256.Sum256(clientData)
		counter, err := VerifyAssertion(AssertionInput{
			Assertion: mustStd(t, item.AssertionB64), PublicKey: key.PublicKey,
			ClientDataHash: hash[:], AppID: realStudioAppID,
		})
		if err != nil {
			t.Fatalf("real assertion %d: %v", i, err)
		}
		if counter <= previous {
			t.Fatalf("assertion %d counter %d does not increase past %d", i, counter, previous)
		}
		previous = counter
	}

	// Single mutation: the same attestation checked against another team's
	// App ID (a different rpIdHash) must fail.
	other := in
	other.AppID = "ZZZZZ99999.tech.malibu.app"
	if _, err := VerifyAttestation(other); !errors.Is(err, ErrAttestationInvalid) {
		t.Fatalf("other team rpIdHash: err=%v", err)
	}
}

func realLeaf(t *testing.T, attestation []byte) *x509.Certificate {
	t.Helper()
	obj, err := decodeCBOR(attestation)
	if err != nil {
		t.Fatal(err)
	}
	stmt, _ := obj.textKey("attStmt")
	x5c, _ := stmt.textKey("x5c")
	if len(x5c.Array) == 0 {
		t.Fatal("no x5c")
	}
	leaf, err := x509.ParseCertificate(x5c.Array[0].Bytes)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("leaf validity %s .. %s", leaf.NotBefore.UTC(), leaf.NotAfter.UTC())
	return leaf
}
