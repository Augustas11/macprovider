package buyer_test

import (
	"context"
	"reflect"
	"runtime"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

// The signed primary fixture runs the real feed loader, independent Tier2
// verifier, registry and persisted billing snapshot; no success resolver is
// substituted. WS transport producer coverage belongs to the WS lane.
func TestPreparedBuyerAuthorityOwnsPublishedInputs(t *testing.T) {
	for _, publication := range []string{"constructor", "setters"} {
		t.Run(publication, func(t *testing.T) {
			server, p, event, feeds, rewards, _ := primaryAdmissionFixture(t)
			baseline, err := server.PrepareModelAdmissionAuthority(context.Background(), p, event)
			if err != nil {
				t.Fatal(err)
			}
			if publication == "setters" {
				server.SetAutotuneFeeds(feeds)
				server.SetBillingConfig(rewards, baseline.Event.ArtifactAdmissionEvidence.ConfigSnapshotID, 1)
			}
			// Mutate all caller-held slice members, including detached signatures.
			for _, raw := range [][]byte{feeds.RateCardJSON, feeds.RateCardSig, feeds.DemandRankJSON, feeds.DemandRankSig, feeds.AutotuneCandidatesJSON, feeds.AutotuneCandidatesSig, feeds.CatalogArtifactsJSON, feeds.CatalogArtifactsSig} {
				if len(raw) == 0 {
					t.Fatal("fixture omitted feed bytes")
				}
				raw[0] ^= 0xff
			}
			row := rewards.RateCard["test-model"]
			row.PromptCreditsPerMtok++
			rewards.RateCard["test-model"] = row
			delete(rewards.RateCard, "test-model")
			current, err := server.PrepareModelAdmissionAuthority(context.Background(), p, event)
			if err != nil {
				t.Fatalf("retained alias changed authority: %v", err)
			}
			before, after := *baseline.Event.ArtifactAdmissionEvidence, *current.Event.ArtifactAdmissionEvidence
			// Each preparation receives its own observation time; input identity and
			// integer price evidence must remain byte-for-byte equivalent.
			before.ProbeExpiresAtUnixMS, after.ProbeExpiresAtUnixMS = 0, 0
			if !reflect.DeepEqual(before, after) {
				t.Fatalf("published evidence changed: before=%+v after=%+v", before, after)
			}
			release, err := current.TryPin()
			if err != nil || release == nil {
				t.Fatalf("owned authority pin: %v", err)
			}
			release()
		})
	}
}

type buyerAuthorityMutation struct {
	name       string
	apply      func(*buyer.Server, buyer.AutotuneFeeds, config.RewardsConfig, *billing.Store, int64) error
	validAfter bool
}

func additionalBuyerAuthorityMutations() []buyerAuthorityMutation {
	return []buyerAuthorityMutation{
		{"feed_generation", func(s *buyer.Server, f buyer.AutotuneFeeds, _ config.RewardsConfig, _ *billing.Store, _ int64) error {
			s.SetAutotuneFeeds(f)
			return nil
		}, true},
		{"billing_generation", func(s *buyer.Server, _ buyer.AutotuneFeeds, c config.RewardsConfig, _ *billing.Store, id int64) error {
			s.SetBillingConfig(c, id, 1)
			return nil
		}, true},
		{"billing_snapshot", func(s *buyer.Server, _ buyer.AutotuneFeeds, c config.RewardsConfig, _ *billing.Store, _ int64) error {
			s.SetBillingConfig(c, 0, 1)
			return nil
		}, false},
		{"effective_rates", func(s *buyer.Server, _ buyer.AutotuneFeeds, c config.RewardsConfig, _ *billing.Store, id int64) error {
			row := c.RateCard["test-model"]
			row.CompletionCreditsPerMtok++
			c.RateCard["test-model"] = row
			s.SetBillingConfig(c, id, 1)
			return nil
		}, false},
		{"settlement_enforcement", func(_ *buyer.Server, _ buyer.AutotuneFeeds, _ config.RewardsConfig, store *billing.Store, _ int64) error {
			setSettlementModeForTest(store, billing.RouteSnapshotModeObserve)
			return nil
		}, false},
		{"tier2_default", func(_ *buyer.Server, _ buyer.AutotuneFeeds, _ config.RewardsConfig, _ *billing.Store, _ int64) error {
			_, err := tier2.ConfigureDefaultStrict(config.Tier2Config{}, zerolog.Nop(), func(*tier2.Catalog) error { return nil })
			return err
		}, false},
		{"tier2_inplace", func(_ *buyer.Server, _ buyer.AutotuneFeeds, _ config.RewardsConfig, _ *billing.Store, _ int64) error {
			return tier2.Default().ConfigureStrict(config.Tier2Config{}, zerolog.Nop())
		}, false},
	}
}

func TestPreparedBuyerAuthorityRejectsCompletedMutation(t *testing.T) {
	for _, mutation := range additionalBuyerAuthorityMutations() {
		t.Run(mutation.name, func(t *testing.T) {
			server, p, event, feeds, rewards, store := primaryAdmissionFixture(t)
			prepared, err := server.PrepareModelAdmissionAuthority(context.Background(), p, event)
			if err != nil {
				t.Fatal(err)
			}
			if err := mutation.apply(server, feeds, rewards, store, prepared.Event.ArtifactAdmissionEvidence.ConfigSnapshotID); err != nil {
				t.Fatal(err)
			}
			if release, err := prepared.TryPin(); err == nil || release != nil {
				if release != nil {
					release()
				}
				t.Fatal("stale prepared authority accepted completed mutation")
			}
			fresh, err := server.PrepareModelAdmissionAuthority(context.Background(), p, event)
			if mutation.validAfter {
				if err != nil {
					t.Fatalf("unchanged newly published authority did not recover: %v", err)
				}
				release, err := fresh.TryPin()
				if err != nil || release == nil {
					t.Fatalf("fresh pin failed: %v", err)
				}
				release()
			} else if err == nil {
				t.Fatal("invalid replacement granted fresh authority")
			}
		})
	}
}

func TestPreparedBuyerAuthorityPinsRealOwnerMutation(t *testing.T) {
	for _, mutation := range additionalBuyerAuthorityMutations() {
		t.Run(mutation.name, func(t *testing.T) {
			server, p, event, feeds, rewards, store := primaryAdmissionFixture(t)
			prepared, err := server.PrepareModelAdmissionAuthority(context.Background(), p, event)
			if err != nil {
				t.Fatal(err)
			}
			release, err := prepared.TryPin()
			if err != nil || release == nil {
				t.Fatalf("initial pin failed: %v", err)
			}
			held := true
			defer func() {
				if held {
					release()
				}
			}()
			done := make(chan error, 1)
			go func() {
				done <- mutation.apply(server, feeds, rewards, store, prepared.Event.ArtifactAdmissionEvidence.ConfigSnapshotID)
			}()
			// An actual pending owner writer causes the production nonblocking pin to
			// fail. Observing that failure proves entry into the setter's owner lock;
			// a goroutine-start notification alone would not establish exclusion.
			deadline := time.Now().Add(5 * time.Second)
			for {
				another, pinErr := prepared.TryPin()
				if pinErr != nil {
					if another != nil {
						another()
						t.Fatal("failed pin returned a release")
					}
					break
				}
				if another == nil {
					t.Fatal("successful pin omitted release")
				}
				another()
				if time.Now().After(deadline) {
					t.Fatal("real mutation never reached owner pin")
				}
				runtime.Gosched()
			}
			select {
			case err := <-done:
				t.Fatalf("mutation crossed held pin: %v", err)
			default:
			}
			release()
			held = false
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("owner lock leaked after release")
			}
			if unlock, err := prepared.TryPin(); err == nil || unlock != nil {
				if unlock != nil {
					unlock()
				}
				t.Fatal("old preparation remained current after publication")
			}
		})
	}
}
