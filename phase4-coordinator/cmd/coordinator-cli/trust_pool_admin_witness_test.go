package main

import (
	"bytes"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	_ "modernc.org/sqlite"
)

func TestTrustPoolAdminManifestWitnessInitFlagValidation(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"missing db", []string{"--out", filepath.Join(dir, "w.json")}, "--db is required"},
		{"missing out", []string{"--db", dbPath}, "--out is required"},
		{"relative out", []string{"--db", dbPath, "--out", "w.json"}, "--out must be an absolute path"},
		{"missing db file", []string{"--db", filepath.Join(dir, "absent.db"), "--out", filepath.Join(dir, "w.json")}, "absent.db"},
		{"positional", []string{"--db", dbPath, "--out", filepath.Join(dir, "w.json"), "extra"}, "unexpected positional arguments"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			err := trustPoolAdmin(append([]string{"manifest-witness-init"}, tc.args...), func(string) string { return "" }, strings.NewReader(""), &out)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err=%v, want %q", err, tc.want)
			}
		})
	}
	if _, err := os.Stat(filepath.Join(dir, "absent.db")); !os.IsNotExist(err) {
		t.Fatalf("missing DB path was created: %v", err)
	}
}

func TestTrustPoolAdminManifestWitnessInitWritesOnceReadOnly(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	if _, err := trustpool.NewStore(db); err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	witnessPath := filepath.Join(dir, "witness.json")
	args := []string{"manifest-witness-init", "--db", dbPath, "--out", witnessPath}
	var out bytes.Buffer
	if err := trustPoolAdmin(args, func(string) string { return "" }, strings.NewReader(""), &out); err != nil {
		t.Fatalf("manifest-witness-init: %v", err)
	}
	if !strings.Contains(out.String(), "pools=0") {
		t.Fatalf("output=%q, want pools=0", out.String())
	}
	if _, err := trustpool.NewStore(db, trustpool.WithManifestAcceptanceWitnessPath(witnessPath)); err != nil {
		t.Fatalf("NewStore with witness: %v", err)
	}
	out.Reset()
	if err := trustPoolAdmin(args, func(string) string { return "" }, strings.NewReader(""), &out); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("second run err=%v, want already exists", err)
	}
}
