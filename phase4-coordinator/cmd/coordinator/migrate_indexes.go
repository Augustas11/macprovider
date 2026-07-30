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
	"encoding/json"
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
	// SPEC-002 v1.5.1 R-2 / issue #197: --check reports per-key
	// migration state without mutating the schema. Intended for
	// reconciliation tooling and operator dashboards.
	check := fs.Bool("check", false, "report migration state without building indexes")
	format := fs.String("format", "text", "output format when --check is set: text|json")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	// SPEC-002 v1.5.1 R-2 / issue #197 R2 code: validate --format BEFORE
	// touching the store so an invalid --format never causes an open
	// that could trigger ALTER TABLE on a legacy DB.
	if *check {
		switch *format {
		case "json", "text", "":
		default:
			fmt.Fprintf(stderr, "unknown --format %q (want text|json)\n", *format)
			return 2
		}
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		fmt.Fprintf(stderr, "config: %v\n", err)
		return 1
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	if *check {
		// Read-only path: do NOT run migrations. A legacy DB MUST be
		// observable as state `legacy` here; otherwise the operator
		// can't tell whether they need to run the daemon first.
		store, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
		if err != nil {
			fmt.Fprintf(stderr, "open request_log store (ro): %v\n", err)
			return 1
		}
		defer store.Close()
		status, err := store.MigrationState(ctx)
		if err != nil {
			fmt.Fprintf(stderr, "MigrationState: %v\n", err)
			return 1
		}
		switch *format {
		case "json":
			enc := json.NewEncoder(stdout)
			enc.SetIndent("", "  ")
			if err := enc.Encode(status); err != nil {
				fmt.Fprintf(stderr, "encode json: %v\n", err)
				return 1
			}
		case "text", "":
			fmt.Fprintf(stdout, "migration_state: %s\n", status.Aggregate)
			for _, k := range status.Keys {
				fmt.Fprintf(stdout, "  %s: %s (columns_present=%t index=%s index_present=%t)\n",
					k.Key, k.State, k.ColumnsPresent, k.IndexName, k.IndexPresent)
			}
		}
		return 0
	}

	store, err := requestlog.OpenStore(cfg.Storage.DBPath)
	if err != nil {
		fmt.Fprintf(stderr, "open request_log store: %v\n", err)
		return 1
	}
	defer store.Close()

	started := time.Now()
	if err := store.MigrateIndexes(ctx); err != nil {
		fmt.Fprintf(stderr, "MigrateIndexes: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "migrate-indexes ok (%s)\n", time.Since(started).Round(time.Millisecond))
	return 0
}
