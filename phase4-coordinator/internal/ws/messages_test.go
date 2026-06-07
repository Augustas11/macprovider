package ws

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseNakAcceptsSwiftSpecShape(t *testing.T) {
	payload := []byte(`{"type":"nak","in_reply_to":"req-nak","error":{"code":"unknown_message_type","message":"Unrecognized message type: 'inference_request'"}}`)

	nak, field, err := ParseNak(payload)
	if err != nil {
		t.Fatalf("ParseNak field=%q err=%v", field, err)
	}
	if nak.Type != "nak" {
		t.Fatalf("type = %q", nak.Type)
	}
	if nak.InReplyTo != "req-nak" {
		t.Fatalf("in_reply_to = %q", nak.InReplyTo)
	}
	if nak.Error.Code != "unknown_message_type" {
		t.Fatalf("error.code = %q", nak.Error.Code)
	}
	if nak.Error.Message != "Unrecognized message type: 'inference_request'" {
		t.Fatalf("error.message = %q", nak.Error.Message)
	}
}

func TestParseHeartbeatPreservesRollingMetrics(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5}`)

	hb, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if hb.RequestsServedSinceLast != 12 {
		t.Fatalf("requests_served_since_last = %d", hb.RequestsServedSinceLast)
	}
	if hb.AvgLatencyMSSinceLast != 450.0 {
		t.Fatalf("avg_latency_ms_since_last = %v", hb.AvgLatencyMSSinceLast)
	}
	if hb.ThroughputTPSSinceLast != 18.5 {
		t.Fatalf("throughput_tps_since_last = %v", hb.ThroughputTPSSinceLast)
	}
}

func TestParseAuthInitialAcceptsLegacyAbsentSpec010(t *testing.T) {
	req, presence, field, err := ParseAuthRequest(mustAuthJSON(t, validAuthRequestInitial()))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if presence.SupportedModels || presence.PublishesSupportedModels {
		t.Fatalf("presence = %+v, want zero", presence)
	}
	if req.SupportedModels != nil {
		t.Fatalf("supported_models = %#v, want nil", req.SupportedModels)
	}
	if req.PublishesSupportedModels {
		t.Fatal("publishes_supported_models = true, want false")
	}
}

func TestParseAuthInitialAcceptsSingleEntryCatalog(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["supported_models"] = []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}

	req, presence, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if !presence.SupportedModels || presence.PublishesSupportedModels {
		t.Fatalf("presence = %+v", presence)
	}
	if len(req.SupportedModels) != 1 || req.SupportedModels[0] != "mlx-community/Qwen2.5-7B-Instruct-4bit" {
		t.Fatalf("supported_models = %#v", req.SupportedModels)
	}
}

func TestParseAuthInitialRejectsOverlongEntry(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["supported_models"] = []string{strings.Repeat("x", 257)}

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if field != "supported_models entry exceeds 256 bytes" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseAuthInitialRejectsEmptyCatalog(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["supported_models"] = []string{}

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if field != "supported_models cannot be empty" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseAuthInitialRejectsOverlongCatalog(t *testing.T) {
	payload := validAuthRequestInitial()
	models := make([]string, 65)
	for i := range models {
		models[i] = "model-" + string(rune('A'+i))
	}
	models[0] = "mlx-community/Qwen2.5-7B-Instruct-4bit"
	payload["supported_models"] = models

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if field != "supported_models exceeds 64 entries" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseAuthInitialRejectsDuplicateUnderNFCASCIIFold(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["model_id"] = "Model-A"
	payload["supported_models"] = []string{"Model-A", "MODEL-A"}

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if field != "supported_models contains duplicate entries" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseAuthInitialRejectsMissingModelID(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["model_id"] = "X"
	payload["supported_models"] = []string{"Y"}

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if !strings.Contains(field, "missing model_id") {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseAuthProofAcceptsAbsentSpec010(t *testing.T) {
	req, presence, field, err := ParseAuthRequest(mustAuthJSON(t, validAuthRequestProof()))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if req.Stage != "proof" {
		t.Fatalf("stage = %q", req.Stage)
	}
	if presence.SupportedModels || presence.PublishesSupportedModels {
		t.Fatalf("presence = %+v, want zero", presence)
	}
}

func TestParseAuthProofRetainsSpec010WhenPresent(t *testing.T) {
	payload := validAuthRequestProof()
	payload["supported_models"] = []string{"X"}

	req, presence, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if !presence.SupportedModels || presence.PublishesSupportedModels {
		t.Fatalf("presence = %+v", presence)
	}
	if len(req.SupportedModels) != 1 || req.SupportedModels[0] != "X" {
		t.Fatalf("supported_models = %#v", req.SupportedModels)
	}
}

func validAuthRequestInitial() map[string]any {
	return map[string]any{
		"type":                     "auth_request",
		"version":                  2,
		"stage":                    "initial",
		"provider_id":              "m4-anon",
		"hostname":                 "provider.local",
		"model_id":                 "mlx-community/Qwen2.5-7B-Instruct-4bit",
		"model_params_b":           7.0,
		"ram_gb":                   16,
		"max_context_tokens":       50000,
		"max_concurrency":          1,
		"throughput_tps_estimate":  19.8,
		"binary_version":           "0.1.0",
		"provider_ecdh_public_key": "test-public-key",
		"tier2_capabilities":       map[string]any{"encrypted_leg": true, "attestation": true, "aead_suites": []string{"AES-256-GCM"}},
	}
}

func validAuthRequestProof() map[string]any {
	return map[string]any{
		"type":            "auth_request",
		"version":         2,
		"stage":           "proof",
		"auth_attempt_id": "auth-1",
		"provider_id":     "m4-anon",
	}
}

func mustAuthJSON(t *testing.T, payload map[string]any) []byte {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("json marshal: %v", err)
	}
	return b
}
