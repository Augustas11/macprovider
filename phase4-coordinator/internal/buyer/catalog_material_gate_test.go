package buyer

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// SPEC-022-R002 R-2.7 (#1689): under enforce, a non-BYOM session whose
// served model has no Tier-2 route-snapshot material is not buyer-routable,
// because recordRouteSnapshot must fail it ("missing catalog material").

func withoutCatalogMaterial(t *testing.T) {
	t.Helper()
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
}

func TestCatalogMaterialGate_EnforceExcludesSessionWithoutMaterial(t *testing.T) {
	withoutCatalogMaterial(t)
	s, registry := enforceReceiptServer(t)
	p := receiptGateProvider("with-key", []byte("receipt-key"))
	if !s.catalogMaterialMissingUnderEnforce(p) {
		t.Fatal("enforce + no Tier-2 material must be a catalog-material miss")
	}

	checker := &eligibilityCtx{s: s, model: "model-a", estimatedTokens: 100, tier2Cfg: s.tier2Config(), settlementEnforce: true}
	if checker.ProviderHasSettlementReceiptKey(p) {
		t.Fatal("routing filter admitted a session whose route snapshot must fail for missing catalog material")
	}
	res := s.eligibleCandidates([]pool.Provider{p}, routing.NewExcluded(0), checker)
	if len(res.Eligible) != 0 || res.Counts[routing.ReasonCatalogMaterialMissing] != 1 || res.Counts[routing.ReasonReceiptKeyMissing] != 0 {
		t.Fatalf("eligibleCandidates = %+v, want the session dropped as catalog_material_missing", res)
	}
	if got := routeKeyedFilterCounts(res.Counts); got["catalog_material_missing"] != 1 || got["receipt_key_missing"] != 0 {
		t.Fatalf("routing telemetry counts = %v, want catalog_material_missing=1", got)
	}

	_, routeErr := s.validatePinnedProviderForRequest(p, "model-a", 100, "Pinned provider not available", nil, false)
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("pinned route error = %+v, want 503 no_provider_available", routeErr)
	}
	_, routeErr = s.validatePinnedProviderForRequest(p, "model-a", 100, "Pinned provider not available", nil, true)
	if routeErr == nil || routeErr.code != "pool_settlement_mode_unsatisfied" {
		t.Fatalf("pool-enforced pinned route error = %+v, want pool_settlement_mode_unsatisfied", routeErr)
	}

	busy := p
	busy.SlotsFree = 0
	if got := s.slotQueueCandidates([]pool.Provider{busy}, routing.NewExcluded(0), checker); len(got) != 0 {
		t.Fatalf("slotQueueCandidates = %+v, want none", got)
	}
	registry.Register(&p, nil)
	w, ok := s.slotQueue.enter(p.ProviderID)
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	defer s.slotQueue.leave(w)
	if _, status := s.pollQueuedProvider(w, "model-a", nil, 100, nil); status != queuedProviderTerminal {
		t.Fatalf("slot-queue poll status = %v, want terminal", status)
	}
}

// ARCH-L1: routing telemetry names the two route-snapshot preconditions
// separately; a missing receipt key stays receipt_key_missing even when the
// served model also lacks material (the key check is evaluated first).
func TestCatalogMaterialGate_ReceiptKeyMissingKeepsItsOwnReason(t *testing.T) {
	withoutCatalogMaterial(t)
	s, _ := enforceReceiptServer(t)
	checker := &eligibilityCtx{s: s, model: "model-a", estimatedTokens: 100, tier2Cfg: s.tier2Config(), settlementEnforce: true}
	noKey := receiptGateProvider("no-key", nil)
	withKey := receiptGateProvider("with-key", []byte("receipt-key"))

	res := s.eligibleCandidates([]pool.Provider{noKey, withKey}, routing.NewExcluded(0), checker)

	if len(res.Eligible) != 0 {
		t.Fatalf("eligible = %+v, want none", res.Eligible)
	}
	got := routeKeyedFilterCounts(res.Counts)
	if got["receipt_key_missing"] != 1 || got["catalog_material_missing"] != 1 {
		t.Fatalf("routing telemetry counts = %v, want receipt_key_missing=1 catalog_material_missing=1", got)
	}
	// A later ProviderHasSettlementReceiptKey call on the same checker (slot
	// queue, pressure probe) must not leak into a completed attribution.
	_ = checker.ProviderHasSettlementReceiptKey(withKey)
	again := s.eligibleCandidates([]pool.Provider{noKey}, routing.NewExcluded(0), checker)
	if again.Counts[routing.ReasonReceiptKeyMissing] != 1 || again.Counts[routing.ReasonCatalogMaterialMissing] != 0 {
		t.Fatalf("second filter counts = %v, want only receipt_key_missing", again.Counts)
	}
}

// The buyer-facing pool envelope is unchanged by the telemetry split: a pool
// whose only member lacks catalog material still answers
// pool_settlement_mode_unsatisfied.
func TestCatalogMaterialGate_PoolEnvelopeUnchanged(t *testing.T) {
	withoutCatalogMaterial(t)
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

	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq("P"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "pool_settlement_mode_unsatisfied" {
		t.Fatalf("want pool_settlement_mode_unsatisfied, got %+v", routeErr)
	}
}

func TestCatalogMaterialGate_ObserveModeUnchanged(t *testing.T) {
	withoutCatalogMaterial(t)
	// No billing store => settlementEnforceMode()==false, exactly as dispatch
	// treats a nil store: the missing material is not an exclusion.
	s := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0))
	p := receiptGateProvider("with-key", []byte("receipt-key"))
	if s.catalogMaterialMissingUnderEnforce(p) {
		t.Fatal("observe mode must not apply the catalog-material gate")
	}
	checker := &eligibilityCtx{s: s, model: "model-a", estimatedTokens: 100, tier2Cfg: s.tier2Config(), settlementEnforce: false}
	if !checker.ProviderHasSettlementReceiptKey(p) {
		t.Fatal("observe mode routing filter must stay a no-op")
	}
	if _, routeErr := s.validatePinnedProviderForRequest(p, "model-a", 100, "Pinned provider not available", nil, false); routeErr != nil {
		t.Fatalf("observe pinned route rejected: %+v", routeErr)
	}
}

func TestCatalogMaterialGate_EnforceRoutesSessionWithMaterial(t *testing.T) {
	withModelACatalogMaterial(t)
	s, _ := enforceReceiptServer(t)
	p := receiptGateProvider("with-key", []byte("receipt-key"))
	if s.catalogMaterialMissingUnderEnforce(p) {
		t.Fatal("material present must not be a catalog-material miss")
	}
	checker := &eligibilityCtx{s: s, model: "model-a", estimatedTokens: 100, tier2Cfg: s.tier2Config(), settlementEnforce: true}
	if !checker.ProviderHasSettlementReceiptKey(p) {
		t.Fatal("enforce routing filter rejected a session with Tier-2 material and a receipt key")
	}
	if _, routeErr := s.validatePinnedProviderForRequest(p, "model-a", 100, "Pinned provider not available", nil, false); routeErr != nil {
		t.Fatalf("enforce pinned route with material rejected: %+v", routeErr)
	}
}

func TestCatalogMaterialGate_BYOMBoundSessionUsesItsOwnGate(t *testing.T) {
	withoutCatalogMaterial(t)
	s, _ := enforceReceiptServer(t)
	p := receiptGateProvider("byom", []byte("receipt-key"))
	p.ModelAdmissionCandidateID = "candidate-1"
	// A BYOM-bound session fails closed on its own path (dispatch returns the
	// BYOM trusted-material error; eligibility never routes it by default), so
	// R-2.7 neither counts it nor names a catalog_material_missing hold for it.
	if catalogMaterialMissing(p) || s.catalogMaterialMissingUnderEnforce(p) {
		t.Fatal("BYOM-bound session must not be classified by the R-2.7 predicate")
	}
}

func poolCheckReadiness(t *testing.T, s *Server, details string) map[string]any {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=cm&assigned_id=s-cm&details="+details, nil)
	req.RemoteAddr = "198.51.100.7:12345"
	if details == "deployment" {
		req.Header.Set("Authorization", "Bearer operator-secret")
	}
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("pool check status = %d body=%s", rr.Code, rr.Body.String())
	}
	var response map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return response
}

func TestPoolCheckCatalogMaterialHold(t *testing.T) {
	for _, tc := range []struct {
		name         string
		enforce      bool
		material     bool
		capable      bool
		state        pool.State
		details      string
		wantServing  bool
		wantHold     string
		wantHoldNull bool
	}{
		{name: "enforce missing capable CLI holds", enforce: true, capable: true, state: pool.StateReady, details: "readiness", wantServing: false, wantHold: "catalog_material_missing"},
		{name: "enforce missing legacy CLI keeps legacy verdict", enforce: true, capable: false, state: pool.StateReady, details: "readiness", wantServing: true, wantHoldNull: true},
		{name: "enforce missing deployment evidence is honest", enforce: true, capable: false, state: pool.StateReady, details: "deployment", wantServing: false, wantHoldNull: true},
		{name: "enforce missing but not serving capable names no catalog hold", enforce: true, capable: true, state: pool.StateUnavailable, details: "readiness", wantServing: false, wantHoldNull: true},
		{name: "observe missing unchanged", enforce: false, capable: true, state: pool.StateReady, details: "readiness", wantServing: true, wantHoldNull: true},
		{name: "enforce material present", enforce: true, material: true, capable: true, state: pool.StateReady, details: "readiness", wantServing: true, wantHoldNull: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.material {
				withModelACatalogMaterial(t)
			} else {
				withoutCatalogMaterial(t)
			}
			var s *Server
			var registry *pool.Registry
			if tc.enforce {
				s, registry = enforceReceiptServer(t)
			} else {
				registry = pool.NewRegistry(nil)
				s = NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
			}
			WithOperatorKey("operator-secret")(s)
			// No receipt key: Register stages a hello-time key as pending, which
			// is not ServingCapable, and pool/check does not read the key.
			p := receiptGateProvider("cm", nil)
			p.State = tc.state
			p.CatalogMaterialHoldV1 = tc.capable
			registry.Register(&p, nil)

			response := poolCheckReadiness(t, s, tc.details)
			if response["buyer_serving"] != tc.wantServing {
				t.Fatalf("buyer_serving = %v, want %v (response %+v)", response["buyer_serving"], tc.wantServing, response)
			}
			hold, present := response["buyer_serving_hold"]
			if tc.wantHoldNull {
				if present {
					t.Fatalf("buyer_serving_hold = %v, want absent", hold)
				}
				return
			}
			if hold != tc.wantHold {
				t.Fatalf("buyer_serving_hold = %v, want %q", hold, tc.wantHold)
			}
		})
	}
}

// pressureForProviderAdmissionStore reports admission-store pressure for one
// provider only, so one routing pass holds a pressured provider next to an
// ordinary one.
type pressureForProviderAdmissionStore struct {
	*routeStatusCountingAdmissionStore
	pressured string
}

func (s *pressureForProviderAdmissionStore) LatestModelAdmissionRouteStatus(_ context.Context, providerID, _, _ string) (providerws.ModelAdmissionEvent, bool, error) {
	if providerID == s.pressured {
		return providerws.ModelAdmissionEvent{}, false, billing.ErrRouteSnapshotStorePressure
	}
	return providerws.ModelAdmissionEvent{}, false, nil
}

// CODE-L1/ARCH-L1: the store-pressure probe evaluates the route-snapshot
// verdict for a provider the BYOM gate already rejected. That verdict must
// not re-attribute another provider's receipt-key rejection.
func TestCatalogMaterialGate_PressureProbeDoesNotReattributeAnotherProvidersReason(t *testing.T) {
	withoutCatalogMaterial(t)
	s, _ := enforceReceiptServer(t)
	base := &routeStatusCountingAdmissionStore{}
	base.empty.Store(false)
	s.modelAdmissionStore = &pressureForProviderAdmissionStore{routeStatusCountingAdmissionStore: base, pressured: "pressured"}
	checker := &eligibilityCtx{s: s, model: "model-a", estimatedTokens: 100, tier2Cfg: s.tier2Config(), settlementEnforce: true}
	pressured := receiptGateProvider("pressured", []byte("receipt-key")) // lacks Tier-2 material
	noKey := receiptGateProvider("no-key", nil)

	res := s.eligibleCandidates([]pool.Provider{pressured, noKey}, routing.NewExcluded(0), checker)

	if len(res.Eligible) != 0 {
		t.Fatalf("eligible = %+v, want none", res.Eligible)
	}
	if res.Counts[routing.ReasonBYOMNonSettlement] != 1 || res.Counts[routing.ReasonReceiptKeyMissing] != 1 || res.Counts[routing.ReasonCatalogMaterialMissing] != 0 {
		t.Fatalf("counts = %v, want byom_non_settlement=1 receipt_key_missing=1 catalog_material_missing=0", res.Counts)
	}
}
