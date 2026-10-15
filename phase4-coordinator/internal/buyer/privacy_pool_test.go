package buyer

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// SPEC-049-R032 tests: a privacy-class request scoped to a Trusted Pool.

const privacyTestPoolID = "pool-privacy-a"

func privacyPoolSnapshot(members []string, generation uint64) trustpool.RouteableSnapshot {
	return trustpool.RouteableSnapshot{
		PoolID:             privacyTestPoolID,
		Members:            members,
		BuyerAccounts:      []string{"account-a"},
		SettlementMode:     "observe",
		Routeable:          true,
		Generation:         generation,
		RouteableUntilUTC:  time.Unix(1_800_000_000, 0).UTC().Add(24 * time.Hour),
		ManifestVersion:    3,
		ManifestCoreDigest: strings.Repeat("c", 64),
	}
}

func newPrivacyPoolHarness(t *testing.T, cfg privacyHarnessConfig, snapshot trustpool.RouteableSnapshot) (*privacyHarness, *trustpool.Registry) {
	t.Helper()
	registry := trustpool.NewRegistry()
	if err := registry.LoadRouteableSnapshotsAtRevision(0, []trustpool.RouteableSnapshot{snapshot}); err != nil {
		t.Fatal(err)
	}
	cfg.trustPools = registry
	return newPrivacyHarness(t, cfg), registry
}

// privacyPoolHeaders is an API-key buyer (no wallet session) whose gateway
// forwarded the authorized pool.
func privacyPoolHeaders(poolID string) func(*http.Request) {
	return func(r *http.Request) {
		r.Header.Del("X-MacProvider-Wallet-Session")
		if poolID != "" {
			r.Header.Set("X-MacProvider-Pool", poolID)
		}
	}
}

func (h *privacyHarness) reservePool(t *testing.T, poolID string) *httptest.ResponseRecorder {
	t.Helper()
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	return h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", privacyPoolHeaders(poolID))
}

func requirePrivacyRefusal(t *testing.T, response *httptest.ResponseRecorder, status int, code, reason string) {
	t.Helper()
	if response.Code != status || !strings.Contains(response.Body.String(), `"code":"`+code+`"`) || response.Header().Get(relayblind.PrivacyRejectReasonHeader) != reason {
		t.Fatalf("status=%d reason=%q body=%s, want %d %s %s", response.Code, response.Header().Get(relayblind.PrivacyRejectReasonHeader), response.Body.String(), status, code, reason)
	}
}

func TestPrivacyPoolMemberEnrolledIsServed(t *testing.T) {
	body := privacyTestResponseBody(t)
	var gotClass atomic.Value
	var dispatches atomic.Int32
	h, registry := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyKey: true, requestLog: true, relay: privacySuccessRelay(body, &gotClass, &dispatches)}, privacyPoolSnapshot([]string{"provider-a"}, 7))
	response := h.reservePool(t, privacyTestPoolID)
	if response.Code != http.StatusOK {
		t.Fatalf("reservation status=%d body=%s", response.Code, response.Body.String())
	}
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if err != nil {
		t.Fatalf("parse: %v body=%s", err, response.Body.String())
	}
	if reservation.PoolID != privacyTestPoolID || reservation.PoolManifestVersion != 3 || reservation.PoolManifestCoreDigest != strings.Repeat("c", 64) || reservation.KeyRecordDigest != h.privacyKey.KeyRecordDigest {
		t.Fatalf("reservation pool labels = %+v", reservation)
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.PoolID != privacyTestPoolID || row.PoolGeneration != 7 || row.PoolManifestVersion != 3 || !row.PrivacyClass {
		t.Fatalf("row=%+v err=%v", row, err)
	}
	raw := h.seal(t, reservation, "privacy-pool-served", h.privacyPrivate)
	response = h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", privacyPoolHeaders(privacyTestPoolID))
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if response.Code != http.StatusOK || err != nil {
		t.Fatalf("consume status=%d err=%v body=%s", response.Code, err, response.Body.String())
	}
	response = h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, privacyPoolHeaders(privacyTestPoolID))
	if response.Code != http.StatusOK || response.Body.String() != body || response.Header().Get(privacyClassHeader) != relayblind.PrivacyClassV1 {
		t.Fatalf("chat status=%d body=%s", response.Code, response.Body.String())
	}
	if gotClass.Load() != relayblind.PrivacyClassV1 || dispatches.Load() != 1 {
		t.Fatalf("class=%v dispatches=%d", gotClass.Load(), dispatches.Load())
	}
	if !registry.PoolDeliveryDrained(privacyTestPoolID) {
		t.Fatal("pool delivery counter was not released")
	}
	var poolID string
	if err := h.requestLog.DB().QueryRow(`SELECT COALESCE(pool_id,'') FROM request_log WHERE status = 200`).Scan(&poolID); err != nil || poolID != privacyTestPoolID {
		t.Fatalf("request log pool_id=%q err=%v", poolID, err)
	}
}

func TestPrivacyPoolEnrolledNonMemberIsRejected(t *testing.T) {
	var dispatches atomic.Int32
	h, _ := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyKey: true, relay: privacyCountingRelay(&dispatches)}, privacyPoolSnapshot([]string{"provider-other"}, 7))
	requirePrivacyRefusal(t, h.reservePool(t, privacyTestPoolID), http.StatusServiceUnavailable, privacyClassUnavailable, relayblind.PrivacyRejectPoolNoEligibleMember)
	// The same enrolled provider still serves the global privacy class.
	global := h.reservePool(t, "")
	if global.Code != http.StatusOK {
		t.Fatalf("global reservation status=%d body=%s", global.Code, global.Body.String())
	}
	if count, err := h.store.CountReservations(context.Background()); err != nil || count != 1 || dispatches.Load() != 0 {
		t.Fatalf("reservations=%d err=%v dispatches=%d", count, err, dispatches.Load())
	}
}

func TestPrivacyPoolMemberNotEnrolledIsRejectedWithClosedReason(t *testing.T) {
	h, _ := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyEnabled: true}, privacyPoolSnapshot([]string{"provider-a"}, 7))
	response := h.reservePool(t, privacyTestPoolID)
	// A member that serves the model without a privacy key reports the
	// privacy-side reason, never a pool reason, and the buyer code is the
	// same privacy_class_unavailable a non-member gets.
	requirePrivacyRefusal(t, response, http.StatusServiceUnavailable, privacyClassUnavailable, relayblind.PrivacyRejectModelNotPrivateCapable)
	if count, _ := h.store.CountReservations(context.Background()); count != 0 {
		t.Fatalf("reservations=%d", count)
	}
}

func TestPrivacyPoolMemberWithoutPoolCapabilityIsNotACandidate(t *testing.T) {
	h, _ := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyKey: true}, privacyPoolSnapshot([]string{"provider-a"}, 7))
	h.provider.TrustedPoolV1 = false
	requirePrivacyRefusal(t, h.reservePool(t, privacyTestPoolID), http.StatusServiceUnavailable, privacyClassUnavailable, relayblind.PrivacyRejectPoolNoEligibleMember)
}

func TestPrivacyPoolGateRefusesBeforeSelection(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*trustpool.RouteableSnapshot)
		status int
		code   string
	}{
		{"unauthorized_account", func(s *trustpool.RouteableSnapshot) { s.BuyerAccounts = []string{"account-other"} }, http.StatusServiceUnavailable, "pool_unavailable"},
		{"not_routeable", func(s *trustpool.RouteableSnapshot) { s.Routeable = false }, http.StatusServiceUnavailable, "pool_unavailable"},
		{"seed_only_pool", func(s *trustpool.RouteableSnapshot) { s.ManifestVersion, s.ManifestCoreDigest = 0, "" }, http.StatusServiceUnavailable, "pool_unavailable"},
		{"model_not_allowed", func(s *trustpool.RouteableSnapshot) { s.ModelAllowlist = []string{"model-b"} }, http.StatusBadRequest, "pool_model_not_allowed"},
		{"settlement_enforce_required", func(s *trustpool.RouteableSnapshot) { s.SettlementMode = "enforce" }, http.StatusServiceUnavailable, "pool_settlement_mode_unsatisfied"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			snapshot := privacyPoolSnapshot([]string{"provider-a"}, 7)
			tc.mutate(&snapshot)
			h, _ := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyKey: true}, snapshot)
			h.server.poolRejectionTimingFloor = time.Nanosecond
			requirePrivacyRefusal(t, h.reservePool(t, privacyTestPoolID), tc.status, tc.code, relayblind.PrivacyRejectPoolScopedRequest)
			if count, _ := h.store.CountReservations(context.Background()); count != 0 {
				t.Fatalf("reservations=%d", count)
			}
		})
	}
	t.Run("unknown_pool", func(t *testing.T) {
		h, _ := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyKey: true}, privacyPoolSnapshot([]string{"provider-a"}, 7))
		h.server.poolRejectionTimingFloor = time.Nanosecond
		requirePrivacyRefusal(t, h.reservePool(t, "pool-unknown"), http.StatusServiceUnavailable, "pool_unavailable", relayblind.PrivacyRejectPoolScopedRequest)
	})
}

func TestPrivacyPoolSelectionRefusedForWalletSessionAndPlainRelayBlind(t *testing.T) {
	h, _ := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true}, privacyPoolSnapshot([]string{"provider-a"}, 7))
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	wallet := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", func(r *http.Request) { r.Header.Set("X-MacProvider-Pool", privacyTestPoolID) })
	requirePrivacyRefusal(t, wallet, http.StatusBadRequest, privacyClassDowngrade, relayblind.PrivacyRejectPoolScopedRequest)
	smuggled := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", func(r *http.Request) {
		privacyPoolHeaders(privacyTestPoolID)(r)
		r.Header.Set("X-MacProvider-Pool-Manifest-Core-Digest", "x")
	})
	requirePrivacyRefusal(t, smuggled, http.StatusBadRequest, privacyClassDowngrade, relayblind.PrivacyRejectPoolScopedRequest)
	plain := h.serverRequest(t, raw, privacyPoolHeaders(privacyTestPoolID))
	if plain.Code != http.StatusBadRequest || !strings.Contains(plain.Body.String(), `"code":"relay_blind_downgrade_rejected"`) {
		t.Fatalf("plain relay-blind with pool status=%d body=%s", plain.Code, plain.Body.String())
	}
	if count, _ := h.store.CountReservations(context.Background()); count != 0 {
		t.Fatalf("reservations=%d", count)
	}
}

func TestPrivacyPoolBindingMismatchIsADowngrade(t *testing.T) {
	var dispatches atomic.Int32
	h, _ := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyKey: true, relay: privacyCountingRelay(&dispatches)}, privacyPoolSnapshot([]string{"provider-a"}, 7))
	// A pool reservation consumed without the pool.
	response := h.reservePool(t, privacyTestPoolID)
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if err != nil {
		t.Fatalf("parse: %v body=%s", err, response.Body.String())
	}
	raw := h.seal(t, reservation, "privacy-pool-stripped", h.privacyPrivate)
	stripped := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", privacyPoolHeaders(""))
	requirePrivacyRefusal(t, stripped, http.StatusBadRequest, privacyClassDowngrade, relayblind.PrivacyRejectMarkerMismatch)
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateRejected {
		t.Fatalf("stripped pool did not burn the reservation: %+v err=%v", row, err)
	}
	// A global reservation consumed with a pool.
	response = h.reservePool(t, "")
	global, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if err != nil || global.PoolID != "" {
		t.Fatalf("global reservation=%+v err=%v", global, err)
	}
	raw = h.seal(t, global, "privacy-pool-injected", h.privacyPrivate)
	injected := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", privacyPoolHeaders(privacyTestPoolID))
	requirePrivacyRefusal(t, injected, http.StatusBadRequest, privacyClassDowngrade, relayblind.PrivacyRejectMarkerMismatch)
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
}

func TestPrivacyPoolRevocationBetweenPhasesIsStale(t *testing.T) {
	t.Run("before_consume", func(t *testing.T) {
		h, registry := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyKey: true}, privacyPoolSnapshot([]string{"provider-a"}, 7))
		reservation, err := relayblind.ParseReservationResponse(h.reservePool(t, privacyTestPoolID).Body.Bytes())
		if err != nil {
			t.Fatal(err)
		}
		registry.Revoke(privacyTestPoolID, "provider-a")
		raw := h.seal(t, reservation, "privacy-pool-revoked", h.privacyPrivate)
		response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", privacyPoolHeaders(privacyTestPoolID))
		requirePrivacyRefusal(t, response, http.StatusServiceUnavailable, privacyClassStale, relayblind.PrivacyRejectPoolStateStale)
	})
	t.Run("before_dispatch", func(t *testing.T) {
		var dispatches atomic.Int32
		h, registry := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyKey: true, relay: privacyCountingRelay(&dispatches)}, privacyPoolSnapshot([]string{"provider-a"}, 7))
		reservation, err := relayblind.ParseReservationResponse(h.reservePool(t, privacyTestPoolID).Body.Bytes())
		if err != nil {
			t.Fatal(err)
		}
		raw := h.seal(t, reservation, "privacy-pool-revoked-late", h.privacyPrivate)
		response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", privacyPoolHeaders(privacyTestPoolID))
		consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
		if err != nil {
			t.Fatalf("consume status=%d body=%s", response.Code, response.Body.String())
		}
		// A membership change that keeps the provider a member still moves
		// the generation fence.
		registry.AddMember(privacyTestPoolID, "provider-new")
		response = h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, privacyPoolHeaders(privacyTestPoolID))
		requirePrivacyRefusal(t, response, http.StatusServiceUnavailable, privacyClassStale, relayblind.PrivacyRejectPoolStateStale)
		if dispatches.Load() != 0 {
			t.Fatalf("dispatches=%d", dispatches.Load())
		}
		row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
		if err != nil || row.State != relayblind.ReservationStateRejected {
			t.Fatalf("row=%+v err=%v", row, err)
		}
	})
}

func TestPrivacyPoolFenceRequiresTheLiveReservedSession(t *testing.T) {
	h, _ := newPrivacyPoolHarness(t, privacyHarnessConfig{privacyKey: true}, privacyPoolSnapshot([]string{"provider-a"}, 7))
	reservation, err := relayblind.ParseReservationResponse(h.reservePool(t, privacyTestPoolID).Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil {
		t.Fatal(err)
	}
	if _, fresh := h.server.privacyPoolFence(row); !fresh {
		t.Fatal("fence refused the live reserved member")
	}
	// A member whose reserved session left the registry is never fenced
	// through, even though its pool membership is unchanged.
	if !h.server.pool.RemoveIfSession("provider-a", "session-a") {
		t.Fatal("session not removed")
	}
	if _, fresh := h.server.privacyPoolFence(row); fresh {
		t.Fatal("fence passed a reservation whose session is gone")
	}
}
