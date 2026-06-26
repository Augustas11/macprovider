// Package migrations embeds and applies the SPEC-017 schema +
// grant migrations. Step 1 IS the migration surface; Steps 2/3/4
// run on top of it.
//
// The runner is minimal-by-design:
//   - Migrations are embedded via //go:embed so deployed binaries
//     do not depend on a filesystem path for SQL files.
//   - Each file runs inside a single transaction so a failed
//     migration cannot leave the DB in an intermediate state.
//   - Version tracking lives in schema_migrations(version, name,
//     applied_at) which is created if missing on first run.
//   - Running the migrations twice is a no-op (idempotent).
//
// Filename convention: NNN_<snake_case_name>.up.sql, sorted
// lexicographically. Down migrations are intentionally not
// supported in v0.1 — Step 1 is creation only per BUILD §F.1.
package migrations

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
)

//go:embed *.up.sql
var migrationFS embed.FS

const versionTableDDL = `
CREATE TABLE IF NOT EXISTS schema_migrations_spec017 (
    version    INT PRIMARY KEY,
    name       TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
`

// Migration represents one parsed .up.sql file.
type Migration struct {
	Version int
	Name    string
	SQL     string
}

// All returns the embedded migrations sorted by version. The
// caller MAY range over the slice for diagnostic logging; Apply
// loads them itself.
func All() ([]Migration, error) {
	entries, err := fs.ReadDir(migrationFS, ".")
	if err != nil {
		return nil, fmt.Errorf("read embedded migration dir: %w", err)
	}
	out := make([]Migration, 0, len(entries))
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".up.sql") {
			continue
		}
		ver, displayName, err := parseFilename(name)
		if err != nil {
			return nil, err
		}
		body, err := fs.ReadFile(migrationFS, name)
		if err != nil {
			return nil, fmt.Errorf("read embedded migration %s: %w", name, err)
		}
		out = append(out, Migration{
			Version: ver,
			Name:    displayName,
			SQL:     string(body),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Version < out[j].Version })
	return out, nil
}

func parseFilename(name string) (int, string, error) {
	base := strings.TrimSuffix(name, ".up.sql")
	parts := strings.SplitN(base, "_", 2)
	if len(parts) != 2 {
		return 0, "", fmt.Errorf("migration filename %q must be NNN_<name>.up.sql", name)
	}
	ver, err := strconv.Atoi(parts[0])
	if err != nil {
		return 0, "", fmt.Errorf("migration filename %q has non-integer version: %w", name, err)
	}
	return ver, parts[1], nil
}

// Apply runs every embedded migration not yet recorded in
// schema_migrations_spec017, in version order, each inside its
// own transaction.
//
// The caller MUST pass a connection authenticated as a role with
// CREATE / GRANT / REVOKE privileges on the public schema. The
// four runtime roles (stats_reader, stats_rollup, provider_portal,
// partner_keys_writer) are NOT migration-capable — using one of
// them here would either fail or improperly widen privileges
// (BUILD §F.2 SECURITY invariant).
func Apply(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, versionTableDDL); err != nil {
		return fmt.Errorf("create schema_migrations_spec017: %w", err)
	}

	applied, err := loadApplied(ctx, db)
	if err != nil {
		return err
	}

	migrations, err := All()
	if err != nil {
		return err
	}

	for _, m := range migrations {
		if _, ok := applied[m.Version]; ok {
			continue
		}
		if err := applyOne(ctx, db, m); err != nil {
			return fmt.Errorf("migration %03d_%s: %w", m.Version, m.Name, err)
		}
	}
	return nil
}

func loadApplied(ctx context.Context, db *sql.DB) (map[int]struct{}, error) {
	rows, err := db.QueryContext(ctx, `SELECT version FROM schema_migrations_spec017`)
	if err != nil {
		return nil, fmt.Errorf("query schema_migrations_spec017: %w", err)
	}
	defer rows.Close()
	out := make(map[int]struct{})
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			return nil, fmt.Errorf("scan applied row: %w", err)
		}
		out[v] = struct{}{}
	}
	return out, rows.Err()
}

func applyOne(ctx context.Context, db *sql.DB, m Migration) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	// The defer pattern below is the standard "rollback on any
	// error, commit on success" — committed transactions ignore
	// the rollback (it returns sql.ErrTxDone, which is fine).
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	if _, err := tx.ExecContext(ctx, m.SQL); err != nil {
		return fmt.Errorf("exec body: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO schema_migrations_spec017 (version, name) VALUES ($1, $2)`,
		m.Version, m.Name,
	); err != nil {
		return fmt.Errorf("record version: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	committed = true
	return nil
}
