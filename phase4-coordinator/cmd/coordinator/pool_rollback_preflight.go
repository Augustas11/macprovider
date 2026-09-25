package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
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
	if err := fs.Parse(args); err != nil {
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
	if err := json.NewEncoder(stdout).Encode(result); err != nil {
		fmt.Fprintf(stderr, "encode json: %v\n", err)
		return 1
	}
	if result.RollbackBlocked {
		return poolRollbackBlockedExit
	}
	return 0
}
