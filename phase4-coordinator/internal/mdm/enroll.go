// Package mdm implements Phase 2 Track P2-A MDM enrollment profile generation
// (Scenario B). It generates per-device .mobileconfig files containing SCEP
// and MDM payloads for enrolling macprovider compute nodes into MicroMDM.
//
// No MicroMDM server deployment or APNs certificate is required for this
// track — the package only handles profile generation.
package mdm

import (
	"fmt"

	"github.com/google/uuid"
)

// Stable payload UUIDs — macOS keys profile identity (and re-enrollment
// update-in-place) on PayloadIdentifier strings and PayloadUUIDs. Using
// fixed UUIDs means a re-enroll with this profile replaces the existing
// macprovider enrollment rather than adding a duplicate.
const (
	scepPayloadUUID = "B3F7E8A1-2C9D-4F5E-8A6B-1E2D3C4B5A00"
	mdmPayloadUUID  = "A1B2C3D4-E5F6-7A8B-9C0D-E1F2A3B4C501"
)

// mdmPayloadIdentifierNS is the payload identifier namespace for macprovider.
// Using live.streamvc.macprovider.enroll.* (NOT io.darkbloom.*).
const mdmPayloadIdentifierNS = "live.streamvc.macprovider.enroll"

// Config carries the MDM enrollment parameters for profile generation.
// Populated at coordinator boot from config.Tier2MDMConfig.
type Config struct {
	// EnrollmentBaseURL is the canonical HTTPS base URL (e.g.
	// "https://coordinator.streamvc.live"). Used to derive SCEP and MDM
	// connect URLs when MDMServerURL or SCEPUrl are not set explicitly.
	EnrollmentBaseURL string

	// MDMServerURL overrides the MicroMDM connect URL. When empty,
	// EnrollmentBaseURL + "/mdm/connect" is used.
	MDMServerURL string

	// SCEPUrl overrides the SCEP endpoint URL. When empty,
	// EnrollmentBaseURL + "/scep" is used.
	SCEPUrl string

	// PushTopic is the APNs push topic tied to the MDM push certificate.
	// Placeholder until the macprovider APNs certificate is provisioned;
	// omit for staging — the resulting profile is syntactically valid.
	PushTopic string
}

// GenerateEnrollmentProfile creates a .mobileconfig plist with two payloads:
//
//  1. SCEP — obtains the MDM identity certificate from the coordinator's
//     SCEP endpoint. Fixed PayloadUUID scepPayloadUUID for re-enrollment
//     stability.
//
//  2. MDM — enrolls the device with MicroMDM via the ServerURL. References
//     the SCEP payload by IdentityCertificateUUID.
//
// AccessRights=1041 (bits 0+4+10): profile inspection, device info queries,
// and security-related queries (SIP, SecureBoot). Strictly read-only — no
// device control or personal data access.
//
// Apple MDM AccessRights bitmask:
//
//	Bit 0  (1)    — Inspect installed config profiles          ✓ REQUESTED
//	Bit 1  (2)    — Install/remove config profiles             ✗
//	Bit 2  (4)    — Device lock and passcode removal           ✗
//	Bit 3  (8)    — Device erase (remote wipe)                 ✗
//	Bit 4  (16)   — Query device information (name, serial)    ✓ REQUESTED
//	Bit 5  (32)   — Query network information                  ✗
//	Bit 6  (64)   — Inspect installed provisioning profiles    ✗
//	Bit 7  (128)  — Install/remove provisioning profiles       ✗
//	Bit 8  (256)  — Inspect installed applications             ✗
//	Bit 9  (512)  — Restriction-related queries                ✗
//	Bit 10 (1024) — Security-related queries (SIP, SecureBoot) ✓ REQUESTED
//	Bit 11 (2048) — Change device settings                     ✗
//	Bit 12 (4096) — App management                             ✗
func GenerateEnrollmentProfile(serialNumber string, cfg Config) string {
	scepURL := cfg.SCEPUrl
	if scepURL == "" {
		scepURL = cfg.EnrollmentBaseURL + "/scep"
	}
	mdmServerURL := cfg.MDMServerURL
	if mdmServerURL == "" {
		mdmServerURL = cfg.EnrollmentBaseURL + "/mdm/connect"
	}
	mdmCheckInURL := cfg.EnrollmentBaseURL + "/mdm/checkin"
	pushTopic := cfg.PushTopic

	profileUUID := uuid.New().String()

	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <!-- Payload 1: SCEP — MDM identity certificate -->
    <dict>
      <key>PayloadContent</key>
      <dict>
        <key>Challenge</key>
        <string>micromdm</string>
        <key>Key Type</key>
        <string>RSA</string>
        <key>Key Usage</key>
        <integer>5</integer>
        <key>Keysize</key>
        <integer>2048</integer>
        <key>Name</key>
        <string>macprovider Device Management Identity Certificate</string>
        <key>Subject</key>
        <array>
          <array>
            <array>
              <string>O</string>
              <string>macprovider</string>
            </array>
          </array>
          <array>
            <array>
              <string>CN</string>
              <string>macprovider Device Identity</string>
            </array>
          </array>
        </array>
        <key>URL</key>
        <string>%s</string>
      </dict>
      <key>PayloadDescription</key>
      <string>Configures SCEP for MDM enrollment</string>
      <key>PayloadDisplayName</key>
      <string>SCEP</string>
      <key>PayloadIdentifier</key>
      <string>%s.scep</string>
      <key>PayloadOrganization</key>
      <string>macprovider</string>
      <key>PayloadType</key>
      <string>com.apple.security.scep</string>
      <key>PayloadUUID</key>
      <string>%s</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
    <!-- Payload 2: MDM — enrollment with MicroMDM -->
    <dict>
      <key>AccessRights</key>
      <integer>1041</integer>
      <key>CheckInURL</key>
      <string>%s</string>
      <key>CheckOutWhenRemoved</key>
      <true/>
      <key>IdentityCertificateUUID</key>
      <string>%s</string>
      <key>PayloadDescription</key>
      <string>Enrolls with the macprovider coordinator for security verification</string>
      <key>PayloadIdentifier</key>
      <string>%s.mdm</string>
      <key>PayloadOrganization</key>
      <string>macprovider</string>
      <key>PayloadType</key>
      <string>com.apple.mdm</string>
      <key>PayloadUUID</key>
      <string>%s</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>ServerCapabilities</key>
      <array>
        <string>com.apple.mdm.per-user-connections</string>
        <string>com.apple.mdm.bootstraptoken</string>
      </array>
      <key>ServerURL</key>
      <string>%s</string>
      <key>SignMessage</key>
      <true/>
      <key>Topic</key>
      <string>%s</string>
    </dict>
  </array>
  <key>PayloadDescription</key>
  <string>macprovider provider enrollment. Grants read-only security verification (SIP, SecureBoot) via MDM.</string>
  <key>PayloadDisplayName</key>
  <string>macprovider Provider Enrollment</string>
  <key>PayloadIdentifier</key>
  <string>%s.%s</string>
  <key>PayloadOrganization</key>
  <string>macprovider</string>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>%s</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>`,
		scepURL,                    // SCEP URL
		mdmPayloadIdentifierNS,     // SCEP PayloadIdentifier prefix
		scepPayloadUUID,            // SCEP PayloadUUID (stable)
		mdmCheckInURL,              // MDM CheckInURL
		scepPayloadUUID,            // MDM IdentityCertificateUUID (refs SCEP payload)
		mdmPayloadIdentifierNS,     // MDM PayloadIdentifier prefix
		mdmPayloadUUID,             // MDM PayloadUUID (stable)
		mdmServerURL,               // MDM ServerURL
		pushTopic,                  // MDM Topic
		mdmPayloadIdentifierNS,     // outer PayloadIdentifier prefix
		serialNumber,               // outer PayloadIdentifier serial suffix
		profileUUID,                // outer PayloadUUID (fresh per request)
	)
}
