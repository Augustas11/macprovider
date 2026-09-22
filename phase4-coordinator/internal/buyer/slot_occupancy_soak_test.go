package buyer

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestFourWideHTTPSoak100AdmitsWithStaleBusyHeartbeat(t *testing.T) {
	var inflight atomic.Int32
	var peak atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := inflight.Add(1)
		defer inflight.Add(-1)
		for {
			cur := peak.Load()
			if n <= cur || peak.CompareAndSwap(cur, n) {
				break
			}
		}
		time.Sleep(40 * time.Millisecond)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chatcmpl-soak","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	provider := pool.Provider{
		ProviderID:            "p-studio",
		AssignedID:            "s-studio",
		ModelID:               "model-a",
		State:                 pool.StateReady,
		Tier:                  pool.TierPinned,
		MaxContextTokens:      20000,
		MaxConcurrency:        4,
		SlotsTotal:            4,
		SlotsFree:             4,
		EndpointURL:           upstream.URL,
		InferencePath:         pool.InferencePathHTTPForwarding,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		TrustedPoolV1:         true,
		ThroughputTPSEstimate: 20,
	}
	registry.Register(&provider, nil)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	server.slotQueueDeadline = 20 * time.Millisecond
	server.slotQueuePollInterval = time.Millisecond

	const waves = 25
	const width = 4
	const total = waves * width
	okN := 0
	shedN := 0
	otherN := 0
	var mu sync.Mutex
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`)

	for wave := 0; wave < waves; wave++ {
		var wg sync.WaitGroup
		codes := make([]int, width)
		wg.Add(width)
		for i := 0; i < width; i++ {
			i := i
			go func() {
				defer wg.Done()
				req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
				rr := httptest.NewRecorder()
				server.Handler().ServeHTTP(rr, req)
				codes[i] = rr.Code
			}()
		}
		wg.Wait()
		// Delayed in-wave "I'm full" snapshot, stamped at receive time the
		// way production WS does after RestoreForwardedSlot.
		registry.ApplyHeartbeat("p-studio", "s-studio", pool.HeartbeatUpdate{
			Status:           pool.StateBusy,
			ModelID:          "model-a",
			MaxContextTokens: 20000,
			MaxConcurrency:   4,
			SlotsFree:        0,
			SlotsTotal:       4,
			At:               time.Now().UTC(),
		})
		for _, code := range codes {
			mu.Lock()
			switch code {
			case http.StatusOK:
				okN++
			case http.StatusServiceUnavailable, http.StatusTooManyRequests:
				shedN++
			default:
				otherN++
			}
			mu.Unlock()
		}
	}

	if peak.Load() > 4 {
		t.Fatalf("upstream peak inflight=%d, want <=4", peak.Load())
	}
	if otherN != 0 {
		t.Fatalf("non-capacity failures=%d, want 0", otherN)
	}
	if okN < 95 {
		t.Fatalf("admitted %d/%d (shed %d), want >=95", okN, total, shedN)
	}
}
