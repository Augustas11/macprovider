package router

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

// SPEC-049-R020 v0.5.0: the code-bound strings are pinned and the pool
// variant drops only pool_scoped_requests.
func TestPrivacyCodeBoundStringsArePinned(t *testing.T) {
	if privacyAssuranceCodeBound != relayblind.PrivacyAssuranceCodeBound {
		t.Fatal("code-bound label differs from the shared constant")
	}
	if len(privacyCodeBoundProtects) != 12 || len(privacyCodeBoundDoesNotProtect) != 7 || len(privacyCodeBoundResidualRisks) != 16 {
		t.Fatalf("list lengths protects=%d does_not=%d residual=%d", len(privacyCodeBoundProtects), len(privacyCodeBoundDoesNotProtect), len(privacyCodeBoundResidualRisks))
	}
	if !reflect.DeepEqual(privacyCodeBoundProtects[:9], privacyProtects) {
		t.Fatal("the code-bound label must keep every device-bound protection")
	}
	global := privacyUsageMetadataFor(privacyAssuranceCodeBound, 7, "")
	if global.Assurance != privacyAssuranceCodeBound || global.Scope != privacyCodeBoundScope ||
		global.DoesNotProtect[len(global.DoesNotProtect)-1] != "pool_scoped_requests" {
		t.Fatalf("global code-bound object %+v", global)
	}
	pooled := privacyUsageMetadataFor(privacyAssuranceCodeBound, 7, "pool-a")
	if !reflect.DeepEqual(pooled.DoesNotProtect, privacyCodeBoundDoesNotProtect[:6]) || pooled.Pool == nil {
		t.Fatalf("pooled code-bound object %+v", pooled)
	}
	if device := privacyUsageMetadataFor(privacyAssuranceV1, 7, ""); !reflect.DeepEqual(device, privacyUsageMetadata(7, "")) {
		t.Fatal("device-bound object changed")
	}
	pooled.Protects[0] = "mutated"
	if privacyCodeBoundProtects[0] == "mutated" {
		t.Fatal("usage object aliases the pinned list")
	}
}

type assuranceHop struct {
	path     string
	required []string
}

// assuranceCoordinator is a coordinator stub that records the requirement
// header per hop and answers chat with echo.
func assuranceCoordinator(t *testing.T, res relayblind.ReservationResponse, raw []byte, echo []string) (*httptest.Server, func() []assuranceHop) {
	t.Helper()
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	var mu sync.Mutex
	var hops []assuranceHop
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hops = append(hops, assuranceHop{path: r.URL.Path, required: append([]string(nil), r.Header.Values(relayblind.PrivacyAssuranceRequiredHeader)...)})
		mu.Unlock()
		switch r.URL.Path {
		case "/v1/relay-blind/route-reservations":
			json.NewEncoder(w).Encode(res)
		case "/v1/relay-blind/consume":
			json.NewEncoder(w).Encode(relayblind.ConsumeResponse{
				Version: relayblind.ConsumeVersion, ProviderBinding: res.ProviderBinding, BuyerBinding: res.BuyerBinding,
				EnvelopeDigest: digestText, ExecutionAuthorization: "internal-execution-authorization",
				ConsumedAtUnix: fixedNow().Unix(), ExpiresAtUnix: res.ExpiresAtUnix,
			})
		case "/v1/chat/completions":
			w.Header().Set(relayBlindValidatedHeader, digestText)
			setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
			for _, value := range echo {
				w.Header().Add(privacyAssuranceHeader, value)
			}
			w.Header().Set(settlementModeHeader, "observe")
			io.WriteString(w, privacyClosedResponseBody(t))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, func() []assuranceHop {
		mu.Lock()
		defer mu.Unlock()
		return append([]assuranceHop(nil), hops...)
	}
}

// SPEC-049-R034 item 1: the requirement crosses to the coordinator once, on
// the reservation only, and only with the privacy-class marker.
func TestPrivacyAssuranceRequirementForwardedOnReservationOnly(t *testing.T) {
	res := privacyReservationFixture(t, false)
	res.PrivacyAssurance = relayblind.PrivacyAssuranceCodeBound
	raw := pilotEnvelopeFixture(t, res)
	upstream, hops := assuranceCoordinator(t, res, raw, []string{privacyAssuranceCodeBound})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-code-bound-forward")

	for name, headers := range map[string]map[string]string{
		"without the privacy marker": {relayblind.PrivacyAssuranceRequiredHeader: privacyAssuranceCodeBound},
		"other value":                {privacyClassHeader: privacyClassV1, relayblind.PrivacyAssuranceRequiredHeader: privacyAssuranceV1},
		"list value":                 {privacyClassHeader: privacyClassV1, relayblind.PrivacyAssuranceRequiredHeader: privacyAssuranceCodeBound + "," + privacyAssuranceCodeBound},
	} {
		t.Run(name, func(t *testing.T) {
			reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), headers)
			if reserve.Code != http.StatusBadRequest {
				t.Fatalf("status %d %s", reserve.Code, reserve.Body.String())
			}
			assertPrivacyError(t, reserve.Body.String(), http.StatusBadRequest, privacyClassDowngrade, "none", "")
		})
	}
	if got := hops(); len(got) != 0 {
		t.Fatalf("refused requirements reached the coordinator: %+v", got)
	}

	reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{
		privacyClassHeader: privacyClassV1, relayblind.PrivacyAssuranceRequiredHeader: privacyAssuranceCodeBound,
	})
	if reserve.Code != http.StatusOK {
		t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
	}
	chatHeaders := privacyChatHeaders()
	chatHeaders[relayblind.PrivacyAssuranceRequiredHeader] = privacyAssuranceCodeBound
	chat := postPrivacy(h, key, "/v1/chat/completions", raw, chatHeaders)
	if chat.Code != http.StatusOK {
		t.Fatalf("chat %d %s", chat.Code, chat.Body.String())
	}
	for _, hop := range hops() {
		want := 0
		if hop.path == "/v1/relay-blind/route-reservations" {
			want = 1
		}
		if len(hop.required) != want || (want == 1 && hop.required[0] != privacyAssuranceCodeBound) {
			t.Fatalf("hop %s carried requirement %v", hop.path, hop.required)
		}
	}
}

// SPEC-049-R034 item 4: the buyer-facing label and disclosure follow the
// coordinator's echo; a repeated or unknown echo is unconfirmed, and an
// absent one (a coordinator before v0.5.0) is device-bound.
func TestPrivacyChatDisclosureFollowsTheEchoedLabel(t *testing.T) {
	for _, tc := range []struct {
		name  string
		echo  []string
		label string
	}{
		{name: "code-bound", echo: []string{privacyAssuranceCodeBound}, label: privacyAssuranceCodeBound},
		{name: "device-bound", echo: []string{privacyAssuranceV1}, label: privacyAssuranceV1},
		{name: "older coordinator", label: privacyAssuranceV1},
		{name: "unknown", echo: []string{"tee_attested"}},
		{name: "repeated", echo: []string{privacyAssuranceCodeBound, privacyAssuranceCodeBound}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := privacyReservationFixture(t, false)
			raw := pilotEnvelopeFixture(t, res)
			upstream, _ := assuranceCoordinator(t, res, raw, tc.echo)
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				enablePrivacy(c)
				c.Coordinator.BuyerURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, "privacy-code-bound-echo")
			chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
			if tc.label == "" {
				if chat.Code != http.StatusInternalServerError {
					t.Fatalf("status %d %s", chat.Code, chat.Body.String())
				}
				assertPrivacyError(t, chat.Body.String(), http.StatusInternalServerError, privacyClassUnconfirmed, "do_not_resubmit", "")
				return
			}
			if chat.Code != http.StatusOK || len(chat.Header().Values(privacyAssuranceHeader)) != 1 || chat.Header().Get(privacyAssuranceHeader) != tc.label {
				t.Fatalf("status %d assurance %v body %s", chat.Code, chat.Header().Values(privacyAssuranceHeader), chat.Body.String())
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
			if want := privacyUsageMetadataFor(tc.label, privacyCoordinatorVerifiedAt, ""); !reflect.DeepEqual(parsed.Usage.Macprovider.Privacy, want) {
				t.Fatalf("privacy usage %+v want %+v", parsed.Usage.Macprovider.Privacy, want)
			}
		})
	}
}
