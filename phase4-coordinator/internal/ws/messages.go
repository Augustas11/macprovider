package ws

import (
	"encoding/json"
	"fmt"
)

type Hello struct {
	Type                  string          `json:"type"`
	Version               int             `json:"version"`
	Tier                  int             `json:"tier"`
	ProviderID            string          `json:"provider_id"`
	Hostname              string          `json:"hostname"`
	ModelID               string          `json:"model_id"`
	ModelParamsB          float64         `json:"model_params_b"`
	RAMGB                 int             `json:"ram_gb"`
	MaxContextTokens      int             `json:"max_context_tokens"`
	MaxConcurrency        int             `json:"max_concurrency"`
	ThroughputTPSEstimate float64         `json:"throughput_tps_estimate"`
	BinaryVersion         string          `json:"binary_version"`
	Attestation           json.RawMessage `json:"attestation"`
}

type HelloAck struct {
	Type               string `json:"type"`
	CoordinatorVersion int    `json:"coordinator_version"`
	AssignedID         string `json:"assigned_id"`
	HeartbeatIntervalS int    `json:"heartbeat_interval_s"`
}

func ParseHello(payload []byte) (Hello, string, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return Hello{}, "json", err
	}

	var h Hello
	if err := requireString(raw, "type", &h.Type); err != nil {
		return Hello{}, err.Field, err
	}
	if h.Type != "hello" {
		return Hello{}, "type", fmt.Errorf("expected hello, got %q", h.Type)
	}
	if err := requireInt(raw, "version", &h.Version); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireInt(raw, "tier", &h.Tier); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireString(raw, "provider_id", &h.ProviderID); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireString(raw, "hostname", &h.Hostname); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireString(raw, "model_id", &h.ModelID); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireFloat(raw, "model_params_b", &h.ModelParamsB); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireInt(raw, "ram_gb", &h.RAMGB); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireInt(raw, "max_context_tokens", &h.MaxContextTokens); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireInt(raw, "max_concurrency", &h.MaxConcurrency); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireFloat(raw, "throughput_tps_estimate", &h.ThroughputTPSEstimate); err != nil {
		return Hello{}, err.Field, err
	}
	if err := requireString(raw, "binary_version", &h.BinaryVersion); err != nil {
		return Hello{}, err.Field, err
	}
	attestation, ok := raw["attestation"]
	if !ok {
		return Hello{}, "missing attestation", fieldError{Field: "missing attestation"}
	}
	h.Attestation = attestation
	return h, "", nil
}

type fieldError struct {
	Field string
}

func (e fieldError) Error() string {
	return e.Field
}

func requireString(raw map[string]json.RawMessage, field string, out *string) *fieldError {
	v, ok := raw[field]
	if !ok {
		return &fieldError{Field: "missing " + field}
	}
	if err := json.Unmarshal(v, out); err != nil || *out == "" {
		return &fieldError{Field: field}
	}
	return nil
}

func requireInt(raw map[string]json.RawMessage, field string, out *int) *fieldError {
	v, ok := raw[field]
	if !ok {
		return &fieldError{Field: "missing " + field}
	}
	if err := json.Unmarshal(v, out); err != nil {
		return &fieldError{Field: field}
	}
	return nil
}

func requireFloat(raw map[string]json.RawMessage, field string, out *float64) *fieldError {
	v, ok := raw[field]
	if !ok {
		return &fieldError{Field: "missing " + field}
	}
	if err := json.Unmarshal(v, out); err != nil {
		return &fieldError{Field: field}
	}
	return nil
}
