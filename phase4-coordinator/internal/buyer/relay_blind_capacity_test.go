package buyer

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

// A saturated session is a capacity condition. It is not a lost session, a
// stale posture, or an expired key. These tests pin the relay-blind chat
// prelude to the plaintext slot-queue semantics: wait on the pinned session,
// and fail as a retryable capacity outcome when no slot frees in time.

func (h *privacyHarness) setSlots(t *testing.T, state pool.State, free int) {
	t.Helper()
	total := 1
	if _, ok := h.server.pool.ApplyStateUpdate(h.provider.ProviderID, h.provider.AssignedID, pool.StateUpdate{State: state, SlotsFree: &free, SlotsTotal: &total, At: h.clock.Now()}); !ok {
		t.Fatal("state update rejected")
	}
}

// waitForSlotWaiter blocks until a chat is parked in the provider's slot
// queue, so a test exercises the wait path instead of racing it.
func (h *privacyHarness) waitForSlotWaiter(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !h.server.slotQueue.hasWaiters(h.provider.ProviderID) {
		if time.Now().After(deadline) {
			t.Fatal("chat never entered the slot queue")
		}
		time.Sleep(time.Millisecond)
	}
}

func (h *privacyHarness) assertNoSlotLease(t *testing.T) {
	t.Helper()
	h.server.slotQueue.mu.Lock()
	reserved, queued := h.server.slotQueue.reserved[h.provider.ProviderID], len(h.server.slotQueue.queues[h.provider.ProviderID])
	h.server.slotQueue.mu.Unlock()
	if reserved != 0 || queued != 0 {
		t.Fatalf("slot lease leaked: reserved=%d queued=%d", reserved, queued)
	}
}

func (h *privacyHarness) consumePrivacy(t *testing.T, requestID string) (relayblind.ReservationResponse, []byte, string) {
	t.Helper()
	reservation := h.reserve(t, true)
	raw := h.seal(t, reservation, requestID, h.privacyPrivate)
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	if response.Code != http.StatusOK {
		t.Fatalf("consume status=%d body=%s", response.Code, response.Body.String())
	}
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	return reservation, raw, consume.ExecutionAuthorization
}

func TestPrivacyChatOnSaturatedSessionWaitsForSlot(t *testing.T) {
	body := privacyTestResponseBody(t)
	var gotClass atomic.Value
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacySuccessRelay(body, &gotClass, &dispatches)})
	h.server.slotQueueDeadline = 5 * time.Second
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	_, raw, authorization := h.consumePrivacy(t, "privacy-saturated-wait")
	h.setSlots(t, pool.StateBusy, 0)

	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	}()
	h.waitForSlotWaiter(t)
	if dispatches.Load() != 0 {
		t.Fatalf("dispatched to a saturated session: dispatches=%d", dispatches.Load())
	}
	h.setSlots(t, pool.StateReady, 1)
	var response *httptest.ResponseRecorder
	select {
	case response = <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("chat did not dispatch after a slot freed")
	}
	if response.Code != http.StatusOK || response.Body.String() != body || response.Header().Get(privacyClassHeader) != relayblind.PrivacyClassV1 {
		t.Fatalf("chat status=%d class=%q body=%s", response.Code, response.Header().Get(privacyClassHeader), response.Body.String())
	}
	if gotClass.Load() != relayblind.PrivacyClassV1 || dispatches.Load() != 1 {
		t.Fatalf("class=%v dispatches=%d", gotClass.Load(), dispatches.Load())
	}
	h.assertNoSlotLease(t)
}

func TestPrivacyChatOnSaturatedSessionTimesOutAsCapacity(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, quota: 1, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueueDeadline = 40 * time.Millisecond
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	reservation, raw, authorization := h.consumePrivacy(t, "privacy-saturated-timeout")
	h.setSlots(t, pool.StateBusy, 0)

	response := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	text := response.Body.String()
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(text, `"code":"relay_blind_provider_unsupported"`) || !strings.Contains(text, `"retryable":true`) || strings.Contains(text, privacyClassStale) || response.Header().Get(privacyPostureVerifiedAtHeader) != "" {
		t.Fatalf("chat status=%d body=%s", response.Code, text)
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateRejected || row.TerminalCode != "relay_blind_provider_unsupported" {
		t.Fatalf("row=%#v err=%v", row, err)
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
	if !h.admission.TryReserveRequest(h.provider) {
		t.Fatal("a capacity wait consumed provider quota")
	}
	h.admission.RefundRequest(h.provider)
	h.assertNoSlotLease(t)
}

// A session that is gone while the request waits is still a lost session.
func TestPrivacyChatSessionLostWhileWaitingIsPostureStale(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueueDeadline = 5 * time.Second
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	_, raw, authorization := h.consumePrivacy(t, "privacy-saturated-lost")
	h.setSlots(t, pool.StateBusy, 0)

	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	}()
	h.waitForSlotWaiter(t)
	h.setSlots(t, pool.StateDraining, 0)
	var response *httptest.ResponseRecorder
	select {
	case response = <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("chat kept waiting on a lost session")
	}
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_posture_stale"`) || dispatches.Load() != 0 {
		t.Fatalf("chat status=%d dispatches=%d body=%s", response.Code, dispatches.Load(), response.Body.String())
	}
}

func TestRelayBlindChatOnSaturatedSessionIsCapacityNotKeyExpired(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{relayKey: true, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueueDeadline = 40 * time.Millisecond
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	reservation := h.reserve(t, false)
	raw := h.seal(t, reservation, "relay-saturated", h.relayPrivate)
	response := relayBlindRequest(t, h.server, http.MethodPost, "/v1/relay-blind/consume", raw, "")
	if response.Code != http.StatusOK {
		t.Fatalf("consume status=%d body=%s", response.Code, response.Body.String())
	}
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	h.setSlots(t, pool.StateBusy, 0)
	response = relayBlindRequest(t, h.server, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"relay_blind_provider_unsupported"`) || dispatches.Load() != 0 {
		t.Fatalf("chat status=%d dispatches=%d body=%s", response.Code, dispatches.Load(), response.Body.String())
	}
}

// A concurrent duplicate of a waiting authorization is a replay. It never
// takes a second slot-queue position.
func TestPrivacyChatConcurrentDuplicateIsReplayWithoutQueueing(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueueDeadline = 5 * time.Second
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	_, raw, authorization := h.consumePrivacy(t, "privacy-saturated-duplicate")
	h.setSlots(t, pool.StateBusy, 0)

	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	}()
	h.waitForSlotWaiter(t)
	duplicate := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	if duplicate.Code != http.StatusConflict || !strings.Contains(duplicate.Body.String(), `"code":"relay_blind_replay"`) {
		t.Fatalf("duplicate status=%d body=%s", duplicate.Code, duplicate.Body.String())
	}
	h.server.slotQueue.mu.Lock()
	queued := len(h.server.slotQueue.queues[h.provider.ProviderID])
	h.server.slotQueue.mu.Unlock()
	if queued != 1 {
		t.Fatalf("duplicate took a queue position: queued=%d", queued)
	}
	h.setSlots(t, pool.StateDraining, 0)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("first chat never returned")
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
}

// A buyer that disconnects while waiting still burns the consumed row, so
// the authorization cannot dispatch later.
func TestPrivacyChatCanceledWhileWaitingBurnsReservation(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueueDeadline = 5 * time.Second
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	reservation, raw, authorization := h.consumePrivacy(t, "privacy-saturated-cancel")
	h.setSlots(t, pool.StateBusy, 0)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, func(r *http.Request) {
			*r = *r.WithContext(ctx)
		})
	}()
	h.waitForSlotWaiter(t)
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("canceled chat kept waiting")
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateRejected {
		t.Fatalf("row=%#v err=%v", row, err)
	}
	h.setSlots(t, pool.StateReady, 1)
	retry := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	if retry.Code == http.StatusOK || dispatches.Load() != 0 {
		t.Fatalf("burned authorization dispatched: status=%d dispatches=%d body=%s", retry.Code, dispatches.Load(), retry.Body.String())
	}
	h.assertNoSlotLease(t)
}

// A posture that lapses during the wait is posture-stale, not capacity.
func TestPrivacyChatPostureLapsesWhileWaitingIsPostureStale(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueueDeadline = 200 * time.Millisecond
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	reservation, raw, authorization := h.consumePrivacy(t, "privacy-saturated-posture")
	h.setSlots(t, pool.StateBusy, 0)

	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	}()
	h.waitForSlotWaiter(t)
	h.authority.DropSession(h.provider.ProviderID, h.provider.AssignedID)
	var response *httptest.ResponseRecorder
	select {
	case response = <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("chat never returned")
	}
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_posture_stale"`) || dispatches.Load() != 0 {
		t.Fatalf("chat status=%d dispatches=%d body=%s", response.Code, dispatches.Load(), response.Body.String())
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateRejected || row.TerminalCode != privacyClassStale {
		t.Fatalf("row=%#v err=%v", row, err)
	}
}

// A slot that frees after the reservation expired is a retryable
// posture-stale outcome, not a non-retryable replay.
func TestPrivacyChatSlotAfterReservationExpiryIsPostureStale(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, ttl: 30, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueueDeadline = 5 * time.Second
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	reservation, raw, authorization := h.consumePrivacy(t, "privacy-saturated-expiry")
	h.setSlots(t, pool.StateBusy, 0)

	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	}()
	h.waitForSlotWaiter(t)
	h.clock.Advance(31 * time.Second)
	h.setSlots(t, pool.StateReady, 1)
	var response *httptest.ResponseRecorder
	select {
	case response = <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("chat never returned")
	}
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_posture_stale"`) || !strings.Contains(response.Body.String(), `"retryable":true`) || dispatches.Load() != 0 {
		t.Fatalf("chat status=%d dispatches=%d body=%s", response.Code, dispatches.Load(), response.Body.String())
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateRejected || row.TerminalCode != privacyClassStale {
		t.Fatalf("row=%#v err=%v", row, err)
	}
}

// A session that stays saturated until the reservation expires is a
// retryable posture-stale outcome, not capacity.
func TestPrivacyChatSaturatedThroughReservationExpiryIsPostureStale(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, ttl: 30, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueueDeadline = 200 * time.Millisecond
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	reservation, raw, authorization := h.consumePrivacy(t, "privacy-saturated-through-expiry")
	h.setSlots(t, pool.StateBusy, 0)

	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	}()
	h.waitForSlotWaiter(t)
	h.clock.Advance(31 * time.Second)
	var response *httptest.ResponseRecorder
	select {
	case response = <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("chat never returned")
	}
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_posture_stale"`) || dispatches.Load() != 0 {
		t.Fatalf("chat status=%d dispatches=%d body=%s", response.Code, dispatches.Load(), response.Body.String())
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateRejected {
		t.Fatalf("row=%#v err=%v", row, err)
	}
}

// Pinned waiters wait in their own lane, capped per provider at half the
// plaintext lane cap, so they can neither fill nor be crowded out of the
// queue plaintext routing shares (SPEC-049-R029).
func TestRelayBlindSlotWaitersAreCappedPerProvider(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueue = newSlotQueue(4)
	h.server.slotQueueDeadline = 5 * time.Second
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	_, rawA, authA := h.consumePrivacy(t, "privacy-saturated-cap-a")
	_, rawB, authB := h.consumePrivacy(t, "privacy-saturated-cap-b")
	reservationC, rawC, authC := h.consumePrivacy(t, "privacy-saturated-cap-c")
	h.setSlots(t, pool.StateBusy, 0)
	// The plaintext lane is full before any pinned waiter arrives.
	for range 4 {
		if _, ok := h.server.slotQueue.enter(h.provider.ProviderID); !ok {
			t.Fatal("plaintext lane rejected a waiter below its cap")
		}
	}

	done := make(chan *httptest.ResponseRecorder, 2)
	go func() { done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", rawA, authA, nil) }()
	go func() { done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", rawB, authB, nil) }()
	deadline := time.Now().Add(3 * time.Second)
	for {
		h.server.slotQueue.mu.Lock()
		pinned := h.server.slotQueue.laneLenLocked(h.provider.ProviderID, slotWaiterPinned)
		h.server.slotQueue.mu.Unlock()
		if pinned == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("pinned waiters=%d, want 2 behind a full plaintext lane", pinned)
		}
		time.Sleep(time.Millisecond)
	}
	third := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", rawC, authC, nil)
	if third.Code != http.StatusServiceUnavailable || !strings.Contains(third.Body.String(), `"code":"relay_blind_provider_unsupported"`) {
		t.Fatalf("third waiter status=%d body=%s", third.Code, third.Body.String())
	}
	row, err := h.store.LookupReservation(context.Background(), reservationC.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateRejected {
		t.Fatalf("row=%#v err=%v", row, err)
	}
	h.setSlots(t, pool.StateDraining, 0)
	for range 2 {
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Fatal("pinned chat never returned")
		}
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
}

// A one-entry slot queue still gives the pinned lane one position.
func TestRelayBlindQueuesWhenQueueHasOnePosition(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	h.server.slotQueue = newSlotQueue(1)
	h.server.slotQueueDeadline = 5 * time.Second
	h.server.slotQueuePollInterval = 5 * time.Millisecond
	_, raw, authorization := h.consumePrivacy(t, "privacy-saturated-one-slot")
	h.setSlots(t, pool.StateBusy, 0)
	if _, ok := h.server.slotQueue.enter(h.provider.ProviderID); !ok {
		t.Fatal("plaintext lane rejected its one waiter")
	}
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, authorization, nil)
	}()
	deadline := time.Now().Add(3 * time.Second)
	for {
		h.server.slotQueue.mu.Lock()
		pinned := h.server.slotQueue.laneLenLocked(h.provider.ProviderID, slotWaiterPinned)
		h.server.slotQueue.mu.Unlock()
		if pinned == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("pinned waiter never entered a one-position queue")
		}
		time.Sleep(time.Millisecond)
	}
	h.setSlots(t, pool.StateDraining, 0)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("pinned chat never returned")
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
	h.server.slotQueue.mu.Lock()
	pinned := h.server.slotQueue.laneLenLocked(h.provider.ProviderID, slotWaiterPinned)
	h.server.slotQueue.mu.Unlock()
	if pinned != 0 {
		t.Fatalf("pinned waiter leaked: %d", pinned)
	}
}
