package buyer

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestRoutingConfigAppliesSlotQueueConfig(t *testing.T) {
	s, _, _ := poolIsolationServer(t)

	WithRoutingConfig(config.RoutingConfig{
		SlotQueueMaxPendingPerProvider: 7,
		SlotQueueDeadlineS:             10,
		SlotQueuePollIntervalMS:        50,
	})(s)

	if s.slotQueue == nil || s.slotQueue.maxPending != 7 {
		t.Fatalf("slot queue maxPending = %v, want 7", s.slotQueue)
	}
	if s.slotQueueDeadline != 10*time.Second {
		t.Fatalf("slotQueueDeadline = %s, want 10s", s.slotQueueDeadline)
	}
	if s.slotQueuePollInterval != 50*time.Millisecond {
		t.Fatalf("slotQueuePollInterval = %s, want 50ms", s.slotQueuePollInterval)
	}
}

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

func TestWholesaleReservedSlotOverflowUsesBoundedQueue(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)
	s.slotQueueDeadline = 100 * time.Millisecond
	s.slotQueuePollInterval = time.Millisecond

	state1 := &forwardState{slotReservationsEnabled: true}
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state1); routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}
	if state1.queuedSlotProviderID != provider.ProviderID {
		t.Fatalf("first selection reservation provider %q, want %q", state1.queuedSlotProviderID, provider.ProviderID)
	}
	if !s.slotQueue.blocksProvider(provider.ProviderID, provider.SlotsFree) {
		t.Fatal("first reservation did not block the provider's advertised slot")
	}
	go func() {
		time.Sleep(10 * time.Millisecond)
		s.releaseQueuedSlotReservation(state1)
	}()

	headers := make(http.Header)
	headers.Set("Authorization", "Bearer gateway-secret")
	headers.Set("X-MacProvider-Internal-Wholesale", "1")
	if !s.hasTrustedWholesaleRoutingHeader(headers) {
		t.Fatal("test headers were not classified as trusted wholesale")
	}
	state2 := &forwardState{slotReservationsEnabled: true}
	started := time.Now()
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), headers, nil, "2026-09-14", state2)
	if routeErr != nil {
		t.Fatalf("wholesale overflow selection rejected after %s queueWait=%s: %+v", time.Since(started), state2.queueWait, routeErr)
	}
	if got.ProviderID != provider.ProviderID {
		t.Fatalf("wholesale queued provider %q, want %q", got.ProviderID, provider.ProviderID)
	}
	if state2.queueWait <= 0 {
		t.Fatal("wholesale reserved-slot overflow bypassed the bounded slot queue")
	}
	if state2.queuedSlotProviderID != provider.ProviderID {
		t.Fatalf("reservation provider %q, want %q", state2.queuedSlotProviderID, provider.ProviderID)
	}
	if elapsed := time.Since(started); elapsed >= s.slotQueueDeadline {
		t.Fatalf("wholesale overflow waited %s; should claim slot before deadline %s", elapsed, s.slotQueueDeadline)
	}
	s.releaseQueuedSlotReservation(state2)
}

func TestDefaultSlotQueueDeadlineCoversOneThirtyBDecode(t *testing.T) {
	s, _, _ := poolIsolationServer(t)
	if s.slotQueueDeadline != 10*time.Second {
		t.Fatalf("default slotQueueDeadline = %s, want 10s", s.slotQueueDeadline)
	}
}

func TestFourSlotProviderAdmitsFourReservations(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-four")
	provider.MaxConcurrency = 4
	provider.SlotsTotal = 4
	provider.SlotsFree = 4
	registry.Register(&provider, nil)

	ids := []string{"rid-four-1", "rid-four-2", "rid-four-3", "rid-four-4"}
	states := make([]*forwardState, 4)
	for i := 0; i < 4; i++ {
		states[i] = &forwardState{slotReservationsEnabled: true}
		got, routeErr := s.selectProviderExcluding(context.Background(), ids[i], poolChatReq(""), http.Header{}, nil, "2026-09-14", states[i])
		if routeErr != nil {
			t.Fatalf("selection %d rejected: %+v", i+1, routeErr)
		}
		if got.ProviderID != provider.ProviderID {
			t.Fatalf("selection %d provider %q, want %q", i+1, got.ProviderID, provider.ProviderID)
		}
		if states[i].queuedSlotProviderID != provider.ProviderID {
			t.Fatalf("selection %d reservation %q, want %q", i+1, states[i].queuedSlotProviderID, provider.ProviderID)
		}
	}
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-four-5", poolChatReq(""), http.Header{}, nil, "2026-09-14", &forwardState{slotReservationsEnabled: true})
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("fifth selection with four slots reserved: want 503 no_provider_available, got %+v", routeErr)
	}
}

func TestAcceptedRequestReleasesReservationAllowsSiblingSelect(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)

	state := &forwardState{slotReservationsEnabled: true}
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-accept-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state); routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}
	s.noteProviderAcceptedRequest(state)
	if state.queuedSlotProviderID != "" {
		t.Fatalf("reservation still held after provider accept: %q", state.queuedSlotProviderID)
	}
	got, ok := registry.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("provider missing after accept")
	}
	if got.SlotsFree != 0 || got.State != pool.StateBusy {
		t.Fatalf("after accept occupancy = state %q slots_free %d, want busy/0", got.State, got.SlotsFree)
	}
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-accept-2", poolChatReq(""), http.Header{}, nil, "2026-09-14", &forwardState{slotReservationsEnabled: true})
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("sibling after accept: want 503 no_provider_available, got provider=%v err=%+v", routeErr == nil, routeErr)
	}
}

func TestReconcileAfterAcceptRestoresOccupancy(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)

	state := &forwardState{slotReservationsEnabled: true}
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-restore-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state); routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}
	s.noteProviderAcceptedRequest(state)
	s.reconcileForwardedSlotAvailable(state)
	if state.slotConsumedOnAccept {
		t.Fatal("consumed flag still set after reconcile")
	}
	got, ok := registry.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("provider missing after reconcile")
	}
	if got.SlotsFree != 1 || got.State != pool.StateReady {
		t.Fatalf("after reconcile occupancy = state %q slots_free %d, want ready/1", got.State, got.SlotsFree)
	}
	selected, routeErr := s.selectProviderExcluding(context.Background(), "rid-restore-2", poolChatReq(""), http.Header{}, nil, "2026-09-14", &forwardState{slotReservationsEnabled: true})
	if routeErr != nil || selected.ProviderID != provider.ProviderID {
		t.Fatalf("sibling after reconcile provider=%q err=%+v, want %q", selected.ProviderID, routeErr, provider.ProviderID)
	}
}

func TestSpoofedWholesaleHeaderRejectedBeforeReservationOverflowQueue(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)
	s.slotQueueDeadline = 100 * time.Millisecond
	s.slotQueuePollInterval = time.Millisecond

	state1 := &forwardState{slotReservationsEnabled: true}
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state1); routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}
	defer s.releaseQueuedSlotReservation(state1)

	headers := make(http.Header)
	headers.Set("X-MacProvider-Internal-Wholesale", "1")
	if s.hasTrustedWholesaleRoutingHeader(headers) {
		t.Fatal("spoofed wholesale header was classified as trusted")
	}
	state2 := &forwardState{slotReservationsEnabled: true}
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-spoof", poolChatReq(""), headers, nil, "2026-09-14", state2)
	if routeErr == nil || routeErr.status != http.StatusBadRequest || routeErr.code != "invalid_request" {
		t.Fatalf("spoofed wholesale header: want 400 invalid_request, got %+v", routeErr)
	}
	if state2.queueWait != 0 {
		t.Fatalf("spoofed wholesale header queueWait=%s, want 0", state2.queueWait)
	}
}

func TestPublicRequestDoesNotFollowWholesaleReservationOverflowWaiter(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)
	s.slotQueueDeadline = 100 * time.Millisecond
	s.slotQueuePollInterval = time.Millisecond

	state1 := &forwardState{slotReservationsEnabled: true}
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state1); routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}

	headers := make(http.Header)
	headers.Set("Authorization", "Bearer gateway-secret")
	headers.Set("X-MacProvider-Internal-Wholesale", "1")
	wholesaleStarted := make(chan struct{})
	wholesaleDone := make(chan *routeError, 1)
	go func() {
		state := &forwardState{slotReservationsEnabled: true}
		close(wholesaleStarted)
		_, routeErr := s.selectProviderExcluding(context.Background(), "rid-wholesale", poolChatReq(""), headers, nil, "2026-09-14", state)
		wholesaleDone <- routeErr
	}()
	<-wholesaleStarted

	deadline := time.Now().Add(25 * time.Millisecond)
	for time.Now().Before(deadline) && !s.slotQueue.hasWaiters(provider.ProviderID) {
		time.Sleep(time.Millisecond)
	}
	if !s.slotQueue.hasWaiters(provider.ProviderID) {
		t.Fatal("wholesale overflow waiter did not enter the queue")
	}

	statePublic := &forwardState{slotReservationsEnabled: true}
	started := time.Now()
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-public", poolChatReq(""), http.Header{}, nil, "2026-09-14", statePublic)
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("public request behind wholesale overflow waiter: want 503 no_provider_available, got %+v", routeErr)
	}
	if statePublic.queueWait != 0 {
		t.Fatalf("public request queueWait=%s, want 0", statePublic.queueWait)
	}
	if elapsed := time.Since(started); elapsed >= s.slotQueueDeadline/2 {
		t.Fatalf("public request waited %s behind wholesale overflow waiter", elapsed)
	}

	s.releaseQueuedSlotReservation(state1)
	if routeErr := <-wholesaleDone; routeErr != nil {
		t.Fatalf("wholesale waiter rejected after public shed: %+v", routeErr)
	}
}

func TestQueuedProviderClaimsReleasedLocalReservation(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)
	s.slotQueueDeadline = 100 * time.Millisecond
	s.slotQueuePollInterval = time.Millisecond

	state1 := &forwardState{slotReservationsEnabled: true}
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state1); routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}

	go func() {
		time.Sleep(10 * time.Millisecond)
		s.releaseQueuedSlotReservation(state1)
	}()

	state2 := &forwardState{slotReservationsEnabled: true}
	got, routeErr, queued := s.trySelectQueuedProvider(context.Background(), "rid-2", "model-a", []pool.Provider{provider}, http.Header{}, nil, "2026-09-14", 1, state2, slotWaiterStandard)
	if !queued {
		t.Fatal("trySelectQueuedProvider did not enter the queue")
	}
	if routeErr != nil {
		t.Fatalf("queued provider rejected after queueWait=%s: %+v", state2.queueWait, routeErr)
	}
	if got.ProviderID != provider.ProviderID {
		t.Fatalf("queued provider %q, want %q", got.ProviderID, provider.ProviderID)
	}
	if state2.queueWait <= 0 {
		t.Fatal("queued provider did not wait for the local reservation")
	}
	s.releaseQueuedSlotReservation(state2)
}

func TestWholesaleReservationOverflowFallbackPreservesSplitQueuedCandidates(t *testing.T) {
	s, _, _ := poolIsolationServer(t)
	queued := poolProvider("p-queued")
	raced := poolProvider("p-raced")
	dupe := queued
	dupe.AssignedID = queued.AssignedID
	busy := poolProvider("p-busy")
	busy.State = pool.StateBusy
	busy.SlotsFree = 0

	got := s.wholesaleReservationOverflowQueueCandidates([]pool.Provider{queued}, []pool.Provider{raced, dupe, busy})
	if len(got) != 2 {
		t.Fatalf("fallback candidates len=%d want 2: %+v", len(got), got)
	}
	if got[0].ProviderID != queued.ProviderID || got[1].ProviderID != raced.ProviderID {
		t.Fatalf("fallback candidates = [%q %q], want [%q %q]", got[0].ProviderID, got[1].ProviderID, queued.ProviderID, raced.ProviderID)
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

	headers := make(http.Header)
	headers.Set("Authorization", "Bearer gateway-secret")
	headers.Set("X-MacProvider-Internal-Wholesale", "1")
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

func TestReconcileForwardedSlotAvailablePublishesGlobalReadySlot(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-global-recovered")
	provider.State = pool.StateBusy
	provider.SlotsFree = 0
	registry.Register(&provider, nil)

	s.reconcileForwardedSlotAvailable(&forwardState{
		provider: provider,
	})

	got, ok := registry.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("provider missing after global capacity reconciliation")
	}
	if got.State != pool.StateReady || got.SlotsFree != 1 {
		t.Fatalf("provider capacity after global reconciliation = state %q slots_free %d, want ready/1", got.State, got.SlotsFree)
	}
}

func TestForwardWithFailoverCommittedStreamPublishesReadySlot(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-committed")
	provider.State = pool.StateBusy
	provider.SlotsFree = 0
	registry.Register(&provider, nil)

	startedAt := time.Unix(1716768000, 0)
	state := &forwardState{
		provider:                provider,
		slotReservationsEnabled: true,
		queuedSlotProviderID:    provider.ProviderID,
		faultedRoutes:           map[string]struct{}{},
	}
	req, _ := http.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := &billingRecorder{
		server:    s,
		state:     state,
		req:       req,
		startedAt: startedAt,
		requestID: "rid-committed",
	}
	committedRendered := false

	s.forwardWithFailover(nil, req, poolChatReq(""), "rid-committed", "rid-committed", startedAt, state, map[string]struct{}{}, rec, transportCallbacks{
		dispatch: func(http.ResponseWriter, *http.Request, chatRequest, string, string, time.Time, *forwardState, *billingRecorder) (dispatchedAttempt, bool) {
			return dispatchedAttempt{tr: transportResult{
				committed: true,
				status:    http.StatusOK,
				attempt:   requestLogAttempt{Status: http.StatusOK},
			}}, true
		},
		renderCommitted: func(http.ResponseWriter, *http.Request, dispatchedAttempt, *forwardState) bool {
			committedRendered = true
			return true
		},
	})

	if !committedRendered {
		t.Fatal("committed stream was not rendered")
	}
	if state.queuedSlotProviderID != "" {
		t.Fatalf("slot reservation leaked after committed stream: %q", state.queuedSlotProviderID)
	}
	if s.slotQueue.blocksProvider(provider.ProviderID, 1) {
		t.Fatal("slot queue still blocks provider after committed stream")
	}
	got, ok := registry.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("provider missing after committed stream")
	}
	if got.State != pool.StateReady || got.SlotsFree != 1 {
		t.Fatalf("provider capacity after committed stream = state %q slots_free %d, want ready/1", got.State, got.SlotsFree)
	}
}

func fourSlotStudio(t *testing.T) (*Server, *pool.Registry, pool.Provider) {
	t.Helper()
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-studio")
	provider.MaxConcurrency = 4
	provider.SlotsTotal = 4
	provider.SlotsFree = 4
	registry.Register(&provider, nil)
	return s, registry, provider
}

func macReportsSlots(t *testing.T, registry *pool.Registry, provider pool.Provider, slotsFree int) {
	t.Helper()
	macReportsSlotsAt(t, registry, provider, slotsFree, time.Now().UTC())
}

func macReportsSlotsAt(t *testing.T, registry *pool.Registry, provider pool.Provider, slotsFree int, at time.Time) {
	t.Helper()
	free := slotsFree
	state := pool.StateReady
	if free <= 0 {
		state = pool.StateBusy
	}
	if _, ok := registry.ApplyStateUpdate(provider.ProviderID, provider.AssignedID, pool.StateUpdate{
		State:     state,
		SlotsFree: &free,
		At:        at,
	}); !ok {
		t.Fatal("macReportsSlots: provider missing")
	}
}

func TestFourWideAdmitThenMacHeartbeatFillsAllSeats(t *testing.T) {
	s, registry, provider := fourSlotStudio(t)
	inFlight := 0
	states := make([]*forwardState, 4)
	for i := 0; i < 4; i++ {
		states[i] = &forwardState{slotReservationsEnabled: true}
		if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-wave1-"+string(rune('a'+i)), poolChatReq(""), http.Header{}, nil, "2026-09-22", states[i]); routeErr != nil {
			t.Fatalf("wave1 seat %d rejected: %+v", i+1, routeErr)
		}
		s.noteProviderAcceptedRequest(states[i])
		inFlight++
		macReportsSlots(t, registry, provider, 4-inFlight)
	}
	got, ok := registry.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("provider missing after wave1 accept")
	}
	if got.SlotsFree != 0 {
		t.Fatalf("after 4 accepts occupancy slots_free=%d, want 0", got.SlotsFree)
	}
	for i := range states {
		s.reconcileForwardedSlotAvailable(states[i])
		inFlight--
		macReportsSlots(t, registry, provider, 4-inFlight)
	}
	got, ok = registry.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("provider missing after wave1 restore")
	}
	if got.SlotsFree != 4 || got.State != pool.StateReady {
		t.Fatalf("after wave1 complete occupancy = state %q slots_free %d, want ready/4", got.State, got.SlotsFree)
	}
	admitted := 0
	for i := 0; i < 4; i++ {
		state := &forwardState{slotReservationsEnabled: true}
		if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-wave2-"+string(rune('a'+i)), poolChatReq(""), http.Header{}, nil, "2026-09-22", state); routeErr != nil {
			t.Fatalf("wave2 seat %d rejected: %+v", i+1, routeErr)
		}
		admitted++
		s.noteProviderAcceptedRequest(state)
		s.reconcileForwardedSlotAvailable(state)
	}
	if admitted != 4 {
		t.Fatalf("wave2 admitted %d, want 4", admitted)
	}
}

func TestFourWideStaleBusyHeartbeatMustNotBlockNextWave(t *testing.T) {
	s, registry, provider := fourSlotStudio(t)
	states := make([]*forwardState, 4)
	for i := 0; i < 4; i++ {
		states[i] = &forwardState{slotReservationsEnabled: true}
		if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-stale-"+string(rune('a'+i)), poolChatReq(""), http.Header{}, nil, "2026-09-22", states[i]); routeErr != nil {
			t.Fatalf("seat %d rejected: %+v", i+1, routeErr)
		}
		s.noteProviderAcceptedRequest(states[i])
		macReportsSlots(t, registry, provider, 3-i)
	}
	for i := range states {
		s.reconcileForwardedSlotAvailable(states[i])
	}
	s.slotQueueDeadline = time.Millisecond
	s.slotQueuePollInterval = time.Millisecond
	// Late copy of the in-wave busy snapshot, stamped at receive time the
	// way production WS does. Must not beat the restore write.
	macReportsSlots(t, registry, provider, 0)
	admitted := 0
	for i := 0; i < 4; i++ {
		state := &forwardState{slotReservationsEnabled: true}
		if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-next-"+string(rune('a'+i)), poolChatReq(""), http.Header{}, nil, "2026-09-22", state); routeErr != nil {
			continue
		}
		admitted++
		s.releaseQueuedSlotReservation(state)
		if state.slotConsumedOnAccept {
			s.restoreConsumedForwardedSlot(state)
		}
	}
	if admitted != 4 {
		t.Fatalf("next wave after stale busy heartbeat admitted %d, want 4", admitted)
	}
}

func TestFourWideThermalBusyAfterSettleWindowBlocksNextWave(t *testing.T) {
	s, registry, provider := fourSlotStudio(t)
	states := make([]*forwardState, 4)
	for i := 0; i < 4; i++ {
		states[i] = &forwardState{slotReservationsEnabled: true}
		if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-thermal-"+string(rune('a'+i)), poolChatReq(""), http.Header{}, nil, "2026-09-22", states[i]); routeErr != nil {
			t.Fatalf("seat %d rejected: %+v", i+1, routeErr)
		}
		s.noteProviderAcceptedRequest(states[i])
	}
	for i := range states {
		s.reconcileForwardedSlotAvailable(states[i])
	}
	s.slotQueueDeadline = time.Millisecond
	s.slotQueuePollInterval = time.Millisecond
	macReportsSlotsAt(t, registry, provider, 0, time.Now().UTC().Add(pool.OccupancySettleWindow+time.Second))
	admitted := 0
	for i := 0; i < 4; i++ {
		state := &forwardState{slotReservationsEnabled: true}
		if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-blocked-"+string(rune('a'+i)), poolChatReq(""), http.Header{}, nil, "2026-09-22", state); routeErr != nil {
			continue
		}
		admitted++
		s.releaseQueuedSlotReservation(state)
		if state.slotConsumedOnAccept {
			s.restoreConsumedForwardedSlot(state)
		}
	}
	if admitted != 0 {
		t.Fatalf("next wave after thermal busy admitted %d, want 0", admitted)
	}
}
