package buyer_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// TestConversationKeyWithheldFromIncompatibleProviderBinaries pins #1998:
// provider CLIs 1.8.238-1.8.240 fail every keyed serial request with
// incompatibleCapacity, so the coordinator serves them keyless while older and
// newer binaries keep receiving the auto-prefix conversation_key.
func TestConversationKeyWithheldFromIncompatibleProviderBinaries(t *testing.T) {
	cases := []struct {
		binary  string
		wantKey bool
	}{
		{"1.8.232", true},
		{"1.8.237", true},
		{"1.8.238", false},
		{"1.8.239", false},
		{"1.8.240", false},
		{"v1.8.240", false},
		{"1.8.241", true},
		{"1.9.0", true},
		{"", true},
		{"1.8.240-dev", true},
	}
	for _, tc := range cases {
		t.Run(tc.binary, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			registry.Register(&pool.Provider{
				ProviderID: "p1", AssignedID: "s1", Hostname: "p1.local",
				ModelID: "model-a", ModelParamsB: 7, RAMGB: 16,
				MaxContextTokens: 20000, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1,
				ThroughputTPSEstimate: 20, Tier: pool.TierProvisional,
				InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady,
				LastHeartbeatAt: time.Now().UTC(), ConnectedAt: time.Now().UTC(),
				BinaryVersion: tc.binary,
			}, nil)

			var gotKey string
			var gotCacheOnly bool
			calls := 0
			server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
				buyer.WithGatewayServiceToken("operator-key"),
				buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
					calls++
					gotKey = providerws.ConversationKeyFromContext(ctx)
					gotCacheOnly = providerws.ConversationCacheOnlyFromContext(ctx)
					chunks := make(chan providerws.InferenceResponseChunk, 1)
					done := make(chan providerws.InferenceResponseEnd, 1)
					chunks <- providerws.InferenceResponseChunk{
						Type: "inference_response_chunk", RequestID: requestID, Seq: 0,
						Data: `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`,
					}
					done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
					return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}, nil
				}, time.Second),
			)
			resp := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
				"Authorization":                     []string{"Bearer operator-key"},
				"X-MacProvider-Internal-Conv-Cache": []string{"conv:auto.prefix.k"},
				"X-MacProvider-Account":             []string{"acct_1998"},
			})
			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			if calls != 1 {
				t.Fatalf("relay calls=%d, want 1", calls)
			}
			if tc.wantKey {
				if gotKey != "conv:auto.prefix.k" || !gotCacheOnly {
					t.Fatalf("key=%q cacheOnly=%v, want forwarded cache-only key", gotKey, gotCacheOnly)
				}
				return
			}
			if gotKey != "" || gotCacheOnly {
				t.Fatalf("key=%q cacheOnly=%v, want no key for binary %s", gotKey, gotCacheOnly, tc.binary)
			}
		})
	}
}
