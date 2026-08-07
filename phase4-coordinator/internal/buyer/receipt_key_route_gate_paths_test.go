package buyer

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	"github.com/rs/zerolog"
)

// enforceReceiptServer builds a buyer.Server whose billing store is in
// verified_model_settlement_mode=enforce, so settlementEnforceMode()
// returns true and the receipt-key gate is live. Returns the registry so
// callers can register providers for the queue/poll paths. The settlement
// config is based on config.Default().Settlement (non-zero CadenceDays) so
// the store's SettlementConfig getter returns the enforce override rather
// than falling back to the default.
func enforceReceiptServer(t *testing.T) (*Server, *pool.Registry) {
	t.Helper()
	reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "billing.db"))
	if err != nil {
		t.Fatalf("requestlog.OpenStore: %v", err)
	}
	t.Cleanup(func() { _ = reqLog.Close() })
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	cfg := config.Default().Settlement
	cfg.VerifiedModelSettlementMode = billing.RouteSnapshotModeEnforce
	store.SetSettlementConfig(cfg)
	registry := pool.NewRegistry(nil)
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		WithBilling(store, config.Default().Rewards),
	)
	return s, registry
}

func receiptGateProvider(providerID string, receiptPubkey []byte) pool.Provider {
	return pool.Provider{
		ProviderID:       providerID,
		AssignedID:       "s-" + providerID,
		ModelID:          "model-a",
		State:            pool.StateReady,
		Tier:             pool.TierPinned,
		MaxContextTokens: 50000,
		MaxConcurrency:   1,
		SlotsTotal:       1,
		SlotsFree:        1,
		EndpointURL:      "https://" + providerID + ".example",
		InferencePath:    pool.InferencePathHTTPForwarding,
		LastHeartbeatAt:  time.Now().UTC(),
		ConnectedAt:      time.Now().UTC(),
		ReceiptPubkey:    receiptPubkey,
	}
}

// TestReceiptKeyGate_ExcludesFromPinnedRoute: the pinned/self-route path
// bypasses EligibleCandidates, so it must re-apply the enforce-mode
// receipt-key gate — a hard pin to an empty-key provider must be refused
// with 503 no_provider_available (retryable), not routed to the guard (500).
func TestReceiptKeyGate_ExcludesFromPinnedRoute(t *testing.T) {
	s, _ := enforceReceiptServer(t)

	noKey := receiptGateProvider("no-key", nil)
	_, routeErr := s.validatePinnedProviderForRequest(noKey, "model-a", 100, "Pinned provider not available", nil)
	if routeErr == nil {
		t.Fatal("pinned empty-receipt-key provider accepted under enforce")
	}
	if routeErr.status != 503 || routeErr.code != "no_provider_available" {
		t.Fatalf("route error = %d/%q, want 503/no_provider_available", routeErr.status, routeErr.code)
	}

	withKey := receiptGateProvider("with-key", []byte("some-receipt-pubkey"))
	if _, routeErr := s.validatePinnedProviderForRequest(withKey, "model-a", 100, "Pinned provider not available", nil); routeErr != nil {
		t.Fatalf("pinned provider with a receipt key rejected: %+v", routeErr)
	}
}

// TestReceiptKeyGate_ExcludesFromSlotQueue: slotQueueCandidates re-derives
// the routing gate by hand, so it must apply the receipt-key predicate too.
func TestReceiptKeyGate_ExcludesFromSlotQueue(t *testing.T) {
	s, _ := enforceReceiptServer(t)
	checker := &eligibilityCtx{s: s, model: "model-a", estimatedTokens: 100, tier2Cfg: s.tier2Config(), settlementEnforce: true}
	busy := func(id string, key []byte) pool.Provider {
		p := receiptGateProvider(id, key)
		p.SlotsFree = 0 // slot-queue eligibility requires a saturated provider
		return p
	}
	providers := []pool.Provider{busy("no-key", nil), busy("with-key", []byte("k"))}
	got := s.slotQueueCandidates(providers, routing.NewExcluded(0), checker)
	if len(got) != 1 || got[0].ProviderID != "with-key" {
		t.Fatalf("slotQueueCandidates = %+v, want only the with-key provider", got)
	}
}

// TestReceiptKeyGate_RecheckedAtSlotQueuePoll: the waiter stores only
// providerID, so the poll must re-check the receipt-key gate — a provider
// whose active receipt key is empty must terminate the wait under enforce,
// while the SAME empty-key shape is served when settlement is not enforcing
// (observe / nil store => no-op). This isolates the gate from every other
// poll predicate.
func TestReceiptKeyGate_RecheckedAtSlotQueuePoll(t *testing.T) {
	// enforce: empty active receipt key => terminal.
	sEnforce, regEnforce := enforceReceiptServer(t)
	p := receiptGateProvider("p-queued", nil)
	regEnforce.Register(&p, nil)
	w, ok := sEnforce.slotQueue.enter("p-queued")
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	defer sEnforce.slotQueue.leave(w)
	if _, status := sEnforce.pollQueuedProvider(w, "model-a", nil, 100); status != queuedProviderTerminal {
		t.Fatalf("enforce poll status = %v, want terminal (empty active receipt key)", status)
	}

	// control: no billing store => settlementEnforceMode()==false => the
	// same empty-key provider is served off the queue (byte-identical).
	regObserve := pool.NewRegistry(nil)
	sObserve := NewServer(regObserve, zerolog.Nop(), time.Now().UTC())
	p2 := receiptGateProvider("p-queued", nil)
	regObserve.Register(&p2, nil)
	w2, ok := sObserve.slotQueue.enter("p-queued")
	if !ok {
		t.Fatal("control: enter returned no waiter")
	}
	defer sObserve.slotQueue.leave(w2)
	got, status2 := sObserve.pollQueuedProvider(w2, "model-a", nil, 100)
	if status2 != queuedProviderAvailable || got.ProviderID != "p-queued" {
		t.Fatalf("observe control poll = (%q, %v), want the provider served", got.ProviderID, status2)
	}
}
