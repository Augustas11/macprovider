package ws_test

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

func TestAdminConversationCacheHistoryRequiresOperatorAndOptIn(t *testing.T) {
	store := newConnectionEventStore(t)
	now := time.Now().UTC()
	if err := store.UpsertLastKnown(context.Background(), providerevents.LastKnown{ProviderID: "cache-provider", AssignedID: "assigned", LastSeenAt: now}); err != nil {
		t.Fatal(err)
	}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{providerws.WithConnectionEventStore(store)})
	defer h.HTTP.Close()
	if _, ok := h.Registry.Register(&pool.Provider{ProviderID: "cache-provider", AssignedID: "assigned", ModelID: "model", State: pool.StateReady, AuthState: pool.AuthBearerValidated, LastHeartbeatAt: now}, nil); !ok {
		t.Fatal("register")
	}
	hb := pool.HeartbeatUpdate{Status: pool.StateReady, ModelID: "model", At: now, ConversationCache: &pool.ConversationCacheTelemetry{ProcessID: "process", Models: []pool.ConversationCacheModel{{ModelID: "model", Lookups: 10, Hits: 4}}}}
	h.Registry.ApplyHeartbeat("cache-provider", "assigned", hb)
	for _, tt := range []struct {
		path          string
		auth, history bool
		status        int
	}{
		{"/admin/providers/cache-provider?cache_history=1", false, false, 401},
		{"/admin/providers/cache-provider", true, false, 200},
		{"/admin/providers/cache-provider?cache_history=1", true, true, 200},
		{"/admin/providers?cache_history=1", true, true, 200},
	} {
		req, _ := http.NewRequest(http.MethodGet, h.HTTP.URL+tt.path, nil)
		if tt.auth {
			req.Header.Set("Authorization", "Bearer test-operator-key")
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		var body struct {
			Provider  map[string]any   `json:"provider"`
			Providers []map[string]any `json:"providers"`
		}
		err = json.NewDecoder(resp.Body).Decode(&body)
		resp.Body.Close()
		if resp.StatusCode != tt.status {
			t.Fatalf("%s status=%d", tt.path, resp.StatusCode)
		}
		if tt.status != 200 {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		p := body.Provider
		if p == nil && len(body.Providers) > 0 {
			p = body.Providers[0]
		}
		if p["conversation_cache"] == nil {
			t.Fatalf("%s missing current sample", tt.path)
		}
		if (p["conversation_cache_history"] != nil) != tt.history {
			t.Fatalf("%s history opt-in failed", tt.path)
		}
	}
	if !h.Registry.RemoveIfSession("cache-provider", "assigned") {
		t.Fatal("disconnect")
	}
	for _, path := range []string{"/admin/providers/cache-provider?cache_history=1", "/admin/providers?cache_history=1"} {
		req, _ := http.NewRequest(http.MethodGet, h.HTTP.URL+path, nil)
		req.Header.Set("Authorization", "Bearer test-operator-key")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		var body struct {
			Provider  map[string]any   `json:"provider"`
			Providers []map[string]any `json:"providers"`
		}
		err = json.NewDecoder(resp.Body).Decode(&body)
		resp.Body.Close()
		if err != nil || resp.StatusCode != 200 {
			t.Fatalf("offline %s status=%d err=%v", path, resp.StatusCode, err)
		}
		p := body.Provider
		if p == nil && len(body.Providers) > 0 {
			p = body.Providers[0]
		}
		if p["presence"] != "offline" || p["conversation_cache_history"] == nil {
			t.Fatalf("offline telemetry missing: %+v", p)
		}
	}

}
