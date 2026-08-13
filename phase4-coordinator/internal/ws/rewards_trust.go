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
const rewardsTrustSweepDegradedThreshold = 3

var (
	rewardsTrustLookupTimeout = 500 * time.Millisecond
	rewardsTrustSweepDeadline = trustRevalidationSweepDeadlineCap
)

func (s *Server) routingAdmissionTier(ctx context.Context, auth providerAuth, providerID string, pinned bool) pool.Tier {
	if pinned {
		return pool.TierPinned
	}
	if s.rewardsTrust == nil || !auth.validated || auth.providerID != providerID {
		return pool.TierProvisional
	}
	if !s.trustedRoutingCustodyEligible(ctx, providerID) {
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
		if !s.trustedRoutingCustodyEligible(context.Background(), providerID) {
			routingTier = pool.TierProvisional
			break
		}
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
	sweepCtx, cancel := context.WithTimeout(context.Background(), rewardsTrustSweepDeadline)
	defer cancel()
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
		if !s.trustedRoutingCustodyEligible(sweepCtx, provider.ProviderID) {
			s.rewardsTrustSweepFailures.Delete(key)
			if provider.Tier == pool.TierTrusted {
				s.ApplyRewardsTrustTier(provider.ProviderID, string(pool.TierProvisional))
			}
			continue
		}
		eligible++
		if sweepCtx.Err() != nil {
			failed++
			s.rewardsTrustSweepFailures.Delete(key)
			if provider.Tier == pool.TierTrusted {
				s.ApplyRewardsTrustTier(provider.ProviderID, string(pool.TierProvisional))
			}
			continue
		}
		lookupCtx, cancel := context.WithTimeout(sweepCtx, rewardsTrustLookupTimeout)
		tier, err := s.rewardsTrust.ProviderTrustTier(lookupCtx, provider.ProviderID)
		cancel()
		if sweepCtx.Err() != nil {
			failed++
			s.rewardsTrustSweepFailures.Delete(key)
			if provider.Tier == pool.TierTrusted {
				s.ApplyRewardsTrustTier(provider.ProviderID, string(pool.TierProvisional))
			}
			continue
		}
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

func (s *Server) trustedRoutingCustodyEligible(ctx context.Context, providerID string) bool {
	if ctx == nil {
		ctx = context.Background()
	}
	if s.tokens == nil {
		return true
	}
	history, ok := s.tokens.(providerTokenCustodyHistoryStore)
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Msg("provider token custody history unavailable; keeping rewards-trusted routing provisional")
		return false
	}
	lookupCtx, cancel := context.WithTimeout(ctx, rewardsTrustLookupTimeout)
	revoked, err := history.HasRevokedTokenForProvider(lookupCtx, providerID)
	cancel()
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("provider token custody history lookup failed; keeping rewards-trusted routing provisional")
		return false
	}
	if !revoked {
		return true
	}
	identities, ok := s.bootstrapTokens.(admissionIdentityStore)
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Msg("provider has revoked token history without durable admission identity store; keeping rewards-trusted routing provisional")
		return false
	}
	identityCtx, identityCancel := context.WithTimeout(ctx, rewardsTrustLookupTimeout)
	_, active, err := identities.LookupAdmissionIdentityPubkey(identityCtx, providerID)
	identityCancel()
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("durable admission identity lookup failed; keeping rewards-trusted routing provisional")
		return false
	}
	if !active {
		s.log.Warn().Str("provider_id", providerID).Msg("provider has revoked token history without active durable admission identity; keeping rewards-trusted routing provisional")
		return false
	}
	return true
}

func (s *Server) clearRewardsTrustLookupFailure(providerID, assignedID string) {
	if s == nil {
		return
	}
	s.rewardsTrustSweepFailures.Delete(sessionKey(providerID, assignedID))
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
