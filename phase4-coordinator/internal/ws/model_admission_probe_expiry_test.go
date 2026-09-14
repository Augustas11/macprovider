package ws

import (
	"context"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"sync/atomic"
	"testing"
	"time"
)

// Probe and catalog deadlines are distinct fields. The authority clock matrix
// exercises the latter; this matrix holds catalog authority valid while the
// original probe lease alone reaches the serialized insertion/readback boundary.
func TestPromotionProbeLeaseBoundary(t *testing.T) {
	for _, at := range []string{"before", "exact", "before-insert", "after-commit"} {
		t.Run(at, func(t *testing.T) {
			runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
				s, p, _, _, e := admissionGuardFixture(t, store)
				base := time.Date(2024, 1, 2, 3, 4, 5, 0, time.UTC)
				expiry := base.Add(10 * time.Minute)
				var clock atomic.Int64
				clock.Store(base.UnixMilli())
				s.now = func() time.Time { return time.UnixMilli(clock.Load()) }
				hooks := &modelAdmissionCommitTestHooks{now: s.now}
				admissionStoreHooks(store, hooks)
				resolve := func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (ModelAdmissionEvent, error) {
					a, err := admissionFixtureResolver(ctx, p, e)
					a.ArtifactAdmissionEvidence.AuthorityExpiresAtUnixMS = base.Add(time.Hour).UnixMilli()
					a.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS = expiry.UnixMilli()
					return a, err
				}
				var once atomic.Bool
				if err := s.SetModelAdmissionAuthority(resolve, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
					a, err := resolve(ctx, p, e)
					return PreparedModelAdmissionAuthority{Event: a, TryPin: func() (func(), error) {
						return func() {
							if at == "after-commit" && once.CompareAndSwap(false, true) {
								clock.Store(expiry.UnixMilli())
							}
						}, nil
					}}, err
				}); err != nil {
					t.Fatal(err)
				}
				switch at {
				case "before":
					clock.Store(expiry.Add(-time.Millisecond).UnixMilli())
				case "exact":
					clock.Store(expiry.UnixMilli())
				case "before-insert":
					hooks.beforeInsert = func() { clock.Store(expiry.UnixMilli()) }
				}
				var result ModelAdmissionEvent
				if at == "before" {
					result = fixturePriced(t, s, p, e)
				} else {
					result = s.promoteModelAdmission(context.Background(), e, p, base)
				}
				latest, _, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
				if err != nil {
					t.Fatal(err)
				}
				if at == "before" {
					if latest.State != "catalog_priced" || latest.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS != expiry.UnixMilli() {
						t.Fatal("valid original probe lease was not preserved")
					}
					return
				}
				if at == "after-commit" {
					if latest.State != "catalog_priced" || latest.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS != expiry.UnixMilli() {
						t.Fatal("historical probe lease was extended or commit lost")
					}
				} else if latest.CoordinatorEventID != e.CoordinatorEventID {
					t.Fatal("expired probe lease persisted positive")
				}
				observed, err := s.refreshArtifactAdmissionStatus(context.Background(), result)
				if err == nil && artifactPositive(observed) {
					t.Fatal("fresh observation revived original expired probe lease")
				}
			})
		})
	}
}
