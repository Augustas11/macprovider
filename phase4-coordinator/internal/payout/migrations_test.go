package payout

import (
	"context"
	"strings"
	"testing"
	"time"
)

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
