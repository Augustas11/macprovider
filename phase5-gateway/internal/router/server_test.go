package router

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
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
	"reflect"
	"strconv"
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

func TestGitHubOAuthDisabledRoutesAreUnmounted(t *testing.T) {
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Auth.GitHubOAuthEnabled = false
		cfg.Auth.OAuth.GitHub.ClientID = ""
		cfg.Auth.OAuth.GitHub.ClientSecret = ""
	})

	for _, path := range []string{"/auth/github/start", "/auth/github/callback"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d want 404 body=%s", path, resp.Code, resp.Body.String())
		}
	}
}

func TestGitHubOAuthHandlersFailClosedWhenDisabled(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.GitHubOAuthEnabled = false
	s := &Server{cfg: cfg}

	for name, handler := range map[string]http.HandlerFunc{
		"start":    s.handleGitHubStart,
		"callback": s.handleGitHubCallback,
	} {
		req := httptest.NewRequest(http.MethodGet, "/auth/github/"+name, nil)
		resp := httptest.NewRecorder()
		handler(resp, req)
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s status=%d want 503 body=%s", name, resp.Code, resp.Body.String())
		}
		if !strings.Contains(resp.Body.String(), "oauth_disabled") {
			t.Fatalf("%s body=%q want oauth_disabled", name, resp.Body.String())
		}
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
			"tier2":{"phase":0,"model_hash":{"active":false,"state":"none"}},
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
		Tier2           map[string]any  `json:"tier2"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("models json: %v", err)
	}
	if body.Tier2 == nil {
		t.Fatalf("gateway stripped coordinator tier2 metadata: %s", resp.Body.String())
	}
	if body.Tier2["phase"].(float64) != 0 {
		t.Fatalf("tier2 phase=%v want 0", body.Tier2["phase"])
	}
	want := (&Server{}).makeTier1Disclosure()
	if !reflect.DeepEqual(body.Tier1Disclosure, want) {
		t.Fatalf("tier1_disclosure=%+v want %+v", body.Tier1Disclosure, want)
	}
	if !strings.Contains(body.Tier1Disclosure.ModelVerificationLimit, "provider-reported request-start model hash") ||
		!strings.Contains(body.Tier1Disclosure.ModelVerificationLimit, "do not detect a provider falsifying") {
		t.Fatalf("model verification limit disclosure is incomplete: %q", body.Tier1Disclosure.ModelVerificationLimit)
	}
	settlement := body.Tier1Disclosure.VerifiedModelSettlement
	if !reflect.DeepEqual(settlement.IncludedPaidEntrypoints, []string{"POST /v1/chat/completions"}) {
		t.Fatalf("included paid entrypoints=%v", settlement.IncludedPaidEntrypoints)
	}
	if len(settlement.ExcludedPaidEntrypoints) == 0 ||
		!strings.Contains(settlement.ExcludedPaidEntrypoints[0], "coordinator.streamvc.live") ||
		!strings.Contains(settlement.ExcludedPaidEntrypoints[0], "m4.streamvc.live") ||
		!strings.Contains(settlement.ExcludedPaidEntrypoints[0], "m1.streamvc.live") {
		t.Fatalf("excluded paid entrypoints must name legacy/direct paths: %+v", settlement.ExcludedPaidEntrypoints)
	}
	for _, got := range []string{
		settlement.ModelIdentity,
		settlement.ModelIdentityCaveat,
		settlement.ObserveMode,
		settlement.EnforceMode,
		settlement.Outcomes.Quarantined,
		settlement.Outcomes.ZeroSettled,
		settlement.PartialCharge,
		settlement.StreamingFailover,
		settlement.BuyerReceiptStatus,
	} {
		if got == "" {
			t.Fatalf("settlement disclosure has empty field: %+v", settlement)
		}
	}
	if !strings.Contains(settlement.ModelIdentityCaveat, "provider-reported request-start model hash") ||
		!strings.Contains(settlement.ModelIdentityCaveat, "does not provide hardware attestation") ||
		!strings.Contains(settlement.ObserveMode, "cannot claim verified model integrity") ||
		!strings.Contains(settlement.EnforceMode, "mixed pools are not described as fully verified") ||
		!strings.Contains(settlement.Outcomes.Quarantined, "not charged") ||
		!strings.Contains(settlement.Outcomes.Quarantined, "not labeled as buyer fault") ||
		!strings.Contains(settlement.Outcomes.ZeroSettled, "no billable verified work") ||
		!strings.Contains(settlement.PartialCharge, "delivered output prefix") ||
		!strings.Contains(settlement.StreamingFailover, "does not double-charge overlapping output") ||
		!strings.Contains(settlement.BuyerReceiptStatus, "without raw prompts or raw outputs") {
		t.Fatalf("settlement disclosure is incomplete: %+v", settlement)
	}
}

func TestUsageIncludesSPEC022SettlementDisclosure(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{})
	fullKey := createAccountAndKey(t, store, cfg, "acct_usage_settlement_disclosure")
	resp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	var body struct {
		Quota                map[string]any                    `json:"quota"`
		SettlementDisclosure verifiedModelSettlementDisclosure `json:"settlement_disclosure"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("usage json: %v", err)
	}
	if body.Quota["daily_tokens_reserved"] == nil {
		t.Fatalf("usage response missing daily_tokens_reserved: %s", resp.Body.String())
	}
	disclosure := body.SettlementDisclosure
	if !strings.Contains(disclosure.PendingReservation, "quota or balance can remain reserved") ||
		!strings.Contains(disclosure.PendingReservation, "Non-verified terminal outcomes release or refund") ||
		!strings.Contains(disclosure.Outcomes.Pending, "not final usage") ||
		!strings.Contains(disclosure.Outcomes.Quarantined, "not charged") ||
		!strings.Contains(disclosure.Outcomes.Quarantined, "not labeled as buyer fault") ||
		!strings.Contains(disclosure.Outcomes.ZeroSettled, "no billable verified work") ||
		!strings.Contains(disclosure.PartialCharge, "settlement-capable receipt binds the delivered output prefix") ||
		!strings.Contains(disclosure.StreamingFailover, "does not double-charge overlapping output") ||
		!strings.Contains(disclosure.BuyerReceiptStatus, "without raw prompts or raw outputs") {
		t.Fatalf("usage settlement disclosure is incomplete: %+v", disclosure)
	}
}

func TestModelsStickyDisclosureUsesCoordinatorRoutingMetadata(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/v1/models":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"object":"list","data":[]}`), nil
		case "/internal/routing":
			if got := r.Header.Get("Authorization"); got != "Bearer service-token" {
				t.Fatalf("operator auth = %q", got)
			}
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"sticky":{"enabled":true,"ttl_seconds":1800}}`), nil
		default:
			t.Fatalf("unexpected request path %s", r.URL.Path)
			return nil, nil
		}
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Routing.StickyEnabled = true
		cfg.Routing.StickyTTLS = 1800
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_models_sticky_disclosure")
	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusOK)
	var body struct {
		Tier1Disclosure tier1Disclosure `json:"tier1_disclosure"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("models json: %v", err)
	}
	if body.Tier1Disclosure.StickyAffinity == nil || !body.Tier1Disclosure.StickyAffinity.Enabled {
		t.Fatalf("sticky disclosure not enabled: %+v", body.Tier1Disclosure.StickyAffinity)
	}
	if body.Tier1Disclosure.StickyAffinity.TTLSeconds != 1800 {
		t.Fatalf("sticky ttl=%d, want 1800", body.Tier1Disclosure.StickyAffinity.TTLSeconds)
	}
}

func TestModelsDisclosureReflectsTier2HashState(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/v1/models":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"object":"list",
				"data":[{
					"id":"model-a",
					"object":"model",
					"hash_verified":false,
					"hash_verification":{
						"status":"partial",
						"verified_provider_count":1,
						"uncatalogued_provider_count":1,
						"mismatch_provider_count":0,
						"invalid_provider_count":0,
						"catalogued":true
					}
				}],
				"tier2":{"phase":1,"model_hash":{"active":true,"state":"partial","require_verified":false,"catalog_available":true}}
			}`), nil
		case "/internal/routing":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"sticky":{"enabled":false,"ttl_seconds":1800},
				"tier2":{"phase":1,"model_hash":{"active":true,"state":"partial"}}
			}`), nil
		default:
			t.Fatalf("unexpected request path %s", r.URL.Path)
			return nil, nil
		}
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_models_tier2_disclosure")
	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusOK)
	var body struct {
		Tier1Disclosure tier1Disclosure `json:"tier1_disclosure"`
		Tier2           map[string]any  `json:"tier2"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("models json: %v", err)
	}
	if body.Tier2 == nil {
		t.Fatalf("gateway stripped coordinator tier2 metadata: %s", resp.Body.String())
	}
	modelHash, _ := body.Tier2["model_hash"].(map[string]any)
	if modelHash == nil || modelHash["state"] != "partial" || modelHash["require_verified"] != false {
		t.Fatalf("tier2 model_hash wrong: %+v body=%s", modelHash, resp.Body.String())
	}
	disclosure := body.Tier1Disclosure
	if disclosure.Version != "v0.8+tier2-v0.2" {
		t.Fatalf("version=%q", disclosure.Version)
	}
	if disclosure.PlaintextToProvider != true {
		t.Fatal("plaintext_to_provider should remain true")
	}
	if disclosure.ModelHashVerified != "partial" || disclosure.ProviderLegEncryption != "none" || disclosure.UntrustedProviderSafety != "none" {
		t.Fatalf("tier2 top-level disclosure wrong: %+v", disclosure)
	}
	if disclosure.Tier2 == nil || intFromModelField(disclosure.Tier2.Phase) != 1 || disclosure.Tier2.ModelHash.VerifiedProviderCount != 1 || disclosure.Tier2.ModelHash.UncataloguedProviderCount != 1 || !disclosure.Tier2.ModelHash.Mixed {
		t.Fatalf("tier2 detail wrong: %+v", disclosure.Tier2)
	}
}

func TestModelsDisclosureUsesTier2MetadataWhenNoHashRows(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/v1/models":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"object":"list","data":[]}`), nil
		case "/internal/routing":
			if got := r.Header.Get("Authorization"); got != "Bearer service-token" {
				t.Fatalf("operator auth = %q", got)
			}
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"sticky":{"enabled":false,"ttl_seconds":1800},
				"tier2":{
					"phase":"mixed",
					"model_hash":{"active":true,"state":"none"}
				}
			}`), nil
		default:
			t.Fatalf("unexpected request path %s", r.URL.Path)
			return nil, nil
		}
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_models_tier2_metadata")
	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusOK)
	var body struct {
		Tier1Disclosure tier1Disclosure `json:"tier1_disclosure"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("models json: %v", err)
	}
	disclosure := body.Tier1Disclosure
	if disclosure.Version != "v0.8+tier2-v0.2" || disclosure.ModelHashVerified != "none" {
		t.Fatalf("tier2 disclosure wrong: %+v", disclosure)
	}
	if disclosure.Tier2 == nil || disclosure.Tier2.Phase != "mixed" || disclosure.Tier2.ModelHash.VerifiedProviderCount != 0 || disclosure.Tier2.ModelHash.UncataloguedProviderCount != 0 {
		t.Fatalf("tier2 detail wrong: %+v", disclosure.Tier2)
	}
}

func TestModelsDisclosureIncludesBehavioralSafetyMetadata(t *testing.T) {
	cases := []struct {
		name       string
		metadata   string
		wantSafety string
		wantCap    bool
		wantEncode bool
		wantTTFT   bool
	}{
		{
			name: "enforced",
			metadata: `{
				"sticky":{"enabled":false,"ttl_seconds":1800},
				"tier2":{
					"phase":"mixed",
					"model_hash":{"active":false,"state":"none"},
					"behavioral_safety":{"state":"enforced","size_cap":true,"encoding_validation":true,"ttft_anomaly_logging":true}
				}
			}`,
			wantSafety: "enforced",
			wantCap:    true,
			wantEncode: true,
			wantTTFT:   true,
		},
		{
			name: "partial",
			metadata: `{
				"sticky":{"enabled":false,"ttl_seconds":1800},
				"tier2":{
					"phase":"mixed",
					"model_hash":{"active":false,"state":"none"},
					"behavioral_safety":{"state":"partial","size_cap":true,"encoding_validation":false,"ttft_anomaly_logging":false}
				}
			}`,
			wantSafety: "partial",
			wantCap:    true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				switch r.URL.Path {
				case "/v1/models":
					return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"object":"list","data":[]}`), nil
				case "/internal/routing":
					return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, tc.metadata), nil
				default:
					t.Fatalf("unexpected request path %s", r.URL.Path)
					return nil, nil
				}
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Coordinator.OperatorURL = "http://operator.test"
			}, WithHTTPClient(client))
			fullKey := createAccountAndKey(t, store, cfg, "acct_models_tier2_behavioral_"+tc.name)
			resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusOK)
			var body struct {
				Tier1Disclosure tier1Disclosure `json:"tier1_disclosure"`
			}
			if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
				t.Fatalf("models json: %v", err)
			}
			disclosure := body.Tier1Disclosure
			if disclosure.UntrustedProviderSafety != tc.wantSafety {
				t.Fatalf("untrusted_provider_safety=%q want %q disclosure=%+v", disclosure.UntrustedProviderSafety, tc.wantSafety, disclosure)
			}
			if disclosure.Tier2 == nil || disclosure.Tier2.BehavioralSafety.State != tc.wantSafety || disclosure.Tier2.BehavioralSafety.SizeCap != tc.wantCap || disclosure.Tier2.BehavioralSafety.EncodingValidation != tc.wantEncode || disclosure.Tier2.BehavioralSafety.TTFTAnomalyLogging != tc.wantTTFT {
				t.Fatalf("behavioral safety disclosure wrong: %+v", disclosure.Tier2)
			}
		})
	}
}

func TestModelsDisclosureIncludesEncryptedLegAndAttestationMetadata(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/v1/models":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"object":"list","data":[]}`), nil
		case "/internal/routing":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"sticky":{"enabled":false,"ttl_seconds":1800},
				"tier2":{
					"phase":"mixed",
					"model_hash":{"active":false,"state":"none"},
					"encrypted_leg":{"state":"partial","encrypted_provider_count":1,"unencrypted_provider_count":1,"mixed":true,"scope":"coordinator_to_provider_only"},
					"attestation":{"state":"unsupported","attested_provider_count":0,"unsupported_provider_count":2,"mixed":false}
				}
			}`), nil
		default:
			t.Fatalf("unexpected request path %s", r.URL.Path)
			return nil, nil
		}
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_models_tier2_bc_metadata")

	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusOK)

	var body struct {
		Tier1Disclosure tier1Disclosure `json:"tier1_disclosure"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("models json: %v", err)
	}
	disclosure := body.Tier1Disclosure
	if disclosure.ProviderLegEncryption != "partial" || disclosure.HardwareAttestation != "unsupported" {
		t.Fatalf("tier1 encrypted/attestation disclosure wrong: %+v", disclosure)
	}
	if disclosure.Tier2 == nil {
		t.Fatalf("tier2 disclosure missing: %+v", disclosure)
	}
	if disclosure.Tier2.EncryptedLeg.State != "partial" || disclosure.Tier2.EncryptedLeg.EncryptedProviderCount != 1 || disclosure.Tier2.EncryptedLeg.UnencryptedProviderCount != 1 || !disclosure.Tier2.EncryptedLeg.Mixed || disclosure.Tier2.EncryptedLeg.Scope != "coordinator_to_provider_only" {
		t.Fatalf("encrypted leg disclosure wrong: %+v", disclosure.Tier2.EncryptedLeg)
	}
	if disclosure.Tier2.Attestation.State != "unsupported" || disclosure.Tier2.Attestation.AttestedProviderCount != 0 || disclosure.Tier2.Attestation.UnsupportedProviderCount != 2 || disclosure.Tier2.Attestation.Mixed {
		t.Fatalf("attestation disclosure wrong: %+v", disclosure.Tier2.Attestation)
	}
}

func TestModelsDisclosureDoesNotUseCachedTier2MetadataToUpgrade(t *testing.T) {
	calls := 0
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/internal/routing" {
			t.Fatalf("unexpected request path %s", r.URL.Path)
		}
		calls++
		if calls == 1 {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"sticky":{"enabled":false,"ttl_seconds":1800},
				"tier2":{"phase":1,"model_hash":{"active":true,"state":"none"}}
			}`), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"sticky":{"enabled":false,"ttl_seconds":1800},
			"tier2":{"phase":0,"model_hash":{"active":false,"state":"none"}}
		}`), nil
	})}
	cfg := config.Default()
	cfg.Coordinator.OperatorURL = "http://operator.test"
	cfg.Coordinator.OperatorKey = "operator-key"
	server := &Server{cfg: cfg, client: client, now: fixedNow}

	if _, ok := server.coordinatorRoutingMetadata(context.Background()); !ok {
		t.Fatal("seed routing metadata cache failed")
	}
	disclosure := server.makeTier1DisclosureForModels(map[string]any{"data": []any{}}, context.Background())

	if disclosure.Version != "v0.8" || disclosure.Tier2 != nil || disclosure.ModelHashVerified != "" {
		t.Fatalf("disclosure used stale cached tier2 metadata: %+v", disclosure)
	}
	if calls != 2 {
		t.Fatalf("routing metadata calls=%d, want 2", calls)
	}
}

func TestModelsDisclosureFailsClosedWhenHashRowsLackFreshActiveMetadata(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/v1/models":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"object":"list",
				"data":[{
					"id":"model-a",
					"object":"model",
					"hash_verified":true,
					"hash_verification":{
						"status":"all_verified",
						"verified_provider_count":1,
						"uncatalogued_provider_count":0,
						"mismatch_provider_count":0,
						"invalid_provider_count":0,
						"catalogued":true
					}
				}]
			}`), nil
		case "/internal/routing":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"sticky":{"enabled":false,"ttl_seconds":1800},
				"tier2":{"phase":0,"model_hash":{"active":false,"state":"none"}}
			}`), nil
		default:
			t.Fatalf("unexpected request path %s", r.URL.Path)
			return nil, nil
		}
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_models_tier2_fail_closed")

	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusBadGateway)

	assertErrorCode(t, resp.Body.String(), "tier2_metadata_unavailable")
}

func TestModelsDisclosureUsesPhase1FallbackWhenRoutingUnavailableButBodyHasHashRows(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/v1/models":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"object":"list",
				"data":[{
					"id":"model-a",
					"object":"model",
					"hash_verified":true,
					"hash_verification":{
						"status":"all_verified",
						"verified_provider_count":1,
						"uncatalogued_provider_count":0,
						"mismatch_provider_count":0,
						"invalid_provider_count":0,
						"catalogued":true
					}
				}]
			}`), nil
		case "/internal/routing":
			return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, `{}`), nil
		default:
			t.Fatalf("unexpected request path %s", r.URL.Path)
			return nil, nil
		}
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_models_tier2_phase1_fallback")

	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusOK)

	var body struct {
		Tier1Disclosure tier1Disclosure `json:"tier1_disclosure"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("models json: %v", err)
	}
	disclosure := body.Tier1Disclosure
	if disclosure.Tier2 == nil || intFromModelField(disclosure.Tier2.Phase) != 1 {
		t.Fatalf("tier2 phase=%v want 1 body=%s", disclosure.Tier2, resp.Body.String())
	}
	if disclosure.ModelHashVerified != "all" {
		t.Fatalf("model_hash_verified=%q want all body=%s", disclosure.ModelHashVerified, resp.Body.String())
	}
}

func TestTier2MetadataHelpersAreConservative(t *testing.T) {
	if got := disclosureStateFromMetadata("required"); got != "none" {
		t.Fatalf("required metadata state mapped to %q, want none", got)
	}
	if got := tier2PhaseFromMetadata(float64(5)); got != 0 {
		t.Fatalf("unknown float phase mapped to %v, want 0", got)
	}
	if got := tier2PhaseFromMetadata(json.Number("5")); got != 0 {
		t.Fatalf("unknown json.Number phase mapped to %v, want 0", got)
	}
	if got := tier2PhaseFromMetadata("mixed"); got != "mixed" {
		t.Fatalf("mixed phase mapped to %v, want mixed", got)
	}
}

func TestModelsDisclosureFailsClosedWhenTopLevelTier2ActiveMetadataUnavailable(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/v1/models":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"object":"list",
				"data":[],
				"tier2":{"phase":1,"model_hash":{"active":true,"state":"none"}}
			}`), nil
		case "/internal/routing":
			return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, `{}`), nil
		default:
			t.Fatalf("unexpected request path %s", r.URL.Path)
			return nil, nil
		}
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_models_tier2_empty_fail_closed")

	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusBadGateway)

	assertErrorCode(t, resp.Body.String(), "tier2_metadata_unavailable")
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

	req := httptest.NewRequest(http.MethodPost, "/admin/kill-switch", strings.NewReader(`{"all_public_api":true,"version":0}`))
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
	if reloaded.KillSwitch.AllPublicAPI {
		t.Fatalf("kill switch mutated deploy config")
	}
	runtimeState, err := store.GetKillSwitch(context.Background())
	if err != nil {
		t.Fatalf("runtime kill switch: %v", err)
	}
	if !runtimeState.AllPublicAPI {
		t.Fatalf("kill switch did not persist to runtime state")
	}
	if runtimeState.Version != 1 {
		t.Fatalf("kill switch version=%d want 1", runtimeState.Version)
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

func TestKillSwitchVersionConflictRejectsStaleWrite(t *testing.T) {
	h, store, _, _ := newTestHarness(t, fakeOAuth{})

	first := postAdminJSON(t, h, "/admin/kill-switch", `{"demo_only":true,"version":0}`)
	var firstBody struct {
		KillSwitch storage.KillSwitchState `json:"kill_switch"`
	}
	if err := json.Unmarshal(first.Body.Bytes(), &firstBody); err != nil {
		t.Fatalf("first response json: %v", err)
	}
	if firstBody.KillSwitch.Version != 1 {
		t.Fatalf("first version=%d want 1", firstBody.KillSwitch.Version)
	}

	req := httptest.NewRequest(http.MethodPost, "/admin/kill-switch", strings.NewReader(`{"all_public_api":true,"version":0}`))
	req.Header.Set("Authorization", "Bearer operator-key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusConflict {
		t.Fatalf("stale kill switch status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "kill_switch_version_conflict")
	var conflict struct {
		CurrentVersion int64 `json:"current_version"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &conflict); err != nil {
		t.Fatalf("conflict json: %v", err)
	}
	if conflict.CurrentVersion != 1 {
		t.Fatalf("current_version=%d want 1", conflict.CurrentVersion)
	}
	state, err := store.GetKillSwitch(context.Background())
	if err != nil {
		t.Fatalf("GetKillSwitch: %v", err)
	}
	if !state.DemoOnly || state.AllPublicAPI {
		t.Fatalf("stale write changed state: %+v", state)
	}
}

type failCapacitySetStore struct {
	*sqlite.Store
}

func (s failCapacitySetStore) SetCapacityTier(ctx context.Context, tier storage.CapacityTier) error {
	return errors.New("forced capacity write failure")
}

type failCapacityGetStore struct {
	*sqlite.Store
}

func (s failCapacityGetStore) GetCapacityTier(ctx context.Context) (storage.CapacityTier, error) {
	return storage.CapacityTier{}, errors.New("forced capacity load failure")
}

func TestCapacityTransitionWriteFailureReturns500AndMetric(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Coordinator.OperatorKey = "operator-key"
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()

	h := New(cfg, failCapacitySetStore{Store: store}, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()
	req := httptest.NewRequest(http.MethodPost, "/admin/capacity-signal", strings.NewReader(`{"signal":"cpu","value":80,"threshold":70,"firing":true}`))
	req.Header.Set("Authorization", "Bearer operator-key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusInternalServerError {
		t.Fatalf("capacity failure status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "admin_state_write_failed")
	tier, err := store.GetCapacityTier(context.Background())
	if err != nil {
		t.Fatalf("GetCapacityTier: %v", err)
	}
	if tier.Tier != 0 {
		t.Fatalf("capacity tier=%d want unchanged 0", tier.Tier)
	}

	metricsReq := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	metricsResp := httptest.NewRecorder()
	h.ServeHTTP(metricsResp, metricsReq)
	if metricsResp.Code != http.StatusOK {
		t.Fatalf("metrics status=%d body=%s", metricsResp.Code, metricsResp.Body.String())
	}
	if !strings.Contains(metricsResp.Body.String(), `admin_state_write_error_total{handler="capacity"} 1`) {
		t.Fatalf("metrics missing capacity write error increment:\n%s", metricsResp.Body.String())
	}
}

func TestCapacityTierLoadFailureReturns500AndMetric(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Coordinator.OperatorKey = "operator-key"
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()

	h := New(cfg, failCapacityGetStore{Store: store}, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()
	req := httptest.NewRequest(http.MethodPost, "/admin/capacity-signal", strings.NewReader(`{"signal":"cpu","value":80,"threshold":70,"firing":true}`))
	req.Header.Set("Authorization", "Bearer operator-key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusInternalServerError {
		t.Fatalf("capacity load failure status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "admin_state_write_failed")
	tier, err := store.GetCapacityTier(context.Background())
	if err != nil {
		t.Fatalf("GetCapacityTier: %v", err)
	}
	if tier.Tier != 0 {
		t.Fatalf("capacity tier=%d want unchanged 0", tier.Tier)
	}

	metricsReq := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	metricsResp := httptest.NewRecorder()
	h.ServeHTTP(metricsResp, metricsReq)
	if metricsResp.Code != http.StatusOK {
		t.Fatalf("metrics status=%d body=%s", metricsResp.Code, metricsResp.Body.String())
	}
	if !strings.Contains(metricsResp.Body.String(), `admin_state_write_error_total{handler="capacity"} 1`) {
		t.Fatalf("metrics missing capacity load error increment:\n%s", metricsResp.Body.String())
	}
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

// TestPoolzPollUsesOperatorKeyNotServiceToken pins the auth-path fix: the
// /v1/status poll of the coordinator's /poolz endpoint must authenticate
// with OperatorKey, NOT UpstreamCoordinatorBearer(). /poolz is operator-only
// on the coordinator (OperatorOnlyBearerMatches) and rejects the service
// token. After the M3-2 service-token cutover set coordinator.service_token,
// UpstreamCoordinatorBearer() began preferring the service token, so the poll
// got 401 and the gateway reported coordinator-down with an empty pool.
//
// This test configures BOTH service_token and operator_key (distinct values)
// and asserts the /poolz request carries Bearer <operator_key>. As a low-cost
// guard it also drives the /v1/sticky DELETE (an /internal/* call) and
// confirms that path still sends Bearer <service_token> via
// UpstreamCoordinatorBearer() — i.e. the fix is scoped to /poolz only.
func TestPoolzPollUsesOperatorKeyNotServiceToken(t *testing.T) {
	const operatorKey = "op-key-distinct"
	const serviceToken = "svc-token-distinct"

	var poolzAuth, stickyAuth string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/poolz"):
			poolzAuth = r.Header.Get("Authorization")
			// Mirror the coordinator: operator-only, rejects service token.
			if poolzAuth != "Bearer "+operatorKey {
				return responseWithBody(http.StatusUnauthorized, nil, `{}`), nil
			}
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
				"pool":[{"model_id":"llama","state":"ready","slots_free":1,"slots_total":2,"max_context_tokens":8192}],
				"summary":{"total_providers":1,"ready":1,"total_slots":2,"free_slots":1}
			}`), nil
		case strings.HasSuffix(r.URL.Path, "/internal/sticky"):
			stickyAuth = r.Header.Get("Authorization")
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"purged":true,"entries":0}`), nil
		default:
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{}`), nil
		}
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Coordinator.OperatorKey = operatorKey
		cfg.Coordinator.ServiceToken = serviceToken
		cfg.Routing.StickyEnabled = true
	}, WithHTTPClient(client))

	// /poolz poll must use the operator key, never the service token.
	_ = assertStatus(t, h, http.MethodGet, "/v1/status", "", "", "", http.StatusOK)
	if poolzAuth != "Bearer "+operatorKey {
		t.Fatalf("/poolz Authorization = %q, want %q", poolzAuth, "Bearer "+operatorKey)
	}
	if poolzAuth == "Bearer "+serviceToken {
		t.Fatalf("/poolz leaked the service token: %q", poolzAuth)
	}

	// /internal/* calls must still use UpstreamCoordinatorBearer() (service
	// token when set) — the fix is scoped to /poolz only.
	fullKey := createAccountAndKey(t, store, cfg, "acct_poolz_scope")
	del := httptest.NewRequest(http.MethodDelete, "/v1/sticky", nil)
	del.Header.Set("Authorization", "Bearer "+fullKey)
	delResp := httptest.NewRecorder()
	h.ServeHTTP(delResp, del)
	if delResp.Code != http.StatusOK {
		t.Fatalf("sticky delete status=%d body=%s", delResp.Code, delResp.Body.String())
	}
	if stickyAuth != "Bearer "+serviceToken {
		t.Fatalf("/internal/sticky Authorization = %q, want %q", stickyAuth, "Bearer "+serviceToken)
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

func TestAggregateStatusL1ByteIdenticalWhenNoProviderPublishes(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"model-a","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"supported_models":["model-a","model-b"],"publishes_supported_models":false},
			{"model_id":"model-a","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"supported_models":["model-a","model-c"]}
		],
		"summary":{"total_providers":2,"ready":2,"total_slots":2,"free_slots":2}
	}`), 1, fixedNow())

	body, err := json.Marshal(out)
	if err != nil {
		t.Fatalf("marshal status: %v", err)
	}
	if bytes.Contains(body, []byte(`"supported_models"`)) {
		t.Fatalf("status JSON contains supported_models in L-1 opt-out case: %s", string(body))
	}
}

func TestAggregateStatusEchoesSupportedModelsWhenSingleProviderPublishes(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"model-a","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"supported_models":["model-b","model-a"],"publishes_supported_models":true}
		],
		"summary":{"total_providers":1,"ready":1,"total_slots":1,"free_slots":1}
	}`), 1, fixedNow())

	if len(out.Models) != 1 {
		t.Fatalf("models=%+v, want one model", out.Models)
	}
	want := []string{"model-a", "model-b"}
	if !reflect.DeepEqual(out.Models[0].SupportedModels, want) {
		t.Fatalf("supported_models=%+v, want %+v", out.Models[0].SupportedModels, want)
	}
}

func TestAggregateStatusUnionsSupportedModelsAcrossPublishingProviders(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"model-a","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"supported_models":["model-a","model-b"],"publishes_supported_models":true},
			{"model_id":"model-a","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"supported_models":["model-a","model-c"],"publishes_supported_models":true}
		],
		"summary":{"total_providers":2,"ready":2,"total_slots":2,"free_slots":2}
	}`), 1, fixedNow())

	if len(out.Models) != 1 {
		t.Fatalf("models=%+v, want one model", out.Models)
	}
	want := []string{"model-a", "model-b", "model-c"}
	if !reflect.DeepEqual(out.Models[0].SupportedModels, want) {
		t.Fatalf("supported_models=%+v, want %+v", out.Models[0].SupportedModels, want)
	}
}

func TestAggregateStatusExcludesNonPublishingProviderFromUnion(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"model-a","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"supported_models":["model-a","model-b"],"publishes_supported_models":true},
			{"model_id":"model-a","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"supported_models":["model-a","model-z"],"publishes_supported_models":false}
		],
		"summary":{"total_providers":2,"ready":2,"total_slots":2,"free_slots":2}
	}`), 1, fixedNow())

	if len(out.Models) != 1 {
		t.Fatalf("models=%+v, want one model", out.Models)
	}
	want := []string{"model-a", "model-b"}
	if !reflect.DeepEqual(out.Models[0].SupportedModels, want) {
		t.Fatalf("supported_models=%+v, want %+v", out.Models[0].SupportedModels, want)
	}
}

// SPEC-003 v0.8.3 FR-C9.4 — bearerless-duplicate sessions are admitted to
// /poolz for operator visibility but are non-routable. The gateway's buyer-
// facing /v1/status aggregation MUST exclude them so the headline "Ready"
// count and per-model availability don't promise capacity the coordinator
// will refuse to route. Tracking issue #82 item 1.
func TestAggregateStatusExcludesBearerlessDuplicatesFromCapacity(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"llama","state":"ready","slots_free":2,"slots_total":2,"max_context_tokens":4096,"auth_state":"bearer_validated"},
			{"model_id":"llama","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"bearerless_duplicate"},
			{"model_id":"llama","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"self_minted"},
			{"model_id":"llama","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096}
		],
		"summary":{"total_providers":4,"ready":3,"total_slots":5,"free_slots":5}
	}`), 1, fixedNow())

	if out.Pool.TotalProviders != 2 {
		t.Fatalf("TotalProviders=%d, want 2 (bearerless duplicate and self_minted excluded)", out.Pool.TotalProviders)
	}
	if out.Pool.Ready != 2 {
		t.Fatalf("Pool.Ready=%d, want 2 (bearerless duplicate and self_minted excluded)", out.Pool.Ready)
	}
	if len(out.Models) != 1 {
		t.Fatalf("models=%+v, want one model entry", out.Models)
	}
	m := out.Models[0]
	if m.ProviderCount != 2 {
		t.Fatalf("model.ProviderCount=%d, want 2 (bearerless duplicate and self_minted excluded)", m.ProviderCount)
	}
	if m.ReadyProviderCount != 2 {
		t.Fatalf("model.ReadyProviderCount=%d, want 2 (bearerless duplicate and self_minted excluded)", m.ReadyProviderCount)
	}
	if m.TotalSlots != 3 {
		t.Fatalf("model.TotalSlots=%d, want 3 (2 excluded slots omitted)", m.TotalSlots)
	}
	if m.SlotsFree != 3 {
		t.Fatalf("model.SlotsFree=%d, want 3 (2 excluded slots omitted)", m.SlotsFree)
	}
	if !m.Available || m.Availability != "available" {
		t.Fatalf("model availability=%+v, want available", m)
	}
}

// All-bearerless pool MUST collapse to no-ready capacity even when the
// coordinator's summary echoes a non-zero total. The Ready=0 promise is the
// load-bearing invariant — buyers MUST NOT see Available=true for a model
// whose only sessions are non-routable bearerless duplicates.
func TestAggregateStatusAllBearerlessPoolReportsNoCapacity(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"llama","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"bearerless_duplicate"}
		],
		"summary":{"total_providers":1,"ready":0,"total_slots":1,"free_slots":0}
	}`), 1, fixedNow())

	if out.Pool.Ready != 0 {
		t.Fatalf("Pool.Ready=%d, want 0", out.Pool.Ready)
	}
	if out.Status != "idle" {
		t.Fatalf("status=%q, want idle", out.Status)
	}
	if len(out.Models) != 0 {
		t.Fatalf("models=%+v, want no model entries (bearerless skipped before model registration)", out.Models)
	}
}

// Regression for the IMPL r1 MEDIUM finding: when /poolz returns pool rows
// that are ALL bearerless_duplicate AND the coordinator's summary reports a
// non-zero Ready, the old fallback (`out.Pool.TotalProviders == 0`)
// reintroduced the excluded Ready capacity into the buyer-visible status.
// The fix gates the fallback on `len(poolz.Pool) == 0` instead, so an
// all-bearerless pool collapses to no capacity even if the coordinator's
// summary is non-zero. (A non-zero coordinator summary.ready alongside an
// all-bearerless pool is a misconfigured-coordinator shape, but the gateway
// MUST NOT amplify it into a buyer-visible promise.)
func TestAggregateStatusAllBearerlessPoolIgnoresSummaryFallback(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"llama","state":"ready","slots_free":2,"slots_total":2,"max_context_tokens":4096,"auth_state":"bearerless_duplicate"}
		],
		"summary":{"total_providers":3,"ready":2,"total_slots":4,"free_slots":2}
	}`), 1, fixedNow())

	if out.Pool.TotalProviders != 0 {
		t.Fatalf("Pool.TotalProviders=%d, want 0 (summary fallback MUST NOT fire when pool rows are present)", out.Pool.TotalProviders)
	}
	if out.Pool.Ready != 0 {
		t.Fatalf("Pool.Ready=%d, want 0 (summary fallback MUST NOT reintroduce excluded Ready)", out.Pool.Ready)
	}
	if out.Status != "idle" {
		t.Fatalf("status=%q, want idle", out.Status)
	}
}

// Summary-fallback positive case: a coordinator that returns ONLY a summary
// (no pool rows) is still honored by the gateway — this preserves the
// pre-existing behavior the fallback was added for. The condition is "no
// detailed pool rows," not "no aggregated capacity after filtering."
func TestAggregateStatusSummaryFallbackFiresOnlyWhenPoolIsEmpty(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[],
		"summary":{"total_providers":2,"ready":2,"total_slots":4,"free_slots":3}
	}`), 1, fixedNow())

	if out.Pool.TotalProviders != 2 {
		t.Fatalf("Pool.TotalProviders=%d, want 2 (summary fallback)", out.Pool.TotalProviders)
	}
	if out.Pool.Ready != 2 {
		t.Fatalf("Pool.Ready=%d, want 2 (summary fallback)", out.Pool.Ready)
	}
}

// SPEC-003 v0.8.3 enum coverage — pins per-value routability so future
// changes MUST update this test and SPEC-002 v1.4.1's aggregation rule together.
// Non-routable auth_state values (bearerless_duplicate, self_minted, mint_failed)
// are excluded from buyer-facing /v1/status capacity.
func TestAggregateStatusAuthStateRoutabilityCoverage(t *testing.T) {
	cases := []struct {
		name      string
		authState string
		wantReady int
	}{
		{name: "empty (pre-v0.8.3 coordinator)", authState: "", wantReady: 1},
		{name: "bearer_validated", authState: "bearer_validated", wantReady: 1},
		{name: "self_minted", authState: "self_minted", wantReady: 0},
		{name: "mint_failed", authState: "mint_failed", wantReady: 0},
		{name: "unknown future value (defensive default = aggregate)", authState: "future_value_xyz", wantReady: 1},
		{name: "bearerless_duplicate", authState: "bearerless_duplicate", wantReady: 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			payload := fmt.Sprintf(`{
				"pool":[
					{"model_id":"llama","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":%q}
				],
				"summary":{"total_providers":1,"ready":%d,"total_slots":1,"free_slots":1}
			}`, tc.authState, tc.wantReady)
			out := aggregateStatus(decodePoolz(t, payload), 1, fixedNow())
			if out.Pool.Ready != tc.wantReady {
				t.Fatalf("auth_state=%q: Pool.Ready=%d, want %d", tc.authState, out.Pool.Ready, tc.wantReady)
			}
		})
	}
}

// Drift-prevention: the string literal in server.go MUST track SPEC-002
// v1.4.1's normative enum value. If the SPEC ever renames
// `bearerless_duplicate`, this test pins the gateway-side const so the
// rename surfaces as a test failure before silent capacity over-promising.
func TestAuthStateBearerlessDuplicateConstantMatchesSpec(t *testing.T) {
	const want = "bearerless_duplicate"
	if authStateBearerlessDuplicate != want {
		t.Fatalf("authStateBearerlessDuplicate = %q, want %q (SPEC-002 v1.4.1 FR-O2 aggregation rule)", authStateBearerlessDuplicate, want)
	}
}

func TestPoolzProviderCountsTowardBuyerCapacity(t *testing.T) {
	falseVal := false
	trueVal := true
	cases := []struct {
		name string
		row  poolzProviderRow
		want bool
	}{
		{name: "routing_eligible true", row: poolzProviderRow{RoutingEligible: &trueVal}, want: true},
		{name: "routing_eligible false", row: poolzProviderRow{RoutingEligible: &falseVal, AuthState: "bearer_validated"}, want: false},
		{name: "legacy bearer_validated", row: poolzProviderRow{AuthState: "bearer_validated"}, want: true},
		{name: "legacy self_minted", row: poolzProviderRow{AuthState: "self_minted"}, want: false},
		{name: "legacy bearerless_duplicate", row: poolzProviderRow{AuthState: "bearerless_duplicate"}, want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := poolzProviderCountsTowardBuyerCapacity(tc.row); got != tc.want {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
		})
	}
}

func TestAggregateStatusAllSelfMintedPoolReportsNoCapacity(t *testing.T) {
	out := aggregateStatus(decodePoolz(t, `{
		"pool":[
			{"model_id":"llama","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"self_minted","routing_eligible":false}
		],
		"summary":{"total_providers":1,"ready":0,"total_slots":1,"free_slots":0}
	}`), 1, fixedNow())

	if out.Pool.Ready != 0 {
		t.Fatalf("Pool.Ready=%d, want 0", out.Pool.Ready)
	}
	if out.Status != "idle" {
		t.Fatalf("status=%q, want idle", out.Status)
	}
	if len(out.Models) != 0 {
		t.Fatalf("models=%+v, want no model entries", out.Models)
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

func TestFeedbackRequiresSourceAndBoundsWrites(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{})
	fullKey := createAccountAndKey(t, store, cfg, "acct_feedback_bounds")

	req := httptest.NewRequest(http.MethodPost, "/v1/feedback", strings.NewReader(`{"rating":4,"comment":"ok","scope":"account"}`))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("missing source status=%d want 400 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "invalid_feedback_source")

	tooLargeBody := `{"rating":4,"comment":"` + strings.Repeat("x", int(cfg.Limits.MaxFeedbackBodyBytes)) + `","scope":"account"}`
	resp = postFeedback(t, h, fullKey, "", tooLargeBody)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("oversize body status=%d want 400 body=%s", resp.Code, resp.Body.String())
	}

	tooLongComment := `{"rating":4,"comment":"` + strings.Repeat("x", cfg.Limits.MaxFeedbackCommentBytes+1) + `","scope":"account"}`
	resp = postFeedback(t, h, fullKey, "", tooLongComment)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("long comment status=%d want 400 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "comment_too_long")
}

func TestFeedbackRateLimitPerIP(t *testing.T) {
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Limits.FeedbackRequestsPerIPPerHour = 10
	})
	fullKey := createAccountAndKey(t, store, cfg, "acct_feedback_rate")
	for i := 0; i < 10; i++ {
		submitFeedback(t, h, fullKey, "", fmt.Sprintf(`{"rating":4,"comment":"ok %d","scope":"account"}`, i))
	}
	resp := postFeedback(t, h, fullKey, "", `{"rating":4,"comment":"blocked","scope":"account"}`)
	if resp.Code != http.StatusTooManyRequests {
		t.Fatalf("11th feedback status=%d want 429 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "feedback_rate_limited")
	// Round-3 SECURITY MEDIUM revert: no Retry-After ships on this path and
	// it sits outside the 30-RPS account clamp, so retryable:true would
	// invite SDK auto-retry hot-looping against an unthrottled endpoint.
	assertBodyRetryable(t, resp.Body.String(), false)
}

func TestFeedbackSummaryLimitsRawScan(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{})
	for i := 0; i < 1100; i++ {
		if err := store.InsertFeedbackEvent(context.Background(), storage.FeedbackEvent{
			EventID: fmt.Sprintf("fb_limit_%04d", i), RequestID: "", AccountID: "acct_summary_limit",
			Scope: "account", Rating: 4, Comment: "", CreatedAt: fixedNow().Add(time.Duration(i) * time.Second),
		}); err != nil {
			t.Fatalf("InsertFeedbackEvent %d: %v", i, err)
		}
	}
	req := httptest.NewRequest(http.MethodGet, "/admin/feedback-summary", nil)
	req.Header.Set("Authorization", "Bearer "+cfg.Coordinator.OperatorKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("summary status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body struct {
		RatingCount int `json:"rating_count"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("summary json: %v body=%s", err, resp.Body.String())
	}
	if body.RatingCount != 1000 {
		t.Fatalf("rating_count=%d want 1000 limited raw scan", body.RatingCount)
	}
}

func TestOperatorBearerAuthorized(t *testing.T) {
	headers := http.Header{}
	headers.Set("Authorization", "Bearer operator-key")
	if !operatorBearerAuthorized(headers, "operator-key") {
		t.Fatal("valid operator bearer rejected")
	}
	headers.Set("Authorization", "Bearer bad-key")
	if operatorBearerAuthorized(headers, "operator-key") {
		t.Fatal("invalid operator bearer accepted")
	}
	if operatorBearerAuthorized(headers, "") {
		t.Fatal("empty operator key accepted")
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

func TestReceiptHeaderForwardedAndSiblingMacProviderHeadersStripped(t *testing.T) {
	const receipt = "receipt-tuple.signature"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{
			"Content-Type":                    []string{"application/json"},
			"X-MacProvider-Receipt":           []string{receipt},
			"X-MacProvider-Foo":               []string{"strip-me"},
			"X-MacProvider-Receipt-Pending":   []string{"strip-me-too"},
			"X-MacProvider-Completion-Tokens": []string{"4"},
		}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_receipt_header")

	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := resp.Header().Get("X-MacProvider-Receipt"); got != receipt {
		t.Fatalf("receipt header = %q, want %q", got, receipt)
	}
	for _, header := range []string{"X-MacProvider-Foo", "X-MacProvider-Receipt-Pending", "X-MacProvider-Completion-Tokens"} {
		if got := resp.Header().Get(header); got != "" {
			t.Fatalf("buyer response exposed %s=%q", header, got)
		}
	}
}

func TestSettlementV04ReceiptHeaderStrippedFromBuyerResponse(t *testing.T) {
	receipt := base64.StdEncoding.EncodeToString([]byte(`{"receipt_version":"4","terminal_state_ts_unix_ms":1782864001789}`)) + "." + base64.StdEncoding.EncodeToString([]byte("signature"))
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{
			"Content-Type":          []string{"application/json"},
			"X-MacProvider-Receipt": []string{receipt},
		}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_receipt_header_v04")

	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := resp.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("v0.4 settlement receipt header leaked to buyer: %q", got)
	}
}

func TestNullUsageErrorReceiptHeaderForwarded(t *testing.T) {
	const receipt = "null-usage-receipt.signature"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusBadGateway, http.Header{
			"Content-Type":                    []string{"application/json"},
			"X-MacProvider-Receipt":           []string{receipt},
			"X-MacProvider-Foo":               []string{"strip-me"},
			"X-MacProvider-Receipt-Pending":   []string{"strip-me-too"},
			"X-MacProvider-Completion-Tokens": []string{"4"},
		}, `{"error":{"message":"model not loaded","type":"api_error","param":null,"code":"error_model_not_loaded"}}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_receipt_null_usage")

	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "error_model_not_loaded")
	if got := resp.Header().Get("X-MacProvider-Receipt"); got != receipt {
		t.Fatalf("receipt header = %q, want %q", got, receipt)
	}
	for _, header := range []string{"X-MacProvider-Foo", "X-MacProvider-Receipt-Pending", "X-MacProvider-Completion-Tokens"} {
		if got := resp.Header().Get(header); got != "" {
			t.Fatalf("null-usage response exposed %s=%q", header, got)
		}
	}
}

func TestGatewayAuthFailureDoesNotExposeReceiptHeader(t *testing.T) {
	upstreamCalled := false
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamCalled = true
		return responseWithBody(http.StatusOK, http.Header{
			"Content-Type":          []string{"application/json"},
			"X-MacProvider-Receipt": []string{"must-not-leak.signature"},
		}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))

	resp := postChat(t, h, "mp_invalid", `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if upstreamCalled {
		t.Fatalf("gateway contacted upstream after auth failure")
	}
	if got := resp.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("auth failure exposed receipt header %q", got)
	}
}

func TestQuotaExhaustedDoesNotExposeReceiptHeader(t *testing.T) {
	upstreamCalled := false
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamCalled = true
		return responseWithBody(http.StatusOK, http.Header{
			"Content-Type":          []string{"application/json"},
			"X-MacProvider-Receipt": []string{"must-not-leak-quota.signature"},
		}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	_, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_receipt_quota_reject")
	fakeStore := &quotaReserveFakeStore{
		Store: store,
		decision: storage.QuotaDecision{
			LimitTokens: 1000, UsedTokens: 1000, RemainingTokens: 0,
			ResetUnix: resetUnix(fixedNow().UTC().Format("2006-01-02")),
		},
		err: storage.ErrQuotaExceeded,
	}
	h := New(cfg, fakeStore, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client)).Handler()

	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if upstreamCalled {
		t.Fatalf("gateway contacted upstream after quota rejection")
	}
	if got := resp.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("quota rejection exposed receipt header %q", got)
	}
}

func TestKillSwitchRejectDoesNotExposeReceiptHeader(t *testing.T) {
	upstreamCalled := false
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamCalled = true
		return responseWithBody(http.StatusOK, http.Header{
			"Content-Type":          []string{"application/json"},
			"X-MacProvider-Receipt": []string{"must-not-leak-killswitch.signature"},
		}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.KillSwitch.AllPublicAPI = true
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_receipt_kill_switch")

	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if upstreamCalled {
		t.Fatalf("gateway contacted upstream after kill-switch rejection")
	}
	if got := resp.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("kill-switch rejection exposed receipt header %q", got)
	}
}

func TestGenericProviderErrorReceiptHeaderStripped(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusBadGateway, http.Header{
			"Content-Type":          []string{"application/json"},
			"X-MacProvider-Receipt": []string{"generic-error-receipt.signature"},
		}, `{"error":{"message":"provider failed","type":"api_error","param":null,"code":"provider_failed"}}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_receipt_generic_error")

	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "upstream_provider_error")
	if got := resp.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("generic provider error exposed receipt header %q", got)
	}
}

func TestStreamingReceiptHeaderStripped(t *testing.T) {
	const receipt = "stream-receipt.signature"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := `data: {"id":"chatcmpl","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"delta":{"content":"ok"}}]}`
		return responseWithBody(http.StatusOK, http.Header{
			"Content-Type":                    []string{"text/event-stream; charset=utf-8"},
			"Trailer":                         []string{settlementOutcomeHeader + ", " + settlementModeHeader},
			"X-MacProvider-Receipt":           []string{receipt},
			"X-MacProvider-Foo":               []string{"strip-me"},
			"X-MacProvider-Receipt-Pending":   []string{"strip-me-too"},
			"X-MacProvider-Completion-Tokens": []string{"4"},
		}, payload+"\n\ndata: [DONE]\n\n"), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_stream_receipt_header")

	resp := postChat(t, h, fullKey, `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := resp.Header().Get("Content-Type"); got != "text/event-stream; charset=utf-8" {
		t.Fatalf("content-type=%q", got)
	}
	for _, header := range []string{"X-MacProvider-Receipt", "X-MacProvider-Foo", "X-MacProvider-Receipt-Pending", "X-MacProvider-Completion-Tokens"} {
		if got := resp.Header().Get(header); got != "" {
			t.Fatalf("streaming buyer response exposed %s=%q", header, got)
		}
	}
	if got := resp.Header().Get("Trailer"); got != "" {
		t.Fatalf("streaming buyer response exposed upstream Trailer declaration %q", got)
	}
	// Issue #190 R2 security HIGH: streaming success responses
	// carry per-tenant X-RateLimit-*-Requests headers and must NOT
	// be cacheable. The SSE-required no-cache/no-transform must
	// coexist with no-store; previously the streaming path
	// overwrote the entry-level no-store header.
	cacheControl := resp.Header().Get("Cache-Control")
	if !strings.Contains(cacheControl, "no-store") {
		t.Errorf("streaming Cache-Control=%q must contain no-store", cacheControl)
	}
	if !strings.Contains(cacheControl, "no-cache") || !strings.Contains(cacheControl, "no-transform") {
		t.Errorf("streaming Cache-Control=%q must keep no-cache and no-transform", cacheControl)
	}
	if got := resp.Header().Get("X-RateLimit-Limit-Requests"); got == "" {
		t.Errorf("streaming response missing X-RateLimit-Limit-Requests")
	}
}

// TestStreamingModeHeaderForwarded pins the item-15 fix: SPEC-018 AC-45's
// buyer-visible X-MacProvider-Streaming-Mode diagnostic — set by the
// coordinator on streaming 200 responses — must survive the gateway's
// blanket X-MacProvider-* strip and reach the buyer, while sibling
// X-MacProvider-* headers stay stripped. Covers all three canonical values.
func TestStreamingModeHeaderForwarded(t *testing.T) {
	for _, mode := range []string{"incremental", "buffered_kill_switch", "buffered_provider_downgrade"} {
		t.Run(mode, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				payload := `data: {"id":"chatcmpl","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"delta":{"content":"ok"}}]}`
				return responseWithBody(http.StatusOK, http.Header{
					"Content-Type":                 []string{"text/event-stream; charset=utf-8"},
					"X-MacProvider-Streaming-Mode": []string{mode},
					"X-MacProvider-Foo":            []string{"strip-me"},
				}, payload+"\n\ndata: [DONE]\n\n"), nil
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			fullKey := createAccountAndKey(t, store, cfg, "acct_stream_mode_"+mode)

			resp := postChat(t, h, fullKey, `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			if got := resp.Header().Get("X-MacProvider-Streaming-Mode"); got != mode {
				t.Fatalf("streaming-mode header = %q, want %q", got, mode)
			}
			if got := resp.Header().Get("X-MacProvider-Foo"); got != "" {
				t.Fatalf("sibling X-MacProvider-Foo leaked = %q", got)
			}
		})
	}
}

// TestStreamingModeHeaderInvalidValueDropped pins the AC-45 defense-in-depth
// enum guard: any upstream value outside the byte-exact closed set is dropped,
// not forwarded or normalized — a compromised/misconfigured upstream cannot
// smuggle arbitrary header content past the X-MacProvider-* strip, and the
// gateway matches SPEC-006 §5.4's "drop any other value" (no trim, no
// case-folding). Covers injection, whitespace-wrapped, case-variant, and
// empty values.
func TestStreamingModeHeaderInvalidValueDropped(t *testing.T) {
	for _, bad := range []struct{ name, value string }{
		{"crlf_injection", "evil\r\ninjected: 1"},
		{"leading_trailing_ws", " incremental "},
		{"case_variant", "Incremental"},
		{"empty", ""},
		{"unknown_token", "buffered"},
	} {
		t.Run(bad.name, func(t *testing.T) {
			value := bad.value
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				payload := `data: {"id":"chatcmpl","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"delta":{"content":"ok"}}]}`
				return responseWithBody(http.StatusOK, http.Header{
					"Content-Type":                 []string{"text/event-stream; charset=utf-8"},
					"X-MacProvider-Streaming-Mode": []string{value},
				}, payload+"\n\ndata: [DONE]\n\n"), nil
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			fullKey := createAccountAndKey(t, store, cfg, "acct_stream_mode_invalid_"+bad.name)

			resp := postChat(t, h, fullKey, `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			if got := resp.Header().Get("X-MacProvider-Streaming-Mode"); got != "" {
				t.Fatalf("non-canonical streaming-mode value %q forwarded = %q (must be dropped)", value, got)
			}
		})
	}
}

func TestSPEC022GatewayStreamingSettlementTrailersControlBuyerDebit(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	payload := strings.Join([]string{
		`data: {"id":"chatcmpl","choices":[{"delta":{"content":"ok"}}]}`,
		`data: {"id":"chatcmpl","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"delta":{},"finish_reason":"stop"}]}`,
		`data: [DONE]`,
		``,
	}, "\n\n")
	pendingDeadlineUnixMS := fixedNow().Add(5 * time.Minute).UnixMilli()
	cases := []struct {
		name           string
		trailer        http.Header
		declareOnly    bool
		wantUsageRows  int64
		wantSettled    int64
		wantRefunded   int64
		wantActive     int64
		wantActiveHold int64
		wantExpiresAt  int64
	}{
		{
			name:          "legacy-no-trailer-debits",
			wantUsageRows: 1,
			wantSettled:   1,
		},
		{
			name:           "verified-closed-trailer-holds-for-reconcile",
			trailer:        settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "verified", "valid", "true", "receipt_verified"),
			wantActive:     1,
			wantActiveHold: promptCapTokens([]byte(body)) + 20,
		},
		{
			name:         "quarantined-closed-trailer-refunds",
			trailer:      settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "quarantined", "invalid", "true", "receipt_invalid"),
			wantRefunded: 1,
		},
		{
			name:         "overlap-blocked-terminal-closed-trailer-refunds",
			trailer:      settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "overlap_blocked_terminal", "valid", "true", "overlap_blocked"),
			wantRefunded: 1,
		},
		{
			name:           "pending-open-trailer-holds",
			trailer:        settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "pending", "inconclusive", "false", "pending_recovery", pendingDeadlineUnixMS),
			wantActive:     1,
			wantActiveHold: promptCapTokens([]byte(body)) + 20,
			wantExpiresAt:  pendingDeadlineUnixMS,
		},
		{
			name:          "declared-missing-trailer-settles-unverified",
			declareOnly:   true,
			wantUsageRows: 1,
			wantSettled:   1,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				header := http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}
				trailer := tc.trailer
				if trailer != nil || tc.declareOnly {
					header.Set("Trailer", strings.Join(settlementFinalityHeaderNamesForTest(), ", "))
				}
				if trailer == nil && tc.declareOnly {
					trailer = http.Header{}
					for _, name := range settlementFinalityHeaderNamesForTest() {
						trailer[name] = nil
					}
				}
				return &http.Response{
					StatusCode: http.StatusOK,
					Header:     header,
					Trailer:    trailer,
					Body:       io.NopCloser(strings.NewReader(payload)),
				}, nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			accountID := "acct_spec022_stream_finality_" + strings.ReplaceAll(tc.name, "-", "_")
			fullKey := createAccountAndKey(t, store, cfg, accountID)

			resp := postChat(t, h, fullKey, body, nil)
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			if got := resp.Header().Get("Trailer"); got != "" {
				t.Fatalf("buyer streaming response leaked internal Trailer declaration %q", got)
			}
			for _, header := range settlementFinalityHeaderNamesForTest() {
				if got := resp.Header().Get(header); got != "" {
					t.Fatalf("buyer streaming response leaked internal settlement header %s=%q", header, got)
				}
			}
			if !strings.Contains(resp.Body.String(), "data: [DONE]") {
				t.Fatalf("streaming response missing OpenAI-compatible DONE frame: %s", resp.Body.String())
			}
			got := gatewaySettlementSnapshot(t, dbPath, accountID)
			if got.usageRows != tc.wantUsageRows || got.settledRows != tc.wantSettled || got.refundedRows != tc.wantRefunded || got.activeRows != tc.wantActive || got.activeReserved != tc.wantActiveHold {
				t.Fatalf("settlement snapshot = %+v, want usage=%d settled=%d refunded=%d active=%d active_reserved=%d",
					got, tc.wantUsageRows, tc.wantSettled, tc.wantRefunded, tc.wantActive, tc.wantActiveHold)
			}
			if tc.wantExpiresAt > 0 {
				if got := gatewayReservationExpiresAtUnixMS(t, dbPath, accountID); got != tc.wantExpiresAt {
					t.Fatalf("reservation expires_at=%d want coordinator pending deadline %d", got, tc.wantExpiresAt)
				}
			}
		})
	}
}

func TestSPEC022GatewayStreamingNonOKFinalityBoundsHold(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	pendingDeadlineUnixMS := fixedNow().Add(5 * time.Minute).UnixMilli()
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		h := settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "pending", "inconclusive", "false", "missing_receipt_deadline_open", pendingDeadlineUnixMS)
		h.Set("Content-Type", "application/json")
		return responseWithBody(http.StatusGatewayTimeout, h, `{"error":{"message":"timeout","type":"api_error","param":null,"code":"provider_timeout"}}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_spec022_stream_non_ok_pending"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)
	if resp.Code != http.StatusGatewayTimeout {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	for _, header := range settlementFinalityHeaderNamesForTest() {
		if got := resp.Header().Get(header); got != "" {
			t.Fatalf("buyer streaming error response leaked internal settlement header %s=%q", header, got)
		}
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.usageRows != 0 || got.settledRows != 0 || got.refundedRows != 0 || got.activeRows != 1 || got.activeReserved != promptCapTokens([]byte(body))+20 {
		t.Fatalf("settlement snapshot = %+v, want non-OK streaming pending finality to hold reservation without debit", got)
	}
	if got := gatewayReservationExpiresAtUnixMS(t, dbPath, accountID); got != pendingDeadlineUnixMS {
		t.Fatalf("reservation expires_at=%d want coordinator pending deadline %d", got, pendingDeadlineUnixMS)
	}
}

func TestSPEC022GatewaySettlementReconcileFinalizesHeldReservation(t *testing.T) {
	accountID := "acct_spec022_reconcile_verified"
	requestID := "req_spec022_reconcile_verified"
	var captured http.Header
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured = r.Header.Clone()
		if r.URL.Path != "/internal/settlement/finality" {
			t.Fatalf("coordinator path=%s", r.URL.Path)
		}
		if got := r.URL.Query().Get("account_id"); got != accountID {
			t.Fatalf("account_id query=%q want %q", got, accountID)
		}
		if got := r.URL.Query().Get("request_id"); got != requestID {
			t.Fatalf("request_id query=%q want %q", got, requestID)
		}
		if got, want := r.URL.Query().Get("reservation_created_at_unix_ms"), strconv.FormatInt(fixedNow().UnixMilli(), 10); got != want {
			t.Fatalf("reservation_created_at_unix_ms query=%q want %q", got, want)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"request_id":        requestID,
			"policy_version":    settlementPolicyVersion,
			"mode":              "enforce",
			"outcome":           "verified",
			"receipt_result":    "valid",
			"reason":            "verified_settlement",
			"closed":            true,
			"prompt_tokens":     8,
			"completion_tokens": 4,
			"total_tokens":      12,
			"token_source":      "coordinator_observed",
			"verified_attempts": 1,
		})
	}))
	defer coordinator.Close()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
		cfg.Coordinator.OperatorKey = "operator-key"
		cfg.Coordinator.ServiceToken = "service-token"
	}, WithHTTPClient(coordinator.Client()))
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      fixedNow().UTC().Format("2006-01-02"),
		RequestedTokens: 20,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       fixedNow(),
		ExpiresAt:       fixedNow().Add(5 * time.Minute),
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.ClampReservationExpiry(context.Background(), accountID, requestID, fixedNow().Add(4*time.Minute)); err != nil {
		t.Fatalf("ClampReservationExpiry: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile?limit=10", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var summary settlementReconcileSummary
	if err := json.Unmarshal(resp.Body.Bytes(), &summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.Scanned != 1 || summary.Verified != 1 || summary.Errors != 0 {
		t.Fatalf("summary=%+v, want one verified reconciliation", summary)
	}
	if got := captured.Get("Authorization"); got != "Bearer service-token" {
		t.Fatalf("coordinator Authorization=%q want service token", got)
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.usageRows != 1 || got.settledRows != 1 || got.refundedRows != 0 || got.activeRows != 0 {
		t.Fatalf("settlement snapshot=%+v, want verified debit and settled reservation", got)
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "spec022_verified" || source != "coordinator_observed" {
		t.Fatalf("usage outcome/source=%s/%s, want spec022_verified/coordinator_observed", outcome, source)
	}
}

func TestSPEC022GatewayStreamingReconcileConsumesCoordinatorVerifiedFinality(t *testing.T) {
	accountID := "acct_spec022_streaming_contract"
	requestID := "req_spec015_v04_streaming_tool_call_nonzero_prefix"
	const promptTokens int64 = 11
	const completionTokens int64 = 7
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/internal/settlement/finality" {
			t.Fatalf("coordinator path=%s", r.URL.Path)
		}
		if got := r.URL.Query().Get("account_id"); got != accountID {
			t.Fatalf("account_id query=%q want %q", got, accountID)
		}
		if got := r.URL.Query().Get("request_id"); got != requestID {
			t.Fatalf("request_id query=%q want %q", got, requestID)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer service-token" {
			t.Fatalf("coordinator Authorization=%q want service token", got)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"request_id":        requestID,
			"policy_version":    settlementPolicyVersion,
			"mode":              "enforce",
			"outcome":           "verified",
			"receipt_result":    "valid",
			"reason":            "verified_settlement",
			"closed":            true,
			"prompt_tokens":     promptTokens,
			"completion_tokens": completionTokens,
			"total_tokens":      promptTokens + completionTokens,
			"token_source":      "coordinator_observed",
			"verified_attempts": 1,
		})
	}))
	defer coordinator.Close()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
		cfg.Coordinator.OperatorKey = "operator-key"
		cfg.Coordinator.ServiceToken = "service-token"
	}, WithHTTPClient(coordinator.Client()))
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      fixedNow().UTC().Format("2006-01-02"),
		RequestedTokens: 32,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       fixedNow(),
		ExpiresAt:       fixedNow().Add(5 * time.Minute),
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.ClampReservationExpiry(context.Background(), accountID, requestID, fixedNow().Add(4*time.Minute)); err != nil {
		t.Fatalf("ClampReservationExpiry: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile?limit=10", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var summary settlementReconcileSummary
	if err := json.Unmarshal(resp.Body.Bytes(), &summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.Scanned != 1 || summary.Verified != 1 || summary.Errors != 0 {
		t.Fatalf("summary=%+v, want one verified streaming reconciliation", summary)
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.usageRows != 1 || got.settledRows != 1 || got.refundedRows != 0 || got.activeRows != 0 {
		t.Fatalf("settlement snapshot=%+v, want verified debit and settled streaming reservation", got)
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
	if outcome != "spec022_verified" || source != "coordinator_observed" || prompt != promptTokens || completion != completionTokens {
		t.Fatalf("usage event outcome/source/tokens=%s/%s/%d/%d, want spec022_verified/coordinator_observed/%d/%d",
			outcome, source, prompt, completion, promptTokens, completionTokens)
	}
}

func TestSPEC022GatewaySettlementReconcileRejectsMissingTokenSource(t *testing.T) {
	accountID := "acct_spec022_missing_token_source"
	requestID := "req_spec022_missing_token_source"
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/internal/settlement/finality" {
			t.Fatalf("coordinator path=%s", r.URL.Path)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"request_id":        requestID,
			"policy_version":    settlementPolicyVersion,
			"mode":              "enforce",
			"outcome":           "verified",
			"receipt_result":    "valid",
			"reason":            "verified_settlement",
			"closed":            true,
			"prompt_tokens":     11,
			"completion_tokens": 7,
			"total_tokens":      18,
			"verified_attempts": 1,
		})
	}))
	defer coordinator.Close()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
		cfg.Coordinator.OperatorKey = "operator-key"
		cfg.Coordinator.ServiceToken = "service-token"
	}, WithHTTPClient(coordinator.Client()))
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      fixedNow().UTC().Format("2006-01-02"),
		RequestedTokens: 32,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       fixedNow(),
		ExpiresAt:       fixedNow().Add(5 * time.Minute),
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.ClampReservationExpiry(context.Background(), accountID, requestID, fixedNow().Add(4*time.Minute)); err != nil {
		t.Fatalf("ClampReservationExpiry: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile?limit=10", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var summary settlementReconcileSummary
	if err := json.Unmarshal(resp.Body.Bytes(), &summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.Scanned != 1 || summary.Verified != 0 || summary.Errors != 1 {
		t.Fatalf("summary=%+v, want missing token_source rejected as reconcile error", summary)
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.usageRows != 0 || got.settledRows != 0 || got.refundedRows != 0 || got.activeRows != 1 {
		t.Fatalf("settlement snapshot=%+v, want reservation held with no buyer debit", got)
	}
}

func TestSPEC022GatewaySettlementReconcileRefundsAndHolds(t *testing.T) {
	now := fixedNow()
	pendingDeadlineUnixMS := now.Add(2 * time.Minute).UnixMilli()
	finalities := map[string]map[string]any{
		"req_refund": {
			"request_id":     "req_refund",
			"policy_version": settlementPolicyVersion,
			"mode":           "enforce",
			"outcome":        "quarantined",
			"receipt_result": "invalid",
			"reason":         "signature_verify_failed",
			"closed":         true,
		},
		"req_hold": {
			"request_id":               "req_hold",
			"policy_version":           settlementPolicyVersion,
			"mode":                     "enforce",
			"outcome":                  "pending",
			"receipt_result":           "inconclusive",
			"reason":                   "receipt_verdict_pending",
			"closed":                   false,
			"pending_deadline_unix_ms": pendingDeadlineUnixMS,
		},
	}
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := finalities[r.URL.Query().Get("request_id")]
		if !ok {
			writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Settlement finality not found")
			return
		}
		writeJSON(w, http.StatusOK, body)
	}))
	defer coordinator.Close()
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
		cfg.Coordinator.OperatorKey = "operator-key"
	}, WithHTTPClient(coordinator.Client()))
	for _, requestID := range []string{"req_refund", "req_hold", "req_missing"} {
		expiresAt := now.Add(5 * time.Minute)
		if requestID == "req_missing" {
			expiresAt = now.Add(-time.Minute)
		}
		if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
			AccountID:       "acct_spec022_reconcile",
			RequestID:       requestID,
			WindowDate:      now.UTC().Format("2006-01-02"),
			RequestedTokens: 20,
			DailyQuota:      cfg.Quotas.AccountDailyTokens,
			CreatedAt:       now,
			ExpiresAt:       now.Add(24 * time.Hour),
		}); err != nil {
			t.Fatalf("ReserveQuota %s: %v", requestID, err)
		}
		if err := store.ClampReservationExpiry(context.Background(), "acct_spec022_reconcile", requestID, expiresAt); err != nil {
			t.Fatalf("ClampReservationExpiry %s: %v", requestID, err)
		}
	}
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       "acct_spec022_reconcile",
		RequestID:       "req_ordinary_active",
		WindowDate:      now.UTC().Format("2006-01-02"),
		RequestedTokens: 20,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       now,
		ExpiresAt:       now.Add(24 * time.Hour),
	}); err != nil {
		t.Fatalf("ReserveQuota ordinary active: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile?limit=10", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var summary settlementReconcileSummary
	if err := json.Unmarshal(resp.Body.Bytes(), &summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.Scanned != 3 || summary.Refunded != 1 || summary.StaleHeld != 1 || summary.Held != 1 || summary.Coordinator404 != 1 || summary.Skipped != 0 || summary.Errors != 0 {
		t.Fatalf("summary=%+v, want refund/hold/stale-held coordinator-404 split", summary)
	}
	got := gatewaySettlementSnapshot(t, dbPath, "acct_spec022_reconcile")
	if got.usageRows != 0 || got.settledRows != 0 || got.refundedRows != 1 || got.activeRows != 2 || got.expiredRows != 0 || got.staleHeldRows != 1 || got.activeReserved != 40 {
		t.Fatalf("settlement snapshot=%+v, want one refund, one stale-held coordinator-404 hold, one held pending reservation, and one ordinary active reservation", got)
	}
	if got := gatewayReservationExpiresAtUnixMSForRequest(t, dbPath, "acct_spec022_reconcile", "req_hold"); got != pendingDeadlineUnixMS {
		t.Fatalf("held reservation expires_at=%d want %d", got, pendingDeadlineUnixMS)
	}
}

func TestSPEC022GatewaySettlementReconcileTreatsTerminalRaceAsSkipped(t *testing.T) {
	accountID := "acct_spec022_reconcile_race"
	requestID := "req_spec022_reconcile_race"
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"request_id":        requestID,
			"policy_version":    settlementPolicyVersion,
			"mode":              "enforce",
			"outcome":           "verified",
			"receipt_result":    "valid",
			"reason":            "verified_settlement",
			"closed":            true,
			"prompt_tokens":     8,
			"completion_tokens": 4,
			"total_tokens":      12,
			"token_source":      "coordinator_observed",
			"verified_attempts": 1,
		})
	}))
	defer coordinator.Close()
	_, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
		cfg.Coordinator.OperatorKey = "operator-key"
	}, WithHTTPClient(coordinator.Client()))
	now := fixedNow()
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      now.UTC().Format("2006-01-02"),
		RequestedTokens: 20,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       now,
		ExpiresAt:       now.Add(24 * time.Hour),
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
	if err := store.ClampReservationExpiry(context.Background(), accountID, requestID, now.Add(5*time.Minute)); err != nil {
		t.Fatalf("ClampReservationExpiry: %v", err)
	}
	stale := storage.ActiveReservation{
		AccountID:      accountID,
		RequestID:      requestID,
		WindowDate:     now.UTC().Format("2006-01-02"),
		ReservedTokens: 20,
		ExpiresAt:      now.Add(5 * time.Minute),
		CreatedAt:      now,
	}
	if err := store.RefundReservation(context.Background(), accountID, requestID, now.Unix()); err != nil {
		t.Fatalf("RefundReservation race setup: %v", err)
	}
	s := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(coordinator.Client()))
	result, err := s.reconcileSettlementReservation(context.Background(), stale)
	if err != nil {
		t.Fatalf("reconcile terminal race err=%v", err)
	}
	if result != "already_terminal" {
		t.Fatalf("reconcile terminal race result=%q want already_terminal", result)
	}
}

type settlementHoldContextStore struct {
	*sqlite.Store
	clampCtxErr error
	markCtxErr  error
}

func (s *settlementHoldContextStore) ClampReservationExpiry(ctx context.Context, accountID, requestID string, expiresAt time.Time) error {
	s.clampCtxErr = ctx.Err()
	return nil
}

func (s *settlementHoldContextStore) MarkReservationSettlementHold(ctx context.Context, accountID, requestID string) error {
	s.markCtxErr = ctx.Err()
	return nil
}

func TestSPEC022GatewaySettlementReconcileHoldUsesCallerContext(t *testing.T) {
	accountID := "acct_spec022_reconcile_hold_ctx"
	requestID := "req_spec022_reconcile_hold_ctx"
	pendingDeadlineUnixMS := fixedNow().Add(5 * time.Minute).UnixMilli()
	wrapped := &settlementHoldContextStore{}
	s := &Server{store: wrapped, now: fixedNow}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	ctx = context.WithValue(ctx, requestIDKey{}, requestID)
	req := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile", nil).WithContext(ctx)

	if !s.boundStreamingSettlementHold(ctx, req, usageSubject{AccountID: accountID}, coordinatorSettlementFinality{
		Action:                settlementFinalityHold,
		Outcome:               "pending",
		Reason:                "receipt_verdict_pending",
		PendingDeadlineUnixMS: pendingDeadlineUnixMS,
	}) {
		t.Fatal("boundStreamingSettlementHold returned false")
	}
	if !errors.Is(wrapped.clampCtxErr, context.Canceled) {
		t.Fatalf("ClampReservationExpiry ctx err=%v want context.Canceled", wrapped.clampCtxErr)
	}
}

func TestSPEC022GatewayStreamingVerifiedHoldIgnoresBuyerCanceledContext(t *testing.T) {
	accountID := "acct_spec022_stream_hold_ctx"
	requestID := "req_spec022_stream_hold_ctx"
	wrapped := &settlementHoldContextStore{}
	s := &Server{store: wrapped, now: fixedNow}
	ctx := context.WithValue(context.Background(), requestIDKey{}, requestID)
	ctx, cancel := context.WithCancel(ctx)
	cancel()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)

	s.markStreamingSettlementHoldForReconciliation(req, usageSubject{AccountID: accountID}, coordinatorSettlementFinality{
		Action:  settlementFinalityDebit,
		Outcome: "verified",
		Reason:  "verified_settlement",
	})

	if wrapped.markCtxErr != nil {
		t.Fatalf("MarkReservationSettlementHold ctx err=%v want nil despite canceled buyer context", wrapped.markCtxErr)
	}
}

func TestSPEC022GatewayNonStreamingPendingHoldIgnoresBuyerCanceledContext(t *testing.T) {
	accountID := "acct_spec022_nonstream_pending_hold_ctx"
	requestID := "req_spec022_nonstream_pending_hold_ctx"
	pendingDeadlineUnixMS := fixedNow().Add(5 * time.Minute).UnixMilli()
	wrapped := &settlementHoldContextStore{}
	s := &Server{store: wrapped, now: fixedNow}
	ctx := context.WithValue(context.Background(), requestIDKey{}, requestID)
	ctx, cancel := context.WithCancel(ctx)
	cancel()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
	h := settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "pending", "inconclusive", "false", "receipt_verdict_pending", pendingDeadlineUnixMS)
	w := httptest.NewRecorder()

	if !s.settleBeforeResponseWithCoordinatorFinality(w, req, usageSubject{AccountID: accountID}, 1, 1, 2, "coordinator", "pending", h) {
		t.Fatalf("settleBeforeResponseWithCoordinatorFinality status=%d body=%s", w.Code, w.Body.String())
	}
	if wrapped.markCtxErr != nil {
		t.Fatalf("MarkReservationSettlementHold ctx err=%v want nil despite canceled buyer context", wrapped.markCtxErr)
	}
	if wrapped.clampCtxErr != nil {
		t.Fatalf("ClampReservationExpiry ctx err=%v want nil despite canceled buyer context", wrapped.clampCtxErr)
	}
}

func TestSPEC022GatewayStreamingPendingHoldIgnoresBuyerCanceledContext(t *testing.T) {
	accountID := "acct_spec022_stream_pending_hold_ctx"
	requestID := "req_spec022_stream_pending_hold_ctx"
	pendingDeadlineUnixMS := fixedNow().Add(5 * time.Minute).UnixMilli()
	wrapped := &settlementHoldContextStore{}
	s := &Server{store: wrapped, now: fixedNow}
	ctx := context.WithValue(context.Background(), requestIDKey{}, requestID)
	ctx, cancel := context.WithCancel(ctx)
	cancel()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
	resp := &http.Response{
		Trailer: settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "pending", "inconclusive", "false", "receipt_verdict_pending", pendingDeadlineUnixMS),
	}

	s.settleStreamingAfterCommitWithCoordinatorFinality(req, usageSubject{AccountID: accountID}, 1, 1, 2, "coordinator", "pending", "", resp)

	if wrapped.markCtxErr != nil {
		t.Fatalf("MarkReservationSettlementHold ctx err=%v want nil despite canceled buyer context", wrapped.markCtxErr)
	}
	if wrapped.clampCtxErr != nil {
		t.Fatalf("ClampReservationExpiry ctx err=%v want nil despite canceled buyer context", wrapped.clampCtxErr)
	}
}

func settlementFinalityHeaderNamesForTest() []string {
	return []string{
		settlementOutcomeHeader,
		settlementReceiptResultHeader,
		settlementReasonHeader,
		settlementClosedHeader,
		settlementModeHeader,
		settlementPolicyVersionHeader,
		settlementPendingUntilHeader,
	}
}

func settlementFinalityTrailerForTest(mode, policyVersion, outcome, receiptResult, closed, reason string, pendingDeadlineUnixMS ...int64) http.Header {
	h := http.Header{}
	h.Set(settlementModeHeader, mode)
	h.Set(settlementPolicyVersionHeader, policyVersion)
	h.Set(settlementOutcomeHeader, outcome)
	h.Set(settlementReceiptResultHeader, receiptResult)
	h.Set(settlementClosedHeader, closed)
	h.Set(settlementReasonHeader, reason)
	if len(pendingDeadlineUnixMS) > 0 && pendingDeadlineUnixMS[0] > 0 {
		h.Set(settlementPendingUntilHeader, strconv.FormatInt(pendingDeadlineUnixMS[0], 10))
	}
	return h
}

// TestProviderAttributionHeadersEmitted asserts the gateway surfaces
// the coord-internal provider peer id (X-MacProvider-Provider) under
// the public X-Provider-Id header on the buyer-facing response, for
// BOTH non-streaming and streaming paths. Required for harness B5/B6
// verdicts (slot utilization, per-provider earnings) which were
// SKIP-ing on every benchmark run because there was no per-request
// provider attribution surface. The internal-prefixed header is
// still stripped, and the session-assigned-token X-MacProvider-Route
// is NOT surfaced (auth-shaped value, deliberately not leaked).
func TestProviderAttributionHeadersEmitted(t *testing.T) {
	const peerID = "m4-air-augstar"
	const routeToken = "session-route-token-do-not-leak"

	t.Run("non-streaming", func(t *testing.T) {
		client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			h := http.Header{}
			h.Set("Content-Type", "application/json")
			h.Set("X-MacProvider-Provider", peerID)
			h.Set("X-MacProvider-Route", routeToken)
			return responseWithBody(http.StatusOK, h, `{"id":"chatcmpl","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
		})}
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
			cfg.Coordinator.BuyerURL = "http://coordinator.test"
		}, WithHTTPClient(client))
		fullKey := createAccountAndKey(t, store, cfg, "acct_attr_nonstream")

		resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

		if resp.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
		}
		if got := resp.Header().Get("X-Provider-Id"); got != peerID {
			t.Errorf("non-streaming X-Provider-Id = %q, want %q", got, peerID)
		}
		if got := resp.Header().Get("X-MacProvider-Provider"); got != "" {
			t.Errorf("non-streaming buyer response leaked internal X-MacProvider-Provider = %q", got)
		}
		if got := resp.Header().Get("X-MacProvider-Route"); got != "" {
			t.Errorf("non-streaming buyer response leaked X-MacProvider-Route = %q (session token must not be exposed)", got)
		}
		if got := resp.Header().Get("X-Provider-Assigned-Id"); got != "" {
			t.Errorf("non-streaming response surfaced X-Provider-Assigned-Id = %q (route token is not for buyers)", got)
		}
	})

	t.Run("streaming", func(t *testing.T) {
		client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			payload := `data: {"id":"chatcmpl","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"delta":{"content":"ok"}}]}`
			h := http.Header{}
			h.Set("Content-Type", "text/event-stream; charset=utf-8")
			h.Set("X-MacProvider-Provider", peerID)
			h.Set("X-MacProvider-Route", routeToken)
			return responseWithBody(http.StatusOK, h, payload+"\n\ndata: [DONE]\n\n"), nil
		})}
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
			cfg.Coordinator.BuyerURL = "http://coordinator.test"
		}, WithHTTPClient(client))
		fullKey := createAccountAndKey(t, store, cfg, "acct_attr_stream")

		resp := postChat(t, h, fullKey, `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

		if resp.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
		}
		if got := resp.Header().Get("X-Provider-Id"); got != peerID {
			t.Errorf("streaming X-Provider-Id = %q, want %q", got, peerID)
		}
		if got := resp.Header().Get("X-MacProvider-Provider"); got != "" {
			t.Errorf("streaming buyer response leaked internal X-MacProvider-Provider = %q", got)
		}
		if got := resp.Header().Get("X-MacProvider-Route"); got != "" {
			t.Errorf("streaming buyer response leaked X-MacProvider-Route = %q", got)
		}
		if got := resp.Header().Get("X-Provider-Assigned-Id"); got != "" {
			t.Errorf("streaming response surfaced X-Provider-Assigned-Id = %q", got)
		}
	})

	t.Run("provider-selected-error-attributed", func(t *testing.T) {
		// PR #250 R1 code MEDIUM: provider-SELECTED errors (null-usage
		// 5xx via passThroughReceiptEligibleProviderError) must also
		// surface attribution. Coord sets X-MacProvider-Provider on
		// selected-provider non-200 responses (phase4-coordinator
		// server.go:1886 + :1909) so B5/B6 can attribute per-Mac
		// failures, not just successes.
		client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			h := http.Header{}
			h.Set("Content-Type", "application/json")
			h.Set("X-MacProvider-Provider", peerID)
			h.Set("X-MacProvider-Route", routeToken)
			return responseWithBody(http.StatusBadGateway, h, `{"error":{"message":"model not loaded","type":"api_error","param":null,"code":"error_model_not_loaded"}}`), nil
		})}
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
			cfg.Coordinator.BuyerURL = "http://coordinator.test"
		}, WithHTTPClient(client))
		fullKey := createAccountAndKey(t, store, cfg, "acct_attr_provider_err")

		resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

		if resp.Code != http.StatusBadGateway {
			t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
		}
		if got := resp.Header().Get("X-Provider-Id"); got != peerID {
			t.Errorf("provider-selected error X-Provider-Id = %q, want %q", got, peerID)
		}
		if got := resp.Header().Get("X-MacProvider-Provider"); got != "" {
			t.Errorf("provider-selected error leaked internal X-MacProvider-Provider = %q", got)
		}
		if got := resp.Header().Get("X-MacProvider-Route"); got != "" {
			t.Errorf("provider-selected error leaked X-MacProvider-Route = %q", got)
		}
		if got := resp.Header().Get("X-Provider-Assigned-Id"); got != "" {
			t.Errorf("provider-selected error surfaced X-Provider-Assigned-Id = %q", got)
		}
	})

	t.Run("empty-source-suppresses-output", func(t *testing.T) {
		// Coord paths that don't carry provider attribution (policy
		// errors, cold-start 503s without a peer selected) must not
		// produce a sentinel `X-Provider-Id: ""` on the buyer
		// response.
		client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return responseWithBody(http.StatusOK, http.Header{
				"Content-Type": []string{"application/json"},
			}, `{"id":"chatcmpl","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
		})}
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
			cfg.Coordinator.BuyerURL = "http://coordinator.test"
		}, WithHTTPClient(client))
		fullKey := createAccountAndKey(t, store, cfg, "acct_attr_empty")

		resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

		if resp.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
		}
		if _, present := resp.Header()["X-Provider-Id"]; present {
			t.Errorf("X-Provider-Id must not be set when source is missing, got %q", resp.Header().Get("X-Provider-Id"))
		}
	})
}

func TestSPEC022GatewaySettlementOutcomeControlsBuyerDebit(t *testing.T) {
	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	successBody := `{"id":"chatcmpl","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`
	cases := []struct {
		name           string
		mode           string
		policyVersion  string
		omitPolicy     bool
		outcome        string
		receiptResult  string
		closed         string
		wantUsageRows  int64
		wantSettled    int64
		wantRefunded   int64
		wantActive     int64
		wantActiveHold int64
		wantExpiresAt  int64
	}{
		{
			name:          "legacy-no-header-debits",
			wantUsageRows: 1,
			wantSettled:   1,
		},
		{
			name:           "verified-closed-holds-for-reconcile",
			mode:           "enforce",
			outcome:        "verified",
			receiptResult:  "valid",
			closed:         "true",
			wantUsageRows:  0,
			wantActive:     1,
			wantActiveHold: promptCapTokens([]byte(body)) + 20,
			wantExpiresAt:  fixedNow().Add(settlementHoldFallbackTTL).UnixMilli(),
		},
		{
			name:          "quarantined-closed-refunds",
			mode:          "enforce",
			outcome:       "quarantined",
			receiptResult: "invalid",
			closed:        "true",
			wantRefunded:  1,
			wantUsageRows: 0,
		},
		{
			name:          "zero-settled-closed-refunds",
			mode:          "enforce",
			outcome:       "zero_settled",
			receiptResult: "valid",
			closed:        "true",
			wantRefunded:  1,
			wantUsageRows: 0,
		},
		{
			name:          "overlap-blocked-terminal-closed-refunds",
			mode:          "enforce",
			outcome:       "overlap_blocked_terminal",
			receiptResult: "valid",
			closed:        "true",
			wantRefunded:  1,
			wantUsageRows: 0,
		},
		{
			name:           "pending-without-deadline-holds-with-fallback-deadline",
			mode:           "enforce",
			outcome:        "pending",
			receiptResult:  "inconclusive",
			closed:         "false",
			wantUsageRows:  0,
			wantActive:     1,
			wantActiveHold: promptCapTokens([]byte(body)) + 20,
			wantExpiresAt:  fixedNow().Add(settlementHoldFallbackTTL).UnixMilli(),
		},
		{
			name:           "verified-open-without-deadline-holds-with-fallback-deadline",
			mode:           "enforce",
			outcome:        "verified",
			receiptResult:  "valid",
			closed:         "false",
			wantUsageRows:  0,
			wantActive:     1,
			wantActiveHold: promptCapTokens([]byte(body)) + 20,
			wantExpiresAt:  fixedNow().Add(settlementHoldFallbackTTL).UnixMilli(),
		},
		{
			name:           "verified-invalid-result-without-deadline-holds",
			mode:           "enforce",
			outcome:        "verified",
			receiptResult:  "invalid",
			closed:         "true",
			wantUsageRows:  0,
			wantActive:     1,
			wantActiveHold: promptCapTokens([]byte(body)) + 20,
			wantExpiresAt:  fixedNow().Add(settlementHoldFallbackTTL).UnixMilli(),
		},
		{
			name:          "observe-mode-keeps-legacy-debit",
			mode:          "observe",
			outcome:       "quarantined",
			receiptResult: "invalid",
			closed:        "true",
			wantUsageRows: 1,
			wantSettled:   1,
		},
		{
			name:           "partial-outcome-without-mode-holds",
			outcome:        "verified",
			receiptResult:  "valid",
			closed:         "true",
			wantUsageRows:  0,
			wantActive:     1,
			wantActiveHold: promptCapTokens([]byte(body)) + 20,
			wantExpiresAt:  fixedNow().Add(settlementHoldFallbackTTL).UnixMilli(),
		},
		{
			name:           "enforce-without-policy-version-holds",
			mode:           "enforce",
			omitPolicy:     true,
			outcome:        "verified",
			receiptResult:  "valid",
			closed:         "true",
			wantUsageRows:  0,
			wantActive:     1,
			wantActiveHold: promptCapTokens([]byte(body)) + 20,
			wantExpiresAt:  fixedNow().Add(settlementHoldFallbackTTL).UnixMilli(),
		},
		{
			name:           "enforce-with-unknown-policy-version-holds",
			mode:           "enforce",
			policyVersion:  "unknown-policy",
			outcome:        "verified",
			receiptResult:  "valid",
			closed:         "true",
			wantUsageRows:  0,
			wantActive:     1,
			wantActiveHold: promptCapTokens([]byte(body)) + 20,
			wantExpiresAt:  fixedNow().Add(settlementHoldFallbackTTL).UnixMilli(),
		},
		{
			name:           "unknown-mode-holds",
			mode:           "monitor",
			outcome:        "verified",
			receiptResult:  "valid",
			closed:         "true",
			wantUsageRows:  0,
			wantActive:     1,
			wantActiveHold: promptCapTokens([]byte(body)) + 20,
			wantExpiresAt:  fixedNow().Add(settlementHoldFallbackTTL).UnixMilli(),
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				h := http.Header{}
				h.Set("Content-Type", "application/json")
				if tc.outcome != "" {
					h.Set(settlementModeHeader, tc.mode)
					policyVersion := tc.policyVersion
					if policyVersion == "" {
						policyVersion = settlementPolicyVersion
					}
					if !tc.omitPolicy {
						h.Set(settlementPolicyVersionHeader, policyVersion)
					}
					h.Set(settlementOutcomeHeader, tc.outcome)
					h.Set(settlementClosedHeader, tc.closed)
					h.Set(settlementReceiptResultHeader, tc.receiptResult)
					h.Set(settlementReasonHeader, "test_"+tc.outcome)
				}
				return responseWithBody(http.StatusOK, h, successBody), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			accountID := "acct_spec022_finality_" + strings.ReplaceAll(tc.name, "-", "_")
			fullKey := createAccountAndKey(t, store, cfg, accountID)

			resp := postChat(t, h, fullKey, body, nil)
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			for _, header := range []string{settlementOutcomeHeader, settlementClosedHeader, settlementReceiptResultHeader, settlementReasonHeader, settlementModeHeader, settlementPolicyVersionHeader, settlementPendingUntilHeader} {
				if got := resp.Header().Get(header); got != "" {
					t.Fatalf("buyer response leaked internal settlement header %s=%q", header, got)
				}
			}
			got := gatewaySettlementSnapshot(t, dbPath, accountID)
			if got.usageRows != tc.wantUsageRows || got.settledRows != tc.wantSettled || got.refundedRows != tc.wantRefunded || got.activeRows != tc.wantActive || got.activeReserved != tc.wantActiveHold {
				t.Fatalf("settlement snapshot = %+v, want usage=%d settled=%d refunded=%d active=%d active_reserved=%d",
					got, tc.wantUsageRows, tc.wantSettled, tc.wantRefunded, tc.wantActive, tc.wantActiveHold)
			}
			if tc.wantExpiresAt > 0 {
				if got := gatewayReservationExpiresAtUnixMS(t, dbPath, accountID); got != tc.wantExpiresAt {
					t.Fatalf("reservation expires_at=%d want fallback hold deadline %d", got, tc.wantExpiresAt)
				}
			}
		})
	}
}

func TestSPEC022GatewayProviderErrorFinalityHoldsBuyerDebit(t *testing.T) {
	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	pendingDeadline := fixedNow().Add(5 * time.Minute)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		h := http.Header{}
		h.Set("Content-Type", "application/json")
		h.Set(settlementModeHeader, "enforce")
		h.Set(settlementPolicyVersionHeader, settlementPolicyVersion)
		h.Set(settlementOutcomeHeader, "pending")
		h.Set(settlementReceiptResultHeader, "inconclusive")
		h.Set(settlementReasonHeader, "missing_receipt_deadline_open")
		h.Set(settlementClosedHeader, "false")
		h.Set(settlementPendingUntilHeader, strconv.FormatInt(pendingDeadline.UnixMilli(), 10))
		return responseWithBody(http.StatusGatewayTimeout, h, `{"error":{"message":"timeout","type":"api_error","param":null,"code":"provider_timeout"}}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_spec022_provider_error_pending"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)
	if resp.Code != http.StatusGatewayTimeout {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.usageRows != 0 || got.settledRows != 0 || got.refundedRows != 0 || got.activeRows != 1 || got.activeReserved != promptCapTokens([]byte(body))+20 {
		t.Fatalf("settlement snapshot = %+v, want pending provider error to hold reservation without debit", got)
	}
	holds, err := store.ListSettlementHeldReservations(context.Background(), 10)
	if err != nil {
		t.Fatalf("ListSettlementHeldReservations: %v", err)
	}
	if len(holds) != 1 || holds[0].AccountID != accountID {
		t.Fatalf("settlement holds=%#v want one visible hold for %s", holds, accountID)
	}
	if got := holds[0].ExpiresAt.UnixMilli(); got != pendingDeadline.UnixMilli() {
		t.Fatalf("held reservation expires_at_unix_ms=%d want %d", got, pendingDeadline.UnixMilli())
	}
}

func TestSPEC022GatewayVerifiedProviderErrorFinalityHoldsForReconcile(t *testing.T) {
	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		h := http.Header{}
		h.Set("Content-Type", "application/json")
		h.Set(settlementModeHeader, "enforce")
		h.Set(settlementPolicyVersionHeader, settlementPolicyVersion)
		h.Set(settlementOutcomeHeader, "verified")
		h.Set(settlementReceiptResultHeader, "valid")
		h.Set(settlementReasonHeader, "verified_provider_error")
		h.Set(settlementClosedHeader, "true")
		return responseWithBody(http.StatusBadGateway, h, `{"error":{"message":"upstream failed","type":"api_error","param":null,"code":"provider_error"}}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_spec022_provider_error_verified"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.usageRows != 0 || got.settledRows != 0 || got.refundedRows != 0 || got.activeRows != 1 || got.activeReserved != promptCapTokens([]byte(body))+20 {
		t.Fatalf("settlement snapshot = %+v, want verified provider error to hold reservation for reconciler", got)
	}
	if got := gatewayReservationExpiresAtUnixMS(t, dbPath, accountID); got != fixedNow().Add(settlementHoldFallbackTTL).UnixMilli() {
		t.Fatalf("reservation expires_at=%d want fallback hold deadline %d", got, fixedNow().Add(settlementHoldFallbackTTL).UnixMilli())
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
	req.Header.Set("X-MacProvider-Retry", "1")
	req.Header.Set("X-MacProvider-Foo", "attacker")
	req.Header.Set("X-Request-ID", "55555555-5555-4555-8555-555555555555")
	req.Header.Set("Idempotency-Key", "idem-gateway-1")
	req.Header.Set("Cookie", "session=secret")
	req.Header.Set("Proxy-Authorization", "Basic secret")
	req.Header.Set("X-Custom-Control", "attacker")
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
	// SPEC-002 §11 + v1.4.2 R-2 + issue #188: the gateway MUST forward
	// the buyer-supplied X-Request-ID verbatim so the coordinator can
	// store it in request_log.external_request_id, giving out-of-process
	// auditors a stable shared id between gateway usage_events and
	// coordinator request_log. Earlier behavior minted a fresh UUID
	// here, breaking that join.
	if got := captured.Get("X-Request-ID"); got != "55555555-5555-4555-8555-555555555555" {
		t.Fatalf("forwarded X-Request-ID = %q, want buyer-supplied value preserved", got)
	}
	// SPEC-006 v0.9.1 + SPEC-002 v1.5.0 + issue #211: the gateway MUST
	// forward X-MacProvider-Account on EVERY forwarded buyer request
	// (not just the sticky-routing conditional path). The composite
	// (account_id, external_request_id) is the reconciliation key
	// joining gateway usage_events to coordinator request_log; without
	// the header on the hot non-sticky path the coordinator could not
	// attribute the row to the gateway account, reopening the
	// cross-account request_id-collision class on the coordinator
	// audit-trail side. This test exercises the non-sticky bearer path.
	if got := captured.Get("X-MacProvider-Account"); got != "acct_strip_success" {
		t.Fatalf("forwarded X-MacProvider-Account = %q, want %q (issue #211: non-sticky hot path must forward account id)", got, "acct_strip_success")
	}
	if got := captured.Get("X-MacProvider-Retry"); got != "1" {
		t.Fatalf("forwarded retry = %q, want 1", got)
	}
	if got := captured.Get("Idempotency-Key"); got != "idem-gateway-1" {
		t.Fatalf("forwarded idempotency key = %q, want idem-gateway-1", got)
	}
	if got := captured.Get("X-MacProvider-Foo"); got != "" {
		t.Fatalf("forwarded unknown MacProvider header = %q", got)
	}
	for _, header := range []string{"Cookie", "Proxy-Authorization"} {
		if got := captured.Get(header); got != "" {
			t.Fatalf("forwarded credential header %s=%q", header, got)
		}
	}
	if got := captured.Get("X-Custom-Control"); got != "" {
		t.Fatalf("forwarded non-allowlisted header = %q", got)
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

// SPEC-006 v0.X R-G3: gateway forwards buyer X-Request-ID on every
// buyer-facing coordinator proxy path, not only /v1/chat/completions.
// /v1/models is the other buyer-facing surface; this test pins that
// behavior so a refactor doesn't silently revert it to newUUID().
func TestModelsForwardsBuyerRequestID(t *testing.T) {
	var capturedModelsXRequestID string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/v1/models" {
			capturedModelsXRequestID = r.Header.Get("X-Request-ID")
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"object":"list","data":[]}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_models_xrequestid")

	const buyerID = "66666666-6666-4666-8666-666666666666"
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("X-Real-IP", "1.2.3.4")
	req.Header.Set("X-Request-ID", buyerID)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("models status=%d body=%s", resp.Code, resp.Body.String())
	}
	if capturedModelsXRequestID != buyerID {
		t.Fatalf("forwarded X-Request-ID on /v1/models = %q, want buyer-supplied %q", capturedModelsXRequestID, buyerID)
	}
}

// SPEC-006 v0.X R-G3 / SPEC-002 v1.4.2 R-2: when the buyer omits
// X-Request-ID, gateway middleware mints a UUID, sets it as the
// response header, AND forwards that SAME id upstream. The two MUST
// agree so the buyer can correlate their request id with what reaches
// the coordinator's request_log.external_request_id. R5 architect
// audit MINOR: previous tests only covered buyer-supplied; this pins
// the middleware-minted branch.
func TestChatForwardsMiddlewareMintedRequestIDWhenBuyerOmits(t *testing.T) {
	var capturedChatXRequestID string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/v1/chat/completions" {
			capturedChatXRequestID = r.Header.Get("X-Request-ID")
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}},
			`{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_minted_rid")

	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	// No X-Request-ID header: gateway middleware MUST mint one.
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	respID := resp.Header().Get("X-Request-ID")
	if !isUUIDLike(respID) {
		t.Fatalf("response X-Request-ID = %q, want middleware-minted UUID", respID)
	}
	if capturedChatXRequestID != respID {
		t.Fatalf("forwarded X-Request-ID = %q, want response/middleware-minted %q", capturedChatXRequestID, respID)
	}
}

func TestNoProvider503EchoesOnlyGatewayRequestID(t *testing.T) {
	cases := []struct {
		name      string
		coordBody string
	}{
		{
			name:      "coordinator_body",
			coordBody: `{"error":{"code":"no_provider_available","message":"No provider available","param":null,"type":"service_unavailable"}}`,
		},
		{
			name:      "empty_body",
			coordBody: "",
		},
	}
	for _, tc := range cases {
		for _, stream := range []bool{false, true} {
			name := tc.name + "_non_stream"
			if stream {
				name = tc.name + "_stream"
			}
			t.Run(name, func(t *testing.T) {
				client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
					return responseWithBody(http.StatusServiceUnavailable, http.Header{
						"Content-Type": []string{"application/json"},
						"X-Request-ID": []string{"99999999-9999-4999-8999-999999999999"},
					}, tc.coordBody), nil
				})}
				h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
					cfg.Coordinator.BuyerURL = "http://coordinator.test"
				}, WithHTTPClient(client))
				fullKey := createAccountAndKey(t, store, cfg, "acct_no_provider_request_id_"+name)

				requestID := "88888888-8888-4888-8888-888888888888"
				body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
				if stream {
					body = `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
				}
				resp := postChat(t, h, fullKey, body, map[string]string{"X-Request-ID": requestID})

				if resp.Code != http.StatusServiceUnavailable {
					t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
				}
				values := resp.Header().Values("X-Request-ID")
				if len(values) != 1 || values[0] != requestID {
					t.Fatalf("response X-Request-ID values=%q, want only gateway request id %q", values, requestID)
				}
			})
		}
	}
}

func TestReceiptEligible5xxEchoesOnlyGatewayRequestID(t *testing.T) {
	cases := []struct {
		name   string
		status int
	}{
		{name: "capacity_503", status: http.StatusServiceUnavailable},
		{name: "upstream_502", status: http.StatusBadGateway},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := `{"error":{"code":"error_model_not_loaded","message":"model not loaded","param":null,"type":"api_error"}}`
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return responseWithBody(tc.status, http.Header{
					"Content-Type": []string{"application/json"},
					"X-Request-ID": []string{"99999999-9999-4999-8999-999999999999"},
				}, body), nil
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			fullKey := createAccountAndKey(t, store, cfg, "acct_receipt_eligible_request_id_"+tc.name)

			requestID := "77777777-7777-4777-8777-777777777777"
			resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, map[string]string{"X-Request-ID": requestID})

			if resp.Code != tc.status {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			values := resp.Header().Values("X-Request-ID")
			if len(values) != 1 || values[0] != requestID {
				t.Fatalf("response X-Request-ID values=%q, want only gateway request id %q", values, requestID)
			}
		})
	}
}

func TestStickyConversationDerivesInternalHeaderAndStripsInjection(t *testing.T) {
	var captured http.Header
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/internal/routing" {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"sticky":{"enabled":true,"ttl_seconds":1800}}`), nil
		}
		captured = r.Header.Clone()
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
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
	if want := expectedConversationKey("test-key-hash-secret", "acct_sticky", "thread-1"); got != want {
		t.Fatalf("internal conversation key = %q, want %q", got, want)
	}
	if got := captured.Get("X-MacProvider-Internal-Source"); got != "" {
		t.Fatalf("internal source forwarded = %q", got)
	}
	if got := captured.Get("Authorization"); got != "Bearer service-token" {
		t.Fatalf("coordinator authorization = %q", got)
	}
	if countAuditEvents(t, dbPath, "internal_header_injection_stripped") != 1 {
		t.Fatalf("internal header injection audit missing")
	}
}

func TestChatCompletionRejectsOversizedCoordinatorBody(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, string(bytes.Repeat([]byte("x"), 16<<20+1))), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_oversized_body")

	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "upstream_provider_error")
}

func TestStickyConversationIgnoredForDemoTraffic(t *testing.T) {
	var captured http.Header
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		captured = r.Header.Clone()
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Routing.StickyEnabled = true
	}, WithHTTPClient(client))
	demo := issueDemoToken(t, h, "1.2.3.4")

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("X-Demo-Token", demo)
	req.Header.Set("X-Real-IP", "1.2.3.4")
	req.Header.Set("X-MacProvider-Conversation", "thread-1")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	// SPEC-006 v0.9.1 / issue #211: sticky's distinguishing header is
	// X-MacProvider-Internal-Conv; it MUST remain suppressed on demo
	// traffic. That's the test's name and core intent.
	if got := captured.Get("X-MacProvider-Internal-Conv"); got != "" {
		t.Fatalf("demo internal conversation forwarded: %q", got)
	}
	// SPEC-006 v0.9.1 / issue #211: X-MacProvider-Account is now
	// forwarded unconditionally (including for demo subjects) so
	// coordinator request_log.account_id can hold "demo:<ip>" and
	// the reconciliation key (account_id, external_request_id) is
	// well-defined for demo rows too. The coordinator gates the
	// header behind the upstream Authorization bearer
	// (hasInternalRoutingHeader / internalBearerAuthorized in
	// phase4-coordinator/internal/buyer/server.go), so the bearer
	// is also now sent on every forward — including demo. This is
	// a SPEC-006 v0.9.1 contract change relative to pre-v0.9.1
	// behavior where Authorization was sticky-gated. Sticky-only
	// state (X-MacProvider-Internal-Conv) is still suppressed for
	// demo; that's what this test's name still guards.
	if got := captured.Get("X-MacProvider-Account"); got != "demo:1.2.3.4" {
		t.Fatalf("demo account header = %q, want %q", got, "demo:1.2.3.4")
	}
	if got := captured.Get("Authorization"); got == "" {
		t.Fatalf("demo coordinator Authorization missing — SPEC-006 v0.9.1 / issue #211 requires it whenever X-MacProvider-Account is forwarded")
	}
	if got := captured.Get("X-Demo-Token"); got != "" {
		t.Fatalf("demo token forwarded: %q", got)
	}
}

func TestStickyDeleteRequiresBearerAndAuthorizesCoordinator(t *testing.T) {
	var captured *http.Request
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		captured = r
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"purged":true,"entries":2}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Routing.StickyEnabled = true
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_sticky_delete")

	req := httptest.NewRequest(http.MethodDelete, "/v1/sticky", nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("missing bearer status=%d body=%s", resp.Code, resp.Body.String())
	}

	req = httptest.NewRequest(http.MethodDelete, "/v1/sticky", nil)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if captured == nil {
		t.Fatal("coordinator request not captured")
	}
	if got := captured.URL.Query().Get("account_id"); got != "acct_sticky_delete" {
		t.Fatalf("account_id = %q", got)
	}
	if got := captured.URL.Scheme + "://" + captured.URL.Host; got != "http://operator.test" {
		t.Fatalf("coordinator sticky URL host = %q", got)
	}
	if got := captured.Header.Get("Authorization"); got != "Bearer service-token" {
		t.Fatalf("coordinator authorization = %q", got)
	}
}

func expectedConversationKey(secret, accountID, tag string) string {
	const scope = "spec006-v0.8-sticky-conversation-v1"
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(scope + "\n" + accountID + "\n" + tag))
	return "conv:" + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
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

func TestNonStreamingRejectsInvalidProviderUsage(t *testing.T) {
	for _, tc := range []struct {
		name         string
		responseBody string
	}{
		{name: "negative", responseBody: `{"id":"chatcmpl_bad_usage","usage":{"prompt_tokens":-1,"completion_tokens":2,"total_tokens":1}}`},
		{name: "empty_object", responseBody: `{"id":"chatcmpl_bad_usage","usage":{}}`},
		{name: "missing_completion", responseBody: `{"id":"chatcmpl_bad_usage","usage":{"prompt_tokens":1}}`},
		{name: "malformed_field", responseBody: `{"id":"chatcmpl_bad_usage","usage":{"prompt_tokens":"1","completion_tokens":2}}`},
		{name: "exceeds_request_bound", responseBody: `{"id":"chatcmpl_bad_usage","usage":{"prompt_tokens":1,"completion_tokens":10000,"total_tokens":10001}}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"invalid usage"}]}`
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, tc.responseBody), nil
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			fullKey := createAccountAndKey(t, store, cfg, "acct_invalid_usage_"+tc.name)

			resp := postChat(t, h, fullKey, body, nil)

			if resp.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "invalid_provider_usage")
			usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
			quota := readQuota(t, usageResp)
			wantUsed := float64(estimatePromptTokens([]byte(body)))
			if quota["daily_tokens_used"].(float64) != wantUsed {
				t.Fatalf("daily_tokens_used=%v want prompt estimate %v", quota["daily_tokens_used"], wantUsed)
			}
			if quota["daily_tokens_reserved"].(float64) != 0 {
				t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
			}
		})
	}
}

func TestNonStreamingSanitizesInvalidCachedPromptTokensWithoutRejectingUsage(t *testing.T) {
	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"invalid cache"}]}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		responseBody := `{"id":"chatcmpl_cache","usage":{"prompt_tokens":3,"cached_prompt_tokens":4,"completion_tokens":2,"total_tokens":5},"choices":[{"message":{"content":"ok"}}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, responseBody), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_invalid_cache_nonstream")

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"cached_prompt_tokens":0`) {
		t.Fatalf("response did not sanitize cached_prompt_tokens: %s", resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_invalid_cache_nonstream")
	if outcome != "ok" || source != "provider_reported" || prompt != 3 || completion != 2 {
		t.Fatalf("usage event outcome/source/prompt/completion = %s/%s/%d/%d, want ok/provider_reported/3/2", outcome, source, prompt, completion)
	}
}

// TestNonStreamingOverCapUsageClampsInsteadOfRejecting is the non-streaming
// analog of the over-cap clamp fix (2026-07-09 canary-probe finding): a prompt
// whose provider-reported tokens exceed the reservation cap (completion within
// max_tokens) settles provider_reported bounded to the cap, and the buyer still
// receives the provider's actual usage counts — instead of a rejection.
func TestNonStreamingOverCapUsageClampsInsteadOfRejecting(t *testing.T) {
	body := `{"model":"llama","max_tokens":5,"messages":[{"role":"user","content":"ok"}]}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		responseBody := `{"id":"chatcmpl_overcap","usage":{"prompt_tokens":200,"completion_tokens":1,"total_tokens":201},"choices":[{"message":{"content":"ok"}}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, responseBody), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_overcap_nonstream")

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	// Visibility: buyer sees the provider's actual prompt count, not a rejection.
	if !strings.Contains(resp.Body.String(), `"prompt_tokens":200`) {
		t.Fatalf("over-cap usage was not forwarded to buyer: %s", resp.Body.String())
	}
	capTokens := promptCapTokens([]byte(body)) + 5
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_overcap_nonstream")
	if outcome != "ok" || source != "provider_reported" || completion != 1 || prompt != capTokens-1 {
		t.Fatalf("usage event outcome/source/prompt/completion = %s/%s/%d/%d, want ok/provider_reported/%d/1 (bounded to cap=%d)", outcome, source, prompt, completion, capTokens-1, capTokens)
	}
}

func TestNonStreamingSynthesizesCompleteUsageWhenProviderUsageAbsent(t *testing.T) {
	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"legacy usage"}]}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		responseBody := `{"id":"chatcmpl_legacy","choices":[{"message":{"content":"ok"}}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, responseBody), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_absent_usage_nonstream")

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	var out struct {
		Usage tokenUsage `json:"usage"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	wantPrompt := estimatePromptTokens([]byte(body))
	if out.Usage.PromptTokens != wantPrompt || out.Usage.CachedPromptTokens != 0 || out.Usage.CompletionTokens != 0 || out.Usage.TotalTokens != wantPrompt {
		t.Fatalf("usage=%+v, want complete gateway-estimated prompt=%d cached=0 completion=0 total=%d", out.Usage, wantPrompt, wantPrompt)
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, "acct_absent_usage_nonstream")
	if outcome != "ok" || source != "gateway_estimated" || prompt != wantPrompt || completion != 0 {
		t.Fatalf("usage event outcome/source/prompt/completion = %s/%s/%d/%d, want ok/gateway_estimated/%d/0", outcome, source, prompt, completion, wantPrompt)
	}
}

func TestNonStreamingSettlementFailureDoesNotReturnSuccess(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"id":"chatcmpl_ok","usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}`), nil
	})}
	_, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_settle_fail")
	fakeStore := &settlementFailStore{Store: store, settleErr: errors.New("forced settlement failure")}
	h := New(cfg, fakeStore, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client)).Handler()

	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusInternalServerError {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "settlement_failed")
	if fakeStore.refundCalls != 1 {
		t.Fatalf("RefundReservation calls=%d, want 1", fakeStore.refundCalls)
	}
}

func TestUsageFromJSONValidatesProviderReportedUsage(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
	}{
		{name: "negative", body: `{"usage":{"prompt_tokens":-1,"completion_tokens":2,"total_tokens":1}}`},
		{name: "empty_object", body: `{"usage":{}}`},
		{name: "missing_completion", body: `{"usage":{"prompt_tokens":1}}`},
		{name: "malformed_field", body: `{"usage":{"prompt_tokens":"1","completion_tokens":2}}`},
		{name: "overflow", body: `{"usage":{"prompt_tokens":9223372036854775807,"completion_tokens":1}}`},
		{name: "inconsistent_total", body: `{"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":4}}`},
		{name: "explicit_zero_total_mismatch", body: `{"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":0}}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, ok, err := usageFromJSON([]byte(tc.body), 10, 10); !ok || err == nil {
				t.Fatalf("usageFromJSON ok=%v err=%v, want provider usage validation error", ok, err)
			}
		})
	}
	usage, ok, err := usageFromJSON([]byte(`{"usage":{"prompt_tokens":1,"completion_tokens":2}}`), 10, 10)
	if err != nil || !ok || usage.TotalTokens != 3 || usage.CachedPromptTokens != 0 {
		t.Fatalf("valid usage = %#v ok=%v err=%v, want total 3 and cached 0", usage, ok, err)
	}
	usage, ok, err = usageFromJSON([]byte(`{"usage":{"prompt_tokens":10,"cached_prompt_tokens":4,"completion_tokens":2}}`), 20, 10)
	if err != nil || !ok || usage.CachedPromptTokens != 4 || usage.TotalTokens != 12 {
		t.Fatalf("valid cached usage = %#v ok=%v err=%v, want cached 4 total 12", usage, ok, err)
	}
	for _, tc := range []struct {
		name string
		body string
	}{
		{name: "negative", body: `{"usage":{"prompt_tokens":3,"cached_prompt_tokens":-1,"completion_tokens":2}}`},
		{name: "above_prompt", body: `{"usage":{"prompt_tokens":3,"cached_prompt_tokens":4,"completion_tokens":2}}`},
		{name: "string", body: `{"usage":{"prompt_tokens":3,"cached_prompt_tokens":"1","completion_tokens":2}}`},
		{name: "float", body: `{"usage":{"prompt_tokens":3,"cached_prompt_tokens":1.5,"completion_tokens":2}}`},
		{name: "object", body: `{"usage":{"prompt_tokens":3,"cached_prompt_tokens":{"n":1},"completion_tokens":2}}`},
		{name: "null", body: `{"usage":{"prompt_tokens":3,"cached_prompt_tokens":null,"completion_tokens":2}}`},
	} {
		t.Run("sanitizes_cache_"+tc.name, func(t *testing.T) {
			usage, ok, err := usageFromJSON([]byte(tc.body), 20, 10)
			if err != nil || !ok {
				t.Fatalf("usageFromJSON ok=%v err=%v, want valid provider usage with sanitized cache", ok, err)
			}
			if usage.PromptTokens != 3 || usage.CompletionTokens != 2 || usage.TotalTokens != 5 || usage.CachedPromptTokens != 0 {
				t.Fatalf("usage=%#v, want prompt=3 completion=2 total=5 cached=0", usage)
			}
		})
	}
	if _, ok, err := usageFromJSON([]byte(`{"usage":null}`), 10, 10); ok || err != nil {
		t.Fatalf("usage null ok=%v err=%v, want absent usage", ok, err)
	}
	// Over-cap usage is CLAMPED to the reservation cap (mirrors the coordinator's
	// bounded charge), not rejected — so the buyer keeps a provider_reported
	// usage frame instead of losing usage and being billed on gateway_estimated.
	// Regression for the 2026-07-09 canary-probe finding.
	clamped, ok, err := usageFromJSON([]byte(`{"usage":{"prompt_tokens":1,"completion_tokens":10,"total_tokens":11}}`), 10, 10)
	if err != nil || !ok {
		t.Fatalf("over-cap usage ok=%v err=%v, want clamped accept", ok, err)
	}
	if clamped.PromptTokens != 0 || clamped.CompletionTokens != 10 || clamped.TotalTokens != 10 {
		t.Fatalf("over-cap clamp = %#v, want prompt=0 completion=10 total=10 (bounded to cap=10)", clamped)
	}
}

func TestUsageBodyWithTokenUsageAddsBuyerVisibleField(t *testing.T) {
	body := []byte(`{"id":"cmpl","usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}`)
	updated := usageBodyWithTokenUsage(body, tokenUsage{PromptTokens: 10, CachedPromptTokens: 4, CompletionTokens: 2, TotalTokens: 12})
	var out struct {
		Usage tokenUsage `json:"usage"`
	}
	if err := json.Unmarshal(updated, &out); err != nil {
		t.Fatal(err)
	}
	if out.Usage.CachedPromptTokens != 4 || out.Usage.TotalTokens != 12 {
		t.Fatalf("updated usage = %+v, want cached 4 and total 12", out.Usage)
	}
}

func TestUsageBodyWithTokenUsageSynthesizesCompleteUsageWhenAbsent(t *testing.T) {
	body := []byte(`{"id":"cmpl","choices":[{"message":{"content":"ok"}}]}`)
	updated := usageBodyWithTokenUsage(body, tokenUsage{PromptTokens: 7, CachedPromptTokens: 0, CompletionTokens: 3, TotalTokens: 10})
	var out struct {
		Usage tokenUsage `json:"usage"`
	}
	if err := json.Unmarshal(updated, &out); err != nil {
		t.Fatal(err)
	}
	if out.Usage.PromptTokens != 7 || out.Usage.CachedPromptTokens != 0 || out.Usage.CompletionTokens != 3 || out.Usage.TotalTokens != 10 {
		t.Fatalf("updated usage = %+v, want complete synthesized usage with cached_prompt_tokens=0", out.Usage)
	}
}

// TestEstimatePromptTokensHeadroomCoversAir5 regresses the 2026-06-28
// phase-A re-run finding where a 115-byte body + max_tokens=4 produced
// a cap of 33, but mlx-community/Qwen2.5-Coder-7B-Instruct-4bit's
// tokenizer reported prompt=30 + completion=4 = 34, tripping the
// usageFromJSON cap as invalid_provider_usage even though the
// provider's response was correct. The fix adds
// promptHeadroomTokens (= 64) padding to the byte-heuristic so a
// 1-token discrepancy between heuristic and actual tokenizer no
// longer breaks chat completions with small max_tokens.
func TestEstimatePromptTokensHeadroomCoversAir5(t *testing.T) {
	body := []byte(`{"model":"mlx-community/Qwen2.5-Coder-7B-Instruct-4bit","max_tokens":4,"messages":[{"role":"user","content":"hi"}]}`)
	maxTokens := int64(4)
	// Cap uses promptCapTokens (with chat-template headroom). Billing
	// paths use bare estimatePromptTokens — see chat_proxy.go split.
	maxUsageTokens := promptCapTokens(body) + maxTokens
	// Provider's actual tokenization for this body.
	providerUsage := []byte(`{"usage":{"prompt_tokens":30,"completion_tokens":4,"total_tokens":34}}`)
	usage, ok, err := usageFromJSON(providerUsage, maxUsageTokens, maxTokens)
	if !ok || err != nil {
		t.Fatalf("usageFromJSON ok=%v err=%v, want clean accept of provider tokenization within headroom (cap=%d, sum=34)", ok, err, maxUsageTokens)
	}
	if usage.PromptTokens != 30 || usage.CompletionTokens != 4 || usage.TotalTokens != 34 {
		t.Fatalf("usage=%#v, want prompt=30 completion=4 total=34", usage)
	}

	// Sanity: a malicious provider reporting prompt=10000 for the same
	// body must STILL be bounded to the buyer's reservation. The clamp caps
	// the settled total at maxUsageTokens (mirrors the coordinator's bounded
	// charge) instead of dropping usage — the over-billing defense holds; the
	// buyer just keeps a bounded provider_reported usage frame rather than
	// losing usage and being billed on gateway_estimated.
	abusiveUsage := []byte(`{"usage":{"prompt_tokens":10000,"completion_tokens":1,"total_tokens":10001}}`)
	clampedAbusive, ok, err := usageFromJSON(abusiveUsage, maxUsageTokens, maxTokens)
	if err != nil || !ok {
		t.Fatalf("abusive over-cap usage ok=%v err=%v, want clamped accept", ok, err)
	}
	if clampedAbusive.TotalTokens != maxUsageTokens || clampedAbusive.CompletionTokens != 1 || clampedAbusive.PromptTokens != maxUsageTokens-1 {
		t.Fatalf("abusive clamp = %#v, want total=%d completion=1 prompt=%d (bounded to cap)", clampedAbusive, maxUsageTokens, maxUsageTokens-1)
	}

	// R1 CODE HIGH #1: a malicious provider must NOT be able to spend
	// the prompt-cap headroom as inflated completion_tokens. Buyer
	// asked for max_tokens=4; provider reporting completion=68 (well
	// under maxUsageTokens=97 thanks to the +64 prompt headroom)
	// would over-bill the buyer 17× the requested max. Must reject
	// on the explicit completion check.
	inflatedCompletion := []byte(`{"usage":{"prompt_tokens":10,"completion_tokens":68,"total_tokens":78}}`)
	if _, _, err := usageFromJSON(inflatedCompletion, maxUsageTokens, maxTokens); err == nil {
		t.Fatalf("expected rejection of completion=68 when max_tokens=4 (sum=78 within maxUsageTokens=%d but completion exceeds max)", maxUsageTokens)
	}
}

func TestQuotaAdmissionUsesPromptCapExposure(t *testing.T) {
	body := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	var called bool
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		called = true
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"id":"chatcmpl","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Quotas.AccountDailyTokens = estimatePromptTokens([]byte(body)) + 20
		cfg.Limits.MaxTokensPerRequest = 20
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_prompt_cap_quota")

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d body=%s, want quota rejection before coordinator", resp.Code, resp.Body.String())
	}
	if called {
		t.Fatal("coordinator was called even though prompt-cap reservation exceeded quota")
	}
}

// TestCompletionFromHeaderCapsAtMaxTokens — R2 CODE HIGH: the
// X-MacProvider-Completion-Tokens header path is used on the
// upstream-error settlement paths. With the +64 prompt-cap
// headroom, a malicious upstream could send a header value above
// max_tokens and over-bill the buyer through the gateway-estimated
// fallback. The completionFromHeaderCapped wrapper clamps to
// maxTokens, mirroring the JSON-usage maxCompletion check.
func TestCompletionFromHeaderCapsAtMaxTokens(t *testing.T) {
	header := http.Header{}
	header.Set("X-MacProvider-Completion-Tokens", "68")
	if got := completionFromHeaderCapped(header, 4); got != 4 {
		t.Fatalf("completionFromHeaderCapped clamped=%d, want 4 (max_tokens cap)", got)
	}
	if got := completionFromHeaderCapped(header, 100); got != 68 {
		t.Fatalf("completionFromHeaderCapped under cap=%d, want 68 (pass-through)", got)
	}
	emptyHeader := http.Header{}
	if got := completionFromHeaderCapped(emptyHeader, 4); got != 0 {
		t.Fatalf("completionFromHeaderCapped no-header=%d, want 0", got)
	}
}

type settlementFailStore struct {
	*sqlite.Store
	settleErr   error
	refundCalls int
}

func (f *settlementFailStore) SettleReservation(context.Context, storage.ReservationSettlement) error {
	return f.settleErr
}

func (f *settlementFailStore) RefundReservation(context.Context, string, string, int64) error {
	f.refundCalls++
	return nil
}

// hangingCoordinatorClient answers every upstream request by blocking until
// the request context is cancelled — i.e. a coordinator that accepts the
// connection and never commits response headers.
func hangingCoordinatorClient() *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
}

// #760 split TestChatCompletionsCoordinatorTimeoutAppliesToStreamAndNonStream:
// the two modes no longer share one clock, so one test per clock.
//
// STREAMING: a coordinator that accepts the connection and never commits
// headers is bounded by the admission phase. The streaming ceiling is left at
// its (much longer) default so the only clock that can end this request is
// admission.
//
// The admission phase deliberately does NOT bound the non-streaming path: the
// coordinator buffers a non-streaming response in full, so its headers do not
// commit until provider work completes and a 120s admission budget would
// false-fail a legitimate slow inference. That path keeps its flat wall —
// TestNonStreamingStillBoundedByRequestWall below.
func TestChatCompletionsAdmissionDeadlineFailsFastPreHeader(t *testing.T) {
	client := hangingCoordinatorClient()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.CoordinatorAdmissionSeconds = 1
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_admission_stream")

	start := time.Now()
	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}],"stream":true}`, nil)
	elapsed := time.Since(start)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if elapsed > 2500*time.Millisecond {
		t.Fatalf("elapsed=%s, want <=2.5s (coordinator_admission_seconds=1)", elapsed)
	}
	assertErrorCode(t, resp.Body.String(), "coordinator_unavailable")
}

// TestNonStreamingStillBoundedByRequestWall pins the non-streaming path to its
// own flat wall. The admission budget is deliberately long here so the ONLY
// clock that can end the request is non_stream_request_seconds — if a future
// change routes non-streaming through the (much longer) streaming ceiling or
// drops its wall entirely, this test stops returning in ~1s.
func TestNonStreamingStillBoundedByRequestWall(t *testing.T) {
	client := hangingCoordinatorClient()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.NonStreamRequestSeconds = 1
		cfg.Timeouts.CoordinatorAdmissionSeconds = 600
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_non_stream_wall")

	start := time.Now()
	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}],"stream":false}`, nil)
	elapsed := time.Since(start)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if elapsed > 2500*time.Millisecond {
		t.Fatalf("elapsed=%s, want <=2.5s (non_stream_request_seconds=1)", elapsed)
	}
	assertErrorCode(t, resp.Body.String(), "coordinator_unavailable")
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

// Pre-fix diagnostic captured by fix-stash-test:
// server_test.go:1113: RefundReservation calls=0, want 1 after committed reservation/cancel race
func TestQuotaReservationLeakOnContextCancel(t *testing.T) {
	_, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(noopClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_reserve_cancel")
	ctx, cancel := context.WithCancel(context.Background())
	reservationInserted := false
	fakeStore := &quotaReserveFakeStore{
		Store: store,
		decision: storage.QuotaDecision{
			Admitted: true, LimitTokens: cfg.Quotas.AccountDailyTokens, UsedTokens: 0,
			ReservedTokens: 4096, RemainingTokens: cfg.Quotas.AccountDailyTokens - 4096,
			ResetUnix: resetUnix(fixedNow().UTC().Format("2006-01-02")),
		},
		err: context.Canceled,
		onReserve: func() {
			reservationInserted = true
			cancel()
		},
	}
	h := New(cfg, fakeStore, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"llama","max_tokens":4096,"messages":[{"role":"user","content":"hi"}]}`)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if !reservationInserted {
		t.Fatal("fake reservation insert side-channel was not set")
	}
	if fakeStore.refundCalls != 1 {
		t.Fatalf("RefundReservation calls=%d, want 1 after committed reservation/cancel race", fakeStore.refundCalls)
	}
	if resp.Code == http.StatusInternalServerError || strings.Contains(resp.Body.String(), "quota_reservation_failed") {
		t.Fatalf("context-cancelled reservation returned status=%d body=%s", resp.Code, resp.Body.String())
	}
}

// Pre-fix diagnostic captured by fix-stash-test:
// server_test.go:1139: status=500, want 429 body={"error":{"code":"quota_reservation_failed","message":"Could not reserve quota","type":"server_error"}}
func TestQuotaExhaustedReturns429Not500(t *testing.T) {
	_, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(noopClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_quota_opaque_error")
	fakeStore := &quotaReserveFakeStore{
		Store: store,
		decision: storage.QuotaDecision{
			LimitTokens: 1000, UsedTokens: 1000, RemainingTokens: 0,
			ResetUnix: resetUnix(fixedNow().UTC().Format("2006-01-02")),
		},
		err: errors.New("opaque quota rejection commit error"),
	}
	h := New(cfg, fakeStore, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()
	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if resp.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d, want 429 body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "quota_exhausted") {
		t.Fatalf("body missing quota_exhausted: %s", resp.Body.String())
	}
	// Round-2 sweep (H-R2 rate_limit_exceeded-family extension): this path
	// ships X-RateLimit-Reset (a reset header, not a literal Retry-After —
	// the sweep's rule treats the two as equivalent temporal signals) via
	// setRateLimitHeaders, so quota_exhausted must be retryable=true.
	if got := resp.Header().Get("X-RateLimit-Reset"); got == "" {
		t.Fatalf("X-RateLimit-Reset missing on quota_exhausted 429")
	}
	assertBodyRetryable(t, resp.Body.String(), true)
}

func TestQuotaAdmittedOpaqueErrorRefundsBefore500(t *testing.T) {
	_, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(noopClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_quota_admitted_error")
	fakeStore := &quotaReserveFakeStore{
		Store: store,
		decision: storage.QuotaDecision{
			Admitted: true, LimitTokens: cfg.Quotas.AccountDailyTokens, UsedTokens: 0,
			ReservedTokens: cfg.Quotas.AccountDailyTokens, RemainingTokens: 0,
			ResetUnix: resetUnix(fixedNow().UTC().Format("2006-01-02")),
		},
		err: errors.New("commit failed after reservation insert"),
	}
	h := New(cfg, fakeStore, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()

	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)

	if fakeStore.refundCalls != 1 {
		t.Fatalf("RefundReservation calls=%d, want 1", fakeStore.refundCalls)
	}
	if resp.Code != http.StatusInternalServerError {
		t.Fatalf("status=%d, want 500 body=%s", resp.Code, resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), "quota_exhausted") {
		t.Fatalf("admitted opaque error should not be remapped to quota_exhausted: %s", resp.Body.String())
	}
}

type quotaReserveFakeStore struct {
	*sqlite.Store
	decision    storage.QuotaDecision
	err         error
	onReserve   func()
	refundCalls int
}

func (f *quotaReserveFakeStore) ReserveQuota(context.Context, storage.ReservationRequest) (storage.QuotaDecision, error) {
	if f.onReserve != nil {
		f.onReserve()
	}
	return f.decision, f.err
}

func (f *quotaReserveFakeStore) RefundReservation(context.Context, string, string, int64) error {
	f.refundCalls++
	return nil
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
		streamLine := fmt.Sprintf("data: {\"id\":\"chatcmpl\",\"choices\":[{\"delta\":{\"content\":\"%s\"}}]}\n", strings.Repeat("x", 120))
		go func() {
			_, _ = fmt.Fprint(pw, streamLine+"\n")
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
	wantReservedAtFirstByte := promptCapTokens([]byte(body)) + 200
	if reservedAtFirstByte != wantReservedAtFirstByte {
		t.Fatalf("reserved at first byte=%d want %d", reservedAtFirstByte, wantReservedAtFirstByte)
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
	wantCompletion := estimateStreamingCompletionTokens(int64(len(strings.Repeat("x", 120))), 200)
	wantUsed := float64(estimatePromptTokens([]byte(body)) + wantCompletion)
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

// SPEC-006 § 17.7 / issue #187 (P0 money-path): when the gateway's
// normal SettleReservation path fails after bytes have already
// flowed to the buyer, the gateway MUST still write a usage_events
// row (via the new EnsureUsageEvent fallback) so the buyer-side
// SPEC-006 accounting + audit trail are preserved. Per SPEC-005
// § 10.3 ('SPEC-005 does NOT read SPEC-006 usage tables'),
// provider-credit composition is computed on the COORDINATOR from
// request_log, NOT from gateway usage_events — so it's unaffected
// by either the bug or the fix. Pre-#187, the failure mode silently
// called RefundReservation and lost the buyer-side audit row.
//
// Repro: provider streams partial bytes (well under max_tokens),
// then errors out. Between the bytes flowing and settlement
// running, we externally refund the reservation — simulating ANY
// path that could remove the reservation row out from under
// SettleReservation (the phase-A scenario 05 production failure
// mode was empirically observed; root cause was not nailed down,
// but the defensive fix here writes the usage_events row regardless
// of why the reservation lookup fails).
func TestStreamingSettlementFallbackWritesUsageEventOnMissingReservation(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"hi"}]}`
	accountID := "acct_fallback_usage_event"
	// Synchronization channels. The test goroutine waits for the
	// gateway's first delta to flush, deletes the reservation row
	// deterministically, signals via deleteDone, and only THEN does
	// the upstream stream close — guaranteeing the settlement path
	// sees a missing reservation. Polling avoided per ISS-187 R1
	// code/security NOTEs.
	var streamStarted = make(chan struct{}, 1)
	var deleteDone = make(chan error, 1)
	var releaseUpstream = make(chan struct{}, 1)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		pr, pw := io.Pipe()
		go func() {
			_, _ = pw.Write([]byte(`data: {"id":"chatcmpl","choices":[{"delta":{"content":"hello"}}]}` + "\n\n"))
			streamStarted <- struct{}{}
			<-releaseUpstream
			_ = pw.CloseWithError(errors.New("forced upstream provider disconnect"))
		}()
		header := http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}
		return &http.Response{StatusCode: http.StatusOK, Header: header, Body: pr}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	go func() {
		<-streamStarted
		db, err := sql.Open("sqlite", dbPath)
		if err != nil {
			deleteDone <- fmt.Errorf("sql.Open: %w", err)
			releaseUpstream <- struct{}{}
			return
		}
		defer db.Close()
		// Poll-with-deadline for the reservation row. The reservation
		// is inserted very early in handleChatCompletions (before the
		// upstream request fires), so by the time streamStarted
		// signals, the row almost certainly exists. The poll
		// tolerates a tiny window for slow CI runners.
		var requestID string
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			if err := db.QueryRow(`SELECT request_id FROM quota_reservations WHERE account_id = ? AND status = 'active' ORDER BY created_at DESC LIMIT 1`, accountID).Scan(&requestID); err == nil {
				break
			}
			time.Sleep(5 * time.Millisecond)
		}
		if requestID == "" {
			deleteDone <- errors.New("timed out waiting for quota_reservations row")
			releaseUpstream <- struct{}{}
			return
		}
		res, err := db.Exec(`DELETE FROM quota_reservations WHERE account_id = ? AND request_id = ?`, accountID, requestID)
		if err != nil {
			deleteDone <- fmt.Errorf("delete: %w", err)
			releaseUpstream <- struct{}{}
			return
		}
		rows, _ := res.RowsAffected()
		if rows != 1 {
			deleteDone <- fmt.Errorf("delete affected %d rows, want 1", rows)
			releaseUpstream <- struct{}{}
			return
		}
		deleteDone <- nil
		releaseUpstream <- struct{}{}
	}()

	resp := postChat(t, h, fullKey, body, nil)
	if err := <-deleteDone; err != nil {
		t.Fatalf("test setup failed: %v", err)
	}
	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_truncated" {
		t.Fatalf("usage_events outcome = %q, want stream_truncated; fallback did not record the partial-stream row (#187 regression)", outcome)
	}
	if source != "gateway_estimated" {
		t.Fatalf("usage_events token_source = %q, want gateway_estimated", source)
	}
	// R2 architect MAJOR: after the fallback writes the usage_events
	// row, the reservation hold MUST also be released so the buyer's
	// quota is not double-counted (sum of usage_events.total_tokens
	// AND active quota_reservations.reserved_tokens). The test
	// deletes the reservation row out from under settlement, so the
	// RefundReservation call after EnsureUsageEvent is a no-op
	// here — but the assertion still pins the contract that there
	// is NO 'active' reservation row left after the handler returns.
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql.Open for post-condition check: %v", err)
	}
	defer db.Close()
	var activeCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM quota_reservations WHERE account_id = ? AND status = 'active'`, accountID).Scan(&activeCount); err != nil {
		t.Fatalf("count active reservations: %v", err)
	}
	if activeCount != 0 {
		t.Fatalf("active quota_reservations rows = %d, want 0 (R2 architect MAJOR: quota double-count regression)", activeCount)
	}
}

// TestEnsureUsageEventCrossAccountInsertsBothRows pins the issue
// #196 schema fix: usage_events PRIMARY KEY is now
// (account_id, request_id), so a buyer using the same X-Request-ID
// under two different accounts produces TWO distinct rows — each
// account is billed independently and the attack surface that
// motivated the earlier ISS-187 R1 payload-verify defense no longer
// exists. The verify code is retained as defense in depth against
// same-account payload drift (covered by the sibling
// TestEnsureUsageEventRejectsSameIdentityPayloadMismatch).
func TestEnsureUsageEventCrossAccountInsertsBothRows(t *testing.T) {
	dir := t.TempDir()
	st, err := sqlite.Open(context.Background(), dir+"/test.db")
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer st.Close()
	rid := "55555555-5555-4555-8555-555555555555"
	now := time.Date(2026, 6, 28, 0, 0, 0, 0, time.UTC)
	victim := storage.UsageEvent{
		RequestID: rid, AccountID: "victim_account",
		WindowDate: "2026-06-28", PromptTokens: 10, CompletionTokens: 20, TotalTokens: 30,
		TokenSource: "provider_reported", Outcome: "ok", CreatedAt: now,
	}
	if err := st.InsertUsageEvent(context.Background(), victim); err != nil {
		t.Fatalf("InsertUsageEvent (victim row): %v", err)
	}
	attacker := storage.UsageEvent{
		RequestID: rid, AccountID: "attacker_account",
		WindowDate: "2026-06-28", PromptTokens: 1, CompletionTokens: 1, TotalTokens: 2,
		TokenSource: "gateway_estimated", Outcome: "stream_truncated", CreatedAt: now,
	}
	if err := st.EnsureUsageEvent(context.Background(), attacker); err != nil {
		t.Fatalf("EnsureUsageEvent for cross-account same-request_id must succeed under composite PK: %v", err)
	}
	// Both rows persisted, each billed against its own account.
	victimUsed, _, err := st.DailyUsage(context.Background(), "victim_account", "2026-06-28")
	if err != nil {
		t.Fatalf("DailyUsage(victim): %v", err)
	}
	if victimUsed != 30 {
		t.Errorf("victim used = %d, want 30", victimUsed)
	}
	attackerUsed, _, err := st.DailyUsage(context.Background(), "attacker_account", "2026-06-28")
	if err != nil {
		t.Fatalf("DailyUsage(attacker): %v", err)
	}
	if attackerUsed != 2 {
		t.Errorf("attacker used = %d, want 2 (must be billed independently from victim)", attackerUsed)
	}
}

// TestEnsureUsageEventRejectsSameIdentityPayloadMismatch pins the
// R2 code MAJOR fix: the conflict-verify check covers the FULL
// billing payload (tokens + window_date), not just identity. Without
// this, a buyer racing two settle paths could pin a low-token row
// first and then have higher-token settles silently no-op,
// undercharging themselves.
func TestEnsureUsageEventRejectsSameIdentityPayloadMismatch(t *testing.T) {
	dir := t.TempDir()
	st, err := sqlite.Open(context.Background(), dir+"/test.db")
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer st.Close()
	rid := "77777777-7777-4777-8777-777777777777"
	now := time.Date(2026, 6, 28, 0, 0, 0, 0, time.UTC)
	base := storage.UsageEvent{
		RequestID: rid, AccountID: "buyer",
		WindowDate: "2026-06-28", PromptTokens: 5, CompletionTokens: 7, TotalTokens: 12,
		TokenSource: "gateway_estimated", Outcome: "stream_truncated", CreatedAt: now,
	}
	if err := st.InsertUsageEvent(context.Background(), base); err != nil {
		t.Fatalf("InsertUsageEvent (base row): %v", err)
	}
	// Same identity (account, source, outcome) but DIFFERENT
	// completion tokens — must be rejected as a conflict.
	bumped := base
	bumped.CompletionTokens = 50
	bumped.TotalTokens = 55
	if err := st.EnsureUsageEvent(context.Background(), bumped); !errors.Is(err, storage.ErrUsageEventConflict) {
		t.Fatalf("EnsureUsageEvent with bumped tokens: err=%v, want ErrUsageEventConflict", err)
	}
	// Same identity + tokens but DIFFERENT window_date — also must
	// be rejected (covers UTC-midnight-crossing race attempts).
	shifted := base
	shifted.WindowDate = "2026-06-29"
	if err := st.EnsureUsageEvent(context.Background(), shifted); !errors.Is(err, storage.ErrUsageEventConflict) {
		t.Fatalf("EnsureUsageEvent with shifted window: err=%v, want ErrUsageEventConflict", err)
	}
}

// TestEnsureUsageEventAcceptsMatchingRetry confirms the benign
// idempotency case: a duplicate INSERT with all matching identity
// + token + window fields is treated as success — covers retries
// and race-with-normal-settle scenarios.
func TestEnsureUsageEventAcceptsMatchingRetry(t *testing.T) {
	dir := t.TempDir()
	st, err := sqlite.Open(context.Background(), dir+"/test.db")
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer st.Close()
	rid := "66666666-6666-4666-8666-666666666666"
	now := time.Date(2026, 6, 28, 0, 0, 0, 0, time.UTC)
	ev := storage.UsageEvent{
		RequestID: rid, AccountID: "buyer",
		WindowDate: "2026-06-28", PromptTokens: 5, CompletionTokens: 7, TotalTokens: 12,
		TokenSource: "gateway_estimated", Outcome: "stream_truncated", CreatedAt: now,
	}
	if err := st.InsertUsageEvent(context.Background(), ev); err != nil {
		t.Fatalf("InsertUsageEvent first call: %v", err)
	}
	if err := st.EnsureUsageEvent(context.Background(), ev); err != nil {
		t.Fatalf("EnsureUsageEvent retry with matching fields: %v", err)
	}
}

// SPEC-002 § FR-B6 / issue #186: when the upstream coordinator
// stream dies mid-flight (provider disconnect surfaces here as an
// io.Pipe close-with-error), the gateway MUST emit the exact
// provider_disconnected SSE error envelope BEFORE `data: [DONE]`.
// OpenAI-compatible SDK clients route on (error.code, error.type)
// to distinguish a normal short response from a provider drop.
//
// The internal settlement outcome stays `stream_truncated` per the
// gateway settlement convention and SPEC-006 § 17.7 quota-debit
// policy (partial stream → prompt + actual completion tokens
// charged) — a separate usage_events.outcome field, not the
// buyer-visible SSE error.code. Earlier the buyer-visible code was
// also `stream_truncated`, conflating settlement and signaling
// (and silently truncating responses for SDK consumers).
func TestStreamingMidStreamProviderDisconnectEmitsFRB6Envelope(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"hi"}]}`
	accountID := "acct_provider_disconnected"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		pr, pw := io.Pipe()
		go func() {
			// One valid delta, then force an unexpected upstream close.
			_, _ = pw.Write([]byte(`data: {"id":"chatcmpl","choices":[{"delta":{"content":"hello"}}]}` + "\n\n"))
			_ = pw.CloseWithError(errors.New("forced upstream provider disconnect"))
		}()
		header := http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}
		return &http.Response{StatusCode: http.StatusOK, Header: header, Body: pr}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}

	// Locate the FR-B6 error event in the SSE stream BEFORE [DONE].
	bodyStr := resp.Body.String()
	doneIdx := strings.Index(bodyStr, "data: [DONE]")
	if doneIdx < 0 {
		t.Fatalf("response missing data: [DONE]; body=%s", bodyStr)
	}
	preDone := bodyStr[:doneIdx]
	if !strings.Contains(preDone, `"code":"provider_disconnected"`) {
		t.Fatalf("FR-B6 envelope missing provider_disconnected before [DONE]; preDone=%s", preDone)
	}
	if !strings.Contains(preDone, `"type":"server_error"`) {
		t.Fatalf("FR-B6 envelope missing type=server_error before [DONE]; preDone=%s", preDone)
	}
	if !strings.Contains(preDone, `"message":"Provider disconnected during streaming"`) {
		t.Fatalf("FR-B6 envelope missing canonical message before [DONE]; preDone=%s", preDone)
	}

	// Internal settlement outcome stays stream_truncated (SPEC-006
	// § 17.7); the buyer-visible code is a SEPARATE field. This
	// assertion guards against any accidental coupling.
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_truncated" || source != "gateway_estimated" {
		t.Fatalf("settlement outcome/source = %s/%s, want stream_truncated/gateway_estimated", outcome, source)
	}
}

func TestStreamingScannerErrorSettlesStreamTruncated(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"large line"}]}`
	accountID := "acct_stream_truncated"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		pr, pw := io.Pipe()
		go func() {
			_, _ = pw.Write([]byte("data: "))
			_, _ = pw.Write([]byte(strings.Repeat("x", 1024*1024+1)))
			_, _ = pw.Write([]byte("\n\n"))
			_ = pw.Close()
		}()
		header := http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}
		return &http.Response{StatusCode: http.StatusOK, Header: header, Body: pr}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	// Issue #186 / code R1 NOTE: pin the BUYER-VISIBLE envelope on
	// the buffer-full gateway-truncation path. This is intentionally
	// stream_truncated / api_error (NOT FR-B6's
	// provider_disconnected / server_error) because the line-too-
	// long failure is gateway protection, not a provider drop. If
	// the codepath drifts, OpenAI SDK consumers would misclassify
	// gateway truncation as a retriable provider failure.
	bodyStr := resp.Body.String()
	doneIdx := strings.Index(bodyStr, "data: [DONE]")
	if doneIdx < 0 {
		t.Fatalf("response missing data: [DONE]; body=%s", bodyStr)
	}
	preDone := bodyStr[:doneIdx]
	if !strings.Contains(preDone, `"code":"stream_truncated"`) {
		t.Fatalf("buffer-full envelope missing code=stream_truncated; preDone=%s", preDone)
	}
	if !strings.Contains(preDone, `"type":"api_error"`) {
		t.Fatalf("buffer-full envelope missing type=api_error; preDone=%s", preDone)
	}
	if strings.Contains(preDone, `"provider_disconnected"`) {
		t.Fatalf("buffer-full envelope leaked provider_disconnected; gateway-truncation must NOT use the FR-B6 envelope; preDone=%s", preDone)
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_truncated" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_truncated/gateway_estimated", outcome, source)
	}
}

func TestStreamingProviderReportedUsageCannotUnderstateTruncatedOutput(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"large line"}]}`
	accountID := "acct_stream_underreported_truncated"
	output := strings.Repeat("x", 100)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		pr, pw := io.Pipe()
		go func() {
			_, _ = pw.Write([]byte(`data: {"id":"chatcmpl","choices":[{"delta":{"content":"` + output + `"}}]}` + "\n\n"))
			_, _ = pw.Write([]byte(`data: {"id":"chatcmpl","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[{"delta":{},"finish_reason":"stop"}]}` + "\n\n"))
			_ = pw.CloseWithError(errors.New("forced upstream stream failure"))
		}()
		header := http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}
		return &http.Response{StatusCode: http.StatusOK, Header: header, Body: pr}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_truncated" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_truncated/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	promptEstimate := estimatePromptTokens([]byte(body))
	wantCompletion := estimateStreamingCompletionTokens(int64(len(output)), 500)
	wantUsed := float64(promptEstimate + wantCompletion)
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingReadErrorAfterBuyerCancelSettlesClientDisconnect(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"cancel"}]}`
	accountID := "acct_stream_read_cancel"
	ctx, cancel := context.WithCancel(context.Background())
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		header := http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     header,
			Body:       cancelingReadCloser{cancel: cancel, err: context.Canceled},
		}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "client_disconnect" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want client_disconnect/gateway_estimated", outcome, source)
	}
}

func TestStreamingCleanEOFLegacySettlesUnverified(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"ok"}]}`
	accountID := "acct_stream_ok"
	// Content payload aligned with the reported completion_tokens so the
	// gateway's byte-based observation matches the provider's tokenizer
	// count and the trust-provider branch fires. Pre-#255 the fixture
	// here was a 2-byte "ok" content + 4 reported completion_tokens —
	// a tokenizer-mismatched fixture that exercised the trust-provider
	// branch only because the old code lacked the downward clamp.
	// With #255 the clamp catches that exact pattern, so the fixture
	// now reflects what a real clean stream looks like.
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := `data: {"id":"chatcmpl","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"delta":{"content":"0123456789abcdef"}}]}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload+"\n\ndata: [DONE]\n\n"), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "unverified_streaming" || source != "provider_reported" {
		t.Fatalf("usage outcome/source = %s/%s, want unverified_streaming/provider_reported", outcome, source)
	}
}

func TestStreamingPreservesSSELineBytes(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"ok"}]}`
	accountID := "acct_stream_bytes"
	streamBody := "data: {\"id\":\"chatcmpl\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, streamBody), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := resp.Body.String(); got != streamBody {
		t.Fatalf("stream body bytes changed:\ngot  %q\nwant %q", got, streamBody)
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "unverified_streaming" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want unverified_streaming/gateway_estimated", outcome, source)
	}
}

func TestStreamingGatewayEstimateStopsOverMaxOutput(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":1,"messages":[{"role":"user","content":"ok"}]}`
	accountID := "acct_stream_clamped"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"id":"chatcmpl","choices":[{"delta":{"content":"` + strings.Repeat("x", 400) + `"}}]}`,
			`data: {"id":"chatcmpl","choices":[{"delta":{},"finish_reason":"stop"}]}`,
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "stream_output_exceeded") {
		t.Fatalf("stream body missing stream_output_exceeded: %s", resp.Body.String())
	}
	if !strings.HasSuffix(resp.Body.String(), "data: [DONE]\n\n") {
		t.Fatalf("stream body missing DONE terminator: %s", resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_output_exceeded" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_output_exceeded/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantUsed := float64(estimatePromptTokens([]byte(body)))
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingGatewayOutputExceededAfterForwardedPrefixChargesNoCompletion(t *testing.T) {
	for _, tc := range []struct {
		name               string
		header             http.Header
		wantUsageRows      int64
		wantSettledRows    int64
		wantActiveRows     int64
		wantActiveReserved int64
		wantHeldRows       int64
	}{
		{
			name:            "legacy-without-finality-trailers",
			header:          http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}},
			wantUsageRows:   1,
			wantSettledRows: 1,
		},
		{
			name: "declared-finality-trailers-unavailable-after-gateway-cancel",
			header: http.Header{
				"Content-Type": []string{"text/event-stream; charset=utf-8"},
				"Trailer":      []string{strings.Join(settlementFinalityHeaderNamesForTest(), ", ")},
			},
			wantActiveRows:     1,
			wantActiveReserved: promptCapTokens([]byte(`{"model":"llama","stream":true,"max_tokens":4,"messages":[{"role":"user","content":"ok"}]}`)) + 4,
			wantHeldRows:       1,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := `{"model":"llama","stream":true,"max_tokens":4,"messages":[{"role":"user","content":"ok"}]}`
			accountID := "acct_stream_output_exceeded_after_prefix_" + strings.ReplaceAll(tc.name, "-", "_")
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				payload := strings.Join([]string{
					`data: {"id":"chatcmpl","choices":[{"delta":{"content":"` + strings.Repeat("x", 32) + `"}}]}`,
					`data: {"id":"chatcmpl","choices":[{"delta":{"content":"y"}}]}`,
					`data: {"id":"chatcmpl","choices":[{"delta":{},"finish_reason":"stop"}]}`,
					`data: [DONE]`,
					``,
				}, "\n\n")
				return responseWithBody(http.StatusOK, tc.header.Clone(), payload), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			fullKey := createAccountAndKey(t, store, cfg, accountID)

			resp := postChat(t, h, fullKey, body, nil)

			if resp.Code != http.StatusOK {
				t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
			}
			if !strings.Contains(resp.Body.String(), "stream_output_exceeded") {
				t.Fatalf("stream body missing stream_output_exceeded: %s", resp.Body.String())
			}
			wantPrompt := estimatePromptTokens([]byte(body))
			got := gatewaySettlementSnapshot(t, dbPath, accountID)
			if got.usageRows != tc.wantUsageRows || got.settledRows != tc.wantSettledRows || got.activeRows != tc.wantActiveRows || got.activeReserved != tc.wantActiveReserved || got.heldRows != tc.wantHeldRows {
				t.Fatalf("settlement snapshot = %+v, want usage=%d settled=%d active=%d active_reserved=%d held=%d",
					got, tc.wantUsageRows, tc.wantSettledRows, tc.wantActiveRows, tc.wantActiveReserved, tc.wantHeldRows)
			}
			if tc.wantUsageRows > 0 {
				outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
				if outcome != "stream_output_exceeded" || source != "gateway_estimated" || completion != 0 {
					t.Fatalf("usage row outcome/source/completion = %s/%s/%d, want stream_output_exceeded/gateway_estimated/0", outcome, source, completion)
				}
				if prompt != wantPrompt {
					t.Fatalf("usage row prompt_tokens=%d want %d", prompt, wantPrompt)
				}
			}
			usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
			quota := readQuota(t, usageResp)
			wantUsed := float64(0)
			if tc.wantUsageRows > 0 {
				wantUsed = float64(wantPrompt)
			}
			if quota["daily_tokens_used"].(float64) != wantUsed {
				t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
			}
			if quota["daily_tokens_reserved"].(float64) != float64(tc.wantActiveReserved) {
				t.Fatalf("daily_tokens_reserved=%v want %v", quota["daily_tokens_reserved"], tc.wantActiveReserved)
			}
		})
	}
}

func TestStreamingGatewayEstimateCountsDataWithoutSpace(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":1,"messages":[{"role":"user","content":"ok"}]}`
	accountID := "acct_stream_no_space"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data:{"id":"chatcmpl","choices":[{"delta":{"content":"` + strings.Repeat("x", 400) + `"}}]}`,
			`data:[DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "stream_output_exceeded") {
		t.Fatalf("stream body missing stream_output_exceeded: %s", resp.Body.String())
	}
	if !strings.HasSuffix(resp.Body.String(), "data: [DONE]\n\n") {
		t.Fatalf("stream body missing DONE terminator: %s", resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_output_exceeded" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_output_exceeded/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantUsed := float64(estimatePromptTokens([]byte(body)))
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingGatewayEstimateCountsGeneratedDeltaStrings(t *testing.T) {
	cases := []struct {
		name    string
		account string
		delta   string
	}{
		{
			name:    "reasoning_content",
			account: "acct_stream_reasoning",
			delta:   `"reasoning_content":"` + strings.Repeat("r", 400) + `"`,
		},
		{
			name:    "refusal",
			account: "acct_stream_refusal",
			delta:   `"refusal":"` + strings.Repeat("f", 400) + `"`,
		},
		{
			name:    "legacy_function_call_arguments",
			account: "acct_stream_function_call",
			delta:   `"function_call":{"name":"lookup","arguments":"` + strings.Repeat("a", 400) + `"}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := `{"model":"llama","stream":true,"max_tokens":1,"messages":[{"role":"user","content":"ok"}]}`
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				payload := strings.Join([]string{
					`data:{"id":"chatcmpl","choices":[{"delta":{` + tc.delta + `},"finish_reason":null}]}`,
					`data:[DONE]`,
					``,
				}, "\n\n")
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			fullKey := createAccountAndKey(t, store, cfg, tc.account)

			resp := postChat(t, h, fullKey, body, nil)

			if resp.Code != http.StatusOK {
				t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
			}
			if !strings.Contains(resp.Body.String(), "stream_output_exceeded") {
				t.Fatalf("stream body missing stream_output_exceeded: %s", resp.Body.String())
			}
			if !strings.HasSuffix(resp.Body.String(), "data: [DONE]\n\n") {
				t.Fatalf("stream body missing DONE terminator: %s", resp.Body.String())
			}
			outcome, source := usageEventOutcome(t, dbPath, tc.account)
			if outcome != "stream_output_exceeded" || source != "gateway_estimated" {
				t.Fatalf("usage outcome/source = %s/%s, want stream_output_exceeded/gateway_estimated", outcome, source)
			}
			usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
			quota := readQuota(t, usageResp)
			wantUsed := float64(estimatePromptTokens([]byte(body)))
			if quota["daily_tokens_used"].(float64) != wantUsed {
				t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
			}
			if quota["daily_tokens_reserved"].(float64) != 0 {
				t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
			}
		})
	}
}

func TestStreamingGatewayEstimateCountsSerializedFrameExposure(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":1,"messages":[{"role":"user","content":"ok"}]}`
	accountID := "acct_stream_metadata"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"id":"` + strings.Repeat("m", 400) + `","object":"chat.completion.chunk","choices":[{"delta":{"content":"ok"},"finish_reason":null}]}`,
			`data: {"id":"` + strings.Repeat("m", 400) + `","object":"chat.completion.chunk","choices":[{"delta":{},"finish_reason":"stop"}]}`,
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.HasSuffix(resp.Body.String(), "data: [DONE]\n\n") {
		t.Fatalf("stream body missing DONE terminator: %s", resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_output_exceeded" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_output_exceeded/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantUsed := float64(estimatePromptTokens([]byte(body)) + 1)
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingGatewayEstimateCountsToolCallArguments(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":1,"messages":[{"role":"user","content":"tool"}],"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object"}}}]}`
	accountID := "acct_stream_tool_call"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"id":"chatcmpl","choices":[{"delta":{"tool_calls":[{"index":0,"id":"` + strings.Repeat("m", 400) + `","type":"function","function":{"name":"` + strings.Repeat("n", 400) + `","arguments":"abcd"}}]},"finish_reason":null}]}`,
			`data: {"id":"chatcmpl","choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), "stream_output_exceeded") {
		t.Fatalf("stream body unexpectedly exceeded output cap: %s", resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_output_exceeded" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_output_exceeded/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantUsed := float64(estimatePromptTokens([]byte(body)) + 1)
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingGatewayEstimateStopsOverMaxToolCallArguments(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":1,"messages":[{"role":"user","content":"tool"}],"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object"}}}]}`
	accountID := "acct_stream_tool_call_clamped"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"id":"chatcmpl","choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","type":"function","function":{"name":"lookup","arguments":"` + strings.Repeat("x", 400) + `"}}]},"finish_reason":null}]}`,
			`data: {"id":"chatcmpl","choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "stream_output_exceeded") {
		t.Fatalf("stream body missing stream_output_exceeded: %s", resp.Body.String())
	}
	if !strings.HasSuffix(resp.Body.String(), "data: [DONE]\n\n") {
		t.Fatalf("stream body missing DONE terminator: %s", resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_output_exceeded" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_output_exceeded/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantUsed := float64(estimatePromptTokens([]byte(body)))
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingGatewayEstimateStopsMalformedChunkWithoutRawCounting(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":100,"messages":[{"role":"user","content":"malformed"}]}`
	accountID := "acct_stream_malformed"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"id":"chatcmpl","choices":[{"delta":{"content":"ok"},"finish_reason":null}]}`,
			`data: not-json-` + strings.Repeat("m", 400),
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "stream_malformed") {
		t.Fatalf("stream body missing stream_malformed: %s", resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), strings.Repeat("m", 200)) {
		t.Fatalf("malformed raw payload was forwarded: %s", resp.Body.String())
	}
	if !strings.HasSuffix(resp.Body.String(), "data: [DONE]\n\n") {
		t.Fatalf("stream body missing DONE terminator: %s", resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_malformed" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_malformed/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantUsed := float64(estimatePromptTokens([]byte(body)) + 1)
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingGatewayEstimateStopsMalformedDataWithoutSpace(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":100,"messages":[{"role":"user","content":"malformed"}]}`
	accountID := "acct_stream_malformed_no_space"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data:{"id":"chatcmpl","choices":[{"delta":{"content":"ok"},"finish_reason":null}]}`,
			`data:not-json-` + strings.Repeat("m", 400),
			`data:[DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "stream_malformed") {
		t.Fatalf("stream body missing stream_malformed: %s", resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), strings.Repeat("m", 200)) {
		t.Fatalf("malformed raw payload was forwarded: %s", resp.Body.String())
	}
	if !strings.HasSuffix(resp.Body.String(), "data: [DONE]\n\n") {
		t.Fatalf("stream body missing DONE terminator: %s", resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_malformed" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_malformed/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantUsed := float64(estimatePromptTokens([]byte(body)) + 1)
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingGatewayEstimateStopsNonObjectDelta(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":100,"messages":[{"role":"user","content":"malformed"}]}`
	accountID := "acct_stream_non_object_delta"
	rawDelta := strings.Repeat("m", 400)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data:{"id":"chatcmpl","choices":[{"delta":"` + rawDelta + `","finish_reason":null}]}`,
			`data:[DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "stream_malformed") {
		t.Fatalf("stream body missing stream_malformed: %s", resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), strings.Repeat("m", 200)) {
		t.Fatalf("non-object delta raw payload was forwarded: %s", resp.Body.String())
	}
	if !strings.HasSuffix(resp.Body.String(), "data: [DONE]\n\n") {
		t.Fatalf("stream body missing DONE terminator: %s", resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_malformed" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_malformed/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantUsed := float64(estimatePromptTokens([]byte(body)))
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingGatewayEstimateStopsDataWithoutChoicesOrUsage(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":100,"messages":[{"role":"user","content":"malformed"}]}`
	accountID := "acct_stream_no_choices"
	rawPayload := strings.Repeat("m", 400)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data:{"object":"not-a-chat-chunk","text":"` + rawPayload + `"}`,
			`data:[DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "stream_malformed") {
		t.Fatalf("stream body missing stream_malformed: %s", resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), strings.Repeat("m", 200)) {
		t.Fatalf("data without choices/usage was forwarded: %s", resp.Body.String())
	}
	if !strings.HasSuffix(resp.Body.String(), "data: [DONE]\n\n") {
		t.Fatalf("stream body missing DONE terminator: %s", resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "stream_malformed" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want stream_malformed/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantUsed := float64(estimatePromptTokens([]byte(body)))
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingInvalidUsageAfterValidFallsBackToGatewayEstimate(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"ok"}]}`
	accountID := "acct_stream_invalid_usage"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"id":"chatcmpl","usage":{"prompt_tokens":1,"completion_tokens":0,"total_tokens":1},"choices":[{"delta":{"content":"ok"}}]}`,
			`data: {"id":"chatcmpl","choices":[{"delta":{"content":"more"}}]}`,
			`data: {"id":"chatcmpl","usage":{},"choices":[{"delta":{"content":""}}]}`,
			`data: {"id":"chatcmpl","usage":{"prompt_tokens":9,"cached_prompt_tokens":4,"completion_tokens":1,"total_tokens":10},"choices":[{"delta":{"content":""}}]}`,
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "unverified_streaming" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want unverified_streaming/gateway_estimated", outcome, source)
	}
	if strings.Contains(resp.Body.String(), `"usage":{}`) {
		t.Fatalf("invalid usage frame was forwarded: %s", resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), `"cached_prompt_tokens":4`) || strings.Contains(resp.Body.String(), `"prompt_tokens":9`) {
		t.Fatalf("later usage frame was forwarded after invalid usage: %s", resp.Body.String())
	}
}

func TestStreamingSanitizesInvalidCachedPromptTokensWithoutRejectingUsage(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"ok"}]}`
	accountID := "acct_stream_invalid_cache"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"id":"chatcmpl","choices":[{"delta":{"content":"ok"}}]}`,
			`data: {"id":"chatcmpl","usage":{"prompt_tokens":3,"cached_prompt_tokens":4,"completion_tokens":2,"total_tokens":5},"choices":[{"delta":{},"finish_reason":"stop"}]}`,
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"cached_prompt_tokens":0`) {
		t.Fatalf("stream body did not sanitize cached_prompt_tokens: %s", resp.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
	if outcome != "unverified_streaming" || source != "provider_reported" || prompt != 3 || completion != 2 {
		t.Fatalf("usage event outcome/source/prompt/completion = %s/%s/%d/%d, want unverified_streaming/provider_reported/3/2", outcome, source, prompt, completion)
	}
}

// TestStreamingOverCapUsageClampsInsteadOfDroppingFrame regresses the
// 2026-07-09 canary-probe finding: when a provider's honest token count
// exceeds the reservation-derived validation cap (common for token-dense
// prompts the byte heuristic under-counts), the gateway used to drop the
// usage frame from the buyer stream and force settlement to gateway_estimated
// byte estimates. It must instead forward the frame (buyer keeps usage
// visibility) and settle provider_reported, clamped to the reservation cap.
func TestStreamingOverCapUsageClampsInsteadOfDroppingFrame(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":5,"messages":[{"role":"user","content":"ok"}]}`
	accountID := "acct_stream_overcap_usage"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"id":"chatcmpl","choices":[{"delta":{"content":"ok"}}]}`,
			`data: {"id":"chatcmpl","usage":{"prompt_tokens":200,"completion_tokens":1,"total_tokens":201},"choices":[{"delta":{},"finish_reason":"stop"}]}`,
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	// Visibility fix: the usage frame is forwarded with the provider's ACTUAL
	// prompt count, not dropped.
	if !strings.Contains(resp.Body.String(), `"prompt_tokens":200`) {
		t.Fatalf("over-cap usage frame was dropped from buyer stream: %s", resp.Body.String())
	}
	// Billing fix: settled provider_reported (not gateway_estimated), clamped to
	// the reservation cap.
	capTokens := promptCapTokens([]byte(body)) + 5
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
	if source != "provider_reported" {
		t.Fatalf("over-cap settlement source=%s outcome=%s, want provider_reported (not gateway_estimated)", source, outcome)
	}
	if completion != 1 || prompt != capTokens-1 {
		t.Fatalf("over-cap clamped tokens prompt/completion = %d/%d, want %d/1 (bounded to cap=%d)", prompt, completion, capTokens-1, capTokens)
	}
}

func TestStreamingProviderReportedUsageCannotUnderstateObservedOutput(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":500,"messages":[{"role":"user","content":"ok"}]}`
	accountID := "acct_stream_underreported_usage"
	output := strings.Repeat("x", 100)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"id":"chatcmpl","choices":[{"delta":{"content":"` + output + `"}}]}`,
			`data: {"id":"chatcmpl","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[{"delta":{},"finish_reason":"stop"}]}`,
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "unverified_streaming" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want unverified_streaming/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	promptEstimate := estimatePromptTokens([]byte(body))
	wantCompletion := estimateStreamingCompletionTokens(int64(len(output)), 500)
	wantUsed := float64(promptEstimate + wantCompletion)
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestStreamingUnderreportedUsageWithHighProviderPromptFallsBackToGatewayEstimate(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":50,"messages":[{"role":"user","content":"ok"}]}`
	accountID := "acct_stream_underreported_high_prompt"
	output := strings.Repeat("x", 100)
	promptEstimate := estimatePromptTokens([]byte(body))
	providerPrompt := promptEstimate + 19
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		payload := strings.Join([]string{
			`data: {"id":"chatcmpl","choices":[{"delta":{"content":"` + output + `"}}]}`,
			`data: {"id":"chatcmpl","usage":{"prompt_tokens":` + strconv.FormatInt(providerPrompt, 10) + `,"completion_tokens":1,"total_tokens":` + strconv.FormatInt(providerPrompt+1, 10) + `},"choices":[{"delta":{},"finish_reason":"stop"}]}`,
			`data: [DONE]`,
			``,
		}, "\n\n")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	outcome, source := usageEventOutcome(t, dbPath, accountID)
	if outcome != "unverified_streaming" || source != "gateway_estimated" {
		t.Fatalf("usage outcome/source = %s/%s, want unverified_streaming/gateway_estimated", outcome, source)
	}
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantCompletion := estimateStreamingCompletionTokens(int64(len(output)), 50)
	wantUsed := float64(promptEstimate + wantCompletion)
	if quota["daily_tokens_used"].(float64) != wantUsed {
		t.Fatalf("daily_tokens_used=%v want %v", quota["daily_tokens_used"], wantUsed)
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestSettleFromUsage_Qwen3_32B_Legacy_Baseline(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_qwen3_32b",
		model:          "mlx-community/Qwen3-32B-4bit",
		contentBytes:   128,
		reportedPrompt: 12,
		reportedComp:   32,
		maxTokens:      128,
		wantOutcome:    "unverified_streaming",
		wantSource:     "provider_reported",
		wantCompletion: 32,
		wantPrompt:     12,
	})
}

func TestSettleFromUsage_Llama_31_8B_NoOverbill(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_llama_31_8b",
		model:          "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
		contentBytes:   372,
		reportedPrompt: 46,
		reportedComp:   69,
		maxTokens:      128,
		wantOutcome:    "unverified_streaming",
		wantSource:     "provider_reported",
		wantCompletion: 69,
		wantPrompt:     46,
	})
}

func TestSettleFromUsage_Qwen25_Coder_32B_NoDownclamp(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_qwen25_coder_32b",
		model:          "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
		contentBytes:   464,
		reportedPrompt: 42,
		reportedComp:   128,
		maxTokens:      128,
		wantOutcome:    "unverified_streaming",
		wantSource:     "provider_reported",
		wantCompletion: 128,
		wantPrompt:     42,
	})
}

func TestSettleFromUsage_GptOss_20B_NoMidStreamByteCap(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_gpt_oss_20b",
		model:          "mlx-community/gpt-oss-20b-MXFP4-Q8",
		contentBytes:   640,
		chunks:         5,
		reportedPrompt: 42,
		reportedComp:   128,
		maxTokens:      128,
		wantOutcome:    "unverified_streaming",
		wantSource:     "provider_reported",
		wantCompletion: 128,
		wantPrompt:     42,
	})
}

func TestSettleFromUsage_Qwen3Coder_30B_A3B_NoMidStreamByteCap(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_qwen3_coder_30b_a3b",
		model:          "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
		contentBytes:   640,
		chunks:         4,
		reportedPrompt: 52,
		reportedComp:   128,
		maxTokens:      128,
		wantOutcome:    "unverified_streaming",
		wantSource:     "provider_reported",
		wantCompletion: 128,
		wantPrompt:     52,
	})
}

func TestSettleFromUsage_NoUsageChunk_FallsBackToByteEstimate(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_no_chunk",
		model:          "llama",
		contentBytes:   120,
		noUsage:        true,
		maxTokens:      128,
		wantOutcome:    "unverified_streaming",
		wantSource:     "gateway_estimated",
		wantCompletion: 51,
	})
}

func TestSettleFromUsage_InvalidUsageChunk_FallsBackToByteEstimate(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_invalid_chunk",
		model:          "llama",
		contentBytes:   120,
		invalidUsage:   true,
		maxTokens:      128,
		wantOutcome:    "unverified_streaming",
		wantSource:     "gateway_estimated",
		wantCompletion: 51,
	})
}

func TestSettleFromUsage_TruncatedStream_WithPartialUsage(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_truncated_partial",
		model:          "llama",
		contentBytes:   120,
		reportedPrompt: 12,
		reportedComp:   42,
		maxTokens:      128,
		streamErr:      errors.New("forced upstream stream failure"),
		wantOutcome:    "stream_truncated",
		wantSource:     "provider_reported",
		wantCompletion: 42,
		wantPrompt:     12,
	})
}

func TestSettleFromUsage_RealStreamOutputExceeded_ProviderReports(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_real_output_exceeded",
		model:          "llama",
		contentBytes:   800,
		reportedPrompt: 12,
		reportedComp:   200,
		maxTokens:      128,
		wantOutcome:    "stream_output_exceeded",
		wantSource:     "provider_reported",
		wantCompletion: 200,
		wantPrompt:     12,
	})
}

func TestSettleFromUsage_OverMaxWithoutObservedOutput_FallsBackToByteCap(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_overmax_spoof",
		model:          "llama",
		contentBytes:   640,
		reportedPrompt: 12,
		reportedComp:   200,
		maxTokens:      128,
		wantOutcome:    "stream_output_exceeded",
		wantSource:     "gateway_estimated",
		wantCompletion: 128,
	})
}

func TestSettleFromUsage_TruncatedOverMaxWithoutObservedOutput_FallsBackToByteCap(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_truncated_overmax_spoof",
		model:          "llama",
		contentBytes:   640,
		reportedPrompt: 12,
		reportedComp:   200,
		maxTokens:      128,
		streamErr:      errors.New("forced upstream stream failure"),
		wantOutcome:    "stream_output_exceeded",
		wantSource:     "gateway_estimated",
		wantCompletion: 128,
	})
}

func TestSettleFromUsage_RunawayByteStream_HardCapChargesOnlyForwardedPrefix(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_runaway_hard_cap",
		model:          "llama",
		contentBytes:   128*8*4 + 1,
		noUsage:        true,
		maxTokens:      128,
		wantOutcome:    "stream_output_exceeded",
		wantSource:     "gateway_estimated",
		wantCompletion: 0,
	})
}

func TestSettleFromUsage_ClientDisconnectOverMaxWithoutObservedOutput_FallsBackToByteCap(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_client_disconnect_overmax_spoof",
		model:          "llama",
		contentBytes:   640,
		reportedPrompt: 12,
		reportedComp:   200,
		maxTokens:      128,
		failWriteAt:    3,
		wantOutcome:    "stream_output_exceeded",
		wantSource:     "gateway_estimated",
		wantCompletion: 128,
	})
}

func TestSettleFromUsage_ClientDisconnect_WithUsage(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_client_disconnect",
		model:          "llama",
		contentBytes:   120,
		reportedPrompt: 12,
		reportedComp:   42,
		maxTokens:      128,
		failWriteAt:    3,
		wantOutcome:    "client_disconnect",
		wantSource:     "gateway_estimated",
		wantCompletion: 30,
	})
}

func TestStreamingIdleTimeoutTerminatesAndIgnoresUsageOnlyFrame(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":128,"messages":[{"role":"user","content":"stall"}]}`
	accountID := "acct_stream_idle_usage_only"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		pr, pw := io.Pipe()
		go func() {
			_, _ = pw.Write([]byte(`data: {"id":"chatcmpl","usage":{"prompt_tokens":0,"completion_tokens":102,"total_tokens":102},"choices":[{"delta":{},"finish_reason":"stop"}]}` + "\n\n"))
			<-r.Context().Done()
			_ = pw.CloseWithError(r.Context().Err())
		}()
		return &http.Response{
			StatusCode: http.StatusOK,
			Header: http.Header{
				"Content-Type": []string{"text/event-stream; charset=utf-8"},
				"Trailer":      []string{settlementOutcomeHeader},
			},
			Body: pr,
		}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.StreamingIdleMS = 25
		cfg.Timeouts.CoordinatorRequestSeconds = 5
		cfg.Timeouts.CoordinatorHeaderTimeoutSeconds = 5
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"code":"provider_timeout"`) || !strings.Contains(resp.Body.String(), "data: [DONE]") {
		t.Fatalf("stream body missing terminal provider_timeout + DONE: %s", resp.Body.String())
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.usageRows != 0 || got.settledRows != 0 || got.activeRows != 1 || got.heldRows != 1 {
		t.Fatalf("settlement snapshot=%+v, want declared idle timeout held without local usage row", got)
	}
}

func TestStreamingBuyerCancelBeforeIdleIgnoresUsageOnlyFrame(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":128,"messages":[{"role":"user","content":"cancel"}]}`
	accountID := "acct_stream_cancel_usage_only"
	firstFrame := make(chan struct{})
	cancelSeen := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		pr, pw := io.Pipe()
		go func() {
			_, _ = pw.Write([]byte(`data: {"id":"chatcmpl","usage":{"prompt_tokens":0,"completion_tokens":102,"total_tokens":102},"choices":[{"delta":{},"finish_reason":"stop"}]}` + "\n\n"))
			close(firstFrame)
			<-r.Context().Done()
			close(cancelSeen)
			_ = pw.CloseWithError(r.Context().Err())
		}()
		return &http.Response{
			StatusCode: http.StatusOK,
			Header: http.Header{
				"Content-Type": []string{"text/event-stream; charset=utf-8"},
				"Trailer":      []string{settlementOutcomeHeader},
			},
			Body: pr,
		}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.StreamingIdleMS = 5000
		cfg.Timeouts.CoordinatorRequestSeconds = 10
		cfg.Timeouts.CoordinatorHeaderTimeoutSeconds = 10
	}, WithHTTPClient(client))
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
	case <-firstFrame:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for usage-only frame")
	}
	time.Sleep(25 * time.Millisecond)
	cancel()
	select {
	case <-cancelSeen:
	case <-time.After(2 * time.Second):
		t.Fatal("upstream did not observe buyer cancellation")
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("gateway did not finish after buyer cancellation")
	}

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.usageRows != 0 || got.settledRows != 0 || got.activeRows != 1 || got.heldRows != 1 {
		t.Fatalf("settlement snapshot=%+v, want declared client disconnect held without local usage row", got)
	}
}

func TestStreamingBuyerDeadlineBeforeIdleIgnoresUsageOnlyFrame(t *testing.T) {
	body := `{"model":"llama","stream":true,"max_tokens":128,"messages":[{"role":"user","content":"deadline"}]}`
	accountID := "acct_stream_deadline_usage_only"
	firstFrame := make(chan struct{})
	cancelSeen := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		pr, pw := io.Pipe()
		go func() {
			_, _ = pw.Write([]byte(`data: {"id":"chatcmpl","usage":{"prompt_tokens":0,"completion_tokens":102,"total_tokens":102},"choices":[{"delta":{},"finish_reason":"stop"}]}` + "\n\n"))
			close(firstFrame)
			<-r.Context().Done()
			close(cancelSeen)
			_ = pw.CloseWithError(r.Context().Err())
		}()
		return &http.Response{
			StatusCode: http.StatusOK,
			Header: http.Header{
				"Content-Type": []string{"text/event-stream; charset=utf-8"},
				"Trailer":      []string{settlementOutcomeHeader},
			},
			Body: pr,
		}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.StreamingIdleMS = 5000
		cfg.Timeouts.CoordinatorRequestSeconds = 10
		cfg.Timeouts.CoordinatorHeaderTimeoutSeconds = 10
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
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
	case <-firstFrame:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for usage-only frame")
	}
	select {
	case <-cancelSeen:
	case <-time.After(2 * time.Second):
		t.Fatal("upstream did not observe buyer deadline")
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("gateway did not finish after buyer deadline")
	}

	if resp.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", resp.Code, resp.Body.String())
	}
	got := gatewaySettlementSnapshot(t, dbPath, accountID)
	if got.usageRows != 0 || got.settledRows != 0 || got.activeRows != 1 || got.heldRows != 1 {
		t.Fatalf("settlement snapshot=%+v, want declared client deadline held without local usage row", got)
	}
}

func TestSettleFromUsage_MalformedSSEChunk(t *testing.T) {
	runStreamingUsageSettlementCase(t, streamingUsageSettlementCase{
		accountID:      "acct_usage_malformed_sse",
		model:          "llama",
		contentBytes:   120,
		malformed:      true,
		maxTokens:      128,
		wantOutcome:    "stream_malformed",
		wantSource:     "gateway_estimated",
		wantCompletion: 30,
	})
}

type streamingUsageSettlementCase struct {
	accountID      string
	model          string
	contentBytes   int
	chunks         int
	reportedPrompt int64
	reportedComp   int64
	noUsage        bool
	invalidUsage   bool
	malformed      bool
	streamErr      error
	failWriteAt    int
	maxTokens      int64
	wantOutcome    string
	wantSource     string
	wantCompletion int64
	wantPrompt     int64
}

func runStreamingUsageSettlementCase(t *testing.T, c streamingUsageSettlementCase) {
	t.Helper()
	body := fmt.Sprintf(`{"model":%q,"stream":true,"max_tokens":%d,"messages":[{"role":"user","content":"ok"}]}`, c.model, c.maxTokens)
	payload := streamingUsagePayload(c)
	ctx := context.Background()
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		header := http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}
		if c.streamErr != nil {
			pr, pw := io.Pipe()
			go func() {
				_, _ = pw.Write([]byte(payload))
				_ = pw.CloseWithError(c.streamErr)
			}()
			return &http.Response{StatusCode: http.StatusOK, Header: header, Body: pr}, nil
		}
		return responseWithBody(http.StatusOK, header, payload), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, c.accountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	var resp http.ResponseWriter = recorder
	if c.failWriteAt > 0 {
		resp = &failingResponseWriter{ResponseWriter: recorder, failAt: c.failWriteAt}
	}
	h.ServeHTTP(resp, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("stream response code=%d body=%s", recorder.Code, recorder.Body.String())
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, c.accountID)
	if outcome != c.wantOutcome || source != c.wantSource || completion != c.wantCompletion {
		t.Fatalf("usage row outcome/source/completion = %s/%s/%d, want %s/%s/%d; body=%s", outcome, source, completion, c.wantOutcome, c.wantSource, c.wantCompletion, recorder.Body.String())
	}
	if c.wantSource == "provider_reported" && prompt != c.wantPrompt {
		t.Fatalf("usage row prompt_tokens = %d, want %d", prompt, c.wantPrompt)
	}
}

func streamingUsagePayload(c streamingUsageSettlementCase) string {
	output := strings.Repeat("x", c.contentBytes)
	chunks := c.chunks
	if chunks <= 0 {
		chunks = 1
	}
	parts := make([]string, 0, chunks+3)
	for i := 0; i < chunks; i++ {
		start := i * len(output) / chunks
		end := (i + 1) * len(output) / chunks
		parts = append(parts, `data: {"id":"chatcmpl","choices":[{"delta":{"content":"`+output[start:end]+`"},"finish_reason":null}]}`)
	}
	switch {
	case c.malformed:
		parts = append(parts, `data: not-json`)
	case c.invalidUsage:
		parts = append(parts, `data: {"id":"chatcmpl","usage":{"prompt_tokens":0,"completion_tokens":-5,"total_tokens":-5},"choices":[{"delta":{},"finish_reason":"stop"}]}`)
	case !c.noUsage:
		parts = append(parts, fmt.Sprintf(`data: {"id":"chatcmpl","usage":{"prompt_tokens":%d,"completion_tokens":%d,"total_tokens":%d},"choices":[{"delta":{},"finish_reason":"stop"}]}`, c.reportedPrompt, c.reportedComp, c.reportedPrompt+c.reportedComp))
	}
	if !c.malformed && c.streamErr == nil {
		parts = append(parts, `data: [DONE]`, ``)
	}
	return strings.Join(parts, "\n\n")
}

func usageEventOutcomeAndTokens(t *testing.T, dbPath, accountID string) (outcome, source string, completion, prompt int64) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	if err := db.QueryRow(`SELECT outcome, token_source, completion_tokens, prompt_tokens FROM usage_events WHERE account_id = ? ORDER BY created_at DESC LIMIT 1`, accountID).Scan(&outcome, &source, &completion, &prompt); err != nil {
		t.Fatalf("query usage row: %v", err)
	}
	return outcome, source, completion, prompt
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
	if _, ok := body["version"]; !ok {
		t.Fatalf("/healthz must include version key; body=%v", body)
	}
	if body["version"] != "dev" {
		t.Fatalf("/healthz version=%q, want default \"dev\"", body["version"])
	}
}

func TestHealthzReportsInjectedVersion(t *testing.T) {
	_, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(noopClient()))
	h := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient()), WithVersion("v1.3.0-7-gabcdef0")).Handler()
	resp := assertStatus(t, h, http.MethodGet, "/healthz", "", "", "", http.StatusOK)
	var body map[string]string
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("health json: %v", err)
	}
	if body["version"] != "v1.3.0-7-gabcdef0" {
		t.Fatalf("/healthz did not surface injected version; body=%v", body)
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

// TestHealthzAcceptsHEAD is L1 (finding, 3-lane re-audit of PR #548): a plain
// httptest.ResponseRecorder does not strip the HEAD response body the way
// the real net/http transport does, so this drives an actual
// httptest.NewServer to catch a regression a recorder-based test would miss
// (mirrors the fix already applied to the coordinator's equivalent test).
func TestHealthzAcceptsHEAD(t *testing.T) {
	_, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(noopClient()))
	h := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()
	ts := httptest.NewServer(h)
	defer ts.Close()

	headResp := doHealthzHEAD(t, ts.URL)
	defer headResp.Body.Close()
	if headResp.StatusCode != http.StatusOK {
		t.Fatalf("HEAD /healthz status = %d, want 200", headResp.StatusCode)
	}
	headBody, _ := io.ReadAll(headResp.Body)
	if len(headBody) != 0 {
		t.Fatalf("HEAD /healthz must return no body; got %q", headBody)
	}

	// GET/HEAD header parity: HEAD must not diverge from GET on the headers
	// that matter (status code path), confirming HEAD isn't quietly routed
	// through a different, unmaintained code path.
	getResp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("healthz GET: %v", err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != headResp.StatusCode {
		t.Fatalf("GET status = %d, HEAD status = %d, want parity", getResp.StatusCode, headResp.StatusCode)
	}
}

// TestHealthzHEADReturns503WhenDBUnreachable is L1's "503 db-unavailable HEAD
// path": HEAD must surface the same 503 GET does when the DB ping fails, and
// still carry no body.
func TestHealthzHEADReturns503WhenDBUnreachable(t *testing.T) {
	_, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(noopClient()))
	h := New(cfg, failingPingStore{Store: store}, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()
	ts := httptest.NewServer(h)
	defer ts.Close()

	resp := doHealthzHEAD(t, ts.URL)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("HEAD /healthz status = %d, want 503", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if len(body) != 0 {
		t.Fatalf("HEAD /healthz must return no body even on 503; got %q", body)
	}
}

func doHealthzHEAD(t *testing.T, baseURL string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodHead, baseURL+"/healthz", nil)
	if err != nil {
		t.Fatalf("new HEAD request: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("healthz HEAD: %v", err)
	}
	return resp
}

// TestGatewayRetryableByCodeClassification asserts the gateway's own
// transient/permanent split (finding H1, mirrors the coordinator's
// spec018RetryableByCode / TestRetryableByCodeClassification).
func TestGatewayRetryableByCodeClassification(t *testing.T) {
	retryable := []string{
		"no_provider_available", "provider_error", "provider_timeout",
		"provider_disconnected", "provider_failed", "provisional_quota_exceeded",
		"preflight_rejected", "idempotency_unavailable", "rate_limited",
		"coordinator_unavailable", "upstream_provider_error", "invalid_provider_usage",
		// Round-2 sweep (H-R2 + rate_limit_exceeded-family extension), as
		// narrowed by round-3's SECURITY MEDIUM revert and runbook item 20:
		// only the codes that actually ship a Retry-After/reset header stay
		// true (signup_rate_limited moved to permanent in item 20 — no
		// header, outside the chat-path clamp).
		"account_request_rate_exceeded", "account_concurrency_exceeded",
		"demo_concurrency_exceeded", "quota_exhausted",
		// Round-2 sweep (M-R2-3 + capacity-pause extension): wording on all
		// three already promises the buyer this resolves with time.
		"public_api_paused", "demo_paused", "capacity_signup_closed",
	}
	for _, code := range retryable {
		if !gatewayRetryable(code) {
			t.Errorf("code %q must be retryable=true", code)
		}
	}
	permanent := []string{
		"model_not_found", "invalid_request", "method_not_allowed",
		"invalid_api_key", "not_found", "request_content_encoding_unsupported",
		"api_key_lookup_failed", "feedback_limit_check_failed", "settlement_failed",
		// Round-3 SECURITY MEDIUM revert + runbook item 20: no Retry-After/reset
		// header and no account-level rate clamp on these paths — retryable:true
		// would invite SDK auto-retry hot-looping (DoS amplifier).
		"feedback_rate_limited", "oauth_state_rate_limited", "demo_session_rate_limited",
		"signup_rate_limited",
	}
	for _, code := range permanent {
		if gatewayRetryable(code) {
			t.Errorf("code %q must be retryable=false", code)
		}
	}
}

// gatewayEmittedErrorCodes is every literal string passed as the `code`
// argument to writeError, writeSSEError, or writeSpec019PreflightError
// across the non-test .go files in this package, as of the round-2 3-lane
// re-audit grep sweep of PR #548
// (`grep -oE 'writeError\(w, [a-zA-Z0-9._]+, "[a-zA-Z0-9_]+", "[a-zA-Z0-9_]+"'
// internal/router/*.go`, plus the writeSSEError/writeSpec019PreflightError
// call sites and the one variable-resolved code, concurrencyErrCode, which
// is always either account_concurrency_exceeded or demo_concurrency_exceeded).
// Deriving this list is NOT automatic (a genuinely new call site with a
// genuinely new code must be added here by hand) — its value is asserting
// the CURRENT known set has no silent gaps, and giving the next audit
// round a single, greppable checklist to diff a fresh sweep against.
var gatewayEmittedErrorCodes = []string{
	"account_blocked", "account_concurrency_exceeded", "account_create_failed",
	"account_lookup_failed", "account_request_rate_exceeded", "admin_state_write_failed",
	"api_key_issuance_failed", "api_key_lookup_failed", "api_key_not_found",
	"api_key_revoke_failed", "api_key_revoked", "api_key_rotation_failed",
	"capacity_signal_load_failed", "capacity_signal_store_failed", "capacity_signup_closed",
	"capacity_tier_load_failed", "comment_too_long", "concurrency_reservation_failed",
	"coordinator_models_error", "coordinator_sticky_error", "coordinator_unavailable",
	"demo_concurrency_exceeded", "demo_paused", "demo_session_check_failed",
	"demo_session_rate_limited", "demo_session_record_failed", "demo_token_issuance_failed",
	"docs_missing", "docs_render_failed", "duplicate_request_id",
	"feedback_limit_check_failed", "feedback_rate_limited", "feedback_store_failed",
	"feedback_summary_failed", "identity_create_failed", "internal_error",
	"invalid_api_key", "invalid_capacity_signal", "invalid_conversation_tag",
	"invalid_demo_token", "invalid_feedback", "invalid_feedback_scope",
	"invalid_feedback_source", "invalid_handoff", "invalid_kill_switch",
	"invalid_kill_switch_version", "invalid_limit", "invalid_operator_token",
	"invalid_provider_usage", "invalid_rating", "invalid_request",
	"invalid_provider_response", "invalid_request_body", "invalid_request_id", "invalid_window",
	"keys_load_failed", "max_tokens_exceeded", "method_not_allowed",
	"missing_bearer_token", "n_must_be_1", "no_provider_available",
	"nonce_unavailable", "not_found", "oauth_action_unknown",
	"oauth_callback_not_allowed", "oauth_exchange_failed", "oauth_return_to_not_allowed",
	"oauth_scope_forbidden", "oauth_state_invalid", "oauth_state_rate_limited",
	"oauth_state_store_failed", "provider_disconnected", "provider_timeout",
	"public_api_paused", "query_timeout", "quota_exhausted",
	"quota_reservation_failed", "request_content_encoding_unsupported", "request_too_large",
	"session_generation_failed", "session_id_untyped", "settlement_failed",
	"settlement_reconcile_load_failed", "signup_event_failed", "signup_limit_check_failed",
	"signup_rate_limited", "state_generation_failed", "stream_malformed",
	"stream_output_exceeded", "stream_truncated", "tier2_metadata_unavailable",
	"token_limit_overflow", "upstream_provider_error", "usage_load_failed",
}

// TestGatewayErrorCodeCompleteness closes L-R2-2 (round-2 3-lane re-audit):
// every code in gatewayEmittedErrorCodes must be triaged into EXACTLY one
// of gatewayRetryableByCode or gatewayPermanentCodes — never both (that
// would mean the two maps disagree) and never neither (that's exactly how
// H1/H-R2 happened: an emitted code silently fell through Go's map
// zero-value to false with nobody having decided it should).
//
// Limitation (carried, round-3 finding #4, also in SPEC-006 §5.2): this
// guards the CURRENT hand-curated inventory in gatewayEmittedErrorCodes,
// not future ones. Adding a new writeError/writeSSEError call site with a
// new code does not fail this test by itself — it only fails once someone
// adds that code to gatewayEmittedErrorCodes without a matching map entry.
// Nothing here parses the .go source at test time to discover a new call
// site automatically; a proper AST/registration-based guard (the round-3
// coordinator-side finding that a hand-curated list can itself silently
// go stale, as gatewayEmittedErrorCodes almost did) is a separate
// follow-up, not implemented here.
func TestGatewayErrorCodeCompleteness(t *testing.T) {
	for _, code := range gatewayEmittedErrorCodes {
		_, inRetryable := gatewayRetryableByCode[code]
		_, inPermanent := gatewayPermanentCodes[code]
		if !inRetryable && !inPermanent {
			t.Errorf("code %q is emitted but triaged into neither gatewayRetryableByCode nor gatewayPermanentCodes — classify it explicitly", code)
		}
		if inRetryable && inPermanent {
			t.Errorf("code %q is in BOTH gatewayRetryableByCode and gatewayPermanentCodes — remove it from one", code)
		}
	}
}

// TestWriteErrorEnvelopeCarriesRetryable is H1: writeError (the gateway's
// generic JSON error writer) must stamp retryable on every envelope, not
// just the ones the coordinator forwards verbatim.
func TestWriteErrorEnvelopeCarriesRetryable(t *testing.T) {
	cases := []struct {
		code string
		want bool
	}{
		{"coordinator_unavailable", true},
		{"provider_timeout", true},
		{"upstream_provider_error", true},
		{"invalid_provider_usage", true},
		{"model_not_found", false},
		{"method_not_allowed", false},
	}
	for _, tc := range cases {
		rr := httptest.NewRecorder()
		writeError(rr, http.StatusServiceUnavailable, "service_unavailable", tc.code, "x")
		var env struct {
			Error struct {
				Code      string `json:"code"`
				Retryable bool   `json:"retryable"`
			} `json:"error"`
		}
		if err := json.Unmarshal(rr.Body.Bytes(), &env); err != nil {
			t.Fatalf("code %q: bad envelope: %v", tc.code, err)
		}
		if env.Error.Retryable != tc.want {
			t.Errorf("code %q: retryable=%v, want %v", tc.code, env.Error.Retryable, tc.want)
		}
	}
}

// TestWriteErrorSetsRetryAfterOnlyForRetryableAvailability is M4: a modest,
// bounded Retry-After hint accompanies 503/504 responses that are
// retryable, but not permanent-error statuses (400/404/etc.) and not
// retryable=false 503s. Round-2 sweep adds the code-aware Retry-After cases
// (M-R2-2 provisional_quota_exceeded 3600s passthrough default via
// writeError directly, and M-R2-3's pause-appropriate 30s, distinct from
// the generic 1s fast-availability default).
func TestWriteErrorSetsRetryAfterOnlyForRetryableAvailability(t *testing.T) {
	cases := []struct {
		name       string
		status     int
		code       string
		wantHeader string
	}{
		{"503_transient", http.StatusServiceUnavailable, "coordinator_unavailable", "1"},
		{"504_transient", http.StatusGatewayTimeout, "provider_timeout", "1"},
		{"503_permanent_code_absent_from_map", http.StatusServiceUnavailable, "settlement_failed", ""},
		{"400_not_availability_status", http.StatusBadRequest, "invalid_request", ""},
		{"503_capacity_pause_gets_30s_not_1s", http.StatusServiceUnavailable, "public_api_paused", "30"},
		{"503_demo_pause_gets_30s_not_1s", http.StatusServiceUnavailable, "demo_paused", "30"},
		{"503_signup_closed_gets_30s_not_1s", http.StatusServiceUnavailable, "capacity_signup_closed", "30"},
		{"429_provisional_quota_gets_3600s_not_suppressed", http.StatusTooManyRequests, "provisional_quota_exceeded", "3600"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rr := httptest.NewRecorder()
			writeError(rr, tc.status, "api_error", tc.code, "x")
			if got := rr.Header().Get("Retry-After"); got != tc.wantHeader {
				t.Fatalf("Retry-After = %q, want %q", got, tc.wantHeader)
			}
		})
	}
}

// TestWriteSSEErrorCarriesRetryable is H1's SSE-writer half: mid-stream
// error frames must also carry retryable, classified the same way as the
// JSON writer.
func TestWriteSSEErrorCarriesRetryable(t *testing.T) {
	cases := []struct {
		code string
		want bool
	}{
		{"provider_disconnected", true},
		{"provider_timeout", true},
		{"stream_malformed", false},
	}
	for _, tc := range cases {
		rr := httptest.NewRecorder()
		writeSSEError(rr, "x", "api_error", tc.code)
		if !bytes.Contains(rr.Body.Bytes(), []byte(`"retryable":`+boolString(tc.want))) {
			t.Errorf("code %q: body = %s, want retryable=%v", tc.code, rr.Body.String(), tc.want)
		}
	}
}

// TestWriteStructuredOutputTimeoutSSERetryable is H2: the gateway's
// SPEC-019 wall-clock structured-output timeout emits the same
// provider_timeout code the coordinator uses, and must agree with the
// coordinator's retryable=true classification for that code — previously
// hardcoded to false, contradicting it.
func TestWriteStructuredOutputTimeoutSSERetryable(t *testing.T) {
	rr := httptest.NewRecorder()
	writeStructuredOutputTimeoutSSE(rr, "req-1")
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"provider_timeout"`)) {
		t.Fatalf("body missing provider_timeout code: %s", rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"retryable":true`)) {
		t.Fatalf("provider_timeout structured-output timeout must be retryable=true: %s", rr.Body.String())
	}
}

// TestCoordinatorErrorRetryablePreservesForwardedBody is H1's "preserve the
// coordinator's retryable" half: when the coordinator's own body carries a
// retryable verdict, the gateway must surface that exact value rather than
// recompute one — this matters because the coordinator can override a
// code's default classification per-response (SPEC-019 end.Retryable).
func TestCoordinatorErrorRetryablePreservesForwardedBody(t *testing.T) {
	// Coordinator explicitly overrode a normally-transient code to false.
	overridden := []byte(`{"error":{"code":"provider_error","retryable":false}}`)
	if got := coordinatorErrorRetryable(http.StatusBadGateway, overridden); got != false {
		t.Fatalf("coordinatorErrorRetryable with explicit false override = %v, want false", got)
	}
	// Coordinator body present but omits retryable entirely: fall back to
	// classifying by code using the gateway's own table.
	noField := []byte(`{"error":{"code":"provider_timeout"}}`)
	if got := coordinatorErrorRetryable(http.StatusGatewayTimeout, noField); got != true {
		t.Fatalf("coordinatorErrorRetryable fallback for provider_timeout = %v, want true", got)
	}
	// Same fallback for a coordinator-only code the gateway never
	// constructs itself (provisional_quota_exceeded) — proves the
	// gatewayRetryableByCode mirror is complete enough that the fallback
	// path doesn't silently reintroduce H2 for codes the gateway only
	// ever sees via a malformed/legacy forwarded body.
	noFieldQuota := []byte(`{"error":{"code":"provisional_quota_exceeded"}}`)
	if got := coordinatorErrorRetryable(http.StatusTooManyRequests, noFieldQuota); got != true {
		t.Fatalf("coordinatorErrorRetryable fallback for provisional_quota_exceeded = %v, want true", got)
	}
	// Empty body 503 (the synthetic no_provider_available fallback case).
	if got := coordinatorErrorRetryable(http.StatusServiceUnavailable, nil); got != true {
		t.Fatalf("coordinatorErrorRetryable empty-body 503 = %v, want true (no_provider_available)", got)
	}
}

func boolString(b bool) string {
	if b {
		return "true"
	}
	return "false"
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
	// Post PR #87 item 3: service_token is REQUIRED for /internal/* upstream
	// calls and the gateway sends it via UpstreamCoordinatorBearer().
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Explorer.Enabled = true
	cfg.Proxy.TrustedCIDRs = []string{"127.0.0.0/8", "::1/128", "192.0.2.0/24"}
	cfg.Auth.OAuth.CallbackAllowlist = []string{"https://api.streamvc.live/auth/github/callback"}
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	if mutate != nil {
		mutate(&cfg)
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

func usageEventOutcome(t *testing.T, dbPath, accountID string) (string, string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	var outcome, source string
	if err := db.QueryRow(`SELECT outcome, token_source FROM usage_events WHERE account_id = ? ORDER BY created_at DESC LIMIT 1`, accountID).Scan(&outcome, &source); err != nil {
		t.Fatalf("query usage outcome: %v", err)
	}
	return outcome, source
}

type gatewaySettlementState struct {
	usageRows      int64
	settledRows    int64
	refundedRows   int64
	expiredRows    int64
	staleHeldRows  int64
	activeRows     int64
	activeReserved int64
	heldRows       int64
}

func gatewaySettlementSnapshot(t *testing.T, dbPath, accountID string) gatewaySettlementState {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	var state gatewaySettlementState
	if err := db.QueryRow(`SELECT COUNT(*) FROM usage_events WHERE account_id = ?`, accountID).Scan(&state.usageRows); err != nil {
		t.Fatalf("query usage_events count: %v", err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM quota_reservations WHERE account_id = ? AND status = 'settled'`, accountID).Scan(&state.settledRows); err != nil {
		t.Fatalf("query settled reservations count: %v", err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM quota_reservations WHERE account_id = ? AND status = 'refunded'`, accountID).Scan(&state.refundedRows); err != nil {
		t.Fatalf("query refunded reservations count: %v", err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM quota_reservations WHERE account_id = ? AND status = 'expired'`, accountID).Scan(&state.expiredRows); err != nil {
		t.Fatalf("query expired reservations count: %v", err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM quota_reservations WHERE account_id = ? AND status = 'stale_held'`, accountID).Scan(&state.staleHeldRows); err != nil {
		t.Fatalf("query stale-held reservations count: %v", err)
	}
	if err := db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(reserved_tokens), 0) FROM quota_reservations WHERE account_id = ? AND status = 'active'`, accountID).Scan(&state.activeRows, &state.activeReserved); err != nil {
		t.Fatalf("query active reservations: %v", err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM quota_reservations WHERE account_id = ? AND status = 'active' AND settlement_hold = 1`, accountID).Scan(&state.heldRows); err != nil {
		t.Fatalf("query held reservations count: %v", err)
	}
	return state
}

func gatewayReservationExpiresAtUnixMS(t *testing.T, dbPath, accountID string) int64 {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	var raw string
	if err := db.QueryRow(`SELECT expires_at FROM quota_reservations WHERE account_id = ? ORDER BY created_at DESC LIMIT 1`, accountID).Scan(&raw); err != nil {
		t.Fatalf("query reservation expires_at: %v", err)
	}
	expiresAt, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		t.Fatalf("parse reservation expires_at %q: %v", raw, err)
	}
	return expiresAt.UnixMilli()
}

func gatewayReservationExpiresAtUnixMSForRequest(t *testing.T, dbPath, accountID, requestID string) int64 {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	var raw string
	if err := db.QueryRow(`SELECT expires_at FROM quota_reservations WHERE account_id = ? AND request_id = ? ORDER BY created_at DESC LIMIT 1`, accountID, requestID).Scan(&raw); err != nil {
		t.Fatalf("query reservation expires_at: %v", err)
	}
	expiresAt, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		t.Fatalf("parse reservation expires_at %q: %v", raw, err)
	}
	return expiresAt.UnixMilli()
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
	req.Header.Set("X-Feedback-Source", "test")
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
coordinator:
  buyer_url: http://coordinator.test
  operator_url: http://operator.test
  operator_key: operator-key
  service_token: service-token
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
  coordinator_header_timeout_seconds: 300
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

// assertBodyRetryable is the round-2 sweep's "retryable agrees with
// Retry-After/reset header" check: callers pair it with an assertion on
// whatever backoff header the path sets (Retry-After, X-RateLimit-Reset*).
func assertBodyRetryable(t *testing.T, raw string, want bool) {
	t.Helper()
	var body struct {
		Error struct {
			Retryable bool `json:"retryable"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &body); err != nil {
		t.Fatalf("error json: %v body=%s", err, raw)
	}
	if body.Error.Retryable != want {
		t.Fatalf("retryable=%v want=%v body=%s", body.Error.Retryable, want, raw)
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

// TestWriteErrorEnvelopeShape verifies the gateway writeError emits the
// canonical OpenAI-compatible error envelope: message, type, param, code,
// plus retryable (SPEC-006 §5.2 amendment, finding H1 3-lane re-audit of
// PR #548: every buyer error envelope MUST carry retryable, not just the
// ones the coordinator forwards verbatim). The 4-field shape predates that
// amendment; this test's allowed-key set was widened by one, deliberately,
// not loosened to paper over a bug.
func TestWriteErrorEnvelopeShape(t *testing.T) {
	w := httptest.NewRecorder()
	writeError(w, http.StatusBadRequest, "invalid_request_error", "test_code", "test message")

	var outer map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &outer); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, w.Body.String())
	}
	errObj, ok := outer["error"].(map[string]any)
	if !ok {
		t.Fatalf("missing 'error' key or wrong type; body=%s", w.Body.String())
	}
	for _, required := range []string{"message", "type", "code", "retryable"} {
		if _, present := errObj[required]; !present {
			t.Errorf("missing required key %q in error envelope; body=%s", required, w.Body.String())
		}
	}
	// param must be present (may be null)
	if _, present := errObj["param"]; !present {
		t.Errorf("missing 'param' key in error envelope; body=%s", w.Body.String())
	}
	// no extra keys beyond the 5-field set
	allowed := map[string]bool{"message": true, "type": true, "param": true, "code": true, "retryable": true}
	for k := range errObj {
		if !allowed[k] {
			t.Errorf("unexpected extra key %q in error envelope", k)
		}
	}
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

type cancelingReadCloser struct {
	cancel func()
	err    error
}

func (r cancelingReadCloser) Read(_ []byte) (int, error) {
	r.cancel()
	return 0, r.err
}

func (r cancelingReadCloser) Close() error {
	return nil
}

type failingResponseWriter struct {
	http.ResponseWriter
	writes int
	failAt int
}

func (w *failingResponseWriter) Write(p []byte) (int, error) {
	w.writes++
	if w.writes >= w.failAt {
		return 0, errors.New("forced buyer write failure")
	}
	return w.ResponseWriter.Write(p)
}

type cancelAfterChunksReadCloser struct {
	chunks [][]byte
	cancel func()
	done   bool
}

func (r *cancelAfterChunksReadCloser) Read(p []byte) (int, error) {
	if len(r.chunks) > 0 {
		n := copy(p, r.chunks[0])
		r.chunks[0] = r.chunks[0][n:]
		if len(r.chunks[0]) == 0 {
			r.chunks = r.chunks[1:]
		}
		return n, nil
	}
	if !r.done {
		r.done = true
		r.cancel()
		return 0, context.Canceled
	}
	return 0, io.EOF
}

func (r *cancelAfterChunksReadCloser) Close() error {
	return nil
}

func splitSSEPayloadChunks(payload string) [][]byte {
	frames := strings.SplitAfter(payload, "\n\n")
	chunks := make([][]byte, 0, len(frames))
	for _, frame := range frames {
		if frame != "" {
			chunks = append(chunks, []byte(frame))
		}
	}
	return chunks
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

// TestCoordinator404ModelNotFoundPassesThroughAndDoesNotChargeQuota pins
// the audit-driven UX fix: when the coordinator returns 404 model_not_found
// (no provider has advertised the requested model — no provider was reached),
// the gateway MUST:
//
//	(a) return 404 with the coord's OpenAI-shaped error body verbatim,
//	    NOT map to 502 upstream_provider_error (a typo on the buyer side
//	    should not look like a server-side outage);
//	(b) refund the quota reservation (zero buyer-quota charge), since no
//	    provider work was done — settling prompt-tokens on this path used
//	    to silently burn ~2.5 tokens per typo'd request.
//
// Regression-locks the bug surfaced by the SPEC-004 stress test (Layer 4
// quota race + Layer 3 single-shot 502 with bearer). Verified via
// fix-stash test on stage as well.
func TestCoordinator404ModelNotFoundPassesThroughAndDoesNotChargeQuota(t *testing.T) {
	for _, stream := range []bool{false, true} {
		name := "non_stream"
		if stream {
			name = "stream"
		}
		t.Run(name, func(t *testing.T) {
			// Mock coord returns the OpenAI-shaped 404 we observed live.
			coordBody := `{"error":{"code":"model_not_found","message":"No provider has advertised model nope-model","param":null,"type":"invalid_request_error"}}`
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return responseWithBody(http.StatusNotFound, http.Header{"Content-Type": []string{"application/json"}}, coordBody), nil
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			fullKey := createAccountAndKey(t, store, cfg, "acct_typo_"+name)

			body := `{"model":"nope-model","max_tokens":1000,"messages":[{"role":"user","content":"x"}]}`
			if stream {
				body = `{"model":"nope-model","max_tokens":1000,"stream":true,"messages":[{"role":"user","content":"x"}]}`
			}
			resp := postChat(t, h, fullKey, body, nil)

			// (a) Status MUST be 404, not 502.
			if resp.Code != http.StatusNotFound {
				t.Fatalf("status=%d body=%s — coord 404 must pass through, NOT map to 502", resp.Code, resp.Body.String())
			}
			// Body MUST be the OpenAI-shaped error from the coord, verbatim
			// (preserves the actionable "No provider has advertised model X"
			// message that lets buyers fix their typo).
			if !strings.Contains(resp.Body.String(), `"code":"model_not_found"`) {
				t.Fatalf("body=%s — expected coord's model_not_found body to pass through verbatim", resp.Body.String())
			}
			if !strings.Contains(resp.Body.String(), `"type":"invalid_request_error"`) {
				t.Fatalf("body=%s — body must preserve OpenAI-shaped error type=invalid_request_error", resp.Body.String())
			}
			// Must NOT contain the old upstream_provider_error wording.
			if strings.Contains(resp.Body.String(), "upstream_provider_error") {
				t.Fatalf("body=%s — must NOT use upstream_provider_error wording on a coord 404", resp.Body.String())
			}

			// (b) Quota MUST be unchanged — no prompt-token settlement on the
			// no-provider-reached path. Previously: ~2.5 tokens/request burn.
			usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
			quota := readQuota(t, usageResp)
			if used := quota["daily_tokens_used"].(float64); used != 0 {
				t.Fatalf("daily_tokens_used=%v, want 0 — coord 404 must not charge quota (no provider reached)", used)
			}
			if reserved := quota["daily_tokens_reserved"].(float64); reserved != 0 {
				t.Fatalf("daily_tokens_reserved=%v, want 0 — reservation must be refunded on coord 404", reserved)
			}
		})
	}
}

// routeSnapshotFailedCoordBody is the exact OpenAI-shaped envelope the
// coordinator emits for a pre-dispatch route_snapshot_failed: writeError →
// errorType(500)="upstream_error", spec018Retryable("route_snapshot_failed")=true,
// inference_ran/settlement_ran hardcoded false
// (phase4-coordinator/internal/buyer/server.go writeErrorTypedParam).
const routeSnapshotFailedCoordBody = `{"error":{"code":"route_snapshot_failed","inference_ran":false,"message":"Could not durably record route snapshot","param":null,"request_id":null,"retryable":true,"settlement_ran":false,"type":"upstream_error"}}
`

// TestCoordinatorRouteSnapshotFailedPreDispatchNoCharge pins item 18: a
// coordinator 500 route_snapshot_failed is emitted BEFORE any provider is
// dispatched (SPEC-022 durable route-snapshot write failure) with no
// settlement finality headers, so no inference ran. The gateway must refund
// the reservation and pass the body through verbatim — NOT settle on the
// prompt estimate (the old bug charged the buyer for a request no provider
// ever saw). Covers both streaming modes.
func TestCoordinatorRouteSnapshotFailedPreDispatchNoCharge(t *testing.T) {
	for _, stream := range []bool{false, true} {
		name := "non_stream"
		if stream {
			name = "stream"
		}
		t.Run(name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				// Genuine first attempt → coordinator emits the POSITIVE
				// no-prior-dispatch marker; the gateway refunds only then.
				hdr := http.Header{}
				hdr.Set("Content-Type", "application/json")
				hdr.Set("X-MacProvider-Settlement-No-Prior-Dispatch", "1")
				return responseWithBody(http.StatusInternalServerError, hdr, routeSnapshotFailedCoordBody), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			acct := "acct_route_snap_" + name
			fullKey := createAccountAndKey(t, store, cfg, acct)

			body := `{"model":"model-a","max_tokens":1000,"messages":[{"role":"user","content":"x"}]}`
			if stream {
				body = `{"model":"model-a","max_tokens":1000,"stream":true,"messages":[{"role":"user","content":"x"}]}`
			}
			resp := postChat(t, h, fullKey, body, nil)

			// (a) Status passes through as 500 with the coordinator body VERBATIM
			// — NOT mapped to a 502 upstream_provider_error (the settle path).
			if resp.Code != http.StatusInternalServerError {
				t.Fatalf("status=%d body=%s — route_snapshot_failed must pass through as 500, not map to 502", resp.Code, resp.Body.String())
			}
			if got := resp.Body.String(); got != routeSnapshotFailedCoordBody {
				t.Fatalf("body must be the coordinator envelope verbatim.\n got=%q\nwant=%q", got, routeSnapshotFailedCoordBody)
			}
			// (a2) retryable:true (the coordinator classifies this transient) is
			// preserved, and the gateway attaches NO Retry-After (no fixed backoff
			// for this code).
			assertBodyRetryable(t, resp.Body.String(), true)
			if got := resp.Header().Get("Retry-After"); got != "" {
				t.Fatalf("Retry-After=%q, want empty for route_snapshot_failed", got)
			}

			// (b) No charge: no provider was reached, so quota is unchanged and
			// the reservation is refunded.
			usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
			quota := readQuota(t, usageResp)
			if used := quota["daily_tokens_used"].(float64); used != 0 {
				t.Fatalf("daily_tokens_used=%v, want 0 — route_snapshot_failed must not charge (no provider reached)", used)
			}
			if reserved := quota["daily_tokens_reserved"].(float64); reserved != 0 {
				t.Fatalf("daily_tokens_reserved=%v, want 0 — reservation must be refunded on route_snapshot_failed", reserved)
			}
			// (c) The ledger records a zero-token refunded audit row keyed to the
			// coordinator code (not a settled charge).
			assertRefundedAuditOutcome(t, dbPath, acct, "route_snapshot_failed")
		})
	}
}

// TestCoordinatorRouteSnapshotFailedWithoutMarkerIsCharged pins the
// deployment-robust positive-marker design: a route_snapshot_failed that
// carries NO X-MacProvider-Settlement-No-Prior-Dispatch marker must settle on
// the estimate, NOT refund. This one case covers both (a) a coordinator-
// internal failover after a prior provider dispatch (the coordinator withholds
// the marker), and (b) a legacy / rolled-back pre-item-18 coordinator that
// never emits the marker — a gateway-first deploy must not wrongly refund.
func TestCoordinatorRouteSnapshotFailedWithoutMarkerIsCharged(t *testing.T) {
	for _, stream := range []bool{false, true} {
		name := "non_stream"
		if stream {
			name = "stream"
		}
		t.Run(name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				// No no-prior-dispatch marker (internal failover OR legacy coord).
				return responseWithBody(http.StatusInternalServerError, http.Header{"Content-Type": []string{"application/json"}}, routeSnapshotFailedCoordBody), nil
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			acct := "acct_route_snap_unmarked_" + name
			fullKey := createAccountAndKey(t, store, cfg, acct)

			body := `{"model":"model-a","max_tokens":8,"messages":[{"role":"user","content":"x"}]}`
			if stream {
				body = `{"model":"model-a","max_tokens":8,"stream":true,"messages":[{"role":"user","content":"x"}]}`
			}
			resp := postChat(t, h, fullKey, body, nil)

			// No marker → estimate-settle path → 502 upstream_provider_error.
			if resp.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s — an unmarked route_snapshot_failed must settle (502), not refund", resp.Code, resp.Body.String())
			}
			// Buyer IS charged the prompt estimate (prior work / legacy safety).
			usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
			if used := readQuota(t, usageResp)["daily_tokens_used"].(float64); used == 0 {
				t.Fatalf("daily_tokens_used=0 — an unmarked route_snapshot_failed must charge the estimate, not refund")
			}
		})
	}
}

// TestCoordinatorPreDispatchNoChargeErrorGuards pins the classifier directly:
// eligibility requires status 500 AND code route_snapshot_failed AND the
// POSITIVE X-MacProvider-Settlement-No-Prior-Dispatch marker AND the ABSENCE of
// every settlement-finality header. The positive marker is required (not the
// absence of a negative one) so an unmarked legacy/rolled-back-coordinator
// response is never refunded.
func TestCoordinatorPreDispatchNoChargeErrorGuards(t *testing.T) {
	body := []byte(`{"error":{"code":"route_snapshot_failed","type":"upstream_error"}}`)
	marked := func() http.Header {
		h := http.Header{}
		h.Set("X-MacProvider-Settlement-No-Prior-Dispatch", "1")
		return h
	}
	// Genuine first attempt (marker present) → eligible.
	if !coordinatorPreDispatchNoChargeError(http.StatusInternalServerError, body, marked()) {
		t.Fatal("marked 500 route_snapshot_failed must be no-charge eligible")
	}
	// The load-bearing inversion: NO marker → NOT eligible (legacy coordinator
	// or coordinator-internal failover → settle, never refund).
	if coordinatorPreDispatchNoChargeError(http.StatusInternalServerError, body, http.Header{}) {
		t.Fatal("an UNMARKED route_snapshot_failed must NOT be no-charge eligible (deploy-safety + internal-failover)")
	}
	// Marker present but a finality header also present → finality path owns it.
	for _, hdr := range []string{
		"X-MacProvider-Settlement-Outcome",
		"X-MacProvider-Settlement-Receipt-Result",
		"X-MacProvider-Settlement-Reason",
		"X-MacProvider-Settlement-Closed",
		"X-MacProvider-Settlement-Mode",
		"X-MacProvider-Settlement-Policy-Version",
		"X-MacProvider-Settlement-Pending-Deadline-Unix-Ms",
	} {
		h := marked()
		h.Set(hdr, "x")
		if coordinatorPreDispatchNoChargeError(http.StatusInternalServerError, body, h) {
			t.Fatalf("finality header %s present must disable no-charge eligibility (finality path owns it)", hdr)
		}
	}
	if coordinatorPreDispatchNoChargeError(http.StatusBadGateway, body, marked()) {
		t.Fatal("502 must not be no-charge eligible (that is the legacy-502 refund path)")
	}
	if coordinatorPreDispatchNoChargeError(http.StatusInternalServerError, []byte(`{"error":{"code":"internal_error"}}`), marked()) {
		t.Fatal("a non-route_snapshot 500 must not be no-charge eligible")
	}
}

// TestCoordinatorGeneric500StillSettlesUpstreamError is the narrowness guard
// for item 18: a 500 whose code is NOT route_snapshot_failed must keep the
// pre-existing settle-on-estimate → 502 upstream_provider_error behavior AND
// charge the prompt estimate, so the no-charge classifier is scoped to the
// pre-dispatch code alone.
func TestCoordinatorGeneric500StillSettlesUpstreamError(t *testing.T) {
	coordBody := `{"error":{"message":"boom","type":"upstream_error","param":null,"code":"internal_error"}}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusInternalServerError, http.Header{"Content-Type": []string{"application/json"}}, coordBody), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	acct := "acct_generic_500"
	fullKey := createAccountAndKey(t, store, cfg, acct)

	resp := postChat(t, h, fullKey, `{"model":"model-a","max_tokens":8,"messages":[{"role":"user","content":"x"}]}`, nil)

	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s — a non-route_snapshot 500 must keep mapping to 502", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "upstream_provider_error") {
		t.Fatalf("body=%s — generic 500 must still surface upstream_provider_error", resp.Body.String())
	}
	// The generic 500 settles on the prompt estimate (buyer IS charged).
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	if used := readQuota(t, usageResp)["daily_tokens_used"].(float64); used == 0 {
		t.Fatalf("daily_tokens_used=0 — a generic 500 must still settle the prompt estimate")
	}
}

// TestCoordinatorProvisionalQuotaExceededPreservesRetryAfter3600 is M-R2-2
// (round-2 3-lane re-audit of PR #548): the coordinator sets its own fixed
// Retry-After: 3600 on provisional_quota_exceeded, but copyCleanHeaders
// strips ANY upstream Retry-After as gateway-owned (issue #190) before the
// gateway forwards the coordinator's body verbatim. Without the
// gatewayRetryAfterByCode code-aware restore, the buyer would see
// retryable:true (correctly preserved from the coordinator's body) with
// ZERO backoff hint — a buyer honoring Retry-After and one honoring
// retryable would reach opposite conclusions about how long to wait.
func TestCoordinatorProvisionalQuotaExceededPreservesRetryAfter3600(t *testing.T) {
	coordBody := `{"error":{"message":"Selected provisional provider is over request quota","type":"rate_limit_exceeded","param":null,"code":"provisional_quota_exceeded","retryable":true,"request_id":null,"inference_ran":false,"settlement_ran":false}}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		// The coordinator's own upstream Retry-After — copyCleanHeaders
		// must strip this (issue #190); the gateway then restores its own
		// 3600s value via gatewayRetryAfterByCode, not by trusting this one.
		return responseWithBody(http.StatusTooManyRequests, http.Header{
			"Content-Type": []string{"application/json"},
			"Retry-After":  []string{"3600"},
		}, coordBody), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_provisional_quota")

	resp := postChat(t, h, fullKey, `{"model":"model-a","max_tokens":8,"messages":[{"role":"user","content":"x"}]}`, nil)

	if resp.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d, want 429 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "provisional_quota_exceeded")
	assertBodyRetryable(t, resp.Body.String(), true)
	if got := resp.Header().Get("Retry-After"); got != "3600" {
		t.Fatalf("Retry-After=%q, want 3600 (gatewayRetryAfterByCode must restore it after copyCleanHeaders strips the upstream value)", got)
	}
}

func TestCoordinatorPreStream502ProviderErrorAuditsZeroAndRefunds(t *testing.T) {
	for _, stream := range []bool{false, true} {
		name := "non_stream"
		if stream {
			name = "stream"
		}
		t.Run(name, func(t *testing.T) {
			coordBody := `{"error":{"code":"provider_error","message":"provider failed before streaming","param":null,"type":"api_error"}}`
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return responseWithBody(http.StatusBadGateway, http.Header{"Content-Type": []string{"application/json"}}, coordBody), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Retry503.MaxAttempts = 2
				cfg.Retry503.BackoffBaseMs = 10
				cfg.Retry503.BackoffMaxMs = 10
			}, WithHTTPClient(client))
			accountID := "acct_prestream_502_" + name
			fullKey := createAccountAndKey(t, store, cfg, accountID)

			body := `{"model":"model-a","max_tokens":1000,"messages":[{"role":"user","content":"x"}]}`
			if stream {
				body = `{"model":"model-a","max_tokens":1000,"stream":true,"messages":[{"role":"user","content":"x"}]}`
			}
			resp := postChat(t, h, fullKey, body, nil)

			if resp.Code != http.StatusBadGateway {
				t.Fatalf("status=%d, want 502 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "upstream_provider_error")
			usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
			quota := readQuota(t, usageResp)
			if used := quota["daily_tokens_used"].(float64); used != 0 {
				t.Fatalf("daily_tokens_used=%v, want 0", used)
			}
			if reserved := quota["daily_tokens_reserved"].(float64); reserved != 0 {
				t.Fatalf("daily_tokens_reserved=%v, want 0", reserved)
			}
			outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
			if outcome != "upstream_error" || source != "gateway_estimated" || prompt != 0 || completion != 0 {
				t.Fatalf("usage event outcome=%q source=%q prompt=%d completion=%d, want upstream_error/gateway_estimated/0/0", outcome, source, prompt, completion)
			}
		})
	}
}

func TestCoordinatorPreStream502ProviderErrorObserveModeKeepsLegacySettlement(t *testing.T) {
	for _, stream := range []bool{false, true} {
		name := "non_stream"
		if stream {
			name = "stream"
		}
		t.Run(name, func(t *testing.T) {
			headers := http.Header{"Content-Type": []string{"application/json"}}
			headers.Set(settlementModeHeader, "observe")
			assertPreStream502LegacySettlement(t, name, stream, "provider_error", headers)
		})
	}
}

func TestCoordinatorPreStream502NonProviderErrorKeepsLegacySettlement(t *testing.T) {
	for _, stream := range []bool{false, true} {
		name := "non_stream"
		if stream {
			name = "stream"
		}
		t.Run(name, func(t *testing.T) {
			assertPreStream502LegacySettlement(t, name, stream, "coordinator_internal_error", http.Header{"Content-Type": []string{"application/json"}})
		})
	}
}

func assertPreStream502LegacySettlement(t *testing.T, name string, stream bool, code string, headers http.Header) {
	t.Helper()
	coordBody := fmt.Sprintf(`{"error":{"code":%q,"message":"coordinator error before streaming","param":null,"type":"api_error"}}`, code)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusBadGateway, headers.Clone(), coordBody), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Retry503.Enabled = false
	}, WithHTTPClient(client))
	accountID := "acct_prestream_502_legacy_" + code + "_" + name
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	body := `{"model":"model-a","max_tokens":1000,"messages":[{"role":"user","content":"x"}]}`
	if stream {
		body = `{"model":"model-a","max_tokens":1000,"stream":true,"messages":[{"role":"user","content":"x"}]}`
	}
	resp := postChat(t, h, fullKey, body, nil)

	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d, want 502 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "upstream_provider_error")
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	wantPrompt := float64(estimatePromptTokens([]byte(body)))
	if used := quota["daily_tokens_used"].(float64); used != wantPrompt {
		t.Fatalf("daily_tokens_used=%v, want prompt estimate %v", used, wantPrompt)
	}
	if reserved := quota["daily_tokens_reserved"].(float64); reserved != 0 {
		t.Fatalf("daily_tokens_reserved=%v, want 0", reserved)
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
	if outcome != "upstream_error" || source != "gateway_estimated" || prompt != int64(wantPrompt) || completion != 0 {
		t.Fatalf("usage event outcome=%q source=%q prompt=%d completion=%d, want upstream_error/gateway_estimated/%d/0", outcome, source, prompt, completion, int64(wantPrompt))
	}
}

func TestCoordinatorGenericValidationErrorsPassThroughAndDoNotChargeQuota(t *testing.T) {
	cases := []struct {
		name   string
		status int
		code   string
	}{
		{"bad_request", http.StatusBadRequest, "invalid_request"},
		{"unprocessable", http.StatusUnprocessableEntity, "invalid_payload"},
	}
	for _, tc := range cases {
		for _, stream := range []bool{false, true} {
			name := tc.name + "_non_stream"
			if stream {
				name = tc.name + "_stream"
			}
			t.Run(name, func(t *testing.T) {
				coordBody := fmt.Sprintf(`{"error":{"code":%q,"message":"invalid buyer request","param":"messages","type":"invalid_request_error"}}`, tc.code)
				client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
					return responseWithBody(tc.status, http.Header{"Content-Type": []string{"application/json"}}, coordBody), nil
				})}
				h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
					cfg.Coordinator.BuyerURL = "http://coordinator.test"
				}, WithHTTPClient(client))
				fullKey := createAccountAndKey(t, store, cfg, "acct_generic_validation_"+name)

				body := `{"model":"model-a","max_tokens":1000,"messages":[{"role":"user","content":"x"}]}`
				if stream {
					body = `{"model":"model-a","max_tokens":1000,"stream":true,"messages":[{"role":"user","content":"x"}]}`
				}
				resp := postChat(t, h, fullKey, body, nil)

				if resp.Code != tc.status {
					t.Fatalf("status=%d, want %d body=%s", resp.Code, tc.status, resp.Body.String())
				}
				if !strings.Contains(resp.Body.String(), `"code":"`+tc.code+`"`) ||
					!strings.Contains(resp.Body.String(), `"type":"invalid_request_error"`) {
					t.Fatalf("body did not preserve coordinator validation envelope: %s", resp.Body.String())
				}
				if strings.Contains(resp.Body.String(), "upstream_provider_error") {
					t.Fatalf("body remapped coordinator validation error: %s", resp.Body.String())
				}
				usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
				quota := readQuota(t, usageResp)
				if used := quota["daily_tokens_used"].(float64); used != 0 {
					t.Fatalf("daily_tokens_used=%v, want 0", used)
				}
				if reserved := quota["daily_tokens_reserved"].(float64); reserved != 0 {
					t.Fatalf("daily_tokens_reserved=%v, want 0", reserved)
				}
			})
		}
	}
}

func TestCoordinatorTier2PolicyErrorsPassThroughAndDoNotChargeQuota(t *testing.T) {
	cases := []struct {
		name   string
		status int
		code   string
		typ    string
	}{
		{
			name:   "require_hash_verified",
			status: http.StatusServiceUnavailable,
			code:   "tier2_hash_verified_required",
			typ:    "server_error",
		},
		{
			name:   "hash_mismatch",
			status: http.StatusServiceUnavailable,
			code:   "tier2_hash_mismatch",
			typ:    "server_error",
		},
		{
			name:   "encrypted_leg_required",
			status: http.StatusServiceUnavailable,
			code:   "tier2_encrypted_leg_required",
			typ:    "server_error",
		},
		{
			name:   "attestation_required",
			status: http.StatusServiceUnavailable,
			code:   "tier2_attestation_required",
			typ:    "server_error",
		},
		{
			name:   "hard_pin_predicate",
			status: http.StatusBadRequest,
			code:   "tier2_hard_pin_predicate_failed",
			typ:    "invalid_request_error",
		},
	}
	for _, tc := range cases {
		for _, stream := range []bool{false, true} {
			name := tc.name + "_non_stream"
			if stream {
				name = tc.name + "_stream"
			}
			t.Run(name, func(t *testing.T) {
				coordBody := fmt.Sprintf(`{"error":{"code":%q,"message":"tier2 policy rejected request","param":null,"type":%q}}`, tc.code, tc.typ)
				client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
					return responseWithBody(tc.status, http.Header{"Content-Type": []string{"application/json"}}, coordBody), nil
				})}
				h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
					cfg.Coordinator.BuyerURL = "http://coordinator.test"
				}, WithHTTPClient(client))
				fullKey := createAccountAndKey(t, store, cfg, "acct_"+name)

				body := `{"model":"model-a","max_tokens":1000,"messages":[{"role":"user","content":"x"}]}`
				if stream {
					body = `{"model":"model-a","max_tokens":1000,"stream":true,"messages":[{"role":"user","content":"x"}]}`
				}
				resp := postChat(t, h, fullKey, body, nil)

				if resp.Code != tc.status {
					t.Fatalf("status=%d, want %d body=%s", resp.Code, tc.status, resp.Body.String())
				}
				if !strings.Contains(resp.Body.String(), `"code":"`+tc.code+`"`) ||
					!strings.Contains(resp.Body.String(), `"type":"`+tc.typ+`"`) {
					t.Fatalf("body did not preserve coordinator error envelope: %s", resp.Body.String())
				}
				if strings.Contains(resp.Body.String(), "provider_unavailable") || strings.Contains(resp.Body.String(), "upstream_provider_error") {
					t.Fatalf("body remapped coordinator Tier-2 policy error: %s", resp.Body.String())
				}
				usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
				quota := readQuota(t, usageResp)
				if used := quota["daily_tokens_used"].(float64); used != 0 {
					t.Fatalf("daily_tokens_used=%v, want 0", used)
				}
				if reserved := quota["daily_tokens_reserved"].(float64); reserved != 0 {
					t.Fatalf("daily_tokens_reserved=%v, want 0", reserved)
				}
			})
		}
	}
}

// TestCoordinatorIdempotencyReplayPassesThroughAndRefunds pins
// issue #200: when the coordinator returns 409
// idempotency_key_replayed (or idempotency_key_body_mismatch), the
// gateway MUST refund the reservation it made and pass the
// coordinator response body through verbatim. Pre-fix it fell
// through the generic !=200 branch, called settleBeforeResponse
// with outcome="upstream_error" (billing the buyer for the prompt
// estimate even though no provider work ran), and remapped the
// response to a 502.
func TestCoordinatorIdempotencyReplayPassesThroughAndRefunds(t *testing.T) {
	cases := []struct {
		name string
		code string
	}{
		{"replayed", "idempotency_key_replayed"},
		{"body_mismatch", "idempotency_key_body_mismatch"},
	}
	for _, tc := range cases {
		for _, stream := range []bool{false, true} {
			name := tc.name + "_non_stream"
			if stream {
				name = tc.name + "_stream"
			}
			t.Run(name, func(t *testing.T) {
				coordBody := fmt.Sprintf(`{"error":{"code":%q,"message":"idempotency","param":null,"type":"invalid_request_error"}}`, tc.code)
				client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
					return responseWithBody(http.StatusConflict, http.Header{"Content-Type": []string{"application/json"}}, coordBody), nil
				})}
				h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
					cfg.Coordinator.BuyerURL = "http://coordinator.test"
				}, WithHTTPClient(client))
				fullKey := createAccountAndKey(t, store, cfg, "acct_"+name)

				body := `{"model":"model-a","max_tokens":1000,"messages":[{"role":"user","content":"x"}]}`
				if stream {
					body = `{"model":"model-a","max_tokens":1000,"stream":true,"messages":[{"role":"user","content":"x"}]}`
				}
				resp := postChat(t, h, fullKey, body, nil)

				// (a) Buyer sees the coordinator 409 + envelope verbatim,
				//     NOT a remapped 502 / upstream_provider_error.
				if resp.Code != http.StatusConflict {
					t.Fatalf("status=%d, want 409, body=%s", resp.Code, resp.Body.String())
				}
				if !strings.Contains(resp.Body.String(), `"code":"`+tc.code+`"`) {
					t.Fatalf("body lost coord error envelope: %s", resp.Body.String())
				}
				if strings.Contains(resp.Body.String(), "upstream_provider_error") {
					t.Fatalf("body remapped to upstream_provider_error: %s", resp.Body.String())
				}

				// (b) No quota burn — refund must have fired.
				usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
				quota := readQuota(t, usageResp)
				if used := quota["daily_tokens_used"].(float64); used != 0 {
					t.Fatalf("daily_tokens_used=%v, want 0 — idempotency 409 must not charge quota", used)
				}
				if reserved := quota["daily_tokens_reserved"].(float64); reserved != 0 {
					t.Fatalf("daily_tokens_reserved=%v, want 0 — reservation must be refunded on idempotency 409", reserved)
				}
			})
		}
	}
}

func TestDuplicateGatewayReservationReturnsConflictWithoutRefund(t *testing.T) {
	requestID := "77777777-7777-4777-8777-777777777777"
	body := `{"model":"model-a","max_tokens":20,"messages":[{"role":"user","content":"x"}]}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		t.Fatalf("coordinator should not be called after duplicate reservation")
		return nil, nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_duplicate_reservation"
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      fixedNow().UTC().Format("2006-01-02"),
		RequestedTokens: 37,
		DailyQuota:      cfg.Quotas.AccountDailyTokens,
		CreatedAt:       fixedNow(),
		ExpiresAt:       fixedNow().Add(time.Hour),
	}); err != nil {
		t.Fatalf("pre-create reservation: %v", err)
	}

	resp := postChat(t, h, fullKey, body, map[string]string{"X-Request-ID": requestID})

	if resp.Code != http.StatusConflict {
		t.Fatalf("status=%d want 409 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "duplicate_request_id")
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	if reserved := quota["daily_tokens_reserved"].(float64); reserved != 37 {
		t.Fatalf("daily_tokens_reserved=%v want original duplicate reservation to remain active", reserved)
	}
	if used := quota["daily_tokens_used"].(float64); used != 0 {
		t.Fatalf("daily_tokens_used=%v want 0", used)
	}
}

// TestConversationKeyIsAccountScoped pins the structural cross-account
// collision guarantee: account A with tag T MUST derive a different conv:
// than account B with the same tag T. Regression-locks the SPEC-006 v0.8.1
// §1.3 HMAC account-scoping property (audit MED-3 / code-review MAJOR).
//
// CRITICAL: this test must call the PRODUCTION `deriveConversationKey`,
// not the test helper `expectedConversationKey`. The re-verify audit (a
// prior version of this test was a tautology) flagged that asserting
// "test helper has the property" doesn't pin "production has the
// property" — a regression dropping `accountID` from production's HMAC
// would silently allow cross-account routing of sticky traffic.
func TestConversationKeyIsAccountScoped(t *testing.T) {
	// Build a minimal Server purely to reach the production method; no
	// handler/store/auth plumbing is required — deriveConversationKey only
	// reads s.cfg.Auth.KeyHashSecret.
	cfg := config.Config{}
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	s := &Server{cfg: cfg}

	tag := "thread-1"
	a := s.deriveConversationKey("acct_alpha", tag)
	b := s.deriveConversationKey("acct_beta", tag)
	if a == b {
		t.Fatalf("cross-account collision: acct_alpha and acct_beta produce same production conv key %q — account_id missing from HMAC msg?", a)
	}
	// Same account + same tag → deterministic (sanity).
	if s.deriveConversationKey("acct_alpha", tag) != a {
		t.Fatal("same inputs produced different production keys — derivation is non-deterministic")
	}
	// Different tag on same account → different key (tag in HMAC msg).
	if s.deriveConversationKey("acct_alpha", "thread-2") == a {
		t.Fatal("different tag on same account produced same production key — tag missing from HMAC msg?")
	}
	// Cross-check: production output matches the test helper's expectation
	// (so a regression in production's HMAC scheme breaks BOTH this test
	// AND TestStickyConversationDerivesInternalHeaderAndStripsInjection).
	if a != expectedConversationKey("test-key-hash-secret", "acct_alpha", tag) {
		t.Fatalf("production deriveConversationKey diverged from expectedConversationKey helper — scheme drift")
	}
}

// TestStickyDeleteIsAccountScopedRegardlessOfQueryParam pins that DELETE
// /v1/sticky purges ONLY the authenticated caller's account, even if the
// caller smuggles an `?account_id=<other>` query param (which the
// coordinator-internal /internal/sticky endpoint accepts). The gateway MUST
// pin scoping to the authenticated subject, not the buyer-supplied query.
// Regression-locks the code-review MAJOR (cross-account purge scope).
func TestStickyDeleteIsAccountScopedRegardlessOfQueryParam(t *testing.T) {
	var captured *http.Request
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		captured = r
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"purged":true,"entries":0}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Routing.StickyEnabled = true
	}, WithHTTPClient(client))
	bobKey := createAccountAndKey(t, store, cfg, "acct_bob")

	// Bob attempts to purge alice's entries via query-param smuggling.
	req := httptest.NewRequest(http.MethodDelete, "/v1/sticky?account_id=acct_alice", nil)
	req.Header.Set("Authorization", "Bearer "+bobKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if captured == nil {
		t.Fatal("coordinator request not captured")
	}
	// The coordinator-bound request MUST carry Bob's account_id, not Alice's.
	if got := captured.URL.Query().Get("account_id"); got != "acct_bob" {
		t.Fatalf("smuggled account_id leaked to coordinator: got %q, want acct_bob (Bob cannot purge Alice's entries)", got)
	}
}

func TestInternalHeaderStripDoesNotAuditUnauthenticatedRequest(t *testing.T) {
	h, _, dbPath, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Routing.StickyEnabled = true
	})

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"llama","messages":[{"role":"user","content":"hi"}]}`))
	// Deliberately NO Authorization header — attacker probing without creds.
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-MacProvider-Internal-Conv", "conv:attacker")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	// Auth-required path must reject.
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for missing bearer, got %d body=%s", resp.Code, resp.Body.String())
	}
	if got := countAuditEvents(t, dbPath, "internal_header_injection_stripped"); got != 0 {
		t.Fatalf("audit event count = %d, want 0 for unauthenticated probe", got)
	}
}

func TestInternalHeaderStripAuditsAuthenticatedRequest(t *testing.T) {
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Routing.StickyEnabled = true
	}, WithHTTPClient(modelsOKClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_internal_header_auth")

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("X-MacProvider-Internal-Conv", "conv:attacker")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("expected 200 for authenticated models request, got %d body=%s", resp.Code, resp.Body.String())
	}
	if got := countAuditEvents(t, dbPath, "internal_header_injection_stripped"); got != 1 {
		t.Fatalf("audit event count = %d, want 1 for authenticated probe", got)
	}
}
