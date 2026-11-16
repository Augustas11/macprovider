package buyer_test

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// SPEC-036 FR-20 per entry: a verification request for a further member's
// model reaches that member with served_model_id; a one-member session gets
// none, as a legacy session.
func TestComputeIntegrityProbeNamesServedModelOnlyForMultiModel(t *testing.T) {
	for _, tc := range []struct {
		name, model, want string
		register          func(*pool.Registry)
	}{
		{name: "member", model: "model-b", want: "model-b", register: func(r *pool.Registry) { registerWarmWSProvider(r, "pw", 50) }},
		{name: "primary", model: "model-a", want: "model-a", register: func(r *pool.Registry) { registerWarmWSProvider(r, "pw", 50) }},
		{name: "one-member", model: "model-a", want: "", register: func(r *pool.Registry) {
			registerSingleOrLegacy(r, "pw", "", pool.InferencePathWSTunneled, true, false)
		}},
	} {
		registry := pool.NewRegistry(nil)
		tc.register(registry)
		var mu sync.Mutex
		var served []string
		relay := func(_ context.Context, provider pool.Provider, reqID string, _ []byte, _ bool) (*providerws.RelayStream, error) {
			mu.Lock()
			served = append(served, provider.ServedModelID)
			mu.Unlock()
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: reqID, Data: `{"id":"ok","choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: reqID, Status: "complete", ChunksSent: 1, Usage: json.RawMessage(`{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}`)}
			return &providerws.RelayStream{RequestID: reqID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}, nil
		}
		server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithGatewayServiceToken("operator-key"), buyer.WithRelay(relay, time.Second))
		body := []byte(`{"model":"` + tc.model + `","messages":[{"role":"user","content":"hi"}],"max_tokens":16,"temperature":0,"stream":false}`)
		if _, err := server.DispatchComputeIntegrityProbe(context.Background(), "pw", "pw-session", body, 16); err != nil {
			t.Fatalf("%s: probe: %v", tc.name, err)
		}
		mu.Lock()
		if len(served) != 1 || served[0] != tc.want {
			t.Fatalf("%s: relay served_model_id = %q, want %q", tc.name, served, tc.want)
		}
		mu.Unlock()
	}
}
