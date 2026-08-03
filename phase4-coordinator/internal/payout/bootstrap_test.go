package payout

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

func quietLogger() (zerolog.Logger, *bytes.Buffer) {
	buf := &bytes.Buffer{}
	logger := zerolog.New(io.Writer(buf))
	return logger, buf
}

func TestBootstrapRuntimeFlags_FirstEverInit_SeedsAndSetsSentinel(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	ctx := context.Background()
	if err := BootstrapRuntimeFlags(ctx, db, time.Now().UTC(), logger); err != nil {
		t.Fatalf("first-ever bootstrap: %v", err)
	}
	// Sentinel row.
	var sentinelCount int
	if err := db.QueryRowContext(ctx, `SELECT count(*) FROM runtime_flags_bootstrapped`).Scan(&sentinelCount); err != nil {
		t.Fatalf("sentinel count: %v", err)
	}
	if sentinelCount != 1 {
		t.Fatalf("sentinel count = %d, want 1", sentinelCount)
	}
	// registration_paused row.
	var pauseValue int
	var pauseActor string
	if err := db.QueryRowContext(ctx,
		`SELECT value, updated_by_actor FROM runtime_flags WHERE name='registration_paused'`,
	).Scan(&pauseValue, &pauseActor); err != nil {
		t.Fatalf("flag scan: %v", err)
	}
	if pauseValue != 0 || pauseActor != "system:bootstrap_seed" {
		t.Fatalf("seeded flag wrong: value=%d actor=%q", pauseValue, pauseActor)
	}
}

func TestBootstrapRuntimeFlags_NormalRestart_DoesNotReseed(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	ctx := context.Background()
	if err := BootstrapRuntimeFlags(ctx, db, time.Now().UTC(), logger); err != nil {
		t.Fatalf("first bootstrap: %v", err)
	}
	// Operator flips registration_paused to 1 out-of-band.
	if _, err := db.ExecContext(ctx,
		`UPDATE runtime_flags SET value=1, updated_at_utc='2026-01-08T00:00:00Z', updated_by_actor='operator_key:test', updated_reason='test' WHERE name='registration_paused'`,
	); err != nil {
		t.Fatalf("operator flip: %v", err)
	}
	// Restart bootstrap: must NOT reset the flag.
	if err := BootstrapRuntimeFlags(ctx, db, time.Now().UTC(), logger); err != nil {
		t.Fatalf("restart bootstrap: %v", err)
	}
	var v int
	if err := db.QueryRowContext(ctx, `SELECT value FROM runtime_flags WHERE name='registration_paused'`).Scan(&v); err != nil {
		t.Fatalf("post-restart scan: %v", err)
	}
	if v != 1 {
		t.Fatalf("operator-set value clobbered; got %d, want 1", v)
	}
}

func TestBootstrapRuntimeFlags_SentinelMissingFlagPresent_Halts(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	ctx := context.Background()
	if err := BootstrapRuntimeFlags(ctx, db, time.Now().UTC(), logger); err != nil {
		t.Fatalf("first bootstrap: %v", err)
	}
	// Delete the sentinel — simulating tamper / partial restore.
	if _, err := db.ExecContext(ctx, `DELETE FROM runtime_flags_bootstrapped`); err != nil {
		t.Fatalf("delete sentinel: %v", err)
	}
	err := BootstrapRuntimeFlags(ctx, db, time.Now().UTC(), logger)
	if err == nil {
		t.Fatal("expected sentinel-missing HALT, got nil")
	}
	var v InvariantViolation
	if !errors.As(err, &v) {
		t.Fatalf("expected InvariantViolation, got %T: %v", err, err)
	}
	if !strings.Contains(v.Where, "sentinel_missing") {
		t.Fatalf("wrong where=%q", v.Where)
	}
}

func TestBootstrapRuntimeFlags_SentinelPresentFlagMissing_Halts(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	ctx := context.Background()
	if err := BootstrapRuntimeFlags(ctx, db, time.Now().UTC(), logger); err != nil {
		t.Fatalf("first bootstrap: %v", err)
	}
	// Delete the closed-set flag while leaving the sentinel.
	if _, err := db.ExecContext(ctx, `DELETE FROM runtime_flags WHERE name='registration_paused'`); err != nil {
		t.Fatalf("delete flag: %v", err)
	}
	err := BootstrapRuntimeFlags(ctx, db, time.Now().UTC(), logger)
	if err == nil {
		t.Fatal("expected runtime_flag-missing HALT, got nil")
	}
	var v InvariantViolation
	if !errors.As(err, &v) {
		t.Fatalf("expected InvariantViolation, got %T: %v", err, err)
	}
	if v.Where != "runtime_flag missing" || v.Name != "registration_paused" {
		t.Fatalf("wrong where=%q name=%q", v.Where, v.Name)
	}
}

func TestInitRunnerStateRow_Idempotent(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	if err := InitRunnerStateRow(ctx, db, time.Now().UTC()); err != nil {
		t.Fatalf("first init: %v", err)
	}
	// Mutate updated_at_utc, then re-init — INSERT OR IGNORE must not
	// clobber the existing row.
	const mutated = "2099-01-01T00:00:00Z"
	if _, err := db.ExecContext(ctx, `UPDATE payout_runner_state SET updated_at_utc=? WHERE id=1`, mutated); err != nil {
		t.Fatalf("mutate: %v", err)
	}
	if err := InitRunnerStateRow(ctx, db, time.Now().UTC()); err != nil {
		t.Fatalf("second init: %v", err)
	}
	var got string
	if err := db.QueryRowContext(ctx, `SELECT updated_at_utc FROM payout_runner_state WHERE id=1`).Scan(&got); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if got != mutated {
		t.Fatalf("INSERT OR IGNORE clobbered row: got %q, want %q", got, mutated)
	}
}
