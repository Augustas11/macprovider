package buyer

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// SPEC-036 FR-26: a scorer-only session is never serving capacity on the
// public trusted-pool status, whatever its session state.
func TestTrustPoolStatusLiveProvidersExcludesReferenceScorer(t *testing.T) {
	registry := pool.NewRegistry(nil)
	now := time.Now().UTC()
	for _, p := range []struct {
		id  string
		ref bool
	}{{"peer", false}, {"ref", true}} {
		registry.Register(&pool.Provider{
			ProviderID:            p.id,
			AssignedID:            p.id + "-session",
			Hostname:              p.id + ".local",
			ModelID:               "model-a",
			MaxContextTokens:      20000,
			MaxConcurrency:        1,
			SlotsFree:             1,
			SlotsTotal:            1,
			State:                 pool.StateReady,
			LastHeartbeatAt:       now,
			ConnectedAt:           now,
			ComputeScoreReference: p.ref,
		}, nil)
	}
	s := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	want := map[string]bool{}
	for _, p := range registry.Snapshot() {
		want[p.ProviderID] = p.ServingCapable() && !p.ComputeScoreReference
	}
	got := s.trustPoolStatusLiveProviders().Providers
	if len(got) != 2 {
		t.Fatalf("live providers=%+v want both sessions listed", got)
	}
	for _, p := range got {
		if p.ProviderID == "ref" && p.ServingCapable {
			t.Fatalf("reference scorer counted as serving capacity: %+v", p)
		}
		if p.ServingCapable != want[p.ProviderID] {
			t.Fatalf("%s serving_capable=%v want %v", p.ProviderID, p.ServingCapable, want[p.ProviderID])
		}
	}
}

// SPEC-036 FR-26: a scorer-only session is absent from the relay-blind and
// privacy-class capability counts the gateway reads.
func TestCapabilityCountsExcludeReferenceScorer(t *testing.T) {
	now := time.Unix(1_800_100_110, 0).UTC()
	server, _, _, closeStore, provider := relayBlindTestServerWithProvider(t, now, nil)
	defer closeStore()
	capabilities := func() string {
		t.Helper()
		request := httptest.NewRequest(http.MethodGet, "/v1/relay-blind/capabilities", nil)
		request.RemoteAddr = "127.0.0.1:43210"
		request.Header.Set("Authorization", "Bearer gateway-token")
		response := httptest.NewRecorder()
		server.Handler().ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("capabilities status=%d body=%s", response.Code, response.Body.String())
		}
		return response.Body.String()
	}
	if body := capabilities(); !strings.Contains(body, `"model-a":{"capable_provider_count":1,"incapable_provider_count":0}`) {
		t.Fatalf("baseline capabilities body=%s", body)
	}
	provider.ComputeScoreReference = true
	if body := capabilities(); strings.Contains(body, "model-a") {
		t.Fatalf("reference scorer counted in capabilities: %s", body)
	}
	if _, models := server.privacyCapabilityModels(t.Context()); len(models) != 0 {
		t.Fatalf("reference scorer counted in privacy-class capabilities: %+v", models)
	}
}
