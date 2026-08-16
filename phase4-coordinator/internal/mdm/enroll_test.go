package mdm_test

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/mdm"
)

func TestGenerateEnrollmentProfile_ContainsSCEPAndMDMPayloads(t *testing.T) {
	cfg := mdm.Config{
		EnrollmentBaseURL: "https://coordinator.malibu.tech",
		PushTopic:         "com.apple.mgmt.External.test-topic",
	}
	profile := mdm.GenerateEnrollmentProfile("C02XYZ1234AB", cfg)

	// Must contain both payload types.
	if !strings.Contains(profile, "com.apple.security.scep") {
		t.Error("profile missing SCEP payload type")
	}
	if !strings.Contains(profile, "com.apple.mdm") {
		t.Error("profile missing MDM payload type")
	}
}

func TestGenerateEnrollmentProfile_SerialInProfile(t *testing.T) {
	const serial = "C02XYZ1234AB"
	cfg := mdm.Config{
		EnrollmentBaseURL: "https://coordinator.malibu.tech",
	}
	profile := mdm.GenerateEnrollmentProfile(serial, cfg)

	if !strings.Contains(profile, serial) {
		t.Errorf("profile does not contain serial number %q", serial)
	}
}

func TestGenerateEnrollmentProfile_ServerURLFromConfig(t *testing.T) {
	cfg := mdm.Config{
		EnrollmentBaseURL: "https://coordinator.malibu.tech",
		MDMServerURL:      "https://mdm.malibu.tech/mdm/connect",
		SCEPUrl:           "https://mdm.malibu.tech/scep",
		PushTopic:         "com.apple.mgmt.External.abc",
	}
	profile := mdm.GenerateEnrollmentProfile("SERIALTEST1", cfg)

	if !strings.Contains(profile, "https://mdm.malibu.tech/mdm/connect") {
		t.Error("profile does not contain the configured MDM ServerURL")
	}
	if !strings.Contains(profile, "https://mdm.malibu.tech/scep") {
		t.Error("profile does not contain the configured SCEP URL")
	}
}

func TestGenerateEnrollmentProfile_FallbackURLs(t *testing.T) {
	cfg := mdm.Config{
		EnrollmentBaseURL: "https://coordinator.malibu.tech",
	}
	profile := mdm.GenerateEnrollmentProfile("SERIALTEST2", cfg)

	// When MDMServerURL/SCEPUrl are empty, they should fall back to
	// EnrollmentBaseURL + path suffixes.
	if !strings.Contains(profile, "https://coordinator.malibu.tech/mdm/connect") {
		t.Error("profile missing fallback MDM ServerURL")
	}
	if !strings.Contains(profile, "https://coordinator.malibu.tech/scep") {
		t.Error("profile missing fallback SCEP URL")
	}
}

func TestGenerateEnrollmentProfile_AccessRights1041(t *testing.T) {
	cfg := mdm.Config{
		EnrollmentBaseURL: "https://coordinator.malibu.tech",
	}
	profile := mdm.GenerateEnrollmentProfile("SERIALTEST3", cfg)

	// AccessRights must be exactly 1041 (bits 0 + 4 + 10).
	if !strings.Contains(profile, "<integer>1041</integer>") {
		t.Error("profile AccessRights is not 1041")
	}
}

func TestGenerateEnrollmentProfile_MacproviderNamespace(t *testing.T) {
	cfg := mdm.Config{
		EnrollmentBaseURL: "https://coordinator.malibu.tech",
	}
	profile := mdm.GenerateEnrollmentProfile("SERIALTEST4", cfg)

	// Identifiers must use the macprovider namespace, not Darkbloom.
	if strings.Contains(profile, "darkbloom") || strings.Contains(profile, "Darkbloom") {
		t.Error("profile contains Darkbloom branding — must use macprovider namespace")
	}
	if !strings.Contains(profile, "live.malibu.provider.enroll") {
		t.Error("profile missing live.malibu.provider.enroll namespace")
	}
}

func TestGenerateEnrollmentProfile_CheckInURL(t *testing.T) {
	cfg := mdm.Config{
		EnrollmentBaseURL: "https://coordinator.malibu.tech",
	}
	profile := mdm.GenerateEnrollmentProfile("SERIALTEST5", cfg)

	if !strings.Contains(profile, "https://coordinator.malibu.tech/mdm/checkin") {
		t.Error("profile missing CheckInURL")
	}
}

func TestGenerateEnrollmentProfile_IdentityCertUUIDMatchesSCEPPayloadUUID(t *testing.T) {
	cfg := mdm.Config{
		EnrollmentBaseURL: "https://coordinator.malibu.tech",
	}
	profile := mdm.GenerateEnrollmentProfile("SERIALTEST6", cfg)

	// The stable SCEP PayloadUUID must appear at least twice: once as the SCEP
	// payload's own PayloadUUID and once as the MDM IdentityCertificateUUID.
	const scepUUID = "B3F7E8A1-2C9D-4F5E-8A6B-1E2D3C4B5A00"
	count := strings.Count(profile, scepUUID)
	if count < 2 {
		t.Errorf("SCEP UUID %q appears %d time(s) in profile; expected >= 2 (PayloadUUID + IdentityCertificateUUID)", scepUUID, count)
	}
}

func TestGenerateEnrollmentProfile_PushTopic(t *testing.T) {
	const topic = "com.apple.mgmt.External.99999-test"
	cfg := mdm.Config{
		EnrollmentBaseURL: "https://coordinator.malibu.tech",
		PushTopic:         topic,
	}
	profile := mdm.GenerateEnrollmentProfile("SERIALTEST7", cfg)

	if !strings.Contains(profile, topic) {
		t.Errorf("profile does not contain configured push topic %q", topic)
	}
}
