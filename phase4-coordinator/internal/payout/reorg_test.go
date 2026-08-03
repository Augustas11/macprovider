package payout

import (
	"context"
	"errors"
	"testing"
	"time"
)

func setupReorgPoller(t *testing.T) (*ReorgPoller, *mockRPCClient, *mockRPCClient) {
	t.Helper()
	db := openTestDB(t)
	primary := &mockRPCClient{label: "primary"}
	secondary := &mockRPCClient{label: "secondary"}
	logger, _ := quietLogger()
	return &ReorgPoller{
		DB:          db,
		RPCs:        TwoRPCs{Primary: primary, Secondary: secondary},
		HotWallet:   "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		PollWindow:  24 * time.Hour,
		RunInterval: 5 * time.Minute,
		Logger:      logger,
		NowFn:       func() time.Time { return time.Now().UTC() },
	}, primary, secondary
}

func seedConfirmedAttempt(t *testing.T, db interface {
	ExecContext(ctx context.Context, query string, args ...any) (interface{}, error)
}, payoutID int64, attemptSeq int, txHash string, isCancel bool) {
	t.Helper()
}

func TestReorgPoller_ProviderReorg_BothRpcsNotFound(t *testing.T) {
	p, primary, secondary := setupReorgPoller(t)
	payoutID := insertReadyRow(t, p.DB, "p1", "settle:p1:1")
	now := NowUTC()
	// Seed a confirmed provider-payout attempt.
	if _, err := p.DB.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, tx_hash, broadcast_at_utc,
   confirmed_at_utc, block_number, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0xfrom', '0xto', 1000, 1, '0xfakehash',
        ?, ?, 100, 0, ?)`, payoutID, now, now, now); err != nil {
		t.Fatalf("seed attempt: %v", err)
	}
	primary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	secondary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	count, err := p.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if count != 1 {
		t.Errorf("polled count = %d, want 1", count)
	}
	// Provider-payout reorg does NOT mutate the row — observability only.
	var confirmedAt string
	if err := p.DB.QueryRowContext(context.Background(),
		`SELECT confirmed_at_utc FROM payout_attempts WHERE payout_id = ? AND attempt_seq = 1`, payoutID,
	).Scan(&confirmedAt); err != nil {
		t.Fatalf("post-reorg scan: %v", err)
	}
	if confirmedAt == "" {
		t.Error("provider-payout reorg should NOT clear confirmed_at_utc (Step 3 orphan-recording does that)")
	}
}

func TestReorgPoller_CancelReorg_LiveAgain(t *testing.T) {
	p, primary, secondary := setupReorgPoller(t)
	payoutID := insertReadyRow(t, p.DB, "p1", "settle:p1:1")
	now := NowUTC()
	if _, err := p.DB.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, tx_hash, broadcast_at_utc,
   confirmed_at_utc, block_number, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0xfrom', '0xfrom', 1, 1, '0xcancelhash',
        ?, ?, 100, 1, ?)`, payoutID, now, now, now); err != nil {
		t.Fatalf("seed cancel: %v", err)
	}
	primary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	secondary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	// Cancel-side reorg MUST clear confirmed_at_utc / block_number.
	var confirmedAt, blockNumber any
	if err := p.DB.QueryRowContext(context.Background(),
		`SELECT confirmed_at_utc, block_number FROM payout_attempts WHERE payout_id = ? AND attempt_seq = 1`, payoutID,
	).Scan(&confirmedAt, &blockNumber); err != nil {
		t.Fatalf("post-reorg scan: %v", err)
	}
	if confirmedAt != nil {
		t.Errorf("cancel reorg should clear confirmed_at_utc, got %v", confirmedAt)
	}
	if blockNumber != nil {
		t.Errorf("cancel reorg should clear block_number, got %v", blockNumber)
	}
}

func TestReorgPoller_RPCError_DoesNotTreatAsReorg(t *testing.T) {
	p, primary, secondary := setupReorgPoller(t)
	payoutID := insertReadyRow(t, p.DB, "p1", "settle:p1:1")
	now := NowUTC()
	if _, err := p.DB.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, tx_hash, broadcast_at_utc,
   confirmed_at_utc, block_number, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', '0xfrom', '0xto', 1000, 1, '0xfakehash',
        ?, ?, 100, 0, ?)`, payoutID, now, now, now); err != nil {
		t.Fatalf("seed: %v", err)
	}
	primary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) {
		return nil, errors.New("network error")
	}
	secondary.receiptFn = func(_ context.Context, _ string) (*Receipt, error) {
		return &Receipt{TxHash: "0xfakehash", Status: 1}, nil
	}
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	// Row MUST still be confirmed — RPC error is not a reorg.
	var confirmedAt string
	_ = p.DB.QueryRowContext(context.Background(),
		`SELECT confirmed_at_utc FROM payout_attempts WHERE payout_id = ? AND attempt_seq = 1`, payoutID,
	).Scan(&confirmedAt)
	if confirmedAt == "" {
		t.Error("RPC error MUST NOT clear confirmed_at_utc")
	}
}
