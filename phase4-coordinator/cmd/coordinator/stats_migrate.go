package main

// SPEC-017 / SPEC-MALIBU-EMISSION-LEDGER — operator migration CLI:
//
//	coordinator stats-migrate [--admin-dsn DSN] [--config path] [--check]
//
// Applies embedded stats/rewards Postgres migrations (schema_migrations_spec017)
// using an admin-capable DSN. Not invoked from the daemon path.

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	statsmigrations "github.com/augstar/macprovider-coordinator/internal/stats/migrations"

	_ "github.com/lib/pq"
)

func runStatsMigrate(args []string) int {
	return runStatsMigrateIO(args, os.Stdout, os.Stderr)
}

func runStatsMigrateIO(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("stats-migrate", flag.ContinueOnError)
	fs.SetOutput(stderr)
	adminDSNFlag := fs.String("admin-dsn", "", "operator admin DSN (overrides --config and "+adminDSNEnv+")")
	configPath := fs.String("config", "", "optional coordinator YAML (reads stats.partner_keys_admin_dsn when --admin-dsn unset)")
	check := fs.Bool("check", false, "report applied migration versions without mutating schema")
	timeout := fs.Duration("timeout", 10*time.Minute, "max time for migration apply")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	dsn, source, err := resolveAdminDSN(*adminDSNFlag, *configPath)
	if err != nil {
		fmt.Fprintf(stderr, "stats-migrate: %v\n", err)
		return 2
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		fmt.Fprintf(stderr, "stats-migrate: open db (%s): %v\n", source, err)
		return 1
	}
	defer db.Close()
	if err := db.PingContext(ctx); err != nil {
		fmt.Fprintf(stderr, "stats-migrate: ping db (%s): %v\n", source, err)
		return 1
	}

	all, err := statsmigrations.All()
	if err != nil {
		fmt.Fprintf(stderr, "stats-migrate: load migrations: %v\n", err)
		return 1
	}

	applied, err := queryAppliedMigrationVersions(ctx, db)
	if err != nil {
		fmt.Fprintf(stderr, "stats-migrate: read applied versions: %v\n", err)
		return 1
	}

	if *check {
		fmt.Fprintf(stdout, "stats-migrate check (%s): %d embedded, %d applied\n", source, len(all), len(applied))
		for _, m := range all {
			state := "pending"
			if applied[m.Version] {
				state = "applied"
			}
			fmt.Fprintf(stdout, "  %03d_%s %s\n", m.Version, m.Name, state)
		}
		return 0
	}

	started := time.Now()
	if err := statsmigrations.Apply(ctx, db); err != nil {
		fmt.Fprintf(stderr, "stats-migrate: apply failed: %v\n", err)
		return 1
	}
	appliedAfter, err := queryAppliedMigrationVersions(ctx, db)
	if err != nil {
		fmt.Fprintf(stderr, "stats-migrate: post-apply version read: %v\n", err)
		return 1
	}
	var pending int
	for _, m := range all {
		if !appliedAfter[m.Version] {
			pending++
		}
	}
	if pending > 0 {
		fmt.Fprintf(stderr, "stats-migrate: %d migration(s) still pending after apply\n", pending)
		return 1
	}
	fmt.Fprintf(stdout, "stats-migrate ok (%s, %s)\n", source, time.Since(started).Round(time.Millisecond))
	return 0
}

func queryAppliedMigrationVersions(ctx context.Context, db *sql.DB) (map[int]bool, error) {
	rows, err := db.QueryContext(ctx, `SELECT version FROM schema_migrations_spec017`)
	if err != nil {
		// Table may not exist before first migration.
		if strings.Contains(err.Error(), "does not exist") {
			return map[int]bool{}, nil
		}
		return nil, err
	}
	defer rows.Close()
	out := make(map[int]bool)
	for rows.Next() {
		var version int
		if err := rows.Scan(&version); err != nil {
			return nil, err
		}
		out[version] = true
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}
