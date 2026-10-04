package buyer

import (
	"encoding/json"
	"net/http"
	"sync/atomic"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

// SPEC-049-R032: the reservation records the label it was granted and the
// successful chat carries exactly that label to the gateway.
func TestPrivacyAssuranceHeaderOnChatMatchesReservation(t *testing.T) {
	body := privacyTestResponseBody(t)
	var gotClass atomic.Value
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relay: privacySuccessRelay(body, &gotClass, &dispatches)})
	reservation := h.reserve(t, true)
	if reservation.PrivacyAssurance != relayblind.PrivacyAssurance || reservation.PrivacyKeyAttestation.Assurance != relayblind.PrivacyAssurance {
		t.Fatalf("reservation assurance %q", reservation.PrivacyAssurance)
	}
	row, err := h.store.LookupReservation(t.Context(), reservation.ProviderBinding)
	if err != nil || row.PrivacyAssurance != relayblind.PrivacyAssurance {
		t.Fatalf("stored label %q err %v", row.PrivacyAssurance, err)
	}
	raw := h.seal(t, reservation, "privacy-assurance-a", h.privacyPrivate)
	consumed := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	if consumed.Code != http.StatusOK || consumed.Header().Get(privacyAssuranceHeader) != "" {
		t.Fatalf("consume status=%d assurance=%q", consumed.Code, consumed.Header().Get(privacyAssuranceHeader))
	}
	consume, err := relayblind.ParseConsumeResponse(consumed.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	chat := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, nil)
	if chat.Code != http.StatusOK || len(chat.Header().Values(privacyAssuranceHeader)) != 1 || chat.Header().Get(privacyAssuranceHeader) != relayblind.PrivacyAssurance {
		t.Fatalf("chat status=%d assurance=%v", chat.Code, chat.Header().Values(privacyAssuranceHeader))
	}
}

func TestPrivacyAssuranceRequiredHeader(t *testing.T) {
	cases := []struct {
		name    string
		privacy bool
		values  []string
		status  int
		code    string
	}{
		{name: "code-bound required, only Beta eligible", privacy: true, values: []string{relayblind.PrivacyAssuranceCodeBound}, status: http.StatusServiceUnavailable, code: privacyClassUnavailable},
		{name: "beta value", privacy: true, values: []string{relayblind.PrivacyAssurance}, status: http.StatusBadRequest, code: privacyClassDowngrade},
		{name: "unknown value", privacy: true, values: []string{"code_bound"}, status: http.StatusBadRequest, code: privacyClassDowngrade},
		{name: "list value", privacy: true, values: []string{relayblind.PrivacyAssuranceCodeBound + "," + relayblind.PrivacyAssuranceCodeBound}, status: http.StatusBadRequest, code: privacyClassDowngrade},
		{name: "repeated", privacy: true, values: []string{relayblind.PrivacyAssuranceCodeBound, relayblind.PrivacyAssuranceCodeBound}, status: http.StatusBadRequest, code: privacyClassDowngrade},
		{name: "without class marker", privacy: false, values: []string{relayblind.PrivacyAssuranceCodeBound}, status: http.StatusBadRequest, code: privacyClassDowngrade},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true})
			raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
			response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", func(r *http.Request) {
				if !tc.privacy {
					r.Header.Del(privacyClassHeader)
				}
				for _, value := range tc.values {
					r.Header.Add(privacyAssuranceRequiredHeader, value)
				}
			})
			var wire struct {
				Error struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			_ = json.Unmarshal(response.Body.Bytes(), &wire)
			if response.Code != tc.status || wire.Error.Code != tc.code {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
			if count, err := h.store.CountReservations(t.Context()); err != nil || count != 0 {
				t.Fatalf("reservations written: %d %v", count, err)
			}
		})
	}
}

func TestReservationAssuranceDefaultsLegacyRowsToBeta(t *testing.T) {
	if got := reservationAssurance(relayblind.Reservation{PrivacyClass: true}); got != relayblind.PrivacyAssurance {
		t.Fatalf("legacy row label %q", got)
	}
	if got := reservationAssurance(relayblind.Reservation{PrivacyClass: true, PrivacyAssurance: relayblind.PrivacyAssuranceCodeBound}); got != relayblind.PrivacyAssuranceCodeBound {
		t.Fatalf("code-bound row label %q", got)
	}
}
