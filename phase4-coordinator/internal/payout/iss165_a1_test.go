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

func TestProduceStaleOutboxRows_LimitBoundsCandidateScan(t *testing.T) {
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
	if v, _ := found["total_candidates"].(float64); int(v) != 4 {
		t.Errorf("backlog.total_candidates=%v, want 4 (exact backlog count)", found["total_candidates"])
	}
	if found["run_id"] != "run-backlog" {
		t.Errorf("backlog.run_id=%v, want run-backlog", found["run_id"])
	}
	if found["severity"] != "WARN" {
		t.Errorf("backlog.severity=%v, want WARN", found["severity"])
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

