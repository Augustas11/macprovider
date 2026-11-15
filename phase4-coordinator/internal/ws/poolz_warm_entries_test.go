package ws_test

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// warmEntryTestHash is a reported model hash; verifyEveryReportedHash
// replaces the server's identity verdict (model-hash verification inactive in
// the default config) with one that verifies every reported hash, so a warm
// set whose members report one is multi-model (SPEC-002-R011).
const warmEntryTestHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func verifyEveryReportedHash(registry *pool.Registry) {
	pool.WithModelIdentityResolver(func(req pool.ModelIdentityRequest) pool.ModelIdentityVerdict {
		if req.ReportedHash == "" {
			return pool.ModelIdentityVerdict{Status: pool.HashStatusUncatalogued}
		}
		return pool.ModelIdentityVerdict{Status: pool.HashStatusVerified}
	})(registry)
}

// SPEC-002-R011 Pool and operator views: /poolz has one row per (provider,
// model) entry with served_model, primary and warm_state; a provider without
// warm_models keeps its single row with none of them. The summary counts
// sessions and takes each session's own (primary) slots, lists every served
// model, and /healthz stays per session.
func TestPoolzWarmEntryRows(t *testing.T) {
	h := newProviderHarness(t)
	defer h.HTTP.Close()
	now := time.Now().UTC()
	base := func(id, model string, slots int) *pool.Provider {
		return &pool.Provider{
			ProviderID: id, AssignedID: "s-" + id, Hostname: id + ".local", ModelID: model,
			MaxContextTokens: 8192, MaxConcurrency: slots, SlotsFree: slots, SlotsTotal: slots,
			ThroughputTPSEstimate: 20, BinaryVersion: "1.8.300", EndpointURL: "https://" + id + ".example",
			Tier: pool.TierPinned, InferencePath: pool.InferencePathHTTPForwarding, State: pool.StateReady,
			LastHeartbeatAt: now, ConnectedAt: now,
		}
	}
	if _, ok := h.Registry.Register(base("legacy", "model-a", 1), nil); !ok {
		t.Fatal("register legacy failed")
	}
	verifyEveryReportedHash(h.Registry)
	warm := base("warm", "model-a", 2)
	warm.ModelHash, warm.HashStatus = warmEntryTestHash, pool.HashStatusVerified
	warm.WarmModels = []pool.WarmModel{
		{ModelID: "model-a", State: pool.WarmModelWarm, Primary: true, Pinned: true, SlotsTotal: 2, SlotsFree: 2, MaxContextTokens: 8192, ThroughputTPSEstimate: 20},
		{ModelID: "model-b", State: pool.WarmModelWarm, SlotsTotal: 3, SlotsFree: 3, MaxContextTokens: 4096, ThroughputTPSEstimate: 12, ModelHash: warmEntryTestHash},
		{ModelID: "model-c", State: pool.WarmModelLoading, SlotsTotal: 1, MaxContextTokens: 4096},
	}
	if _, ok := h.Registry.Register(warm, nil); !ok {
		t.Fatal("register warm failed")
	}

	raw, _ := fetchPoolzRaw(t, h.HTTP.URL)
	var body struct {
		Pool    []map[string]any `json:"pool"`
		Summary struct {
			TotalProviders int      `json:"total_providers"`
			Ready          int      `json:"ready"`
			TotalSlots     int      `json:"total_slots"`
			FreeSlots      int      `json:"free_slots"`
			Models         []string `json:"models"`
		} `json:"summary"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Pool) != 4 {
		t.Fatalf("rows=%d want 4 (legacy + three entries)", len(body.Pool))
	}
	rows := map[string]map[string]any{}
	for _, row := range body.Pool {
		key := row["provider_id"].(string)
		if served, ok := row["served_model"].(string); ok {
			key += "#" + served
		}
		rows[key] = row
	}
	legacy := rows["legacy"]
	for _, field := range []string{"served_model", "primary", "warm_state"} {
		if _, ok := legacy[field]; ok {
			t.Fatalf("legacy row carries %s: %v", field, legacy)
		}
	}
	if legacy["model_id"] != "model-a" || legacy["slots_total"] != 1.0 {
		t.Fatalf("legacy row = %v", legacy)
	}
	for _, tc := range []struct {
		key, state, warmState string
		primary               bool
		total, free           float64
		routing               bool
	}{
		{"warm#model-a", "ready", "warm", true, 2, 2, true},
		{"warm#model-b", "ready", "warm", false, 3, 3, true},
		{"warm#model-c", "unavailable", "loading", false, 1, 0, false},
	} {
		row := rows[tc.key]
		if row == nil {
			t.Fatalf("no row %s", tc.key)
		}
		if row["primary"] != tc.primary || row["warm_state"] != tc.warmState || row["state"] != tc.state ||
			row["slots_total"] != tc.total || row["slots_free"] != tc.free || row["routing_eligible"] != tc.routing {
			t.Fatalf("%s row = %v", tc.key, row)
		}
	}
	if s := body.Summary; s.TotalProviders != 2 || s.Ready != 2 || s.TotalSlots != 3 || s.FreeSlots != 3 {
		t.Fatalf("summary = %+v, want 2 sessions with primary slots only (1+2)", s)
	}
	models := map[string]bool{}
	for _, m := range body.Summary.Models {
		models[m] = true
	}
	if len(body.Summary.Models) != 3 || !models["model-a"] || !models["model-b"] || !models["model-c"] {
		t.Fatalf("summary models = %v", body.Summary.Models)
	}

	// The new fields sit behind the same operator gate as their neighbours.
	resp, err := http.Get(h.HTTP.URL + "/poolz")
	if err != nil {
		t.Fatalf("/poolz: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated /poolz status=%d", resp.StatusCode)
	}
	hz, err := http.Get(h.HTTP.URL + "/healthz")
	if err != nil {
		t.Fatalf("/healthz: %v", err)
	}
	defer hz.Body.Close()
	var health struct {
		PoolSize  int `json:"pool_size"`
		PoolReady int `json:"pool_ready"`
	}
	if err := json.NewDecoder(hz.Body).Decode(&health); err != nil {
		t.Fatalf("decode healthz: %v", err)
	}
	if health.PoolSize != 2 || health.PoolReady != 2 {
		t.Fatalf("healthz = %+v, want per-session counts", health)
	}
}
