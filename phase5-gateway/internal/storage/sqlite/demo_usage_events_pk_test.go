// Regression coverage for issue #210 — demo_usage_events PRIMARY KEY
// is (demo_token_hash, request_id). Pre-issue-#210 the PK was just
// (request_id), which let two demo identities (different
// demo_token_hash) collide on the same buyer-supplied X-Request-ID
// and lose the second identity's audit row.
//
// Sibling of [[usage_events_pk_test]] (#196) — same exploit class,
// different table.
package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestDemoUsageEventsCrossDemoCollisionInsertsBothRows(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	const sharedRequestID = "demo-shared-uuid-1"
	for _, demoHash := range []string{"demoHash_A", "demoHash_B"} {
		if err := store.EnsureDemoUsageEvent(ctx, storage.DemoUsageEvent{
			RequestID: sharedRequestID, ClientIP: "1.2.3.4",
			DemoTokenHash: demoHash, WindowDate: "2026-06-28", TotalTokens: 5,
			CreatedAt: fixedTime(),
		}); err != nil {
			t.Fatalf("EnsureDemoUsageEvent(%s): %v", demoHash, err)
		}
	}
	rows, err := store.db.QueryContext(ctx, `
		SELECT demo_token_hash, total_tokens FROM demo_usage_events
		WHERE request_id = ? ORDER BY demo_token_hash`, sharedRequestID)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	var got []struct {
		hash   string
		tokens int64
	}
	for rows.Next() {
		var s struct {
			hash   string
			tokens int64
		}
		if err := rows.Scan(&s.hash, &s.tokens); err != nil {
			t.Fatalf("scan: %v", err)
		}
		got = append(got, s)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 rows after cross-demo collision, got %d: %+v", len(got), got)
	}
	if got[0].hash != "demoHash_A" || got[1].hash != "demoHash_B" {
		t.Errorf("rows = %+v, want both demo hashes preserved", got)
	}
}

func TestDemoUsageEventsCompositePKUpgradeFromLegacyPK(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "legacy-demo-gateway.db")
	rawDB, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	legacyDDL := []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)`,
		`CREATE TABLE demo_usage_events (
			request_id TEXT PRIMARY KEY,
			client_ip TEXT NOT NULL,
			demo_token_hash TEXT NOT NULL,
			window_date TEXT NOT NULL,
			total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
			created_at TEXT NOT NULL
		)`,
		`CREATE INDEX idx_demo_usage_ip_token_date ON demo_usage_events(client_ip, demo_token_hash, window_date)`,
		`CREATE TRIGGER demo_usage_events_no_update BEFORE UPDATE ON demo_usage_events
			BEGIN SELECT RAISE(ABORT, 'demo_usage_events are append-only'); END`,
		`CREATE TRIGGER demo_usage_events_no_delete BEFORE DELETE ON demo_usage_events
			BEGIN SELECT RAISE(ABORT, 'demo_usage_events are append-only'); END`,
		`INSERT INTO schema_migrations VALUES (1, '2026-06-01T00:00:00Z')`,
		`INSERT INTO schema_migrations VALUES (2, '2026-06-15T00:00:00Z')`,
	}
	for _, d := range legacyDDL {
		if _, err := rawDB.ExecContext(ctx, d); err != nil {
			t.Fatalf("legacy DDL %q: %v", strings.SplitN(d, "(", 2)[0], err)
		}
	}
	// Seed two legacy rows (distinct request_ids — legacy PK forbids
	// sharing).
	for _, seed := range []struct{ req, hash string }{
		{"legacy-req-1", "demoHash_X"},
		{"legacy-req-2", "demoHash_Y"},
	} {
		if _, err := rawDB.ExecContext(ctx, `
			INSERT INTO demo_usage_events(request_id, client_ip, demo_token_hash, window_date, total_tokens, created_at)
			VALUES(?, '5.6.7.8', ?, '2026-06-27', 10, '2026-06-27T00:00:00Z')`,
			seed.req, seed.hash); err != nil {
			t.Fatalf("seed %s: %v", seed.req, err)
		}
	}
	// Also need usage_events table for the parallel migration to find.
	if _, err := rawDB.ExecContext(ctx, `CREATE TABLE usage_events (
		request_id TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		demo_identity TEXT NOT NULL DEFAULT '',
		window_date TEXT NOT NULL,
		prompt_tokens INTEGER NOT NULL CHECK (prompt_tokens >= 0),
		completion_tokens INTEGER NOT NULL CHECK (completion_tokens >= 0),
		total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
		token_source TEXT NOT NULL CHECK (token_source IN ('provider_reported', 'gateway_estimated', 'manual_fixture')),
		outcome TEXT NOT NULL,
		created_at TEXT NOT NULL
	)`); err != nil {
		t.Fatalf("legacy usage_events: %v", err)
	}
	if err := rawDB.Close(); err != nil {
		t.Fatalf("close legacy db: %v", err)
	}

	store, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open (triggers migration): %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	// Composite PK installed.
	pkCols := readPKColumns(t, store, "demo_usage_events")
	if !(len(pkCols) == 2 && pkCols[0] == "demo_token_hash" && pkCols[1] == "request_id") {
		t.Fatalf("post-migration PK = %v, want [demo_token_hash request_id]", pkCols)
	}

	// Rows preserved.
	var n int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM demo_usage_events`).Scan(&n); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	if n != 2 {
		t.Errorf("rows preserved = %d, want 2", n)
	}

	// v3 stamp atomic with rebuild.
	var maxVer sql.NullInt64
	if err := store.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&maxVer); err != nil {
		t.Fatalf("read schema_migrations: %v", err)
	}
	if !maxVer.Valid || maxVer.Int64 < 3 {
		t.Errorf("schema_migrations max version = %v, want >= 3", maxVer)
	}

	// Append-only DELETE trigger preserved.
	if _, err := store.db.ExecContext(ctx,
		`DELETE FROM demo_usage_events WHERE request_id = 'legacy-req-1'`); err == nil {
		t.Fatal("DELETE on demo_usage_events after migration unexpectedly succeeded")
	}

	// Cross-demo collision now works.
	if err := store.EnsureDemoUsageEvent(ctx, storage.DemoUsageEvent{
		RequestID: "post-mig-shared", ClientIP: "9.9.9.9",
		DemoTokenHash: "demoHash_A", WindowDate: "2026-06-28", TotalTokens: 1,
		CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("post-migration insert A: %v", err)
	}
	if err := store.EnsureDemoUsageEvent(ctx, storage.DemoUsageEvent{
		RequestID: "post-mig-shared", ClientIP: "9.9.9.9",
		DemoTokenHash: "demoHash_B", WindowDate: "2026-06-28", TotalTokens: 2,
		CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("post-migration cross-demo insert B: %v", err)
	}
}

func TestDemoUsageEventsSqliteMasterByteIdenticalAcrossPaths(t *testing.T) {
	ctx := context.Background()
	fresh := newTestStore(t)
	freshMaster := readDemoUsageEventsMaster(t, fresh)

	path := filepath.Join(t.TempDir(), "migrated-demo-gateway.db")
	rawDB, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	legacyDDL := []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)`,
		`CREATE TABLE usage_events (
			request_id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			demo_identity TEXT NOT NULL DEFAULT '',
			window_date TEXT NOT NULL,
			prompt_tokens INTEGER NOT NULL CHECK (prompt_tokens >= 0),
			completion_tokens INTEGER NOT NULL CHECK (completion_tokens >= 0),
			total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
			token_source TEXT NOT NULL CHECK (token_source IN ('provider_reported', 'gateway_estimated', 'manual_fixture')),
			outcome TEXT NOT NULL,
			created_at TEXT NOT NULL
		)`,
		`CREATE TABLE demo_usage_events (
			request_id TEXT PRIMARY KEY,
			client_ip TEXT NOT NULL,
			demo_token_hash TEXT NOT NULL,
			window_date TEXT NOT NULL,
			total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
			created_at TEXT NOT NULL
		)`,
		`CREATE INDEX idx_demo_usage_ip_token_date ON demo_usage_events(client_ip, demo_token_hash, window_date)`,
		`CREATE TRIGGER demo_usage_events_no_update BEFORE UPDATE ON demo_usage_events
			BEGIN SELECT RAISE(ABORT, 'demo_usage_events are append-only'); END`,
		`CREATE TRIGGER demo_usage_events_no_delete BEFORE DELETE ON demo_usage_events
			BEGIN SELECT RAISE(ABORT, 'demo_usage_events are append-only'); END`,
	}
	for _, d := range legacyDDL {
		if _, err := rawDB.ExecContext(ctx, d); err != nil {
			t.Fatalf("legacy DDL: %v", err)
		}
	}
	if err := rawDB.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	migrated, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = migrated.Close() })
	migratedMaster := readDemoUsageEventsMaster(t, migrated)

	if len(freshMaster) != len(migratedMaster) {
		t.Fatalf("master row counts differ: fresh=%d migrated=%d", len(freshMaster), len(migratedMaster))
	}
	for name, freshSQL := range freshMaster {
		migSQL, ok := migratedMaster[name]
		if !ok {
			t.Errorf("migrated master missing %q", name)
			continue
		}
		if freshSQL != migSQL {
			t.Errorf("sqlite_master.sql diverges for %q\n  fresh:    %q\n  migrated: %q", name, freshSQL, migSQL)
		}
	}
}

func readDemoUsageEventsMaster(t *testing.T, store *Store) map[string]string {
	t.Helper()
	rows, err := store.db.QueryContext(context.Background(), `
		SELECT name, COALESCE(sql, '') FROM sqlite_master
		WHERE tbl_name = 'demo_usage_events' AND name NOT LIKE 'sqlite_autoindex_%'
		ORDER BY name`)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var name, sqlText string
		if err := rows.Scan(&name, &sqlText); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out[name] = sqlText
	}
	return out
}

// Silence unused-import linter if errors not used in any case path.
var _ = errors.Is
