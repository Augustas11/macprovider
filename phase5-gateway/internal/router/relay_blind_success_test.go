package router

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

func pilotReservationFixture(t *testing.T, stream bool) (relayblind.ReservationResponse, []byte) {
	t.Helper()
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, identity, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	record, err := relayblind.NewSignedKeyRecord(key.PublicKey().Bytes(), identity, []string{"test-model"}, 4096, fixedNow().Add(-time.Minute), fixedNow().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	random := func() string {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(b)
	}
	return relayblind.ReservationResponse{Version: relayblind.ReservationVersion, ProviderBinding: random(), BuyerBinding: random(), KeyRecordDigest: record.KeyRecordDigest, KeyRecord: record, KID: record.KID, EndpointFamily: "chat_completions", Model: "test-model", ProviderModel: "test-model", Stream: stream, MaxEncryptedRequestBytes: 4096, MaxOutputTokens: 8, InputTokenUpperBound: 16, ReservationTokenCap: 24, ExpiresAtUnix: fixedNow().Add(30 * time.Second).Unix(), CachePolicy: "no-store", FailoverPolicy: "disabled"}, key.Bytes()
}
func pilotEnvelopeFixture(t *testing.T, res relayblind.ReservationResponse) []byte {
	t.Helper()
	nonce := make([]byte, 32)
	rand.Read(nonce)
	env, err := res.NewEnvelope("123e4567-e89b-42d3-a456-426614174088", fixedNow(), nonce)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := res.KeyRecord.EncryptionPublicKey()
	if err != nil {
		t.Fatal(err)
	}
	inner, _ := json.Marshal(map[string]any{"model": "test-model", "messages": []any{map[string]any{"role": "user", "content": "PRIVATE_PILOT_CANARY"}}, "max_tokens": 8, "stream": res.Stream})
	env, err = env.Encrypt(inner, pub, key.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// Unit integration with an authenticated coordinator stub. Real service and Swift
// provider evidence belongs to test/integration, not this boundary test.
func TestRelayBlindSuccessfulChatUsesExistingSettlementAndNeverRetries(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(map[bool]string{false: "nonstream", true: "stream"}[stream], func(t *testing.T) {
			res, _ := pilotReservationFixture(t, stream)
			raw := pilotEnvelopeFixture(t, res)
			digest := sha256.Sum256(raw)
			digestText := base64.RawURLEncoding.EncodeToString(digest[:])
			var consumed, dispatched atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer service-token" || r.Header.Get("X-MacProvider-Account") != "pilot-account" {
					t.Error("missing trusted auth/account")
				}
				switch r.URL.Path {
				case "/v1/relay-blind/route-reservations":
					json.NewEncoder(w).Encode(res)
				case "/v1/relay-blind/consume":
					consumed.Add(1)
					body, _ := io.ReadAll(r.Body)
					if !bytes.Equal(body, raw) {
						t.Error("envelope mutated")
					}
					json.NewEncoder(w).Encode(relayblind.ConsumeResponse{Version: relayblind.ConsumeVersion, ProviderBinding: res.ProviderBinding, BuyerBinding: res.BuyerBinding, EnvelopeDigest: digestText, ExecutionAuthorization: "internal-execution-authorization", ConsumedAtUnix: fixedNow().Unix(), ExpiresAtUnix: res.ExpiresAtUnix})
				case "/v1/chat/completions":
					dispatched.Add(1)
					body, _ := io.ReadAll(r.Body)
					if !bytes.Equal(body, raw) || bytes.Contains(body, []byte("PRIVATE_PILOT_CANARY")) {
						t.Error("opaque body changed or plaintext forwarded")
					}
					if r.Header.Get(relayBlindExecutionHeader) != "internal-execution-authorization" {
						t.Error("missing execution authority")
					}
					w.Header().Set(relayBlindValidatedHeader, digestText)
					w.Header().Set(settlementModeHeader, "observe")
					w.Header().Set("X-MacProvider-Provider", "stable-provider-secret")
					if stream {
						w.Header().Set("Content-Type", "text/event-stream")
						io.WriteString(w, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":2,\"total_tokens\":22}}\n\ndata: [DONE]\n\n")
					} else {
						json.NewEncoder(w).Encode(map[string]any{"id": "completion", "object": "chat.completion", "model": "test-model", "choices": []any{map[string]any{"message": map[string]any{"role": "assistant", "content": "ok"}, "finish_reason": "stop", "index": 0}}, "usage": map[string]any{"prompt_tokens": 20, "completion_tokens": 2, "total_tokens": 22}})
					}
				default:
					w.WriteHeader(404)
				}
			}))
			defer upstream.Close()
			h, store, path, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Features.RelayBlindRequests.Enabled = true
				c.Coordinator.BuyerURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, "pilot-account")
			post := func(body []byte) *httptest.ResponseRecorder {
				r := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewReader(body))
				r.Header.Set("Authorization", "Bearer "+key)
				r.Header.Set("X-Request-ID", "123e4567-e89b-42d3-a456-426614174088")
				r.Header.Set(relayBlindExecutionHeader, "spoofed")
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)
				return w
			}
			w := post(raw)
			if w.Code != 200 {
				t.Fatalf("status %d body %s", w.Code, w.Body.String())
			}
			if w.Header().Get(relayBlindEffectiveHeader) != "relay_blind_satisfied" || w.Header().Get("X-Provider-Id") != "" || strings.Contains(w.Body.String(), "stable-provider-secret") {
				t.Fatal("incorrect privacy disclosure")
			}
			if !strings.Contains(w.Body.String(), "unavailable_for_relay_blind_request") {
				t.Fatalf("missing settlement metadata: %s", w.Body.String())
			}
			replay := post(raw)
			if replay.Code != 409 {
				t.Fatalf("replay status %d: %s", replay.Code, replay.Body.String())
			}
			if consumed.Load() != 1 || dispatched.Load() != 1 {
				t.Fatalf("consume %d dispatch %d", consumed.Load(), dispatched.Load())
			}
			used, held, err := store.DailyUsage(context.Background(), "pilot-account", fixedNow().Format("2006-01-02"))
			if err != nil {
				t.Fatal(err)
			}
			if used != 18 || held != 0 {
				t.Fatalf("usage=%d held=%d", used, held)
			}
			db, err := sql.Open("sqlite", path)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			var count int
			if err = db.QueryRow("SELECT count(*) FROM usage_events WHERE account_id='pilot-account'").Scan(&count); err != nil || count != 1 {
				t.Fatalf("events=%d err=%v", count, err)
			}
		})
	}
}

func TestRelayBlindLostValidationHoldsAndRecoversWithoutResubmission(t *testing.T) {
	res, _ := pilotReservationFixture(t, false)
	raw := pilotEnvelopeFixture(t, res)
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	var dispatched, statusCalls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/relay-blind/consume":
			json.NewEncoder(w).Encode(relayblind.ConsumeResponse{Version: relayblind.ConsumeVersion, ProviderBinding: res.ProviderBinding, BuyerBinding: res.BuyerBinding, EnvelopeDigest: digestText, ExecutionAuthorization: "internal-execution-authorization", ConsumedAtUnix: fixedNow().Unix(), ExpiresAtUnix: res.ExpiresAtUnix})
		case "/v1/chat/completions":
			dispatched.Add(1)
			io.WriteString(w, `{}`)
		case "/v1/relay-blind/status":
			statusCalls.Add(1)
			var query map[string]string
			json.NewDecoder(r.Body).Decode(&query)
			if query["envelope_digest"] != digestText || query["provider_binding_digest"] == "" {
				t.Error("unbound recovery lookup")
			}
			json.NewEncoder(w).Encode(map[string]any{"version": "relay-blind-status-v1", "state": "terminal", "internal_request_id": "internal-1", "validated": true, "input_tokens": 4, "completion_tokens": 8, "effective_privacy_outcome": "relay_blind_satisfied", "retry_action": "do_not_resubmit"})
		default:
			w.WriteHeader(404)
		}
	}))
	defer upstream.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		c.Features.RelayBlindRequests.Enabled = true
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "pilot-recover")
	request := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewReader(raw))
	request.Header.Set("Authorization", "Bearer "+key)
	request.Header.Set("X-Request-ID", "123e4567-e89b-42d3-a456-426614174088")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, request)
	if w.Code != 500 || !strings.Contains(w.Body.String(), "do_not_resubmit") {
		t.Fatalf("unexpected failure %d %s", w.Code, w.Body.String())
	}
	used, held, err := store.DailyUsage(context.Background(), "pilot-recover", fixedNow().Format("2006-01-02"))
	if err != nil || used != 0 || held != 24 {
		t.Fatalf("before recovery used=%d held=%d err=%v", used, held, err)
	}
	recovered := New(cfg, store, fakeOAuth{}, WithNow(fixedNow))
	for i := 0; i < 2; i++ {
		if _, err := recovered.ReconcileSettlementHolds(context.Background(), 100); err != nil {
			t.Fatal(err)
		}
	}
	used, held, err = store.DailyUsage(context.Background(), "pilot-recover", fixedNow().Format("2006-01-02"))
	if err != nil || used != 4 || held != 0 {
		t.Fatalf("recovered used=%d held=%d err=%v", used, held, err)
	}
	if dispatched.Load() != 1 || statusCalls.Load() != 1 {
		t.Fatalf("dispatch %d recovery %d", dispatched.Load(), statusCalls.Load())
	}
}

func TestRelayBlindModelCapabilitiesAreFreshAndModelScoped(t *testing.T) {
	for _, tc := range []struct {
		name, payload string
		available     bool
	}{
		{"fresh", `{"version":"relay-blind-capabilities-v1","models":{"test-model":{"capable_provider_count":1,"incapable_provider_count":1},"hidden-model":{"capable_provider_count":3,"incapable_provider_count":0}}}`, true},
		{"no-capable", `{"version":"relay-blind-capabilities-v1","models":{"test-model":{"capable_provider_count":0,"incapable_provider_count":1}}}`, false},
		{"trailing", `{"version":"relay-blind-capabilities-v1","models":{}} {}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/v1/relay-blind/capabilities" {
					if r.Header.Get("Authorization") != "Bearer service-token" {
						t.Error("missing gateway authentication")
					}
					io.WriteString(w, tc.payload)
					return
				}
				if r.URL.Path == "/v1/models" {
					io.WriteString(w, `{"object":"list","data":[{"id":"test-model","object":"model"}]}`)
					return
				}
				w.WriteHeader(404)
			}))
			defer upstream.Close()
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Features.RelayBlindRequests.Enabled = true
				c.Coordinator.BuyerURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, "capability-buyer")
			r := httptest.NewRequest("GET", "/v1/models", nil)
			r.Header.Set("Authorization", "Bearer "+key)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != 200 {
				t.Fatalf("models status %d", w.Code)
			}
			if strings.Contains(w.Body.String(), "hidden-model") {
				t.Fatal("hidden model capability leaked")
			}
			var body map[string]any
			if json.Unmarshal(w.Body.Bytes(), &body) != nil {
				t.Fatal("invalid models JSON")
			}
			rows, _ := body["data"].([]any)
			if len(rows) != 1 {
				t.Fatal("wrong models count")
			}
			row := rows[0].(map[string]any)
			d, _ := row["relay_blind_request_encryption"].(map[string]any)
			if tc.available {
				if d["scope"] != relayBlindScope {
					t.Fatal("incorrect request-only disclosure")
				}
				endpoints := d["endpoint_families"].(map[string]any)
				chat := endpoints["chat_completions"].(map[string]any)
				if chat["required_mode"] != "available" || chat["pool_composition"] != "mixed" {
					t.Fatal("incorrect capability composition")
				}
			} else if d != nil {
				endpoints := d["endpoint_families"].(map[string]any)
				chat := endpoints["chat_completions"].(map[string]any)
				if chat["required_mode"] == "available" {
					t.Fatal("unavailable evidence labeled capable")
				}
			}
		})
	}
}
