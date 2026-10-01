package main

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

// Freeze audit R1 (#1816) CODE H2: a SIGHUP that tightens or removes
// trusted_pools.pool_model_pricing_bounds is in force once the reload is
// recorded as applied (it was previously accepted and ignored).
func TestSIGHUPReloadAppliesPoolModelPricingBounds(t *testing.T) {
	defer tier2.ResetForTest()
	useAppliedConfigStatePath(t)
	t.Cleanup(func() { livePoolModelPricingBounds.Store(nil) })
	startup, _, wsServer, buyerServer := reloadTestServers(config.Default())
	livePoolModelPricingBounds.Store(&poolmanifest.PoolModelPricingBounds{MaxPromptRatePerMtok: 5000, MaxPromptCacheHitRatePerMtok: 5000, MaxCompletionRatePerMtok: 5000})

	tightened := startup
	tightened.TrustedPools.Enabled = true
	tightened.TrustedPools.RefreshIntervalS = 5
	tightened.TrustedPools.PoolModelPricingBounds = &config.TrustedPoolsPoolModelPricingBounds{MaxPromptRatePerMtok: 1000, MaxPromptCacheHitRatePerMtok: 1000, MaxCompletionRatePerMtok: 1000}
	reloadTier2Config(writeReloadConfig(t, tightened), startup.Tier2, zerolog.Nop(), wsServer, buyerServer, nil)
	if b := currentPoolModelPricingBounds(); b == nil || b.MaxCompletionRatePerMtok != 1000 {
		t.Fatalf("tightened bounds after SIGHUP = %+v", b)
	}

	removed := tightened
	removed.TrustedPools.PoolModelPricingBounds = nil
	reloadTier2Config(writeReloadConfig(t, removed), startup.Tier2, zerolog.Nop(), wsServer, buyerServer, nil)
	if b := currentPoolModelPricingBounds(); b != nil {
		t.Fatalf("removed bounds still in force after SIGHUP: %+v", b)
	}
}
