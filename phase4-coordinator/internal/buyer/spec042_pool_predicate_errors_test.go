package buyer

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	"github.com/rs/zerolog"
)

func TestPoolPredicateErrors_EncryptedLegUnsatisfied(t *testing.T) {
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	plain := poolProvider("member-plain")
	plain.EncryptedLeg = false
	registry.Register(&plain, nil)
	tp.AddMember("P", "member-plain")
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithPoolMembership(tp),
		WithTier2Config(config.Tier2Config{RequireEncryptedLeg: true}),
	)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_encrypted_leg_unsatisfied" {
		t.Fatalf("encrypted-leg pool predicate: want pool_encrypted_leg_unsatisfied, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_encrypted_leg_unsatisfied must be non-retryable")
	}
}

func TestPoolPredicateErrors_AttestationUnsatisfied(t *testing.T) {
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	unsupported := poolProvider("member-unsupported")
	unsupported.EncryptedLeg = true
	unsupported.AttestationStatus = pool.AttestationStatusUnsupported
	registry.Register(&unsupported, nil)
	tp.AddMember("P", "member-unsupported")
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithPoolMembership(tp),
		WithTier2Config(config.Tier2Config{RequireAttestation: true}),
	)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_attestation_unsatisfied" {
		t.Fatalf("attestation pool predicate: want pool_attestation_unsatisfied, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_attestation_unsatisfied must be non-retryable")
	}
}

func TestPoolPredicateErrors_SettlementModeUnsatisfied(t *testing.T) {
	s, registry := enforceReceiptServer(t)
	tp := trustpool.NewRegistry()
	s.trustPools = tp
	noKey := receiptGateProvider("member-no-key", nil)
	noKey.TrustedPoolV1 = true
	registry.Register(&noKey, nil)
	tp.AddMember("P", "member-no-key")

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_settlement_mode_unsatisfied" {
		t.Fatalf("settlement pool predicate: want pool_settlement_mode_unsatisfied, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_settlement_mode_unsatisfied must be non-retryable")
	}
}

func TestPoolPredicateErrors_SettlementPolicyRequiresEnforceMode(t *testing.T) {
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	now := time.Unix(1716768000, 0).UTC()
	member := poolProvider("member-with-key")
	member.ReceiptPubkey = []byte("receipt-key")
	if _, registered := registry.RegisterAt(&member, nil, now); !registered {
		t.Fatal("RegisterAt refused member-with-key")
	}
	slotsFree := 1
	published, ok := registry.ApplyStateUpdate("member-with-key", member.AssignedID, pool.StateUpdate{
		State:     pool.StateReady,
		SlotsFree: &slotsFree,
		At:        now,
	})
	if !ok || len(published.ReceiptPubkey) == 0 || !published.RoutingEligible() {
		t.Fatalf("published provider = %+v ok=%v, want active receipt key and routing-eligible", published, ok)
	}
	if err := tp.LoadRouteableSnapshot(trustpool.RouteableSnapshot{
		PoolID:         "P",
		Members:        []string{"member-with-key"},
		SettlementMode: "enforce",
		Routeable:      true,
		Generation:     1,
	}); err != nil {
		t.Fatalf("LoadRouteableSnapshot: %v", err)
	}
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithPoolMembership(tp),
	)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_settlement_mode_unsatisfied" {
		t.Fatalf("settlement policy enforce gate: want pool_settlement_mode_unsatisfied, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_settlement_mode_unsatisfied must be non-retryable")
	}
}

func TestPoolPredicateErrors_SettlementPolicyEnforceModeRoutesWithReceiptKey(t *testing.T) {
	enforceServer, _ := enforceReceiptServer(t)
	billingStore, billingCfg, _ := enforceServer.billingState()
	s, registry, tp := poolIsolationServer(t)
	WithBilling(billingStore, billingCfg)(s)
	now := time.Unix(1716768000, 0).UTC()
	member := poolProvider("member-with-key")
	member.ReceiptPubkey = []byte("receipt-key")
	if _, registered := registry.RegisterAt(&member, nil, now); !registered {
		t.Fatal("RegisterAt refused member-with-key")
	}
	slotsFree := 1
	published, ok := registry.ApplyStateUpdate("member-with-key", member.AssignedID, pool.StateUpdate{
		State:     pool.StateReady,
		SlotsFree: &slotsFree,
		At:        now,
	})
	if !ok || len(published.ReceiptPubkey) == 0 || !published.RoutingEligible() {
		t.Fatalf("published provider = %+v ok=%v, want active receipt key and routing-eligible", published, ok)
	}
	if err := tp.LoadRouteableSnapshot(trustpool.RouteableSnapshot{
		PoolID:         "P",
		Members:        []string{"member-with-key"},
		SettlementMode: "enforce",
		Routeable:      true,
		Generation:     1,
	}); err != nil {
		t.Fatalf("LoadRouteableSnapshot: %v", err)
	}

	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "member-with-key")
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), headers, nil, "2024-01-01", &forwardState{})
	if routeErr != nil {
		t.Fatalf("settlement policy enforce gate rejected enforce-capable route: %+v", routeErr)
	}
	if got.ProviderID != "member-with-key" {
		t.Fatalf("provider = %q, want member-with-key", got.ProviderID)
	}
}

func TestPoolPredicateErrors_SettlementPolicyPinnedNoReceiptKeyUsesPoolCode(t *testing.T) {
	for _, tc := range []struct {
		name      string
		header    string
		headerVal string
	}{
		{name: "provider", header: "X-MacProvider-Provider", headerVal: "member-no-key"},
		{name: "session", header: "X-MacProvider-Session", headerVal: "s-member-no-key"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			enforceServer, _ := enforceReceiptServer(t)
			billingStore, billingCfg, _ := enforceServer.billingState()
			s, registry, tp := poolIsolationServer(t)
			WithBilling(billingStore, billingCfg)(s)
			member := receiptGateProvider("member-no-key", nil)
			member.TrustedPoolV1 = true
			registry.Register(&member, nil)
			if err := tp.LoadRouteableSnapshot(trustpool.RouteableSnapshot{
				PoolID:         "P",
				Members:        []string{"member-no-key"},
				SettlementMode: "enforce",
				Routeable:      true,
				Generation:     1,
			}); err != nil {
				t.Fatalf("LoadRouteableSnapshot: %v", err)
			}
			headers := http.Header{}
			headers.Set(tc.header, tc.headerVal)

			_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), headers, nil, "2024-01-01", &forwardState{})
			if routeErr == nil || routeErr.code != "pool_settlement_mode_unsatisfied" {
				t.Fatalf("%s pin settlement predicate: want pool_settlement_mode_unsatisfied, got %+v", tc.name, routeErr)
			}
			if spec018RetryableByCode[routeErr.code] {
				t.Fatalf("%s pin pool_settlement_mode_unsatisfied must be non-retryable", tc.name)
			}
		})
	}
}

func TestPoolPredicateErrors_SettlementPolicyQueuedNoReceiptKeyUsesPoolCode(t *testing.T) {
	enforceServer, _ := enforceReceiptServer(t)
	billingStore, billingCfg, _ := enforceServer.billingState()
	s, registry, _ := poolIsolationServer(t)
	WithBilling(billingStore, billingCfg)(s)
	active := receiptGateProvider("member-queued", nil)
	active.TrustedPoolV1 = true
	registry.Register(&active, nil)
	candidate := active
	candidate.ReceiptPubkey = []byte("receipt-key-at-selection")
	candidate.SlotsFree = 0
	state := &forwardState{
		poolID:                        "P",
		poolMembers:                   map[string]bool{"member-queued": true},
		poolRequiresSettlementEnforce: true,
	}

	_, routeErr, queued := s.trySelectQueuedProvider(context.Background(), "rid", "model-a", []pool.Provider{candidate}, http.Header{}, nil, "2024-01-01", 100, state)
	if !queued {
		t.Fatal("trySelectQueuedProvider queued=false, want queued path exercised")
	}
	if routeErr == nil || routeErr.code != "pool_settlement_mode_unsatisfied" {
		t.Fatalf("queued settlement predicate: want pool_settlement_mode_unsatisfied, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("queued pool_settlement_mode_unsatisfied must be non-retryable")
	}
}

func TestPoolPredicateErrors_SettlementPolicyRecheckedBeforeDispatch(t *testing.T) {
	enforceServer, _ := enforceReceiptServer(t)
	billingStore, billingCfg, _ := enforceServer.billingState()
	s, _, tp := poolIsolationServer(t)
	WithBilling(billingStore, billingCfg)(s)
	tp.AddMember("P", "member-with-key")

	observeCfg := config.Default().Settlement
	observeCfg.VerifiedModelSettlementMode = billing.RouteSnapshotModeObserve
	billingStore.SetSettlementConfig(observeCfg)

	state := &forwardState{
		poolID:                        "P",
		poolMembers:                   map[string]bool{"member-with-key": true},
		poolGeneration:                tp.Generation("P"),
		poolGenSet:                    true,
		poolRequiresSettlementEnforce: true,
		provider:                      poolProvider("member-with-key"),
		faultedRoutes:                 map[string]struct{}{},
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rr := httptest.NewRecorder()
	rec := &billingRecorder{
		server:    s,
		state:     state,
		req:       req,
		startedAt: time.Unix(1716768000, 0),
		requestID: "rid",
	}
	dispatched := false

	s.forwardWithFailover(rr, req, poolChatReq("P"), "rid", "rid", time.Unix(1716768000, 0), state, map[string]struct{}{}, rec, transportCallbacks{
		dispatch: func(http.ResponseWriter, *http.Request, chatRequest, string, string, time.Time, *forwardState, *billingRecorder) (dispatchedAttempt, bool) {
			dispatched = true
			return dispatchedAttempt{}, false
		},
	})
	if dispatched {
		t.Fatal("dispatch callback ran after settlement mode downgraded to observe")
	}
	if rr.Code != http.StatusServiceUnavailable || !strings.Contains(rr.Body.String(), "pool_settlement_mode_unsatisfied") {
		t.Fatalf("status/body = %d/%s, want 503 pool_settlement_mode_unsatisfied", rr.Code, rr.Body.String())
	}
	if rr.Header().Get(settlementNoPriorDispatchHeader) != "1" {
		t.Fatalf("%s = %q, want 1", settlementNoPriorDispatchHeader, rr.Header().Get(settlementNoPriorDispatchHeader))
	}
}

func TestPoolPredicateErrors_ProviderCapabilityUnsatisfied(t *testing.T) {
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	legacy := poolProvider("member-legacy")
	legacy.TrustedPoolV1 = false
	registry.Register(&legacy, nil)
	tp.AddMember("P", "member-legacy")
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithPoolMembership(tp),
	)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_provider_capability_unsatisfied" {
		t.Fatalf("provider capability pool predicate: want pool_provider_capability_unsatisfied, got %+v", routeErr)
	}
	if spec018RetryableByCode[routeErr.code] {
		t.Fatal("pool_provider_capability_unsatisfied must be non-retryable")
	}
}

func TestPoolPredicateErrors_CapableMemberLaterPredicateWinsOverLegacyCapability(t *testing.T) {
	registry := pool.NewRegistry(nil)
	tp := trustpool.NewRegistry()
	legacy := poolProvider("member-legacy")
	legacy.TrustedPoolV1 = false
	registry.Register(&legacy, nil)
	tp.AddMember("P", "member-legacy")

	capablePlain := poolProvider("member-capable-plain")
	capablePlain.EncryptedLeg = false
	registry.Register(&capablePlain, nil)
	tp.AddMember("P", "member-capable-plain")

	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithPoolMembership(tp),
		WithTier2Config(config.Tier2Config{RequireEncryptedLeg: true}),
	)

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_encrypted_leg_unsatisfied" {
		t.Fatalf("mixed capability/predicate failure: want pool_encrypted_leg_unsatisfied, got %+v", routeErr)
	}
}
