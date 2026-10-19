package main

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/rs/zerolog"
)

func stakeRoutingFixture(t *testing.T, cooldownHours int) *billing.Store {
	t.Helper()
	req, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { req.Close() })
	store, err := billing.NewStore(req.DB())
	if err != nil {
		t.Fatal(err)
	}
	// Nothing listens on port 1: every rewards read fails fast.
	rewardsDB, err := sql.Open("postgres", "postgres://nobody@127.0.0.1:1/rewards?sslmode=disable&connect_timeout=1")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { rewardsDB.Close() })
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	cfg := &config.Config{}
	cfg.StakeAllowance.UnlockCooldownHours = cooldownHours
	cfg.StakeAllowance.RefreshCheckIntervalSeconds = 3600
	setupStakeAllowance(ctx, cfg, req.DB(), rewardsDB, store, zerolog.Nop())
	return store
}

func TestStakeRoutingIdentityNotInstalledWhenLedgerFails(t *testing.T) {
	// A zero cooldown makes NewStakeLedger refuse: the stake source must
	// contribute nothing and never refuse a buyer.
	store := stakeRoutingFixture(t, 0)
	owned, err := store.BuyerOwnedProviders(context.Background(), "acct", nil)
	if err != nil || len(owned) != 0 {
		t.Fatalf("owned=%v err=%v", owned, err)
	}
	if got := store.RoutingStakeIdentityFallbacks(); got != 0 {
		t.Fatalf("stake identity read attempted without a ledger: fallbacks=%d", got)
	}
}

func TestStakeRoutingIdentityUnreachableLedgerFallsBack(t *testing.T) {
	store := stakeRoutingFixture(t, 24)
	start := time.Now()
	owned, err := store.BuyerOwnedProviders(context.Background(), "acct", nil)
	if err != nil || len(owned) != 0 {
		t.Fatalf("unreachable rewards database refused the buyer: owned=%v err=%v", owned, err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("stake identity read stalled dispatch for %v", elapsed)
	}
	if got := store.RoutingStakeIdentityFallbacks(); got != 1 {
		t.Fatalf("fallbacks=%d", got)
	}
}
