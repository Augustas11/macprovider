package router

import (
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRelayBlindWalletReplayBeforeTemporalThrottle(t *testing.T) {
	for _, route := range []struct {
		path, family    string
		adaptersEnabled bool
	}{
		{"/v1/chat/completions", "chat_completions", false},
		{"/v1/responses", "responses", false},
		{"/v1/messages", "messages", false},
		{"/v1/responses", "responses", true},
		{"/v1/messages", "messages", true},
	} {
		for _, enabled := range []bool{false, true} {
			for _, bound := range []string{"available", "rate", "rows", "bytes"} {
				t.Run(route.family+"/"+map[bool]string{false: "disabled", true: "enabled"}[enabled]+"/"+bound, func(t *testing.T) {
					dispatches := 0
					baseClient := walletModelsClient()
					client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
						if !strings.HasSuffix(r.URL.Path, "/poolz") {
							dispatches++
						}
						return baseClient.Transport.RoundTrip(r)
					})}
					h, store, dbPath, cfg := newWalletSessionHarness(t, client)
					cfg.Features.RelayBlindRequests.Enabled = enabled
					cfg.Features.ResponsesAPIEnabled = route.adaptersEnabled
					cfg.Features.AnthropicMessagesEnabled = route.adaptersEnabled
					cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
					body := []byte(validRelayBlindRequestEnvelope(t, map[string]any{"endpoint_family": route.family}))
					if bound != "available" {
						cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 1
					}
					if bound == "rows" {
						cfg.Auth.WalletSessions.ReplayMaxRowsPerSession = 1
					}
					if bound == "bytes" {
						cfg.Auth.WalletSessions.ReplayMaxBytesPerSession = int64(len(body))
					}
					h = New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client)).Handler()
					accountID := "acct_wallet_relay_precedence"
					key := createAccountAndKey(t, store, cfg, accountID)
					wallet := registerWalletSessionViaAPI(t, h, cfg, key, accountID, []string{"model-a"})
					send := func(id string, payload []byte) *httptest.ResponseRecorder {
						response := httptest.NewRecorder()
						h.ServeHTTP(response, signedWalletRequest(t, wallet, http.MethodPost, route.path, route.path, id, payload))
						return response
					}
					firstID := "018f7b7b-7c35-4cf0-8d4e-3f0ab1c4a901"
					first := send(firstID, body)
					if first.Code < 400 || first.Code == http.StatusTooManyRequests {
						t.Fatalf("first response=%d %s", first.Code, first.Body.String())
					}
					assertErrorCode(t, send(firstID, body).Body.String(), "wallet_session_duplicate_request")
					assertErrorCode(t, send(firstID, append(append([]byte(nil), body...), ' ')).Body.String(), "wallet_session_replay_mismatch")
					replayed := send("018f7b7b-7c35-4cf0-8d4e-3f0ab1c4a902", body)
					want := "relay_blind_replay"
					if bound == "rows" || bound == "bytes" {
						want = "wallet_session_replay_capacity_exhausted"
					}
					if replayed.Code != http.StatusConflict {
						t.Fatalf("replay status=%d want 409: %s", replayed.Code, replayed.Body.String())
					}
					assertErrorCode(t, replayed.Body.String(), want)
					assertBodyRetryable(t, replayed.Body.String(), false)
					db, err := sql.Open("sqlite", dbPath)
					if err != nil {
						t.Fatal(err)
					}
					defer db.Close()
					var rows int
					if err := db.QueryRow(`SELECT COUNT(*) FROM wallet_session_replays WHERE session_id = ?`, wallet.SessionID).Scan(&rows); err != nil {
						t.Fatal(err)
					}
					wantRows := 1
					if bound == "available" {
						wantRows = 2
					}
					if rows != wantRows || dispatches != 0 {
						t.Fatalf("metadata rows=%d want %d; dispatches=%d want 0", rows, wantRows, dispatches)
					}
					if bound == "rate" {
						var audits int
						if err := db.QueryRow(`SELECT COUNT(*) FROM audit_events WHERE event_type = 'wallet_session_rejected' AND json_extract(payload_json, '$.reason') = 'relay_blind_replay'`).Scan(&audits); err != nil || audits != 1 {
							t.Fatalf("replay audits=%d want 1 err=%v", audits, err)
						}
					}
					assertNoDailyUsage(t, store, accountID)
				})
			}
		}
	}
}

func TestRelayBlindWalletThrottleDoesNotClassifyInvalidOrFreshReplay(t *testing.T) {
	for _, tc := range []struct {
		name      string
		overrides map[string]any
	}{
		{"fresh", map[string]any{"request_id": "fresh-request", "request_replay_nonce": "fresh-nonce", "buyer_ephemeral_public_key": "fresh-key"}},
		{"downgrade", map[string]any{"mode": "preferred"}},
		{"unknown_field", map[string]any{"unexpected": "value"}},
		{"stale", map[string]any{"issued_at_unix": fixedNow().Add(-2 * time.Minute).Unix()}},
		{"wrong_route", map[string]any{"endpoint_family": "responses"}},
		{"model_denied", map[string]any{"model": "model-b"}},
		{"cap_exceeded", map[string]any{"reservation_token_cap": 51}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client := walletModelsClient()
			h, store, _, cfg := newWalletSessionHarness(t, client)
			cfg.Features.RelayBlindRequests.Enabled = true
			cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 1
			h = New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client)).Handler()
			accountID := "acct_wallet_relay_controls"
			key := createAccountAndKey(t, store, cfg, accountID)
			wallet := registerWalletSessionViaAPI(t, h, cfg, key, accountID, []string{"model-a"})
			send := func(id string, overrides map[string]any) *httptest.ResponseRecorder {
				response := httptest.NewRecorder()
				h.ServeHTTP(response, signedWalletRequest(t, wallet, http.MethodPost, "/v1/chat/completions", "/v1/chat/completions", id, []byte(validRelayBlindRequestEnvelope(t, overrides))))
				return response
			}
			assertErrorCode(t, send("018f7b7b-7c35-4cf0-8d4e-3f0ab1c4a901", nil).Body.String(), "relay_blind_required_unavailable")
			response := send("018f7b7b-7c35-4cf0-8d4e-3f0ab1c4a902", tc.overrides)
			if response.Code != http.StatusTooManyRequests {
				t.Fatalf("status=%d want 429 body=%s", response.Code, response.Body.String())
			}
			assertErrorCode(t, response.Body.String(), "wallet_session_rate_limited")
			assertBodyRetryable(t, response.Body.String(), true)
			assertNoDailyUsage(t, store, accountID)
		})
	}
}
