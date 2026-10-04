package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

type spikeResult struct {
	OSVersion              string            `json:"os_version"`
	OSVersionString        string            `json:"os_version_string"`
	BundleIdentifier       string            `json:"bundle_identifier"`
	BundleVersion          string            `json:"bundle_version"`
	IsSupported            bool              `json:"is_supported"`
	SecureEnclaveAvailable bool              `json:"secure_enclave_available"`
	Identity               identityRecord    `json:"identity"`
	KeyID                  string            `json:"key_id"`
	NonceB64               string            `json:"nonce_b64"`
	AttestationB64         string            `json:"attestation_b64"`
	ClientData             string            `json:"client_data"`
	AssertionB64           string            `json:"assertion_b64"`
	Assertions             []assertionRecord `json:"assertions"`
	AttestStage            string            `json:"attest_stage"`
	AttestError            *probeError       `json:"attest_error"`
	Child                  *childRecord      `json:"child"`
}

type identityRecord struct {
	TeamID                      string            `json:"team_id"`
	Identifier                  string            `json:"identifier"`
	CDHash                      string            `json:"cdhash"`
	EmbeddedProvisioningProfile bool              `json:"embedded_provisioning_profile"`
	ProfileBytes                int64             `json:"profile_bytes"`
	OSStatus                    int32             `json:"os_status"`
	Entitlements                map[string]string `json:"entitlements,omitempty"`
	ErrorDescription            string            `json:"error_description,omitempty"`
}

type assertionRecord struct {
	ClientData    string `json:"client_data"`
	ClientDataB64 string `json:"client_data_b64"`
	AssertionB64  string `json:"assertion_b64"`
}

type probeError struct {
	Domain      string `json:"domain"`
	Code        int    `json:"code"`
	Description string `json:"description"`
}

type childRecord struct {
	Path             string           `json:"path"`
	Requirement      string           `json:"requirement"`
	PID              int              `json:"pid"`
	Pass             bool             `json:"pass"`
	OSStatus         int32            `json:"os_status"`
	OSStatusName     string           `json:"os_status_name"`
	CDHash           string           `json:"cdhash"`
	TeamID           string           `json:"team_id"`
	Identifier       string           `json:"identifier"`
	Flags            uint32           `json:"flags"`
	FlagsHex         string           `json:"flags_hex"`
	FlagNames        []string         `json:"flag_names"`
	UnnamedBitsHex   string           `json:"unnamed_bits_hex"`
	AuditToken       *auditTokenCheck `json:"audit_token"`
	ErrorDescription string           `json:"error_description,omitempty"`
}

type auditTokenCheck struct {
	Available        bool   `json:"available"`
	Pass             bool   `json:"pass"`
	OSStatus         int32  `json:"os_status"`
	OSStatusName     string `json:"os_status_name"`
	ErrorDescription string `json:"error_description,omitempty"`
}

func loadResult(path string) (spikeResult, []byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return spikeResult{}, nil, err
	}
	var result spikeResult
	if err := json.Unmarshal(data, &result); err != nil {
		return spikeResult{}, data, fmt.Errorf("parse result: %w", err)
	}
	return result, data, nil
}

func (r spikeResult) assertionList() ([]assertionRecord, error) {
	if len(r.Assertions) > 0 {
		return r.Assertions, nil
	}
	if r.AssertionB64 != "" {
		return []assertionRecord{{
			ClientData:   r.ClientData,
			AssertionB64: r.AssertionB64,
		}}, nil
	}
	return nil, fmt.Errorf("result has no assertions")
}

func (a assertionRecord) clientBytes() ([]byte, error) {
	if a.ClientDataB64 != "" {
		raw, err := decodeB64(a.ClientDataB64)
		if err != nil {
			return nil, fmt.Errorf("client_data_b64: %w", err)
		}
		if a.ClientData != "" && string(raw) != a.ClientData {
			return nil, fmt.Errorf("client_data_b64 does not match client_data")
		}
		return raw, nil
	}
	if a.ClientData == "" {
		return nil, fmt.Errorf("client_data is empty")
	}
	return []byte(a.ClientData), nil
}

func decodeB64(value string) ([]byte, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, fmt.Errorf("empty")
	}
	encodings := []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	}
	var last error
	for _, enc := range encodings {
		out, err := enc.DecodeString(value)
		if err == nil {
			return out, nil
		}
		last = err
	}
	return nil, last
}
