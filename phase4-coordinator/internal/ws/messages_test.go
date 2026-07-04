package ws

import (
	"encoding/base64"
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

	hb, presence, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if presence != (HeartbeatPresence{}) {
		t.Fatalf("presence = %+v, want zero", presence)
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

func TestInferenceResponseEndPreservesSettlementReceiptDeadline(t *testing.T) {
	payload := []byte(`{"type":"inference_response_end","request_id":"req-1","status":"complete","chunks_sent":1,"terminal_state_ts_unix_ms":1710000000123,"receipt_pending_deadline_seconds":120,"late_receipt_settlement":"not_settled","receipt":"tuple.sig"}`)

	var end InferenceResponseEnd
	if err := json.Unmarshal(payload, &end); err != nil {
		t.Fatalf("unmarshal end: %v", err)
	}
	if end.TerminalStateTSUnixMS != 1710000000123 {
		t.Fatalf("TerminalStateTSUnixMS = %d", end.TerminalStateTSUnixMS)
	}
	if end.ReceiptPendingDeadlineSeconds != 120 {
		t.Fatalf("ReceiptPendingDeadlineSeconds = %d", end.ReceiptPendingDeadlineSeconds)
	}
	if end.LateReceiptSettlement != "not_settled" {
		t.Fatalf("LateReceiptSettlement = %q", end.LateReceiptSettlement)
	}
}

func TestParseHeartbeatL1AcceptsLegacyAbsentSPEC011Fields(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5}`)

	hb, presence, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if presence != (HeartbeatPresence{}) {
		t.Fatalf("presence = %+v, want zero", presence)
	}
	if hb.ModelHash != "" || hb.Loading {
		t.Fatalf("SPEC-011 fields = (%q, %v), want zero", hb.ModelHash, hb.Loading)
	}
}

func TestParseHeartbeatAcceptsSPEC011Fields(t *testing.T) {
	hash := "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12"
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"model_hash":"` + hash + `","loading":true}`)

	hb, presence, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if !presence.ModelHash || !presence.Loading {
		t.Fatalf("presence = %+v, want both true", presence)
	}
	if hb.ModelHash != hash || !hb.Loading {
		t.Fatalf("SPEC-011 fields = (%q, %v)", hb.ModelHash, hb.Loading)
	}
}

func TestParseHeartbeatAcceptsLastAutoupdateEventObject(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"last_autoupdate_event":{"event":"provider_autoupdate","phase":"download","outcome":"failure","failure_class":"target_release_not_found"}}`)

	hb, _, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if !json.Valid(hb.LastAutoupdateEvent) || !strings.Contains(string(hb.LastAutoupdateEvent), "target_release_not_found") {
		t.Fatalf("last_autoupdate_event = %s", hb.LastAutoupdateEvent)
	}
}

func TestParseHeartbeatRejectsOversizedLastAutoupdateEvent(t *testing.T) {
	large := `{"event":"provider_autoupdate","extra":"` + strings.Repeat("x", 4096) + `"}`
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"last_autoupdate_event":` + large + `}`)

	_, _, field, err := ParseHeartbeat(payload)
	if err == nil {
		t.Fatal("ParseHeartbeat err = nil")
	}
	if field != "last_autoupdate_event" {
		t.Fatalf("field = %q", field)
	}
}

func TestParseHeartbeatRejectsOversizedModelID(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"` + strings.Repeat("m", 257) + `","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5}`)

	_, _, field, err := ParseHeartbeat(payload)
	if err == nil {
		t.Fatal("ParseHeartbeat err = nil")
	}
	if field != "model_id" {
		t.Fatalf("field = %q", field)
	}
}

func TestParseStateUpdateAcceptsLastAutoupdateEvent(t *testing.T) {
	payload := []byte(`{"type":"state_update","state":"draining","reason":"autoupdate_to_1.7.0","since":"2026-06-29T15:00:00Z","metrics_snapshot":{"slots_free":0,"slots_total":1},"last_autoupdate_event":{"event":"provider_autoupdate","phase":"drain","outcome":"in_progress"}}`)

	update, field, err := ParseStateUpdate(payload)
	if err != nil {
		t.Fatalf("ParseStateUpdate field=%q err=%v", field, err)
	}
	if update.Reason != "autoupdate_to_1.7.0" {
		t.Fatalf("reason = %q", update.Reason)
	}
	if !json.Valid(update.LastAutoupdateEvent) {
		t.Fatalf("last_autoupdate_event invalid: %s", update.LastAutoupdateEvent)
	}
}

func TestParseDrainStatusAcceptsAutoupdateTimeoutSkipped(t *testing.T) {
	status, field, err := ParseDrainStatus([]byte(`{"type":"drain_status","phase":"timeout_skipped","inflight_requests":1,"estimated_drain_seconds":0}`))
	if err != nil {
		t.Fatalf("ParseDrainStatus field=%q err=%v", field, err)
	}
	if status.Phase != "timeout_skipped" {
		t.Fatalf("phase = %q", status.Phase)
	}
}

func TestAdmissionFramesAdvertiseAutoupdateDrainExtensions(t *testing.T) {
	ackBytes, err := json.Marshal(HelloAck{Type: "hello_ack", AutoupdateDrainExtensions: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(ackBytes), `"autoupdate_drain_extensions":true`) {
		t.Fatalf("hello_ack = %s", ackBytes)
	}
	responseBytes, err := json.Marshal(AuthResponse{Type: "auth_response", Version: 2, Status: "accepted", AutoupdateDrainExtensions: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(responseBytes), `"autoupdate_drain_extensions":true`) {
		t.Fatalf("auth_response = %s", responseBytes)
	}
}

func TestParseHeartbeatRejectsModelHashWrongType(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"model_hash":123}`)

	_, _, field, err := ParseHeartbeat(payload)
	if err == nil {
		t.Fatal("ParseHeartbeat err = nil")
	}
	if field != "model_hash" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseHeartbeatRejectsLoadingWrongType(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"loading":"yes"}`)

	_, _, field, err := ParseHeartbeat(payload)
	if err == nil {
		t.Fatal("ParseHeartbeat err = nil")
	}
	if field != "loading" {
		t.Fatalf("badField = %q", field)
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
	if req.ProviderReceiptPublicKey != "" || req.ProviderReceiptPubkey != nil {
		t.Fatalf("receipt key = (%q, %#v), want absent", req.ProviderReceiptPublicKey, req.ProviderReceiptPubkey)
	}
}

func TestParseAuthInitialAcceptsProviderReceiptPublicKey(t *testing.T) {
	payload := validAuthRequestInitial()
	pubkey := bytesOf(0x42, 32)
	payload["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(pubkey)

	req, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if req.ProviderReceiptPublicKey != base64.StdEncoding.EncodeToString(pubkey) {
		t.Fatalf("ProviderReceiptPublicKey = %q", req.ProviderReceiptPublicKey)
	}
	if string(req.ProviderReceiptPubkey) != string(pubkey) {
		t.Fatalf("ProviderReceiptPubkey = %#v, want %#v", req.ProviderReceiptPubkey, pubkey)
	}
}

func TestParseAuthInitialRejectsInvalidProviderReceiptPublicKey(t *testing.T) {
	for name, value := range map[string]string{
		"invalid_base64": "not base64",
		"wrong_length":   base64.StdEncoding.EncodeToString(bytesOf(0x42, 31)),
	} {
		t.Run(name, func(t *testing.T) {
			payload := validAuthRequestInitial()
			payload["provider_receipt_public_key"] = value

			_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
			if err == nil {
				t.Fatal("ParseAuthRequest err = nil")
			}
			if field != "provider_receipt_public_key" {
				t.Fatalf("badField = %q", field)
			}
		})
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
	// SPEC-010 v1.5 R-3.1.4 / R-3.1.9 LOCKED containment substring.
	if field != "model_id not in supported_models" {
		t.Fatalf("badField = %q, want %q (SPEC-010 R-3.1.4 locked oracle)",
			field, "model_id not in supported_models")
	}
}

// TestParseAuthInitialRejectsSupportedModelsWrongType pins the SPEC-010
// v1.5 R-3.1.9 step-1 LOCKED substring "supported_models must be array
// of strings" for the JSON-type-check failure path. Without the exact
// substring, the wire-side AC-K.15 surfacing falls through to the
// generic envelope close (the pre-merge audit CRITICAL [code:1.1]).
func TestParseAuthInitialRejectsSupportedModelsWrongType(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["supported_models"] = "not-an-array"

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if field != "supported_models must be array of strings" {
		t.Fatalf("badField = %q, want %q (SPEC-010 R-3.1.9 step-1 locked oracle)",
			field, "supported_models must be array of strings")
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

func bytesOf(value byte, count int) []byte {
	out := make([]byte, count)
	for i := range out {
		out[i] = value
	}
	return out
}

// TestParseHelloRejectsControlCharsInRequiredStrings pins SPEC-002
// v1.5.1 R-2 / issue #197 R4 security: provider-supplied required
// strings on a hello (provider_id, hostname, model_id, binary_version)
// MUST be rejected at parse time when they contain control characters
// (C0, DEL, C1) so they cannot inject terminal-CSI sequences into
// structured logs or close-frame reason strings. JSON “ decodes
// to U+009B and is valid UTF-8 but would otherwise pass the parser.
func TestParseHelloRejectsControlCharsInRequiredStrings(t *testing.T) {
	base := map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             "p-ok",
		"hostname":                "h-ok",
		"model_id":                "m-ok",
		"model_params_b":          7.0,
		"ram_gb":                  16,
		"max_context_tokens":      50000,
		"max_concurrency":         1,
		"throughput_tps_estimate": 19.8,
		"binary_version":          "0.1.0",
		"attestation":             nil,
	}
	for _, field := range []string{"provider_id", "hostname", "model_id", "binary_version"} {
		for name, bad := range map[string]string{
			"c0_null":      "p-\x00",
			"c0_lf":        "p-\n",
			"c1_csi_utf8":  "p-",
			"c1_low_utf8":  "p-",
			"c1_high_utf8": "p-",
			"del":          "p-\x7f",
		} {
			t.Run(field+"/"+name, func(t *testing.T) {
				payload := make(map[string]any, len(base))
				for k, v := range base {
					payload[k] = v
				}
				payload[field] = bad
				raw, err := json.Marshal(payload)
				if err != nil {
					t.Fatalf("marshal: %v", err)
				}
				_, badField, err := ParseHello(raw)
				if err == nil {
					t.Fatalf("ParseHello accepted %s=%q", field, bad)
				}
				if badField != field {
					t.Fatalf("badField=%q, want %q", badField, field)
				}
			})
		}
	}
}

func TestParseHelloRejectsOversizedHandshakeFields(t *testing.T) {
	base := map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             "p-ok",
		"hostname":                "h-ok",
		"model_id":                "m-ok",
		"model_params_b":          7.0,
		"ram_gb":                  16,
		"max_context_tokens":      50000,
		"max_concurrency":         1,
		"throughput_tps_estimate": 19.8,
		"binary_version":          "0.1.0",
		"attestation":             nil,
	}
	for _, tc := range []struct {
		name  string
		field string
		value any
	}{
		{name: "hostname", field: "hostname", value: strings.Repeat("h", 254)},
		{name: "model_id", field: "model_id", value: strings.Repeat("m", 257)},
		{name: "binary_version", field: "binary_version", value: strings.Repeat("1", 33)},
		{name: "attestation", field: "attestation", value: strings.Repeat("a", 1025)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload := make(map[string]any, len(base))
			for k, v := range base {
				payload[k] = v
			}
			payload[tc.field] = tc.value
			raw, err := json.Marshal(payload)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			_, badField, err := ParseHello(raw)
			if err == nil {
				t.Fatalf("ParseHello accepted oversized %s", tc.field)
			}
			if badField != tc.field {
				t.Fatalf("badField=%q, want %q", badField, tc.field)
			}
		})
	}
}

func TestParseAuthRequestRejectsOversizedHandshakeFields(t *testing.T) {
	initial := validAuthRequestInitial()
	initial["hostname"] = strings.Repeat("h", 254)
	if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, initial)); err == nil || field != "hostname" {
		t.Fatalf("oversized hostname field=%q err=%v, want hostname error", field, err)
	}

	initial = validAuthRequestInitial()
	initial["model_id"] = strings.Repeat("m", 257)
	if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, initial)); err == nil || field != "model_id" {
		t.Fatalf("oversized model_id field=%q err=%v, want model_id error", field, err)
	}

	initial = validAuthRequestInitial()
	initial["binary_version"] = strings.Repeat("1", 33)
	if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, initial)); err == nil || field != "binary_version" {
		t.Fatalf("oversized binary_version field=%q err=%v, want binary_version error", field, err)
	}

	proof := validAuthRequestProof()
	proof["attestation_token"] = strings.Repeat("a", 1025)
	if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, proof)); err == nil || field != "attestation_token" {
		t.Fatalf("oversized attestation_token field=%q err=%v, want attestation_token error", field, err)
	}
}
