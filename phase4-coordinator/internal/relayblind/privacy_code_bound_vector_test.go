package relayblind

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

// privacyCodeBoundFixtureRel is the shared SPEC-049 v0.2 framing vector. The
// Swift provider and Malibu.app supervisor tests frame the same statements and
// must produce these bytes.
const privacyCodeBoundFixtureRel = "../../../test/fixtures/relay-blind/privacy-code-bound-v2.json"

type privacyCodeBoundVector struct {
	Version                     string                       `json:"version"`
	PostureV2                   PostureStatementV2           `json:"posture_v2"`
	PostureV2FramingHex         string                       `json:"posture_v2_framing_hex"`
	PostureV2ClientDataHashHex  string                       `json:"posture_v2_client_data_hash_hex"`
	Enrollment                  AppAttestEnrollmentStatement `json:"enrollment"`
	EnrollmentFramingHex        string                       `json:"enrollment_framing_hex"`
	EnrollmentClientDataHashHex string                       `json:"enrollment_client_data_hash_hex"`
}

func TestPrivacyCodeBoundVectorGenerate(t *testing.T) {
	if os.Getenv("MACPROVIDER_REGEN_FIXTURES") != "1" {
		t.Skip("set MACPROVIDER_REGEN_FIXTURES=1 to regenerate privacy-code-bound-v2.json")
	}
	if err := os.WriteFile(privacyCodeBoundFixtureRel, privacyCodeBoundFixtureBytes(t), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPrivacyCodeBoundVector(t *testing.T) {
	want := privacyCodeBoundFixtureBytes(t)
	got, err := os.ReadFile(privacyCodeBoundFixtureRel)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("privacy-code-bound-v2.json drifted from the Go framing; regenerate and update the Swift parity tests")
	}
	var loaded privacyCodeBoundVector
	if err := json.Unmarshal(got, &loaded); err != nil {
		t.Fatal(err)
	}
	rawPosture, err := json.Marshal(loaded.PostureV2)
	if err != nil {
		t.Fatal(err)
	}
	posture, err := ParsePostureStatementV2(rawPosture)
	if err != nil {
		t.Fatal(err)
	}
	if posture.childCheckFailure() || !PrivacyChildCSFlagsOK(posture.ChildCSFlags) {
		t.Fatal("fixture posture must pass the child-check rules")
	}
	framing, err := posture.Framing()
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(framing) != loaded.PostureV2FramingHex {
		t.Fatal("posture v2 framing mismatch")
	}
	rawEnrollment, err := json.Marshal(loaded.Enrollment)
	if err != nil {
		t.Fatal(err)
	}
	enrollment, err := ParseAppAttestEnrollmentStatement(rawEnrollment)
	if err != nil {
		t.Fatal(err)
	}
	framing, err = enrollment.Framing()
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(framing) != loaded.EnrollmentFramingHex {
		t.Fatal("enrollment framing mismatch")
	}
}

func privacyCodeBoundFixtureBytes(t *testing.T) []byte {
	t.Helper()
	digests := []string{
		encodeBase64URL(bytes.Repeat([]byte{0x33}, 32)),
		encodeBase64URL(bytes.Repeat([]byte{0x44}, 32)),
	}
	base := testPosture(digests[0])
	base.Version = PrivacyPostureV2Version
	base.SEKeyBackend = PrivacySEBackendKeychain
	base.PrivacyKeyRecordDigests = digests
	keyID := encodeBase64URL(bytes.Repeat([]byte{0x11}, 32))
	posture := PostureStatementV2{
		PostureStatement:         base,
		Assurance:                PrivacyAssuranceCodeBound,
		AppAttestKeyID:           keyID,
		SupervisorTeamID:         fixtureTeamID,
		SupervisorBundleID:       PrivacySupervisorBundleID,
		SupervisorBundleVersion:  "213",
		ChildCDHash:              fixtureCDHash,
		ChildSigningIdentifier:   PrivacyChildSigningIdentifier,
		ChildCSFlags:             0x22011311,
		ChildCheckedAtUnix:       base.IssuedAtUnix + 1,
		ChildChannelPeerVerified: true,
	}
	postureFraming, err := posture.Framing()
	if err != nil {
		t.Fatal(err)
	}
	enrollment := AppAttestEnrollmentStatement{
		Version:                 PrivacyAppAttestEnrollmentV1,
		PrivacyClass:            PrivacyClassV1,
		ProviderID:              base.ProviderID,
		AssignedSession:         base.AssignedSession,
		Challenge:               encodeBase64URL(bytes.Repeat([]byte{0x22}, 32)),
		AppAttestKeyID:          keyID,
		TeamID:                  fixtureTeamID,
		BundleID:                PrivacySupervisorBundleID,
		Environment:             PrivacyAppAttestEnvironment,
		SEPublicKey:             encodeBase64URL(bytes.Repeat([]byte{0x55}, 64)),
		IdentityPublicKey:       encodeBase64URL(bytes.Repeat([]byte{0x66}, 32)),
		ChildCDHash:             fixtureCDHash,
		ChildCSFlags:            0x22011311,
		SupervisorBundleVersion: "213",
		IssuedAtUnix:            base.IssuedAtUnix,
	}
	enrollmentFraming, err := enrollment.Framing()
	if err != nil {
		t.Fatal(err)
	}
	postureHash := sha256.Sum256(postureFraming)
	enrollmentHash := sha256.Sum256(enrollmentFraming)
	raw, err := json.MarshalIndent(privacyCodeBoundVector{
		Version:                     "privacy-code-bound-v2-vector-1",
		PostureV2:                   posture,
		PostureV2FramingHex:         hex.EncodeToString(postureFraming),
		PostureV2ClientDataHashHex:  hex.EncodeToString(postureHash[:]),
		Enrollment:                  enrollment,
		EnrollmentFramingHex:        hex.EncodeToString(enrollmentFraming),
		EnrollmentClientDataHashHex: hex.EncodeToString(enrollmentHash[:]),
	}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return append(raw, '\n')
}
