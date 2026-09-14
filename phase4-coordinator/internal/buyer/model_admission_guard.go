package buyer

import (
	"context"
	"fmt"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// WithModelAdmissionTransport is constructor-only. Both halves of the WS owner
// are mandatory for artifact authority; legacy routing remains independent.
func WithModelAdmissionTransport(available func(string, string) bool, closeTransport func(string, string, string) error) Option {
	return func(s *Server) { s.modelAdmissionAvailable, s.modelAdmissionClose = available, closeTransport }
}

func (s *Server) ModelAdmissionAuthorityReady() bool {
	return s != nil && s.modelAdmissionAvailable != nil && s.modelAdmissionClose != nil
}

func cloneAdmissionRewards(cfg config.RewardsConfig) config.RewardsConfig {
	if cfg.RateCard != nil {
		rows := make(map[string]config.RateCardEntry, len(cfg.RateCard))
		for key, row := range cfg.RateCard {
			rows[key] = row
		}
		cfg.RateCard = rows
	}
	return cfg
}

func cloneAdmissionFeeds(f AutotuneFeeds) AutotuneFeeds {
	f.RateCardJSON = append([]byte(nil), f.RateCardJSON...)
	f.RateCardSig = append([]byte(nil), f.RateCardSig...)
	f.DemandRankJSON = append([]byte(nil), f.DemandRankJSON...)
	f.DemandRankSig = append([]byte(nil), f.DemandRankSig...)
	f.AutotuneCandidatesJSON = append([]byte(nil), f.AutotuneCandidatesJSON...)
	f.AutotuneCandidatesSig = append([]byte(nil), f.AutotuneCandidatesSig...)
	f.CatalogArtifactsJSON = append([]byte(nil), f.CatalogArtifactsJSON...)
	f.CatalogArtifactsSig = append([]byte(nil), f.CatalogArtifactsSig...)
	return f
}

type admissionAuthorityCapture struct {
	feedGeneration, billingGeneration uint64
	store                             *billing.Store
	catalog                           *tier2.Catalog
	material                          tier2.RouteSnapshotMaterial
	provider                          pool.Provider
	settlement                        config.SettlementConfig
}

// PrepareModelAdmissionAuthority does all parsing and immutable DB verification
// before admission serialization. Its pin only compares unchanged owned sources.
func (s *Server) PrepareModelAdmissionAuthority(ctx context.Context, p pool.Provider, event providerws.ModelAdmissionEvent) (providerws.PreparedModelAdmissionAuthority, error) {
	var capture admissionAuthorityCapture
	resolved, err := s.resolveModelAdmissionAuthority(ctx, p, event, &capture)
	if err != nil {
		return providerws.PreparedModelAdmissionAuthority{}, err
	}
	return providerws.PreparedModelAdmissionAuthority{Event: resolved, TryPin: func() (func(), error) {
		var releases []func()
		release := func() {
			for i := len(releases) - 1; i >= 0; i-- {
				releases[i]()
			}
		}
		fail := func() (func(), error) {
			release()
			return nil, fmt.Errorf("model admission authority changed or contended")
		}
		if !s.autotuneFeedsMu.TryRLock() {
			return fail()
		}
		releases = append(releases, s.autotuneFeedsMu.RUnlock)
		if s.autotuneFeedsGeneration != capture.feedGeneration {
			return fail()
		}
		if !s.billingMu.TryRLock() {
			return fail()
		}
		releases = append(releases, s.billingMu.RUnlock)
		if s.billingAuthorityGeneration != capture.billingGeneration || s.billing != capture.store {
			return fail()
		}
		settlement, unlock, ok := capture.store.TryPinSettlementConfig(config.Default().Settlement)
		if !ok {
			return fail()
		}
		releases = append(releases, unlock)
		if settlement != capture.settlement || billing.VerifiedModelSettlementMode(settlement) != billing.RouteSnapshotModeEnforce {
			return fail()
		}
		material, unlock, ok := tier2.TryPinSnapshotMaterial(capture.catalog, p.ModelID, p.ModelHash)
		if !ok {
			return fail()
		}
		releases = append(releases, unlock)
		if material != capture.material {
			return fail()
		}
		return release, nil
	}}, nil
}
