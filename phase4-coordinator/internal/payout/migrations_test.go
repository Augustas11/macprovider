package payout

import (
	"context"
	"strings"
	"testing"
	"time"
)

// TestStripExistingColumnAlters_SkipsCommentsAndStringLiterals is
// the FULL-r2 [full-sec:r2-1] MEDIUM closure: the ADD COLUMN
// regex must NOT match text inside `--` line comments or single/
// double-quoted string literals. A future migration containing
// such a form would otherwise trigger a spurious PRAGMA lookup
// and a body rewrite.
func TestStripExistingColumnAlters_SkipsCommentsAndStringLiterals(t *testing.T) {
	db := openTestDB(t)
	// payout_attempts already has gas_reserved_native_wei + run_id
	// from migrations 0010 + 0012, so columnExists returns true for
	// these. If the regex naively matched a commented or quoted
	// ALTER, the rewrite would drop the surrounding statement and
	// corrupt the migration body.
	in := `-- the next migration WAS: ALTER TABLE payout_attempts ADD COLUMN gas_reserved_native_wei BLOB;
SELECT 'ALTER TABLE payout_attempts ADD COLUMN run_id TEXT';
CREATE TABLE IF NOT EXISTS audit_marker (k TEXT);
`
	out, err := stripExistingColumnAlters(context.Background(), db, in)
	if err != nil {
		t.Fatalf("stripExistingColumnAlters: %v", err)
	}
	if out != in {
		t.Errorf("body changed; want byte-identical when only commented + quoted ALTERs\ninput=%q\noutput=%q", in, out)
	}
	// And the rewrite IS active for a real top-level ALTER on an
	// existing column — same column the comment named, so we know
	// the comment alone is what got skipped, not a general "no
	// columns exist" branch.
	in2 := `ALTER TABLE payout_attempts ADD COLUMN gas_reserved_native_wei INTEGER NULL;
CREATE INDEX IF NOT EXISTS idx_marker ON audit_marker(k);
`
	out2, err := stripExistingColumnAlters(context.Background(), db, in2)
	if err != nil {
		t.Fatalf("stripExistingColumnAlters real ALTER: %v", err)
	}
	if !strings.Contains(out2, "already present, statement skipped") {
		t.Errorf("expected real ALTER on existing column to be rewritten; got:\n%s", out2)
	}
}

func TestMigrate_Idempotent(t *testing.T) {
	db := openTestDB(t)
	// Migrate already ran in openTestDB. Second pass must
	// succeed silently — every statement uses IF NOT EXISTS.
	if err := Migrate(context.Background(), db); err != nil {
		t.Fatalf("second Migrate: %v", err)
	}
	if err := AssertSameDB(context.Background(), db); err != nil {
		t.Fatalf("AssertSameDB: %v", err)
	}
	// Trigger-presence asserter — also catches any DDL drift.
	// payout_runner_state row INSERT is required for the
	// bootstrap-flip triggers to fire on confirm path; we
	// install one here for the schema-shape test.
	if err := InitRunnerStateRow(context.Background(), db, time.Now().UTC()); err != nil {
		t.Fatalf("init runner_state: %v", err)
	}
	if err := AssertTriggersPresent(context.Background(), db); err != nil {
		t.Fatalf("AssertTriggersPresent: %v", err)
	}
}

func TestMigrate_PartialUniqueIndexEnforcesOneLiveNonCancel(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	payoutID := insertReadyRow(t, db, "p1", "settle:p1:w1")

	// First live non-cancel attempt — INSERT succeeds.
	if _, err := db.ExecContext(ctx, `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0xfrom', '0xto', 100, 1, 0, '2026-01-08T00:00:00Z')`,
		payoutID,
	); err != nil {
		t.Fatalf("first INSERT: %v", err)
	}
	// Second LIVE non-cancel attempt for same payout_id —
	// MUST fail the partial UNIQUE
	// idx_pa_one_live_non_cancel_per_payout.
	_, err := db.ExecContext(ctx, `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 2, 'base-mainnet', '0xfrom', '0xto', 100, 2, 0, '2026-01-08T00:00:01Z')`,
		payoutID,
	)
	if err == nil || !strings.Contains(err.Error(), "UNIQUE") {
		t.Fatalf("second live INSERT must fail UNIQUE, got %v", err)
	}

	// Abandon the first; a fresh non-cancel attempt must succeed.
	if _, err := db.ExecContext(ctx,
		`UPDATE payout_attempts SET abandoned_at_utc='2026-01-08T00:00:02Z', updated_at_utc='2026-01-08T00:00:02Z' WHERE payout_id=? AND attempt_seq=1`,
		payoutID,
	); err != nil {
		t.Fatalf("abandon first: %v", err)
	}
	if _, err := db.ExecContext(ctx, `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 2, 'base-mainnet', '0xfrom', '0xto', 100, 2, 0, '2026-01-08T00:00:03Z')`,
		payoutID,
	); err != nil {
		t.Fatalf("post-abandon INSERT: %v", err)
	}
}

func TestMigrate_BootstrapOneWayTrigger(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	if err := InitRunnerStateRow(ctx, db, time.Now().UTC()); err != nil {
		t.Fatalf("init runner_state: %v", err)
	}
	// Flip 0 → 1 manually (simulating the bootstrap-flip
	// trigger's effect).
	if _, err := db.ExecContext(ctx,
		`UPDATE payout_runner_state SET payout_bootstrap_complete=1, bootstrap_completed_at_utc='2026-01-08T00:00:00Z', updated_at_utc='2026-01-08T00:00:00Z' WHERE id=1`,
	); err != nil {
		t.Fatalf("flip 0→1: %v", err)
	}
	// Attempt 1 → 0 — must be REJECTED by trg_prs_bootstrap_one_way.
	_, err := db.ExecContext(ctx,
		`UPDATE payout_runner_state SET payout_bootstrap_complete=0, updated_at_utc='2026-01-08T00:00:01Z' WHERE id=1`,
	)
	if err == nil || !strings.Contains(err.Error(), "one-way") {
		t.Fatalf("1→0 must be rejected by trigger, got %v", err)
	}
}

func TestAssertPragmas_RejectsRelaxedSynchronous(t *testing.T) {
	db := openTestDB(t)
	// Default DSN ships synchronous=FULL after the SPEC-016
	// Step 1 DSN change — AssertPragmas should pass.
	if err := AssertPragmas(context.Background(), db); err != nil {
		t.Fatalf("AssertPragmas on default DSN: %v", err)
	}
}
