package buyer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/relayblind"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func routingOwnerContext(t *testing.T, account string) context.Context {
	t.Helper()
	a, err := requestlog.NewAuthenticatedAccount(account)
	if err != nil {
		t.Fatal(err)
	}
	return context.WithValue(context.Background(), authenticatedAccountContextKey{}, a)
}

func TestBuyerOwnershipSelectionPaths(t *testing.T) {
	for _, path := range []string{"normal", "sticky", "provider-pin", "session-pin", "retry", "all-owned", "lookup-error", "no-link", "pool", "pool-all-owned"} {
		t.Run(path, func(t *testing.T) {
			s, registry, tp := poolIsolationServer(t)
			own, other := poolProvider("own"), poolProvider("other")
			registry.Register(&own, nil)
			registry.Register(&other, nil)
			WithBuyerOwnershipLookup(func(context.Context, string, []int64) (map[string]bool, error) {
				if path == "lookup-error" {
					return nil, errors.New("closed database")
				}
				if path == "no-link" {
					return nil, nil
				}
				return map[string]bool{"own": true, "other": (path == "all-owned" || path == "pool-all-owned")}, nil
			})(s)
			req := poolChatReq("")
			if path == "pool" || path == "pool-all-owned" {
				tp.AddMember("P", "own")
				tp.AddMember("P", "other")
				req = poolChatReq("P")
			}
			headers := http.Header{}
			headers.Set("Authorization", "Bearer gateway-secret")
			if path == "provider-pin" {
				headers.Set("X-MacProvider-Provider", "own")
			}
			if path == "session-pin" {
				headers.Set("X-MacProvider-Session", own.AssignedID)
			}
			if path == "sticky" {
				WithRoutingConfig(config.RoutingConfig{StickyEnabled: true, StickyTTLS: 1800, StickyMaxEntries: 100})(s)
				headers.Set("X-MacProvider-Internal-Conv", "conv:owned-conversation")
				s.stickyStore(headers, own, "model-a")
			}
			excluded := map[string]struct{}{}
			if path == "retry" {
				excluded[other.SortKey()] = struct{}{}
			}
			got, routeErr := s.selectProviderExcluding(routingOwnerContext(t, "acct"), "route", req, headers, excluded, "day", &forwardState{})
			denied := path == "provider-pin" || path == "session-pin" || path == "all-owned" || path == "lookup-error" || path == "retry" || path == "pool-all-owned"
			if denied {
				if routeErr == nil {
					t.Fatalf("excluded path selected %s", got.ProviderID)
				}
				return
			}
			if routeErr != nil {
				t.Fatalf("selection failed: %+v", routeErr)
			}
			if path != "no-link" && got.ProviderID != "other" {
				t.Fatalf("selected own provider: %+v", got)
			}
		})
	}
}

func TestBuyerOwnershipDispatchRevalidatesWithoutBilling(t *testing.T) {
	h, _ := newEconHarness(t, WithGatewayServiceToken(allowanceTestServiceToken), WithRequireGatewayContext(true))
	calls := 0
	WithBuyerOwnershipLookup(func(context.Context, string, []int64) (map[string]bool, error) {
		calls++
		return map[string]bool{"p1": calls > 1}, nil
	})(h.server)
	rec := allowanceChat(h, "acct", "ownership-race", nil)
	if rec.Code != 503 || !strings.Contains(rec.Body.String(), "no_provider_available") {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	if calls < 2 || ledgerRowsFor(t, h, "acct", "ownership-race") != 0 {
		t.Fatal("dispatch did not revalidate or charged excluded provider")
	}
}

func TestBuyerOwnershipTrustedContextAndLookupStates(t *testing.T) {
	for _, raw := range []string{"unavailable", "0", "-1", "7,", "07", "7,8"} {
		headers := http.Header{}
		headers.Set(routingGitHubIDsHeader, raw)
		identity := parseRoutingIdentity(headers)
		if identity.unavailable != (raw != "7,8") {
			t.Fatalf("parse %q = %+v", raw, identity)
		}
	}
	s, _, _ := poolIsolationServer(t)
	// Missing production resolver is never sufficient for a linked assertion.
	ctx := context.WithValue(routingOwnerContext(t, "acct"), routingIdentityContextKey{}, routingIdentity{ids: []int64{7}})
	if _, err := s.buyerOwnedProviders(ctx); err == nil {
		t.Fatal("linked identity without resolver allowed")
	}
	var called bool
	WithBuyerOwnershipLookup(func(context.Context, string, []int64) (map[string]bool, error) { called = true; return nil, nil })(s)
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { s.buyerOwnedProviders(r.Context()); w.WriteHeader(200) })
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	req.Header.Set("X-MacProvider-Account", "forged")
	req.Header.Set(routingGitHubIDsHeader, "7")
	rr := httptest.NewRecorder()
	s.gatewayContextMiddleware(next).ServeHTTP(rr, req)
	if rr.Code != 401 || called {
		t.Fatal("forged account reached ownership lookup")
	}
}

func TestBuyerOwnershipRelayBlindReservationExcludesOwned(t *testing.T) {
	s, _, _, closeStore, _ := relayBlindTestServerWithProvider(t, time.Now().UTC(), nil)
	defer closeStore()
	ctx := routingOwnerContext(t, "acct")
	WithBuyerOwnershipLookup(func(context.Context, string, []int64) (map[string]bool, error) {
		return map[string]bool{"provider-a": true}, nil
	})(s)
	_, _, found, _, _ := s.selectRelayBlindProvider(ctx, "acct", "model-a", 2048, false, relayblind.KeyClassRelayBlind, nil)
	if found {
		t.Fatal("relay-blind reserved owned provider")
	}
	WithBuyerOwnershipLookup(func(context.Context, string, []int64) (map[string]bool, error) {
		return nil, errors.New("ownership store closed")
	})(s)
	_, _, found, _, ownershipErr := s.selectRelayBlindProvider(ctx, "acct", "model-a", 2048, false, relayblind.KeyClassRelayBlind, nil)
	if found || ownershipErr == nil || !ownershipErr.ownershipLookupFailed {
		t.Fatalf("lookup failure: found=%v err=%+v", found, ownershipErr)
	}
	WithBuyerOwnershipLookup(func(context.Context, string, []int64) (map[string]bool, error) { return nil, nil })(s)
	_, _, found, _, _ = s.selectRelayBlindProvider(ctx, "acct", "model-a", 2048, false, relayblind.KeyClassRelayBlind, nil)
	if !found {
		t.Fatal("successful no-link lookup excluded ordinary relay-blind buyer")
	}
}

func TestBuyerOwnershipOperatorMapAppliesGlobally(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	own, other := poolProvider("own"), poolProvider("other")
	registry.Register(&own, nil)
	registry.Register(&other, nil)
	tp.SetProviderOwnerAccounts(map[string][]string{"acct": {"own"}})
	got, routeErr := s.selectProviderExcluding(routingOwnerContext(t, "acct"), "route", poolChatReq(""), http.Header{}, nil, "day", &forwardState{})
	if routeErr != nil || got.ProviderID != "other" {
		t.Fatalf("global route ignored owner map: %+v %v", got, routeErr)
	}
}

func TestBuyerOwnershipEncryptedDispatchRevalidates(t *testing.T) {
	for _, tc := range []struct {
		private, lookupFails bool
	}{{false, false}, {true, false}, {false, true}, {true, true}} {
		private := tc.private
		t.Run(fmt.Sprintf("privacy=%v/lookup_fails=%v", private, tc.lookupFails), func(t *testing.T) {
			var dispatches atomic.Int32
			h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, privacyEnabled: true, relayKey: true, relay: privacySuccessRelay(`{"choices":[]}`, nil, &dispatches)})
			metrics := &recordingRouteMetrics{}
			h.authority.UseMetrics(metrics)
			owned := false
			WithBuyerOwnershipLookup(func(context.Context, string, []int64) (map[string]bool, error) {
				if owned && tc.lookupFails {
					return nil, errors.New("ownership store closed")
				}
				return map[string]bool{h.provider.ProviderID: owned}, nil
			})(h.server)
			reservation := h.reserve(t, private)
			key := h.relayPrivate
			if private {
				key = h.privacyPrivate
			}
			envelope := h.seal(t, reservation, "owned-after-reservation", key)
			send := func(path string, body []byte, auth string) *httptest.ResponseRecorder {
				if private {
					return h.privacyRequest(t, http.MethodPost, path, body, auth, nil)
				}
				return relayBlindRequest(t, h.server, http.MethodPost, path, body, auth)
			}
			rr := send("/v1/relay-blind/consume", envelope, "")
			consume, err := relayblind.ParseConsumeResponse(rr.Body.Bytes())
			if rr.Code != 200 || err != nil {
				t.Fatalf("consume=%d %s err=%v", rr.Code, rr.Body.String(), err)
			}
			owned = true
			rr = send("/v1/chat/completions", envelope, consume.ExecutionAuthorization)
			if rr.Code != 503 || dispatches.Load() != 0 {
				t.Fatalf("owned encrypted dispatch=%d status=%d body=%s", dispatches.Load(), rr.Code, rr.Body.String())
			}
			if rr.Header().Get(settlementNoPriorDispatchHeader) != "1" {
				t.Fatal("pre-dispatch ownership refusal lacks the no-prior-dispatch marker")
			}
			reason := relayblind.PrivacyRejectDispatchUnavailable
			if tc.lookupFails {
				reason = relayblind.PrivacyRejectStoreUnavailable
			}
			want := 0
			if private {
				want = 1
			}
			if got := metrics.count(relayblind.PrivacyRejectPhaseDispatch, reason); got != want {
				t.Fatalf("privacy rejection %s counted %d, want %d", reason, got, want)
			}
			if tc.lookupFails && h.server.ownershipLookupRefusals.Load() == 0 || !tc.lookupFails && h.server.ownedProviderRefusals.Load() == 0 {
				t.Fatal("ownership refusal was not counted")
			}
			row, err := h.store.LookupReservation(context.Background(), consume.ProviderBinding)
			if err != nil || row.State != relayblind.ReservationStateRejected {
				t.Fatalf("reservation state=%s err=%v", row.State, err)
			}
		})
	}
}

func TestBuyerOwnershipFailoverCannotSelectOwnProvider(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	s.failoverEnabled = true
	own, failed := poolProvider("own"), poolProvider("failed")
	registry.Register(&own, nil)
	registry.Register(&failed, nil)
	WithBuyerOwnershipLookup(func(context.Context, string, []int64) (map[string]bool, error) {
		return map[string]bool{"own": true}, nil
	})(s)
	next, ok := s.failoverCandidate(routingOwnerContext(t, "acct"), "fallback", poolChatReq(""), http.Header{}, failed, nil, "day", &forwardState{})
	if ok {
		t.Fatalf("failover selected owned provider: %s", next.ProviderID)
	}
}

func TestBuyerOwnershipRelayBlindReservationLookupFailureIsTransient(t *testing.T) {
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, privacyEnabled: true, relayKey: true})
	WithBuyerOwnershipLookup(func(context.Context, string, []int64) (map[string]bool, error) {
		return nil, errors.New("ownership store closed")
	})(h.server)
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	rr := relayBlindRequest(t, h.server, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "")
	if rr.Code != http.StatusServiceUnavailable || !strings.Contains(rr.Body.String(), `"relay_blind_required_unavailable"`) {
		t.Fatalf("status=%d body=%s, want transient relay_blind_required_unavailable", rr.Code, rr.Body.String())
	}
}
