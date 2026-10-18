package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

// A SIGHUP reload whose billing snapshot fails leaves every earlier staged
// part unapplied: the WS/buyer Tier-2 views, the billing output ceiling, the
// Tier-2 catalog and the release stay exactly as they were, and no later
// publication promotes what the rejected reload staged.
func TestSIGHUPReloadBillingFailureLeavesNoPartialState(t *testing.T) {
	defer tier2.ResetForTest()
	h := newPricingReloadHarness(t, pricingRewards(100, 200))
	tier2.SetReleasePublisher(h.ws)
	t.Cleanup(func() { tier2.SetReleasePublisher(nil) })
	h.store.SetOutputBytesPerTokenCeiling(h.startup.Tier2.OutputBytesPerTokenCeiling)

	original := reloadBillingConfigV05
	t.Cleanup(func() { reloadBillingConfigV05 = original })
	reloadBillingConfigV05 = func(*billing.Store, context.Context, config.RewardsConfig, bool, bool, int64, string, time.Time) (int64, error) {
		return 0, errors.New("injected billing failure")
	}

	beforeTier2 := fetchReloadTier2Metadata(t, h.buyer)
	beforeCatalog := tier2.Default()
	beforeRelease := h.ws.CurrentAutotuneCatalog()
	beforeCeiling := h.store.OutputBytesPerTokenCeiling()
	before := h.state(t)
	rows := h.snapshotRows(t, "ledger_config_snapshots")

	next := h.startup
	next.Tier2.ObserveEnabled = !h.startup.Tier2.ObserveEnabled
	next.Tier2.OutputBytesPerTokenCeiling = beforeCeiling + 7
	var logs bytes.Buffer
	reloadCoordinatorConfig(writeReloadConfig(t, next), "", h.startup.Tier2, zerolog.New(&logs), h.ws, h.buyer, nil, nil, nil, h.store)
	if !strings.Contains(logs.String(), "billing config reload rejected") {
		t.Fatalf("billing failure not reached; logs=%s", logs.String())
	}

	if got := fetchReloadTier2Metadata(t, h.buyer); got != beforeTier2 {
		t.Fatalf("buyer Tier-2 view changed by a rejected reload: before=%+v after=%+v", beforeTier2, got)
	}
	if got := h.store.OutputBytesPerTokenCeiling(); got != beforeCeiling {
		t.Fatalf("billing output ceiling changed by a rejected reload: %d -> %d", beforeCeiling, got)
	}
	if got := h.ws.CurrentAutotuneCatalog(); got != beforeRelease {
		t.Fatalf("release changed by a rejected reload: %v", got)
	}
	if tier2.Default() != beforeCatalog {
		t.Fatal("Tier-2 catalog swapped by a rejected reload")
	}
	h.assertUnchanged(t, before, rows, "a billing-rejected reload")

	// A later publication must not promote the rejected reload's staging.
	h.ws.RefreshTier2HashStatuses()
	if tier2.Default() != beforeCatalog {
		t.Fatal("a later publication promoted the rejected reload's staged Tier-2 catalog")
	}
}
