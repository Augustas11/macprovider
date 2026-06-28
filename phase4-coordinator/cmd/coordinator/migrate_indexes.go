package main

// SPEC-002 v1.4.2 R-2 / ISS-188 operator-runbook subcommand:
//
//	coordinator migrate-indexes --config <path>
//
// One-shot CREATE INDEX for request_log.external_request_id (and any
// future ensureIndex DDL). Intentionally NOT invoked from the daemon
// path: the request-log store caps the pool at one writer connection,
// so running CREATE INDEX inside the daemon would contend with the 6s
// INSERT timeout on the hot path. Operator runs this once per deploy
// before re-binding traffic, or during a maintenance window.

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func runMigrateIndexes(args []string) int {
	return runMigrateIndexesIO(args, os.Stdout, os.Stderr)
}

func runMigrateIndexesIO(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("migrate-indexes", flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", "coordinator.yaml", "path to coordinator YAML config")
	timeout := fs.Duration("timeout", 30*time.Minute, "max time the index build may run")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		fmt.Fprintf(stderr, "config: %v\n", err)
		return 1
	}
	store, err := requestlog.OpenStore(cfg.Storage.DBPath)
	if err != nil {
		fmt.Fprintf(stderr, "open request_log store: %v\n", err)
		return 1
	}
	defer store.Close()

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	started := time.Now()
	if err := store.MigrateIndexes(ctx); err != nil {
		fmt.Fprintf(stderr, "MigrateIndexes: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "migrate-indexes ok (%s)\n", time.Since(started).Round(time.Millisecond))
	return 0
}
