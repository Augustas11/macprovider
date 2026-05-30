package router

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
	_ "modernc.org/sqlite"
)

type fakeOAuth struct {
	identity auth.OAuthIdentity
	err      error
}

func (f fakeOAuth) Exchange(context.Context, string, string) (auth.OAuthIdentity, error) {
	return f.identity, f.err
}

func TestOAuthCallbackAllowlist(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{identity: auth.OAuthIdentity{ProviderUserID: "42", Scopes: []string{"read:user"}}})

	req := httptest.NewRequest(http.MethodGet, "/auth/github/start?redirect_uri="+url.QueryEscape("https://evil.example/callback"), nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("evil start status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "oauth_callback_not_allowed")

	state, cookie := startOAuth(t, h, "https://api.streamvc.live/auth/github/callback")
	req = httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state="+url.QueryEscape(state), nil)
	req.AddCookie(cookie)
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusFound || resp.Header().Get("Location") != "/account" {
		t.Fatalf("matching callback status=%d location=%q body=%s", resp.Code, resp.Header().Get("Location"), resp.Body.String())
	}
	if !strings.HasPrefix(findCookie(resp, "mp_new_api_key"), "mp_") {
		t.Fatalf("new key cookie missing")
	}
}

func TestOAuthStateCSRF(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{identity: auth.OAuthIdentity{ProviderUserID: "43", Scopes: []string{"read:user"}}})
	_, cookie := startOAuth(t, h, "https://api.streamvc.live/auth/github/callback")

	req := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state=forged", nil)
	req.AddCookie(cookie)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("forged state status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "oauth_state_invalid")

	state, cookie := startOAuth(t, h, "https://api.streamvc.live/auth/github/callback")
	req = httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state="+url.QueryEscape(state), nil)
	req.AddCookie(cookie)
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusFound {
		t.Fatalf("valid state status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestOAuthScopeMinimization(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{identity: auth.OAuthIdentity{ProviderUserID: "44", Scopes: []string{"read:user"}}})
	state, cookie := startOAuth(t, h, "https://api.streamvc.live/auth/github/callback")
	req := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state="+url.QueryEscape(state), nil)
	req.AddCookie(cookie)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusFound {
		t.Fatalf("allowed scope status=%d body=%s", resp.Code, resp.Body.String())
	}

	h, _, dbPath, _ := newTestHarness(t, fakeOAuth{identity: auth.OAuthIdentity{ProviderUserID: "45", Scopes: []string{"repo"}}})
	state, cookie = startOAuth(t, h, "https://api.streamvc.live/auth/github/callback")
	req = httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=bad&state="+url.QueryEscape(state), nil)
	req.AddCookie(cookie)
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusForbidden {
		t.Fatalf("elevated scope status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "oauth_scope_forbidden")
	if countAuditEvents(t, dbPath, "oauth_scope_rejected") != 1 {
		t.Fatalf("oauth_scope_rejected audit count mismatch")
	}

	h, _, _, _ = newTestHarness(t, fakeOAuth{err: auth.ErrForbiddenScope})
	state, cookie = startOAuth(t, h, "https://api.streamvc.live/auth/github/callback")
	req = httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=bad&state="+url.QueryEscape(state), nil)
	req.AddCookie(cookie)
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusForbidden {
		t.Fatalf("provider forbidden scope status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestKeyRevocationLatency(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_revoke")
	assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusOK)

	validation, err := auth.NewKeyManager(cfg.Auth.KeyPrefix, cfg.Auth.KeyHash, cfg.Auth.KeyHashSecret).Validate(context.Background(), store, fullKey)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if err := store.RevokeAPIKey(context.Background(), validation.KeyID, "test", "req_revoke"); err != nil {
		t.Fatalf("RevokeAPIKey: %v", err)
	}
	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusForbidden)
	assertErrorCode(t, resp.Body.String(), "api_key_revoked")
}

func TestModelsResponseIncludesTier1Disclosure(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"object":"list",
			"data":[],
			"provider_count":2,
			"total_slots":4,
			"tier1_disclosure":{"version":"evil","plaintext_to_provider":false,"model_identity":"claimed","hardware_attestation":"claimed","tier2_milestone":"now"}
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Public.BaseURL = "https://operator.example"
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_models_disclosure")
	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusOK)
	var body struct {
		Tier1Disclosure tier1Disclosure `json:"tier1_disclosure"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("models json: %v", err)
	}
	want := (&Server{}).makeTier1Disclosure()
	if body.Tier1Disclosure != want {
		t.Fatalf("tier1_disclosure=%+v want %+v", body.Tier1Disclosure, want)
	}
}

func TestKeyRotationPreservesHistory(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{})
	fullKey := createAccountAndKey(t, store, cfg, "acct_rotate")
	if err := store.InsertUsageEvent(context.Background(), storage.UsageEvent{
		RequestID: "req_usage", AccountID: "acct_rotate", WindowDate: "2026-05-29",
		PromptTokens: 10, CompletionTokens: 5, TokenSource: "provider_reported", Outcome: "ok", CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatalf("InsertUsageEvent: %v", err)
	}
	if err := store.InsertFeedbackEvent(context.Background(), storage.FeedbackEvent{
		EventID: "fb_rotate", RequestID: "req_usage", AccountID: "acct_rotate", Scope: "account", Rating: 4, CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatalf("InsertFeedbackEvent: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/auth/api-keys", nil)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusCreated {
		t.Fatalf("rotate status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body struct {
		APIKey string `json:"api_key"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("rotate json: %v", err)
	}
	if !strings.HasPrefix(body.APIKey, "mp_") {
		t.Fatalf("new key = %q", body.APIKey)
	}

	oldResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusForbidden)
	assertErrorCode(t, oldResp.Body.String(), "api_key_revoked")
	newResp := assertStatus(t, h, http.MethodGet, "/v1/usage", body.APIKey, "", "1.2.3.4", http.StatusOK)
	var usage map[string]any
	if err := json.Unmarshal(newResp.Body.Bytes(), &usage); err != nil {
		t.Fatalf("usage json: %v", err)
	}
	for _, field := range []string{"account_id", "quota", "keys", "models", "rating"} {
		if _, ok := usage[field]; !ok {
			t.Fatalf("usage missing field %s: %v", field, usage)
		}
	}
	quota := usage["quota"].(map[string]any)
	if quota["daily_tokens_used"].(float64) != 15 {
		t.Fatalf("daily_tokens_used=%v, want 15", quota["daily_tokens_used"])
	}
}

func TestDemoTokenValidation(t *testing.T) {
	current := fixedNow()
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithNow(func() time.Time { return current }), WithHTTPClient(modelsOKClient()))

	req := httptest.NewRequest(http.MethodPost, "/auth/demo-session", nil)
	req.Header.Set("X-Real-IP", "1.2.3.4")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusCreated {
		t.Fatalf("demo session status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body struct {
		DemoToken string `json:"demo_token"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("demo json: %v", err)
	}
	if body.DemoToken == "" {
		t.Fatal("demo_token missing")
	}

	assertStatus(t, h, http.MethodGet, "/v1/models", "", body.DemoToken, "1.2.3.4", http.StatusOK)
	forged := body.DemoToken[:len(body.DemoToken)-1] + "x"
	resp = assertStatus(t, h, http.MethodGet, "/v1/models", "", forged, "1.2.3.4", http.StatusUnauthorized)
	assertErrorCode(t, resp.Body.String(), "invalid_demo_token")
	resp = assertStatus(t, h, http.MethodGet, "/v1/models", "", body.DemoToken, "5.6.7.8", http.StatusUnauthorized)
	assertErrorCode(t, resp.Body.String(), "invalid_demo_token")
	current = current.Add(25 * time.Hour)
	resp = assertStatus(t, h, http.MethodGet, "/v1/models", "", body.DemoToken, "1.2.3.4", http.StatusUnauthorized)
	assertErrorCode(t, resp.Body.String(), "invalid_demo_token")
}

func TestKeyHashStorage(t *testing.T) {
	_, store, dbPath, cfg := newTestHarness(t, fakeOAuth{})
	fullKey := createAccountAndKey(t, store, cfg, "acct_hash")

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql open: %v", err)
	}
	defer db.Close()
	var rawCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM api_keys WHERE CAST(key_hash AS TEXT) LIKE '%' || ? || '%' OR key_hash_prefix = ?`, fullKey, fullKey).Scan(&rawCount); err != nil {
		t.Fatalf("query raw key: %v", err)
	}
	if rawCount != 0 {
		t.Fatalf("full key was stored")
	}
}

func TestKillSwitchPersistsAcrossRestart(t *testing.T) {
	configPath := writeTestConfig(t, false)
	cfg, err := config.Load(configPath)
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()
	h := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithConfigPath(configPath), WithHTTPClient(noopClient())).Handler()

	req := httptest.NewRequest(http.MethodPost, "/admin/kill-switch", strings.NewReader(`{"all_public_api":true}`))
	req.Header.Set("Authorization", "Bearer operator-key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("kill switch status=%d body=%s", resp.Code, resp.Body.String())
	}
	reloaded, err := config.Load(configPath)
	if err != nil {
		t.Fatalf("reload config: %v", err)
	}
	if !reloaded.KillSwitch.AllPublicAPI {
		t.Fatalf("kill switch did not persist")
	}
	if countAuditEvents(t, cfg.Storage.DBPath, "kill_switch_toggled") != 1 {
		t.Fatalf("kill_switch_toggled audit missing")
	}

	reloaded.Storage.DBPath = cfg.Storage.DBPath
	restarted := New(reloaded, store, fakeOAuth{}, WithNow(fixedNow), WithConfigPath(configPath), WithHTTPClient(noopClient())).Handler()
	fullKey := createAccountAndKey(t, store, reloaded, "acct_paused")
	chatResp := postChat(t, restarted, fullKey, `{"model":"llama","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if chatResp.Code != http.StatusServiceUnavailable {
		t.Fatalf("paused chat status=%d body=%s", chatResp.Code, chatResp.Body.String())
	}
	assertErrorCode(t, chatResp.Body.String(), "public_api_paused")
}

func TestStatusRedactionAndPoolzCacheFlush(t *testing.T) {
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Header.Get("Authorization") != "Bearer operator-key" {
			return responseWithBody(http.StatusUnauthorized, nil, `{}`), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"pool":[
				{"provider_id":"m4-secret","assigned_id":"route-secret","hostname":"m4.local","endpoint_url":"https://m4.streamvc.live","model_id":"llama","state":"ready","slots_free":1,"slots_total":2,"max_context_tokens":8192,"memory_bytes":123,"cpu_count":10,"operator_identity":"operator"},
				{"provider_id":"m1-secret","assigned_id":"route-2","hostname":"m1.local","endpoint_url":"https://m1.streamvc.live","model_id":"llama","state":"unavailable","slots_free":0,"slots_total":1,"max_context_tokens":4096}
			],
			"summary":{"total_providers":2,"ready":1,"total_slots":3,"free_slots":1}
		}`), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Capacity.ReadyProviderDegradedThreshold = 2
	}, WithHTTPClient(client))
	resp := assertStatus(t, h, http.MethodGet, "/v1/status", "", "", "", http.StatusOK)
	body := resp.Body.String()
	for _, forbidden := range []string{"m4-secret", "route-secret", "m4.local", "streamvc.live", "memory_bytes", "operator"} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("status leaked %q in %s", forbidden, body)
		}
	}
	var parsed statusResponse
	if err := json.Unmarshal(resp.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("status json: %v", err)
	}
	if parsed.Status != "degraded" || !parsed.Degraded || parsed.Pool.Ready != 1 || len(parsed.Models) != 1 {
		t.Fatalf("status parsed = %+v", parsed)
	}
	_ = assertStatus(t, h, http.MethodGet, "/v1/status", "", "", "", http.StatusOK)
	if calls != 1 {
		t.Fatalf("poolz calls=%d want cache hit with 1", calls)
	}
}

func TestAggregateStatusIdleWhenCoordinatorReachableWithNoReadyProviders(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"llama","state":"unavailable","slots_free":0,"slots_total":1,"max_context_tokens":4096}
		],
		"summary":{"total_providers":1,"ready":0,"total_slots":1,"free_slots":0}
	}`), 1, fixedNow())

	if out.Status != "idle" || out.Degraded {
		t.Fatalf("status=%q degraded=%t, want idle and not degraded", out.Status, out.Degraded)
	}
	if len(out.Models) != 1 {
		t.Fatalf("models=%+v, want one model", out.Models)
	}
	model := out.Models[0]
	if model.Available || model.Availability != "no_awake_provider" || model.ReadyProviderCount != 0 {
		t.Fatalf("model availability = %+v, want no awake provider", model)
	}
}

func TestAggregateStatusPartialCapacityRemainsDegraded(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"llama","state":"ready","slots_free":1,"slots_total":2,"max_context_tokens":8192},
			{"model_id":"llama","state":"unavailable","slots_free":0,"slots_total":1,"max_context_tokens":4096}
		],
		"summary":{"total_providers":2,"ready":1,"total_slots":3,"free_slots":1}
	}`), 2, fixedNow())

	if out.Status != "degraded" || !out.Degraded {
		t.Fatalf("status=%q degraded=%t, want degraded", out.Status, out.Degraded)
	}
	if len(out.Models) != 1 || !out.Models[0].Available || out.Models[0].Availability != "available" {
		t.Fatalf("models=%+v, want available model", out.Models)
	}
}

func TestAggregateStatusNoFreeSlotsIsModelUnavailableNotSystemIdle(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"llama","state":"ready","slots_free":0,"slots_total":1,"max_context_tokens":4096}
		],
		"summary":{"total_providers":1,"ready":1,"total_slots":1,"free_slots":0}
	}`), 1, fixedNow())

	if out.Status != "up" || out.Degraded {
		t.Fatalf("status=%q degraded=%t, want up and not degraded", out.Status, out.Degraded)
	}
	if len(out.Models) != 1 || out.Models[0].Available || out.Models[0].Availability != "no_free_slots" {
		t.Fatalf("models=%+v, want no_free_slots", out.Models)
	}
}

func TestStatusCoordinatorUnreachableRemainsDown(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return nil, errors.New("coordinator unavailable")
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	resp := assertStatus(t, h, http.MethodGet, "/v1/status", "", "", "", http.StatusOK)

	var parsed statusResponse
	if err := json.Unmarshal(resp.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("status json: %v", err)
	}
	if parsed.Status != "down" || parsed.Degraded || parsed.Coordinator.Status != "down" {
		t.Fatalf("status parsed = %+v, want coordinator down", parsed)
	}
}

func TestDegradedCalculationMatchesFRB1(t *testing.T) {
	cases := []struct {
		name  string
		stats poolzModelStats
		want  bool
	}{
		{name: "no providers", stats: poolzModelStats{}, want: true},
		{name: "all unavailable", stats: poolzModelStats{TotalProviders: 2, UnavailableOrDraining: 2, Ready: 0, SlotsFreeTotal: 2}, want: true},
		{name: "less than half ready", stats: poolzModelStats{TotalProviders: 3, UnavailableOrDraining: 1, Ready: 1, SlotsFreeTotal: 2}, want: true},
		{name: "no free slots", stats: poolzModelStats{TotalProviders: 2, Ready: 2, SlotsFreeTotal: 0}, want: true},
		{name: "healthy", stats: poolzModelStats{TotalProviders: 2, Ready: 1, SlotsFreeTotal: 1}, want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := computeDegraded(tc.stats); got != tc.want {
				t.Fatalf("computeDegraded(%+v)=%t want %t", tc.stats, got, tc.want)
			}
		})
	}
}

func TestFeedbackSummaryAggregation(t *testing.T) {
	h, store, dbPath, cfg := newTestHarness(t, fakeOAuth{})
	fullKey := createAccountAndKey(t, store, cfg, "acct_feedback")
	submitFeedback(t, h, fullKey, "", `{"rating":1,"comment":"old","request_id":"req_dup","scope":"request"}`)
	submitFeedback(t, h, fullKey, "", `{"rating":4,"comment":"new","request_id":"req_dup","scope":"request"}`)
	submitFeedback(t, h, fullKey, "", `{"rating":2,"comment":"session","scope":"session"}`)
	submitFeedback(t, h, fullKey, "", `{"rating":3,"comment":"account","scope":"account"}`)
	demo := issueDemoToken(t, h, "1.2.3.4")
	submitFeedback(t, h, "", demo, `{"rating":4,"comment":"play","scope":"playground"}`)

	req := httptest.NewRequest(http.MethodGet, "/admin/feedback-summary?window=7d", nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized summary status=%d", resp.Code)
	}
	assertErrorCode(t, resp.Body.String(), "invalid_operator_token")

	req = httptest.NewRequest(http.MethodGet, "/admin/feedback-summary?window=7d", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("summary status=%d body=%s", resp.Code, resp.Body.String())
	}
	var summary map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &summary); err != nil {
		t.Fatalf("summary json: %v", err)
	}
	if summary["rating_count"].(float64) != 4 {
		t.Fatalf("rating_count=%v want 4", summary["rating_count"])
	}
	dist := summary["distribution"].(map[string]any)
	if dist["1"].(float64) != 0 || dist["2"].(float64) != 1 || dist["3"].(float64) != 1 || dist["4"].(float64) != 2 {
		t.Fatalf("distribution=%v", dist)
	}
	if len(summary["comment_samples"].([]any)) > 20 {
		t.Fatalf("too many comments")
	}
	if countRows(t, dbPath, "feedback_events") != 5 {
		t.Fatalf("feedback append-only event count mismatch")
	}
}

func TestCapacityTierDeescalation(t *testing.T) {
	current := fixedNow()
	h, _, dbPath, _ := newTestHarness(t, fakeOAuth{}, WithNow(func() time.Time { return current }))
	postAdminJSON(t, h, "/admin/capacity-signal", `{"signal":"cpu","value":80,"threshold":70,"firing":true}`)
	if countAuditEvents(t, dbPath, "capacity_tier_escalated") != 1 {
		t.Fatalf("capacity_tier_escalated audit missing")
	}
	current = current.Add(2 * time.Hour)
	postAdminJSON(t, h, "/admin/capacity-signal", `{"signal":"cpu","value":50,"threshold":70,"firing":false}`)
	req := httptest.NewRequest(http.MethodPost, "/admin/capacity-tier/evaluate", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("evaluate status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("evaluate json: %v", err)
	}
	if body["previous_tier"].(float64) != 1 || body["new_tier"].(float64) != 0 || body["signals_below_threshold"] != true {
		t.Fatalf("evaluate body=%v", body)
	}
	if countAuditEvents(t, dbPath, "capacity_tier_deescalated") != 1 {
		t.Fatalf("capacity_tier_deescalated audit missing")
	}
}

func TestProviderPinningHeadersStripped(t *testing.T) {
	var captured http.Header
	failing := false
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		captured = r.Header.Clone()
		if failing {
			return responseWithBody(http.StatusInternalServerError, http.Header{
				"X-MacProvider-Provider": []string{"m4-secret"},
			}, `{"provider_id":"m4-secret","route_id":"route-secret"}`), nil
		}
		return responseWithBody(http.StatusOK, http.Header{
			"Content-Type":           []string{"application/json"},
			"X-MacProvider-Provider": []string{"m4-secret"},
			"X-MacProvider-Route":    []string{"route-secret"},
		}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_strip_success")

	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-MacProvider-Provider", "pinned")
	req.Header.Set("X-MacProvider-Session", "session")
	req.Header.Set("X-MacProvider-Pref", "fast")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("success status=%d body=%s", resp.Code, resp.Body.String())
	}
	for _, header := range []string{"X-MacProvider-Provider", "X-MacProvider-Session", "X-MacProvider-Pref"} {
		if got := captured.Get(header); got != "" {
			t.Fatalf("forwarded %s=%q", header, got)
		}
		if got := resp.Header().Get(header); got != "" {
			t.Fatalf("buyer response exposed %s=%q", header, got)
		}
	}
	if got := resp.Header().Get("X-MacProvider-Route"); got != "" {
		t.Fatalf("buyer response exposed route=%q", got)
	}
	if got := captured.Get("X-Request-ID"); got == "" {
		t.Fatalf("forwarded X-Request-ID missing")
	}

	failing = true
	fullKey = createAccountAndKey(t, store, cfg, "acct_strip_failure")
	req = httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-MacProvider-Provider", "pinned")
	req.Header.Set("X-MacProvider-Session", "session")
	req.Header.Set("X-MacProvider-Pref", "fast")
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("failure status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "upstream_provider_error")
	if strings.Contains(resp.Body.String(), "provider_id") || strings.Contains(resp.Body.String(), "route_id") {
		t.Fatalf("provider details leaked in body: %s", resp.Body.String())
	}
	for _, header := range []string{"X-MacProvider-Provider", "X-MacProvider-Session", "X-MacProvider-Pref"} {
		if got := captured.Get(header); got != "" {
			t.Fatalf("forwarded failure %s=%q", header, got)
		}
		if got := resp.Header().Get(header); got != "" {
			t.Fatalf("failure response exposed %s=%q", header, got)
		}
	}
}

func TestStickyConversationDerivesInternalHeaderAndStripsInjection(t *testing.T) {
	var captured http.Header
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		captured = r.Header.Clone()
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Routing.StickyEnabled = true
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_sticky")

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-MacProvider-Conversation", "thread-1")
	req.Header.Set("X-MacProvider-Internal-Conv", "conv:attacker")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	got := captured.Get("X-MacProvider-Internal-Conv")
	if !strings.HasPrefix(got, "conv:") || got == "conv:attacker" {
		t.Fatalf("internal conversation key = %q", got)
	}
	if captured.Get("X-MacProvider-Internal-Source") != "gateway" {
		t.Fatalf("internal source = %q, want gateway", captured.Get("X-MacProvider-Internal-Source"))
	}
	if countAuditEvents(t, dbPath, "internal_header_injection_stripped") != 1 {
		t.Fatalf("internal header injection audit missing")
	}
}

func TestStickyConversationIgnoredWhenDisabled(t *testing.T) {
	var captured http.Header
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		captured = r.Header.Clone()
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Routing.StickyEnabled = false
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_sticky_disabled")

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("X-MacProvider-Conversation", "bad tag with spaces")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := captured.Get("X-MacProvider-Internal-Conv"); got != "" {
		t.Fatalf("internal conversation forwarded while disabled: %q", got)
	}
}

func TestQuotaSettlement504ZeroCompletion(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusGatewayTimeout, http.Header{
			"X-MacProvider-Completion-Tokens": []string{"0"},
		}, ""), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_timeout")
	body := `{"model":"llama","max_tokens":80,"messages":[{"role":"user","content":"timeout"}]}`
	resp := postChat(t, h, fullKey, body, nil)
	if resp.Code != http.StatusGatewayTimeout {
		t.Fatalf("timeout status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "provider_timeout")

	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantPrompt := float64(estimatePromptTokens([]byte(body)))
	if quota["daily_tokens_used"].(float64) != wantPrompt {
		t.Fatalf("daily_tokens_used=%v want prompt estimate %v", quota["daily_tokens_used"], wantPrompt)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestChatCompletionsCoordinatorTimeoutAppliesToStreamAndNonStream(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.CoordinatorRequestSeconds = 1
	}, WithHTTPClient(client))

	for _, tc := range []struct {
		name string
		body string
	}{
		{name: "non_stream", body: `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}],"stream":false}`},
		{name: "stream", body: `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}],"stream":true}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fullKey := createAccountAndKey(t, store, cfg, "acct_timeout_"+tc.name)
			start := time.Now()
			resp := postChat(t, h, fullKey, tc.body, nil)
			elapsed := time.Since(start)
			if resp.Code != http.StatusServiceUnavailable {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			if elapsed > 2500*time.Millisecond {
				t.Fatalf("elapsed=%s, want <=2.5s", elapsed)
			}
			assertErrorCode(t, resp.Body.String(), "coordinator_unavailable")
		})
	}
}

func TestChatCompletionsCoordinatorRequestCancelsWithBuyerContext(t *testing.T) {
	entered := make(chan struct{})
	cancelled := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		close(entered)
		<-r.Context().Done()
		close(cancelled)
		return nil, r.Context().Err()
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.CoordinatorRequestSeconds = 60
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_cancel")
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		h.ServeHTTP(resp, req)
		close(done)
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("coordinator transport was not entered")
	}
	cancel()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("coordinator request did not observe buyer cancellation")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("handler did not return after buyer cancellation")
	}
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "coordinator_unavailable")
}

func TestStreamingQuotaReservationAndSettlementUsesDisconnectEstimation(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":200,"messages":[{"role":"user","content":"count slowly"}]}`
	accountID := "acct_stream_estimated"
	var store *sqlite.Store
	var reservedAtFirstByte int64
	firstByte := make(chan struct{})
	cancelSeen := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/v1/chat/completions/cancel" {
			t.Fatalf("gateway called non-spec cancel endpoint")
		}
		used, reserved, err := store.DailyUsage(context.Background(), accountID, "2026-05-29")
		if err != nil {
			t.Errorf("DailyUsage from upstream: %v", err)
		}
		if used != 0 {
			t.Errorf("used before first byte=%d want 0", used)
		}
		reservedAtFirstByte = reserved
		pr, pw := io.Pipe()
		go func() {
			_, _ = fmt.Fprintf(pw, "data: %s\n\n", strings.Repeat("x", 120))
			close(firstByte)
			<-r.Context().Done()
			close(cancelSeen)
			_ = pw.Close()
		}()
		header := http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}
		return &http.Response{StatusCode: http.StatusOK, Header: header, Body: pr}, nil
	})}
	h, createdStore, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	store = createdStore
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		h.ServeHTTP(resp, req)
		close(done)
	}()
	select {
	case <-firstByte:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for first upstream byte")
	}
	time.Sleep(25 * time.Millisecond)
	if reservedAtFirstByte != 200 {
		t.Fatalf("reserved at first byte=%d want 200", reservedAtFirstByte)
	}
	cancel()
	select {
	case <-cancelSeen:
	case <-time.After(2 * time.Second):
		t.Fatal("upstream did not observe cancellation")
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("gateway did not finish after cancellation")
	}
	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := resp.Header().Get("Content-Type"); got != "text/event-stream; charset=utf-8" {
		t.Fatalf("stream content-type=%q", got)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantUsed := float64(estimatePromptTokens([]byte(body)) + 30)
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestNotFoundReturnsOpenAIEnvelope(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(noopClient()))
	resp := assertStatus(t, h, http.MethodGet, "/v1/does-not-exist", "", "", "", http.StatusNotFound)
	assertErrorCode(t, resp.Body.String(), "not_found")
}

func TestXRequestIDValidationRejectsNonV4(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(noopClient()))
	for _, id := range []string{
		"6ba7b810-9dad-11d1-80b4-00c04fd430c8",
		"6ba7b810-9dad-31d1-80b4-00c04fd430c8",
		"6ba7b810-9dad-51d1-80b4-00c04fd430c8",
		"not-a-uuid",
	} {
		req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
		req.Header.Set("X-Request-ID", id)
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		got := resp.Header().Get("X-Request-ID")
		if got == id {
			t.Fatalf("accepted non-v4 request id %q", id)
		}
		if !isUUIDLike(got) {
			t.Fatalf("generated request id %q is not v4", got)
		}
	}
	valid := "6ba7b810-9dad-41d1-80b4-00c04fd430c8"
	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	req.Header.Set("X-Request-ID", valid)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if got := resp.Header().Get("X-Request-ID"); got != valid {
		t.Fatalf("valid v4 request id got %q want %q", got, valid)
	}
}

func TestPanicRecoveryLogsPanicAndReturnsEnvelope(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(old) })
	s := &Server{}
	h := s.middleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	}))
	req := httptest.NewRequest(http.MethodGet, "/panic", nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusInternalServerError {
		t.Fatalf("panic status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "internal_error")
	logs := buf.String()
	if !strings.Contains(logs, "boom") || !strings.Contains(logs, "goroutine") {
		t.Fatalf("panic log missing value or stack: %s", logs)
	}
}

func TestHealthzReturnsOK(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(noopClient()))
	resp := assertStatus(t, h, http.MethodGet, "/healthz", "", "", "", http.StatusOK)
	var body map[string]string
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("health json: %v", err)
	}
	if body["status"] != "ok" {
		t.Fatalf("health status=%v", body)
	}
}

type failingPingStore struct {
	*sqlite.Store
}

func (f failingPingStore) Ping(context.Context) error {
	return errors.New("db down")
}

func TestHealthzReturns503WhenDBUnreachable(t *testing.T) {
	_, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(noopClient()))
	h := New(cfg, failingPingStore{Store: store}, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()
	resp := assertStatus(t, h, http.MethodGet, "/healthz", "", "", "", http.StatusServiceUnavailable)
	var body map[string]string
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("health json: %v", err)
	}
	if body["status"] != "unavailable" {
		t.Fatalf("health status=%v", body)
	}
}

func startOAuth(t *testing.T, h http.Handler, redirectURI string) (string, *http.Cookie) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/auth/github/start?redirect_uri="+url.QueryEscape(redirectURI), nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusFound {
		t.Fatalf("start status=%d body=%s", resp.Code, resp.Body.String())
	}
	location, err := url.Parse(resp.Header().Get("Location"))
	if err != nil {
		t.Fatalf("parse location: %v", err)
	}
	state := location.Query().Get("state")
	if state == "" {
		t.Fatalf("state missing in %s", location.String())
	}
	for _, cookie := range resp.Result().Cookies() {
		if cookie.Name == "mp_oauth_session" {
			return state, cookie
		}
	}
	t.Fatal("mp_oauth_session cookie missing")
	return "", nil
}

func newTestHarness(t *testing.T, oauth auth.OAuthProvider, opts ...Option) (http.Handler, *sqlite.Store, string, config.Config) {
	t.Helper()
	return newTestHarnessConfig(t, oauth, nil, opts...)
}

func newTestHarnessConfig(t *testing.T, oauth auth.OAuthProvider, mutate func(*config.Config), opts ...Option) (http.Handler, *sqlite.Store, string, config.Config) {
	t.Helper()
	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Auth.OAuth.GitHub.ClientID = "client-id"
	cfg.Auth.OAuth.GitHub.ClientSecret = "client-secret"
	cfg.Coordinator.OperatorKey = "operator-key"
	cfg.Auth.OAuth.CallbackAllowlist = []string{"https://api.streamvc.live/auth/github/callback"}
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	if mutate != nil {
		mutate(&cfg)
	}
	if len(cfg.Coordinators) > 0 && cfg.Coordinator.BuyerURL != "" {
		cfg.Coordinators[0].BaseURL = cfg.Coordinator.BuyerURL
	}
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Fatalf("store.Close: %v", err)
		}
	})
	allOpts := append([]Option{WithNow(fixedNow)}, opts...)
	return New(cfg, store, oauth, allOpts...).Handler(), store, cfg.Storage.DBPath, cfg
}

func createAccountAndKey(t *testing.T, store *sqlite.Store, cfg config.Config, accountID string) string {
	t.Helper()
	if err := store.CreateAccount(context.Background(), storage.Account{
		AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	fullKey, _, err := auth.NewKeyManager(cfg.Auth.KeyPrefix, cfg.Auth.KeyHash, cfg.Auth.KeyHashSecret).Issue(context.Background(), store, accountID)
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	return fullKey
}

func assertStatus(t *testing.T, h http.Handler, method, path, bearer, demoToken, ip string, want int) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	if demoToken != "" {
		req.Header.Set("X-Demo-Token", demoToken)
	}
	if ip != "" {
		req.Header.Set("X-Real-IP", ip)
	}
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != want {
		t.Fatalf("%s %s status=%d want=%d body=%s", method, path, resp.Code, want, resp.Body.String())
	}
	return resp
}

func postChat(t *testing.T, h http.Handler, bearer, body string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+bearer)
	req.Header.Set("Content-Type", "application/json")
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	return resp
}

func readQuota(t *testing.T, resp *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("usage json: %v body=%s", err, resp.Body.String())
	}
	quota, ok := body["quota"].(map[string]any)
	if !ok {
		t.Fatalf("quota missing: %v", body)
	}
	return quota
}

func decodePoolz(t *testing.T, raw string) poolzResponse {
	t.Helper()
	var poolz poolzResponse
	if err := json.Unmarshal([]byte(raw), &poolz); err != nil {
		t.Fatalf("poolz json: %v", err)
	}
	return poolz
}

func submitFeedback(t *testing.T, h http.Handler, bearer, demoToken, body string) {
	t.Helper()
	resp := postFeedback(t, h, bearer, demoToken, body)
	if resp.Code != http.StatusOK {
		t.Fatalf("feedback status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func postFeedback(t *testing.T, h http.Handler, bearer, demoToken, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/feedback", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Real-IP", "1.2.3.4")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	if demoToken != "" {
		req.Header.Set("X-Demo-Token", demoToken)
	}
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	return resp
}

func issueDemoToken(t *testing.T, h http.Handler, ip string) string {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/auth/demo-session", nil)
	req.Header.Set("X-Real-IP", ip)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusCreated {
		t.Fatalf("demo status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body struct {
		DemoToken string `json:"demo_token"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("demo json: %v", err)
	}
	return body.DemoToken
}

func postAdminJSON(t *testing.T, h http.Handler, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer operator-key")
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("admin %s status=%d body=%s", path, resp.Code, resp.Body.String())
	}
	return resp
}

func writeTestConfig(t *testing.T, allPublicAPI bool) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "gateway.yaml")
	content := fmt.Sprintf(`
listen:
  bind_address: 127.0.0.1
  port: 9443
public:
  base_url: https://api.streamvc.live
  account_path: /account
coordinators:
  - name: pearl-local
    base_url: http://127.0.0.1:8443
    weight: 1
    enabled: true
coordinator:
  buyer_url: http://coordinator.test
  operator_url: http://operator.test
  operator_key: operator-key
  poolz_poll_interval_s: 10
storage:
  driver: sqlite
  db_path: gateway.db
auth:
  key_prefix: mp_
  key_hash: hmac_sha256
  key_hash_secret: test-key-hash-secret
  github_oauth_enabled: true
  email_magic_link_enabled: false
  oauth:
    callback_allowlist:
      - https://api.streamvc.live/auth/github/callback
    github:
      client_id: client-id
      client_secret: client-secret
      authorize_url: https://github.com/login/oauth/authorize
      token_url: https://github.com/login/oauth/access_token
      user_url: https://api.github.com/user
  demo:
    signing_secret: test-demo-secret
quotas:
  account_daily_tokens: 100000
  demo_daily_tokens_per_ip: 1000
  demo_sessions_per_ip_per_hour: 10
  account_concurrency: 2
  signup_accounts_per_ip_per_day: 3
limits:
  max_tokens_per_request: 4096
  demo_max_tokens_per_request: 512
  max_feedback_comment_bytes: 2000
  request_body_bytes: 1048576
kill_switch:
  demo_only: false
  all_public_api: %t
capacity:
  monthly_budget_usd: 500
  ready_provider_degraded_threshold: 1
  projected_cost_tier1_percent: 80
  tier_cooldown_seconds: 3600
timeouts:
  coordinator_request_seconds: 300
  streaming_cancel_ms: 500
`, allPublicAPI)
	if err := os.WriteFile(path, []byte(content), 0600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

func noopClient() *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusServiceUnavailable, nil, ""), nil
	})}
}

func modelsOKClient() *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"object":"list","data":[]}`), nil
	})}
}

func assertErrorCode(t *testing.T, raw, code string) {
	t.Helper()
	var body struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &body); err != nil {
		t.Fatalf("error json: %v body=%s", err, raw)
	}
	if body.Error.Code != code {
		t.Fatalf("error code=%q want=%q body=%s", body.Error.Code, code, raw)
	}
}

func findCookie(resp *httptest.ResponseRecorder, name string) string {
	for _, cookie := range resp.Result().Cookies() {
		if cookie.Name == name {
			return cookie.Value
		}
	}
	return ""
}

func countAuditEvents(t *testing.T, dbPath, eventType string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql open: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM audit_events WHERE event_type = ?`, eventType).Scan(&count); err != nil {
		t.Fatalf("count audit: %v", err)
	}
	return count
}

func countRows(t *testing.T, dbPath, table string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql open: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&count); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	return count
}

func fixedNow() time.Time {
	return time.Date(2026, 5, 29, 0, 0, 0, 0, time.UTC)
}

var _ = errors.Is

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func responseWithBody(status int, header http.Header, body string) *http.Response {
	if header == nil {
		header = http.Header{}
	}
	return &http.Response{
		StatusCode: status,
		Header:     header,
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}
