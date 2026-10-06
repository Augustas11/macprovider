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
	select {
	case response := <-done:
		t.Fatalf("chat returned while the session was saturated: status=%d body=%s", response.Code, response.Body.String())
	case <-time.After(50 * time.Millisecond):
	}
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
	h.server.slotQueue.mu.Lock()
	reserved, queued := h.server.slotQueue.reserved[h.provider.ProviderID], len(h.server.slotQueue.queues[h.provider.ProviderID])
	h.server.slotQueue.mu.Unlock()
	if reserved != 0 || queued != 0 {
		t.Fatalf("slot lease leaked: reserved=%d queued=%d", reserved, queued)
	}
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
	h.server.slotQueue.mu.Lock()
	reserved, queued := h.server.slotQueue.reserved[h.provider.ProviderID], len(h.server.slotQueue.queues[h.provider.ProviderID])
	h.server.slotQueue.mu.Unlock()
	if reserved != 0 || queued != 0 {
		t.Fatalf("slot lease leaked: reserved=%d queued=%d", reserved, queued)
	}
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
	time.Sleep(30 * time.Millisecond)
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
