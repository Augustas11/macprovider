package buyer_test

import (
	"bytes"
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// SPEC-001-R012: a request whose inference_request frame exceeds the selected
// provider's WebSocket message limit is answered 413 request_too_large. It is
// not retried on another provider and the provider stays routable: the
// coordinator wrote nothing, so the provider session is intact.
func TestProviderFrameTooLargeAnswers413WithoutRetryOrProviderFault(t *testing.T) {
	for _, stream := range []bool{false, true} {
		registry := pool.NewRegistry(nil)
		registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
		registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
		var mu sync.Mutex
		var attempts []string
		server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
			buyer.WithRoutingConfig(config.RoutingConfig{MaxRetries: 2, RetryPerAttemptTimeoutS: 1, StickyTTLS: 1800, StickyMaxEntries: 10000}),
			buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
				mu.Lock()
				attempts = append(attempts, provider.ProviderID)
				mu.Unlock()
				return nil, providerws.ErrProviderFrameTooLarge
			}, 10*time.Second),
		)
		body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`)
		if stream {
			body = []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`)
		}
		rr := postChat(t, server, body, http.Header{"X-MacProvider-Retry": []string{"1"}})
		if rr.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("stream=%v status %d body %s, want 413", stream, rr.Code, rr.Body.String())
		}
		if !bytes.Contains(rr.Body.Bytes(), []byte(`"request_too_large"`)) {
			t.Fatalf("stream=%v body %s, want request_too_large", stream, rr.Body.String())
		}
		if n := bytes.Count(rr.Body.Bytes(), []byte(`"error"`)); n != 1 {
			t.Fatalf("stream=%v wrote %d error envelopes: %s", stream, n, rr.Body.String())
		}
		mu.Lock()
		got := append([]string(nil), attempts...)
		mu.Unlock()
		if len(got) != 1 {
			t.Fatalf("stream=%v attempts %v, want exactly one (no retry)", stream, got)
		}
		p, ok := registry.Resolve(got[0], map[string]string{"p1": "s1", "p2": "s2"}[got[0]])
		if !ok || p.State != pool.StateReady {
			t.Fatalf("stream=%v provider %s after refusal: ok=%v state=%v", stream, got[0], ok, p.State)
		}
	}
}
