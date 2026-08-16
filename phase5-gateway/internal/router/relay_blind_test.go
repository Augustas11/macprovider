package router

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestRelayBlindModelsDisclosureDefaultOffOmitted(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_models_default")

	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusOK)
	var body struct {
		Tier1Disclosure tier1Disclosure `json:"tier1_disclosure"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("models json: %v", err)
	}
	if body.Tier1Disclosure.RelayBlindRequestEncryption != nil {
		t.Fatalf("relay-blind disclosure present while feature is default-off: %+v", body.Tier1Disclosure.RelayBlindRequestEncryption)
	}
}

func TestRelayBlindModelsDisclosureEnabledUnavailable(t *testing.T) {
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
	}, WithHTTPClient(modelsOKClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_models_enabled")

	resp := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "1.2.3.4", http.StatusOK)
	var body struct {
		Tier1Disclosure tier1Disclosure `json:"tier1_disclosure"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("models json: %v", err)
	}
	disclosure := body.Tier1Disclosure.RelayBlindRequestEncryption
	if disclosure == nil {
		t.Fatalf("relay-blind disclosure missing while feature is enabled: %s", resp.Body.String())
	}
	if got := disclosure.EndpointFamilies["chat_completions"].RequiredMode; got != "required_unavailable" {
		t.Fatalf("chat_completions required_mode=%q want required_unavailable", got)
	}
	for _, family := range []string{"responses", "messages"} {
		if got := disclosure.EndpointFamilies[family].RequiredMode; got != "unsupported" {
			t.Fatalf("%s required_mode=%q want unsupported", family, got)
		}
	}
	if disclosure.Settlement.VerifiedModelSettlement != "unavailable_for_relay_blind_request" {
		t.Fatalf("settlement disclosure=%+v", disclosure.Settlement)
	}
	if disclosure.Settlement.UsageSettlement != "standard_usage_settlement_and_clear_cap_enforcement_still_apply" {
		t.Fatalf("settlement disclosure=%+v", disclosure.Settlement)
	}
	if !bytes.Contains(resp.Body.Bytes(), []byte(`"usage_settlement":"standard_usage_settlement_and_clear_cap_enforcement_still_apply"`)) {
		t.Fatalf("relay-blind settlement disclosure missing usage_settlement key: %s", resp.Body.String())
	}
	if bytes.Contains(resp.Body.Bytes(), []byte(`"standard_usage_settlement":`)) {
		t.Fatalf("relay-blind settlement disclosure used stale standard_usage_settlement key: %s", resp.Body.String())
	}
	if bytes.Contains(resp.Body.Bytes(), []byte("capable_provider_count")) || bytes.Contains(resp.Body.Bytes(), []byte("incapable_provider_count")) {
		t.Fatalf("relay-blind disclosure must omit unknown provider counts without fresh evidence: %s", resp.Body.String())
	}
}

func TestRelayBlindRouteReservationFailsClosedNoStoreNoQuota(t *testing.T) {
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
	}, WithHTTPClient(noopClient()))
	accountID := "acct_relay_blind_route"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/relay-blind/route-reservations", strings.NewReader(`{
		"endpoint_family":"chat_completions",
		"model":"model-a",
		"stream":false,
		"max_output_tokens":16,
		"input_token_upper_bound":8,
		"encrypted_request_bytes":128
	}`))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("route reservation status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "relay_blind_required_unavailable")
	assertBodyRetryable(t, resp.Body.String(), false)
	if got := resp.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control=%q want no-store", got)
	}
	if got := resp.Header().Get("Pragma"); got != "no-cache" {
		t.Fatalf("Pragma=%q want no-cache", got)
	}
	assertNoDailyUsage(t, store, accountID)
}

func TestRelayBlindRouteReservationDisabledFailsTypedNoStoreNoQuota(t *testing.T) {
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests = config.RelayBlindRequestsConfig{}
	}, WithHTTPClient(noopClient()))
	accountID := "acct_relay_blind_route_disabled"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/relay-blind/route-reservations", strings.NewReader(`{
		"endpoint_family":"chat_completions",
		"model":"model-a",
		"stream":false,
		"max_output_tokens":16,
		"input_token_upper_bound":8,
		"encrypted_request_bytes":128
	}`))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("route reservation status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "relay_blind_disabled")
	assertBodyRetryable(t, resp.Body.String(), false)
	if got := resp.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control=%q want no-store", got)
	}
	if got := resp.Header().Get("Pragma"); got != "no-cache" {
		t.Fatalf("Pragma=%q want no-cache", got)
	}
	assertNoDailyUsage(t, store, accountID)
}

func TestRelayBlindRouteReservationAcceptsWalletSessionSignature(t *testing.T) {
	h, store, _, cfg := newWalletSessionHarness(t, walletModelsClient())
	apiKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_route_wallet")
	client := registerWalletSessionViaAPI(t, h, cfg, apiKey, "acct_relay_blind_route_wallet", []string{"model-a"})
	rawBody := []byte(`{
		"endpoint_family":"chat_completions",
		"model":"model-a",
		"stream":false,
		"max_output_tokens":16,
		"input_token_upper_bound":8,
		"encrypted_request_bytes":128
	}`)

	req := signedWalletRequest(t, client, http.MethodPost, "/v1/relay-blind/route-reservations", "/v1/relay-blind/route-reservations", "018f7b7b-7c35-4cf0-8d4e-3f0ab1c2d928", rawBody)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("route reservation status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "relay_blind_disabled")
	assertBodyRetryable(t, resp.Body.String(), false)
	if got := resp.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control=%q want no-store", got)
	}
	if got := resp.Header().Get("Pragma"); got != "no-cache" {
		t.Fatalf("Pragma=%q want no-cache", got)
	}
	assertNoDailyUsage(t, store, client.AccountID)

	replay := httptest.NewRecorder()
	h.ServeHTTP(replay, signedWalletRequest(t, client, http.MethodPost, "/v1/relay-blind/route-reservations", "/v1/relay-blind/route-reservations", "018f7b7b-7c35-4cf0-8d4e-3f0ab1c2d928", rawBody))
	if replay.Code != http.StatusConflict {
		t.Fatalf("replay route reservation status=%d want 409 body=%s", replay.Code, replay.Body.String())
	}
	assertErrorCode(t, replay.Body.String(), "wallet_session_duplicate_request")
	assertBodyRetryable(t, replay.Body.String(), false)
}

func TestRelayBlindRouteReservationWalletSessionPrecheckRejectsModelAndCaps(t *testing.T) {
	for name, tc := range map[string]struct {
		model        string
		perReqCap    int64
		inputTokens  int64
		outputTokens int64
		code         string
		status       int
	}{
		"model not allowed": {
			model:        "model-b",
			perReqCap:    50,
			inputTokens:  8,
			outputTokens: 16,
			code:         "wallet_session_model_not_allowed",
			status:       http.StatusForbidden,
		},
		"per request cap exceeded": {
			model:        "model-a",
			perReqCap:    20,
			inputTokens:  8,
			outputTokens: 16,
			code:         "wallet_session_request_cap_exceeded",
			status:       http.StatusBadRequest,
		},
	} {
		t.Run(name, func(t *testing.T) {
			h, store, _, cfg := newWalletSessionHarness(t, walletModelsClient())
			accountID := "acct_relay_blind_route_wallet_precheck_" + strings.ReplaceAll(name, " ", "_")
			apiKey := createAccountAndKey(t, store, cfg, accountID)
			client := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, []string{"model-a"}, 100, tc.perReqCap)
			rawBody, err := json.Marshal(map[string]any{
				"endpoint_family":         "chat_completions",
				"model":                   tc.model,
				"stream":                  false,
				"max_output_tokens":       tc.outputTokens,
				"input_token_upper_bound": tc.inputTokens,
				"encrypted_request_bytes": int64(128),
			})
			if err != nil {
				t.Fatalf("marshal route reservation: %v", err)
			}

			req := signedWalletRequest(t, client, http.MethodPost, "/v1/relay-blind/route-reservations", "/v1/relay-blind/route-reservations", "018f7b7b-7c35-4cf0-8d4e-3f0ab1c2e928", rawBody)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)

			if resp.Code != tc.status {
				t.Fatalf("route reservation status=%d want %d body=%s", resp.Code, tc.status, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), tc.code)
			assertBodyRetryable(t, resp.Body.String(), false)
			assertNoDailyUsage(t, store, client.AccountID)
		})
	}
}

func TestRelayBlindRouteReservationRejectsClosedSchemaAndCaps(t *testing.T) {
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Features.RelayBlindRequests.MaxEncryptedRequestBytes = 64
	}, WithHTTPClient(noopClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_route_invalid")

	for name, tc := range map[string]struct {
		body string
		code string
	}{
		"unknown field": {
			body: `{"endpoint_family":"chat_completions","model":"model-a","max_output_tokens":16,"input_token_upper_bound":8,"encrypted_request_bytes":32,"extra":true}`,
			code: "relay_blind_route_reservation_invalid",
		},
		"missing stream": {
			body: `{"endpoint_family":"chat_completions","model":"model-a","max_output_tokens":16,"input_token_upper_bound":8,"encrypted_request_bytes":32}`,
			code: "relay_blind_route_reservation_invalid",
		},
		"too large": {
			body: `{"endpoint_family":"chat_completions","model":"model-a","stream":false,"max_output_tokens":16,"input_token_upper_bound":8,"encrypted_request_bytes":65}`,
			code: "relay_blind_route_reservation_invalid",
		},
		"unsupported family": {
			body: `{"endpoint_family":"responses","model":"model-a","stream":false,"max_output_tokens":16,"input_token_upper_bound":8,"encrypted_request_bytes":32}`,
			code: "relay_blind_endpoint_unsupported",
		},
		"duplicate model key": {
			body: `{"endpoint_family":"chat_completions","model":"model-a","model":"model-b","stream":false,"max_output_tokens":16,"input_token_upper_bound":8,"encrypted_request_bytes":32}`,
			code: "relay_blind_route_reservation_invalid",
		},
	} {
		t.Run(name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/relay-blind/route-reservations", strings.NewReader(tc.body))
			req.Header.Set("Authorization", "Bearer "+fullKey)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), tc.code)
			assertBodyRetryable(t, resp.Body.String(), false)
		})
	}
}

func TestRelayBlindRouteReservationRejectsAPIAndDemoTokenCapViolations(t *testing.T) {
	for name, tc := range map[string]struct {
		demo        bool
		maxOutput   int64
		inputTokens int64
		code        string
	}{
		"api max output above limit": {
			maxOutput:   21,
			inputTokens: 8,
			code:        "relay_blind_route_reservation_invalid",
		},
		"api input output overflow": {
			maxOutput:   16,
			inputTokens: math.MaxInt64,
			code:        "relay_blind_route_reservation_invalid",
		},
		"demo max output above limit": {
			demo:        true,
			maxOutput:   11,
			inputTokens: 8,
			code:        "relay_blind_route_reservation_invalid",
		},
		"invalid model syntax": {
			maxOutput:   16,
			inputTokens: 8,
			code:        "relay_blind_route_reservation_invalid",
		},
	} {
		t.Run(name, func(t *testing.T) {
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Limits.MaxTokensPerRequest = 20
				cfg.Limits.DemoMaxTokensPerRequest = 10
			}, WithHTTPClient(noopClient()))
			fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_route_cap_"+strings.ReplaceAll(name, " ", "_"))
			rawBody, err := json.Marshal(map[string]any{
				"endpoint_family":         "chat_completions",
				"model":                   "model-a",
				"stream":                  false,
				"max_output_tokens":       tc.maxOutput,
				"input_token_upper_bound": tc.inputTokens,
				"encrypted_request_bytes": int64(32),
			})
			if name == "invalid model syntax" {
				rawBody, err = json.Marshal(map[string]any{
					"endpoint_family":         "chat_completions",
					"model":                   "model-a\nprompt",
					"stream":                  false,
					"max_output_tokens":       tc.maxOutput,
					"input_token_upper_bound": tc.inputTokens,
					"encrypted_request_bytes": int64(32),
				})
			}
			if err != nil {
				t.Fatalf("marshal route reservation: %v", err)
			}
			req := httptest.NewRequest(http.MethodPost, "/v1/relay-blind/route-reservations", bytes.NewReader(rawBody))
			if tc.demo {
				req.Header.Set("X-Demo-Token", issueDemoToken(t, h, "1.2.3.4"))
				req.Header.Set("X-Real-IP", "1.2.3.4")
			} else {
				req.Header.Set("Authorization", "Bearer "+fullKey)
			}
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)

			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), tc.code)
			assertBodyRetryable(t, resp.Body.String(), false)
		})
	}
}

func TestRelayBlindRequiredChatFailsClosedBeforeDispatchOrQuota(t *testing.T) {
	dispatchCalls := 0
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}))
	accountID := "acct_relay_blind_chat"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(validRelayBlindRequestEnvelope(t, nil)))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("chat status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "relay_blind_required_unavailable")
	assertBodyRetryable(t, resp.Body.String(), false)
	if dispatchCalls != 0 {
		t.Fatalf("coordinator dispatch calls=%d want 0", dispatchCalls)
	}
	assertNoDailyUsage(t, store, accountID)
	if got := countAuditEvents(t, dbPath, "relay_blind_required_rejected"); got != 1 {
		t.Fatalf("required-mode rejection audit events=%d want 1", got)
	}
	payload := relayBlindAuditPayload(t, dbPath, "relay_blind_required_rejected")
	for _, want := range []string{`"mode_class":"required"`, `"effective_outcome":"relay_blind_unavailable"`, `"reason_code":"relay_blind_required_unavailable"`, `"endpoint_family":"chat_completions"`, `"model":"model-a"`} {
		if !strings.Contains(payload, want) {
			t.Fatalf("required audit payload missing %s: %s", want, payload)
		}
	}
	for _, forbidden := range []string{"ciphertext", "tag", "buyer_ephemeral_public_key"} {
		if strings.Contains(payload, forbidden) {
			t.Fatalf("required audit payload leaked %s: %s", forbidden, payload)
		}
	}
}

func TestRelayBlindRequiredChatWalletAuditIncludesSafeCorrelation(t *testing.T) {
	h, store, dbPath, cfg := newWalletSessionHarness(t, walletModelsClient())
	cfg.Features.RelayBlindRequests.Enabled = true
	h = New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(walletModelsClient())).Handler()
	accountID := "acct_relay_blind_wallet_required_audit"
	apiKey := createAccountAndKey(t, store, cfg, accountID)
	walletClient := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, []string{"model-a"}, 100, 50)
	rawBody := []byte(validRelayBlindRequestEnvelope(t, map[string]any{
		"request_id":           "req-wallet-required-audit",
		"request_replay_nonce": "nonce-wallet-required-audit",
		"ciphertext":           "ciphertext-wallet-required-audit",
	}))

	req := signedWalletRequest(t, walletClient, http.MethodPost, "/v1/chat/completions", "/v1/chat/completions", "018f7b7b-7c35-4cf0-8d4e-3f0ab1c4f928", rawBody)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "relay_blind_required_unavailable")

	var payload map[string]any
	if err := json.Unmarshal([]byte(relayBlindAuditPayload(t, dbPath, "relay_blind_required_rejected")), &payload); err != nil {
		t.Fatalf("audit payload json: %v", err)
	}
	for key, want := range map[string]string{
		"wallet_session_id":      walletClient.SessionID,
		"provider_binding":       "opaque-binding",
		"kid":                    "kid-1",
		"requested_privacy_mode": "relay_blind_required",
		"reason_code":            "relay_blind_required_unavailable",
	} {
		if got, _ := payload[key].(string); got != want {
			t.Fatalf("audit payload[%s]=%q want %q payload=%v", key, got, want, payload)
		}
	}
	if digest, _ := payload["envelope_digest"].(string); len(digest) != relayBlindAuditDigestHexBytes {
		t.Fatalf("envelope_digest length=%d want %d payload=%v", len(digest), relayBlindAuditDigestHexBytes, payload)
	}
	for _, forbidden := range []string{"ciphertext", "tag", "buyer_ephemeral_public_key"} {
		if _, ok := payload[forbidden]; ok {
			t.Fatalf("required audit payload leaked %s: %v", forbidden, payload)
		}
	}
}

func TestRelayBlindRequiredChatReplayReturnsRelayBlindReplay(t *testing.T) {
	dispatchCalls := 0
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}))
	accountID := "acct_relay_blind_replay"
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	body := validRelayBlindRequestEnvelope(t, nil)

	for i, want := range []struct {
		status int
		code   string
	}{
		{http.StatusServiceUnavailable, "relay_blind_required_unavailable"},
		{http.StatusConflict, "relay_blind_replay"},
	} {
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+fullKey)
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Code != want.status {
			t.Fatalf("request %d status=%d want %d body=%s", i, resp.Code, want.status, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), want.code)
		assertBodyRetryable(t, resp.Body.String(), false)
	}
	if dispatchCalls != 0 {
		t.Fatalf("coordinator dispatch calls=%d want 0", dispatchCalls)
	}
	assertNoDailyUsage(t, store, accountID)
}

func TestRelayBlindRequiredChatDisabledWithZeroBoundsFailsUnavailableBeforeDispatchOrQuota(t *testing.T) {
	dispatchCalls := 0
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests = config.RelayBlindRequestsConfig{}
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}))
	accountID := "acct_relay_blind_disabled_zero_bounds"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	body := validRelayBlindRequestEnvelope(t, nil)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("chat status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "relay_blind_disabled")
	assertBodyRetryable(t, resp.Body.String(), false)
	if dispatchCalls != 0 {
		t.Fatalf("coordinator dispatch calls=%d want 0", dispatchCalls)
	}
	assertNoDailyUsage(t, store, accountID)
	if got := countAuditEvents(t, dbPath, "relay_blind_required_rejected"); got != 1 {
		t.Fatalf("required-mode rejection audit events=%d want 1", got)
	}
	payload := relayBlindAuditPayload(t, dbPath, "relay_blind_required_rejected")
	for _, want := range []string{`"effective_outcome":"relay_blind_unavailable"`, `"reason_code":"relay_blind_disabled"`} {
		if !strings.Contains(payload, want) {
			t.Fatalf("required audit payload missing %s: %s", want, payload)
		}
	}

	replay := httptest.NewRecorder()
	replayReq := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	replayReq.Header.Set("Authorization", "Bearer "+fullKey)
	h.ServeHTTP(replay, replayReq)
	if replay.Code != http.StatusConflict {
		t.Fatalf("disabled replay status=%d want 409 body=%s", replay.Code, replay.Body.String())
	}
	assertErrorCode(t, replay.Body.String(), "relay_blind_replay")
	assertBodyRetryable(t, replay.Body.String(), false)

	cfg.Features.RelayBlindRequests = config.Default().Features.RelayBlindRequests
	cfg.Features.RelayBlindRequests.Enabled = true
	reenabled := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()
	reenabledResp := httptest.NewRecorder()
	reenabledReq := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	reenabledReq.Header.Set("Authorization", "Bearer "+fullKey)
	reenabled.ServeHTTP(reenabledResp, reenabledReq)
	if reenabledResp.Code != http.StatusConflict {
		t.Fatalf("reenabled replay status=%d want 409 body=%s", reenabledResp.Code, reenabledResp.Body.String())
	}
	assertErrorCode(t, reenabledResp.Body.String(), "relay_blind_replay")
	assertBodyRetryable(t, reenabledResp.Body.String(), false)
}

func TestRelayBlindRequiredChatDoesNotConsumeAccountRateLimit(t *testing.T) {
	dispatchCalls := 0
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Quotas.AccountRequestRatePerSecond = 1
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}))
	accountID := "acct_relay_blind_rate_bucket"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(validRelayBlindRequestEnvelope(t, map[string]any{
			"request_id":                 fmt.Sprintf("req-rate-%d", i),
			"request_replay_nonce":       fmt.Sprintf("nonce-rate-%d", i),
			"buyer_ephemeral_public_key": fmt.Sprintf("x25519-public-key-%d", i),
			"ciphertext":                 fmt.Sprintf("ciphertext-%d", i),
		})))
		req.Header.Set("Authorization", "Bearer "+fullKey)
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("relay request %d status=%d want 503 body=%s", i, resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "relay_blind_required_unavailable")
		assertBodyRetryable(t, resp.Body.String(), false)
	}

	plain := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"max_tokens":8}`))
	plain.Header.Set("Authorization", "Bearer "+fullKey)
	plainResp := httptest.NewRecorder()
	h.ServeHTTP(plainResp, plain)
	if plainResp.Code != http.StatusOK {
		t.Fatalf("plaintext status=%d want 200 body=%s", plainResp.Code, plainResp.Body.String())
	}
	if dispatchCalls != 1 {
		t.Fatalf("coordinator dispatch calls=%d want 1", dispatchCalls)
	}
}

func TestRelayBlindRequiredChatMetadataLimiterDoesNotConsumePlaintextBucket(t *testing.T) {
	dispatchCalls := 0
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Features.RelayBlindRequests.MetadataRequestsPerMinute = 1
		cfg.Quotas.AccountRequestRatePerSecond = 1
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}))
	accountID := "acct_relay_blind_metadata_rate"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	firstBody := validRelayBlindRequestEnvelope(t, map[string]any{
		"request_id":                 "req-metadata-rate-0",
		"request_replay_nonce":       "nonce-metadata-rate-0",
		"buyer_ephemeral_public_key": "x25519-public-key-metadata-rate-0",
		"ciphertext":                 "ciphertext-metadata-rate-0",
	})
	for i, tc := range []struct {
		status int
		code   string
	}{
		{http.StatusServiceUnavailable, "relay_blind_required_unavailable"},
		{http.StatusConflict, "relay_blind_replay"},
		{http.StatusTooManyRequests, "relay_blind_metadata_rate_limited"},
	} {
		body := firstBody
		if i == 2 {
			body = validRelayBlindRequestEnvelope(t, map[string]any{
				"request_id":                 "req-metadata-rate-1",
				"request_replay_nonce":       "nonce-metadata-rate-1",
				"buyer_ephemeral_public_key": "x25519-public-key-metadata-rate-1",
				"ciphertext":                 "ciphertext-metadata-rate-1",
			})
		}
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+fullKey)
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Code != tc.status {
			t.Fatalf("relay request %d status=%d want %d body=%s", i, resp.Code, tc.status, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), tc.code)
		assertBodyRetryable(t, resp.Body.String(), tc.status == http.StatusTooManyRequests)
	}

	plain := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"max_tokens":8}`))
	plain.Header.Set("Authorization", "Bearer "+fullKey)
	plainResp := httptest.NewRecorder()
	h.ServeHTTP(plainResp, plain)
	if plainResp.Code != http.StatusOK {
		t.Fatalf("plaintext status=%d want 200 body=%s", plainResp.Code, plainResp.Body.String())
	}
	if dispatchCalls != 1 {
		t.Fatalf("coordinator dispatch calls=%d want 1", dispatchCalls)
	}
}

func TestRelayBlindRequiredChatReplayCapacityLimitsMetadataWrites(t *testing.T) {
	dispatchCalls := 0
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Features.RelayBlindRequests.MetadataRequestsPerMinute = 100
		cfg.Features.RelayBlindRequests.ReplayMaxRowsPerAccount = 1
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}))
	accountID := "acct_relay_blind_replay_capacity"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	firstBody := validRelayBlindRequestEnvelope(t, map[string]any{
		"request_id":                 "req-replay-capacity-0",
		"request_replay_nonce":       "nonce-replay-capacity-0",
		"buyer_ephemeral_public_key": "x25519-public-key-replay-capacity-0",
		"ciphertext":                 "ciphertext-replay-capacity-0",
	})
	for i, tc := range []struct {
		status int
		code   string
	}{
		{http.StatusServiceUnavailable, "relay_blind_required_unavailable"},
		{http.StatusConflict, "relay_blind_replay"},
		{http.StatusTooManyRequests, "relay_blind_metadata_rate_limited"},
	} {
		body := firstBody
		if i == 2 {
			body = validRelayBlindRequestEnvelope(t, map[string]any{
				"request_id":                 "req-replay-capacity-1",
				"request_replay_nonce":       "nonce-replay-capacity-1",
				"buyer_ephemeral_public_key": "x25519-public-key-replay-capacity-1",
				"ciphertext":                 "ciphertext-replay-capacity-1",
			})
		}
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+fullKey)
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Code != tc.status {
			t.Fatalf("relay request %d status=%d want %d body=%s", i, resp.Code, tc.status, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), tc.code)
		assertBodyRetryable(t, resp.Body.String(), tc.status == http.StatusTooManyRequests)
		if tc.status == http.StatusTooManyRequests {
			if got := resp.Header().Get("Retry-After"); got != "600" {
				t.Fatalf("relay capacity Retry-After=%q want 600", got)
			}
		}
	}
	if dispatchCalls != 0 {
		t.Fatalf("coordinator dispatch calls=%d want 0", dispatchCalls)
	}
	assertNoDailyUsage(t, store, accountID)
}

func TestRelayBlindRequiredChatWalletSessionPrecheckRejectsModelAndCapsBeforeDispatchOrQuota(t *testing.T) {
	for name, tc := range map[string]struct {
		overrides map[string]any
		perReqCap int64
		code      string
		status    int
	}{
		"model not allowed": {
			overrides: map[string]any{"model": "model-b"},
			perReqCap: 50,
			code:      "wallet_session_model_not_allowed",
			status:    http.StatusForbidden,
		},
		"reservation cap exceeded": {
			overrides: map[string]any{"reservation_token_cap": int64(51)},
			perReqCap: 50,
			code:      "wallet_session_request_cap_exceeded",
			status:    http.StatusBadRequest,
		},
	} {
		t.Run(name, func(t *testing.T) {
			dispatchCalls := 0
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if strings.HasSuffix(r.URL.Path, "/poolz") {
					return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
						"pool":[
							{"model_id":"model-a","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"bearer_validated"},
							{"model_id":"model-b","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"bearer_validated"}
						]
					}`), nil
				}
				dispatchCalls++
				return responseWithBody(http.StatusOK, nil, `{}`), nil
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Public.BaseURL = "https://api.malibu.test"
				cfg.Auth.WalletSessions.Enabled = true
				cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
				cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
				cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
				cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
				cfg.Features.RelayBlindRequests.Enabled = true
			}, WithHTTPClient(client))
			accountID := "acct_relay_blind_wallet_precheck_" + strings.ReplaceAll(name, " ", "_")
			apiKey := createAccountAndKey(t, store, cfg, accountID)
			walletClient := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, []string{"model-a"}, 100, tc.perReqCap)
			rawBody := []byte(validRelayBlindRequestEnvelope(t, tc.overrides))
			req := signedWalletRequest(t, walletClient, http.MethodPost, "/v1/chat/completions", "/v1/chat/completions", "018f7b7b-7c35-4cf0-8d4e-3f0ab1c2f928", rawBody)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)

			if resp.Code != tc.status {
				t.Fatalf("chat status=%d want %d body=%s", resp.Code, tc.status, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), tc.code)
			assertBodyRetryable(t, resp.Body.String(), false)
			if dispatchCalls != 0 {
				t.Fatalf("coordinator dispatch calls=%d want 0", dispatchCalls)
			}
			assertNoDailyUsage(t, store, walletClient.AccountID)

			replay := httptest.NewRecorder()
			h.ServeHTTP(replay, signedWalletRequest(t, walletClient, http.MethodPost, "/v1/chat/completions", "/v1/chat/completions", "018f7b7b-7c35-4cf0-8d4e-3f0ab1c2f928", rawBody))
			if replay.Code != http.StatusConflict {
				t.Fatalf("replay chat status=%d want 409 body=%s", replay.Code, replay.Body.String())
			}
			assertErrorCode(t, replay.Body.String(), "wallet_session_duplicate_request")
			assertBodyRetryable(t, replay.Body.String(), false)
		})
	}
}

func TestRelayBlindInvalidChatEnvelopeFailsClosedBeforeDispatchOrQuota(t *testing.T) {
	for name, tc := range map[string]struct {
		body string
	}{
		"missing clear field": {
			body: validRelayBlindRequestEnvelope(t, map[string]any{"provider_binding": ""}),
		},
		"missing stream": {
			body: validRelayBlindRequestEnvelope(t, map[string]any{"stream": deleteRelayBlindEnvelopeField{}}),
		},
		"unknown field": {
			body: validRelayBlindRequestEnvelope(t, map[string]any{"messages": []map[string]string{{"role": "user", "content": "plaintext must not dispatch"}}}),
		},
		"route inconsistent family": {
			body: validRelayBlindRequestEnvelope(t, map[string]any{"endpoint_family": "responses"}),
		},
		"duplicate non-sentinel key": {
			body: strings.Replace(validRelayBlindRequestEnvelope(t, nil), `"model":"model-a"`, `"model":"model-a","model":"model-b"`, 1),
		},
	} {
		t.Run(name, func(t *testing.T) {
			dispatchCalls := 0
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
			}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				dispatchCalls++
				return responseWithBody(http.StatusOK, nil, `{}`), nil
			})}))
			accountID := "acct_relay_blind_invalid_" + strings.ReplaceAll(name, " ", "_")
			fullKey := createAccountAndKey(t, store, cfg, accountID)

			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(tc.body))
			req.Header.Set("Authorization", "Bearer "+fullKey)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)

			if resp.Code != http.StatusBadRequest {
				t.Fatalf("chat status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "relay_blind_envelope_invalid")
			assertBodyRetryable(t, resp.Body.String(), false)
			if dispatchCalls != 0 {
				t.Fatalf("coordinator dispatch calls=%d want 0", dispatchCalls)
			}
			assertNoDailyUsage(t, store, accountID)
		})
	}
}

func TestRelayBlindEnvelopeMultipleJSONValuesNamesEnvelope(t *testing.T) {
	dispatchCalls := 0
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}))
	accountID := "acct_relay_blind_envelope_multiple_json"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(validRelayBlindRequestEnvelope(t, nil)+` {}`))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusBadRequest {
		t.Fatalf("chat status=%d want 400 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "relay_blind_envelope_invalid")
	assertBodyRetryable(t, resp.Body.String(), false)
	if !strings.Contains(resp.Body.String(), "Relay-blind request envelope") {
		t.Fatalf("error message must name request envelope: %s", resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), "route reservation") {
		t.Fatalf("error message must not name route reservation: %s", resp.Body.String())
	}
	if dispatchCalls != 0 {
		t.Fatalf("coordinator dispatch calls=%d want 0", dispatchCalls)
	}
	assertNoDailyUsage(t, store, accountID)
}

func TestRelayBlindChatEnvelopeRejectsAPIAndDemoTokenCapViolations(t *testing.T) {
	for name, tc := range map[string]struct {
		demo      bool
		overrides map[string]any
	}{
		"api max output above limit": {
			overrides: map[string]any{"max_output_tokens": int64(21), "reservation_token_cap": int64(29)},
		},
		"api input output overflow": {
			overrides: map[string]any{"input_token_upper_bound": int64(math.MaxInt64), "reservation_token_cap": int64(math.MaxInt64)},
		},
		"api reservation cap below sum": {
			overrides: map[string]any{"reservation_token_cap": int64(23)},
		},
		"demo max output above limit": {
			demo:      true,
			overrides: map[string]any{"max_output_tokens": int64(11), "reservation_token_cap": int64(19)},
		},
		"stale timestamp": {
			overrides: map[string]any{"issued_at_unix": fixedNow().Add(-2 * time.Minute).Unix()},
		},
		"invalid model syntax": {
			overrides: map[string]any{"model": "model-a\nprompt"},
		},
	} {
		t.Run(name, func(t *testing.T) {
			dispatchCalls := 0
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Limits.MaxTokensPerRequest = 20
				cfg.Limits.DemoMaxTokensPerRequest = 10
			}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				dispatchCalls++
				return responseWithBody(http.StatusOK, nil, `{}`), nil
			})}))
			fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_envelope_cap_"+strings.ReplaceAll(name, " ", "_"))

			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(validRelayBlindRequestEnvelope(t, tc.overrides)))
			if tc.demo {
				req.Header.Set("X-Demo-Token", issueDemoToken(t, h, "1.2.3.4"))
				req.Header.Set("X-Real-IP", "1.2.3.4")
			} else {
				req.Header.Set("Authorization", "Bearer "+fullKey)
			}
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)

			if resp.Code != http.StatusBadRequest {
				t.Fatalf("chat status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "relay_blind_envelope_invalid")
			assertBodyRetryable(t, resp.Body.String(), false)
			if dispatchCalls != 0 {
				t.Fatalf("coordinator dispatch calls=%d want 0", dispatchCalls)
			}
		})
	}
}

func TestRelayBlindMalformedSentinelFieldsFailClosedBeforeDispatchOrQuota(t *testing.T) {
	for name, body := range map[string]string{
		"typed version": `{
			"version":1,
			"mode":"required",
			"model":"model-a",
			"messages":[{"role":"user","content":"plaintext must not dispatch"}]
		}`,
		"missing version": `{
			"mode":"required",
			"model":"model-a",
			"messages":[{"role":"user","content":"plaintext must not dispatch"}]
		}`,
		"wrong version": `{
			"version":"relay-blind-request-v2",
			"mode":"required",
			"model":"model-a",
			"messages":[{"role":"user","content":"plaintext must not dispatch"}]
		}`,
		"duplicate mode smuggling": `{
			"version":"relay-blind-request-v1",
			"mode":"required",
			"mode":"metadata-only",
			"model":"model-a",
			"messages":[{"role":"user","content":"plaintext must not dispatch"}]
		}`,
		"duplicate version smuggling": `{
				"version":"relay-blind-request-v1",
				"version":"not-relay-blind",
				"mode":"metadata-only",
				"model":"model-a",
				"messages":[{"role":"user","content":"plaintext must not dispatch"}]
			}`,
		"truncated after required mode": `{
				"version":"relay-blind-request-v1",
				"mode":"required",
				"model":`,
		"trailing garbage after relay sentinel": `{
				"version":"relay-blind-request-v1",
				"mode":"required"
			} junk`,
	} {
		t.Run(name, func(t *testing.T) {
			dispatchCalls := 0
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
			}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				dispatchCalls++
				return responseWithBody(http.StatusOK, nil, `{}`), nil
			})}))
			accountID := "acct_relay_blind_malformed_sentinel_" + strings.ReplaceAll(name, " ", "_")
			fullKey := createAccountAndKey(t, store, cfg, accountID)

			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+fullKey)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)

			if resp.Code != http.StatusBadRequest {
				t.Fatalf("chat status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "relay_blind_envelope_invalid")
			assertBodyRetryable(t, resp.Body.String(), false)
			if dispatchCalls != 0 {
				t.Fatalf("coordinator dispatch calls=%d want 0", dispatchCalls)
			}
			assertNoDailyUsage(t, store, accountID)
		})
	}
}

func TestRelayBlindTruncatedNamespaceFailsClosedBeforeRouteParsing(t *testing.T) {
	for name, tc := range map[string]struct {
		path      string
		body      string
		mutate    func(*config.Config)
		anthropic bool
	}{
		"chat truncated version": {
			path: "/v1/chat/completions",
			body: `{"version":"relay-blind-request-v1"`,
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
			},
		},
		"disabled responses truncated version": {
			path: "/v1/responses",
			body: `{"version":"relay-blind-request-v1"`,
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Features.ResponsesAPIEnabled = false
			},
		},
		"disabled messages truncated version": {
			path: "/v1/messages",
			body: `{"version":"relay-blind-request-v1"`,
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Features.AnthropicMessagesEnabled = false
			},
			anthropic: true,
		},
	} {
		t.Run(name, func(t *testing.T) {
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, tc.mutate, WithHTTPClient(noopClient()))
			fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_truncated_"+strings.ReplaceAll(name, " ", "_"))
			req := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(tc.body))
			req.Header.Set("Authorization", "Bearer "+fullKey)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			if tc.anthropic {
				assertAnthropicErrorCode(t, resp.Body.String(), "relay_blind_envelope_invalid")
			} else {
				assertErrorCode(t, resp.Body.String(), "relay_blind_envelope_invalid")
			}
			assertBodyRetryable(t, resp.Body.String(), false)
		})
	}
}

func TestRelayBlindProbePreservesDefaultOffPlaintextCompatibility(t *testing.T) {
	for name, body := range map[string]string{
		"non-relay string mode": `{
			"version":"not-relay-blind",
			"mode":"metadata-only",
			"model":"model-a",
			"messages":[{"role":"user","content":"hello"}],
			"max_tokens":8
		}`,
		"non-relay non-string mode": `{
			"version":"not-relay-blind",
			"mode":{"client":"metadata"},
			"model":"model-a",
			"messages":[{"role":"user","content":"hello"}],
			"max_tokens":8
		}`,
	} {
		t.Run(name, func(t *testing.T) {
			dispatchCalls := 0
			h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				dispatchCalls++
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
			})}))
			fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_plaintext_compat_"+strings.ReplaceAll(name, " ", "_"))

			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+fullKey)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)

			if resp.Code != http.StatusOK {
				t.Fatalf("plaintext compatibility status=%d want 200 body=%s", resp.Code, resp.Body.String())
			}
			if dispatchCalls != 1 {
				t.Fatalf("coordinator dispatch calls=%d want 1", dispatchCalls)
			}
		})
	}
}

func TestRelayBlindUnsupportedFamiliesRemainMountedWhenPlaintextFeatureDisabled(t *testing.T) {
	for name, tc := range map[string]struct {
		path           string
		endpointFamily string
		relayEnabled   bool
		authed         bool
		code           string
		status         int
		body           string
		mutate         func(*config.Config)
	}{
		"responses required relay": {
			path:           "/v1/responses",
			endpointFamily: "responses",
			relayEnabled:   true,
			authed:         true,
			code:           "relay_blind_endpoint_unsupported",
			status:         http.StatusBadRequest,
			body:           validRelayBlindRequestEnvelope(t, map[string]any{"endpoint_family": "responses"}),
		},
		"messages required relay": {
			path:           "/v1/messages",
			endpointFamily: "messages",
			relayEnabled:   true,
			authed:         true,
			code:           "relay_blind_endpoint_unsupported",
			status:         http.StatusBadRequest,
			body:           validRelayBlindRequestEnvelope(t, map[string]any{"endpoint_family": "messages"}),
		},
		"responses required relay while relay disabled": {
			path:           "/v1/responses",
			endpointFamily: "responses",
			authed:         true,
			code:           "relay_blind_disabled",
			status:         http.StatusServiceUnavailable,
			body:           validRelayBlindRequestEnvelope(t, map[string]any{"endpoint_family": "responses"}),
		},
		"messages required relay while relay disabled": {
			path:           "/v1/messages",
			endpointFamily: "messages",
			authed:         true,
			code:           "relay_blind_disabled",
			status:         http.StatusServiceUnavailable,
			body:           validRelayBlindRequestEnvelope(t, map[string]any{"endpoint_family": "messages"}),
		},
		"responses plaintext": {
			path:         "/v1/responses",
			relayEnabled: true,
			authed:       true,
			code:         "not_found",
			status:       http.StatusNotFound,
			body:         `{"model":"model-a","input":"hello"}`,
		},
		"messages plaintext": {
			path:         "/v1/messages",
			relayEnabled: true,
			authed:       true,
			code:         "not_found",
			status:       http.StatusNotFound,
			body:         `{"model":"model-a","max_tokens":8,"messages":[{"role":"user","content":"hello"}]}`,
		},
		"responses plaintext without auth": {
			path:         "/v1/responses",
			relayEnabled: true,
			code:         "not_found",
			status:       http.StatusNotFound,
			body:         `{"model":"model-a","input":"hello"}`,
		},
		"responses oversized plaintext": {
			path:         "/v1/responses",
			relayEnabled: true,
			authed:       true,
			code:         "not_found",
			status:       http.StatusNotFound,
			body:         `{"model":"model-a","input":"` + strings.Repeat("x", 64) + `"}`,
			mutate: func(cfg *config.Config) {
				cfg.Limits.RequestBodyBytes = 32
			},
		},
		"messages oversized plaintext": {
			path:         "/v1/messages",
			relayEnabled: true,
			authed:       true,
			code:         "not_found",
			status:       http.StatusNotFound,
			body:         `{"model":"model-a","max_tokens":8,"messages":[{"role":"user","content":"` + strings.Repeat("x", 64) + `"}]}`,
			mutate: func(cfg *config.Config) {
				cfg.Limits.RequestBodyBytes = 32
			},
		},
		"responses malformed relay without auth": {
			path:         "/v1/responses",
			relayEnabled: true,
			code:         "missing_bearer_token",
			status:       http.StatusUnauthorized,
			body:         `{"version":"relay-blind-request-v1","model":"model-a"}`,
		},
		"messages malformed relay without auth": {
			path:         "/v1/messages",
			relayEnabled: true,
			code:         "missing_bearer_token",
			status:       http.StatusUnauthorized,
			body:         `{"version":"relay-blind-request-v1","mode":1,"model":"model-a"}`,
		},
		"responses missing mode": {
			path:         "/v1/responses",
			relayEnabled: true,
			authed:       true,
			code:         "relay_blind_envelope_invalid",
			status:       http.StatusBadRequest,
			body:         `{"version":"relay-blind-request-v1","model":"model-a"}`,
		},
		"messages non-string mode": {
			path:         "/v1/messages",
			relayEnabled: true,
			authed:       true,
			code:         "relay_blind_envelope_invalid",
			status:       http.StatusBadRequest,
			body:         `{"version":"relay-blind-request-v1","mode":1,"model":"model-a"}`,
		},
	} {
		t.Run(name, func(t *testing.T) {
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = tc.relayEnabled
				cfg.Features.ResponsesAPIEnabled = false
				cfg.Features.AnthropicMessagesEnabled = false
				if tc.mutate != nil {
					tc.mutate(cfg)
				}
			}, WithHTTPClient(noopClient()))
			fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_disabled_family_"+strings.ReplaceAll(name, " ", "_"))
			req := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(tc.body))
			if tc.authed {
				req.Header.Set("Authorization", "Bearer "+fullKey)
			}
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != tc.status {
				t.Fatalf("status=%d want %d body=%s", resp.Code, tc.status, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), tc.code)
			assertBodyRetryable(t, resp.Body.String(), false)
			if tc.code == "relay_blind_endpoint_unsupported" || tc.code == "relay_blind_disabled" {
				if got := countAuditEvents(t, dbPath, "relay_blind_required_rejected"); got != 1 {
					t.Fatalf("required-mode rejection audit events=%d want 1", got)
				}
				payload := relayBlindAuditPayload(t, dbPath, "relay_blind_required_rejected")
				for _, want := range []string{`"endpoint_family":"` + tc.endpointFamily + `"`, `"effective_outcome":"relay_blind_unavailable"`, `"reason_code":"` + tc.code + `"`} {
					if !strings.Contains(payload, want) {
						t.Fatalf("required audit payload missing %s: %s", want, payload)
					}
				}
			}
		})
	}
}

func TestRelayBlindDisabledMessagesRelayShapeUsesAnthropicFacade(t *testing.T) {
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Features.AnthropicMessagesEnabled = false
	}, WithHTTPClient(noopClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_messages_facade")

	for name, headers := range map[string]map[string]string{
		"authorization": {"Authorization": "Bearer " + fullKey},
		"x-api-key":     {"X-Api-Key": fullKey},
	} {
		t.Run(name, func(t *testing.T) {
			body := validRelayBlindRequestEnvelope(t, map[string]any{
				"endpoint_family":            "messages",
				"request_id":                 "req-messages-facade-" + name,
				"request_replay_nonce":       "nonce-messages-facade-" + name,
				"buyer_ephemeral_public_key": "x25519-public-key-messages-facade-" + name,
				"ciphertext":                 "ciphertext-messages-facade-" + name,
			})
			req := httptest.NewRequest(http.MethodPost, "/v1/messages", strings.NewReader(body))
			for key, value := range headers {
				req.Header.Set(key, value)
			}
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			assertAnthropicErrorCode(t, resp.Body.String(), "relay_blind_endpoint_unsupported")
			assertBodyRetryable(t, resp.Body.String(), false)
		})
	}

	body := validRelayBlindRequestEnvelope(t, map[string]any{"endpoint_family": "messages"})
	req := httptest.NewRequest(http.MethodPost, "/v1/messages", strings.NewReader(body))
	req.Header.Set("X-Demo-Token", "demo-token")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("demo status=%d want 401 body=%s", resp.Code, resp.Body.String())
	}
	assertAnthropicErrorCode(t, resp.Body.String(), "invalid_demo_token")
	assertBodyRetryable(t, resp.Body.String(), false)

	if got := countAuditEvents(t, dbPath, "relay_blind_required_rejected"); got != 2 {
		t.Fatalf("required-mode rejection audit events=%d want 2", got)
	}
}

func TestRelayBlindDisabledFamilyOptionsSupportsBrowserPreflight(t *testing.T) {
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Features.ResponsesAPIEnabled = false
		cfg.Features.AnthropicMessagesEnabled = false
	}, WithHTTPClient(noopClient()))

	for _, path := range []string{"/v1/responses", "/v1/messages"} {
		req := httptest.NewRequest(http.MethodOptions, path, nil)
		req.Header.Set("Origin", "https://console.malibu.tech")
		req.Header.Set("Access-Control-Request-Method", http.MethodPost)
		req.Header.Set("Access-Control-Request-Headers", "Authorization, Content-Type")
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)

		if resp.Code != http.StatusNoContent {
			t.Fatalf("%s OPTIONS status=%d want 204 body=%s", path, resp.Code, resp.Body.String())
		}
		if got := resp.Header().Get("Access-Control-Allow-Origin"); got != "https://console.malibu.tech" {
			t.Fatalf("%s Access-Control-Allow-Origin=%q", path, got)
		}
		if got := resp.Header().Get("Access-Control-Allow-Methods"); got != http.MethodPost {
			t.Fatalf("%s Access-Control-Allow-Methods=%q", path, got)
		}
	}
}

func TestRelayBlindEnabledFamiliesPreferDisabledOverUnsupported(t *testing.T) {
	for name, tc := range map[string]struct {
		path           string
		endpointFamily string
		mutate         func(*config.Config)
	}{
		"responses": {
			path:           "/v1/responses",
			endpointFamily: "responses",
			mutate: func(cfg *config.Config) {
				cfg.Features.ResponsesAPIEnabled = true
				cfg.Features.RelayBlindRequests.Enabled = false
			},
		},
		"messages": {
			path:           "/v1/messages",
			endpointFamily: "messages",
			mutate: func(cfg *config.Config) {
				cfg.Features.AnthropicMessagesEnabled = true
				cfg.Features.RelayBlindRequests.Enabled = false
			},
		},
	} {
		t.Run(name, func(t *testing.T) {
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, tc.mutate, WithHTTPClient(noopClient()))
			fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_enabled_family_disabled_"+name)
			req := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(validRelayBlindRequestEnvelope(t, map[string]any{"endpoint_family": tc.endpointFamily})))
			req.Header.Set("Authorization", "Bearer "+fullKey)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != http.StatusServiceUnavailable {
				t.Fatalf("status=%d want 503 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "relay_blind_disabled")
			assertBodyRetryable(t, resp.Body.String(), false)
			payload := relayBlindAuditPayload(t, dbPath, "relay_blind_required_rejected")
			for _, want := range []string{`"endpoint_family":"` + tc.endpointFamily + `"`, `"reason_code":"relay_blind_disabled"`} {
				if !strings.Contains(payload, want) {
					t.Fatalf("required audit payload missing %s: %s", want, payload)
				}
			}
		})
	}
}

func TestRelayBlindSaturatedChatRateDoesNotMaskRelayTypedError(t *testing.T) {
	dispatchCalls := 0
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Quotas.AccountRequestRatePerSecond = 1
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}))
	fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_saturated_typed")

	first := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"max_tokens":8}`))
	first.Header.Set("Authorization", "Bearer "+fullKey)
	firstResp := httptest.NewRecorder()
	h.ServeHTTP(firstResp, first)
	if firstResp.Code != http.StatusOK {
		t.Fatalf("first plaintext status=%d want 200 body=%s", firstResp.Code, firstResp.Body.String())
	}

	relay := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(validRelayBlindRequestEnvelope(t, map[string]any{
		"request_id":                 "req-saturated-typed",
		"request_replay_nonce":       "nonce-saturated-typed",
		"buyer_ephemeral_public_key": "x25519-public-key-saturated-typed",
		"ciphertext":                 "ciphertext-saturated-typed",
	})))
	relay.Header.Set("Authorization", "Bearer "+fullKey)
	relayResp := httptest.NewRecorder()
	h.ServeHTTP(relayResp, relay)
	if relayResp.Code != http.StatusServiceUnavailable {
		t.Fatalf("relay status=%d want 503 body=%s", relayResp.Code, relayResp.Body.String())
	}
	assertErrorCode(t, relayResp.Body.String(), "relay_blind_required_unavailable")
	assertBodyRetryable(t, relayResp.Body.String(), false)
	if dispatchCalls != 1 {
		t.Fatalf("coordinator dispatch calls=%d want 1", dispatchCalls)
	}
}

func TestRelayBlindLateSentinelDoesNotConsumePlaintextBucket(t *testing.T) {
	dispatchCalls := 0
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Quotas.AccountRequestRatePerSecond = 1
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}))
	fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_late_sentinel")

	body := validRelayBlindRequestEnvelope(t, map[string]any{
		"padding":                    strings.Repeat("x", 4096),
		"request_id":                 "req-late-sentinel",
		"request_replay_nonce":       "nonce-late-sentinel",
		"buyer_ephemeral_public_key": "x25519-public-key-late-sentinel",
		"ciphertext":                 "ciphertext-late-sentinel",
	})
	relay := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	relay.Header.Set("Authorization", "Bearer "+fullKey)
	relayResp := httptest.NewRecorder()
	h.ServeHTTP(relayResp, relay)
	if relayResp.Code != http.StatusBadRequest {
		t.Fatalf("relay status=%d want 400 body=%s", relayResp.Code, relayResp.Body.String())
	}
	assertErrorCode(t, relayResp.Body.String(), "relay_blind_envelope_invalid")

	plain := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"max_tokens":8}`))
	plain.Header.Set("Authorization", "Bearer "+fullKey)
	plainResp := httptest.NewRecorder()
	h.ServeHTTP(plainResp, plain)
	if plainResp.Code != http.StatusOK {
		t.Fatalf("plaintext status=%d want 200 body=%s", plainResp.Code, plainResp.Body.String())
	}
	if dispatchCalls != 1 {
		t.Fatalf("coordinator dispatch calls=%d want 1", dispatchCalls)
	}
}

func TestRelayBlindNonObjectNamespaceDoesNotConsumePlaintextBucket(t *testing.T) {
	dispatchCalls := 0
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Quotas.AccountRequestRatePerSecond = 1
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}))
	fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_nonobject")

	relay := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`["relay-blind-request-v1",{"mode":"required"}]`))
	relay.Header.Set("Authorization", "Bearer "+fullKey)
	relayResp := httptest.NewRecorder()
	h.ServeHTTP(relayResp, relay)
	if relayResp.Code != http.StatusBadRequest {
		t.Fatalf("relay status=%d want 400 body=%s", relayResp.Code, relayResp.Body.String())
	}
	assertErrorCode(t, relayResp.Body.String(), "relay_blind_envelope_invalid")

	plain := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"max_tokens":8}`))
	plain.Header.Set("Authorization", "Bearer "+fullKey)
	plainResp := httptest.NewRecorder()
	h.ServeHTTP(plainResp, plain)
	if plainResp.Code != http.StatusOK {
		t.Fatalf("plaintext status=%d want 200 body=%s", plainResp.Code, plainResp.Body.String())
	}
	if dispatchCalls != 1 {
		t.Fatalf("coordinator dispatch calls=%d want 1", dispatchCalls)
	}
}

func TestRelayBlindDisabledFamilyPrechecksModelAndCapsBeforeReplayAudit(t *testing.T) {
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Features.ResponsesAPIEnabled = false
		cfg.Limits.MaxTokensPerRequest = 10
	}, WithHTTPClient(noopClient()))
	fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_disabled_family_cap")
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(validRelayBlindRequestEnvelope(t, map[string]any{
		"endpoint_family":            "responses",
		"max_output_tokens":          int64(11),
		"reservation_token_cap":      int64(19),
		"request_id":                 "req-disabled-family-cap",
		"request_replay_nonce":       "nonce-disabled-family-cap",
		"ciphertext":                 "ciphertext-disabled-family-cap",
		"buyer_ephemeral_public_key": "x25519-public-key-disabled-family-cap",
	})))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "relay_blind_envelope_invalid")
	assertBodyRetryable(t, resp.Body.String(), false)
	if got := countAuditEvents(t, dbPath, "relay_blind_required_rejected"); got != 0 {
		t.Fatalf("required audit events=%d want 0", got)
	}
	assertNoDailyUsage(t, store, "acct_relay_blind_disabled_family_cap")
}

func TestRelayBlindDisabledFamilyWalletPrecheckStillRecordsWalletReplay(t *testing.T) {
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Public.BaseURL = "https://api.malibu.test"
		cfg.Auth.WalletSessions.Enabled = true
		cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
		cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
		cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
		cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Features.ResponsesAPIEnabled = false
	}, WithHTTPClient(walletModelsClient()))
	accountID := "acct_relay_blind_disabled_family_wallet_precheck"
	apiKey := createAccountAndKey(t, store, cfg, accountID)
	walletClient := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, []string{"model-a"}, 100, 50)
	rawBody := []byte(validRelayBlindRequestEnvelope(t, map[string]any{
		"endpoint_family": "responses",
		"model":           "model-b",
	}))

	req := signedWalletRequest(t, walletClient, http.MethodPost, "/v1/responses", "/v1/responses", "018f7b7b-7c35-4cf0-8d4e-3f0ab1c3f928", rawBody)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusForbidden {
		t.Fatalf("status=%d want 403 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "wallet_session_model_not_allowed")
	assertBodyRetryable(t, resp.Body.String(), false)
	if got := countAuditEvents(t, dbPath, "relay_blind_required_rejected"); got != 0 {
		t.Fatalf("required audit events=%d want 0", got)
	}

	replay := httptest.NewRecorder()
	h.ServeHTTP(replay, signedWalletRequest(t, walletClient, http.MethodPost, "/v1/responses", "/v1/responses", "018f7b7b-7c35-4cf0-8d4e-3f0ab1c3f928", rawBody))
	if replay.Code != http.StatusConflict {
		t.Fatalf("replay status=%d want 409 body=%s", replay.Code, replay.Body.String())
	}
	assertErrorCode(t, replay.Body.String(), "wallet_session_duplicate_request")
	assertNoDailyUsage(t, store, accountID)
}

func TestRelayBlindDisabledFamilyWalletMetadataAdmittedBeforeMalformedAndDowngrade(t *testing.T) {
	for name, tc := range map[string]struct {
		body string
		code string
	}{
		"malformed missing mode": {
			body: `{"version":"relay-blind-request-v1","model":"model-a"}`,
			code: "relay_blind_envelope_invalid",
		},
		"downgrade": {
			body: `{"version":"relay-blind-request-v1","mode":"opportunistic","model":"model-a"}`,
			code: "relay_blind_downgrade_rejected",
		},
	} {
		t.Run(name, func(t *testing.T) {
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Public.BaseURL = "https://api.malibu.test"
				cfg.Auth.WalletSessions.Enabled = true
				cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
				cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
				cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
				cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Features.ResponsesAPIEnabled = false
			}, WithHTTPClient(walletModelsClient()))
			accountID := "acct_relay_blind_disabled_family_wallet_metadata_" + strings.ReplaceAll(name, " ", "_")
			apiKey := createAccountAndKey(t, store, cfg, accountID)
			walletClient := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, []string{"model-a"}, 100, 50)
			rawBody := []byte(tc.body)

			req := signedWalletRequest(t, walletClient, http.MethodPost, "/v1/responses", "/v1/responses", "018f7b7b-7c35-4cf0-8d4e-3f0ab1c50928", rawBody)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), tc.code)
			assertBodyRetryable(t, resp.Body.String(), false)

			replay := httptest.NewRecorder()
			h.ServeHTTP(replay, signedWalletRequest(t, walletClient, http.MethodPost, "/v1/responses", "/v1/responses", "018f7b7b-7c35-4cf0-8d4e-3f0ab1c50928", rawBody))
			if replay.Code != http.StatusConflict {
				t.Fatalf("replay status=%d want 409 body=%s", replay.Code, replay.Body.String())
			}
			assertErrorCode(t, replay.Body.String(), "wallet_session_duplicate_request")
			assertBodyRetryable(t, replay.Body.String(), false)
			assertNoDailyUsage(t, store, accountID)
		})
	}
}

func TestRelayBlindEnvelopeRejectsDowngradeAndUnsupportedFamilies(t *testing.T) {
	for name, tc := range map[string]struct {
		path   string
		body   string
		mutate func(*config.Config)
		code   string
		status int
	}{
		"opportunistic chat": {
			path: "/v1/chat/completions",
			body: `{"version":"relay-blind-request-v1","mode":"opportunistic-secret-prompt-material","model":"model-a"}`,
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
			},
			code:   "relay_blind_downgrade_rejected",
			status: http.StatusBadRequest,
		},
		"unsupported relay namespace with plaintext fields": {
			path: "/v1/chat/completions",
			body: `{"version":"relay-blind-request-v2","mode":"opportunistic","model":"model-a","messages":[{"role":"user","content":"must not dispatch plaintext"}],"max_tokens":8}`,
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
			},
			code:   "relay_blind_envelope_invalid",
			status: http.StatusBadRequest,
		},
		"responses unsupported": {
			path: "/v1/responses",
			body: validRelayBlindRequestEnvelope(t, map[string]any{"endpoint_family": "responses"}),
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Features.ResponsesAPIEnabled = true
			},
			code:   "relay_blind_endpoint_unsupported",
			status: http.StatusBadRequest,
		},
		"messages unsupported": {
			path: "/v1/messages",
			body: validRelayBlindRequestEnvelope(t, map[string]any{"endpoint_family": "messages"}),
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Features.AnthropicMessagesEnabled = true
			},
			code:   "relay_blind_endpoint_unsupported",
			status: http.StatusBadRequest,
		},
	} {
		t.Run(name, func(t *testing.T) {
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, tc.mutate, WithHTTPClient(noopClient()))
			fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_"+strings.ReplaceAll(name, " ", "_"))
			req := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(tc.body))
			req.Header.Set("Authorization", "Bearer "+fullKey)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != tc.status {
				t.Fatalf("status=%d want %d body=%s", resp.Code, tc.status, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), tc.code)
			assertBodyRetryable(t, resp.Body.String(), false)
			if tc.code == "relay_blind_downgrade_rejected" && countAuditEvents(t, dbPath, "relay_blind_downgrade_rejected") != 1 {
				t.Fatalf("downgrade rejection audit event missing")
			}
			if tc.code == "relay_blind_downgrade_rejected" {
				payload := relayBlindAuditPayload(t, dbPath, "relay_blind_downgrade_rejected")
				if strings.Contains(payload, "opportunistic-secret-prompt-material") {
					t.Fatalf("downgrade audit leaked raw mode: %s", payload)
				}
				if !strings.Contains(payload, `"mode_class":"non_required"`) {
					t.Fatalf("downgrade audit missing bounded mode class: %s", payload)
				}
				for _, want := range []string{`"requested_privacy_mode":"relay_blind_required"`, `"effective_outcome":"relay_blind_unavailable"`} {
					if !strings.Contains(payload, want) {
						t.Fatalf("downgrade audit payload missing %s: %s", want, payload)
					}
				}
			}
		})
	}
}

func TestRelayBlindDowngradeMetadataLimiterDoesNotConsumePlaintextBucket(t *testing.T) {
	dispatchCalls := 0
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Features.RelayBlindRequests.MetadataRequestsPerMinute = 1
		cfg.Quotas.AccountRequestRatePerSecond = 1
	}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		dispatchCalls++
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}))
	accountID := "acct_relay_blind_downgrade_metadata_rate"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	for i, tc := range []struct {
		body   string
		status int
		code   string
	}{
		{`{"version":"relay-blind-request-v1","mode":"opportunistic","model":"model-a"}`, http.StatusBadRequest, "relay_blind_downgrade_rejected"},
		{`{"version":"relay-blind-request-v1","mode":"fallback","model":"model-a"}`, http.StatusTooManyRequests, "relay_blind_metadata_rate_limited"},
	} {
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+fullKey)
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Code != tc.status {
			t.Fatalf("downgrade request %d status=%d want %d body=%s", i, resp.Code, tc.status, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), tc.code)
		assertBodyRetryable(t, resp.Body.String(), tc.status == http.StatusTooManyRequests)
	}
	if got := countAuditEvents(t, dbPath, "relay_blind_downgrade_rejected"); got != 1 {
		t.Fatalf("downgrade audit events=%d want 1", got)
	}

	plain := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"max_tokens":8}`))
	plain.Header.Set("Authorization", "Bearer "+fullKey)
	plainResp := httptest.NewRecorder()
	h.ServeHTTP(plainResp, plain)
	if plainResp.Code != http.StatusOK {
		t.Fatalf("plaintext status=%d want 200 body=%s", plainResp.Code, plainResp.Body.String())
	}
	if dispatchCalls != 1 {
		t.Fatalf("coordinator dispatch calls=%d want 1", dispatchCalls)
	}
}

func TestRelayBlindDisabledFamilyDowngradeUsesMetadataLimiterBeforeAudit(t *testing.T) {
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
		cfg.Features.RelayBlindRequests.MetadataRequestsPerMinute = 1
		cfg.Features.ResponsesAPIEnabled = false
	}, WithHTTPClient(noopClient()))
	accountID := "acct_relay_blind_disabled_family_downgrade_rate"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	for i, tc := range []struct {
		body   string
		status int
		code   string
	}{
		{`{"version":"relay-blind-request-v1","mode":"opportunistic","model":"model-a"}`, http.StatusBadRequest, "relay_blind_downgrade_rejected"},
		{`{"version":"relay-blind-request-v1","mode":"fallback","model":"model-a"}`, http.StatusTooManyRequests, "relay_blind_metadata_rate_limited"},
	} {
		req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+fullKey)
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Code != tc.status {
			t.Fatalf("disabled downgrade request %d status=%d want %d body=%s", i, resp.Code, tc.status, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), tc.code)
		assertBodyRetryable(t, resp.Body.String(), tc.status == http.StatusTooManyRequests)
	}
	if got := countAuditEvents(t, dbPath, "relay_blind_downgrade_rejected"); got != 1 {
		t.Fatalf("downgrade audit events=%d want 1", got)
	}
	assertNoDailyUsage(t, store, accountID)
}

func TestRelayBlindUnsupportedFamiliesValidateMalformedBeforeUnsupported(t *testing.T) {
	for name, tc := range map[string]struct {
		path   string
		body   string
		mutate func(*config.Config)
		code   string
	}{
		"responses opportunistic": {
			path: "/v1/responses",
			body: `{"version":"relay-blind-request-v1","mode":"opportunistic","model":"model-a"}`,
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Features.ResponsesAPIEnabled = true
			},
			code: "relay_blind_downgrade_rejected",
		},
		"responses unsupported relay namespace": {
			path: "/v1/responses",
			body: `{"version":"relay-blind-request-v2","mode":"opportunistic","model":"model-a","input":"must not dispatch plaintext"}`,
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Features.ResponsesAPIEnabled = true
			},
			code: "relay_blind_envelope_invalid",
		},
		"messages malformed version type": {
			path: "/v1/messages",
			body: `{"version":1,"mode":"required","model":"model-a"}`,
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Features.AnthropicMessagesEnabled = true
			},
			code: "relay_blind_envelope_invalid",
		},
		"responses unknown field": {
			path: "/v1/responses",
			body: validRelayBlindRequestEnvelope(t, map[string]any{
				"endpoint_family": "responses",
				"input":           "plaintext must not be accepted",
			}),
			mutate: func(cfg *config.Config) {
				cfg.Features.RelayBlindRequests.Enabled = true
				cfg.Features.ResponsesAPIEnabled = true
			},
			code: "relay_blind_envelope_invalid",
		},
	} {
		t.Run(name, func(t *testing.T) {
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, tc.mutate, WithHTTPClient(noopClient()))
			fullKey := createAccountAndKey(t, store, cfg, "acct_relay_blind_malformed_"+strings.ReplaceAll(name, " ", "_"))
			req := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(tc.body))
			req.Header.Set("Authorization", "Bearer "+fullKey)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if resp.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), tc.code)
			assertBodyRetryable(t, resp.Body.String(), false)
		})
	}
}

func TestRelayBlindDowngradeAuditFailureFailsClosed(t *testing.T) {
	_, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Features.RelayBlindRequests.Enabled = true
	}, WithHTTPClient(noopClient()))
	accountID := "acct_relay_blind_audit_fail"
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	h := New(cfg, relayBlindAuditFailStore{Store: store}, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"version":"relay-blind-request-v1","mode":"opportunistic","model":"model-a"}`))
	req.Header.Set("Authorization", "Bearer "+fullKey)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusInternalServerError {
		t.Fatalf("status=%d want 500 body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "internal_error")
	assertBodyRetryable(t, resp.Body.String(), false)
}

func assertNoDailyUsage(t *testing.T, store interface {
	DailyUsage(context.Context, string, string) (int64, int64, error)
}, accountID string) {
	t.Helper()
	used, reserved, err := store.DailyUsage(context.Background(), accountID, fixedNow().Format("2006-01-02"))
	if err != nil {
		t.Fatalf("DailyUsage: %v", err)
	}
	if used != 0 || reserved != 0 {
		t.Fatalf("DailyUsage used=%d reserved=%d want 0,0", used, reserved)
	}
}

func validRelayBlindRequestEnvelope(t *testing.T, overrides map[string]any) string {
	t.Helper()
	env := map[string]any{
		"version":                    "relay-blind-request-v1",
		"mode":                       "required",
		"endpoint_family":            "chat_completions",
		"model":                      "model-a",
		"provider_model":             "provider-model-a",
		"stream":                     false,
		"request_id":                 "req-relay-blind-1",
		"max_output_tokens":          int64(16),
		"input_token_upper_bound":    int64(8),
		"reservation_token_cap":      int64(24),
		"provider_binding":           "opaque-binding",
		"key_record_digest":          "sha256:key-record",
		"kid":                        "kid-1",
		"buyer_ephemeral_public_key": "x25519-public-key",
		"request_replay_nonce":       "nonce-1",
		"issued_at_unix":             fixedNow().Unix(),
		"algorithm":                  "x25519-hkdf-sha256-a256gcm-v1",
		"ciphertext":                 "ciphertext",
		"tag":                        "tag",
	}
	for k, v := range overrides {
		if _, ok := v.(deleteRelayBlindEnvelopeField); ok {
			delete(env, k)
			continue
		}
		env[k] = v
	}
	body, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal relay-blind envelope: %v", err)
	}
	return string(body)
}

type deleteRelayBlindEnvelopeField struct{}

func assertAnthropicErrorCode(t *testing.T, raw, code string) {
	t.Helper()
	var body struct {
		Type  string `json:"type"`
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &body); err != nil {
		t.Fatalf("anthropic error json: %v body=%s", err, raw)
	}
	if body.Type != "error" {
		t.Fatalf("anthropic error type=%q want error body=%s", body.Type, raw)
	}
	if body.Error.Code != code {
		t.Fatalf("anthropic error code=%q want=%q body=%s", body.Error.Code, code, raw)
	}
}

type relayBlindAuditFailStore struct {
	Store
}

func (s relayBlindAuditFailStore) InsertAuditEvent(ctx context.Context, event storage.AuditEvent) error {
	if event.Type == "relay_blind_downgrade_rejected" {
		return errors.New("audit insert failed")
	}
	return s.Store.InsertAuditEvent(ctx, event)
}

func relayBlindAuditPayload(t *testing.T, dbPath, eventType string) string {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql open: %v", err)
	}
	defer db.Close()
	var payload string
	if err := db.QueryRow(`SELECT payload_json FROM audit_events WHERE event_type = ? ORDER BY created_at DESC LIMIT 1`, eventType).Scan(&payload); err != nil {
		t.Fatalf("audit payload query: %v", err)
	}
	return payload
}
