package buyer_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// SPEC-051-R016: a global request never reaches a shard group head (even with
// its group available) or a member session; it is served by an ordinary
// provider, and a pin to a head is refused.
func TestGlobalRequestNeverRoutesToShardGroupSessions(t *testing.T) {
	registry := pool.NewRegistry(nil)
	add := func(id string, mutate func(*pool.Provider)) {
		p := &pool.Provider{
			ProviderID: id, AssignedID: "s-" + id, ModelID: "model-a", MaxContextTokens: 20000, MaxConcurrency: 4, SlotsFree: 4, SlotsTotal: 4,
			ThroughputTPSEstimate: 100, Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady,
			LastHeartbeatAt: time.Now().UTC(), ConnectedAt: time.Now().UTC(), BinaryVersion: "0.1.0",
		}
		mutate(p)
		registry.Register(p, nil)
	}
	add("head", func(p *pool.Provider) { p.ShardGroupHeadV1 = true; p.ThroughputTPSEstimate = 1000 })
	add("member", func(p *pool.Provider) { p.ShardMemberV1 = true; p.ThroughputTPSEstimate = 900 })
	add("plain", func(*pool.Provider) {})
	registry.SetShardGroupState("head", "s-head", true, 1, "pool/ijUnc-ZQf-LJeRvkhi-0iQ/model-a", []pool.ShardGroupMemberView{{ProviderID: "member"}})
	var calls []string
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			calls = append(calls, provider.ProviderID)
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Data: `{"id":"x","choices":[{"message":{"content":"ok"}}]}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}, nil
		}, time.Second))
	for i := 0; i < 3; i++ {
		rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
		if rr.Code != http.StatusOK || rr.Header().Get("X-MacProvider-Provider") != "plain" {
			t.Fatalf("status=%d provider=%q body=%s", rr.Code, rr.Header().Get("X-MacProvider-Provider"), rr.Body.String())
		}
	}
	for _, c := range calls {
		if c != "plain" {
			t.Fatalf("relayed to %q", c)
		}
	}
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{"X-Macprovider-Session": []string{"s-head"}})
	if rr.Code != http.StatusServiceUnavailable || !strings.Contains(rr.Body.String(), "shard_group_unavailable") {
		t.Fatalf("pinned head: status=%d body=%s", rr.Code, rr.Body.String())
	}
}
