// Package mdm implements Phase 2 Track P2-A MDM enrollment profile generation
// (Scenario B) and Phase 3 MicroMDM API client for live MDA round-trips.
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
func (c *Client) ListDevices(ctx context.Context) ([]Device, error) {
	req, err := c.newRequest(ctx, http.MethodGet, "/v1/devices", nil)
	if err != nil {
		return nil, err
	}
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
	serial = strings.ToUpper(strings.TrimSpace(serial))
	for _, d := range devices {
		if strings.ToUpper(strings.TrimSpace(d.SerialNumber)) == serial {
			return d, true, nil
		}
	}
	return Device{}, false, nil
}

// commandPayload is the JSON body for POST /v1/commands.
type commandPayload struct {
	UDID    string          `json:"udid"`
	Payload json.RawMessage `json:"payload"`
}

// EnqueueDeviceInformationAttestation enqueues a DeviceInformation MDM command
// for udid with DeviceAttestation and DeviceAttestationNonce queries. The nonce
// is base64-encoded before sending (Apple MDM plist <data> field format).
//
// nonce32 should be 32 bytes — SHA256 of the provider's SE public key so that
// the resulting MDA freshness extension can be verified with verifyMDAFreshness.
func (c *Client) EnqueueDeviceInformationAttestation(ctx context.Context, udid string, nonce32 []byte) error {
	nonceB64 := base64.StdEncoding.EncodeToString(nonce32)
	// MicroMDM accepts raw plist-like JSON for MDM commands. The Queries list
	// is an array of string keys; DeviceAttestationNonce is a base64 data blob.
	cmdBody := map[string]interface{}{
		"request_type": "DeviceInformation",
		"queries":      []string{"DeviceAttestation"},
		"device_attestation_nonce": nonceB64,
	}
	cmdRaw, err := json.Marshal(cmdBody)
	if err != nil {
		return fmt.Errorf("mdm enqueue: marshal command: %w", err)
	}
	payload := commandPayload{UDID: udid, Payload: cmdRaw}
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("mdm enqueue: marshal payload: %w", err)
	}
	req, err := c.newRequest(ctx, http.MethodPost, "/v1/commands", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("mdm enqueue: http: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("mdm enqueue: status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

// DeviceAttestationResult holds the parsed DeviceAttestation fields from a
// DeviceInformation command response (polled or received via webhook).
type DeviceAttestationResult struct {
	// CertificateChain holds the raw DER bytes of each certificate in the
	// Apple MDA chain (leaf first), as returned by the device.
	CertificateChain [][]byte
}

// ParseDeviceAttestationFromPlist parses a MicroMDM device information response
// body (JSON wrapping plist fields) and extracts the DeviceAttestation chain.
//
// MicroMDM v1.13 returns device responses via GET /v1/commands when the command
// is polled. The response format is a JSON object with a "payload" key containing
// the MDM CheckIn/Acknowledge plist decoded into JSON. The DeviceAttestation key
// holds a base64-encoded sequence of DER certificates (Apple-specific format:
// either a JSON array of base64 strings or a concatenated DER blob).
//
// This function handles both variants. When the format is unknown it returns
// (nil, ErrNoDeviceAttestation).
func ParseDeviceAttestationFromPlist(data []byte) (*DeviceAttestationResult, error) {
	// Unwrap MicroMDM command response envelope.
	var outer struct {
		Payload struct {
			DeviceAttestation interface{} `json:"DeviceAttestation"`
		} `json:"payload"`
	}
	// Also try flat parse (direct MDM response JSON).
	var flat struct {
		DeviceAttestation interface{} `json:"DeviceAttestation"`
	}
	var parsed interface{}
	if err := json.Unmarshal(data, &outer); err == nil && outer.Payload.DeviceAttestation != nil {
		parsed = outer.Payload.DeviceAttestation
	} else if err2 := json.Unmarshal(data, &flat); err2 == nil && flat.DeviceAttestation != nil {
		parsed = flat.DeviceAttestation
	} else {
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
