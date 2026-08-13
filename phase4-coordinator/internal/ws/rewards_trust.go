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
