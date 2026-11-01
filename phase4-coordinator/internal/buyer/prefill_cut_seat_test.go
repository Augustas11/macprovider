package buyer

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// prefillCutProvider models a two-seat Mac for the turn-0 prefill cut
// (#2192): one long chat keeps decoding while another is cut before its first
// token. The Mac sends no end frame for the cut chat and retires it only after
// cancelLag, then reports its free seat on a ready heartbeat. Until then a
// third chat is refused with error_queue_full.
type prefillCutProvider struct {
	registry  *pool.Registry
	cancelLag time.Duration

	releaseLong chan struct{}
	cutStarted  chan struct{}
	cutDone     chan providerws.InferenceResponseEnd

	mu         sync.Mutex
	active     int
	queueFull  int
	nextServed int
	longDone   bool
	retires    sync.WaitGroup
}

const prefillCutSeats = 2

func (p *prefillCutProvider) heartbeat(active int) {
	free := prefillCutSeats - active
	state := pool.StateReady
	if free <= 0 {
		free = 0
		state = pool.StateBusy
	}
	p.registry.ApplyHeartbeat("p-cut", "s-cut", pool.HeartbeatUpdate{
		Status:           state,
		ModelID:          "model-a",
		MaxContextTokens: 20000,
		MaxConcurrency:   prefillCutSeats,
		SlotsFree:        free,
		SlotsTotal:       prefillCutSeats,
		At:               time.Now().UTC(),
	})
}

func (p *prefillCutProvider) relay(ctx context.Context, _ pool.Provider, requestID string, body []byte, _ bool) (*providerws.RelayStream, error) {
	chunks := make(chan providerws.InferenceResponseChunk, 1)
	done := make(chan providerws.InferenceResponseEnd, 1)
	errs := make(chan error, 1)
	stream := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}
	complete := func() {
		chunks <- providerws.InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: requestID,
			Data:      `{"id":"chatcmpl-cut","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`,
		}
		done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	switch {
	case bytes.Contains(body, []byte("long-turn")):
		p.active++
		go func() {
			<-p.releaseLong
			p.mu.Lock()
			p.longDone = true
			p.mu.Unlock()
			complete()
			p.mu.Lock()
			p.active--
			active := p.active
			p.mu.Unlock()
			p.heartbeat(active)
		}()
	case bytes.Contains(body, []byte("cut-turn")):
		p.active++
		p.cutDone = done
		close(p.cutStarted)
		p.retires.Add(1)
		go func() {
			defer p.retires.Done()
			// Cancelled before its first token: no end frame follows.
			<-ctx.Done()
			time.Sleep(p.cancelLag)
			p.mu.Lock()
			p.active--
			active := p.active
			p.mu.Unlock()
			p.heartbeat(active)
		}()
	default:
		if p.active >= prefillCutSeats {
			p.queueFull++
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "error_queue_full", ChunksSent: 0, Error: "Provider request queue is full"}
			return stream, nil
		}
		p.nextServed++
		complete()
	}
	return stream, nil
}

func newPrefillCutFixture(t *testing.T, cancelLag time.Duration) (*Server, *pool.Registry, *prefillCutProvider) {
	t.Helper()
	registry := pool.NewRegistry(nil)
	provider := pool.Provider{
		ProviderID:            "p-cut",
		AssignedID:            "s-cut",
		ModelID:               "model-a",
		State:                 pool.StateReady,
		Tier:                  pool.TierPinned,
		MaxContextTokens:      20000,
		MaxConcurrency:        prefillCutSeats,
		SlotsTotal:            prefillCutSeats,
		SlotsFree:             prefillCutSeats,
		InferencePath:         pool.InferencePathWSTunneled,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		TrustedPoolV1:         true,
		ThroughputTPSEstimate: 20,
	}
	registry.Register(&provider, nil)
	fake := &prefillCutProvider{
		registry:    registry,
		cancelLag:   cancelLag,
		releaseLong: make(chan struct{}),
		cutStarted:  make(chan struct{}),
	}
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), WithRelay(fake.relay, 30*time.Second))
	server.slotQueuePollInterval = time.Millisecond
	server.slotQueueDeadline = 2 * time.Second
	return server, registry, fake
}

func prefillCutRequest(ctx context.Context, server *Server, content string, stream bool) *httptest.ResponseRecorder {
	streamField := "false"
	if stream {
		streamField = "true"
	}
	body := `{"model":"model-a","messages":[{"role":"user","content":"` + content + `"}],"stream":` + streamField + `}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body)).WithContext(ctx)
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}

// startLongAndCut puts one long chat in flight, then cuts a second chat before
// its first token the way the gateway's first_token deadline does: the buyer
// context ends and the provider never sends an end frame.
func startLongAndCut(t *testing.T, server *Server, registry *pool.Registry, fake *prefillCutProvider) (longResult <-chan *httptest.ResponseRecorder) {
	t.Helper()
	longCh := make(chan *httptest.ResponseRecorder, 1)
	go func() { longCh <- prefillCutRequest(context.Background(), server, "long-turn", false) }()
	deadline := time.Now().Add(5 * time.Second)
	for registry.ForwardedInFlight("p-cut", "s-cut") != 1 {
		if time.Now().After(deadline) {
			t.Fatal("long chat never took its seat")
		}
		time.Sleep(time.Millisecond)
	}
	cutCtx, cut := context.WithCancel(context.Background())
	cutCh := make(chan *httptest.ResponseRecorder, 1)
	go func() { cutCh <- prefillCutRequest(cutCtx, server, "cut-turn", true) }()
	select {
	case <-fake.cutStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("cut chat never dispatched")
	}
	cut()
	select {
	case <-cutCh:
	case <-time.After(5 * time.Second):
		t.Fatal("handler of the cut chat did not return")
	}
	return longCh
}

func assertOneSeatHeldByLongChat(t *testing.T, registry *pool.Registry, when string) {
	t.Helper()
	if got := registry.ForwardedInFlight("p-cut", "s-cut"); got != 1 {
		t.Fatalf("%s: forwarded in flight = %d, want 1 (only the long chat)", when, got)
	}
	got, _ := registry.Resolve("p-cut", "s-cut")
	if got.SlotsFree != prefillCutSeats-1 {
		t.Fatalf("%s: slots_free = %d, want %d", when, got.SlotsFree, prefillCutSeats-1)
	}
}

// TestPrefillCutBeforeFirstTokenReleasesSeatOnce: a chat cut before its first
// token, with no provider end frame, returns its seat exactly once when its
// handler returns, so the next chat routes at once. A late end frame for the
// cut chat changes nothing.
func TestPrefillCutBeforeFirstTokenReleasesSeatOnce(t *testing.T) {
	server, registry, fake := newPrefillCutFixture(t, 0)
	longCh := startLongAndCut(t, server, registry, fake)
	fake.retires.Wait()
	assertOneSeatHeldByLongChat(t, registry, "after the cut")

	fake.cutDone <- providerws.InferenceResponseEnd{Type: "inference_response_end", Status: "cancelled", ChunksSent: 0}
	assertOneSeatHeldByLongChat(t, registry, "after a late end frame for the cut chat")

	started := time.Now()
	rr := prefillCutRequest(context.Background(), server, "next-turn", false)
	if rr.Code != http.StatusOK {
		t.Fatalf("next chat after the cut: status=%d body=%s, want 200", rr.Code, rr.Body.String())
	}
	if waited := time.Since(started); waited > time.Second {
		t.Fatalf("next chat waited %s for a seat that was free", waited)
	}
	assertOneSeatHeldByLongChat(t, registry, "after the next chat")

	close(fake.releaseLong)
	if long := <-longCh; long.Code != http.StatusOK {
		t.Fatalf("long chat: status=%d, want 200", long.Code)
	}
	if got := registry.ForwardedInFlight("p-cut", "s-cut"); got != 0 {
		t.Fatalf("after quiescence: forwarded in flight = %d, want 0", got)
	}
	if got, _ := registry.Resolve("p-cut", "s-cut"); got.SlotsFree != prefillCutSeats || !got.RoutingEligible() {
		t.Fatalf("after quiescence: slots_free=%d routable=%v, want %d/true", got.SlotsFree, got.RoutingEligible(), prefillCutSeats)
	}
}

// TestPrefillCutQueueFullClearsOnReadyReportWhileChatsInFlight is the replay
// 429 window (#2192): the coordinator returns the cut chat's seat before the
// Mac has retired it, so the next chat is refused with error_queue_full. The
// Mac then reports the seat free while the long chat is still decoding. That
// report must reopen the seat; waiting for the long chat to finish shed every
// retry in between with 429.
func TestPrefillCutQueueFullClearsOnReadyReportWhileChatsInFlight(t *testing.T) {
	server, registry, fake := newPrefillCutFixture(t, 100*time.Millisecond)
	longCh := startLongAndCut(t, server, registry, fake)
	defer func() {
		select {
		case <-fake.releaseLong:
		default:
			close(fake.releaseLong)
		}
		<-longCh
		fake.retires.Wait()
	}()

	rr := prefillCutRequest(context.Background(), server, "next-turn", false)
	if rr.Code != http.StatusOK {
		t.Fatalf("next chat after the cut: status=%d body=%s, want 200 once the Mac reports the seat free", rr.Code, rr.Body.String())
	}
	fake.mu.Lock()
	queueFull, served, longDone := fake.queueFull, fake.nextServed, fake.longDone
	fake.mu.Unlock()
	if queueFull == 0 {
		t.Fatal("the next chat never met the Mac's error_queue_full; the scenario did not run")
	}
	if served != 1 || longDone {
		t.Fatalf("next chat served=%d long chat done=%v, want served while the long chat still decodes", served, longDone)
	}
	assertOneSeatHeldByLongChat(t, registry, "after the next chat")
}
