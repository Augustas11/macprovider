package payout

import (
	"context"
	"errors"
	"testing"
	"time"
)

const testRunInterval = 5 * time.Minute

func TestAcquire_FreshHappyPath(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	state, takeover, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if takeover {
		t.Error("fresh acquire should NOT be a takeover")
	}
	if len(state.HolderToken) != 32 {
		t.Errorf("token length = %d, want 32 (16 bytes hex)", len(state.HolderToken))
	}
	if err := SelfFence(context.Background(), db, state); err != nil {
		t.Errorf("SelfFence on fresh lease: %v", err)
	}
}

func TestAcquire_ConflictOnFreshHolder(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	state1, _, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire #1: %v", err)
	}
	_ = state1
	// Second Acquire should conflict — heartbeat is fresh.
	_, _, err = Acquire(context.Background(), db, testRunInterval, logger)
	if err == nil {
		t.Fatal("second Acquire should conflict")
	}
	if !errors.Is(err, ErrLeaseConflict) {
		t.Errorf("err = %v, want ErrLeaseConflict", err)
	}
}

func TestAcquire_TakeoverOnStaleHolder(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	state1, _, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire #1: %v", err)
	}
	// Backdate the heartbeat beyond the 3× window.
	stale := time.Now().Add(-30 * time.Minute).UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(context.Background(),
		`UPDATE payout_runner_lease SET heartbeat_at_utc = ? WHERE id = 1`, stale,
	); err != nil {
		t.Fatalf("backdate heartbeat: %v", err)
	}
	state2, takeover, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire takeover: %v", err)
	}
	if !takeover {
		t.Error("stale-holder Acquire should be a takeover")
	}
	if state2.HolderToken == state1.HolderToken {
		t.Error("takeover should rotate holder_token")
	}
	// First state's SelfFence should now fail.
	if err := SelfFence(context.Background(), db, state1); !errors.Is(err, ErrLeaseLost) {
		t.Errorf("prior holder SelfFence err = %v, want ErrLeaseLost", err)
	}
}

func TestHeartbeat_RefreshesHolder(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	state, _, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := Heartbeat(context.Background(), db, state, logger); err != nil {
		t.Errorf("Heartbeat: %v", err)
	}
}

func TestHeartbeat_LeaseLost(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	state, _, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	// Manually overwrite holder_token to simulate a takeover.
	if _, err := db.ExecContext(context.Background(),
		`UPDATE payout_runner_lease SET holder_token = 'other' WHERE id = 1`,
	); err != nil {
		t.Fatalf("clobber token: %v", err)
	}
	if err := Heartbeat(context.Background(), db, state, logger); !errors.Is(err, ErrLeaseLost) {
		t.Errorf("Heartbeat err = %v, want ErrLeaseLost", err)
	}
}

func TestRelease_DeletesRow(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	state, _, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := Release(context.Background(), db, state, logger); err != nil {
		t.Fatalf("Release: %v", err)
	}
	// Subsequent fresh Acquire should succeed without takeover.
	state2, takeover, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire after Release: %v", err)
	}
	if takeover {
		t.Error("after Release, fresh Acquire should NOT be a takeover")
	}
	if state2.HolderToken == state.HolderToken {
		t.Error("post-release Acquire should mint a fresh token")
	}
}

func TestIsLeaseActive(t *testing.T) {
	db := openTestDB(t)
	logger, _ := quietLogger()
	_, _, _ = Acquire(context.Background(), db, testRunInterval, logger)
	// Acquire a sql.Conn for the helper.
	conn, _ := db.Conn(context.Background())
	defer conn.Close()
	active, err := IsLeaseActive(context.Background(), conn, testRunInterval)
	if err != nil {
		t.Fatalf("IsLeaseActive: %v", err)
	}
	if !active {
		t.Error("fresh lease should be active")
	}
	stale := time.Now().Add(-30 * time.Minute).UTC().Format(time.RFC3339Nano)
	_, _ = db.ExecContext(context.Background(),
		`UPDATE payout_runner_lease SET heartbeat_at_utc = ? WHERE id = 1`, stale)
	active, _ = IsLeaseActive(context.Background(), conn, testRunInterval)
	if active {
		t.Error("stale lease should NOT be active")
	}
}
