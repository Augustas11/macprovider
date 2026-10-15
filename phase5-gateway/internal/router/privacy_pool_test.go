package router

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

// SPEC-049-R032 gateway tests: a privacy-class request scoped to an
// authorized Trusted Pool.

type privacyPoolHops struct {
	mu   sync.Mutex
	pool map[string][]string
}

func (h *privacyPoolHops) record(r *http.Request) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.pool == nil {
		h.pool = map[string][]string{}
	}
	h.pool[r.URL.Path] = append(h.pool[r.URL.Path], r.Header.Get(poolEmitHeader))
}

func (h *privacyPoolHops) get(path string) []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.pool[path]...)
}

// privacyPoolGateway fronts privacyCoordinator with the /internal/routing
// pool metadata the gateway reads before authorizing a pool selection.
func privacyPoolGateway(t *testing.T, res relayblind.ReservationResponse, raw []byte, account string, onChat func(http.ResponseWriter, *http.Request)) (http.Handler, string, *privacyPoolHops) {
	t.Helper()
	upstream, _ := privacyCoordinator(t, res, raw, onChat)
	target, err := url.Parse(upstream.URL)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	hops := &privacyPoolHops{}
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/internal/routing" {
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"pools":{"enabled":true,"routeable_pools":["`+testPoolID+`"]}}`)
			return
		}
		hops.record(r)
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = front.URL
		c.Coordinator.OperatorURL = front.URL
		c.Features.TrustedPools = config.TrustedPoolsConfig{Enabled: true, AccountPools: map[string][]string{"acct_pool": {testPoolID}}}
	})
	key := createAccountAndKey(t, store, cfg, account)
	return h, key, hops
}

func pooledPrivacyReservationFixture(t *testing.T) relayblind.ReservationResponse {
	t.Helper()
	res := privacyReservationFixture(t, false)
	res.PoolID, res.PoolManifestVersion, res.PoolManifestCoreDigest = testPoolID, 3, strings.Repeat("c", 64)
	if err := res.Validate(); err != nil {
		t.Fatal(err)
	}
	return res
}

func TestPrivacyPoolScopedRequestForwardsAuthorizedPool(t *testing.T) {
	res := pooledPrivacyReservationFixture(t)
	raw := pilotEnvelopeFixture(t, res)
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	h, key, hops := privacyPoolGateway(t, res, raw, "acct_pool", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(relayBlindValidatedHeader, digestText)
		setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
		w.Header().Set(settlementModeHeader, "observe")
		io.WriteString(w, privacyClosedResponseBody(t))
	})
	reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{
		privacyClassHeader: privacyClassV1, poolSelectHeader: testPoolID,
	})
	if reserve.Code != http.StatusOK {
		t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
	}
	parsed, err := relayblind.ParseReservationResponse(reserve.Body.Bytes())
	if err != nil || parsed.PoolID != testPoolID || parsed.PoolManifestVersion != 3 {
		t.Fatalf("reservation %+v err=%v", parsed, err)
	}
	headers := privacyChatHeaders()
	headers[poolSelectHeader] = testPoolID
	headers[privacyModeHeader] = privacyModeRelayBlindRequired
	chat := postPrivacy(h, key, "/v1/chat/completions", raw, headers)
	if chat.Code != http.StatusOK {
		t.Fatalf("chat %d %s", chat.Code, chat.Body.String())
	}
	for _, path := range []string{"/v1/relay-blind/route-reservations", "/v1/relay-blind/consume", "/v1/chat/completions"} {
		if got := hops.get(path); len(got) != 1 || got[0] != testPoolID {
			t.Fatalf("%s forwarded pool %v", path, got)
		}
	}
	if chat.Header().Get(privacyModeHeader) != privacyModeRelayBlindRequired || chat.Header().Get(privacyModeDisclosureHeader) != privacyModePoolScopedDisclosure {
		t.Fatalf("mode disclosure %q / %q", chat.Header().Get(privacyModeHeader), chat.Header().Get(privacyModeDisclosureHeader))
	}
	var body struct {
		Usage struct {
			Macprovider struct {
				Privacy privacyUsageObject `json:"privacy"`
			} `json:"macprovider"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(chat.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	got := body.Usage.Macprovider.Privacy
	if !reflect.DeepEqual(got, privacyUsageMetadata(privacyCoordinatorVerifiedAt, testPoolID)) {
		t.Fatalf("pool disclosure %+v", got)
	}
	if got.Pool == nil || got.Pool.PoolID != testPoolID || len(got.DoesNotProtect) != 5 || strings.Contains(strings.Join(got.DoesNotProtect, ","), "pool_scoped_requests") {
		t.Fatalf("pool-scoped disclosure %+v", got)
	}
}

func TestPrivacyPoolDisclosureExactStrings(t *testing.T) {
	object := privacyUsageMetadata(1, testPoolID)
	if object.Pool.Scope != "served_only_by_current_trusted_pool_members_enrolled_in_this_class; pool_membership_is_administrative_trust_not_content_privacy; a_pool_operator_running_a_member_mac_is_its_provider_operator" ||
		!reflect.DeepEqual(object.Pool.PoolOperatorSees, []string{"pool_policy_membership_and_buyer_grants", "aggregate_payable_request_counts_and_provider_credits"}) ||
		!reflect.DeepEqual(object.Pool.PoolOperatorDoesNotSee, []string{"request_and_response_content_through_pool_surfaces", "per_request_metadata_and_buyer_attribution_through_pool_surfaces"}) ||
		!reflect.DeepEqual(object.DoesNotProtect, privacyDoesNotProtect[:5]) {
		t.Fatalf("pool disclosure drifted: %+v", object)
	}
	encoded, err := json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(string(encoded), `"posture_verified_at_unix":1,"pool":{"pool_id":"`+testPoolID+`","scope":"`+privacyPoolScope+`","pool_operator_sees":["pool_policy_membership_and_buyer_grants","aggregate_payable_request_counts_and_provider_credits"],"pool_operator_does_not_see":["request_and_response_content_through_pool_surfaces","per_request_metadata_and_buyer_attribution_through_pool_surfaces"]}}`) {
		t.Fatalf("pool member order: %s", encoded)
	}
	global, err := json.Marshal(privacyUsageMetadata(1, ""))
	if err != nil || strings.Contains(string(global), `"pool"`) || !strings.Contains(string(global), "pool_scoped_requests") {
		t.Fatalf("global disclosure changed: %s", global)
	}
}

func TestPrivacyPoolUnauthorizedSelectionNeverForwarded(t *testing.T) {
	res := pooledPrivacyReservationFixture(t)
	raw := pilotEnvelopeFixture(t, res)
	h, key, hops := privacyPoolGateway(t, res, raw, "acct_other", func(w http.ResponseWriter, r *http.Request) {
		t.Error("chat reached the coordinator")
	})
	reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{
		privacyClassHeader: privacyClassV1, poolSelectHeader: testPoolID,
	})
	if reserve.Code != http.StatusServiceUnavailable || !strings.Contains(reserve.Body.String(), `"code":"pool_unavailable"`) {
		t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
	}
	headers := privacyChatHeaders()
	headers[poolSelectHeader] = testPoolID
	chat := postPrivacy(h, key, "/v1/chat/completions", raw, headers)
	if chat.Code != http.StatusServiceUnavailable || !strings.Contains(chat.Body.String(), `"code":"pool_unavailable"`) {
		t.Fatalf("chat %d %s", chat.Code, chat.Body.String())
	}
	for _, path := range []string{"/v1/relay-blind/route-reservations", "/v1/relay-blind/consume", "/v1/chat/completions"} {
		if got := hops.get(path); len(got) != 0 {
			t.Fatalf("%s reached the coordinator: %v", path, got)
		}
	}
}

func TestPrivacyPoolReservationMustMatchSelectedPool(t *testing.T) {
	// The coordinator answers a pool-scoped reservation with a global one.
	res := privacyReservationFixture(t, false)
	raw := pilotEnvelopeFixture(t, res)
	h, key, _ := privacyPoolGateway(t, res, raw, "acct_pool", func(w http.ResponseWriter, r *http.Request) {})
	reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{
		privacyClassHeader: privacyClassV1, poolSelectHeader: testPoolID,
	})
	if reserve.Code != http.StatusServiceUnavailable {
		t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
	}
	assertPrivacyError(t, reserve.Body.String(), http.StatusServiceUnavailable, privacyClassUnavailable, "none", "")
}

func TestPrivacyPoolCoordinatorPoolRefusalKeepsSPEC042Code(t *testing.T) {
	for code, status := range map[string]int{"pool_policy_stale": 503, "pool_model_not_allowed": 400, "pool_settlement_mode_unsatisfied": 503, "pool_unavailable": 503} {
		gotStatus, _, _, ok := privacyPoolRefusal(code)
		if !ok || gotStatus != status {
			t.Fatalf("%s mapped to %d ok=%v", code, gotStatus, ok)
		}
	}
	if _, _, _, ok := privacyPoolRefusal("pool_no_eligible_member"); ok {
		t.Fatal("membership-side refusals stay privacy_class_unavailable")
	}
}

func TestPrivacyModeRelayBlindRequiredAllowsPoolOnlyWithPrivacyClass(t *testing.T) {
	envelope := []byte(`{"version":"relay-blind-request-v1","mode":"required"}`)
	plain := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	plain.Header.Set(privacyModeHeader, privacyModeRelayBlindRequired)
	plain.Header.Set(poolSelectHeader, testPoolID)
	w := httptest.NewRecorder()
	if _, ok := gatePrivacyModeBeforeRelayBlind(w, plain, envelope); ok || !strings.Contains(w.Body.String(), privacyModeUnsatisfied) {
		t.Fatalf("plain relay-blind with pool passed the mode gate: %s", w.Body.String())
	}
	private := plain.Clone(plain.Context())
	private.Header.Set(privacyClassHeader, privacyClassV1)
	w = httptest.NewRecorder()
	if mode, ok := gatePrivacyModeBeforeRelayBlind(w, private, envelope); !ok || mode != privacyModeRelayBlindRequired {
		t.Fatalf("privacy-class pool refused by the mode gate: %s", w.Body.String())
	}
}
