package main

import (
	"fmt"
	"reflect"
	"strings"
	"sync/atomic"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// reloadStartupOnlyBaseline is the boot config as the SIGHUP loader parses it.
// A reload that changes anything the reload does not apply is rejected, so a
// coordinator_config_applied event with source sighup always means the whole
// on-disk file is in force (ops gates read it as that proof).
var reloadStartupOnlyBaseline atomic.Pointer[config.Config]

// sighupReloadBaseline parses the boot files with the SIGHUP loader, so the
// baseline and every reload come from the same loader (payout stripped, same
// defaults and env resolution). The bytes must be the ones boot applied.
func sighupReloadBaseline(configPath, overlayPath string, boot config.SourceDigests) (config.Config, error) {
	cfg, digests, err := config.LoadForSIGHUPReloadWithOverlayDigests(configPath, overlayPath)
	if err != nil {
		return config.Config{}, err
	}
	if digests != boot {
		return config.Config{}, fmt.Errorf("config files changed during boot; restart to apply one version")
	}
	return cfg, nil
}

// withoutReloadedConfig zeroes every field reloadCoordinatorConfig applies or
// checks itself, plus payout (its own listener). What remains is startup-only.
func withoutReloadedConfig(c config.Config) config.Config {
	c.Payout = config.Default().Payout
	c.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{}
	c.CoordinatorAdvertisedVersion = config.CoordinatorAdvertisedVersion{}
	c.PrivacyClass = config.PrivacyClassConfig{}
	c.Tier2 = config.Tier2Config{}
	c.TrustedPools = config.TrustedPoolsConfig{}
	c.AutotuneFeeds = config.AutotuneFeedsConfig{}
	c.ProofOfWeights = config.ProofOfWeightsConfig{}
	c.Rewards = config.RewardsConfig{}
	c.Settlement = config.SettlementConfig{}
	c.ShardGroups = config.ShardGroupsConfig{}
	c.Routing.BuyerUXConformancePath = ""
	c.Routing.DefaultObjective = ""
	c.Routing.MinProviderThroughputTPS = 0
	c.Routing.ModelClasses = nil
	c.Routing.VisionQualifications = nil
	c.Billing.CeilingRestatementEnabled = false
	c.Billing.ForceCreditSettlementHoldSeconds = 0
	c.Billing.QuarantineResolutionForceCreditEnabled = false
	c.Billing.QuarantineResolutionForceVoidEnabled = false
	c.Billing.Retention = config.BillingRetentionConfig{}
	c.Billing.LedgerRollup = config.LedgerRollupConfig{}
	c.Stats.Rollup.UsdPerMillionCredits = 0
	c.Storage.RequestLogRetentionDays = 0
	return c
}

// startupOnlyConfigDrift names the config sections whose startup-only fields
// differ between the boot baseline and a reload candidate.
func startupOnlyConfigDrift(baseline, next config.Config) []string {
	b := reflect.ValueOf(withoutReloadedConfig(baseline))
	n := reflect.ValueOf(withoutReloadedConfig(next))
	t := b.Type()
	var changed []string
	for i := 0; i < t.NumField(); i++ {
		if !reflect.DeepEqual(b.Field(i).Interface(), n.Field(i).Interface()) {
			name := strings.Split(t.Field(i).Tag.Get("yaml"), ",")[0]
			if name == "" || name == "-" {
				name = t.Field(i).Name
			}
			changed = append(changed, name)
		}
	}
	return changed
}
