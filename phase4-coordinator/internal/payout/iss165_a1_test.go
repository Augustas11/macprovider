package payout

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// seedDistinctStaleCancelRow inserts a stale cancel attempt under a
// fresh provider so the unique (provider_id, window) constraint on
// ledger_payout_ready doesn't collide across iterations. The default
// seedStaleCancelRow hard-codes "p1" and is suitable only for single-
// row tests.
func seedDistinctStaleCancelRow(t *testing.T, db *sql.DB, runInterval time.Duration, idx int) int64 {
	t.Helper()
	providerID := fmt.Sprintf("p%d", idx)
	idempotency := fmt.Sprintf("settle:%s:%d", providerID, idx)
	payoutID := insertReadyRow(t, db, providerID, idempotency)
	old := time.Now().Add(-4 * runInterval).UTC().Format(time.RFC3339Nano)
	txHash := fmt.Sprintf("0xstale%d", idx)
	if _, err := db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   broadcast_at_utc, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0x', '0x', 1, ?, X'02', ?,
        ?, 1, ?)`,
		payoutID, int64(idx)+10, txHash, old, old,
	); err != nil {
		t.Fatalf("insert distinct stale cancel: %v", err)
	}
	return payoutID
}

// #165 A1 regression — ProduceStaleOutboxRows must honor the LIMIT
// bound (sized from snap.MaxRowsPerRun) and emit a
// payout_stale_outbox_backlog WARN with the precise candidate count
// when the candidate set exceeds the limit.

func TestProduceStaleOutboxRows_LimitBoundsProducedRows(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	primary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	secondary.receiptFn = primary.receiptFn
	rpcs := TwoRPCs{Primary: primary, Secondary: secondary}
	runInterval := time.Minute

	// Seed 5 stale rows; cap at 2 — only 2 should produce this cycle.
	for i := 0; i < 5; i++ {
		_ = seedDistinctStaleCancelRow(t, db, runInterval, i)
	}

	produced, err := ProduceStaleOutboxRows(
		context.Background(), db, zerolog.Nop(),
		rpcs, "run-limit", time.Now(), runInterval, 2,
	)
	if err != nil {
		t.Fatalf("ProduceStaleOutboxRows: %v", err)
	}
	if produced != 2 {
		t.Errorf("produced=%d, want 2 (limit-bounded)", produced)
	}

	// Verify exactly 2 outbox rows landed; the remaining 3 stay
	// candidates for the next cycle (their markers stay NULL).
	var outbox int
	_ = db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM cancel_reconfirm_stale_outbox`,
	).Scan(&outbox)
	if outbox != 2 {
		t.Errorf("outbox rows=%d, want 2 (limit suppressed remainder)", outbox)
	}
	var stillCandidate int
	_ = db.QueryRowContext(context.Background(), `
SELECT COUNT(*) FROM payout_attempts
 WHERE is_cancel_self_transfer = 1
   AND cancel_reconfirm_stale_paged_at_utc IS NULL`,
	).Scan(&stillCandidate)
	if stillCandidate != 3 {
		t.Errorf("candidates remaining=%d, want 3", stillCandidate)
	}
}

func TestProduceStaleOutboxRows_EmitsBacklogGaugeWhenLimitHit(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	primary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	secondary.receiptFn = primary.receiptFn
	rpcs := TwoRPCs{Primary: primary, Secondary: secondary}
	runInterval := time.Minute

	for i := 0; i < 4; i++ {
		_ = seedDistinctStaleCancelRow(t, db, runInterval, i)
	}

	var buf bytes.Buffer
	log := zerolog.New(&buf)
	if _, err := ProduceStaleOutboxRows(
		context.Background(), db, log,
		rpcs, "run-backlog", time.Now(), runInterval, 2,
	); err != nil {
		t.Fatalf("ProduceStaleOutboxRows: %v", err)
	}

	var found map[string]any
	for _, line := range strings.Split(strings.TrimRight(buf.String(), "\n"), "\n") {
		if line == "" {
			continue
		}
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			continue
		}
		if ev["event"] == "payout_stale_outbox_backlog" {
			found = ev
			break
		}
	}
	if found == nil {
		t.Fatalf("payout_stale_outbox_backlog not emitted; log=%q", buf.String())
	}
	if v, _ := found["limit"].(float64); int(v) != 2 {
		t.Errorf("backlog.limit=%v, want 2", found["limit"])
	}
	// total_candidates is the post-production REMAINING backlog
	// (rows still un-paged after this cycle), not the pre-cycle
	// count: 4 seeded, 2 paged this cycle → 2 remaining.
	if v, _ := found["total_candidates"].(float64); int(v) != 2 {
		t.Errorf("backlog.total_candidates=%v, want 2 (remaining un-paged)", found["total_candidates"])
	}
	if v, _ := found["produced"].(float64); int(v) != 2 {
		t.Errorf("backlog.produced=%v, want 2 (produced == limit)", found["produced"])
	}
	if found["run_id"] != "run-backlog" {
		t.Errorf("backlog.run_id=%v, want run-backlog", found["run_id"])
	}
	if found["severity"] != "WARN" {
		t.Errorf("backlog.severity=%v, want WARN", found["severity"])
	}
}

// TestProduceStaleOutboxRows_NonActionableRowsDoNotConsumeLimit pins
// the #165 R1 SECURITY HIGH closure: non-actionable candidates
// (e.g. at-least-one-RPC sees the receipt) MUST be skipped without
// consuming the limit budget. Without this, the first `limit`
// non-actionable rows in oldest-first order would permanently block
// truly stale cancels from PAGEing (denial of detection).
func TestProduceStaleOutboxRows_NonActionableRowsDoNotConsumeLimit(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	// Per-tx classification: rows 0..2 reconfirmable (primary sees
	// receipt → skip), rows 3..5 truly stale (both miss → produce).
	primary.receiptFn = func(_ context.Context, txHash string) (*Receipt, error) {
		// Reconfirmable: any tx hash starting "0xstale0", "0xstale1", "0xstale2".
		if strings.HasPrefix(txHash, "0xstale0") || strings.HasPrefix(txHash, "0xstale1") || strings.HasPrefix(txHash, "0xstale2") {
			return &Receipt{Status: 1, BlockNumber: 100}, nil
		}
		return nil, nil
	}
	secondary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	rpcs := TwoRPCs{Primary: primary, Secondary: secondary}
	runInterval := time.Minute

	for i := 0; i < 6; i++ {
		_ = seedDistinctStaleCancelRow(t, db, runInterval, i)
	}

	// Limit=2. If LIMIT bounded the SCAN, rows 0..1 (reconfirmable)
	// would consume the budget and rows 3..5 (truly stale) would
	// never PAGE this cycle. With limit bounding PRODUCTION, we
	// expect produced=2 (the first two of rows 3..5).
	produced, err := ProduceStaleOutboxRows(
		context.Background(), db, zerolog.Nop(),
		rpcs, "run-skip", time.Now(), runInterval, 2,
	)
	if err != nil {
		t.Fatalf("ProduceStaleOutboxRows: %v", err)
	}
	if produced != 2 {
		t.Errorf("produced=%d, want 2 — truly stale rows must PAGE despite earlier non-actionable rows", produced)
	}
	// Confirm the produced rows are from the truly-stale set
	// (rows 3,4 — first two of the actionable trio).
	var outboxCount int
	_ = db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM cancel_reconfirm_stale_outbox WHERE tx_hash LIKE '0xstale3%' OR tx_hash LIKE '0xstale4%'`,
	).Scan(&outboxCount)
	if outboxCount != 2 {
		t.Errorf("outbox rows for truly-stale=%d, want 2 (denial-of-detection regression)", outboxCount)
	}
}

// TestProduceStaleOutboxRows_LargeNonActionablePrefixDoesNotStarve
// pins the R3 audit closure: a >1000 non-actionable prefix MUST NOT
// block a single actionable row from PAGEing. This regression
// guards against any future reintroduction of a hidden
// scan-prefix cap. The test seeds 1100 reconfirmable rows
// (primary-sees-receipt → skip) followed by 1 truly stale row.
// With limit=1 the producer MUST find + PAGE the one stale row
// in this cycle.
func TestProduceStaleOutboxRows_LargeNonActionablePrefixDoesNotStarve(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping large-prefix regression in -short mode")
	}
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	const prefixSize = 1100 // > 1000 to defeat any rumored prefix cap.
	primary.receiptFn = func(_ context.Context, txHash string) (*Receipt, error) {
		// The truly-stale row has tx_hash "0xstaleACTIONABLE";
		// every other row is reconfirmable.
		if txHash == "0xstaleactionable" {
			return nil, nil
		}
		return &Receipt{Status: 1, BlockNumber: 100}, nil
	}
	secondary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	rpcs := TwoRPCs{Primary: primary, Secondary: secondary}
	runInterval := time.Minute

	for i := 0; i < prefixSize; i++ {
		_ = seedDistinctStaleCancelRow(t, db, runInterval, i)
	}
	// Seed the actionable row last so it sorts after the prefix
	// (oldest-first ordering uses updated_at_utc, all are
	// identical, then payout_id ASC — so a later-inserted row
	// gets a larger payout_id and sorts last).
	providerID := "p-actionable"
	payoutID := insertReadyRow(t, db, providerID, "settle:"+providerID)
	old := time.Now().Add(-4 * runInterval).UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   broadcast_at_utc, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0x', '0x', 1, ?, X'02', ?,
        ?, 1, ?)`,
		payoutID, int64(prefixSize)+1000, "0xstaleactionable", old, old,
	); err != nil {
		t.Fatalf("insert actionable: %v", err)
	}

	produced, err := ProduceStaleOutboxRows(
		context.Background(), db, zerolog.Nop(),
		rpcs, "run-large-prefix", time.Now(), runInterval, 1,
	)
	if err != nil {
		t.Fatalf("ProduceStaleOutboxRows: %v", err)
	}
	if produced != 1 {
		t.Errorf("produced=%d, want 1 — large non-actionable prefix must not starve stale rows", produced)
	}
}

func TestProduceStaleOutboxRows_NoBacklogEventWhenWithinLimit(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	primary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	secondary.receiptFn = primary.receiptFn
	rpcs := TwoRPCs{Primary: primary, Secondary: secondary}
	runInterval := time.Minute

	for i := 0; i < 2; i++ {
		_ = seedDistinctStaleCancelRow(t, db, runInterval, i)
	}

	var buf bytes.Buffer
	log := zerolog.New(&buf)
	if _, err := ProduceStaleOutboxRows(
		context.Background(), db, log,
		rpcs, "run-clean", time.Now(), runInterval, 50,
	); err != nil {
		t.Fatalf("ProduceStaleOutboxRows: %v", err)
	}
	if strings.Contains(buf.String(), "payout_stale_outbox_backlog") {
		t.Errorf("backlog event emitted when candidates <= limit; log=%q", buf.String())
	}
}

func TestProduceStaleOutboxRows_ZeroLimitDisablesCap(t *testing.T) {
	db := openTestDB(t)
	seedBootstrapForTest(t, db)
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	primary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	secondary.receiptFn = primary.receiptFn
	rpcs := TwoRPCs{Primary: primary, Secondary: secondary}
	runInterval := time.Minute

	for i := 0; i < 3; i++ {
		_ = seedDistinctStaleCancelRow(t, db, runInterval, i)
	}

	produced, err := ProduceStaleOutboxRows(
		context.Background(), db, zerolog.Nop(),
		rpcs, "run-uncapped", time.Now(), runInterval, 0,
	)
	if err != nil {
		t.Fatalf("ProduceStaleOutboxRows: %v", err)
	}
	if produced != 3 {
		t.Errorf("produced=%d, want 3 (limit=0 means no cap, back-compat)", produced)
	}
}

