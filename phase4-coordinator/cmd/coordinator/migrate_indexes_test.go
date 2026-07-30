package main

// SPEC-002 v1.5.1 R-2 / issue #197 R2 code: `migrate-indexes --check`
// MUST be read-only — running the daemon's migrate() inside --check
// would silently advance a legacy DB to "unindexed" before reporting
// state, defeating the operator's ability to see the pre-migration
// state. This test pins that contract.

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// TestMigrateIndexesCheckIsReadOnly pre-seeds a legacy-schema
// request_log (no external_request_id / account_id columns) and runs
// the --check subcommand. The schema MUST be unchanged after the
// command exits, and the JSON output MUST report aggregate "legacy".
func TestMigrateIndexesCheckIsReadOnly(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	configPath := filepath.Join(dir, "coordinator.yaml")

	// Seed a legacy request_log: only the v1.0 columns the
	// coordinator originally shipped. external_request_id and
	// account_id are intentionally absent so MigrationState
	// reports state "legacy".
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open seed db: %v", err)
	}
	if _, err := db.ExecContext(context.Background(), `CREATE TABLE request_log (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		ts_utc TEXT NOT NULL,
		request_id TEXT NOT NULL,
		model TEXT NOT NULL
	)`); err != nil {
		t.Fatalf("seed legacy schema: %v", err)
	}
	_ = db.Close()

	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: "+dbPath+"\n"), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	var stdout, stderr bytes.Buffer
	rc := runMigrateIndexesIO([]string{"--config", configPath, "--check", "--format", "json"}, &stdout, &stderr)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, stderr.String())
	}

	var got struct {
		MigrationState string `json:"migration_state"`
		Keys           []struct {
			Key            string `json:"key"`
			ColumnsPresent bool   `json:"columns_present"`
			IndexPresent   bool   `json:"index_present"`
			State          string `json:"state"`
		} `json:"keys"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("decode json: %v\nstdout=%s", err, stdout.String())
	}
	if got.MigrationState != "legacy" {
		t.Fatalf("migration_state=%q, want legacy: stdout=%s", got.MigrationState, stdout.String())
	}
	if len(got.Keys) == 0 {
		t.Fatalf("keys empty: %s", stdout.String())
	}
	for _, k := range got.Keys {
		if k.State != "legacy" {
			t.Errorf("key %q state=%q, want legacy", k.Key, k.State)
		}
		if k.ColumnsPresent {
			t.Errorf("key %q columns_present=true on legacy schema", k.Key)
		}
		if k.IndexPresent {
			t.Errorf("key %q index_present=true on legacy schema", k.Key)
		}
	}

	// Critical assertion: --check did NOT run migrate(). Re-open
	// the raw DB and verify the legacy columns are still missing.
	db, err = sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("reopen db: %v", err)
	}
	defer db.Close()
	rows, err := db.QueryContext(context.Background(), `PRAGMA table_info(request_log)`)
	if err != nil {
		t.Fatalf("table_info: %v", err)
	}
	defer rows.Close()
	cols := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, ctype, dflt sql.NullString
		var notnull, pk int
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			t.Fatalf("scan: %v", err)
		}
		cols[name.String] = true
	}
	if cols["external_request_id"] {
		t.Errorf("--check mutated schema: external_request_id column present after read-only invocation")
	}
	if cols["account_id"] {
		t.Errorf("--check mutated schema: account_id column present after read-only invocation")
	}
}

// TestMigrateIndexesCheckRejectsBogusFormatBeforeOpen ensures the
// `--format` validation happens before OpenStore, so an invalid
// --format never triggers a write to the DB on a legacy schema.
func TestMigrateIndexesCheckRejectsBogusFormatBeforeOpen(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	configPath := filepath.Join(dir, "coordinator.yaml")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open seed db: %v", err)
	}
	if _, err := db.ExecContext(context.Background(), `CREATE TABLE request_log (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		ts_utc TEXT NOT NULL,
		request_id TEXT NOT NULL,
		model TEXT NOT NULL
	)`); err != nil {
		t.Fatalf("seed: %v", err)
	}
	_ = db.Close()
	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\nstorage:\n  db_path: "+dbPath+"\n"), 0o644); err != nil {
		t.Fatalf("config: %v", err)
	}

	var stdout, stderr bytes.Buffer
	rc := runMigrateIndexesIO([]string{"--config", configPath, "--check", "--format", "bogus"}, &stdout, &stderr)
	if rc != 2 {
		t.Fatalf("rc=%d, want 2 for bogus --format; stderr=%s", rc, stderr.String())
	}

	// Verify the legacy schema is still legacy.
	db, err = sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("reopen db: %v", err)
	}
	defer db.Close()
	rows, err := db.QueryContext(context.Background(), `PRAGMA table_info(request_log)`)
	if err != nil {
		t.Fatalf("table_info: %v", err)
	}
	defer rows.Close()
	cols := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, ctype, dflt sql.NullString
		var notnull, pk int
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			t.Fatalf("scan: %v", err)
		}
		cols[name.String] = true
	}
	if cols["external_request_id"] || cols["account_id"] {
		t.Errorf("bogus --format triggered schema migration before format validation")
	}
}
