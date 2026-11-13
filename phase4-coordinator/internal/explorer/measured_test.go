package explorer

import (
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

// SPEC-002 FR-O2 v1.6.31: operator-token explorer provider rows carry the
// measured decode fields next to the estimate, read from the shared store.
func TestProviderRowsCarryMeasuredThroughput(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	store := routing.NewPerfStore()
	h.WithPerfStore(store)
	left, right := net.Pipe()
	t.Cleanup(func() { _ = left.Close(); _ = right.Close() })
	registry := pool.NewRegistry(nil)
	for _, id := range []string{"provider_measured", "provider_reported"} {
		registry.Register(&pool.Provider{ProviderID: id, AssignedID: "a_" + id, ModelID: "Llama", State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, ThroughputTPSEstimate: 7}, left)
	}
	h.pool = registry
	now := time.Now()
	for i := 0; i < routing.PerfFreshMinSamples; i++ {
		store.Observe(routing.PerfObservation{ProviderID: "provider_measured", Model: "llama", Streamed: true, CompletionTokens: 101, TTFTMs: 50, DecodeMs: 1000, At: now})
	}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/providers", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	for _, want := range []string{`"measured_decode_tps":100`, `"measured_decode_samples":3`, `"routed_throughput_source":"measured"`, `"routed_throughput_source":"reported"`, `"measured_decode_tps":null`, `"measured_decode_age_s":null`, `"throughput_tps_estimate":7`} {
		if !strings.Contains(body, want) {
			t.Fatalf("providers missing %q: %s", want, body)
		}
	}
	detail := requestExplorer(t, h, http.MethodGet, "/admin/explorer/providers/provider_measured", "operator-key")
	if detail.Code != http.StatusOK || !strings.Contains(detail.Body.String(), `"routed_throughput_source":"measured"`) {
		t.Fatalf("detail status=%d body=%s", detail.Code, detail.Body.String())
	}
	if anon := requestExplorer(t, h, http.MethodGet, "/admin/explorer/providers", ""); anon.Code != http.StatusUnauthorized {
		t.Fatalf("providers without operator token = %d, want 401", anon.Code)
	}
}
