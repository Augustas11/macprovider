package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// poolRollbackBlockedExit is the exit status when a downgrade to a
// pre-SPEC-022-v0.2.0 coordinator would strand pool settlement.
const poolRollbackBlockedExit = 3

func runPoolRollbackPreflight(args []string) int {
	return runPoolRollbackPreflightIO(args, os.Stdout, os.Stderr, time.Now)
}

// runPoolRollbackPreflightIO is the SPEC-022 v0.2.0 downgrade gate: it must
// be run with the CURRENT binary against the live database before any
// rollback to a coordinator that predates pool_operator_attested settlement.
func runPoolRollbackPreflightIO(args []string, stdout, stderr io.Writer, now func() time.Time) int {
	fs := flag.NewFlagSet("pool-rollback-preflight", flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", "coordinator.yaml", "path to coordinator YAML config")
	configOverlay := fs.String("config-overlay", "", "optional coordinator YAML config overlay")
	timeout := fs.Duration("timeout", 5*time.Minute, "max time the preflight may run")
	targetTier := fs.String("target-tier", trustpool.RollbackTierV1Only, "rollback target tier (v1-only, m8, m9, p1816, p1880; trusted-pool-production-launch runbook section 9 step 4b); the default is the oldest")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if !trustpool.ValidRollbackTier(*targetTier) {
		fmt.Fprintf(stderr, "STOP: unknown --target-tier %q (v1-only, m8, m9, p1816, p1880)\n", *targetTier)
		return 2
	}
	cfg, err := config.LoadWithOverlay(*configPath, *configOverlay)
	if err != nil {
		fmt.Fprintf(stderr, "config: %v\n", err)
		return 1
	}
	store, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
	if err != nil {
		fmt.Fprintf(stderr, "open request_log (ro): %v\n", err)
		return 1
	}
	defer store.Close()
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	result, err := billing.CheckPoolRollbackPreflight(ctx, store.DB(), now())
	if err != nil {
		fmt.Fprintf(stderr, "pool rollback preflight: %v\n", err)
		return 1
	}
	// #1816 VM acceptance A-2: a target that cannot decode one accepted
	// manifest disables every pool at start, so the history gates too.
	replay, err := trustpool.CheckManifestHistoryReplay(ctx, store.DB(), *targetTier)
	if err != nil {
		fmt.Fprintf(stderr, "STOP: manifest history replay check: %v; do not roll back the coordinator, roll it forward\n", err)
		return 1
	}
	// #1880: a pre-p1880 target ignores requested_pool_model_id and could
	// bind a live offer to another pool with the same artifact.
	selection, err := trustpool.CheckPoolSelectionRollback(ctx, store.DB(), *targetTier)
	if err != nil {
		fmt.Fprintf(stderr, "STOP: pool selection check: %v; do not roll back the coordinator\n", err)
		return 1
	}
	if len(replay.CannotReplay) > 0 || selection.Blocked {
		// Waiting never clears it.
		result.RollbackBlocked = true
		result.EarliestSafeUnixMS = 0
	}
	if err := json.NewEncoder(stdout).Encode(struct {
		billing.PoolRollbackPreflight
		ManifestHistory trustpool.ManifestReplayCheck        `json:"manifest_history"`
		PoolSelection   trustpool.PoolSelectionRollbackCheck `json:"pool_selection"`
	}{result, replay, selection}); err != nil {
		fmt.Fprintf(stderr, "encode json: %v\n", err)
		return 1
	}
	if len(replay.CannotReplay) > 0 {
		fmt.Fprintf(stderr, "STOP: a %s coordinator cannot replay the pool manifest history (%s) and would disable every pool; roll forward instead\n",
			*targetTier, strings.Join(replay.CannotReplay, ", "))
		if len(replay.SupersededWindows) > 0 && *targetTier != trustpool.RollbackTierP1880 {
			fmt.Fprintf(stderr, "STOP: superseded policy windows (%s) stay in each pool's history for good; only a p1880 or newer coordinator replays them: roll forward\n",
				strings.Join(replay.SupersededWindows, "; "))
		}
	}
	if selection.Blocked {
		fmt.Fprintf(stderr, "STOP: %d live offer(s) name a pool entry that a %s coordinator would ignore (%s); clear each by having the provider run `macprovider-cli models admission withdraw <candidate> --yes --json` (and re-offer without pool_model_id if it should stay offered), then re-run this preflight\n",
			len(selection.LiveSelectorOffers), *targetTier, strings.Join(selection.LiveSelectorOffers, "; "))
	}
	if result.RollbackBlocked {
		return poolRollbackBlockedExit
	}
	return 0
}
