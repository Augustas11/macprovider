package buyer

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

func TestRelayBlindHTTPFlowPersistsValidationBeforeSuccess(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(map[bool]string{false: "nonstream", true: "stream"}[stream], func(t *testing.T) {
			now := time.Unix(1_800_100_000, 0).UTC()
			var dispatches atomic.Int32
			server, record, providerPrivate, closeStore := relayBlindTestServer(t, now, func(_ context.Context, _ pool.Provider, requestID string, body []byte, gotStream bool, relayContext providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
				dispatches.Add(1)
				if gotStream != stream || requestID == "" || len(body) == 0 {
					t.Errorf("unexpected dispatch stream=%v requestID=%q body=%d", gotStream, requestID, len(body))
				}
				chunks := make(chan providerws.InferenceResponseChunk)
				done := make(chan providerws.InferenceResponseEnd, 1)
				errs := make(chan error, 1)
				validations := make(chan providerws.RelayBlindValidation, 1)
				validated := relayBlindValidationForContext(relayContext, "validated", 11)
				terminal := relayBlindValidationForContext(relayContext, "terminal", 11)
				validations <- validated
				go func() {
					if stream {
						chunks <- providerws.InferenceResponseChunk{RequestID: requestID, Seq: 0, Data: "data: {\"choices\":[]}\n\n"}
					} else {
						chunks <- providerws.InferenceResponseChunk{RequestID: requestID, Seq: 0, Data: "{\"choices\":[]}"}
					}
					close(chunks)
					done <- providerws.InferenceResponseEnd{RequestID: requestID, Status: "complete", Usage: json.RawMessage(`{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}`), RelayBlindValidation: &terminal}
				}()
				return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs, Validations: validations}, nil
			})
			defer closeStore()

			reservationRequest := relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", Stream: stream, MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048}
			reservationRaw, _ := json.Marshal(reservationRequest)
			response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", reservationRaw, "")
			if response.Code != http.StatusOK {
				t.Fatalf("reservation status=%d body=%s", response.Code, response.Body.String())
			}
			reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
			if err != nil || reservation.KeyRecordDigest != record.KeyRecordDigest {
				t.Fatalf("reservation=%#v err=%v", reservation, err)
			}

			envelope, err := reservation.NewEnvelope("external-request-a", now, bytes.Repeat([]byte{0x33}, 32))
			if err != nil {
				t.Fatal(err)
			}
			buyerPrivate, err := ecdh.X25519().GenerateKey(nil)
			if err != nil {
				t.Fatal(err)
			}
			envelope, err = envelope.Encrypt([]byte(`{"model":"model-a","messages":[{"role":"user","content":"secret"}]}`), providerPrivate.PublicKey().Bytes(), buyerPrivate.Bytes())
			if err != nil {
				t.Fatal(err)
			}
			envelopeRaw, _ := json.Marshal(envelope)
			response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/consume", envelopeRaw, "")
			if response.Code != http.StatusOK {
				t.Fatalf("consume status=%d body=%s", response.Code, response.Body.String())
			}
			consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
			if err != nil {
				t.Fatal(err)
			}

			response = relayBlindRequest(t, server, http.MethodPost, "/v1/chat/completions", envelopeRaw, consume.ExecutionAuthorization)
			if response.Code != http.StatusOK {
				t.Fatalf("chat status=%d body=%s", response.Code, response.Body.String())
			}
			if got := response.Header().Get(relayBlindValidatedHeader); got != consume.EnvelopeDigest {
				t.Fatalf("validation header=%q want=%q", got, consume.EnvelopeDigest)
			}
			if got := response.Header().Get(relayBlindInputTokensHeader); got != "11" {
				t.Fatalf("input header=%q", got)
			}
			if dispatches.Load() != 1 {
				t.Fatalf("dispatches=%d", dispatches.Load())
			}

			statusRequest, _ := json.Marshal(relayblind.StatusRequest{ProviderBindingDigest: relayblind.BindingDigest(consume.ProviderBinding), EnvelopeDigest: consume.EnvelopeDigest})
			response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/status", statusRequest, "")
			status, err := relayblind.ParseStatusResponse(response.Body.Bytes())
			if response.Code != http.StatusOK || err != nil || status.State != relayblind.ReservationStateTerminal || !status.Validated || status.InputTokens == nil || *status.InputTokens != 11 || status.CompletionTokens == nil || *status.CompletionTokens != 3 || status.EffectivePrivacyOutcome != "relay_blind_satisfied" {
				t.Fatalf("status code=%d value=%#v err=%v body=%s", response.Code, status, err, response.Body.String())
			}
		})
	}
}

func TestRelayBlindStatusRejectsDuplicateAndOversizeJSON(t *testing.T) {
	now := time.Unix(1_800_100_100, 0).UTC()
	server, _, _, closeStore := relayBlindTestServer(t, now, nil)
	defer closeStore()
	digest := strings.Repeat("A", 43)
	for _, body := range [][]byte{
		[]byte(`{"provider_binding_digest":"` + digest + `","provider_binding_digest":"` + digest + `","envelope_digest":"` + digest + `"}`),
		bytes.Repeat([]byte(" "), 1025),
		{},
	} {
		response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/status", body, "")
		if response.Code != http.StatusBadRequest {
			t.Fatalf("body size=%d status=%d body=%s", len(body), response.Code, response.Body.String())
		}
	}
}

func TestRelayBlindCapabilitiesRequireGatewayBearerButNoAccount(t *testing.T) {
	now := time.Unix(1_800_100_110, 0).UTC()
	server, _, _, closeStore := relayBlindTestServer(t, now, nil)
	defer closeStore()

	request := httptest.NewRequest(http.MethodGet, "/v1/relay-blind/capabilities", nil)
	request.RemoteAddr = "127.0.0.1:43210"
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status=%d body=%s", response.Code, response.Body.String())
	}

	request = httptest.NewRequest(http.MethodGet, "/v1/relay-blind/capabilities", nil)
	request.RemoteAddr = "127.0.0.1:43210"
	request.Header.Set("Authorization", "Bearer gateway-token")
	response = httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("gateway aggregate status=%d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `"model-a":{"capable_provider_count":1,"incapable_provider_count":0}`) {
		t.Fatalf("unexpected capabilities body=%s", response.Body.String())
	}
}

func TestRelayBlindErrorCarriesCompletePrivacyMetadata(t *testing.T) {
	now := time.Unix(1_800_100_125, 0).UTC()
	server, _, _, closeStore := relayBlindTestServer(t, now, nil)
	defer closeStore()
	server.relayBlind.cfg.Enabled = false
	response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", []byte(`{}`), "")
	for _, want := range []string{
		`"requested_privacy_mode":"relay_blind_required"`,
		`"effective_privacy_outcome":"relay_blind_unavailable"`,
		`"scope":"request_content_hidden_from_relays; provider_reads_request; responses_visible_to_relays"`,
		`"retry_action":"none"`,
		`"verified_model_settlement":"unavailable_for_relay_blind_request"`,
		`"usage_settlement":"standard_usage_settlement_and_clear_cap_enforcement_still_apply"`,
	} {
		if !strings.Contains(response.Body.String(), want) {
			t.Fatalf("missing %s in %s", want, response.Body.String())
		}
	}
}

func TestRelayBlindAcceptsMaximumDecodedCiphertextEnvelope(t *testing.T) {
	now := time.Unix(1_800_100_150, 0).UTC()
	server, _, providerPrivate, closeStore := relayBlindTestServer(t, now, nil)
	defer closeStore()
	requestRaw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 1, InputTokenUpperBound: 1, EncryptedRequestBytes: relayblind.MaxEncryptedRequestBytes})
	response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", requestRaw, "")
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if response.Code != http.StatusOK || err != nil {
		t.Fatalf("reservation code=%d err=%v body=%s", response.Code, err, response.Body.String())
	}
	envelope, _ := reservation.NewEnvelope("maximum-envelope", now, bytes.Repeat([]byte{0x31}, 32))
	buyerPrivate, _ := ecdh.X25519().GenerateKey(nil)
	envelope, err = envelope.Encrypt(bytes.Repeat([]byte{'x'}, relayblind.MaxEncryptedRequestBytes), providerPrivate.PublicKey().Bytes(), buyerPrivate.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(envelope)
	if len(raw) <= relayblind.MaxEncryptedRequestBytes {
		t.Fatalf("serialized envelope unexpectedly small: %d", len(raw))
	}
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/consume", raw, "")
	if response.Code != http.StatusOK {
		t.Fatalf("consume code=%d bytes=%d body=%s", response.Code, len(raw), response.Body.String())
	}
}

func TestRelayBlindAuthenticatedPregenerationRejection(t *testing.T) {
	now := time.Unix(1_800_100_175, 0).UTC()
	server, _, providerPrivate, closeStore := relayBlindTestServer(t, now, func(_ context.Context, _ pool.Provider, requestID string, _ []byte, _ bool, context providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
		validations := make(chan providerws.RelayBlindValidation, 1)
		rejected := relayBlindValidationForContext(context, "rejected", 0)
		rejected.ErrorCode = "relay_blind_ciphertext_invalid"
		validations <- rejected
		return &providerws.RelayStream{RequestID: requestID, Chunks: make(chan providerws.InferenceResponseChunk), Done: make(chan providerws.InferenceResponseEnd, 1), Errors: make(chan error, 1), Validations: validations}, nil
	})
	defer closeStore()
	reservationRaw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 1024})
	response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", reservationRaw, "")
	reservation, _ := relayblind.ParseReservationResponse(response.Body.Bytes())
	envelope, _ := reservation.NewEnvelope("pregeneration-reject", now, bytes.Repeat([]byte{0x42}, 32))
	buyerPrivate, _ := ecdh.X25519().GenerateKey(nil)
	envelope, _ = envelope.Encrypt([]byte(`{"model":"model-a","messages":[]}`), providerPrivate.PublicKey().Bytes(), buyerPrivate.Bytes())
	envelopeRaw, _ := json.Marshal(envelope)
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/consume", envelopeRaw, "")
	consume, _ := relayblind.ParseConsumeResponse(response.Body.Bytes())
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/chat/completions", envelopeRaw, consume.ExecutionAuthorization)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), `"code":"relay_blind_ciphertext_invalid"`) || response.Header().Get(relayBlindValidatedHeader) != "" {
		t.Fatalf("rejection code=%d headers=%v body=%s", response.Code, response.Header(), response.Body.String())
	}
}

func TestRelayBlindPostValidationTerminalErrorPreservesSatisfiedOutcome(t *testing.T) {
	now := time.Unix(1_800_100_190, 0).UTC()
	server, _, providerPrivate, closeStore := relayBlindTestServer(t, now, func(_ context.Context, _ pool.Provider, requestID string, _ []byte, _ bool, context providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
		validations := make(chan providerws.RelayBlindValidation, 1)
		validations <- relayBlindValidationForContext(context, "validated", 9)
		done := make(chan providerws.InferenceResponseEnd, 1)
		terminal := relayBlindValidationForContext(context, "terminal", 9)
		done <- providerws.InferenceResponseEnd{
			RequestID:            requestID,
			Status:               "error",
			Error:                "provider runtime failed",
			Usage:                json.RawMessage(`{"prompt_tokens":9,"completion_tokens":0,"total_tokens":9}`),
			RelayBlindValidation: &terminal,
		}
		return &providerws.RelayStream{RequestID: requestID, Chunks: make(chan providerws.InferenceResponseChunk), Done: done, Errors: make(chan error, 1), Validations: validations}, nil
	})
	defer closeStore()

	reservationRaw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 1024})
	response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", reservationRaw, "")
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if response.Code != http.StatusOK || err != nil {
		t.Fatalf("reservation code=%d err=%v body=%s", response.Code, err, response.Body.String())
	}
	envelope, _ := reservation.NewEnvelope("post-validation-error", now, bytes.Repeat([]byte{0x43}, 32))
	buyerPrivate, _ := ecdh.X25519().GenerateKey(nil)
	envelope, _ = envelope.Encrypt([]byte(`{"model":"model-a","messages":[]}`), providerPrivate.PublicKey().Bytes(), buyerPrivate.Bytes())
	envelopeRaw, _ := json.Marshal(envelope)
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/consume", envelopeRaw, "")
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if response.Code != http.StatusOK || err != nil {
		t.Fatalf("consume code=%d err=%v body=%s", response.Code, err, response.Body.String())
	}
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/chat/completions", envelopeRaw, consume.ExecutionAuthorization)
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("chat code=%d body=%s", response.Code, response.Body.String())
	}
	if got := response.Header().Get(relayBlindValidatedHeader); got != consume.EnvelopeDigest {
		t.Fatalf("validation header=%q want=%q", got, consume.EnvelopeDigest)
	}
	for _, want := range []string{`"effective_privacy_outcome":"relay_blind_satisfied"`, `"retry_action":"do_not_resubmit"`} {
		if !strings.Contains(response.Body.String(), want) {
			t.Fatalf("missing %s in %s", want, response.Body.String())
		}
	}
}

func TestRelayBlindDisableAfterConsumeBurnsAuthorizationWithoutDispatch(t *testing.T) {
	now := time.Unix(1_800_100_200, 0).UTC()
	var dispatches atomic.Int32
	server, _, providerPrivate, closeStore := relayBlindTestServer(t, now, func(context.Context, pool.Provider, string, []byte, bool, providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
		dispatches.Add(1)
		return nil, context.Canceled
	})
	defer closeStore()
	reservationRaw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 1024})
	response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", reservationRaw, "")
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if response.Code != http.StatusOK || err != nil {
		t.Fatalf("reservation code=%d err=%v body=%s", response.Code, err, response.Body.String())
	}
	envelope, err := reservation.NewEnvelope("external-request-disable", now, bytes.Repeat([]byte{0x44}, 32))
	if err != nil {
		t.Fatal(err)
	}
	buyerPrivate, err := ecdh.X25519().GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	envelope, err = envelope.Encrypt([]byte(`{"model":"model-a","messages":[{"role":"user","content":"secret"}]}`), providerPrivate.PublicKey().Bytes(), buyerPrivate.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	envelopeRaw, _ := json.Marshal(envelope)
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/consume", envelopeRaw, "")
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if response.Code != http.StatusOK || err != nil {
		t.Fatalf("consume code=%d err=%v body=%s", response.Code, err, response.Body.String())
	}
	server.relayBlind.cfg.Enabled = false
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/chat/completions", envelopeRaw, consume.ExecutionAuthorization)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"relay_blind_disabled"`) {
		t.Fatalf("disabled chat code=%d body=%s", response.Code, response.Body.String())
	}
	server.relayBlind.cfg.Enabled = true
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/chat/completions", envelopeRaw, consume.ExecutionAuthorization)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), `"code":"relay_blind_replay"`) {
		t.Fatalf("reenabled chat code=%d body=%s", response.Code, response.Body.String())
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
}

func relayBlindTestServer(t *testing.T, now time.Time, relay RelayBlindRelayFunc) (*Server, relayblind.KeyRecord, *ecdh.PrivateKey, func()) {
	t.Helper()
	store, err := relayblind.OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	identityPublic, identityPrivate, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	providerPrivate, err := ecdh.X25519().GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	record, err := relayblind.NewSignedKeyRecord(providerPrivate.PublicKey().Bytes(), identityPrivate, []string{"model-a"}, relayblind.MaxEncryptedRequestBytes, now.Add(-time.Minute), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	authority, err := relayblind.NewAuthority(store, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(identityPublic)}, 8)
	if err != nil {
		t.Fatal(err)
	}
	if err := authority.AcceptProviderKeys(context.Background(), "provider-a", "session-a", []relayblind.KeyRecord{record}, now); err != nil {
		t.Fatal(err)
	}
	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "provider-a", AssignedID: "session-a", ModelID: "model-a", MaxContextTokens: 4096, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, State: pool.StateReady, AuthState: pool.AuthBearerValidated, InferencePath: pool.InferencePathWSTunneled}
	if _, registered := registry.RegisterAt(provider, nil, now); !registered {
		t.Fatal("provider registration rejected")
	}
	if relay == nil {
		relay = func(context.Context, pool.Provider, string, []byte, bool, providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
			return nil, context.Canceled
		}
	}
	cfg := config.Default().RelayBlind
	cfg.Enabled = true
	cfg.ReservationTTLSeconds = 30
	cfg.MaxClockSkewSeconds = 60
	cfg.MaxActiveReservations = 100
	cfg.MetadataRequestsPerMinute = 100
	server := NewServer(registry, zerolog.Nop(), now, WithGatewayServiceToken("gateway-token"), WithRequireGatewayContext(true), WithRelayBlind(cfg, store, relay))
	server.now = func() time.Time { return now }
	return server, record, providerPrivate, func() { _ = store.Close() }
}

func relayBlindRequest(t *testing.T, server *Server, method, path string, body []byte, executionAuthorization string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, path, bytes.NewReader(body))
	request.RemoteAddr = "127.0.0.1:43210"
	request.Header.Set("Authorization", "Bearer gateway-token")
	request.Header.Set("X-MacProvider-Account", "account-a")
	request.Header.Set("X-MacProvider-Wallet-Session", "wallet-a")
	request.Header.Set("Content-Type", "application/json")
	if executionAuthorization != "" {
		request.Header.Set(relayBlindExecutionAuthorizationHeader, executionAuthorization)
	}
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	return response
}

func relayBlindValidationForContext(value providerws.RelayBlindDispatchContext, state string, inputTokens int64) providerws.RelayBlindValidation {
	return providerws.RelayBlindValidation{ExecutionAuthDigest: value.ExecutionAuthDigest, EnvelopeDigest: value.EnvelopeDigest, KID: value.KID,
		ProviderBindingDigest: value.ProviderBindingDigest, BuyerBindingDigest: value.BuyerBindingDigest, AssignedSession: value.AssignedSession,
		RequestID: value.RequestID, State: state, InputTokens: inputTokens, InputTokenUpperBound: value.InputTokenUpperBound, MaxOutputTokens: value.MaxOutputTokens}
}
