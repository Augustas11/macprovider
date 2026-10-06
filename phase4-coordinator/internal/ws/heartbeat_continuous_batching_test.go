package ws

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const cbHeartbeatPrefix = `{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":32,"max_context_tokens":32768,"max_concurrency":4,"slots_free":3,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0`

const cbActiveObject = `{"active":true,"mode":"canary","unsupported_reason":null,"authorization_source":"coordinator","policy_authorized":true,"policy_decision_reason":"authorized","runtime_tuple":{"model_id":"model-a","model_sha256":"` + cbHex64 + `","tokenizer_sha256":"` + cbHex64 + `","chat_template_sha256":null,"cache_class":"mixed","kv_dtype":"fp16","requires_moe":true,"hardware_class":"m3-ultra-512","metallib_sha256":"` + cbHex64 + `","kernel_identifier":"paged-kv-v1","provider_cli_version":"1.8.217","live_executable_cdhash":"` + cbCDHash + `"}}`

const (
	cbHex64  = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	cbCDHash = "0123456789abcdef0123456789abcdef01234567"
)

func TestParseHeartbeatContinuousBatchingAccepted(t *testing.T) {
	hb, _, field, err := ParseHeartbeat([]byte(cbHeartbeatPrefix + `,"continuous_batching":` + cbActiveObject + `}`))
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	cb := hb.ContinuousBatching
	if cb == nil || !cb.Active || cb.Mode != "canary" || cb.AuthorizationSource != "coordinator" || !cb.PolicyAuthorized {
		t.Fatalf("continuous_batching = %+v", cb)
	}
	tuple := cb.RuntimeTuple
	if tuple == nil || tuple.ModelID != "model-a" || !tuple.RequiresMoE || tuple.ChatTemplateSHA256 != nil ||
		tuple.LiveExecutableCDHash == nil || *tuple.LiveExecutableCDHash != cbCDHash || tuple.ProviderCLIVersion != "1.8.217" {
		t.Fatalf("runtime_tuple = %+v", tuple)
	}
}

// Observability-only: a malformed object is dropped and the heartbeat (which
// carries capacity and liveness) is still accepted.
func TestParseHeartbeatContinuousBatchingMalformedIsDroppedNotRejected(t *testing.T) {
	for name, object := range map[string]string{
		"not object":     `"yes"`,
		"unknown field":  `{"active":true,"mode":"on","authorization_source":"coordinator","policy_authorized":true,"extra":1}`,
		"missing active": `{"mode":"on","authorization_source":"coordinator","policy_authorized":true}`,
		"bad mode":       `{"active":true,"mode":"turbo","authorization_source":"coordinator","policy_authorized":true}`,
		"control char":   `{"active":true,"mode":"on","authorization_source":"coord\u001binator","policy_authorized":true}`,
		"long token":     `{"active":true,"mode":"on","authorization_source":"` + strings.Repeat("a", 129) + `","policy_authorized":true}`,
		"bad digest":     strings.Replace(cbActiveObject, `"model_sha256":"`+cbHex64, `"model_sha256":"ABC`, 1),
		"bad cdhash":     strings.Replace(cbActiveObject, cbCDHash, "zz", 1),
		"tuple no moe":   strings.Replace(cbActiveObject, `"requires_moe":true,`, ``, 1),
		"oversized":      `{"active":true,"mode":"on","authorization_source":"coordinator","policy_authorized":true,"policy_decision_reason":"` + strings.Repeat("a", 5000) + `"}`,
	} {
		hb, _, field, err := ParseHeartbeat([]byte(cbHeartbeatPrefix + `,"continuous_batching":` + object + `}`))
		if err != nil {
			t.Fatalf("%s: heartbeat rejected field=%q err=%v", name, field, err)
		}
		if hb.ContinuousBatching != nil {
			t.Fatalf("%s: malformed continuous_batching kept: %+v", name, hb.ContinuousBatching)
		}
	}
}

func TestPoolzExposesHeartbeatContinuousBatching(t *testing.T) {
	cfg := capacityTestConfig(0)
	cfg.Auth.OperatorKey = "operator-key-for-cb-poolz-test-0123456789"
	registry := pool.NewRegistry(nil)
	server := NewServer(cfg, registry, zerolog.Nop())
	registerCapacityTestProvider(t, server, registry, 4)

	poolz := func() map[string]any {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/poolz", nil)
		req.Header.Set("Authorization", "Bearer "+cfg.Auth.OperatorKey)
		rec := httptest.NewRecorder()
		server.handlePoolz(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("/poolz status %d", rec.Code)
		}
		var body map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("/poolz json: %v", err)
		}
		return body
	}
	summaryInt := func(body map[string]any, key string) float64 {
		t.Helper()
		v, ok := body["summary"].(map[string]any)[key].(float64)
		if !ok {
			t.Fatalf("summary.%s missing: %v", key, body["summary"])
		}
		return v
	}

	body := poolz()
	if summaryInt(body, "continuous_batching_reporting") != 0 || summaryInt(body, "continuous_batching_active") != 0 {
		t.Fatalf("summary before heartbeat = %v", body["summary"])
	}

	server.handleHeartbeat(nil, "provider-a", "assigned-a", []byte(cbHeartbeatPrefix+`,"continuous_batching":`+cbActiveObject+`}`))
	body = poolz()
	if summaryInt(body, "continuous_batching_reporting") != 1 || summaryInt(body, "continuous_batching_active") != 1 {
		t.Fatalf("summary after heartbeat = %v", body["summary"])
	}
	row := body["pool"].([]any)[0].(map[string]any)
	cb, ok := row["continuous_batching"].(map[string]any)
	if !ok || cb["active"] != true || cb["observed_at"] == "" {
		t.Fatalf("pool row continuous_batching = %v", row["continuous_batching"])
	}
	tuple := cb["runtime_tuple"].(map[string]any)
	if tuple["metallib_sha256"] != cbHex64 || tuple["chat_template_sha256"] != nil {
		t.Fatalf("runtime_tuple = %v", tuple)
	}

	// A later heartbeat without the field (a downgraded CLI) clears it.
	server.handleHeartbeat(nil, "provider-a", "assigned-a", []byte(cbHeartbeatPrefix+`}`))
	body = poolz()
	if _, present := body["pool"].([]any)[0].(map[string]any)["continuous_batching"]; present {
		t.Fatal("continuous_batching survived a heartbeat that omitted it")
	}
	if summaryInt(body, "continuous_batching_reporting") != 0 {
		t.Fatalf("summary after clearing = %v", body["summary"])
	}
}
