package ws_test

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

func stressNetworkOffer(t *testing.T, store providerws.ModelAdmissionStore, seed providerws.ModelAdmissionEvent) providerws.ModelAdmissionEvent {
	t.Helper()
	seed.CandidateID = "byom_" + strings.Repeat("b", 52)
	seed.RequestID = "stress-offer"
	seed.Nonce = "stress-offer"
	seed.PayloadDigestSHA256 = strings.Repeat("b", 64)
	seed.CoordinatorEventID = ""
	seed.ExpectedCurrentEventID = ""
	seed.ArtifactAdmissionEvidence = nil
	e, _, err := store.AppendModelAdmissionOffer(context.Background(), seed)
	if err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"sandbox_probe_only", "network_admitted_unsettled"} {
		e.ExpectedCurrentEventID = e.CoordinatorEventID
		e.CoordinatorEventID = ""
		e.State = state
		e.RequestID = "stress-" + state
		e.Nonce = e.RequestID
		e.PayloadDigestSHA256 = strings.Repeat("c", 64)
		e, err = store.AppendModelAdmissionDecision(context.Background(), e)
		if err != nil {
			t.Fatal(err)
		}
	}
	return e
}

// All mutation lanes contend with the production WS->registry->buyer->billing->
// Tier2 pin chain. The signed fixture supplies authority, never a success guard.
func TestPromotionLockOrderAndAvailabilityAllOwners(t *testing.T) {
	for _, kind := range []string{"memory", "sqlite"} {
		t.Run(kind, func(t *testing.T) {
			for round := 0; round < 4; round++ {
				t.Run(fmt.Sprintf("round_%d", round), func(t *testing.T) {
					var registry *pool.Registry
					_, p, seed, feeds, rewards, billingStore, referenceCfg := ownerPrimaryAdmissionFixture(t, &registry)
					store := providerws.NewAdmissionStoreForTest(t, kind)
					owner, p, baseline := providerws.NewFullAdmissionOwnerForTest(t, registry, p, store, seed)
					server := buyer.NewServer(registry, zerolog.Nop(), time.Now(), buyer.WithAutotuneFeeds(feeds), buyer.WithBilling(billingStore, rewards), buyer.WithBillingSnapshotID(1), buyer.WithModelAdmissionStore(store), buyer.WithModelAdmissionTransport(owner.ModelAdmissionSessionAvailable, owner.CloseModelAdmissionTransport))
					if err := owner.SetModelAdmissionAuthority(server.ResolveModelAdmissionAuthority, server.PrepareModelAdmissionAuthority); err != nil {
						t.Fatal(err)
					}
					providerws.PromoteFullAdmissionForTest(owner, p, baseline)
					latest, _, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, baseline.CandidateID)
					if err != nil || latest.State != "settlement_capable" {
						t.Fatalf("baseline actual promotion: %+v %v", latest, err)
					}
					candidate := stressNetworkOffer(t, store, seed)
					_, guard, err := providerws.PrepareFullAdmissionForTest(owner, p, candidate)
					if err != nil {
						t.Fatal(err)
					}

					// A distinct provider supplies ordinary registry readers during contention.
					readConn, readPeer := net.Pipe()
					defer readConn.Close()
					defer readPeer.Close()
					other := pool.Provider{ProviderID: "ordinary-reader", AssignedID: "ordinary-session", ModelID: "ordinary-model", State: pool.StateReady}
					registry.Register(&other, readConn)
					registrationConn, registrationPeer := net.Pipe()
					defer registrationConn.Close()
					defer registrationPeer.Close()
					liveConn, err := registry.Conn(p.ProviderID, p.AssignedID)
					if err != nil {
						t.Fatal(err)
					}
					var callbackCount atomic.Int32
					providerws.InstallCountingCanaryBuyerServingForTest(owner, func() { callbackCount.Add(1) })

					release, err := guard()
					if err != nil || release == nil {
						t.Fatalf("initial full pin: %v", err)
					}
					heldAt := time.Now()
					var releaseOnce sync.Once
					unpin := func() { releaseOnce.Do(release) }
					defer unpin()
					started := make(chan string, 10)
					done := make(chan string, 10)
					failures := make(chan error, 10)
					start := make(chan struct{})
					launch := func(name string, mutate func() error) {
						go func() {
							<-start
							started <- name
							err := mutate()
							if err != nil {
								failures <- fmt.Errorf("%s: %w", name, err)
							}
							done <- name
						}()
					}
					launch("registration", func() error {
						copy := other
						copy.ProviderID = "stress-registration"
						copy.AssignedID = "stress-registration-session"
						if _, ok := registry.Register(&copy, registrationConn); !ok {
							return fmt.Errorf("registration refused")
						}
						return nil
					})
					launch("heartbeat", func() error {
						_, _, heartbeatOK := registry.ApplyHeartbeat(p.ProviderID, p.AssignedID, pool.HeartbeatUpdate{Status: pool.StateReady, ModelID: p.ModelID, ModelHash: p.ModelHash, ModelHashPresent: true, ModelHashAlgorithm: p.ModelHashAlgorithm, ModelHashAlgorithmPresent: true, MaxContextTokens: 100000, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, At: time.Now()})
						if !heartbeatOK {
							return fmt.Errorf("heartbeat lost current session")
						}
						return nil
					})
					launch("receipt", func() error {
						copy := p
						copy.ReceiptPubkey = append([]byte(nil), p.ReceiptPubkey...)
						copy.ReceiptPubkey[0] ^= 1
						if _, ok := registry.Register(&copy, liveConn); !ok {
							return fmt.Errorf("receipt publication refused")
						}
						if _, ok := registry.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady}); !ok {
							return fmt.Errorf("receipt state update lost current session")
						}
						return nil
					})
					launch("canary", func() error {
						if result := registry.RecordCanaryResult(p.ProviderID, p.AssignedID, false, time.Now(), 1); !result.Current {
							return fmt.Errorf("canary lost current session")
						}
						return nil
					})
					launch("feed", func() error { server.SetAutotuneFeeds(feeds); return nil })
					launch("billing", func() error { server.SetBillingConfig(rewards, 1, 1); return nil })
					launch("settlement", func() error {
						cfg := config.Default().Settlement
						cfg.VerifiedModelSettlementMode = "observe"
						billingStore.SetSettlementConfig(cfg)
						return nil
					})
					capturedCatalog := tier2.Default()
					launch("tier2-inplace", func() error { return capturedCatalog.ConfigureStrict(referenceCfg, zerolog.Nop()) })
					launch("tier2-default", func() error {
						_, err := tier2.ConfigureDefaultStrict(referenceCfg, zerolog.Nop(), func(*tier2.Catalog) error { return nil })
						return err
					})
					launch("close-delete", func() error {
						if err := owner.CloseModelAdmissionTransport(p.ProviderID, p.AssignedID, "owner stress"); err != nil {
							return err
						}
						providerws.DeleteAdmissionSessionForTest(owner, p)
						return nil
					})
					close(start)
					deadline := time.After(5 * time.Second)
					for i := 0; i < 10; i++ {
						select {
						case <-started:
						case <-deadline:
							t.Fatal("mutation lane did not start")
						}
					}
					// Unlike a start notification, TryRLock failure under our known RLock proves
					// an actual registry writer is pending and catches recursive reader locking.
					until := time.Now().Add(5 * time.Second)
					for {
						_, _, unlock, ok := registry.TryPinModelAdmissionProvider(p.ProviderID, p.AssignedID)
						if !ok {
							break
						}
						unlock()
						if time.Now().After(until) {
							t.Fatal("no actual registry writer contention")
						}
						runtime.Gosched()
					}
					for i := 0; i < 16; i++ {
						began := time.Now()
						unlock, pinErr := guard()
						if unlock != nil {
							unlock()
							t.Fatal("contended full pin returned release")
						}
						if pinErr == nil {
							t.Fatal("contended full pin accepted")
						}
						if time.Since(began) > 250*time.Millisecond {
							t.Fatal("nonblocking full guard exceeded 250ms")
						}
					}
					select {
					case name := <-done:
						t.Fatalf("%s crossed held complete pin", name)
					default:
					}
					var reads atomic.Int32
					readersDone := make(chan struct{})
					go func() {
						defer close(readersDone)
						for i := 0; i < 32; i++ {
							if _, ok := registry.Resolve(other.ProviderID, other.AssignedID); ok {
								reads.Add(1)
							}
						}
					}()
					promotionsDone := make(chan struct{})
					go func() {
						defer close(promotionsDone)
						for i := 0; i < 8; i++ {
							providerws.PromoteFullAdmissionForTest(owner, p, candidate)
						}
					}()
					routeResult := make(chan error, 1)
					go func() {
						for i := 0; i < 4; i++ {
							req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"stress"}],"max_tokens":16}`, p.ModelID)))
							req.Header.Set("Content-Type", "application/json")
							w := httptest.NewRecorder()
							server.Handler().ServeHTTP(w, req)
							if w.Code != http.StatusServiceUnavailable || (!strings.Contains(w.Body.String(), `"code":"byom_non_settlement_unavailable"`) && !strings.Contains(w.Body.String(), `"code":"no_provider_available"`)) || strings.Contains(w.Body.String(), `"choices"`) || w.Header().Get("X-MacProvider-Receipt") != "" {
								routeResult <- fmt.Errorf("invalid authority routed: %d %s", w.Code, w.Body.String())
								return
							}
						}
						routeResult <- nil
					}()

					heldFor := time.Since(heldAt)
					unpin()
					deadline = time.After(5 * time.Second)
					completed := map[string]bool{}
					for i := 0; i < 10; i++ {
						select {
						case name := <-done:
							if completed[name] {
								t.Fatal("duplicate mutation completion")
							}
							completed[name] = true
						case <-deadline:
							t.Fatalf("owner writer stalled: completed=%v", completed)
						}
					}
					select {
					case err := <-failures:
						t.Fatal(err)
					default:
					}
					for _, finished := range []chan struct{}{readersDone, promotionsDone} {
						select {
						case <-finished:
						case <-time.After(5 * time.Second):
							t.Fatal("reader/promotion progress stalled")
						}
					}
					select {
					case err := <-routeResult:
						if err != nil {
							t.Fatal(err)
						}
					case <-time.After(5 * time.Second):
						t.Fatal("concurrent router progress stalled")
					}

					if reads.Load() != 32 {
						t.Fatalf("ordinary reads=%d", reads.Load())
					}
					if callbackCount.Load() == 0 {
						t.Fatal("canary did not enter actual buyer-serving callback")
					}
					if unlock, pinErr := guard(); pinErr == nil || unlock != nil {
						if unlock != nil {
							unlock()
						}
						t.Fatal("completed mutations accepted stale authority")
					}
					latest, _, err = store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, candidate.CandidateID)
					if err != nil || latest.State != "network_admitted_unsettled" {
						t.Fatalf("mutation produced false positive: %+v %v", latest, err)
					}
					if owner.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
						t.Fatal("deleted session remains admission available")
					}

					t.Logf("full_pin_held=%s writers=%d ordinary_reads=%d callback_calls=%d contended_pins=16 actual_promotion_attempts=8 denied_routes=4", heldFor, len(completed), reads.Load(), callbackCount.Load())
				})
			}
		})
	}
}
