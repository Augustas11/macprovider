package pool

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func cacheTelemetry(process string, lookups uint64) *ConversationCacheTelemetry {
	return &ConversationCacheTelemetry{ProcessID: process, Models: []ConversationCacheModel{{ModelID: "model-a", Lookups: lookups, Hits: lookups / 2, Misses: map[string]uint64{"cold_start": lookups / 2}, Evictions: map[string]uint64{"lru_byte_limit": 1}}}}
}

func TestConversationCacheHeartbeatIsolationAndHistory(t *testing.T) {
	r := NewRegistry(nil)
	now := time.Date(2026, 10, 29, 0, 0, 0, 0, time.UTC)
	registerHeartbeatProvider(t, r, "model-a", "", HashStatusUncatalogued, now)
	for i := 0; i < 3; i++ {
		hb := heartbeatUpdateAt("model-a", now.Add(time.Duration(i)*30*time.Second))
		hb.ConversationCache = cacheTelemetry("process-a", uint64(i+1)*10)
		if _, _, ok := r.ApplyHeartbeat("p1", "current", hb); !ok {
			t.Fatal("heartbeat rejected")
		}
		hb.ConversationCache.Models[0].Misses["cold_start"] = 999 // pool owns a copy
	}
	p, _ := r.Resolve("p1", "current")
	latest, history := p.ConversationCacheObservations()
	if latest.Models[0].Lookups != 30 || latest.Models[0].Misses["cold_start"] != 15 || len(history) != 2 {
		t.Fatalf("unexpected observations: %+v %+v", latest, history)
	}
	latest.Models[0].Misses["cold_start"] = 888
	history[0].Models[0].Misses["cold_start"] = 777
	again, _ := r.Resolve("p1", "current")
	if again.ConversationCacheObservation().Models[0].Misses["cold_start"] != 15 {
		t.Fatal("observation alias")
	}
	wire, _ := json.Marshal(p)
	if strings.Contains(string(wire), "cold_start") || strings.Contains(string(wire), "conversation_cache") {
		t.Fatal("operator telemetry leaked through provider JSON")
	}
	hb := heartbeatUpdateAt("model-a", now.Add(70*time.Second))
	hb.ConversationCache = cacheTelemetry("process-b", 1)
	r.ApplyHeartbeat("p1", "current", hb)
	p, _ = r.Resolve("p1", "current")
	latest, history = p.ConversationCacheObservations()
	if latest.ProcessID != "process-b" || len(history) != 3 {
		t.Fatal("restart was not preserved")
	}
	hb = heartbeatUpdateAt("model-a", now.Add(80*time.Second))
	hb.ConversationCache = cacheTelemetry("process-b", 500)
	if _, _, ok := r.ApplyHeartbeat("p1", "wrong-session", hb); ok {
		t.Fatal("stale session accepted")
	}
	p, _ = r.Resolve("p1", "current")
	if p.ConversationCacheObservation().Models[0].Lookups != 1 {
		t.Fatal("stale session overwrote telemetry")
	}
}

func TestConversationCacheHistoryBoundAndValidation(t *testing.T) {
	p := Provider{}
	now := time.Now()
	for i := 0; i < 1500; i++ {
		p.recordConversationCache(cacheTelemetry("p", uint64(i)), now.Add(time.Duration(i)*time.Minute))
	}
	_, h := p.ConversationCacheObservations()
	if len(h) > conversationCacheHistoryLimit {
		t.Fatalf("unbounded history: %d", len(h))
	}
	bad := cacheTelemetry("p", 1)
	bad.Models[0].Hits = 2
	if bad.Valid() {
		t.Fatal("hits exceed lookups")
	}
	bad = cacheTelemetry("p", 1)
	bad.Models = append(bad.Models, bad.Models[0])
	if bad.Valid() {
		t.Fatal("duplicate model")
	}
	bad = cacheTelemetry("p", 1)
	bad.Models[0].Misses[strings.Repeat("a", 65)] = 1
	if bad.Valid() {
		t.Fatal("unbounded reason")
	}
}

func TestConversationCacheRetainedAfterDisconnectAndReconnect(t *testing.T) {
	r := NewRegistry(nil)
	now := time.Now().UTC()
	registerHeartbeatProvider(t, r, "model-a", "", HashStatusUncatalogued, now)
	hb := heartbeatUpdateAt("model-a", now)
	hb.ConversationCache = cacheTelemetry("process", 10)
	r.ApplyHeartbeat("p1", "current", hb)
	if !r.RemoveIfSession("p1", "current") {
		t.Fatal("remove")
	}
	latest, h := r.RetainedConversationCache("p1", now.Add(time.Second), true)
	if latest == nil || len(h) != 1 || latest.Models[0].Lookups != 10 {
		t.Fatal("disconnect lost history")
	}
	registerHeartbeatProvider(t, r, "model-a", "", HashStatusUncatalogued, now.Add(2*time.Second))
	hb = heartbeatUpdateAt("model-a", now.Add(2*time.Minute))
	hb.ConversationCache = cacheTelemetry("process", 20)
	r.ApplyHeartbeat("p1", "current", hb)
	p, _ := r.Resolve("p1", "current")
	_, h = p.ConversationCacheObservations()
	if len(h) != 2 || h[0].Models[0].Lookups != 10 || h[1].Models[0].Lookups != 20 {
		t.Fatal("reconnect lost baseline")
	}
	if latest, _ := r.RetainedConversationCache("p1", now.Add(25*time.Hour), false); latest != nil {
		t.Fatal("expired retained data")
	}
}

func TestConversationCacheRetainedProviderBoundAndCatalogCardinality(t *testing.T) {
	r := NewRegistry(nil)
	now := time.Now()
	for i := 0; i < retainedCacheProviders+1; i++ {
		p := &Provider{ProviderID: strings.Repeat("x", i+1)}
		p.recordConversationCache(cacheTelemetry("process", 10), now.Add(time.Duration(i)*time.Second))
		r.retainConversationCacheLocked(p, now.Add(time.Duration(i)*time.Second))
	}
	if len(r.conversationCaches) != retainedCacheProviders {
		t.Fatalf("unbounded retained providers: %d", len(r.conversationCaches))
	}
	if _, ok := r.conversationCaches["x"]; ok {
		t.Fatal("oldest retained provider not evicted")
	}
	c := cacheTelemetry("process", 10)
	for i := 0; i < 20; i++ {
		m := c.Models[0]
		m.ModelID = strings.Repeat("m", i+1)
		c.Models = append(c.Models, m)
	}
	if !c.Valid() {
		t.Fatal("legitimate catalog cardinality above16 rejected")
	}
	c.Models = make([]ConversationCacheModel, 257)
	if c.Valid() {
		t.Fatal("unbounded model cardinality")
	}
}

func TestConversationCacheHistoryMemoryBudget(t *testing.T) {
	p := Provider{}
	c := cacheTelemetry("process", 10)
	// A catalog-sized process keeps current counters for every model, while
	// shedding old snapshots when their conservative allocation budget fills.
	for i := 1; i < 256; i++ {
		m := c.Models[0]
		m.ModelID = strings.Repeat("m", i)
		c.Models = append(c.Models, m)
	}
	now := time.Now()
	for i := 0; i < 100; i++ {
		p.recordConversationCache(c, now.Add(time.Duration(i)*time.Minute))
	}
	_, history := p.ConversationCacheObservations()
	bytes := 0
	for _, sample := range history {
		bytes += sample.estimatedBytes
	}
	if len(history) >= 100 || bytes > 8*1024*1024 {
		t.Fatalf("history memory unbounded: samples=%d estimated_bytes=%d", len(history), bytes)
	}
	if len(p.ConversationCacheObservation().Models) != 256 {
		t.Fatal("budget dropped current model counters")
	}
}
