package payout

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// seedStaleCancelRow inserts the canonical "stale cancel" row
// shape the §4.7 producer hunts for: cancel + signed + broadcast
// + not-confirmed + not-paged + not-abandoned, with
// updated_at_utc older than 3 × runInterval.
func seedStaleCancelRow(t *testing.T, db *sql.DB, runInterval time.Duration, txHash string) int64 {
	t.Helper()
	payoutID := insertReadyRow(t, db, "p1", "settle:p1:"+txHash)
	old := time.Now().Add(-4 * runInterval).UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   broadcast_at_utc, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0x', '0x', 1, 5, X'02', ?,
        ?, 1, ?)`,
		payoutID, txHash, old, old,
	); err != nil {
		t.Fatalf("insert stale cancel: %v", err)
	}
	return payoutID
}

// TestProduceStaleOutboxRows_BothRPCsMissAfterThreshold_Produces
// locks codex Step 3 r2 [arch:r2-3.2-A] MAJOR closure (positive
// path): when BOTH RPCs return nil receipt + nil error AND the
// stale threshold has been crossed, the producer SHOULD page +
// CAS + insert outbox row.
func TestProduceStaleOutboxRows_BothRPCsMissAfterThreshold_Produces(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	primary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	secondary.receiptFn = primary.receiptFn
	rpcs := TwoRPCs{Primary: primary, Secondary: secondary}
	runInterval := time.Minute
	payoutID := seedStaleCancelRow(t, db, runInterval, "0xstale1")

	produced, err := ProduceStaleOutboxRows(
		context.Background(), db, zerolog.Nop(),
		rpcs, "run-A", time.Now(), runInterval, 0,
	)
	if err != nil {
		t.Fatalf("ProduceStaleOutboxRows: %v", err)
	}
	if produced != 1 {
		t.Errorf("produced=%d, want 1 — both RPCs miss should page", produced)
	}
	// Verify the outbox row persisted run_id.
	var runID string
	_ = db.QueryRowContext(context.Background(),
		`SELECT COALESCE(run_id, '') FROM cancel_reconfirm_stale_outbox WHERE payout_id=? AND attempt_seq=1`,
		payoutID,
	).Scan(&runID)
	if runID != "run-A" {
		t.Errorf("outbox.run_id = %q, want %q (run_id not persisted)", runID, "run-A")
	}
	// Verify the marker CAS flipped NULL→now AND updated_at_utc
	// advanced (codex Step 3 r3 [code:r3-3.1] MEDIUM closure).
	var staleMarker sql.NullString
	var updatedAt string
	_ = db.QueryRowContext(context.Background(),
		`SELECT cancel_reconfirm_stale_paged_at_utc, updated_at_utc FROM payout_attempts WHERE payout_id=? AND attempt_seq=1`,
		payoutID,
	).Scan(&staleMarker, &updatedAt)
	if !staleMarker.Valid {
		t.Errorf("cancel_reconfirm_stale_paged_at_utc not set after producer")
	}
	if staleMarker.Valid && updatedAt != staleMarker.String {
		t.Errorf("updated_at_utc=%q != stale_marker=%q — SPEC §4.7 requires both advance",
			updatedAt, staleMarker.String)
	}
}

// TestProduceStaleOutboxRows_PrimaryReturnsReceipt_DoesNotPage
// locks the [arch:r2-3.2-A] negative path: if either RPC sees a
// receipt for the tx, the cancel is reconfirmable and the
// producer MUST NOT page. Without this check, the producer
// would emit a false PAGE for a cancel that would reconfirm in
// the same cycle.
func TestProduceStaleOutboxRows_PrimaryReturnsReceipt_DoesNotPage(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	// Primary sees a receipt — cancel is reconfirmable.
	primary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) {
		return &Receipt{Status: 1, BlockNumber: 100}, nil
	}
	secondary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	rpcs := TwoRPCs{Primary: primary, Secondary: secondary}
	runInterval := time.Minute
	payoutID := seedStaleCancelRow(t, db, runInterval, "0xreconfirmable")

	produced, err := ProduceStaleOutboxRows(
		context.Background(), db, zerolog.Nop(),
		rpcs, "run-B", time.Now(), runInterval, 0,
	)
	if err != nil {
		t.Fatalf("ProduceStaleOutboxRows: %v", err)
	}
	if produced != 0 {
		t.Errorf("produced=%d, want 0 — primary sees receipt, must skip", produced)
	}
	// Verify the marker is still NULL — no false PAGE.
	var staleMarker sql.NullString
	_ = db.QueryRowContext(context.Background(),
		`SELECT cancel_reconfirm_stale_paged_at_utc FROM payout_attempts WHERE payout_id=? AND attempt_seq=1`,
		payoutID,
	).Scan(&staleMarker)
	if staleMarker.Valid {
		t.Errorf("cancel_reconfirm_stale_paged_at_utc set despite primary seeing receipt — false PAGE risk")
	}
}

// TestProduceStaleOutboxRows_NoRPCs_Disabled covers the test-path
// disable: passing a zero TwoRPCs MUST return (0, nil) without
// touching the DB. This preserves the test harness contract.
func TestProduceStaleOutboxRows_NoRPCs_Disabled(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	_ = seedStaleCancelRow(t, db, time.Minute, "0xdisabled")
	produced, err := ProduceStaleOutboxRows(
		context.Background(), db, zerolog.Nop(),
		TwoRPCs{}, "run-C", time.Now(), time.Minute, 0,
	)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if produced != 0 {
		t.Errorf("produced=%d, want 0 when TwoRPCs is empty", produced)
	}
}
