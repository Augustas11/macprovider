package ws_test

import (
	"context"
	"fmt"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Every leaf uses independently signed loader bytes, the actual buyer preparer,
// real WS probe/authentication, full coordinator owner pins, and durable history.
func TestAdmissionHTTPBuyerOwnerMutationMatrix(t *testing.T) {
	for _, mutation := range []string{"snapshot", "prompt", "cache", "completion", "share", "multiplier", "default", "enforcement", "signed-feeds", "tier2-default", "tier2-inplace", "replacement", "registry-removal", "session-removal", "closing", "not-ready", "pending-key", "receipt-key", "benchmark", "ceiling", "stale", "sandboxed", "sanction", "resolver"} {
		t.Run(mutation, func(t *testing.T) {
			providerws.RunAdmissionOwnerHTTPMatrixForTest(t, func(t *testing.T, owner *providerws.Server, registry *pool.Registry, wire pool.Provider) (pool.Provider, func(), func(), func() bool) {
				_, p, _, feeds, rewards, store, _ := ownerPrimaryAdmissionFixture(t)
				p.ProviderID = wire.ProviderID
				p.AssignedID = wire.AssignedID
				conn, err := registry.Conn(wire.ProviderID, wire.AssignedID)
				if err != nil {
					t.Fatal(err)
				}
				registry.RemoveIfSession(wire.ProviderID, wire.AssignedID)
				if _, ok := registry.Register(&p, conn); !ok {
					t.Fatal("signed fixture registration refused")
				}
				registry.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: time.Now()})
				p, _ = registry.Resolve(p.ProviderID, p.AssignedID)
				server := buyer.NewServer(registry, zerolog.Nop(), time.Now(), buyer.WithAutotuneFeeds(feeds), buyer.WithBilling(store, rewards), buyer.WithBillingSnapshotID(1), buyer.WithModelAdmissionStore(providerws.AdmissionStoreForServerForTest(owner)), buyer.WithModelAdmissionTransport(owner.ModelAdmissionSessionAvailable, owner.CloseModelAdmissionTransport))
				var prepared providerws.PreparedModelAdmissionAuthority
				if err := owner.SetModelAdmissionAuthority(server.ResolveModelAdmissionAuthority, func(ctx context.Context, p pool.Provider, e providerws.ModelAdmissionEvent) (providerws.PreparedModelAdmissionAuthority, error) {
					a, err := server.PrepareModelAdmissionAuthority(ctx, p, e)
					prepared = a
					return a, err
				}); err != nil {
					t.Fatal(err)
				}
				replacement := feeds
				if mutation == "signed-feeds" {
					replacement = ownerReplacementFeeds(t, feeds)
				}
				mutate := func() {
					switch mutation {
					case "snapshot":
						server.SetBillingConfig(rewards, 0, 1)
					case "prompt", "cache", "completion", "share", "multiplier", "default":
						changed := rewards
						changed.RateCard = map[string]config.RateCardEntry{"test-model": rewards.RateCard["test-model"]}
						rate := changed.RateCard["test-model"]
						switch mutation {
						case "prompt":
							rate.PromptCreditsPerMtok++
						case "cache":
							rate.SetPromptCacheHitCreditsPerMtok(999)
						case "completion":
							rate.CompletionCreditsPerMtok++
						case "share":
							changed.ProviderShare = 0.8
						case "multiplier":
							changed.GlobalMultiplier = 1
						case "default":
							delete(changed.RateCard, "test-model")
							changed.RateCard["default"] = rate
						}
						if mutation != "default" {
							changed.RateCard["test-model"] = rate
						}
						server.SetBillingConfig(changed, 1, 1)
					case "enforcement":
						ownerSetSettlementModeForTest(store, "observe")
					case "signed-feeds":
						server.SetAutotuneFeeds(replacement)
					case "tier2-default":
						if _, err := tier2.ConfigureDefaultStrict(config.Tier2Config{}, zerolog.Nop(), func(*tier2.Catalog) error { return nil }); err != nil {
							t.Error(err)
						}
					case "tier2-inplace":
						if err := tier2.Default().ConfigureStrict(config.Tier2Config{}, zerolog.Nop()); err != nil {
							t.Error(err)
						}
					}
				}
				pending := func() bool {
					release, err := prepared.TryPin()
					if err != nil {
						return true
					}
					release()
					return false
				}
				switch mutation {
				case "replacement", "registry-removal", "session-removal", "closing", "not-ready", "pending-key", "receipt-key", "benchmark", "ceiling", "stale", "sandboxed", "sanction", "resolver":
					mutate, pending = providerws.WSAdmissionMutationForTest(t, owner, p, mutation)
				}
				route := func() {
					req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"after mutation"}],"max_tokens":16}`, p.ModelID)))
					req.Header.Set("Content-Type", "application/json")
					response := httptest.NewRecorder()
					server.Handler().ServeHTTP(response, req)
					if response.Code != http.StatusServiceUnavailable || (!strings.Contains(response.Body.String(), `"byom_non_settlement_unavailable"`) && !strings.Contains(response.Body.String(), `"no_provider_available"`)) {
						t.Fatalf("completed mutation route result: %d %s", response.Code, response.Body.String())
					}

				}
				return p, mutate, route, pending
			})
		})
	}
}
