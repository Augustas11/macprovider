package relayblind

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

const rotationFixtureRel = "../../../test/fixtures/relay-blind/privacy-key-rotation-v1.json"

// rotationVector is the shared Go/Swift SPEC-049 §4.12 framing vector.
// ECDSA signatures are randomized, so the vector pins framing and digests and
// carries only the deterministic Ed25519 signatures.
type rotationVector struct {
	Version                   string               `json:"version"`
	Posture                   PostureStatement     `json:"posture"`
	PostureDigest             string               `json:"posture_digest"`
	Statement                 KeyRotationStatement `json:"statement"`
	RotationFramingHex        string               `json:"rotation_framing_hex"`
	PreviousIdentitySignature string               `json:"previous_identity_signature"`
	IdentitySignature         string               `json:"identity_signature"`
}

func rotationFixtureBytes(t *testing.T) []byte {
	t.Helper()
	previous := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x01}, ed25519.SeedSize))
	next := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x02}, ed25519.SeedSize))
	posture := testPosture("xPyccfRu3euY3JtLkfdfuR5x2vDS7c4jjS1C0f1v6Yo")
	posture.ProviderID, posture.AssignedSession = "provider-fixture", "session-fixture"
	posture.Nonce = encodeBase64URL(bytes.Repeat([]byte{0x5a}, 32))
	posture.Sequence, posture.IssuedAtUnix = 7, 1_700_000_000
	digest, err := PostureDigest(posture)
	if err != nil {
		t.Fatal(err)
	}
	se := make([]byte, 64)
	seRaw, _ := hex.DecodeString("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
	copy(se, seRaw)
	statement := KeyRotationStatement{
		Version: PrivacyKeyRotationVersion, PrivacyClass: PrivacyClassV1, ProviderID: posture.ProviderID, AssignedSession: posture.AssignedSession,
		Nonce: posture.Nonce, IssuedAtUnix: posture.IssuedAtUnix,
		PreviousIdentityPublicKey: encodeBase64URL(previous.Public().(ed25519.PublicKey)),
		IdentityPublicKey:         encodeBase64URL(next.Public().(ed25519.PublicKey)),
		SEPublicKey:               base64.StdEncoding.EncodeToString(se), PostureDigest: digest,
	}
	framing, err := statement.Framing()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.MarshalIndent(rotationVector{
		Version: PrivacyKeyRotationVersion, Posture: posture, PostureDigest: digest, Statement: statement,
		RotationFramingHex:        hex.EncodeToString(framing),
		PreviousIdentitySignature: encodeBase64URL(ed25519.Sign(previous, framing)),
		IdentitySignature:         encodeBase64URL(ed25519.Sign(next, framing)),
	}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return append(raw, '\n')
}

func TestPrivacyRotationVectorGenerate(t *testing.T) {
	if os.Getenv("MACPROVIDER_REGEN_FIXTURES") != "1" {
		t.Skip("set MACPROVIDER_REGEN_FIXTURES=1 to regenerate privacy-key-rotation-v1.json")
	}
	if err := os.WriteFile(rotationFixtureRel, rotationFixtureBytes(t), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPrivacyRotationVector(t *testing.T) {
	got, err := os.ReadFile(rotationFixtureRel)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, rotationFixtureBytes(t)) {
		t.Fatal("privacy-key-rotation-v1.json drifted from the Go framing")
	}
	var loaded rotationVector
	if err := json.Unmarshal(got, &loaded); err != nil {
		t.Fatal(err)
	}
	framing, err := hex.DecodeString(loaded.RotationFramingHex)
	if err != nil {
		t.Fatal(err)
	}
	previous, _ := decodeBase64URLFixed(loaded.Statement.PreviousIdentityPublicKey, ed25519.PublicKeySize)
	next, _ := decodeBase64URLFixed(loaded.Statement.IdentityPublicKey, ed25519.PublicKeySize)
	if !verifyIdentityPosture(previous, framing, loaded.PreviousIdentitySignature) || !verifyIdentityPosture(next, framing, loaded.IdentitySignature) {
		t.Fatal("vector signatures do not verify")
	}
}
