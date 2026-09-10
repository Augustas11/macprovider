package router

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
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

func TestRelayBlindHandlerCiphertextAndPlaintextBodyLimits(t *testing.T) {
	const requestID = "123e4567-e89b-42d3-a456-426614174088"
	res, raw := protocolEdgeMaxEnvelope(t, requestID)
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	var consumed, dispatched atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/relay-blind/consume":
			consumed.Add(1)
			body, _ := io.ReadAll(r.Body)
			if !bytes.Equal(body, raw) {
				t.Errorf("consume body changed: got %d bytes, want %d", len(body), len(raw))
			}
			_ = json.NewEncoder(w).Encode(relayblind.ConsumeResponse{
				Version:                relayblind.ConsumeVersion,
				ProviderBinding:        res.ProviderBinding,
				BuyerBinding:           res.BuyerBinding,
				EnvelopeDigest:         digestText,
				ExecutionAuthorization: "protocol-edge-authorization",
				ConsumedAtUnix:         fixedNow().Unix(),
				ExpiresAtUnix:          res.ExpiresAtUnix,
			})
		case "/v1/chat/completions":
			dispatched.Add(1)
			w.Header().Set(relayBlindValidatedHeader, digestText)
			w.Header().Set(settlementModeHeader, "observe")
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"id":"edge","object":"chat.completion","model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()

	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		c.Features.RelayBlindRequests.Enabled = true
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "protocol-edge-body")
	post := func(id string, body []byte) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+key)
		r.Header.Set("X-Request-ID", id)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}

	t.Run("decoded ciphertext exactly one MiB", func(t *testing.T) {
		var env relayblind.Envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			t.Fatal(err)
		}
		ciphertext, err := base64.RawURLEncoding.Strict().DecodeString(env.Ciphertext)
		if err != nil || len(ciphertext) != relayblind.MaxEncryptedRequestBytes {
			t.Fatalf("decoded ciphertext bytes=%d err=%v", len(ciphertext), err)
		}
		w := post(requestID, raw)
		if w.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
		}
		if consumed.Load() != 1 || dispatched.Load() != 1 {
			t.Fatalf("consume=%d dispatch=%d", consumed.Load(), dispatched.Load())
		}
	})

	t.Run("decoded ciphertext one byte over one MiB", func(t *testing.T) {
		var env relayblind.Envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			t.Fatal(err)
		}
		env.Ciphertext = base64.RawURLEncoding.EncodeToString(make([]byte, relayblind.MaxEncryptedRequestBytes+1))
		over, err := json.Marshal(env)
		if err != nil {
			t.Fatal(err)
		}
		w := post(requestID, over)
		if w.Code != http.StatusBadRequest {
			t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
		}
		assertErrorCode(t, w.Body.String(), "relay_blind_envelope_invalid")
		if consumed.Load() != 1 || dispatched.Load() != 1 {
			t.Fatalf("oversized ciphertext reached upstream: consume=%d dispatch=%d", consumed.Load(), dispatched.Load())
		}
	})

	for _, tc := range []struct {
		name string
		body func(int) []byte
	}{
		{
			name: "plaintext one byte over request body limit",
			body: func(limit int) []byte { return bytes.Repeat([]byte{'x'}, limit+1) },
		},
		{
			name: "plaintext nested relay version one byte over request body limit",
			body: func(limit int) []byte {
				prefix := []byte(`{"nested":{"version":"relay-blind-request-v1"},"padding":"`)
				suffix := []byte(`"}`)
				return append(append(prefix, bytes.Repeat([]byte{'x'}, limit+1-len(prefix)-len(suffix))...), suffix...)
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := tc.body(int(cfg.Limits.RequestBodyBytes))
			if int64(len(body)) != cfg.Limits.RequestBodyBytes+1 {
				t.Fatalf("fixture bytes=%d want=%d", len(body), cfg.Limits.RequestBodyBytes+1)
			}
			w := post("123e4567-e89b-42d3-a456-426614174099", body)
			if w.Code != http.StatusRequestEntityTooLarge {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
			assertErrorCode(t, w.Body.String(), "request_too_large")
			if consumed.Load() != 1 || dispatched.Load() != 1 {
				t.Fatalf("oversized plaintext reached upstream: consume=%d dispatch=%d", consumed.Load(), dispatched.Load())
			}
		})
	}
}

func TestRelayBlindHandlerRejectsMalformedOriginalUsageAndBoundsValidOvercap(t *testing.T) {
	cases := []struct {
		name      string
		usageJSON string
		valid     bool
	}{
		{name: "mismatched total", usageJSON: `{"prompt_tokens":4,"completion_tokens":2,"total_tokens":7}`},
		{name: "negative", usageJSON: `{"prompt_tokens":-1,"completion_tokens":2,"total_tokens":1}`},
		{name: "overflow", usageJSON: `{"prompt_tokens":9223372036854775807,"completion_tokens":1,"total_tokens":9223372036854775807}`},
		{name: "valid over clear input cap", usageJSON: `{"prompt_tokens":20,"completion_tokens":2,"total_tokens":22}`, valid: true},
	}
	for _, stream := range []bool{false, true} {
		stream := stream
		for _, tc := range cases {
			tc := tc
			name := map[bool]string{false: "nonstream", true: "stream"}[stream] + "/" + tc.name
			t.Run(name, func(t *testing.T) {
				res, _ := pilotReservationFixture(t, stream)
				raw := pilotEnvelopeFixture(t, res)
				digest := sha256.Sum256(raw)
				digestText := base64.RawURLEncoding.EncodeToString(digest[:])
				upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					switch r.URL.Path {
					case "/v1/relay-blind/consume":
						_ = json.NewEncoder(w).Encode(relayblind.ConsumeResponse{
							Version:                relayblind.ConsumeVersion,
							ProviderBinding:        res.ProviderBinding,
							BuyerBinding:           res.BuyerBinding,
							EnvelopeDigest:         digestText,
							ExecutionAuthorization: "protocol-edge-authorization",
							ConsumedAtUnix:         fixedNow().Unix(),
							ExpiresAtUnix:          res.ExpiresAtUnix,
						})
					case "/v1/chat/completions":
						w.Header().Set(relayBlindValidatedHeader, digestText)
						w.Header().Set(settlementModeHeader, "observe")
						if stream {
							w.Header().Set("Content-Type", "text/event-stream")
							_, _ = fmt.Fprintf(w, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[],\"usage\":%s}\n\ndata: [DONE]\n\n", tc.usageJSON)
						} else {
							w.Header().Set("Content-Type", "application/json")
							_, _ = fmt.Fprintf(w, `{"id":"edge","object":"chat.completion","model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":%s}`, tc.usageJSON)
						}
					default:
						http.NotFound(w, r)
					}
				}))
				defer upstream.Close()

				h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
					c.Features.RelayBlindRequests.Enabled = true
					c.Coordinator.BuyerURL = upstream.URL
				})
				account := "protocol-edge-usage"
				key := createAccountAndKey(t, store, cfg, account)
				r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(raw))
				r.Header.Set("Authorization", "Bearer "+key)
				r.Header.Set("X-Request-ID", "123e4567-e89b-42d3-a456-426614174088")
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)

				used, held, err := store.DailyUsage(context.Background(), account, fixedNow().Format("2006-01-02"))
				if err != nil {
					t.Fatal(err)
				}
				visible, found := protocolEdgeVisibleUsage(t, w.Body.Bytes(), stream)
				if tc.valid {
					if w.Code != http.StatusOK {
						t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
					}
					if !found || visible != (protocolEdgeUsage{PromptTokens: 20, CompletionTokens: 2, TotalTokens: 22}) {
						t.Fatalf("visible usage=%+v found=%v body=%s", visible, found, w.Body.String())
					}
					if used != 18 || held != 0 {
						t.Fatalf("bounded settlement used=%d held=%d", used, held)
					}
					return
				}

				if found {
					t.Fatalf("malformed original usage remained buyer-visible: %+v body=%s", visible, w.Body.String())
				}
				if stream {
					if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "data: [DONE]") {
						t.Fatalf("stream status=%d body=%s", w.Code, w.Body.String())
					}
					if used < 0 || used > res.MaxOutputTokens || held != 0 {
						t.Fatalf("stream fallback settlement used=%d held=%d cap=%d", used, held, res.MaxOutputTokens)
					}
				} else {
					if w.Code != http.StatusBadGateway {
						t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
					}
					assertErrorCode(t, w.Body.String(), "invalid_provider_usage")
					if used != 0 || held != 0 {
						t.Fatalf("nonstream malformed settlement used=%d held=%d", used, held)
					}
				}
			})
		}
	}
}

func TestRelayBlindReservationResponseEncryptedByteBounds(t *testing.T) {
	const requestedBytes = int64(512)
	for _, tc := range []struct {
		name        string
		responseMax uint64
		wantStatus  int
	}{
		{name: "equal accepted", responseMax: uint64(requestedBytes), wantStatus: http.StatusOK},
		{name: "higher accepted", responseMax: 4096, wantStatus: http.StatusOK},
		{name: "below rejected", responseMax: uint64(requestedBytes - 1), wantStatus: http.StatusServiceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res, _ := pilotReservationFixture(t, false)
			res.MaxEncryptedRequestBytes = tc.responseMax
			var calls atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v1/relay-blind/route-reservations" {
					http.NotFound(w, r)
					return
				}
				calls.Add(1)
				_ = json.NewEncoder(w).Encode(res)
			}))
			defer upstream.Close()

			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Features.RelayBlindRequests.Enabled = true
				c.Coordinator.BuyerURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, "protocol-edge-reservation")
			body := fmt.Sprintf(`{"endpoint_family":"chat_completions","model":"test-model","stream":false,"max_output_tokens":8,"input_token_upper_bound":16,"encrypted_request_bytes":%d}`, requestedBytes)
			r := httptest.NewRequest(http.MethodPost, "/v1/relay-blind/route-reservations", strings.NewReader(body))
			r.Header.Set("Authorization", "Bearer "+key)
			r.Header.Set("X-Request-ID", "123e4567-e89b-42d3-a456-426614174088")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.wantStatus {
				t.Fatalf("status=%d want=%d body=%s", w.Code, tc.wantStatus, w.Body.String())
			}
			if tc.wantStatus != http.StatusOK {
				assertErrorCode(t, w.Body.String(), "relay_blind_required_unavailable")
			}
			if calls.Load() != 1 {
				t.Fatalf("reservation calls=%d", calls.Load())
			}
		})
	}
}

func protocolEdgeMaxEnvelope(t *testing.T, requestID string) (relayblind.ReservationResponse, []byte) {
	t.Helper()
	providerKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, identityKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	record, err := relayblind.NewSignedKeyRecord(providerKey.PublicKey().Bytes(), identityKey, []string{"test-model"}, relayblind.MaxEncryptedRequestBytes, fixedNow().Add(-time.Minute), fixedNow().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	randomBinding := func() string {
		value := make([]byte, 32)
		if _, err := rand.Read(value); err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(value)
	}
	res := relayblind.ReservationResponse{
		Version:                  relayblind.ReservationVersion,
		ProviderBinding:          randomBinding(),
		BuyerBinding:             randomBinding(),
		KeyRecordDigest:          record.KeyRecordDigest,
		KeyRecord:                record,
		KID:                      record.KID,
		EndpointFamily:           relayblind.EndpointChatCompletions,
		Model:                    "test-model",
		ProviderModel:            "test-model",
		Stream:                   false,
		MaxEncryptedRequestBytes: relayblind.MaxEncryptedRequestBytes,
		MaxOutputTokens:          8,
		InputTokenUpperBound:     16,
		ReservationTokenCap:      24,
		ExpiresAtUnix:            fixedNow().Add(30 * time.Second).Unix(),
		CachePolicy:              relayblind.CachePolicyNoStore,
		FailoverPolicy:           relayblind.FailoverPolicyDisabled,
	}
	replayNonce := make([]byte, 32)
	if _, err := rand.Read(replayNonce); err != nil {
		t.Fatal(err)
	}
	env, err := res.NewEnvelope(requestID, fixedNow(), replayNonce)
	if err != nil {
		t.Fatal(err)
	}
	buyerKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	env, err = env.Encrypt(bytes.Repeat([]byte{'x'}, relayblind.MaxEncryptedRequestBytes), providerKey.PublicKey().Bytes(), buyerKey.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}
	return res, raw
}

type protocolEdgeUsage struct {
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
	TotalTokens      int64 `json:"total_tokens"`
}

func protocolEdgeVisibleUsage(t *testing.T, body []byte, stream bool) (protocolEdgeUsage, bool) {
	t.Helper()
	decode := func(raw []byte) (protocolEdgeUsage, bool) {
		var envelope struct {
			Usage *protocolEdgeUsage `json:"usage"`
		}
		if json.Unmarshal(raw, &envelope) != nil || envelope.Usage == nil {
			return protocolEdgeUsage{}, false
		}
		return *envelope.Usage, true
	}
	if !stream {
		return decode(body)
	}
	for _, line := range bytes.Split(body, []byte("\n")) {
		line = bytes.TrimSpace(line)
		if !bytes.HasPrefix(line, []byte("data: ")) || bytes.Equal(line, []byte("data: [DONE]")) {
			continue
		}
		if usage, ok := decode(bytes.TrimPrefix(line, []byte("data: "))); ok {
			return usage, true
		}
	}
	return protocolEdgeUsage{}, false
}
