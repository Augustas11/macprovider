package ws

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func warmHeartbeatServer(t *testing.T) (*Server, *pool.Registry, *lockedBuffer, time.Time) {
	t.Helper()
	registry := pool.NewRegistry(nil)
	logs := &lockedBuffer{}
	at := time.Date(2026, 11, 16, 0, 0, 0, 0, time.UTC)
	registry.Register(&pool.Provider{
		ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 4, MaxConcurrency: 4, MaxContextTokens: 32000, LastHeartbeatAt: at,
		SupportedModels: []string{"model-a", "model-b", "model-c"},
		WarmModels: []pool.WarmModel{
			{ModelID: "model-a", State: pool.WarmModelWarm, Primary: true, Pinned: true, SlotsTotal: 4, SlotsFree: 1, MaxContextTokens: 32000},
			{ModelID: "model-b", State: pool.WarmModelWarm, SlotsTotal: 2, SlotsFree: 2, MaxContextTokens: 8000},
		},
	}, nil)
	server := NewServer(config.Default(), registry, zerolog.New(logs), WithNow(func() time.Time { return at.Add(time.Minute) }))
	return server, registry, logs, at
}

func heartbeatPayload(t *testing.T, payload map[string]any) []byte {
	t.Helper()
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// SPEC-002-R011: a malformed warm_models on a heartbeat drops only the warm
// set update; the rest of the heartbeat applies and the previous member list
// stays, with one structured log line.
func TestHeartbeatMalformedWarmModelsKeepsPreviousSetAndAppliesTheRest(t *testing.T) {
	for name, mutate := range map[string]func(map[string]any){
		"entry bound":         func(p map[string]any) { warmModelsEntry(p, 1)["max_context_tokens"] = 20_000_000 },
		"not supported":       func(p map[string]any) { warmModelsEntry(p, 1)["model_id"] = "model-z" },
		"primary contradicts": func(p map[string]any) { warmModelsEntry(p, 0)["slots_total"] = 3 },
	} {
		server, registry, logs, at := warmHeartbeatServer(t)
		payload := warmModelsHeartbeat()
		delete(payload, "model_hash")
		delete(payload, "model_hash_algorithm")
		delete(warmModelsEntry(payload, 0), "model_hash")
		delete(warmModelsEntry(payload, 0), "model_hash_algorithm")
		mutate(payload)
		server.handleHeartbeat(nil, "p1", "s1", heartbeatPayload(t, payload))

		session, _ := registry.Resolve("p1", "s1")
		if !session.LastHeartbeatAt.After(at) || session.SlotsFree != 3 {
			t.Fatalf("%s: heartbeat not applied: last=%v slots_free=%d", name, session.LastHeartbeatAt, session.SlotsFree)
		}
		if len(session.WarmModels) != 2 || session.WarmModels[1].ModelID != "model-b" {
			t.Fatalf("%s: previous warm set not kept: %+v", name, session.WarmModels)
		}
		if _, ok := registry.ResolveEntry("p1", "s1", "model-c"); ok {
			t.Fatalf("%s: the rejected warm set was applied", name)
		}
		if n := strings.Count(logs.String(), `"event":"heartbeat_warm_models_rejected"`); n != 1 {
			t.Fatalf("%s: rejected log lines = %d, want 1:\n%s", name, n, logs.String())
		}
	}
}

// A kept warm set whose primary is no longer the session's model is dropped.
func TestHeartbeatMalformedWarmModelsWithModelChangeDropsTheSet(t *testing.T) {
	server, registry, _, _ := warmHeartbeatServer(t)
	payload := warmModelsHeartbeat()
	delete(payload, "model_hash")
	delete(payload, "model_hash_algorithm")
	payload["model_id"] = "model-c"
	server.handleHeartbeat(nil, "p1", "s1", heartbeatPayload(t, payload))
	session, _ := registry.Resolve("p1", "s1")
	if session.ModelID != "model-c" || session.WarmModels != nil {
		t.Fatalf("model=%s warm=%+v, want model-c without a warm set", session.ModelID, session.WarmModels)
	}
}

// The primary entry is checked for equality with the top level only: a legal
// top-level value outside an entry bound is accepted on both.
func TestWarmModelsPrimaryEntryFollowsTopLevelRules(t *testing.T) {
	payload := warmModelsHeartbeat()
	payload["max_context_tokens"] = 20_000_000
	warmModelsEntry(payload, 0)["max_context_tokens"] = 20_000_000
	payload["model_params_b"] = 200_000.0
	warmModelsEntry(payload, 0)["model_params_b"] = 200_000.0
	hb, _, field, err := ParseHeartbeat(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("legal top-level value mirrored by the primary rejected: field=%q err=%v", field, err)
	}
	if hb.WarmModels[0].MaxContextTokens != 20_000_000 || len(hb.WarmModels) != 3 {
		t.Fatalf("warm_models = %+v", hb.WarmModels)
	}
	// A further member keeps its bounds.
	warmModelsEntry(payload, 1)["max_context_tokens"] = 20_000_000
	if _, _, field, err := ParseHeartbeat(mustAuthJSON(t, payload)); err == nil || field != warmModelsField {
		t.Fatalf("member over its bound accepted: field=%q err=%v", field, err)
	}
}
