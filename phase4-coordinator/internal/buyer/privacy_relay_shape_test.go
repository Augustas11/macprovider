package buyer

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

func privacyTestFrame(t *testing.T, seq uint64, final bool) string {
	t.Helper()
	raw, err := json.Marshal(relayblind.PrivacyFrame{
		Object: relayblind.PrivacyFrameObject, Version: relayblind.PrivacyResponseVersion, Seq: seq, Final: final,
		Ciphertext: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{byte(0x40 + seq)}, 48)),
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func privacyTestResponseBody(t *testing.T) string {
	t.Helper()
	return `{"object":"` + relayblind.PrivacyResponseObject + `","version":"` + relayblind.PrivacyResponseVersion + `","frames":[` +
		privacyTestFrame(t, 0, false) + `,` + privacyTestFrame(t, 1, true) + `],"usage":{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}}`
}

const privacyTestUsageEvent = "data: {\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":3,\"total_tokens\":14}}\n\n"

// privacyChunksRelay emits the given provider chunks, then a complete
// terminal frame with valid relay-blind evidence.
func privacyChunksRelay(chunks []string, dispatches *atomic.Int32) RelayBlindRelayFunc {
	return func(_ context.Context, _ pool.Provider, requestID string, _ []byte, _ bool, relayContext providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
		if dispatches != nil {
			dispatches.Add(1)
		}
		out := make(chan providerws.InferenceResponseChunk)
		done := make(chan providerws.InferenceResponseEnd, 1)
		errs := make(chan error, 1)
		validations := make(chan providerws.RelayBlindValidation, 1)
		validations <- relayBlindValidationForContext(relayContext, "validated", 11)
		terminal := relayBlindValidationForContext(relayContext, "terminal", 11)
		go func() {
			for i, data := range chunks {
				out <- providerws.InferenceResponseChunk{RequestID: requestID, Seq: i, Data: data}
			}
			close(out)
			done <- providerws.InferenceResponseEnd{RequestID: requestID, Status: "complete", Usage: json.RawMessage(`{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}`), RelayBlindValidation: &terminal}
		}()
		return &providerws.RelayStream{RequestID: requestID, Chunks: out, Done: done, Errors: errs, Validations: validations}, nil
	}
}

func (h *privacyHarness) privacyChat(t *testing.T, stream bool, requestID string) (relayblind.ReservationResponse, *http.Response, string) {
	t.Helper()
	reservation := h.reserveStream(t, stream)
	raw := h.seal(t, reservation, requestID, h.privacyPrivate)
	consumed := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	consume, err := relayblind.ParseConsumeResponse(consumed.Body.Bytes())
	if consumed.Code != http.StatusOK || err != nil {
		t.Fatalf("consume status=%d err=%v body=%s", consumed.Code, err, consumed.Body.String())
	}
	response := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, nil)
	return reservation, response.Result(), response.Body.String()
}

func TestPrivacyRelayRefusesClearNonStreamBody(t *testing.T) {
	t.Run("clear body", func(t *testing.T) {
		clear := `{"id":"x","object":"chat.completion","choices":[{"message":{"content":"CANARY-PRIVACY-CLEAR"}}],"usage":{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}}`
		h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, requestLog: true, relay: privacyChunksRelay([]string{clear}, nil)})
		reservation, response, body := h.privacyChat(t, false, "privacy-clear-json")
		if response.StatusCode != http.StatusInternalServerError || strings.Contains(body, "CANARY") || !strings.Contains(body, `"code":"privacy_class_unconfirmed"`) || !strings.Contains(body, `"retry_action":"do_not_resubmit"`) {
			t.Fatalf("status=%d body=%s", response.StatusCode, body)
		}
		if response.Header.Get(privacyClassHeader) != "" || response.Header.Get(privacyPostureVerifiedAtHeader) != "" {
			t.Fatalf("privacy success headers on refusal: %v", response.Header)
		}
		row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
		if err != nil || row.State != relayblind.ReservationStateUnknownPostdispatch || row.TerminalCode != privacyClassUnconfirmed {
			t.Fatalf("row=%#v err=%v", row, err)
		}
	})
	t.Run("closed envelope", func(t *testing.T) {
		want := privacyTestResponseBody(t)
		h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyChunksRelay([]string{want}, nil)})
		_, response, body := h.privacyChat(t, false, "privacy-closed-json")
		if response.StatusCode != http.StatusOK || body != want || response.Header.Get(privacyClassHeader) != relayblind.PrivacyClassV1 {
			t.Fatalf("status=%d body=%s", response.StatusCode, body)
		}
	})
}

func TestPrivacyRelayRefusesClearStreamContent(t *testing.T) {
	frame0 := "data: " + privacyTestFrame(t, 0, false) + "\n\n"
	frame1 := "data: " + privacyTestFrame(t, 1, true) + "\n\n"
	for _, tc := range []struct {
		name    string
		chunks  []string
		refused bool
		forward []string
	}{
		{name: "valid", chunks: []string{frame0, frame1, privacyTestUsageEvent, "data: [DONE]\n\n"}, forward: []string{frame0, frame1, privacyTestUsageEvent, "data: [DONE]\n\n"}},
		{name: "valid split across chunks", chunks: []string{frame0[:20], frame0[20:] + frame1[:7], frame1[7:] + privacyTestUsageEvent + "data: [DONE]\n\n"}, forward: []string{frame0, frame1, privacyTestUsageEvent, "data: [DONE]\n\n"}},
		{name: "clear content chunk", chunks: []string{frame0, "data: {\"choices\":[{\"delta\":{\"content\":\"CANARY-PRIVACY-CLEAR\"}}]}\n\n", frame1, privacyTestUsageEvent, "data: [DONE]\n\n"}, refused: true, forward: []string{frame0}},
		{name: "clear tool call chunk", chunks: []string{frame0, frame1, "data: {\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"CANARY\"}}]}}],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":3,\"total_tokens\":14}}\n\n", "data: [DONE]\n\n"}, refused: true, forward: []string{frame0, frame1}},
		{name: "missing final usage and done", chunks: []string{frame0}, refused: true, forward: []string{frame0}},
		{name: "non data line", chunks: []string{frame0, ": CANARY comment\n\n"}, refused: true, forward: []string{frame0}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, requestLog: true, relay: privacyChunksRelay(tc.chunks, nil)})
			reservation, response, body := h.privacyChat(t, true, "privacy-stream-"+strings.ReplaceAll(tc.name, " ", "-"))
			if response.StatusCode != http.StatusOK {
				t.Fatalf("status=%d body=%s", response.StatusCode, body)
			}
			if strings.Contains(body, "CANARY") {
				t.Fatalf("clear content forwarded: %s", body)
			}
			want := strings.Join(tc.forward, "")
			if !strings.HasPrefix(body, want) {
				t.Fatalf("forwarded prefix mismatch body=%q want prefix %q", body, want)
			}
			row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
			if err != nil {
				t.Fatal(err)
			}
			if !tc.refused {
				if body != want || row.State != relayblind.ReservationStateTerminal {
					t.Fatalf("body=%q state=%s", body, row.State)
				}
				return
			}
			tail := strings.TrimPrefix(body, want)
			if !strings.HasPrefix(tail, "data: {\"error\":") || !strings.Contains(tail, `"code":"privacy_class_unconfirmed"`) || !strings.Contains(tail, `"retry_action":"do_not_resubmit"`) || !strings.HasSuffix(tail, "\n\ndata: [DONE]\n\n") {
				t.Fatalf("refusal tail=%q", tail)
			}
			if row.State != relayblind.ReservationStateUnknownPostdispatch || row.TerminalCode != privacyClassUnconfirmed {
				t.Fatalf("row=%#v", row)
			}
		})
	}
}

func TestPrivacyConsumeClassifiesMarkerBeforeEnvelope(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, quota: 1, relay: privacyCountingRelay(&dispatches)})
	reservation := h.reserve(t, true)
	skewed := h.seal(t, reservation, "privacy-consume-skew", h.privacyPrivate)
	h.clock.Advance(61 * time.Second)
	plaintext := []byte(`{"model":"model-a","messages":[{"role":"user","content":"PROMPT-CANARY-7f3a"}]}`)
	for _, tc := range []struct {
		name    string
		body    []byte
		header  string
		message string
	}{
		{name: "invalid header on unparseable envelope", body: skewed, header: "not-the-class", message: "Privacy class marker does not match the reservation"},
		{name: "invalid header on plaintext", body: plaintext, header: "not-the-class", message: "Privacy class marker is not valid for a plaintext request"},
		{name: "valid header on plaintext", body: plaintext, header: relayblind.PrivacyClassV1, message: "Privacy class marker is not valid for a plaintext request"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", tc.body, "", func(r *http.Request) {
				r.Header.Set(privacyClassHeader, tc.header)
			})
			body := response.Body.String()
			if response.Code != http.StatusBadRequest || !strings.Contains(body, `"code":"privacy_class_downgrade_rejected"`) || !strings.Contains(body, tc.message) || strings.Contains(body, "relay_blind_envelope_invalid") || strings.Contains(body, "PROMPT-CANARY-7f3a") {
				t.Fatalf("status=%d body=%s", response.Code, body)
			}
		})
	}
	skew := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", skewed, "", nil)
	if skew.Code != http.StatusBadRequest || !strings.Contains(skew.Body.String(), `"code":"relay_blind_envelope_invalid"`) {
		t.Fatalf("valid header skew status=%d body=%s", skew.Code, skew.Body.String())
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateReserved {
		t.Fatalf("reservation consumed: row=%#v err=%v", row, err)
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
	if !h.admission.CheckQuota(h.provider) || !h.admission.TryReserveRequest(h.provider) {
		t.Fatal("quota was consumed before dispatch")
	}
}

func TestPrivacyControlPlaneInvalidationIsTyped(t *testing.T) {
	t.Run("quarantine before consume", func(t *testing.T) {
		h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true})
		reservation := h.reserve(t, true)
		raw := h.seal(t, reservation, "privacy-quarantine-consume", h.privacyPrivate)
		if err := h.store.QuarantineAndRevokePrivacy(context.Background(), "provider-a", "review", h.clock.Now(), time.Hour, time.Hour); err != nil {
			t.Fatal(err)
		}
		response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
		if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_unavailable"`) {
			t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
		}
	})
	t.Run("empty privacy key advertisement before consume", func(t *testing.T) {
		h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true})
		reservation := h.reserve(t, true)
		raw := h.seal(t, reservation, "privacy-empty-keys", h.privacyPrivate)
		if err := h.authority.AcceptPrivacyKeys(context.Background(), "provider-a", "session-a", nil, h.clock.Now()); err != nil {
			t.Fatal(err)
		}
		response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
		if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_unavailable"`) {
			t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
		}
	})
	t.Run("kill switch cycled before consume", func(t *testing.T) {
		h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true})
		reservation := h.reserve(t, true)
		raw := h.seal(t, reservation, "privacy-kill-cycle", h.privacyPrivate)
		if err := h.store.DisablePrivacyAndRejectPredispatch(context.Background(), "maintenance", h.clock.Now()); err != nil {
			t.Fatal(err)
		}
		if err := h.store.SetPrivacyDisabled(context.Background(), false, "", h.clock.Now()); err != nil {
			t.Fatal(err)
		}
		response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
		if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_disabled"`) {
			t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
		}
	})
	t.Run("quarantine between consume and chat", func(t *testing.T) {
		var dispatches atomic.Int32
		h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
		reservation := h.reserve(t, true)
		raw := h.seal(t, reservation, "privacy-quarantine-chat", h.privacyPrivate)
		consumed := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
		consume, err := relayblind.ParseConsumeResponse(consumed.Body.Bytes())
		if consumed.Code != http.StatusOK || err != nil {
			t.Fatalf("consume status=%d err=%v", consumed.Code, err)
		}
		if err := h.store.QuarantineAndRevokePrivacy(context.Background(), "provider-a", "review", h.clock.Now(), time.Hour, time.Hour); err != nil {
			t.Fatal(err)
		}
		response := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, nil)
		if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_unavailable"`) {
			t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
		}
		if dispatches.Load() != 0 {
			t.Fatalf("dispatches=%d", dispatches.Load())
		}
	})
	t.Run("genuine replay stays replay", func(t *testing.T) {
		h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyChunksRelay([]string{privacyTestResponseBody(t)}, nil)})
		reservation := h.reserve(t, true)
		raw := h.seal(t, reservation, "privacy-replay", h.privacyPrivate)
		consumed := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
		consume, err := relayblind.ParseConsumeResponse(consumed.Body.Bytes())
		if consumed.Code != http.StatusOK || err != nil {
			t.Fatalf("consume status=%d err=%v", consumed.Code, err)
		}
		again := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
		if again.Code != http.StatusConflict || !strings.Contains(again.Body.String(), `"code":"relay_blind_replay"`) {
			t.Fatalf("consume replay status=%d body=%s", again.Code, again.Body.String())
		}
		chat := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, nil)
		if chat.Code != http.StatusOK {
			t.Fatalf("chat status=%d body=%s", chat.Code, chat.Body.String())
		}
		replay := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, nil)
		if replay.Code != http.StatusConflict || !strings.Contains(replay.Body.String(), `"code":"relay_blind_replay"`) {
			t.Fatalf("chat replay status=%d body=%s", replay.Code, replay.Body.String())
		}
	})
}
