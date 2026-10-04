package relayblind

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
)

// SPEC-049 v0.2 constants (§4.1). These are compiled in; no configuration
// selects another bundle, child, or environment.
const (
	PrivacyPostureV2Version          = "privacy-posture-v2"
	PrivacyPostureV2Domain           = "macprovider/spec049/posture/v2"
	PrivacyAppAttestEnrollmentV1     = "privacy-app-attest-enrollment-v1"
	PrivacyAppAttestEnrollmentDomain = "macprovider/spec049/app-attest-enrollment/v1"
	PrivacySupervisorBundleID        = "tech.malibu.app"
	PrivacyChildSigningIdentifier    = "live.malibu.provider.cli"
	PrivacyAppAttestEnvironment      = "production"

	// PrivacyChildRequiredCSFlags is CS_VALID|CS_HARD|CS_KILL|CS_RUNTIME.
	PrivacyChildRequiredCSFlags uint64 = 0x00010301
	// PrivacyChildForbiddenCSFlags is
	// CS_ADHOC|CS_GET_TASK_ALLOW|CS_INVALID_ALLOWED|CS_DEBUGGED.
	PrivacyChildForbiddenCSFlags uint64 = 0x10000026

	// MaxPrivacyPostureV2ResponseBytes is the encoded version 2 cap.
	MaxPrivacyPostureV2ResponseBytes = 12288
	// MaxPrivacyAppAttestEnrollmentBytes is the encoded enrollment cap.
	MaxPrivacyAppAttestEnrollmentBytes = 32768

	maxSupervisorBundleVersionBytes = 64
	childCheckSkewSeconds           = int64(5)
)

// PrivacyAppID is the App Attest App ID for a configured team.
func PrivacyAppID(teamID string) string {
	return teamID + "." + PrivacySupervisorBundleID
}

// PrivacyChildCSFlagsOK applies the §4.1 required and forbidden masks.
func PrivacyChildCSFlagsOK(flags uint64) bool {
	return flags <= 0xffffffff && flags&PrivacyChildRequiredCSFlags == PrivacyChildRequiredCSFlags && flags&PrivacyChildForbiddenCSFlags == 0
}

// PostureStatementV2 is the closed privacy-posture-v2 statement: fields
// 1..24 of §4.3 under version privacy-posture-v2, then fields 25..34.
type PostureStatementV2 struct {
	PostureStatement
	Assurance                string `json:"assurance"`
	AppAttestKeyID           string `json:"app_attest_key_id"`
	SupervisorTeamID         string `json:"supervisor_team_id"`
	SupervisorBundleID       string `json:"supervisor_bundle_id"`
	SupervisorBundleVersion  string `json:"supervisor_bundle_version"`
	ChildCDHash              string `json:"child_cdhash"`
	ChildSigningIdentifier   string `json:"child_signing_identifier"`
	ChildCSFlags             uint64 `json:"child_cs_flags"`
	ChildCheckedAtUnix       int64  `json:"child_checked_at_unix"`
	ChildChannelPeerVerified bool   `json:"child_channel_peer_verified"`
}

var postureV2Fields = []string{
	"version", "privacy_class", "provider_id", "assigned_session", "nonce", "sequence", "issued_at_unix",
	"binary_version", "code_cdhash", "team_id", "signing_identifier", "hardened_runtime", "library_validation",
	"get_task_allow", "cs_debugged", "p_traced", "pt_deny_attach_applied", "core_dumps_disabled", "sip_enabled",
	"runtime_source", "diagnostic_env_clear", "kv_disk_tier_disabled", "se_key_backend", "privacy_key_record_digests",
	"assurance", "app_attest_key_id", "supervisor_team_id", "supervisor_bundle_id", "supervisor_bundle_version",
	"child_cdhash", "child_signing_identifier", "child_cs_flags", "child_checked_at_unix", "child_channel_peer_verified",
}

// ParsePostureStatementV2 decodes the closed statement and checks field
// syntax. Value policy (team, child flags, identifiers) is left to the
// authority so a signed failing posture can still be quarantined.
func ParsePostureStatementV2(raw []byte) (PostureStatementV2, error) {
	if len(raw) == 0 || len(raw) > MaxPrivacyPostureV2ResponseBytes {
		return PostureStatementV2{}, ErrInvalidPrivacy
	}
	var value PostureStatementV2
	if err := decodeClosed(raw, &value, postureV2Fields); err != nil {
		return PostureStatementV2{}, fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if err := value.validate(); err != nil {
		return PostureStatementV2{}, err
	}
	return value, nil
}

func (s PostureStatementV2) validate() error {
	if s.Version != PrivacyPostureV2Version {
		return fmt.Errorf("%w: posture identity", ErrInvalidPrivacy)
	}
	if err := s.validateFields(); err != nil {
		return err
	}
	if s.Assurance == "" || !visibleASCII(s.Assurance, MaxIdentifierBytes) {
		return fmt.Errorf("%w: posture assurance", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(s.AppAttestKeyID, 32); err != nil {
		return fmt.Errorf("%w: posture app attest key", ErrInvalidPrivacy)
	}
	if !validTeamID(s.SupervisorTeamID) || !visibleASCII(s.SupervisorBundleID, MaxIdentifierBytes) || !visibleASCII(s.SupervisorBundleVersion, maxSupervisorBundleVersionBytes) {
		return fmt.Errorf("%w: posture supervisor", ErrInvalidPrivacy)
	}
	if !validCDHash(s.ChildCDHash) || !visibleASCII(s.ChildSigningIdentifier, MaxIdentifierBytes) || s.ChildCSFlags > 0xffffffff {
		return fmt.Errorf("%w: posture child", ErrInvalidPrivacy)
	}
	return nil
}

// Framing is the v2 domain followed by fields 1..34 in §4.10 order.
func (s PostureStatementV2) Framing() ([]byte, error) {
	if err := s.validate(); err != nil {
		return nil, err
	}
	keyID, err := decodeBase64URLFixed(s.AppAttestKeyID, 32)
	if err != nil {
		return nil, err
	}
	var framed bytes.Buffer
	if err := s.writeFraming(&framed, PrivacyPostureV2Domain); err != nil {
		return nil, err
	}
	if err := writeFrame(&framed, []byte(s.Assurance)); err != nil {
		return nil, err
	}
	if err := writeFrame(&framed, keyID); err != nil {
		return nil, err
	}
	for _, value := range []string{s.SupervisorTeamID, s.SupervisorBundleID, s.SupervisorBundleVersion, s.ChildCDHash, s.ChildSigningIdentifier} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	writeU64(&framed, s.ChildCSFlags)
	writeI64(&framed, s.ChildCheckedAtUnix)
	writeBool(&framed, s.ChildChannelPeerVerified)
	return framed.Bytes(), nil
}

// childCheckFailure applies the §4.10 fields 30..34 rules. A failure is
// quarantine reason supervisor_child_check_failed.
func (s PostureStatementV2) childCheckFailure() bool {
	return s.ChildCDHash != s.CodeCDHash ||
		s.ChildSigningIdentifier != PrivacyChildSigningIdentifier || s.SigningIdentifier != PrivacyChildSigningIdentifier ||
		!PrivacyChildCSFlagsOK(s.ChildCSFlags) ||
		abs64(s.ChildCheckedAtUnix-s.IssuedAtUnix) > childCheckSkewSeconds ||
		!s.ChildChannelPeerVerified
}

// AppAttestEnrollmentStatement is the closed
// privacy-app-attest-enrollment-v1 statement of §4.11.
type AppAttestEnrollmentStatement struct {
	Version                 string `json:"version"`
	PrivacyClass            string `json:"privacy_class"`
	ProviderID              string `json:"provider_id"`
	AssignedSession         string `json:"assigned_session"`
	Challenge               string `json:"challenge"`
	AppAttestKeyID          string `json:"app_attest_key_id"`
	TeamID                  string `json:"team_id"`
	BundleID                string `json:"bundle_id"`
	Environment             string `json:"environment"`
	SEPublicKey             string `json:"se_public_key"`
	IdentityPublicKey       string `json:"identity_public_key"`
	ChildCDHash             string `json:"child_cdhash"`
	ChildCSFlags            uint64 `json:"child_cs_flags"`
	SupervisorBundleVersion string `json:"supervisor_bundle_version"`
	IssuedAtUnix            int64  `json:"issued_at_unix"`
}

var enrollmentFields = []string{
	"version", "privacy_class", "provider_id", "assigned_session", "challenge", "app_attest_key_id", "team_id",
	"bundle_id", "environment", "se_public_key", "identity_public_key", "child_cdhash", "child_cs_flags",
	"supervisor_bundle_version", "issued_at_unix",
}

func ParseAppAttestEnrollmentStatement(raw []byte) (AppAttestEnrollmentStatement, error) {
	if len(raw) == 0 || len(raw) > MaxPrivacyAppAttestEnrollmentBytes {
		return AppAttestEnrollmentStatement{}, ErrInvalidPrivacy
	}
	var value AppAttestEnrollmentStatement
	if err := decodeClosed(raw, &value, enrollmentFields); err != nil {
		return AppAttestEnrollmentStatement{}, fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if err := value.validate(); err != nil {
		return AppAttestEnrollmentStatement{}, err
	}
	return value, nil
}

func (s AppAttestEnrollmentStatement) validate() error {
	if s.Version != PrivacyAppAttestEnrollmentV1 || s.PrivacyClass != PrivacyClassV1 {
		return fmt.Errorf("%w: enrollment identity", ErrInvalidPrivacy)
	}
	if !visibleASCII(s.ProviderID, MaxIdentifierBytes) || !visibleASCII(s.AssignedSession, MaxIdentifierBytes) {
		return fmt.Errorf("%w: enrollment session", ErrInvalidPrivacy)
	}
	for _, check := range []struct {
		value string
		size  int
	}{{s.Challenge, 32}, {s.AppAttestKeyID, 32}, {s.SEPublicKey, 64}, {s.IdentityPublicKey, 32}} {
		if _, err := decodeBase64URLFixed(check.value, check.size); err != nil {
			return fmt.Errorf("%w: enrollment bytes", ErrInvalidPrivacy)
		}
	}
	if !validTeamID(s.TeamID) || !visibleASCII(s.BundleID, MaxIdentifierBytes) || !visibleASCII(s.Environment, MaxIdentifierBytes) {
		return fmt.Errorf("%w: enrollment app", ErrInvalidPrivacy)
	}
	if !validCDHash(s.ChildCDHash) || s.ChildCSFlags > 0xffffffff || !visibleASCII(s.SupervisorBundleVersion, maxSupervisorBundleVersionBytes) {
		return fmt.Errorf("%w: enrollment child", ErrInvalidPrivacy)
	}
	return nil
}

// Framing is the enrollment domain followed by fields 1..15 in §4.11 order.
func (s AppAttestEnrollmentStatement) Framing() ([]byte, error) {
	if err := s.validate(); err != nil {
		return nil, err
	}
	var framed bytes.Buffer
	for _, value := range []string{PrivacyAppAttestEnrollmentDomain, s.Version, s.PrivacyClass, s.ProviderID, s.AssignedSession} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	challenge, _ := decodeBase64URLFixed(s.Challenge, 32)
	keyID, _ := decodeBase64URLFixed(s.AppAttestKeyID, 32)
	for _, value := range [][]byte{challenge, keyID} {
		if err := writeFrame(&framed, value); err != nil {
			return nil, err
		}
	}
	for _, value := range []string{s.TeamID, s.BundleID, s.Environment} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	sePub, _ := decodeBase64URLFixed(s.SEPublicKey, 64)
	idPub, _ := decodeBase64URLFixed(s.IdentityPublicKey, 32)
	for _, value := range [][]byte{sePub, idPub, []byte(s.ChildCDHash)} {
		if err := writeFrame(&framed, value); err != nil {
			return nil, err
		}
	}
	writeU64(&framed, s.ChildCSFlags)
	if err := writeFrame(&framed, []byte(s.SupervisorBundleVersion)); err != nil {
		return nil, err
	}
	writeI64(&framed, s.IssuedAtUnix)
	return framed.Bytes(), nil
}

// privacyPostureV2Wire is the closed version 2 posture response.
type privacyPostureV2Wire struct {
	Type               string          `json:"type"`
	Version            int             `json:"version"`
	Statement          json.RawMessage `json:"statement"`
	SESignature        string          `json:"se_signature"`
	IdentitySignature  string          `json:"identity_signature"`
	AppAttestAssertion string          `json:"app_attest_assertion"`
}

func parsePrivacyPostureV2Response(raw []byte) (privacyPostureV2Wire, error) {
	var response privacyPostureV2Wire
	if err := decodeClosed(raw, &response, []string{"type", "version", "statement", "se_signature", "identity_signature", "app_attest_assertion"}); err != nil {
		return privacyPostureV2Wire{}, err
	}
	if response.Type != privacyPostureResponseType || response.Version != 2 {
		return privacyPostureV2Wire{}, ErrInvalidPrivacy
	}
	statement := bytesTrimSpace(response.Statement)
	if len(statement) == 0 || statement[0] != '{' {
		return privacyPostureV2Wire{}, ErrInvalidPrivacy
	}
	return response, nil
}

// privacyPostureWireVersion reads only the response version so the caller
// can select the closed decoder (§4.4). Any other value is rejected later.
func privacyPostureWireVersion(raw []byte) int {
	var probe struct {
		Version json.RawMessage `json:"version"`
	}
	if json.Unmarshal(raw, &probe) != nil {
		return 0
	}
	switch string(probe.Version) {
	case "1":
		return 1
	case "2":
		return 2
	default:
		return 0
	}
}

// privacyAppAttestEnrollmentWire is the closed enrollment message.
type privacyAppAttestEnrollmentWire struct {
	Type              string          `json:"type"`
	Version           int             `json:"version"`
	Statement         json.RawMessage `json:"statement"`
	Attestation       string          `json:"attestation"`
	SESignature       string          `json:"se_signature"`
	IdentitySignature string          `json:"identity_signature"`
}

const privacyAppAttestEnrollmentType = "privacy_app_attest_enrollment"

func parsePrivacyAppAttestEnrollment(raw []byte) (privacyAppAttestEnrollmentWire, error) {
	var wire privacyAppAttestEnrollmentWire
	if len(raw) == 0 || len(raw) > MaxPrivacyAppAttestEnrollmentBytes {
		return privacyAppAttestEnrollmentWire{}, ErrInvalidPrivacy
	}
	if err := decodeClosed(raw, &wire, []string{"type", "version", "statement", "attestation", "se_signature", "identity_signature"}); err != nil {
		return privacyAppAttestEnrollmentWire{}, err
	}
	if wire.Type != privacyAppAttestEnrollmentType || wire.Version != 1 {
		return privacyAppAttestEnrollmentWire{}, ErrInvalidPrivacy
	}
	statement := bytesTrimSpace(wire.Statement)
	if len(statement) == 0 || statement[0] != '{' {
		return privacyAppAttestEnrollmentWire{}, ErrInvalidPrivacy
	}
	return wire, nil
}

// sha256Bytes returns SHA-256 of value as a slice.
func sha256Bytes(value []byte) []byte {
	sum := sha256.Sum256(value)
	return sum[:]
}
