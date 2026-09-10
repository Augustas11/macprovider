package router

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

func relayBlindRecoveryMetadata(t *testing.T, reservation relayblind.ReservationResponse, raw []byte) *storage.RelayBlindMetadata {
	t.Helper()
	envelope, err := relayblind.ParseEnvelope(raw)
	if err != nil {
		t.Fatal(err)
	}
	envelopeDigest := sha256.Sum256(raw)
	bindingDigest := sha256.Sum256([]byte(envelope.ProviderBinding))
	return &storage.RelayBlindMetadata{
		RequestedPrivacyMode:    "relay_blind_required",
		EffectivePrivacyOutcome: "relay_blind_unavailable",
		EnvelopeDigest:          base64.RawURLEncoding.EncodeToString(envelopeDigest[:]),
		KeyRecordDigest:         envelope.KeyRecordDigest,
		KID:                     envelope.KID,
		ProviderBindingDigest:   base64.RawURLEncoding.EncodeToString(bindingDigest[:]),
		InputTokenUpperBound:    reservation.InputTokenUpperBound,
		MaxOutputTokens:         reservation.MaxOutputTokens,
	}
}

func seedRelayBlindAPIHold(t *testing.T, store *sqlite.Store, accountID, requestID string, metadata *storage.RelayBlindMetadata) {
	t.Helper()
	ctx := context.Background()
	if err := store.CreateAccount(ctx, storage.Account{
		AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: accountID, RequestID: requestID, WindowDate: fixedNow().Format("2006-01-02"),
		RequestedTokens: metadata.InputTokenUpperBound + metadata.MaxOutputTokens, DailyQuota: 100,
		CreatedAt: fixedNow(), ExpiresAt: fixedNow().Add(time.Hour), RelayBlind: metadata,
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.MarkReservationSettlementHold(ctx, accountID, requestID); err != nil {
		t.Fatal(err)
	}
}

func TestRelayBlindRecoveryStatusEdges(t *testing.T) {
	inputSix := int64(6)
	completionSeven := int64(7)
	for _, tc := range []struct {
		name          string
		status        relayblind.StatusResponse
		wantUsed      int64
		wantPrompt    int64
		wantEffective string
	}{
		{
			name: "unknown_postdispatch_unvalidated",
			status: relayblind.StatusResponse{Version: relayblind.StatusVersion, State: "unknown_postdispatch",
				EffectivePrivacyOutcome: "relay_blind_unavailable", RetryAction: relayblind.RetryDoNotResubmit},
			wantEffective: "relay_blind_unavailable",
		},
		{
			name: "unknown_postdispatch_validated",
			status: relayblind.StatusResponse{Version: relayblind.StatusVersion, State: "unknown_postdispatch", Validated: true,
				InputTokens: &inputSix, EffectivePrivacyOutcome: "relay_blind_satisfied", RetryAction: relayblind.RetryDoNotResubmit},
			wantUsed: 6, wantPrompt: 6, wantEffective: "relay_blind_satisfied",
		},
		{
			name: "terminal_validated_but_privacy_unavailable",
			status: relayblind.StatusResponse{Version: relayblind.StatusVersion, State: "terminal", Validated: true,
				InputTokens: &inputSix, CompletionTokens: &completionSeven, EffectivePrivacyOutcome: "relay_blind_unavailable", RetryAction: relayblind.RetryDoNotResubmit},
			wantUsed: 6, wantPrompt: 6, wantEffective: "relay_blind_unavailable",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var statusCalls atomic.Int32
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if r.URL.Path != "/v1/relay-blind/status" {
					return responseWithBody(http.StatusNotFound, nil, `{}`), nil
				}
				statusCalls.Add(1)
				body, err := json.Marshal(tc.status)
				if err != nil {
					t.Fatal(err)
				}
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": {"application/json"}}, string(body)), nil
			})}
			_, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Features.RelayBlindRequests.Enabled = true
			}, WithHTTPClient(client))
			reservation, _ := pilotReservationFixture(t, false)
			raw := pilotEnvelopeFixture(t, reservation)
			accountID := "acct_recovery_" + tc.name
			requestID := "req_recovery_" + tc.name
			seedRelayBlindAPIHold(t, store, accountID, requestID, relayBlindRecoveryMetadata(t, reservation, raw))

			server := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client))
			summary, err := server.ReconcileSettlementHolds(context.Background(), 10)
			if err != nil || summary.Observed != 1 || summary.Errors != 0 {
				t.Fatalf("summary=%+v err=%v", summary, err)
			}
			if statusCalls.Load() != 1 {
				t.Fatalf("status calls=%d want 1", statusCalls.Load())
			}
			used, held, err := store.DailyUsage(context.Background(), accountID, fixedNow().Format("2006-01-02"))
			if err != nil || used != tc.wantUsed || held != 0 {
				t.Fatalf("used/held=%d/%d want %d/0 err=%v", used, held, tc.wantUsed, err)
			}
			db, err := sql.Open("sqlite", dbPath)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			var prompt, completion int64
			var effective string
			if err := db.QueryRow(`SELECT prompt_tokens, completion_tokens, effective_privacy_outcome FROM usage_events
				WHERE account_id = ? AND request_id = ?`, accountID, requestID).Scan(&prompt, &completion, &effective); err != nil {
				t.Fatal(err)
			}
			if prompt != tc.wantPrompt || completion != 0 || effective != tc.wantEffective {
				t.Fatalf("usage prompt/completion/effective=%d/%d/%s want %d/0/%s", prompt, completion, effective, tc.wantPrompt, tc.wantEffective)
			}
		})
	}
}

func TestRelayBlindConsumedPredispatchThenRejectedRefundsExactlyOnce(t *testing.T) {
	for _, wallet := range []bool{false, true} {
		name := "api"
		if wallet {
			name = "wallet"
		}
		t.Run(name, func(t *testing.T) {
			var statusCalls atomic.Int32
			modelsClient := walletModelsClient()
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if r.URL.Path != "/v1/relay-blind/status" {
					return modelsClient.Do(r)
				}
				state := "consumed_predispatch"
				if statusCalls.Add(1) > 1 {
					state = "rejected"
				}
				status := relayblind.StatusResponse{Version: relayblind.StatusVersion, State: state,
					EffectivePrivacyOutcome: "relay_blind_unavailable", RetryAction: relayblind.RetryDoNotResubmit}
				body, err := json.Marshal(status)
				if err != nil {
					t.Fatal(err)
				}
				return responseWithBody(http.StatusOK, http.Header{"Content-Type": {"application/json"}}, string(body)), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Public.BaseURL = "https://api.malibu.test"
				c.Features.RelayBlindRequests.Enabled = true
				c.Auth.WalletSessions.Enabled = true
				c.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
				c.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
				c.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
				c.Auth.WalletSessions.MetadataRequestsPerMinute = 100
			}, WithHTTPClient(client))
			reservation, _ := pilotReservationFixture(t, false)
			raw := pilotEnvelopeFixture(t, reservation)
			metadata := relayBlindRecoveryMetadata(t, reservation, raw)
			accountID := "acct_rejected_" + name
			requestID := "req_rejected_" + name
			walletSessionID := ""
			if !wallet {
				seedRelayBlindAPIHold(t, store, accountID, requestID, metadata)
			} else {
				apiKey := createAccountAndKey(t, store, cfg, accountID)
				walletClient := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, []string{"model-a"}, 100, 24)
				walletSessionID = walletClient.SessionID
				hash := sha256.Sum256([]byte("wallet-recovery-replay"))
				if _, err := store.AdmitWalletSessionInference(context.Background(), storage.WalletSessionAdmissionRequest{
					RelayBlind: metadata, SessionID: walletSessionID, AccountID: accountID, RequestID: requestID,
					Method: http.MethodPost, CanonicalRoute: "/v1/chat/completions", ModelID: "model-a",
					WindowDate: fixedNow().Format("2006-01-02"), RequestedTokens: 24, DailyQuota: 100,
					Replay: storage.WalletSessionReplayMaterial{SessionID: walletSessionID, AccountID: accountID, RequestID: requestID,
						Method: http.MethodPost, CanonicalRoute: "/v1/chat/completions", SemanticHeadersHash: hash[:], RawBodyHash: hash[:], BodyBytes: int64(len(raw))},
					CreatedAt: fixedNow(), ExpiresAt: fixedNow().Add(time.Hour),
				}); err != nil {
					t.Fatal(err)
				}
				if err := store.ArmWalletSessionDispatch(context.Background(), storage.WalletSessionDispatchArm{
					SessionID: walletSessionID, AccountID: accountID, RequestID: requestID, CanonicalRoute: "/v1/chat/completions", ArmedAt: fixedNow(),
				}); err != nil {
					t.Fatal(err)
				}
			}

			server := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client))
			first, err := server.ReconcileSettlementHolds(context.Background(), 10)
			if err != nil || first.Held != 1 || first.Refunded != 0 {
				t.Fatalf("consumed summary=%+v err=%v", first, err)
			}
			second, err := server.ReconcileSettlementHolds(context.Background(), 10)
			if err != nil || second.Refunded != 1 {
				t.Fatalf("rejected summary=%+v err=%v", second, err)
			}
			third, err := server.ReconcileSettlementHolds(context.Background(), 10)
			if err != nil || third.Scanned != 0 || statusCalls.Load() != 2 {
				t.Fatalf("repeat summary=%+v status_calls=%d err=%v", third, statusCalls.Load(), err)
			}
			db, err := sql.Open("sqlite", dbPath)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			var quotaRefunds, usageRows int
			if err := db.QueryRow(`SELECT COUNT(*) FROM quota_reservations WHERE account_id = ? AND request_id = ? AND status = 'refunded'`, accountID, requestID).Scan(&quotaRefunds); err != nil {
				t.Fatal(err)
			}
			if err := db.QueryRow(`SELECT COUNT(*) FROM usage_events WHERE account_id = ? AND request_id = ?`, accountID, requestID).Scan(&usageRows); err != nil {
				t.Fatal(err)
			}
			if quotaRefunds != 1 || usageRows != 0 {
				t.Fatalf("quota refunds/usage rows=%d/%d want 1/0", quotaRefunds, usageRows)
			}
			if walletSessionID != "" {
				var walletRefunds int
				if err := db.QueryRow(`SELECT COUNT(*) FROM wallet_session_reservations WHERE session_id = ? AND request_id = ? AND status = 'refunded'`, walletSessionID, requestID).Scan(&walletRefunds); err != nil {
					t.Fatal(err)
				}
				if walletRefunds != 1 {
					t.Fatalf("wallet refunds=%d want 1", walletRefunds)
				}
			}
		})
	}
}

func TestRelayBlindConsumeFailureNeverDispatchesAndReplayNeedsFreshEnvelope(t *testing.T) {
	for _, tc := range []struct {
		name      string
		transport func(relayblind.ReservationResponse) http.RoundTripper
	}{
		{
			name: "response_loss",
			transport: func(_ relayblind.ReservationResponse) http.RoundTripper {
				return roundTripFunc(func(r *http.Request) (*http.Response, error) {
					if r.URL.Path == "/v1/relay-blind/consume" {
						return nil, errors.New("consume response lost")
					}
					return responseWithBody(http.StatusNotFound, nil, `{}`), nil
				})
			},
		},
		{
			name: "malformed_evidence",
			transport: func(_ relayblind.ReservationResponse) http.RoundTripper {
				return roundTripFunc(func(r *http.Request) (*http.Response, error) {
					if r.URL.Path == "/v1/relay-blind/consume" {
						return responseWithBody(http.StatusOK, http.Header{"Content-Type": {"application/json"}}, `{"version":"relay-blind-consume-v1","provider_binding":"wrong"}`), nil
					}
					return responseWithBody(http.StatusNotFound, nil, `{}`), nil
				})
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reservation, _ := pilotReservationFixture(t, false)
			raw := pilotEnvelopeFixture(t, reservation)
			var dispatches atomic.Int32
			base := tc.transport(reservation)
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/v1/chat/completions" {
					dispatches.Add(1)
				}
				return base.RoundTrip(r)
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Features.RelayBlindRequests.Enabled = true
			}, WithHTTPClient(client))
			key := createAccountAndKey(t, store, cfg, "acct_consume_"+tc.name)
			send := func() *httptest.ResponseRecorder {
				r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(raw))
				r.Header.Set("Authorization", "Bearer "+key)
				r.Header.Set("X-Request-ID", "123e4567-e89b-42d3-a456-426614174088")
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)
				return w
			}
			first := send()
			if first.Code != http.StatusServiceUnavailable || first.Header().Get("X-MacProvider-Relay-Blind-Retry-Action") != "new_reservation_and_envelope" {
				t.Fatalf("first status/retry=%d/%q body=%s", first.Code, first.Header().Get("X-MacProvider-Relay-Blind-Retry-Action"), first.Body.String())
			}
			second := send()
			if second.Code != http.StatusConflict {
				t.Fatalf("replay status=%d body=%s", second.Code, second.Body.String())
			}
			assertErrorCode(t, second.Body.String(), "relay_blind_replay")
			var replayBody struct {
				Error struct {
					MacProvider struct {
						RetryAction string `json:"retry_action"`
					} `json:"macprovider"`
				} `json:"error"`
			}
			if err := json.Unmarshal(second.Body.Bytes(), &replayBody); err != nil {
				t.Fatal(err)
			}
			if replayBody.Error.MacProvider.RetryAction != "do_not_resubmit" {
				t.Fatalf("replay retry action=%q want do_not_resubmit", replayBody.Error.MacProvider.RetryAction)
			}
			if dispatches.Load() != 0 {
				t.Fatalf("dispatches=%d want 0", dispatches.Load())
			}
			assertNoDailyUsage(t, store, "acct_consume_"+tc.name)
		})
	}
}
