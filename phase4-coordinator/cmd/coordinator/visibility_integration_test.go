//go:build integration

package main

// SPEC-017 v0.1.8 Step 4.A — visibility revert CLI integration
// tests. Mirrors the partner-keys integration suite (same
// per-test Postgres container helper). The locked-AC invariant
// for this subcommand is AC-20: no row with
// `new_mode='exact' AND actor_kind='operator'` exists.

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"
)

func runVisibilityRevertT(args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := runVisibilityRevert(args, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

// ===========================================================================
// `visibility revert` on an 'exact' row succeeds → bucketed + audit row.
// ===========================================================================
func TestVisibilityRevertSuccess(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)

	// Seed an 'exact' row.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := adminDB.ExecContext(ctx,
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p1', 'exact')`,
	); err != nil {
		t.Fatalf("seed: %v", err)
	}

	code, stdout, stderr := runVisibilityRevertT(
		"--admin-dsn", fx.adminDSN(),
		"--id", "p1",
		"--reason", "test revert",
	)
	if code != 0 {
		t.Fatalf("revert exit=%d stderr=%q", code, stderr)
	}
	if !strings.Contains(stdout, "old_mode=exact new_mode=bucketed") {
		t.Errorf("stdout = %q; expected old=exact new=bucketed", stdout)
	}

	// Verify row + audit.
	var mode string
	if err := adminDB.QueryRowContext(ctx,
		`SELECT mode FROM provider_visibility WHERE provider_id='p1'`,
	).Scan(&mode); err != nil {
		t.Fatalf("select: %v", err)
	}
	if mode != "bucketed" {
		t.Errorf("mode = %q, want bucketed", mode)
	}

	var (
		oldMode, newMode, actorKind, actorID string
	)
	if err := adminDB.QueryRowContext(ctx,
		`SELECT old_mode, new_mode, actor_kind, actor_id
		   FROM provider_visibility_audit
		  WHERE provider_id='p1'
		  ORDER BY id DESC LIMIT 1`,
	).Scan(&oldMode, &newMode, &actorKind, &actorID); err != nil {
		t.Fatalf("select audit: %v", err)
	}
	if oldMode != "exact" || newMode != "bucketed" {
		t.Errorf("audit modes = %q/%q, want exact/bucketed", oldMode, newMode)
	}
	if actorKind != "operator" {
		t.Errorf("actor_kind = %q, want operator", actorKind)
	}
	if strings.TrimSpace(actorID) == "" {
		t.Errorf("actor_id must be non-empty")
	}
}

// ===========================================================================
// AC-20 — `visibility exact` verb is NOT supported; no path to write
// new_mode='exact' AND actor_kind='operator'.
// ===========================================================================
func TestVisibilityExactVerbHardRejected(t *testing.T) {
	code := runVisibility([]string{"exact", "--id", "p1", "--reason", "x"})
	if code == 0 {
		t.Fatalf("visibility exact verb should hard-reject; got exit=0")
	}
}

// ===========================================================================
// AC-20 SQL assertion — after a revert, no audit row with
// new_mode='exact' AND actor_kind='operator'.
// ===========================================================================
func TestAC20_NoOperatorExactRow(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Seed and revert.
	if _, err := adminDB.ExecContext(ctx,
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p2', 'exact')`,
	); err != nil {
		t.Fatalf("seed: %v", err)
	}
	code, _, stderr := runVisibilityRevertT(
		"--admin-dsn", fx.adminDSN(),
		"--id", "p2",
		"--reason", "test",
	)
	if code != 0 {
		t.Fatalf("revert exit=%d stderr=%q", code, stderr)
	}

	// AC-20 invariant.
	var count int
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM provider_visibility_audit
		  WHERE new_mode='exact' AND actor_kind='operator'`,
	).Scan(&count); err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 0 {
		t.Errorf("AC-20 violation: %d row(s) with new_mode='exact' AND actor_kind='operator'", count)
	}
}

// ===========================================================================
// Revert with no existing row → clean error, not a panic / silent insert.
// ===========================================================================
func TestVisibilityRevertNoRow(t *testing.T) {
	fx, _ := startCLIPostgres(t)
	code, _, stderr := runVisibilityRevertT(
		"--admin-dsn", fx.adminDSN(),
		"--id", "missing",
		"--reason", "x",
	)
	if code != 1 {
		t.Errorf("revert missing exit=%d want 1; stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, "no provider_visibility row") {
		t.Errorf("stderr should explain missing row; got %q", stderr)
	}
}

// ===========================================================================
// Revert on already-bucketed row → clean error, not a no-op audit row.
// ===========================================================================
func TestVisibilityRevertAlreadyBucketed(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := adminDB.ExecContext(ctx,
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p3', 'bucketed')`,
	); err != nil {
		t.Fatalf("seed: %v", err)
	}
	code, _, stderr := runVisibilityRevertT(
		"--admin-dsn", fx.adminDSN(),
		"--id", "p3",
		"--reason", "x",
	)
	if code != 1 {
		t.Errorf("revert already-bucketed exit=%d want 1; stderr=%q", code, stderr)
	}
	// No audit row should be written for this no-op case.
	var n int
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM provider_visibility_audit WHERE provider_id='p3'`,
	).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 0 {
		t.Errorf("audit row should NOT be inserted on no-op revert; got %d", n)
	}
}
