package ws_test

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

func observeDecode(store *routing.PerfStore, providerID, model string, decodeMs float64, at time.Time) {
	for i := 0; i < routing.PerfFreshMinSamples; i++ {
		store.Observe(routing.PerfObservation{ProviderID: providerID, Model: model, Streamed: true, CompletionTokens: 101, TTFTMs: 50, DecodeMs: decodeMs, At: at})
	}
}

// SPEC-002 FR-O2 v1.6.31: operator-only /poolz rows carry the measured decode
// fields read from the buyer router's shared store, routing_eligible applies
// the floor to routed throughput, and the per-version segments average the
// fresh measured decode.
func TestPoolzMeasuredThroughputFields(t *testing.T) {
	store := routing.NewPerfStore()
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{providerws.WithPerfStore(store)})
	defer h.HTTP.Close()
	now := time.Now().UTC()
	for _, id := range []string{"measured", "unmeasured"} {
		if _, ok := h.Registry.Register(&pool.Provider{
			ProviderID: id, AssignedID: "s-" + id, Hostname: id + ".local", ModelID: "Org/Model-A",
			MaxContextTokens: 8192, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1,
			ThroughputTPSEstimate: 5, BinaryVersion: "1.8.300", EndpointURL: "https://" + id + ".example",
			Tier: pool.TierPinned, InferencePath: pool.InferencePathHTTPForwarding, State: pool.StateReady,
			LastHeartbeatAt: now, ConnectedAt: now,
		}, nil); !ok {
			t.Fatal("register provider failed")
		}
	}
	// 100 tokens over 1 s: 100 tok/s, stored under the case-folded model.
	observeDecode(store, "measured", "org/model-a", 1000, now)
	h.Provider.SetMinProviderThroughputTPS(50)

	raw, _ := fetchPoolzRaw(t, h.HTTP.URL)
	var body struct {
		Pool    []map[string]any `json:"pool"`
		Summary struct {
			ByBinaryVersion map[string]map[string]any `json:"by_binary_version"`
		} `json:"summary"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	rows := map[string]map[string]any{}
	for _, row := range body.Pool {
		for _, field := range []string{"measured_decode_tps", "measured_decode_samples", "measured_decode_age_s", "routed_throughput_tps", "routed_throughput_source", "throughput_tps_estimate"} {
			if _, ok := row[field]; !ok {
				t.Fatalf("row %v lacks %s", row["provider_id"], field)
			}
		}
		rows[row["provider_id"].(string)] = row
	}
	m, u := rows["measured"], rows["unmeasured"]
	if m["measured_decode_tps"] != 100.0 || m["measured_decode_samples"] != 3.0 || m["routed_throughput_source"] != "measured" || m["routing_eligible"] != true || m["serving_eligible"] != true {
		t.Fatalf("measured row = %v", m)
	}
	if u["measured_decode_tps"] != nil || u["measured_decode_age_s"] != nil || u["routed_throughput_tps"] != 5.0 || u["routed_throughput_source"] != "reported" || u["routing_eligible"] != false {
		t.Fatalf("unmeasured row = %v", u)
	}
	seg := body.Summary.ByBinaryVersion["1.8.300"]
	if seg["measured_decode_tps_samples"] != 1.0 || seg["measured_decode_tps_avg"] != 100.0 {
		t.Fatalf("segment = %v", seg)
	}

	resp, err := http.Get(h.HTTP.URL + "/poolz")
	if err != nil {
		t.Fatalf("/poolz: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("/poolz without operator key = %d, want 401", resp.StatusCode)
	}
}

// A provider the floor excludes on its measured decode is readmitted on its
// estimate once the decode signal is stale.
func TestPoolzFloorReadmitsOnceMeasuredDecodeIsStale(t *testing.T) {
	store := routing.NewPerfStore()
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{providerws.WithPerfStore(store)})
	defer h.HTTP.Close()
	now := time.Now().UTC()
	if _, ok := h.Registry.Register(&pool.Provider{
		ProviderID: "slow", AssignedID: "s-slow", Hostname: "slow.local", ModelID: "model-a",
		MaxContextTokens: 8192, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1,
		ThroughputTPSEstimate: 80, EndpointURL: "https://slow.example",
		Tier: pool.TierPinned, InferencePath: pool.InferencePathHTTPForwarding, State: pool.StateReady,
		LastHeartbeatAt: now, ConnectedAt: now,
	}, nil); !ok {
		t.Fatal("register provider failed")
	}
	h.Provider.SetMinProviderThroughputTPS(50)
	// 10 tok/s measured: excluded while fresh.
	observeDecode(store, "slow", "model-a", 10000, now)
	if got := fetchPoolz(t, h.HTTP.URL); got.Pool[0].RoutingEligible {
		t.Fatal("fresh measured decode below the floor must exclude")
	}
	stale := routing.NewPerfStore()
	observeDecode(stale, "slow", "model-a", 10000, now.Add(-routing.PerfFreshMaxAge-time.Minute))
	h2 := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{providerws.WithPerfStore(stale)})
	defer h2.HTTP.Close()
	p, _ := h.Registry.Resolve("slow", "s-slow")
	if _, ok := h2.Registry.Register(&p, nil); !ok {
		t.Fatal("register provider failed")
	}
	h2.Provider.SetMinProviderThroughputTPS(50)
	if got := fetchPoolz(t, h2.HTTP.URL); !got.Pool[0].RoutingEligible {
		t.Fatal("a stale record must fall back to the estimate")
	}
}
