package ws_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

func admissionTransportBuyerFixture(t *testing.T, kind string, relay ...buyer.RelayFunc) (*providerws.Server, *buyer.Server, pool.Provider, providerws.ModelAdmissionEvent, providerws.ModelAdmissionStore) {
	t.Helper()
	var registry *pool.Registry
	_, p, seed, feeds, rewards, billingStore, _ := ownerPrimaryAdmissionFixture(t, &registry)
	store := providerws.NewAdmissionStoreForTest(t, kind)
	owner, p, baseline := providerws.NewFullAdmissionOwnerForTest(t, registry, p, store, seed)
	options := []buyer.Option{
		buyer.WithAutotuneFeeds(feeds),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithBillingSnapshotID(1),
		buyer.WithModelAdmissionStore(store),
		buyer.WithModelAdmissionTransport(owner.ModelAdmissionSessionAvailable, owner.CloseModelAdmissionTransport),
	}
	if len(relay) > 0 {
		options = append(options, buyer.WithRelay(relay[0], time.Second))
	}
	server := buyer.NewServer(registry, zerolog.Nop(), time.Now(), options...)
	if err := owner.SetModelAdmissionAuthority(server.ResolveModelAdmissionAuthority, server.PrepareModelAdmissionAuthority); err != nil {
		t.Fatal(err)
	}
	providerws.PromoteFullAdmissionForTest(owner, p, baseline)
	latest, found, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, baseline.CandidateID)
	if err != nil || !found || latest.State != "settlement_capable" {
		t.Fatalf("baseline admission found=%v state=%q err=%v", found, latest.State, err)
	}
	return owner, server, p, baseline, store
}

func admissionTransportChat(t *testing.T, server *buyer.Server, p pool.Provider, pinned bool) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"transport composition"}],"max_tokens":16}`, p.ModelID)))
	req.Header.Set("Content-Type", "application/json")
	if pinned {
		req.Header.Set("X-MacProvider-Provider", p.ProviderID)
		req.Header.Set("X-MacProvider-Session", p.AssignedID)
	}
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}

func assertAdmissionTransportRouteUnavailable(t *testing.T, rr *httptest.ResponseRecorder) {
	t.Helper()
	if rr.Code != http.StatusServiceUnavailable || (!strings.Contains(rr.Body.String(), `"code":"byom_non_settlement_unavailable"`) && !strings.Contains(rr.Body.String(), `"code":"no_provider_available"`)) {
		t.Fatalf("route remained available: status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func admissionTransportReoffer(t *testing.T, store providerws.ModelAdmissionStore, seed, revoked providerws.ModelAdmissionEvent) providerws.ModelAdmissionEvent {
	t.Helper()
	offer := seed
	offer.State = "offer_submitted"
	offer.RequestID = "replacement-reoffer"
	offer.Nonce = "replacement-reoffer"
	offer.PayloadDigestSHA256 = strings.Repeat("4", 64)
	offer.DiscoveryDigestSHA256 = strings.Repeat("6", 64)
	offer.EvaluationDigestSHA256 = strings.Repeat("7", 64)
	offer.CoordinatorEventID = ""
	offer.ExpectedCurrentEventID = ""
	offer.ArtifactAdmissionEvidence = nil
	current, replay, err := store.AppendModelAdmissionOffer(context.Background(), offer)
	if err != nil || replay {
		t.Fatalf("replacement reoffer replay=%v err=%v", replay, err)
	}
	for _, state := range []string{"sandbox_probe_only", "network_admitted_unsettled"} {
		current.ExpectedCurrentEventID = current.CoordinatorEventID
		current.CoordinatorEventID = ""
		current.State = state
		current.RequestID = "replacement-" + state
		current.Nonce = current.RequestID
		current.PayloadDigestSHA256 = strings.Repeat("5", 64)
		current, err = store.AppendModelAdmissionDecision(context.Background(), current)
		if err != nil {
			t.Fatalf("replacement %s after %s: %v", state, revoked.CoordinatorEventID, err)
		}
	}
	return current
}

// Each leaf drives one real producer and one buyer selection shape. This keeps
// the closure proof bounded while covering default and exact pinned routing.
func TestAdmissionTransportRealProducersInvalidateBuyerSelection(t *testing.T) {
	for _, tc := range []struct {
		name    string
		pinned  bool
		trigger func(*testing.T, *providerws.Server, pool.Provider) func()
	}{
		{
			name:    "closeSession_default",
			trigger: providerws.TriggerCloseSessionHeldForTest,
		},
		{
			name:   "scheduled_trust_pinned_ready_revival",
			pinned: true,
			trigger: func(t *testing.T, owner *providerws.Server, p pool.Provider) func() {
				return providerws.TriggerTrustClosureHeldForTest(t, owner, p, true)
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			owner, server, p, _, _ := admissionTransportBuyerFixture(t, "memory")
			if _, ok := providerws.CaptureAdmissionTransportSessionForTest(owner, p); !ok {
				t.Fatal("real accepted session was not observable")
			}
			fire := tc.trigger(t, owner, p)
			if owner.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
				t.Fatal("closing session remained admission-available")
			}
			assertAdmissionTransportRouteUnavailable(t, admissionTransportChat(t, server, p, tc.pinned))
			fire()
			if owner.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
				t.Fatal("terminal closure revived admission availability")
			}
		})
	}
}

func TestAdmissionTransportCallbackStateTable(t *testing.T) {
	for _, tc := range []struct {
		state string
		want  bool
	}{
		{state: "exact", want: true},
		{state: "absent-map"},
		{state: "closing"},
		{state: "terminal-closed"},
	} {
		t.Run(tc.state, func(t *testing.T) {
			owner, _, p, _, _ := admissionTransportBuyerFixture(t, "memory")
			providerws.SetAdmissionTransportStateForTest(t, owner, p, tc.state)
			if got := owner.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID); got != tc.want {
				t.Fatalf("availability=%v want %v", got, tc.want)
			}
		})
	}

	owner, _, p, _, _ := admissionTransportBuyerFixture(t, "memory")
	for _, ids := range [][2]string{{"", p.AssignedID}, {p.ProviderID + "-other", p.AssignedID}, {p.ProviderID, ""}, {p.ProviderID, p.AssignedID + "-other"}} {
		if owner.ModelAdmissionSessionAvailable(ids[0], ids[1]) {
			t.Fatalf("non-exact callback tuple accepted: %q %q", ids[0], ids[1])
		}
	}
}

// The old trust timer is retained across a real replacement registration. A
// refreshed offer/evaluation is promoted for the replacement before the old
// timer fires, then actual buyer selection must still reach that replacement.
func TestAdmissionTransportOldTimerCannotDisplaceReadmittedReplacement(t *testing.T) {
	for _, route := range []struct {
		name   string
		pinned bool
	}{
		{name: "default"},
		{name: "pinned", pinned: true},
	} {
		t.Run(route.name, func(t *testing.T) {
			selected := make(chan pool.Provider, 1)
			owner, server, p, seed, store := admissionTransportBuyerFixture(t, "sqlite", func(_ context.Context, provider pool.Provider, _ string, _ []byte, _ bool) (*providerws.RelayStream, error) {
				selected <- provider
				return nil, errors.New("selection observed")
			})
			fireOld := providerws.TriggerTrustClosureHeldForTest(t, owner, p, true)
			assertAdmissionTransportRouteUnavailable(t, admissionTransportChat(t, server, p, route.pinned))
			revoked, found, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, seed.CandidateID)
			if err != nil || !found || revoked.State != "revoked" {
				t.Fatalf("old session revocation found=%v state=%q err=%v", found, revoked.State, err)
			}
			replacement := providerws.ReplaceAdmissionTransportSessionForTest(t, owner, p)

			refreshed := admissionTransportReoffer(t, store, seed, revoked)
			providerws.PromoteFullAdmissionForTest(owner, replacement, refreshed)
			latest, found, err := store.LatestModelAdmissionStatus(context.Background(), replacement.ProviderID, refreshed.CandidateID)
			if err != nil || !found || latest.State != "settlement_capable" {
				t.Fatalf("replacement admission found=%v state=%q err=%v", found, latest.State, err)
			}
			if latest.DiscoveryDigestSHA256 == seed.DiscoveryDigestSHA256 || latest.EvaluationDigestSHA256 == seed.EvaluationDigestSHA256 {
				t.Fatal("replacement reused old discovery/evaluation identity")
			}
			replayed, err := store.AppendModelAdmissionDecision(context.Background(), revoked)
			if err != nil || replayed.CoordinatorEventID != revoked.CoordinatorEventID {
				t.Fatalf("old revocation replay event=%q err=%v", replayed.CoordinatorEventID, err)
			}
			stale := revoked
			stale.CoordinatorEventID = ""
			stale.ExpectedCurrentEventID = revoked.CoordinatorEventID
			stale.RequestID += "-distinct-stale"
			stale.Nonce += "-distinct-stale"
			stale.PayloadDigestSHA256 = strings.Repeat("3", 64)
			if _, err := store.AppendModelAdmissionDecision(context.Background(), stale); err == nil {
				t.Fatal("distinct stale old revocation displaced replacement")
			}

			fireOld()
			if !owner.ModelAdmissionSessionAvailable(replacement.ProviderID, replacement.AssignedID) {
				t.Fatal("old timer displaced exact replacement session")
			}
			if owner.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
				t.Fatal("old session became available after its timer fired")
			}

			rr := admissionTransportChat(t, server, replacement, route.pinned)
			select {
			case got := <-selected:
				if got.ProviderID != replacement.ProviderID || got.AssignedID != replacement.AssignedID {
					t.Fatalf("selected stale session %q/%q", got.ProviderID, got.AssignedID)
				}
			default:
				t.Fatalf("buyer did not select replacement: status=%d body=%s", rr.Code, rr.Body.String())
			}
		})
	}
}
