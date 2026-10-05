package sqlite

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// SPEC-022 R-13: the dispatch coverage proof is recorded once per relay-blind
// reservation, survives a restart, and is visible to the reconciler.
func TestRelayBlindSettlementDispatchRecordedOnceAndLoaded(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	createAccount(t, store, "acct_rb_mode")
	now := fixedTime()
	for _, requestID := range []string{"req_enforce", "req_observe", "req_unknown"} {
		if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
			AccountID: "acct_rb_mode", RequestID: requestID, WindowDate: now.Format("2006-01-02"),
			RequestedTokens: 20, DailyQuota: 100, CreatedAt: now, ExpiresAt: now.Add(time.Minute), RelayBlind: relayBlindTestMetadata(),
		}); err != nil {
			t.Fatal(err)
		}
		if err := store.MarkReservationSettlementHold(ctx, "acct_rb_mode", requestID); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.RecordRelayBlindSettlementDispatch(ctx, "acct_rb_mode", "req_enforce", storage.RelayBlindSettlementModeEnforce, ""); err == nil {
		t.Fatal("enforce record without an internal request id accepted")
	}
	if err := store.RecordRelayBlindSettlementDispatch(ctx, "acct_rb_mode", "req_enforce", storage.RelayBlindSettlementModeEnforce, "internal-1"); err != nil {
		t.Fatal(err)
	}
	if err := store.RecordRelayBlindSettlementDispatch(ctx, "acct_rb_mode", "req_enforce", storage.RelayBlindSettlementModeObserve, ""); err != nil {
		t.Fatal(err)
	}
	if err := store.RecordRelayBlindSettlementDispatch(ctx, "acct_rb_mode", "req_observe", storage.RelayBlindSettlementModeObserve, "ignored"); err != nil {
		t.Fatal(err)
	}
	if err := store.RecordRelayBlindSettlementDispatch(ctx, "acct_rb_mode", "req_missing", storage.RelayBlindSettlementModeObserve, ""); err != storage.ErrReservationNotFound {
		t.Fatalf("missing reservation err=%v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	held, err := store.ListSettlementHeldReservations(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string][2]string{}
	for _, reservation := range held {
		got[reservation.RequestID] = [2]string{reservation.RelayBlindSettlementMode, reservation.RelayBlindInternalRequestID}
	}
	want := map[string][2]string{"req_enforce": {"enforce", "internal-1"}, "req_observe": {"observe", ""}, "req_unknown": {"", ""}}
	for id, value := range want {
		if got[id] != value {
			t.Fatalf("%s mode=%v want %v (all=%v)", id, got[id], value, got)
		}
	}
	one, err := store.LookupSettlementHeldReservation(ctx, "acct_rb_mode", "req_enforce")
	if err != nil || one.RelayBlindSettlementMode != "enforce" || one.RelayBlindInternalRequestID != "internal-1" {
		t.Fatalf("lookup=%+v err=%v", one, err)
	}
}

// The relay-blind dispatch columns stamp schema v18 with the migration, so a
// v17 gateway (one that would settle a relay-blind hold from the status row)
// refuses the migrated database.
func TestRelayBlindSettlementDispatchMigrationRefusesV17Gateway(t *testing.T) {
	ctx := context.Background()
	store, err := Open(ctx, filepath.Join(t.TempDir(), "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	var version int64
	if err := store.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&version); err != nil || version != 18 {
		t.Fatalf("schema version=%d err=%v, want 18", version, err)
	}
	if err := store.checkSchemaVersionGateAt(ctx, 17); err == nil {
		t.Fatal("a v17 gateway accepted a database carrying the relay-blind dispatch columns")
	}
	if err := store.checkSchemaVersionGateAt(ctx, maxKnownSchemaVersion); err != nil {
		t.Fatalf("current gateway refused its own schema: %v", err)
	}
	// Re-running the migration on a DB that already has the columns is a
	// no-op that keeps the stamp.
	if err := store.ensureRelayBlindSettlementDispatchColumns(ctx); err != nil {
		t.Fatal(err)
	}
}
