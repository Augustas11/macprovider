package ws

import (
	"context"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type ProviderRewardsTrustTierStore interface {
	ProviderTrustTier(ctx context.Context, providerID string) (string, error)
}

const rewardsTrustTierTrusted = "trusted"
const rewardsTrustLookupTimeout = 500 * time.Millisecond
const rewardsTrustSweepDegradedThreshold = 3

func (s *Server) routingAdmissionTier(ctx context.Context, auth providerAuth, providerID string, pinned bool) pool.Tier {
	if pinned {
		return pool.TierPinned
	}
	if s.rewardsTrust == nil || !auth.validated || auth.providerID != providerID {
		return pool.TierProvisional
	}
	lookupCtx, cancel := context.WithTimeout(ctx, rewardsTrustLookupTimeout)
	defer cancel()
	tier, err := s.rewardsTrust.ProviderTrustTier(lookupCtx, providerID)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("rewards trust tier lookup failed; keeping provisional routing tier")
		return pool.TierProvisional
	}
	if strings.EqualFold(strings.TrimSpace(tier), rewardsTrustTierTrusted) {
		return pool.TierTrusted
	}
	return pool.TierProvisional
}

func (s *Server) ApplyRewardsTrustTier(providerID, tier string) {
	if s == nil || s.pool == nil {
		return
	}
	var routingTier pool.Tier
	switch strings.ToLower(strings.TrimSpace(tier)) {
	case rewardsTrustTierTrusted:
		routingTier = pool.TierTrusted
	case string(pool.TierProvisional):
		routingTier = pool.TierProvisional
	default:
		s.log.Warn().Str("provider_id", providerID).Str("trust_tier", tier).Msg("unknown rewards trust tier; live routing tier unchanged")
		return
	}
	updated, ok := s.pool.SetEarnedTrustTier(providerID, routingTier)
	if !ok {
		return
	}
	s.log.Info().
		Str("provider_id", providerID).
		Str("routing_tier", string(updated.Tier)).
		Str("rewards_trust_tier", tier).
		Msg("live provider routing tier reconciled from rewards trust")
}

func (s *Server) runRewardsTrustTierReconciliationSweep() {
	if s == nil || s.pool == nil || s.rewardsTrust == nil {
		return
	}
	var eligible, succeeded, failed int
	for _, provider := range s.pool.Snapshot() {
		if provider.Tier == pool.TierPinned {
			continue
		}
		if _, ok := s.sessionFor(provider.ProviderID, provider.AssignedID); !ok {
			continue
		}
		key := sessionKey(provider.ProviderID, provider.AssignedID)
		if provider.AuthState != pool.AuthBearerValidated {
			s.rewardsTrustSweepFailures.Delete(key)
			if provider.Tier == pool.TierTrusted {
				s.ApplyRewardsTrustTier(provider.ProviderID, string(pool.TierProvisional))
			}
			continue
		}
		eligible++
		lookupCtx, cancel := context.WithTimeout(context.Background(), rewardsTrustLookupTimeout)
		tier, err := s.rewardsTrust.ProviderTrustTier(lookupCtx, provider.ProviderID)
		cancel()
		if err != nil {
			failed++
			failures := s.recordRewardsTrustLookupFailure(key)
			s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Msg("rewards trust tier reconciliation failed")
			if failures >= rewardsTrustSweepDegradedThreshold && provider.Tier == pool.TierTrusted {
				s.ApplyRewardsTrustTier(provider.ProviderID, string(pool.TierProvisional))
			}
			continue
		}
		s.rewardsTrustSweepFailures.Delete(key)
		succeeded++
		routingTier := pool.TierProvisional
		if strings.EqualFold(strings.TrimSpace(tier), rewardsTrustTierTrusted) {
			routingTier = pool.TierTrusted
		}
		if provider.Tier != routingTier {
			s.ApplyRewardsTrustTier(provider.ProviderID, string(routingTier))
		}
	}
	if eligible == 0 {
		s.rewardsTrustStoreFailures = 0
		return
	}
	if failed > 0 && succeeded == 0 {
		s.rewardsTrustStoreFailures++
		s.log.Warn().
			Int("eligible_sessions", eligible).
			Int("consecutive_failures", s.rewardsTrustStoreFailures).
			Msg("rewards trust tier reconciliation skipped; trust store unavailable")
		if s.rewardsTrustStoreFailures >= rewardsTrustSweepDegradedThreshold {
			for _, provider := range s.pool.Snapshot() {
				if provider.Tier == pool.TierTrusted {
					s.ApplyRewardsTrustTier(provider.ProviderID, string(pool.TierProvisional))
				}
			}
		}
		return
	}
	if s.rewardsTrustStoreFailures > 0 {
		s.log.Info().
			Int("prior_consecutive_failures", s.rewardsTrustStoreFailures).
			Msg("rewards trust tier reconciliation recovered")
	}
	s.rewardsTrustStoreFailures = 0
}

func (s *Server) recordRewardsTrustLookupFailure(key string) int {
	if s == nil {
		return 0
	}
	prior, _ := s.rewardsTrustSweepFailures.Load(key)
	failures, _ := prior.(int)
	failures++
	s.rewardsTrustSweepFailures.Store(key, failures)
	return failures
}
