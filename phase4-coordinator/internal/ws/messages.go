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
	ModelHash             string          `json:"model_hash,omitempty"`
	ModelParamsB          float64         `json:"model_params_b"`
	RAMGB                 int             `json:"ram_gb"`
	MaxContextTokens      int             `json:"max_context_tokens"`
	MaxConcurrency        int             `json:"max_concurrency"`
	ThroughputTPSEstimate float64         `json:"throughput_tps_estimate"`
	BinaryVersion         string          `json:"binary_version"`
	Attestation           json.RawMessage `json:"attestation"`
	EndpointURL           *string         `json:"endpoint_url,omitempty"`
}

type HelloAck struct {
	Type                     string `json:"type"`
	CoordinatorVersion       int    `json:"coordinator_version"`
	AssignedID               string `json:"assigned_id"`
	HeartbeatIntervalS       int    `json:"heartbeat_interval_s"`
	Tier                     string `json:"tier,omitempty"`
	RecommendedBinaryVersion string `json:"recommended_binary_version,omitempty"`
}

type Heartbeat struct {
	Type                    string  `json:"type"`
	Status                  string  `json:"status"`
	ModelID                 string  `json:"model_id"`
	ModelParamsB            float64 `json:"model_params_b"`
	RAMGB                   int     `json:"ram_gb"`
	MaxContextTokens        int     `json:"max_context_tokens"`
	MaxConcurrency          int     `json:"max_concurrency"`
	SlotsFree               int     `json:"slots_free"`
	SlotsTotal              int     `json:"slots_total"`
	ThroughputTPSEstimate   float64 `json:"throughput_tps_estimate"`
	RequestsServedSinceLast int     `json:"requests_served_since_last"`
	AvgLatencyMSSinceLast   float64 `json:"avg_latency_ms_since_last"`
	ThroughputTPSSinceLast  float64 `json:"throughput_tps_since_last"`
}

type StateUpdate struct {
	Type            string          `json:"type"`
	State           string          `json:"state"`
	Reason          string          `json:"reason"`
	Since           string          `json:"since"`
	MetricsSnapshot MetricsSnapshot `json:"metrics_snapshot"`
}

type PreflightAck struct {
	Type             string `json:"type"`
	RequestID        string `json:"request_id"`
	Accepted         bool   `json:"accepted"`
	EstimatedWaitMS  int    `json:"estimated_wait_ms"`
	Reason           string `json:"reason"`
	MaxContextTokens int    `json:"max_context_tokens"`
}

type DrainStatus struct {
	Type                  string `json:"type"`
	Phase                 string `json:"phase"`
	InflightRequests      int    `json:"inflight_requests"`
	EstimatedDrainSeconds int    `json:"estimated_drain_seconds"`
}

type InferenceRequest struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Stream    bool   `json:"stream"`
	Body      string `json:"body"`
}

type InferenceResponseChunk struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Seq       int    `json:"seq"`
	Data      string `json:"data"`
}

type InferenceResponseEnd struct {
	Type       string          `json:"type"`
	RequestID  string          `json:"request_id"`
	Status     string          `json:"status"`
	ChunksSent int             `json:"chunks_sent"`
	Usage      json.RawMessage `json:"usage,omitempty"`
	Error      string          `json:"error,omitempty"`
}

type CancelRequest struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Reason    string `json:"reason"`
}

type NakError struct {
	Code    string                 `json:"code"`
	Message string                 `json:"message,omitempty"`
	Details map[string]interface{} `json:"details,omitempty"`
}

type Nak struct {
	Type      string   `json:"type"`
	InReplyTo string   `json:"in_reply_to"`
	Error     NakError `json:"error"`
}

var preflightRejectionReasons = map[string]struct{}{
	"context_exceeds_capacity": {},
	"queue_full":               {},
	"draining":                 {},
	"model_not_loaded":         {},
	"unhealthy":                {},
	"tier_mismatch":            {},
}

type MetricsSnapshot struct {
	SlotsFree  *int `json:"slots_free"`
	SlotsTotal *int `json:"slots_total"`
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
	if v, ok := raw["model_hash"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &h.ModelHash); err != nil {
			return Hello{}, "model_hash", err
		}
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
	if ok {
		h.Attestation = attestation
	}
	if v, ok := raw["endpoint_url"]; ok && string(v) != "null" {
		var endpoint string
		if err := json.Unmarshal(v, &endpoint); err != nil {
			return Hello{}, "endpoint_url", err
		}
		h.EndpointURL = &endpoint
	}
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

func ParseHeartbeat(payload []byte) (Heartbeat, string, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return Heartbeat{}, "json", err
	}
	var hb Heartbeat
	if err := requireString(raw, "type", &hb.Type); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if hb.Type != "heartbeat" {
		return Heartbeat{}, "type", fmt.Errorf("expected heartbeat, got %q", hb.Type)
	}
	if err := requireString(raw, "status", &hb.Status); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireString(raw, "model_id", &hb.ModelID); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireFloat(raw, "model_params_b", &hb.ModelParamsB); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireInt(raw, "ram_gb", &hb.RAMGB); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireInt(raw, "max_context_tokens", &hb.MaxContextTokens); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireInt(raw, "max_concurrency", &hb.MaxConcurrency); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireInt(raw, "slots_free", &hb.SlotsFree); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireInt(raw, "slots_total", &hb.SlotsTotal); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireFloat(raw, "throughput_tps_estimate", &hb.ThroughputTPSEstimate); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireInt(raw, "requests_served_since_last", &hb.RequestsServedSinceLast); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireFloat(raw, "avg_latency_ms_since_last", &hb.AvgLatencyMSSinceLast); err != nil {
		return Heartbeat{}, err.Field, err
	}
	if err := requireFloat(raw, "throughput_tps_since_last", &hb.ThroughputTPSSinceLast); err != nil {
		return Heartbeat{}, err.Field, err
	}
	return hb, "", nil
}

func ParseStateUpdate(payload []byte) (StateUpdate, string, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return StateUpdate{}, "json", err
	}
	var update StateUpdate
	if err := requireString(raw, "type", &update.Type); err != nil {
		return StateUpdate{}, err.Field, err
	}
	if update.Type != "state_update" {
		return StateUpdate{}, "type", fmt.Errorf("expected state_update, got %q", update.Type)
	}
	if err := requireString(raw, "state", &update.State); err != nil {
		return StateUpdate{}, err.Field, err
	}
	if v, ok := raw["reason"]; ok {
		_ = json.Unmarshal(v, &update.Reason)
	}
	if v, ok := raw["since"]; ok {
		_ = json.Unmarshal(v, &update.Since)
	}
	if v, ok := raw["metrics_snapshot"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &update.MetricsSnapshot); err != nil {
			return StateUpdate{}, "metrics_snapshot", err
		}
	}
	return update, "", nil
}

func ParsePreflightAck(payload []byte) (PreflightAck, string, error) {
	var ack PreflightAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		return PreflightAck{}, "json", err
	}
	if ack.Type != "preflight_ack" {
		return PreflightAck{}, "type", fmt.Errorf("expected preflight_ack, got %q", ack.Type)
	}
	if ack.RequestID == "" {
		return PreflightAck{}, "request_id", fieldError{Field: "missing request_id"}
	}
	if !ack.Accepted {
		if _, ok := preflightRejectionReasons[ack.Reason]; !ok {
			return PreflightAck{}, "reason", fieldError{Field: "invalid reason"}
		}
	}
	return ack, "", nil
}

func ParseDrainStatus(payload []byte) (DrainStatus, string, error) {
	var status DrainStatus
	if err := json.Unmarshal(payload, &status); err != nil {
		return DrainStatus{}, "json", err
	}
	if status.Type != "drain_status" {
		return DrainStatus{}, "type", fmt.Errorf("expected drain_status, got %q", status.Type)
	}
	switch status.Phase {
	case "starting", "in_progress", "complete":
	default:
		return DrainStatus{}, "phase", fieldError{Field: "invalid phase"}
	}
	if status.InflightRequests < 0 {
		return DrainStatus{}, "inflight_requests", fieldError{Field: "invalid inflight_requests"}
	}
	if status.EstimatedDrainSeconds < 0 {
		return DrainStatus{}, "estimated_drain_seconds", fieldError{Field: "invalid estimated_drain_seconds"}
	}
	return status, "", nil
}

func ParseNak(payload []byte) (Nak, string, error) {
	var nak Nak
	if err := json.Unmarshal(payload, &nak); err != nil {
		return Nak{}, "json", err
	}
	if nak.Type != "nak" {
		return Nak{}, "type", fmt.Errorf("expected nak, got %q", nak.Type)
	}
	if nak.InReplyTo == "" {
		return Nak{}, "in_reply_to", fieldError{Field: "missing in_reply_to"}
	}
	if nak.Error.Code == "" {
		return Nak{}, "error.code", fieldError{Field: "missing error.code"}
	}
	return nak, "", nil
}
