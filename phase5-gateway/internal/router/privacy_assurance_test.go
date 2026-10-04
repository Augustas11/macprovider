package router

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

func codeBoundReservationFixture(t *testing.T) relayblind.ReservationResponse {
	t.Helper()
	res := privacyReservationFixture(t, false)
	attestation := *res.PrivacyKeyAttestation
	attestation.Assurance = relayblind.PrivacyAssuranceCodeBound
	res.PrivacyKeyAttestation = &attestation
	res.PrivacyAssurance = relayblind.PrivacyAssuranceCodeBound
	if err := res.Validate(); err != nil {
		t.Fatal(err)
	}
	return res
}

func TestPrivacyCodeBoundStringsMatchSpec(t *testing.T) {
	if privacyAssuranceCodeBound != relayblind.PrivacyAssuranceCodeBound {
		t.Fatal("code-bound label drifted from relayblind")
	}
	if len(privacyCodeBoundProtects) != 12 || len(privacyCodeBoundDoesNotProtect) != 7 || len(privacyCodeBoundResidualRisks) != 13 {
		t.Fatalf("list lengths %d %d %d", len(privacyCodeBoundProtects), len(privacyCodeBoundDoesNotProtect), len(privacyCodeBoundResidualRisks))
	}
	got := privacyUsageMetadata(9, privacyAssuranceCodeBound)
	if got.Assurance != privacyAssuranceCodeBound || got.Scope != privacyCodeBoundScope || got.PostureVerifiedAtUnix != 9 {
		t.Fatalf("code-bound usage %+v", got)
	}
	got.Protects[0] = "mutated"
	if privacyCodeBoundProtects[0] == "mutated" {
		t.Fatal("code-bound usage lists alias the package slices")
	}
	if beta := privacyUsageMetadata(9, privacyAssuranceV1); beta.Scope != privacyScope || beta.Assurance != privacyAssuranceV1 {
		t.Fatalf("beta usage %+v", beta)
	}
}

// The gateway selects the R020 string set from the coordinator's validated
// label and forwards exactly that one value.
func TestPrivacyCodeBoundChatSelectsLabelStrings(t *testing.T) {
	res := codeBoundReservationFixture(t)
	raw := pilotEnvelopeFixture(t, res)
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	upstream, log := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(relayBlindValidatedHeader, digestText)
		setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
		w.Header().Set(privacyAssuranceHeader, privacyAssuranceCodeBound)
		w.Header().Set(settlementModeHeader, "observe")
		io.WriteString(w, privacyClosedResponseBody(t))
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-code-bound")
	reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{
		privacyClassHeader: privacyClassV1, privacyAssuranceRequiredHeader: privacyAssuranceCodeBound,
	})
	if reserve.Code != http.StatusOK {
		t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
	}
	chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
	if chat.Code != http.StatusOK || len(chat.Header().Values(privacyAssuranceHeader)) != 1 || chat.Header().Get(privacyAssuranceHeader) != privacyAssuranceCodeBound {
		t.Fatalf("chat %d assurance=%v %s", chat.Code, chat.Header().Values(privacyAssuranceHeader), chat.Body.String())
	}
	var parsed struct {
		Usage struct {
			Macprovider struct {
				Privacy privacyUsageObject `json:"privacy"`
			} `json:"macprovider"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(chat.Body.Bytes(), &parsed); err != nil {
		t.Fatal(err)
	}
	if want := privacyUsageMetadata(privacyCoordinatorVerifiedAt, privacyAssuranceCodeBound); !reflect.DeepEqual(parsed.Usage.Macprovider.Privacy, want) {
		t.Fatalf("usage %+v", parsed.Usage.Macprovider.Privacy)
	}
	hops := log.snapshot()
	if len(hops) != 3 {
		t.Fatalf("hops %+v", hops)
	}
	required := []string{}
	for _, hop := range hops {
		required = append(required, hop.required)
	}
	if !reflect.DeepEqual(required, []string{privacyAssuranceCodeBound, "", ""}) {
		t.Fatalf("requirement forwarded on %v", required)
	}
}

func TestPrivacyAssuranceRequiredValidation(t *testing.T) {
	for _, tc := range []struct {
		name    string
		class   bool
		values  []string
		reserve relayblind.ReservationResponse
		status  int
		code    string
	}{
		{name: "beta value", class: true, values: []string{privacyAssuranceV1}, status: http.StatusBadRequest, code: privacyClassDowngrade},
		{name: "unknown", class: true, values: []string{"code_bound"}, status: http.StatusBadRequest, code: privacyClassDowngrade},
		{name: "repeated", class: true, values: []string{privacyAssuranceCodeBound, privacyAssuranceCodeBound}, status: http.StatusBadRequest, code: privacyClassDowngrade},
		{name: "list", class: true, values: []string{privacyAssuranceCodeBound + "," + privacyAssuranceCodeBound}, status: http.StatusBadRequest, code: privacyClassDowngrade},
		{name: "without class", class: false, values: []string{privacyAssuranceCodeBound}, status: http.StatusBadRequest, code: privacyClassDowngrade},
		{name: "coordinator returned beta", class: true, values: []string{privacyAssuranceCodeBound}, status: http.StatusServiceUnavailable, code: privacyClassUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := privacyReservationFixture(t, false)
			upstream, log := privacyCoordinator(t, res, nil, func(http.ResponseWriter, *http.Request) {})
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				enablePrivacy(c)
				c.Coordinator.BuyerURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, "privacy-required-"+tc.name)
			request := newPrivacyRequest(key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res))
			if tc.class {
				request.Header.Set(privacyClassHeader, privacyClassV1)
			}
			for _, value := range tc.values {
				request.Header.Add(privacyAssuranceRequiredHeader, value)
			}
			response := serve(h, request)
			if response.Code != tc.status {
				t.Fatalf("status %d %s", response.Code, response.Body.String())
			}
			var wire struct {
				Error struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			if err := json.Unmarshal(response.Body.Bytes(), &wire); err != nil || wire.Error.Code != tc.code {
				t.Fatalf("body %s", response.Body.String())
			}
			if tc.status == http.StatusBadRequest && len(log.snapshot()) != 0 {
				t.Fatalf("invalid requirement reached the coordinator: %+v", log.snapshot())
			}
		})
	}
}

func TestPrivacyCoordinatorAssuranceValidation(t *testing.T) {
	for name, values := range map[string][]string{
		"missing":  nil,
		"repeated": {privacyAssuranceV1, privacyAssuranceV1},
		"unknown":  {"code_bound"},
		"list":     {privacyAssuranceV1 + "," + privacyAssuranceCodeBound},
	} {
		t.Run(name, func(t *testing.T) {
			res := privacyReservationFixture(t, false)
			raw := pilotEnvelopeFixture(t, res)
			digest := sha256.Sum256(raw)
			digestText := base64.RawURLEncoding.EncodeToString(digest[:])
			upstream, _ := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set(relayBlindValidatedHeader, digestText)
				setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
				w.Header().Del(privacyAssuranceHeader)
				for _, value := range values {
					w.Header().Add(privacyAssuranceHeader, value)
				}
				w.Header().Set(settlementModeHeader, "observe")
				io.WriteString(w, privacyClosedResponseBody(t))
			})
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				enablePrivacy(c)
				c.Coordinator.BuyerURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, "privacy-assurance-"+name)
			chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
			assertPrivacyError(t, chat.Body.String(), http.StatusInternalServerError, privacyClassUnconfirmed, "do_not_resubmit", "Privacy class completion was not confirmed")
			if chat.Header().Get(privacyAssuranceHeader) != "" {
				t.Fatalf("assurance header on error: %v", chat.Header())
			}
		})
	}
}

func newPrivacyRequest(key, path string, body []byte) *http.Request {
	r := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+key)
	return r
}

func serve(h http.Handler, r *http.Request) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
