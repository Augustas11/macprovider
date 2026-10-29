package ws

import (
	"encoding/json"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestConversationCacheHeartbeatAndOperatorProjection(t *testing.T) {
	r := pool.NewRegistry(nil)
	server := NewServer(capacityTestConfig(0), r, zerolog.Nop())
	registerCapacityTestProvider(t, server, r, 4)
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7,"ram_gb":32,"max_context_tokens":32768,"max_concurrency":4,"slots_free":4,"slots_total":4,"throughput_tps_estimate":20,"requests_served_since_last":0,"avg_latency_ms_since_last":0,"throughput_tps_since_last":0,"conversation_cache":{"process_id":"proc-1","models":[{"model_id":"model-a","lookups":10,"hits":4,"cached_prompt_tokens":1200,"misses":{"cold_start":6},"evictions":{"lru_byte_limit":2},"entries":3,"tokens":400,"bytes":8000,"hot_byte_limit":16000}]}}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
	p, ok := r.Resolve("provider-a", "assigned-a")
	if !ok {
		t.Fatal("missing provider")
	}
	v := adminViewFromLive(p)
	if v.ConversationCache == nil || v.ConversationCache.Models[0].Hits != 4 || v.ConversationCache.Models[0].Evictions["lru_byte_limit"] != 2 {
		t.Fatalf("missing operator cache telemetry: %+v", v)
	}
	if len(v.ConversationCacheHistory) != 0 {
		t.Fatal("history should be opt-in")
	}
	b, _ := json.Marshal(v)
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(b, &fields); err != nil || fields["conversation_cache"] == nil {
		t.Fatal("missing admin field")
	}
	var raw map[string]any
	json.Unmarshal(payload, &raw)
	raw["conversation_cache"] = map[string]any{"process_id": "proc-1", "models": []any{map[string]any{"model_id": "a", "lookups": 1, "hits": 2}}}
	malformed, _ := json.Marshal(raw)
	hb, _, _, err := ParseHeartbeat(malformed)
	if err != nil || hb.ConversationCache != nil {
		t.Fatalf("optional invalid telemetry must not reject heartbeat: %v", err)
	}
	delete(raw, "conversation_cache")
	legacy, _ := json.Marshal(raw)
	if hb, _, _, err := ParseHeartbeat(legacy); err != nil || hb.ConversationCache != nil {
		t.Fatalf("legacy heartbeat failed: %v", err)
	}
}
