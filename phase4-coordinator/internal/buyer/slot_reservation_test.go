package buyer

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestSelectProviderReservesDirectSlot(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)

	state := &forwardState{slotReservationsEnabled: true}
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state)
	if routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}
	if got.ProviderID != provider.ProviderID {
		t.Fatalf("selected provider %q, want %q", got.ProviderID, provider.ProviderID)
	}
	if state.queuedSlotProviderID != provider.ProviderID {
		t.Fatalf("reservation provider %q, want %q", state.queuedSlotProviderID, provider.ProviderID)
	}

	blockedState := &forwardState{slotReservationsEnabled: true}
	_, routeErr = s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-14", blockedState)
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("second selection with slot reserved: want 503 no_provider_available, got %+v", routeErr)
	}

	s.releaseQueuedSlotReservation(state)
	got, routeErr = s.selectProviderExcluding(context.Background(), "rid-3", poolChatReq(""), http.Header{}, nil, "2026-09-14", &forwardState{slotReservationsEnabled: true})
	if routeErr != nil || got.ProviderID != provider.ProviderID {
		t.Fatalf("selection after release provider=%q err=%+v, want %q nil", got.ProviderID, routeErr, provider.ProviderID)
	}
}

func TestSelectProviderReservationsShedAfterAllSlotsTaken(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	first := poolProvider("p-one")
	second := poolProvider("p-two")
	registry.Register(&first, nil)
	registry.Register(&second, nil)

	state1 := &forwardState{slotReservationsEnabled: true}
	selected1, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state1)
	if routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}

	state2 := &forwardState{slotReservationsEnabled: true}
	selected2, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-14", state2)
	if routeErr != nil {
		t.Fatalf("second selection rejected: %+v", routeErr)
	}
	if selected2.ProviderID == selected1.ProviderID {
		t.Fatalf("second selection reused reserved provider %q", selected1.ProviderID)
	}

	_, routeErr = s.selectProviderExcluding(context.Background(), "rid-3", poolChatReq(""), http.Header{}, nil, "2026-09-14", &forwardState{slotReservationsEnabled: true})
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("third selection with all slots reserved: want 503 no_provider_available, got %+v", routeErr)
	}
}

func TestReservedSlotOverflowShedsWithoutQueueWait(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)
	s.slotQueueDeadline = 100 * time.Millisecond
	s.slotQueuePollInterval = time.Millisecond

	state1 := &forwardState{slotReservationsEnabled: true}
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state1); routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}

	state2 := &forwardState{slotReservationsEnabled: true}
	started := time.Now()
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-14", state2)
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("overflow selection with reserved slot: want 503 no_provider_available, got %+v", routeErr)
	}
	if state2.queueWait != 0 {
		t.Fatalf("overflow selection queueWait=%s, want 0", state2.queueWait)
	}
	if elapsed := time.Since(started); elapsed >= s.slotQueueDeadline/2 {
		t.Fatalf("overflow selection waited %s; local reservation overflow should shed without queueing", elapsed)
	}
}

func TestSelectProviderReleasesDirectSlotOnPreflightReject(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)
	s.preflightThreshold = 1
	s.preflightTimeout = time.Second
	s.preflight = func(_ pool.Provider, _ string, _ int, _ time.Duration) (PreflightResult, bool, error) {
		return PreflightResult{Accepted: false, Reason: "busy"}, true, nil
	}

	state := &forwardState{slotReservationsEnabled: true}
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state)
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "preflight_rejected" {
		t.Fatalf("preflight reject: want 503 preflight_rejected, got %+v", routeErr)
	}
	if state.queuedSlotProviderID != "" {
		t.Fatalf("reservation leaked after preflight rejection: %q", state.queuedSlotProviderID)
	}

	s.preflight = nil
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-14", &forwardState{slotReservationsEnabled: true})
	if routeErr != nil || got.ProviderID != provider.ProviderID {
		t.Fatalf("selection after preflight release provider=%q err=%+v, want %q nil", got.ProviderID, routeErr, provider.ProviderID)
	}
}

func TestWholesaleSelectionUsesBoundedSlotQueue(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	provider.SlotsFree = 0
	registry.Register(&provider, nil)
	s.slotQueueDeadline = 10 * time.Millisecond
	s.slotQueuePollInterval = time.Millisecond

	headers := http.Header{
		"Authorization":                    []string{"Bearer gateway-secret"},
		"X-MacProvider-Internal-Wholesale": []string{"1"},
	}
	state := &forwardState{slotReservationsEnabled: true}
	started := time.Now()
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), headers, nil, "2026-09-14", state)
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("wholesale queued selection: want 503 no_provider_available, got %+v", routeErr)
	}
	if state.queueWait <= 0 {
		t.Fatal("wholesale request bypassed the bounded slot queue")
	}
	if elapsed := time.Since(started); elapsed < s.slotQueueDeadline {
		t.Fatalf("wholesale selection returned before queue deadline: elapsed=%s deadline=%s", elapsed, s.slotQueueDeadline)
	}
}

func TestSlotQueueWaitsForBusyProviderCapacity(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-busy")
	provider.State = pool.StateBusy
	provider.SlotsFree = 0
	registry.Register(&provider, nil)
	s.slotQueueDeadline = 100 * time.Millisecond
	s.slotQueuePollInterval = time.Millisecond

	go func() {
		time.Sleep(10 * time.Millisecond)
		one := 1
		registry.ApplyStateUpdate(provider.ProviderID, provider.AssignedID, pool.StateUpdate{
			State:     pool.StateReady,
			SlotsFree: &one,
			At:        time.Now().UTC(),
		})
	}()

	state := &forwardState{slotReservationsEnabled: true}
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid-busy", poolChatReq(""), http.Header{}, nil, "2026-09-15", state)
	if routeErr != nil {
		t.Fatalf("busy queued selection rejected: %+v", routeErr)
	}
	if got.ProviderID != provider.ProviderID {
		t.Fatalf("busy queued provider = %q, want %q", got.ProviderID, provider.ProviderID)
	}
	if state.queueWait <= 0 {
		t.Fatal("busy provider selection bypassed the bounded slot queue")
	}
	if state.queuedSlotProviderID != provider.ProviderID {
		t.Fatalf("reservation provider %q, want %q", state.queuedSlotProviderID, provider.ProviderID)
	}
}

func TestReconcileForwardedSlotAvailablePublishesReadySlot(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-recovered")
	provider.State = pool.StateBusy
	provider.SlotsFree = 0
	registry.Register(&provider, nil)

	s.reconcileForwardedSlotAvailable(&forwardState{
		provider:                provider,
		slotReservationsEnabled: true,
		queuedSlotProviderID:    provider.ProviderID,
	})

	got, ok := registry.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("provider missing after capacity reconciliation")
	}
	if got.State != pool.StateReady || got.SlotsFree != 1 {
		t.Fatalf("provider capacity after reconciliation = state %q slots_free %d, want ready/1", got.State, got.SlotsFree)
	}
}
