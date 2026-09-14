package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// This fixture supplies only catalog evidence; the real WS/pool/store owners
// still decide transport, exclusion, event-CAS and commit serialization.
func setFixtureModelAdmissionAuthority(s *Server, resolve ModelAdmissionAuthorityResolver) {
	_ = s.SetModelAdmissionAuthority(resolve, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
		resolved, err := resolve(ctx, p, e)
		return PreparedModelAdmissionAuthority{Event: resolved, TryPin: func() (func(), error) { return func() {}, nil }}, err
	})
}

var admissionFixtureNow = time.Now()

func admissionFixtureResolver(_ context.Context, p pool.Provider, e ModelAdmissionEvent) (ModelAdmissionEvent, error) {
	e.CatalogModelKey = "fixture-model"
	e.CatalogID = "independent-tier2"
	e.CatalogBodyDigest = strings.Repeat("4", 64)
	e.CatalogSignatureKeyID = "tier2-key"
	e.CatalogSignaturePubkeyFingerprint = "ed25519-sha256:" + strings.Repeat("5", 64)
	e.ExpectedCatalogModelHash = p.ModelHash
	e.ExpectedCatalogModelHashAlgorithm = p.ModelHashAlgorithm
	e.ArtifactAdmissionEvidence = probeArtifactEvidence(p, admissionFixtureNow)
	return e, nil
}

func admissionGuardFixture(t *testing.T, store ModelAdmissionStore) (*Server, pool.Provider, *providerSession, net.Conn, ModelAdmissionEvent) {
	t.Helper()
	a, b := net.Pipe()
	t.Cleanup(func() { a.Close(); b.Close() })
	now := time.Now()
	p := pool.Provider{ProviderID: "guard-provider", AssignedID: "guard-session", ModelID: "mlx-community/Fixture", ModelHash: strings.Repeat("3", 64), ExpectedModelHash: strings.Repeat("3", 64), ModelHashAlgorithm: modelidentity.SnapshotManifestV1, State: pool.StateReady, InferencePath: pool.InferencePathWSTunneled, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, ReceiptPubkey: make([]byte, ed25519.PublicKeySize), LastActivityAt: now, LastHeartbeatAt: now}
	r := pool.NewRegistry(nil)
	r.Register(&p, a)
	r.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: now})
	p, _ = r.Resolve(p.ProviderID, p.AssignedID)
	s := NewServer(modelAdmissionProbeAuthConfig(), r, zerolog.Nop(), WithModelAdmissionStore(store))
	ps := newProviderSession(p.ProviderID, p.AssignedID, a, 8)
	s.storeProviderSession(sessionKey(p.ProviderID, p.AssignedID), ps)
	setFixtureModelAdmissionAuthority(s, admissionFixtureResolver)
	e := modelAdmissionProbeOffer("guard", "guard")
	e.ProviderID = p.ProviderID
	e.ServedModelRef = p.ModelID
	e.RuntimeSource = "mlx_cache"
	e.OfferIdentitySHA256 = strings.Repeat("9", 64)
	e, _, err := store.AppendModelAdmissionOffer(context.Background(), e)
	if err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"sandbox_probe_only", "network_admitted_unsettled"} {
		e, err = store.AppendModelAdmissionDecision(context.Background(), modelAdmissionCoordinatorDecisionFromCurrent(e, state, "synthetic_probe_passed", "fixture", state, now))
		if err != nil {
			t.Fatal(err)
		}
	}
	return s, p, ps, b, e
}

func fixturePriced(t *testing.T, s *Server, p pool.Provider, e ModelAdmissionEvent) ModelAdmissionEvent {
	t.Helper()
	a, g, err := s.prepareAdmission(context.Background(), p, e)
	if err != nil {
		t.Fatal(err)
	}
	state := "catalog_priced"
	if e.State == state {
		state = "settlement_capable"
	}
	d := modelAdmissionCoordinatorDecisionFromCurrent(e, state, "primary_artifact_authority_verified", "fixture", "priced", time.Now())
	d.CatalogModelKey = a.Event.CatalogModelKey
	d.CatalogID = a.Event.CatalogID
	d.CatalogBodyDigest = a.Event.CatalogBodyDigest
	d.CatalogSignatureKeyID = a.Event.CatalogSignatureKeyID
	d.CatalogSignaturePubkeyFingerprint = a.Event.CatalogSignaturePubkeyFingerprint
	d.ExpectedCatalogModelHash = a.Event.ExpectedCatalogModelHash
	d.ExpectedCatalogModelHashAlgorithm = a.Event.ExpectedCatalogModelHashAlgorithm
	d.ArtifactAdmissionEvidence = a.Event.ArtifactAdmissionEvidence
	a.Event = d
	d, err = s.modelAdmissions.(guardedModelAdmissionStore).AppendGuardedModelAdmissionDecision(context.Background(), d, func() (func(), error) { return s.pinAdmission(context.Background(), p, a, g) })
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func fixturePreparedDecision(t *testing.T, s *Server, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, uint64, ModelAdmissionEvent) {
	t.Helper()
	a, generation, err := s.prepareAdmission(context.Background(), p, e)
	if err != nil {
		t.Fatal(err)
	}
	d := modelAdmissionCoordinatorDecisionFromCurrent(e, "catalog_priced", "primary_artifact_authority_verified", "fixture", "priced", time.Now())
	d.CatalogModelKey = a.Event.CatalogModelKey
	d.CatalogID = a.Event.CatalogID
	d.CatalogBodyDigest = a.Event.CatalogBodyDigest
	d.CatalogSignatureKeyID = a.Event.CatalogSignatureKeyID
	d.CatalogSignaturePubkeyFingerprint = a.Event.CatalogSignaturePubkeyFingerprint
	d.ExpectedCatalogModelHash = a.Event.ExpectedCatalogModelHash
	d.ExpectedCatalogModelHashAlgorithm = a.Event.ExpectedCatalogModelHashAlgorithm
	d.ArtifactAdmissionEvidence = a.Event.ArtifactAdmissionEvidence
	a.Event = d
	return a, generation, d
}

func TestPromotionRejectsAuthorityDriftBeforeCommit(t *testing.T) {
	for _, boundary := range []string{"catalog_priced", "settlement_capable"} {
		t.Run(boundary, func(t *testing.T) {
			for _, mutation := range []string{"replacement", "removal", "closing", "not-ready", "pending-key", "receipt-key", "benchmark", "ceiling", "stale", "sandboxed", "sanction", "resolver"} {
				t.Run(mutation, func(t *testing.T) {
					runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
						s, p, ps, _, e := admissionGuardFixture(t, store)
						if boundary == "settlement_capable" {
							e = fixturePriced(t, s, p, e)
						}
						original := s.modelAdmissionPrepare
						mutate := func() {
							switch mutation {
							case "replacement":
								q := p
								q.AssignedID = "replacement"
								s.pool.Register(&q, ps.conn)
							case "removal":
								s.pool.RemoveIfSession(p.ProviderID, p.AssignedID)
							case "closing":
								ps.beginClosing()
							case "not-ready":
								s.pool.MarkState(p.ProviderID, p.AssignedID, pool.StateUnavailable)
							case "pending-key", "receipt-key":
								q := p
								q.ReceiptPubkey = bytes.Repeat([]byte{2}, ed25519.PublicKeySize)
								s.pool.Register(&q, ps.conn)
								if mutation == "receipt-key" {
									s.pool.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: time.Now()})
								}
							case "benchmark":
								s.pool.SetBenchmarkQuarantine(p.ProviderID, p.AssignedID, true)
							case "ceiling":
								s.pool.SetAdmissionCeilingExcluded(p.ProviderID, p.AssignedID, true)
							case "stale":
								s.pool.SetAdmissionEvidenceStale(p.ProviderID, p.AssignedID, true)
							case "sandboxed":
								s.pool.SetAdmissionSandboxed(p.ProviderID, p.AssignedID, true)
							case "sanction":
								s.pool.LoadCanarySanctions([]pool.CanarySanctionSnapshot{{ProviderID: p.ProviderID, FailCount: 1}})
							case "resolver":
								_ = s.SetModelAdmissionAuthority(nil)
							}
						}
						_ = s.SetModelAdmissionAuthority(admissionFixtureResolver, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
							a, err := original(ctx, p, e)
							mutate()
							return a, err
						})
						before := e.CoordinatorEventID
						s.promoteModelAdmission(context.Background(), e, p, time.Now())
						latest, _, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
						if err != nil {
							t.Fatal(err)
						}
						if latest.CoordinatorEventID != before {
							t.Fatalf("stale positive append: %+v", latest)
						}
						observed, err := s.refreshArtifactAdmissionStatus(context.Background(), e)
						if err == nil && artifactPositive(observed) {
							t.Fatalf("stale positive readback: %+v", observed)
						}
					})
				})
			}
		})
	}
}

func TestPromotionPinsAuthorityThroughCommit(t *testing.T) {
	runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
		s, p, ps, _, e := admissionGuardFixture(t, store)
		entered, resume, closingEntered, closed := make(chan struct{}), make(chan struct{}), make(chan struct{}), make(chan struct{})
		ps.beforeClosing = func() { close(closingEntered) }
		original := s.modelAdmissionPrepare
		var pinned atomic.Bool
		_ = s.SetModelAdmissionAuthority(admissionFixtureResolver, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
			a, err := original(ctx, p, e)
			a.TryPin = func() (func(), error) {
				pinned.Store(true)
				close(entered)
				<-resume
				return func() { pinned.Store(false) }, nil
			}
			return a, err
		})
		done := make(chan ModelAdmissionEvent, 1)
		go func() { done <- fixturePriced(t, s, p, e) }()
		<-entered
		go func() { ps.beginClosing(); close(closed) }()
		<-closingEntered
		select {
		case <-closed:
			t.Fatal("closing published through held pin")
		default:
		}
		close(resume)
		<-closed
		result := <-done
		if pinned.Load() {
			t.Fatal("pin leaked")
		}
		// The first event can commit before overlapping invalidation; the next
		// boundary must reject that same now-closing session.
		if result.State != "catalog_priced" {
			t.Fatalf("ordering outcome: %s", result.State)
		}
		observed, err := s.refreshArtifactAdmissionStatus(context.Background(), result)
		if err == nil && artifactPositive(observed) {
			t.Fatal("closing stayed positive")
		}
	})
}

func TestGuardedAdmissionStoreRetainsPinUntilCommit(t *testing.T) {
	runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
		s, p, _, _, e := admissionGuardFixture(t, store)
		original := s.modelAdmissionPrepare
		released := false
		_ = s.SetModelAdmissionAuthority(admissionFixtureResolver, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
			a, err := original(ctx, p, e)
			a.TryPin = func() (func(), error) {
				heldAt := time.Now()
				return func() {
					held := time.Since(heldAt)
					t.Logf("authority pins held through durable append/COMMIT: %s", held)
					if held > 250*time.Millisecond {
						t.Error("authority pin duration exceeded 250ms commit budget")
					}
					if released {
						return
					}
					released = true
					switch typed := store.(type) {
					case *memoryModelAdmissionStore:
						if typed.latest[p.ProviderID+"|"+e.CandidateID].State != "catalog_priced" {
							t.Error("released before memory append")
						}
					case *SQLiteModelAdmissionStore:
						var state string
						if err := typed.db.QueryRow("SELECT state FROM model_admission_events ORDER BY id DESC LIMIT 1").Scan(&state); err != nil || state != "catalog_priced" {
							t.Errorf("released before durable COMMIT: %s %v", state, err)
						}
					}
				}, nil
			}
			return a, err
		})
		fixturePriced(t, s, p, e)
		if !released {
			t.Fatal("release omitted")
		}
	})
}

func TestGuardedAdmissionRefusesOrdinaryArtifactAppend(t *testing.T) {
	runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
		s, p, _, _, e := admissionGuardFixture(t, store)
		priced := fixturePriced(t, s, p, e)
		d := modelAdmissionCoordinatorDecisionFromCurrent(priced, "settlement_capable", "verified", "fixture", "settled", time.Now())
		if _, err := store.AppendModelAdmissionDecision(context.Background(), d); err == nil {
			t.Fatal("unguarded artifact-positive append accepted")
		}
	})
}

func TestPromotionGuardContentionAndCancellation(t *testing.T) {
	runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
		s, p, ps, _, e := admissionGuardFixture(t, store)
		a, g, err := s.prepareAdmission(context.Background(), p, e)
		if err != nil {
			t.Fatal(err)
		}
		ps.writeMu.Lock()
		release, err := s.pinAdmission(context.Background(), p, a, g)
		ps.writeMu.Unlock()
		if err == nil || release != nil {
			t.Fatal("contended writer accepted")
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if release, err = s.pinAdmission(ctx, p, a, g); err == nil || release != nil {
			t.Fatal("canceled pin accepted")
		}
		a.TryPin = func() (func(), error) { return nil, errors.New("injected owner failure") }
		if release, err = s.pinAdmission(context.Background(), p, a, g); err == nil || release != nil {
			t.Fatal("owner failure accepted")
		}
		a, _, _ = s.prepareAdmission(context.Background(), p, e)
		release, err = s.pinAdmission(context.Background(), p, a, g)
		if err != nil {
			t.Fatalf("pin leaked after failure: %v", err)
		}
		release()
	})
}

func TestPromotionGuardWSAuthoritySourceLockFirst(t *testing.T) {
	for _, source := range []string{"authority-installation", "session-publication"} {
		t.Run(source, func(t *testing.T) {
			runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
				s, p, ps, _, e := admissionGuardFixture(t, store)
				prepared, generation, decision := fixturePreparedDecision(t, s, p, e)
				beforeEvents, beforeRetries := admissionStoreCounts(t, store)
				switch source {
				case "authority-installation":
					s.modelAdmissionAuthorityMu.Lock()
				case "session-publication":
					s.sessionPublicationMu.Lock()
				}
				started := time.Now()
				_, err := store.(guardedModelAdmissionStore).AppendGuardedModelAdmissionDecision(context.Background(), decision, func() (func(), error) {
					return s.pinAdmission(context.Background(), p, prepared, generation)
				})
				switch source {
				case "authority-installation":
					s.modelAdmissionAuthorityMu.Unlock()
				case "session-publication":
					s.sessionPublicationMu.Unlock()
				}
				if err == nil {
					t.Fatal("write-lock-first guard accepted")
				}
				if elapsed := time.Since(started); elapsed > 250*time.Millisecond {
					t.Fatalf("write-lock-first guard looped for %s", elapsed)
				}
				afterEvents, afterRetries := admissionStoreCounts(t, store)
				if beforeEvents != afterEvents || beforeRetries != afterRetries {
					t.Fatalf("failed guard mutated event/replay state: events %d->%d retries %d->%d", beforeEvents, afterEvents, beforeRetries, afterRetries)
				}
				if source == "authority-installation" {
					if err := s.SetModelAdmissionAuthority(admissionFixtureResolver, s.modelAdmissionPrepare); err != nil {
						t.Fatal(err)
					}
				} else {
					s.deleteProviderSession(sessionKey(p.ProviderID, p.AssignedID))
					s.storeProviderSession(sessionKey(p.ProviderID, p.AssignedID), ps)
				}
				if got := fixturePriced(t, s, p, e); got.State != "catalog_priced" {
					t.Fatalf("later promotion=%s", got.State)
				}
			})
		})
	}
}

func admissionStoreCounts(t *testing.T, store ModelAdmissionStore) (events, retries int) {
	t.Helper()
	switch typed := store.(type) {
	case *memoryModelAdmissionStore:
		typed.mu.Lock()
		defer typed.mu.Unlock()
		return len(typed.events), len(typed.retries)
	case *SQLiteModelAdmissionStore:
		if err := typed.db.QueryRow("SELECT COUNT(*) FROM model_admission_events").Scan(&events); err != nil {
			t.Fatal(err)
		}
		if err := typed.db.QueryRow("SELECT COUNT(*) FROM model_admission_retries").Scan(&retries); err != nil {
			t.Fatal(err)
		}
		return events, retries
	default:
		t.Fatalf("unsupported store %T", store)
		return 0, 0
	}
}
