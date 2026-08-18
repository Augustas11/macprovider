package mdm

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"howett.net/plist"
)

// ClientConfig holds the configuration for the MicroMDM API client.
// All fields are required when the client is enabled (APIURL non-empty).
type ClientConfig struct {
	// BaseURL is the MicroMDM server API base URL, e.g. "http://127.0.0.1:8080".
	BaseURL string
	// APIToken is the MicroMDM API token (basic-auth password with "micromdm" username).
	APIToken string
	// HTTPClient is optional; when nil the default http.Client with a 15s timeout
	// is used.
	HTTPClient *http.Client
}

// Client is a minimal MicroMDM API client for Phase 3 live MDA.
// It supports listing devices and enqueuing DeviceInformation attestation commands.
type Client struct {
	cfg ClientConfig
	hc  *http.Client
}

// NewClient creates a new MicroMDM API client from cfg.
// Returns an error when BaseURL is empty.
func NewClient(cfg ClientConfig) (*Client, error) {
	if strings.TrimSpace(cfg.BaseURL) == "" {
		return nil, fmt.Errorf("mdm client: BaseURL is required")
	}
	hc := cfg.HTTPClient
	if hc == nil {
		hc = &http.Client{Timeout: 15 * time.Second}
	}
	return &Client{cfg: cfg, hc: hc}, nil
}

// Device is a minimal MicroMDM device record returned by /v1/devices.
type Device struct {
	// UDID is the device's Unique Device Identifier.
	UDID string `json:"udid"`
	// SerialNumber is the hardware serial number.
	SerialNumber string `json:"serial_number"`
	// EnrollmentStatus indicates whether the device is enrolled.
	EnrollmentStatus bool `json:"enrollment_status"`
}

// listDevicesResponse is the /v1/devices API response envelope.
type listDevicesResponse struct {
	Devices []Device `json:"devices"`
}

// ListDevices returns all devices enrolled in MicroMDM.
// MicroMDM's HTTP API only accepts POST /v1/devices (GET is 404).
func (c *Client) ListDevices(ctx context.Context) ([]Device, error) {
	req, err := c.newRequest(ctx, http.MethodPost, "/v1/devices", bytes.NewReader([]byte("{}")))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	var resp listDevicesResponse
	if err := c.doJSON(req, &resp); err != nil {
		return nil, fmt.Errorf("mdm list devices: %w", err)
	}
	return resp.Devices, nil
}

// FindDeviceBySerial returns the first device whose serial number matches
// serial (case-insensitive). Returns (Device{}, false, nil) when not found.
func (c *Client) FindDeviceBySerial(ctx context.Context, serial string) (Device, bool, error) {
	devices, err := c.ListDevices(ctx)
	if err != nil {
		return Device{}, false, err
	}
	serial = NormalizeSerial(serial)
	for _, d := range devices {
		if NormalizeSerial(d.SerialNumber) == serial {
			return d, true, nil
		}
	}
	return Device{}, false, nil
}

// EnqueueDeviceInformationAttestation enqueues a DeviceInformation MDM command
// for udid with DevicePropertiesAttestation + DeviceAttestationNonce via
// MicroMDM's raw plist endpoint POST /v1/commands/{udid}.
//
// MicroMDM's JSON DeviceInformation model only has `queries` and drops unknown
// fields (including device_attestation_nonce), so the nonce must be delivered
// as a plist <data> field on the raw command path (R2-H2).
//
// nonce32 should be 32 bytes — SHA256 of the provider's SE public key so that
// the resulting MDA freshness extension can be verified with verifyMDAFreshness.
//
// Returns the CommandUUID embedded in the plist (for pending keying).
func (c *Client) EnqueueDeviceInformationAttestation(ctx context.Context, udid string, nonce32 []byte) (commandUUID string, err error) {
	udid = strings.TrimSpace(udid)
	if udid == "" {
		return "", fmt.Errorf("mdm enqueue: udid required")
	}
	if len(nonce32) == 0 {
		return "", fmt.Errorf("mdm enqueue: nonce required")
	}
	commandUUID = uuid.New().String()
	body := buildDeviceInformationAttestationPlist(commandUUID, nonce32)
	path := "/v1/commands/" + udid
	req, err := c.newRequest(ctx, http.MethodPost, path, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/xml")
	resp, err := c.hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("mdm enqueue: http: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("mdm enqueue: status %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	return commandUUID, nil
}

// buildDeviceInformationAttestationPlist builds an Apple MDM DeviceInformation
// command plist with DeviceAttestationNonce as <data> (base64 text).
func buildDeviceInformationAttestationPlist(commandUUID string, nonce32 []byte) []byte {
	nonceB64 := base64.StdEncoding.EncodeToString(nonce32)
	// commandUUID and nonceB64 are hex/base64 — safe for XML text content.
	return []byte(fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CommandUUID</key>
  <string>%s</string>
  <key>Command</key>
  <dict>
    <key>RequestType</key>
    <string>DeviceInformation</string>
    <key>Queries</key>
    <array>
      <string>DevicePropertiesAttestation</string>
    </array>
    <key>DeviceAttestationNonce</key>
    <data>%s</data>
  </dict>
</dict>
</plist>
`, commandUUID, nonceB64))
}

// DeviceAttestationResult holds the parsed DeviceAttestation fields from a
// DeviceInformation command response (polled or received via webhook).
type DeviceAttestationResult struct {
	// CertificateChain holds the raw DER bytes of each certificate in the
	// Apple MDA chain (leaf first), as returned by the device.
	CertificateChain [][]byte
}

// AcknowledgeEventParse holds fields extracted from a MicroMDM command webhook.
type AcknowledgeEventParse struct {
	Topic       string
	UDID        string
	CommandUUID string
	Status      string
	Result      *DeviceAttestationResult
}

// micromdmWebhookEnvelope is the real MicroMDM command-webhook JSON shape.
type micromdmWebhookEnvelope struct {
	Topic            string `json:"topic"`
	AcknowledgeEvent *struct {
		UDID        string `json:"udid"`
		Status      string `json:"status"`
		CommandUUID string `json:"command_uuid"`
		RawPayload  string `json:"raw_payload"`
	} `json:"acknowledge_event"`
}

// ParseAcknowledgeEvent parses a MicroMDM command webhook body.
// Primary path: topic mdm.Connect + acknowledge_event.raw_payload (base64 plist).
// Empty topic is accepted when acknowledge_event is present (test fixtures).
// Falls back to legacy flat/payload JSON DeviceAttestation for secondary compat.
func ParseAcknowledgeEvent(data []byte) (*AcknowledgeEventParse, error) {
	var env micromdmWebhookEnvelope
	if err := json.Unmarshal(data, &env); err == nil && env.AcknowledgeEvent != nil {
		topic := strings.TrimSpace(env.Topic)
		if topic != "" && topic != "mdm.Connect" {
			return nil, fmt.Errorf("mdm: ignore webhook topic %q", topic)
		}
		ae := env.AcknowledgeEvent
		out := &AcknowledgeEventParse{
			Topic:       topic,
			UDID:        strings.TrimSpace(ae.UDID),
			CommandUUID: strings.TrimSpace(ae.CommandUUID),
			Status:      strings.TrimSpace(ae.Status),
		}
		raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(ae.RawPayload))
		if err != nil {
			// Some fixtures may already be raw XML; try as-is.
			raw = []byte(strings.TrimSpace(ae.RawPayload))
		}
		if len(raw) == 0 {
			return out, ErrNoDeviceAttestation
		}
		result, err := ParseDeviceAttestationFromPlistBytes(raw)
		if err != nil {
			return out, err
		}
		out.Result = result
		return out, nil
	}

	// Secondary compat: legacy flat JSON used by early Phase 3 tests.
	udid := extractWebhookUDID(data)
	result, err := ParseDeviceAttestationFromPlist(data)
	if err != nil {
		return nil, err
	}
	return &AcknowledgeEventParse{
		UDID:   udid,
		Result: result,
	}, nil
}

// ParseDeviceAttestationFromPlistBytes extracts the MDA chain from raw Apple
// MDM response plist bytes (XML or binary).
func ParseDeviceAttestationFromPlistBytes(data []byte) (*DeviceAttestationResult, error) {
	var top map[string]interface{}
	if _, err := plist.Unmarshal(data, &top); err != nil {
		return nil, fmt.Errorf("mdm: plist decode: %w", err)
	}
	if qr, ok := top["QueryResponses"].(map[string]interface{}); ok {
		if v, ok := mapAttestationValue(qr); ok {
			return extractDeviceAttestationCerts(plistValueToJSONCompat(v))
		}
	}
	if v, ok := mapAttestationValue(top); ok {
		return extractDeviceAttestationCerts(plistValueToJSONCompat(v))
	}
	return nil, ErrNoDeviceAttestation
}

// mapAttestationValue returns Apple's DevicePropertiesAttestation value, or the
// legacy DeviceAttestation fallback used by early Phase 3 fixtures.
func mapAttestationValue(m map[string]interface{}) (interface{}, bool) {
	if m == nil {
		return nil, false
	}
	if v, ok := m["DevicePropertiesAttestation"]; ok && v != nil {
		return v, true
	}
	if v, ok := m["DeviceAttestation"]; ok && v != nil {
		return v, true
	}
	return nil, false
}

func firstAttestationValue(values ...interface{}) interface{} {
	for _, v := range values {
		if v != nil {
			return v
		}
	}
	return nil
}

// plistValueToJSONCompat converts howett plist values into the shapes
// extractDeviceAttestationCerts already understands ([]interface{} of strings,
// or a single base64/string / []byte).
func plistValueToJSONCompat(v interface{}) interface{} {
	switch tv := v.(type) {
	case []interface{}:
		out := make([]interface{}, 0, len(tv))
		for _, item := range tv {
			out = append(out, plistValueToJSONCompat(item))
		}
		return out
	case []byte:
		return base64.StdEncoding.EncodeToString(tv)
	case string:
		return tv
	default:
		return v
	}
}

// ParseDeviceAttestationFromPlist parses a MicroMDM device information response
// body (JSON wrapping plist fields) and extracts the MDA certificate chain.
//
// MicroMDM v1.13 returns device responses via GET /v1/commands when the command
// is polled. The response format is a JSON object with a "payload" key containing
// the MDM CheckIn/Acknowledge plist decoded into JSON. Prefer
// QueryResponses.DevicePropertiesAttestation (Apple); DeviceAttestation is
// legacy fallback. The value is a base64-encoded sequence of DER certificates
// (JSON array of base64 strings or a concatenated DER blob).
//
// This function handles both variants. When the format is unknown it returns
// (nil, ErrNoDeviceAttestation).
func ParseDeviceAttestationFromPlist(data []byte) (*DeviceAttestationResult, error) {
	// Unwrap MicroMDM command response envelope.
	var outer struct {
		Payload struct {
			DevicePropertiesAttestation interface{} `json:"DevicePropertiesAttestation"`
			DeviceAttestation           interface{} `json:"DeviceAttestation"`
			QueryResponses              struct {
				DevicePropertiesAttestation interface{} `json:"DevicePropertiesAttestation"`
				DeviceAttestation           interface{} `json:"DeviceAttestation"`
			} `json:"QueryResponses"`
		} `json:"payload"`
	}
	// Also try flat parse (direct MDM response JSON).
	var flat struct {
		DevicePropertiesAttestation interface{} `json:"DevicePropertiesAttestation"`
		DeviceAttestation           interface{} `json:"DeviceAttestation"`
		QueryResponses              struct {
			DevicePropertiesAttestation interface{} `json:"DevicePropertiesAttestation"`
			DeviceAttestation           interface{} `json:"DeviceAttestation"`
		} `json:"QueryResponses"`
	}
	var parsed interface{}
	if err := json.Unmarshal(data, &outer); err == nil {
		parsed = firstAttestationValue(
			outer.Payload.QueryResponses.DevicePropertiesAttestation,
			outer.Payload.QueryResponses.DeviceAttestation,
			outer.Payload.DevicePropertiesAttestation,
			outer.Payload.DeviceAttestation,
		)
	}
	if parsed == nil {
		if err2 := json.Unmarshal(data, &flat); err2 == nil {
			parsed = firstAttestationValue(
				flat.QueryResponses.DevicePropertiesAttestation,
				flat.QueryResponses.DeviceAttestation,
				flat.DevicePropertiesAttestation,
				flat.DeviceAttestation,
			)
		}
	}
	if parsed == nil {
		return nil, ErrNoDeviceAttestation
	}
	return extractDeviceAttestationCerts(parsed)
}

// ErrNoDeviceAttestation is returned by ParseDeviceAttestationFromPlist when
// no DeviceAttestation field is present in the response.
var ErrNoDeviceAttestation = fmt.Errorf("mdm: no DeviceAttestation field in response")

func extractDeviceAttestationCerts(v interface{}) (*DeviceAttestationResult, error) {
	switch tv := v.(type) {
	case []interface{}:
		// Array of base64-encoded DER certificates.
		chain := make([][]byte, 0, len(tv))
		for i, item := range tv {
			s, ok := item.(string)
			if !ok {
				return nil, fmt.Errorf("mdm: DeviceAttestation[%d] is not a string", i)
			}
			der, err := decodeBase64Cert(s)
			if err != nil {
				return nil, fmt.Errorf("mdm: DeviceAttestation[%d]: %w", i, err)
			}
			chain = append(chain, der)
		}
		return &DeviceAttestationResult{CertificateChain: chain}, nil
	case string:
		// Single base64-encoded DER certificate or concatenated DER chain.
		der, err := decodeBase64Cert(tv)
		if err != nil {
			return nil, fmt.Errorf("mdm: DeviceAttestation base64: %w", err)
		}
		if certs, err := x509.ParseCertificates(der); err == nil && len(certs) > 0 {
			chain := make([][]byte, 0, len(certs))
			for _, c := range certs {
				chain = append(chain, append([]byte(nil), c.Raw...))
			}
			return &DeviceAttestationResult{CertificateChain: chain}, nil
		}
		// Fallback: treat as a single opaque DER blob (may fail later verify).
		if _, err := x509.ParseCertificate(der); err == nil {
			return &DeviceAttestationResult{CertificateChain: [][]byte{der}}, nil
		}
		return &DeviceAttestationResult{CertificateChain: [][]byte{der}}, nil
	default:
		return nil, fmt.Errorf("mdm: unexpected DeviceAttestation type %T", v)
	}
}

func decodeBase64Cert(s string) ([]byte, error) {
	for _, enc := range []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	} {
		if b, err := enc.DecodeString(strings.TrimSpace(s)); err == nil {
			return b, nil
		}
	}
	return nil, fmt.Errorf("not valid base64")
}

func (c *Client) newRequest(ctx context.Context, method, path string, body io.Reader) (*http.Request, error) {
	url := strings.TrimRight(c.cfg.BaseURL, "/") + path
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return nil, fmt.Errorf("mdm: build request: %w", err)
	}
	req.SetBasicAuth("micromdm", c.cfg.APIToken)
	return req, nil
}

func (c *Client) doJSON(req *http.Request, out interface{}) error {
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("http: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
