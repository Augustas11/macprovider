package buyer

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// closedLoopCBProvider models one continuous-batching Mac behind the WS relay
// the way the provider CLI behaves (#1906):
//   - the Mac admits at most limit requests and answers error_queue_full
//     (chunks_sent 0) to anything beyond that;
//   - it sends inference_response_end before it drops the request from its
//     own active set, so a request re-issued the instant the coordinator sees
//     the end frame can land while the Mac still counts the finished one;
//   - it pushes a state_update on every occupancy change and a periodic
//     heartbeat on one ordered stream with a transit delay, both stamped at
//     coordinator receipt, so either can describe occupancy that has
//     already changed (including chats the Mac has not yet retired).
//
// The coordinator-side relay active map is modelled too: an entry is retired
// when the end frame arrives, before the buyer goroutine restores the slot.
type closedLoopCBProvider struct {
	registry   *pool.Registry
	providerID string
	assignedID string
	limit      int
	removeLag  time.Duration
	transit    time.Duration
	reports    chan closedLoopReport
	running    sync.WaitGroup

	mu          sync.Mutex
	active      int
	relayActive int
	peak        int
	queueFull   int
	backpress   int
	seq         int
}

type closedLoopReport struct {
	sentAt    time.Time
	heartbeat bool
	active    int
}

// publish queues an occupancy report on the provider's ordered WS stream.
func (p *closedLoopCBProvider) publish(active int, heartbeat bool) {
	p.reports <- closedLoopReport{sentAt: time.Now(), heartbeat: heartbeat, active: active}
}

// deliverReports applies reports in send order after the WS transit delay,
// stamped at coordinator receipt the way the WS reader stamps them.
func (p *closedLoopCBProvider) deliverReports(done chan<- struct{}) {
	defer close(done)
	for report := range p.reports {
		if wait := time.Until(report.sentAt.Add(p.transit)); wait > 0 {
			time.Sleep(wait)
		}
		free := p.limit - report.active
		if free < 0 {
			free = 0
		}
		state := pool.StateReady
		if free == 0 {
			state = pool.StateBusy
		}
		total := p.limit
		if report.heartbeat {
			p.registry.ApplyHeartbeat(p.providerID, p.assignedID, pool.HeartbeatUpdate{
				Status:           state,
				ModelID:          "model-a",
				MaxContextTokens: 20000,
				MaxConcurrency:   p.limit,
				SlotsFree:        free,
				SlotsTotal:       total,
				At:               time.Now().UTC(),
			})
			continue
		}
		p.registry.ApplyStateUpdate(p.providerID, p.assignedID, pool.StateUpdate{
			State:      state,
			SlotsFree:  &free,
			SlotsTotal: &total,
			At:         time.Now().UTC(),
		})
	}
}

func (p *closedLoopCBProvider) relay(ctx context.Context, _ pool.Provider, requestID string, _ []byte, _ bool) (*providerws.RelayStream, error) {
	chunks := make(chan providerws.InferenceResponseChunk, 1)
	done := make(chan providerws.InferenceResponseEnd, 1)
	errs := make(chan error, 1)
	stream := &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}

	p.mu.Lock()
	if p.relayActive >= p.limit {
		p.backpress++
		p.mu.Unlock()
		return nil, providerws.ErrRelayBackpressure
	}
	if p.active >= p.limit {
		p.queueFull++
		p.mu.Unlock()
		done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "error_queue_full", ChunksSent: 0, Error: "Provider request queue is full"}
		return stream, nil
	}
	p.relayActive++
	p.active++
	if p.active > p.peak {
		p.peak = p.active
	}
	p.seq++
	decode := time.Duration(3+p.seq%7) * time.Millisecond
	active := p.active
	p.mu.Unlock()
	p.publish(active, false)

	p.running.Add(1)
	go func() {
		defer p.running.Done()
		select {
		case <-ctx.Done():
		case <-time.After(decode):
		}
		chunks <- providerws.InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: requestID,
			Data:      `{"id":"chatcmpl-cl","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`,
		}
		p.mu.Lock()
		p.relayActive--
		p.mu.Unlock()
		done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
		// The Mac retires the request from its own active set only after
		// the end frame is on the wire.
		time.Sleep(p.removeLag)
		p.mu.Lock()
		p.active--
		active := p.active
		p.mu.Unlock()
		p.publish(active, false)
	}()
	return stream, nil
}

func (p *closedLoopCBProvider) heartbeatLoop(stop <-chan struct{}) {
	ticker := time.NewTicker(2 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			p.mu.Lock()
			active := p.active
			p.mu.Unlock()
			p.publish(active, true)
		}
	}
}

// TestClosedLoopNClientsAgainstNSlotsShedZero is the #1906 reproduction: N
// closed-loop buyers against one provider advertising N continuous-batching
// slots must never be shed. Each buyer re-issues the instant its previous
// request completes, so total demand never exceeds advertised capacity.
func TestClosedLoopNClientsAgainstNSlotsShedZero(t *testing.T) {
	for _, n := range []int{8, 16, 32} {
		n := n
		t.Run(fmt.Sprintf("slots_%d", n), func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			provider := pool.Provider{
				ProviderID:            "p-cb",
				AssignedID:            "s-cb",
				ModelID:               "model-a",
				State:                 pool.StateReady,
				Tier:                  pool.TierPinned,
				MaxContextTokens:      20000,
				MaxConcurrency:        n,
				SlotsTotal:            n,
				SlotsFree:             n,
				InferencePath:         pool.InferencePathWSTunneled,
				LastHeartbeatAt:       time.Now().UTC(),
				ConnectedAt:           time.Now().UTC(),
				TrustedPoolV1:         true,
				ThroughputTPSEstimate: 20,
			}
			registry.Register(&provider, nil)
			fake := &closedLoopCBProvider{
				registry:   registry,
				providerID: "p-cb",
				assignedID: "s-cb",
				limit:      n,
				removeLag:  time.Millisecond,
				transit:    2 * time.Millisecond,
				reports:    make(chan closedLoopReport, 4096),
			}
			reportsDone := make(chan struct{})
			go fake.deliverReports(reportsDone)
			server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), WithRelay(fake.relay, 5*time.Second))
			server.slotQueuePollInterval = time.Millisecond

			stop := make(chan struct{})
			hbDone := make(chan struct{})
			go func() {
				defer close(hbDone)
				fake.heartbeatLoop(stop)
			}()

			const rounds = 40
			body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`)
			var mu sync.Mutex
			codes := map[string]int{}
			var wg sync.WaitGroup
			for c := 0; c < n; c++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					for i := 0; i < rounds; i++ {
						req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
						rr := httptest.NewRecorder()
						server.Handler().ServeHTTP(rr, req)
						key := fmt.Sprintf("%d", rr.Code)
						if rr.Code != http.StatusOK {
							key += " " + rr.Body.String()
						}
						mu.Lock()
						codes[key]++
						mu.Unlock()
					}
				}()
			}
			wg.Wait()
			close(stop)
			<-hbDone
			fake.running.Wait()
			close(fake.reports)
			<-reportsDone

			fake.mu.Lock()
			peak, queueFull, backpress := fake.peak, fake.queueFull, fake.backpress
			fake.mu.Unlock()
			total := n * rounds
			if codes["200"] != total {
				t.Fatalf("N=%d closed-loop clients vs %d slots: %d/%d OK; outcomes=%v (provider queue_full=%d relay_backpressure=%d)", n, n, codes["200"], total, codes, queueFull, backpress)
			}
			if peak > n {
				t.Fatalf("provider peak active=%d, want <=%d", peak, n)
			}
		})
	}
}
