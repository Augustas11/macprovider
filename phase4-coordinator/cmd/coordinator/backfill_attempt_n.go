package main

// SPEC-002 v1.5.2 / issue #168: operator-runbook subcommand
//
//	coordinator backfill-attempt-n --config <path>
//
// One-shot UPDATE to populate request_log.attempt_n for legacy
// pre-v1.5.2 rows. The column is added by daemon startup
// (ensureColumns); rows written before v1.5.2 carry NULL. This
// subcommand walks rows in id-ASC order within each
// (account_id, request_id) group under SQLite IS semantics and
// assigns attempt_n monotonically — byte-identical to the v0.3.1
// read-time fallback derivation, persisted once so the read paths
// can use the column directly.
//
// Idempotent: rows with non-NULL attempt_n are skipped. Safe to
// re-run.
//
// `--check --format=text|json` reports migration state without
// mutating the schema:
//   - legacy: column absent
//   - populating: column present, some rows still NULL
//   - populated: column present, zero NULL rows
//
// Intentionally NOT invoked from the daemon path: the request-log
// store caps the pool at one writer connection (issue #21 / ARCH-3),
// so running this inside the daemon would contend with the 6s
// INSERT timeout on the hot path.

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func runBackfillAttemptN(args []string) int {
	return runBackfillAttemptNIO(args, os.Stdout, os.Stderr)
}

func runBackfillAttemptNIO(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("backfill-attempt-n", flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", "coordinator.yaml", "path to coordinator YAML config")
	timeout := fs.Duration("timeout", 30*time.Minute, "max time the backfill may run")
	check := fs.Bool("check", false, "report migration state without backfilling")
	dryRun := fs.Bool("dry-run", false, "preflight: execute the backfill UPDATE inside a transaction and ROLLBACK, reporting rows-that-would-be-updated and wall-clock so operators can measure against the 6s hot-path INSERT budget before committing live. Mutually exclusive with --check.")
	format := fs.String("format", "text", "output format when --check is set: text|json")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *check && *dryRun {
		fmt.Fprintln(stderr, "--check and --dry-run are mutually exclusive")
		return 2
	}
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
		store, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
		if err != nil {
			fmt.Fprintf(stderr, "open request_log (ro): %v\n", err)
			return 1
		}
		defer store.Close()
		status, err := store.AttemptNState(ctx)
		if err != nil {
			fmt.Fprintf(stderr, "AttemptNState: %v\n", err)
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
			fmt.Fprintf(stdout, "migration_state: %s\n  null_count: %d\n  total_count: %d\n",
				status.MigrationState, status.NullCount, status.TotalCount)
		}
		return 0
	}

	store, err := requestlog.OpenStore(cfg.Storage.DBPath)
	if err != nil {
		fmt.Fprintf(stderr, "open request_log: %v\n", err)
		return 1
	}
	defer store.Close()

	if *dryRun {
		started := time.Now()
		wouldUpdate, err := store.BackfillAttemptNDryRun(ctx)
		if err != nil {
			fmt.Fprintf(stderr, "BackfillAttemptNDryRun: %v\n", err)
			return 1
		}
		elapsed := time.Since(started).Round(time.Millisecond)
		fmt.Fprintf(stdout, "backfill-attempt-n dry-run ok (would_update=%d, elapsed=%s)\n",
			wouldUpdate, elapsed)
		// Helper guidance for the operator: a healthy live run requires
		// elapsed << the 6s hot-path INSERT timeout.
		if elapsed > 4*time.Second {
			fmt.Fprintf(stdout, "WARNING: dry-run elapsed %s approaches the 6s hot-path INSERT timeout; consider running in a maintenance window\n", elapsed)
		}
		return 0
	}

	started := time.Now()
	updated, err := store.BackfillAttemptN(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "BackfillAttemptN: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "backfill-attempt-n ok (updated=%d, %s)\n",
		updated, time.Since(started).Round(time.Millisecond))
	return 0
}

// Compile-time check that sql.NullInt64 stays as expected.
var _ sql.NullInt64
