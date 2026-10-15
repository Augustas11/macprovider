package ws

import (
	"encoding/json"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestToolSelectionCapabilityWire(t *testing.T) {
	capabilities := []pool.ToolSelectionCapability{{ModelID: "mlx-community/Qwen3.6-35B-A3B-4bit", Runtime: "mlx_cache", Modes: []string{"auto", "none", "required", "named"}, Validation: "schema-holdback-v1"}}
	auth := validAuthRequestInitial()
	auth["tool_selection_capabilities"] = capabilities
	req, _, field, err := ParseAuthRequest(mustAuthJSON(t, auth))
	if err != nil {
		t.Fatalf("auth %s %v", field, err)
	}
	if len(req.Hello().ToolSelectionCapabilities) != 1 || req.Hello().ToolSelectionCapabilities[0].Validation != "schema-holdback-v1" {
		t.Fatalf("auth capabilities lost: %+v", req)
	}
	hello := map[string]any{"type": "hello", "version": 1, "tier": 1, "provider_id": "p", "hostname": "test", "model_id": capabilities[0].ModelID, "model_params_b": 35.0, "ram_gb": 128, "max_context_tokens": 50000, "max_concurrency": 1, "throughput_tps_estimate": 1.0, "binary_version": "999.0.0", "attestation": nil, "tool_selection_capabilities": capabilities}
	parsed, field, err := ParseHello(mustAuthJSON(t, hello))
	if err != nil || len(parsed.ToolSelectionCapabilities) != 1 {
		t.Fatalf("hello %s %v %+v", field, err, parsed)
	}
	heartbeat := map[string]any{"type": "heartbeat", "status": "ready", "model_id": capabilities[0].ModelID, "model_params_b": 35.0, "ram_gb": 128, "max_context_tokens": 50000, "max_concurrency": 1, "slots_free": 1, "slots_total": 1, "throughput_tps_estimate": 1.0, "requests_served_since_last": 0, "avg_latency_ms_since_last": 0.0, "throughput_tps_since_last": 0.0, "tool_selection_capabilities": capabilities}
	hb, _, field, err := ParseHeartbeat(mustAuthJSON(t, heartbeat))
	if err != nil || len(hb.ToolSelectionCapabilities) != 1 {
		t.Fatalf("heartbeat %s %v %+v", field, err, hb)
	}
	raw, _ := json.Marshal(pool.Provider{ToolSelectionCapabilities: hb.ToolSelectionCapabilities})
	var projection map[string]json.RawMessage
	_ = json.Unmarshal(raw, &projection)
	if len(projection["tool_selection_capabilities"]) == 0 {
		t.Fatal("poolz lost capabilities")
	}
}
