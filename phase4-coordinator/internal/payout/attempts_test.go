package payout

import (
	"context"
	"errors"
	"testing"
	"time"
)

func seedAddress(t *testing.T, db interface {
	ExecContext(ctx context.Context, query string, args ...any) (interface{}, error)
}, providerID, address, hotWallet string) {
	t.Helper()
}

func TestSelectReadyPayouts_FiltersByHotWalletAndCoolingOff(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	canonicalHot, _ := CanonicalizeEIP55(hotWallet)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	past := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339Nano)
	future := time.Now().Add(48 * time.Hour).UTC().Format(time.RFC3339Nano)

	// Seed two ready rows + one provider with payable + one with cooling.
	_, _ = db.ExecContext(ctx, `
INSERT INTO provider_payout_addresses
  (provider_id, chain, address, payout_allowed, pending_until_utc,
   rotated_from, registered_at_utc, registered_against_hot_wallet)
VALUES ('payable', 'base-mainnet', '0xAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa', 1, ?, NULL, ?, ?),
       ('cooling', 'base-mainnet', '0xBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBb', 1, ?, NULL, ?, ?)`,
		past, past, canonicalHot, future, now, canonicalHot)

	_ = insertReadyRow(t, db, "payable", "settle:payable:1")
	_ = insertReadyRow(t, db, "cooling", "settle:cooling:1")

	rows, err := SelectReadyPayouts(ctx, db, canonicalHot, now, 50)
	if err != nil {
		t.Fatalf("SelectReadyPayouts: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1 (only payable)", len(rows))
	}
	if rows[0].ProviderID != "payable" {
		t.Errorf("provider_id = %s", rows[0].ProviderID)
	}
}

func TestInsertAttempt_DuplicateLiveTrips(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	payoutID := insertReadyRow(t, db, "p1", "settle:p1:1")
	conn, _ := db.Conn(ctx)
	defer conn.Close()
	_, _ = conn.ExecContext(ctx, `BEGIN IMMEDIATE`)
	defer conn.ExecContext(context.Background(), `ROLLBACK`)
	now := NowUTC()
	if err := InsertAttempt(ctx, conn, payoutID, 1, "0xfrom", "0xto", 900_000, 1, now); err != nil {
		t.Fatalf("first INSERT: %v", err)
	}
	err := InsertAttempt(ctx, conn, payoutID, 2, "0xfrom", "0xto", 900_000, 2, now)
	if err == nil {
		t.Fatal("second live INSERT should trip UNIQUE")
	}
	if !errors.Is(err, ErrDuplicateLiveAttempt) {
		t.Errorf("err = %v, want ErrDuplicateLiveAttempt", err)
	}
}

func TestCASPersistSignedTx_HappyPath(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	payoutID := insertReadyRow(t, db, "p1", "settle:p1:1")
	conn, _ := db.Conn(ctx)
	defer conn.Close()
	_, _ = conn.ExecContext(ctx, `BEGIN IMMEDIATE`)
	defer conn.ExecContext(context.Background(), `ROLLBACK`)
	now := NowUTC()
	if err := InsertAttempt(ctx, conn, payoutID, 1, "0xfrom", "0xto", 900_000, 1, now); err != nil {
		t.Fatalf("INSERT: %v", err)
	}
	if err := CASPersistSignedTx(ctx, conn, payoutID, 1, []byte{0x02, 0xde, 0xad}, "0xhash", now); err != nil {
		t.Fatalf("CASPersistSignedTx: %v", err)
	}
	// Second CAS-persist should fail with ErrRawSignedTxAlreadyPresent.
	err := CASPersistSignedTx(ctx, conn, payoutID, 1, []byte{0x02, 0xbe, 0xef}, "0xother", now)
	if !errors.Is(err, ErrRawSignedTxAlreadyPresent) {
		t.Errorf("second CAS err = %v, want ErrRawSignedTxAlreadyPresent", err)
	}
}

func TestCASPersistSignedTx_AbandonedStateChanged(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	payoutID := insertReadyRow(t, db, "p1", "settle:p1:1")
	conn, _ := db.Conn(ctx)
	defer conn.Close()
	_, _ = conn.ExecContext(ctx, `BEGIN IMMEDIATE`)
	defer conn.ExecContext(context.Background(), `ROLLBACK`)
	now := NowUTC()
	_ = InsertAttempt(ctx, conn, payoutID, 1, "0xfrom", "0xto", 900_000, 1, now)
	// Simulate a concurrent abandon.
	_, _ = conn.ExecContext(ctx,
		`UPDATE payout_attempts SET abandoned_at_utc = ?, updated_at_utc = ? WHERE payout_id = ? AND attempt_seq = 1`,
		now, now, payoutID)
	err := CASPersistSignedTx(ctx, conn, payoutID, 1, []byte{0x02}, "0xh", now)
	if !errors.Is(err, ErrAttemptStateChangedDuringSign) {
		t.Errorf("err = %v, want ErrAttemptStateChangedDuringSign", err)
	}
}

func TestNonceCursor_RoundTrip(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	addr := "0xABCdef0000000000000000000000000000000000"
	if err := UpsertNonceCursor(ctx, db, addr, 7, 7, 7, NowUTC()); err != nil {
		t.Fatalf("Upsert: %v", err)
	}
	got, ok, err := ReadNonceCursor(ctx, db, addr)
	if err != nil || !ok {
		t.Fatalf("Read: ok=%v err=%v", ok, err)
	}
	if got != 7 {
		t.Errorf("got %d, want 7", got)
	}
	// Upsert again with a HIGHER value (forward sync) → cursor advances.
	if err := UpsertNonceCursor(ctx, db, addr, 8, 8, 8, NowUTC()); err != nil {
		t.Fatalf("Upsert #2: %v", err)
	}
	got, _, _ = ReadNonceCursor(ctx, db, addr)
	if got != 8 {
		t.Errorf("got %d, want 8 after forward upsert", got)
	}
	// SPEC-016:1749-1750 monotonicity: a restart whose chosen nonce LAGS
	// the stored cursor (e.g. chain pending nonce behind the DB cursor
	// because of an abandoned-unfilled hole) must NOT erase the hole. The
	// ON CONFLICT takes MAX(stored, incoming), so the cursor stays at 8.
	if err := UpsertNonceCursor(ctx, db, addr, 5, 5, 5, NowUTC()); err != nil {
		t.Fatalf("Upsert #3 (lagging): %v", err)
	}
	got, _, _ = ReadNonceCursor(ctx, db, addr)
	if got != 8 {
		t.Errorf("got %d, want 8 (cursor must not regress below stored value)", got)
	}
}

func TestNextAttemptSeq(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	payoutID := insertReadyRow(t, db, "p1", "settle:p1:1")
	conn, _ := db.Conn(ctx)
	defer conn.Close()
	seq, err := NextAttemptSeq(ctx, conn, payoutID)
	if err != nil {
		t.Fatalf("NextAttemptSeq: %v", err)
	}
	if seq != 1 {
		t.Errorf("no rows yet → seq = %d, want 1", seq)
	}
	_, _ = conn.ExecContext(ctx, `BEGIN IMMEDIATE`)
	_ = InsertAttempt(ctx, conn, payoutID, 1, "0xfrom", "0xto", 100, 1, NowUTC())
	_, _ = conn.ExecContext(ctx, `COMMIT`)
	seq, _ = NextAttemptSeq(ctx, conn, payoutID)
	if seq != 2 {
		t.Errorf("after seq=1 → next = %d, want 2", seq)
	}
}

// Verify ErrDuplicateLiveAttempt only trips on LIVE non-cancel
// rows (cancel rows lifted out of the partial UNIQUE WHERE).
func TestInsertAttempt_PostAbandonReinsertSucceeds(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	payoutID := insertReadyRow(t, db, "p1", "settle:p1:1")
	conn, _ := db.Conn(ctx)
	defer conn.Close()
	_, _ = conn.ExecContext(ctx, `BEGIN IMMEDIATE`)
	defer conn.ExecContext(context.Background(), `ROLLBACK`)
	now := NowUTC()
	_ = InsertAttempt(ctx, conn, payoutID, 1, "0xfrom", "0xto", 100, 1, now)
	// Abandon row 1 in the same txn.
	_, _ = conn.ExecContext(ctx,
		`UPDATE payout_attempts SET abandoned_at_utc=?, updated_at_utc=? WHERE payout_id=? AND attempt_seq=1`,
		now, now, payoutID)
	// New attempt at seq=2 should succeed.
	if err := InsertAttempt(ctx, conn, payoutID, 2, "0xfrom", "0xto", 100, 2, now); err != nil {
		t.Errorf("post-abandon fresh INSERT: %v", err)
	}
}
