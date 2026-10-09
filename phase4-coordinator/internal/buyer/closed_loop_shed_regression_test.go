package buyer

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// TestQueueFullAfterInFlightDrainedRequeuesUntilReadyReport pins the #1906
// closed-loop shed: chat A finishes and the coordinator restores its seat, so
// nothing is in flight. The re-issued chat B lands before the Mac retired A
// and is refused with error_queue_full. B was accepted against a seat the Mac
// had not yet confirmed, so it must wait in the slot queue for the Mac's next
// ready report instead of being excluded and shed.
func TestQueueFullAfterInFlightDrainedRequeuesUntilReadyReport(t *testing.T) {
	registry := pool.NewRegistry(nil)
	provider := pool.Provider{
		ProviderID:            "p-cb",
		AssignedID:            "s-cb",
		ModelID:               "model-a",
		State:                 pool.StateReady,
		Tier:                  pool.TierPinned,
		MaxContextTokens:      20000,
		MaxConcurrency:        2,
		SlotsTotal:            2,
		SlotsFree:             2,
		InferencePath:         pool.InferencePathWSTunneled,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		TrustedPoolV1:         true,
		ThroughputTPSEstimate: 20,
	}
	registry.Register(&provider, nil)

	var mu sync.Mutex
	calls := 0
	var reports sync.WaitGroup
	relay := func(ctx context.Context, _ pool.Provider, requestID string, _ []byte, _ bool) (*providerws.RelayStream, error) {
		chunks := make(chan providerws.InferenceResponseChunk, 1)
		done := make(chan providerws.InferenceResponseEnd, 1)
		errs := make(chan error, 1)
		stream := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}
		mu.Lock()
		calls++
		call := calls
		mu.Unlock()
		if call == 2 {
			if got := registry.ForwardedInFlight("p-cb", "s-cb"); got != 0 {
				t.Errorf("forwarded in flight at the refusal = %d, want 0", got)
			}
			// The Mac retires A and reports ready only after it refused B.
			reports.Add(1)
			go func() {
				defer reports.Done()
				time.Sleep(20 * time.Millisecond)
				registry.ApplyHeartbeat("p-cb", "s-cb", pool.HeartbeatUpdate{
					Status:           pool.StateReady,
					ModelID:          "model-a",
					MaxContextTokens: 20000,
					MaxConcurrency:   2,
					SlotsFree:        2,
					SlotsTotal:       2,
					At:               time.Now().UTC(),
				})
			}()
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "error_queue_full", ChunksSent: 0, Error: "Provider request queue is full"}
			return stream, nil
		}
		chunks <- providerws.InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: requestID,
			Data:      `{"id":"chatcmpl-rq","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`,
		}
		done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
		return stream, nil
	}
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), WithRelay(relay, 5*time.Second))
	server.slotQueuePollInterval = time.Millisecond

	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`)
	for i, label := range []string{"A", "B"} {
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("request %s (#%d): status=%d body=%s, want 200", label, i+1, rr.Code, rr.Body.String())
		}
	}
	reports.Wait()
	mu.Lock()
	defer mu.Unlock()
	if calls != 3 {
		t.Fatalf("relay calls = %d, want 3 (A, refused B, requeued B)", calls)
	}
}

// TestReservationMissBelowAdvertisedCapacityWaitsForSeat pins the other #1906
// closed-loop shed: slots_free sits below SlotsTotal minus coordinator demand
// because the Mac still counts chats the coordinator saw finish. A public
// request that misses a reservation while coordinator-owned demand is below
// SlotsTotal waits for the seat instead of shedding as overflow. Genuine
// overflow (demand at SlotsTotal) still sheds at once:
// TestReservedSlotOverflowShedsWithoutQueueWait.
func TestReservationMissBelowAdvertisedCapacityWaitsForSeat(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	provider.MaxConcurrency = 4
	provider.SlotsTotal = 4
	provider.SlotsFree = 1
	registry.Register(&provider, nil)
	s.slotQueueDeadline = 5 * time.Second
	s.slotQueuePollInterval = time.Millisecond

	state1 := &forwardState{slotReservationsEnabled: true}
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state1); routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}

	type result struct {
		provider pool.Provider
		err      *routeError
		state    *forwardState
	}
	second := make(chan result, 1)
	go func() {
		state := &forwardState{slotReservationsEnabled: true}
		got, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-14", state)
		second <- result{provider: got, err: routeErr, state: state}
	}()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && !s.slotQueue.hasWaiters(provider.ProviderID) {
		select {
		case r := <-second:
			t.Fatalf("second selection returned without waiting: provider=%q err=%+v", r.provider.ProviderID, r.err)
		default:
		}
		time.Sleep(time.Millisecond)
	}
	if !s.slotQueue.hasWaiters(provider.ProviderID) {
		t.Fatal("second selection neither waited nor returned")
	}
	// The Mac retires its finished chats and reports the seats free.
	free := 4
	registry.ApplyStateUpdate(provider.ProviderID, provider.AssignedID, pool.StateUpdate{State: pool.StateReady, SlotsFree: &free})

	r := <-second
	if r.err != nil || r.provider.ProviderID != provider.ProviderID {
		t.Fatalf("second selection: provider=%q err=%+v, want %q nil", r.provider.ProviderID, r.err, provider.ProviderID)
	}
	if r.state.queueWait <= 0 {
		t.Fatalf("second selection queueWait=%s, want it to have waited in the slot queue", r.state.queueWait)
	}
	s.releaseQueuedSlotReservation(state1)
	s.releaseQueuedSlotReservation(r.state)
}
