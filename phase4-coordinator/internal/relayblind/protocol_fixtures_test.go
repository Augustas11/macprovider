package relayblind

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"testing"
	"time"
)

// Shared with the protocol tests that now live in the relayblind module.
// Coordinator tests still build the same fixture material.
const (
	fixtureCDHash = "0123456789abcdef0123456789abcdef01234567"
	fixtureBinary = "0.0.0-fixture"
	fixtureTeamID = "AB12CD34EF"
)

func testPrivacyMaterial(t *testing.T, now time.Time) (KeyRecord, IdentityPin, ed25519.PrivateKey) {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	identity := ed25519.NewKeyFromSeed(seed)
	provider, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x11}, 32))
	if err != nil {
		t.Fatal(err)
	}
	record, err := NewSignedKeyRecord(provider.PublicKey().Bytes(), identity, []string{"model-a"}, 4096, now, now.Add(time.Duration(MaxPrivacyKeyLifetimeSeconds)*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	public := identity.Public().(ed25519.PublicKey)
	sum := sha256.Sum256(public)
	pin := IdentityPin{
		Version: PinVersion, IdentityPublicKey: encodeBase64URL(public), Fingerprint: encodeBase64URL(sum[:]),
		Models: []string{"model-a"}, EndpointFamilies: []string{EndpointChatCompletions},
		NotBeforeUnix: now.Add(-time.Hour).Unix(), ExpiresAtUnix: now.Add(2 * time.Hour).Unix(),
	}
	return record, pin, identity
}

func testPosture(digest string) PostureStatement {
	return PostureStatement{
		Version: PrivacyPostureVersion, PrivacyClass: PrivacyClassV1, ProviderID: "provider-fixture",
		AssignedSession: "session-fixture", Nonce: encodeBase64URL(bytes.Repeat([]byte{0x5a}, 32)),
		Sequence: 1, IssuedAtUnix: 1700000000, BinaryVersion: fixtureBinary, CodeCDHash: fixtureCDHash,
		TeamID: fixtureTeamID, SigningIdentifier: "live.malibu.provider.cli", HardenedRuntime: true,
		LibraryValidation: true, GetTaskAllow: false, CSDebugged: false, PTraced: false,
		PTDenyAttachApplied: true, CoreDumpsDisabled: true, SIPEnabled: true, RuntimeSource: PrivacyRuntimeSource,
		DiagnosticEnvClear: true, KVDiskTierDisabled: true, SEKeyBackend: PrivacySEBackendFile,
		PrivacyKeyRecordDigests: []string{digest},
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func signAttestation(t *testing.T, key ed25519.PrivateKey, attestation PrivacyKeyAttestation) string {
	t.Helper()
	framed, err := attestation.Framing()
	if err != nil {
		t.Fatal(err)
	}
	return encodeBase64URL(ed25519.Sign(key, framed))
}
