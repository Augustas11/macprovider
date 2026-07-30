package ws_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	_ "modernc.org/sqlite"
)

func newConnectionEventStore(t *testing.T) *providerevents.SQLiteStore {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	store, err := providerevents.NewSQLiteStore(db)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	return store
}

func TestAdminProvidersRequireOperatorAuth(t *testing.T) {
	store := newConnectionEventStore(t)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithConnectionEventStore(store),
	})
	defer h.HTTP.Close()

	for _, path := range []string{
		"/admin/providers",
		"/admin/providers/m4-anon",
		"/admin/providers/m4-anon/events",
	} {
		resp, err := http.Get(h.HTTP.URL + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("%s status=%d want 401", path, resp.StatusCode)
		}
	}
}

func TestAdminProvidersOfflineLastKnownAndEvents(t *testing.T) {
	store := newConnectionEventStore(t)
	ctx := context.Background()
	seen := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	if err := store.UpsertLastKnown(ctx, providerevents.LastKnown{
		ProviderID:    "augustass-macbook-air",
		AssignedID:    "asg-1",
		BinaryVersion: "1.8.57",
		ModelID:       "qwen2.5-coder-14b",
		ModelLoaded:   true,
		ModelHash:     strings.Repeat("a", 64),
		State:         "unavailable",
		AuthState:     "bearer_validated",
		LastSeenAt:    seen,
		Diagnostic:    "network_offline: Authorization: Bearer mpk_should_redact",
		DiagnosticAt:  &seen,
	}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if err := store.Record(ctx, providerevents.Event{
		ProviderID:    "augustass-macbook-air",
		SessionID:     "asg-1",
		Kind:          providerevents.KindAuthRejected,
		Outcome:       providerevents.OutcomeFailure,
		FailureReason: providerevents.ReasonInvalidToken,
		AuthStage:     providerevents.AuthStageUpgrade,
		Diagnostic:    "Authorization: Bearer mpk_should_redact",
	}); err != nil {
		t.Fatalf("record: %v", err)
	}

	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithConnectionEventStore(store),
	})
	defer h.HTTP.Close()

	req, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/providers/augustass-macbook-air", nil)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET detail: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	var body struct {
		Provider map[string]any   `json:"provider"`
		Events   []map[string]any `json:"events"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Provider["presence"] != "offline" {
		t.Fatalf("presence=%v want offline", body.Provider["presence"])
	}
	if body.Provider["binary_version"] != "1.8.57" || body.Provider["model_id"] != "qwen2.5-coder-14b" {
		t.Fatalf("last-known incomplete: %#v", body.Provider)
	}
	if body.Provider["model_loaded"] != true || body.Provider["model_hash"] != strings.Repeat("a", 64) {
		t.Fatalf("diagnostic model fields missing: %#v", body.Provider)
	}
	if containsSecret(body.Provider["diagnostic"].(string)) {
		t.Fatalf("provider diagnostic leaked secret: %q", body.Provider["diagnostic"])
	}
	if len(body.Events) == 0 {
		t.Fatal("expected recent events for offline provider")
	}
	diag, _ := body.Events[0]["diagnostic"].(string)
	if containsSecret(diag) {
		t.Fatalf("diagnostic leaked secret: %q", diag)
	}
	if body.Events[0]["failure_reason"] != providerevents.ReasonInvalidToken {
		t.Fatalf("failure_reason=%v", body.Events[0]["failure_reason"])
	}

	listReq, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/providers", nil)
	if err != nil {
		t.Fatalf("list request: %v", err)
	}
	listReq.Header.Set("Authorization", "Bearer test-operator-key")
	listResp, err := http.DefaultClient.Do(listReq)
	if err != nil {
		t.Fatalf("GET list: %v", err)
	}
	defer listResp.Body.Close()
	if listResp.StatusCode != http.StatusOK {
		t.Fatalf("list status=%d", listResp.StatusCode)
	}
}

func TestAdminProvidersConnectedUsesLivePool(t *testing.T) {
	store := newConnectionEventStore(t)
	ctx := context.Background()
	diagnosticAt := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	if err := store.UpsertLastKnown(ctx, providerevents.LastKnown{
		ProviderID:      "m4-anon",
		AssignedID:      "asg-live",
		BinaryVersion:   "stale-version",
		ModelID:         "stale-model",
		ModelLoaded:     false,
		State:           "unavailable",
		AuthState:       "stale-auth",
		LastSeenAt:      diagnosticAt,
		RoutingEligible: false,
		Diagnostic:      "network_offline: redacted",
		DiagnosticAt:    &diagnosticAt,
	}); err != nil {
		t.Fatalf("upsert last-known: %v", err)
	}

	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithConnectionEventStore(store),
	})
	defer h.HTTP.Close()

	now := time.Now().UTC()
	provider := &pool.Provider{
		ProviderID:      "m4-anon",
		AssignedID:      "asg-live",
		BinaryVersion:   "1.8.57",
		ModelID:         "llama",
		State:           pool.StateReady,
		AuthState:       pool.AuthBearerValidated,
		ConnectedAt:     now,
		LastHeartbeatAt: now,
		LastActivityAt:  now,
		SlotsFree:       1,
		SlotsTotal:      1,
	}
	if _, ok := h.Registry.Register(provider, nil); !ok {
		t.Fatal("register live provider failed")
	}

	req, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/providers/m4-anon", nil)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	var body struct {
		Provider map[string]any `json:"provider"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Provider["presence"] != "connected" {
		t.Fatalf("presence=%v", body.Provider["presence"])
	}
	if body.Provider["binary_version"] != "1.8.57" {
		t.Fatalf("binary_version=%v", body.Provider["binary_version"])
	}
	if body.Provider["model_id"] != "llama" || body.Provider["routing_eligible"] != true {
		t.Fatalf("live fields were not authoritative: %#v", body.Provider)
	}
	if body.Provider["diagnostic"] != "network_offline: redacted" || body.Provider["diagnostic_at"] == nil {
		t.Fatalf("live detail dropped diagnostic fields: %#v", body.Provider)
	}

	listReq, err := http.NewRequest(http.MethodGet, h.HTTP.URL+"/admin/providers", nil)
	if err != nil {
		t.Fatalf("list request: %v", err)
	}
	listReq.Header.Set("Authorization", "Bearer test-operator-key")
	listResp, err := http.DefaultClient.Do(listReq)
	if err != nil {
		t.Fatalf("GET list: %v", err)
	}
	defer listResp.Body.Close()
	if listResp.StatusCode != http.StatusOK {
		t.Fatalf("list status=%d", listResp.StatusCode)
	}
	var listBody struct {
		Providers []map[string]any `json:"providers"`
	}
	if err := json.NewDecoder(listResp.Body).Decode(&listBody); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(listBody.Providers) != 1 {
		t.Fatalf("providers=%d want 1", len(listBody.Providers))
	}
	if listBody.Providers[0]["presence"] != "connected" || listBody.Providers[0]["binary_version"] != "1.8.57" {
		t.Fatalf("list did not use live fields: %#v", listBody.Providers[0])
	}
	if listBody.Providers[0]["diagnostic"] != "network_offline: redacted" || listBody.Providers[0]["diagnostic_at"] == nil {
		t.Fatalf("list dropped diagnostic fields: %#v", listBody.Providers[0])
	}
}

func containsSecret(s string) bool {
	return strings.Contains(s, "mpk_") || strings.Contains(s, "Bearer mpk")
}
