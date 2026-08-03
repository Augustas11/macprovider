package payout

import (
	"context"
	"strings"
	"testing"
	"time"
)

// TestRunner_RebroadcastPersistedBytes_NoReSign locks codex
// round-1 [code:1.1] MAJOR closure: when an attempt has
// raw_signed_tx IS NOT NULL AND broadcast_at_utc IS NULL,
// processRow MUST take the rebroadcastAndPoll branch and broadcast
// the persisted envelope bit-for-bit without invoking the Signer.
func TestRunner_RebroadcastPersistedBytes_NoReSign(t *testing.T) {
	s := setupRunnerForTest(t)
	db := s.db
	canonicalHot, _ := CanonicalizeEIP55(s.hotAddr)
	past := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339Nano)
	providerAddr := "0x000000000000000000000000000000000000dEaD"
	_, _ = db.ExecContext(context.Background(), `
INSERT INTO provider_payout_addresses
  (provider_id, chain, address, payout_allowed, pending_until_utc,
   rotated_from, registered_at_utc, registered_against_hot_wallet)
VALUES ('p1', 'base-mainnet', ?, 1, ?, NULL, ?, ?)`,
		providerAddr, past, past, canonicalHot)
	payoutID := insertReadyRow(t, db, "p1", "settle:p1:w1")
	_, _ = db.ExecContext(context.Background(),
		`UPDATE ledger_payout_ready SET provider_credits = 900000, gross_credits = 1000000 WHERE id = ?`, payoutID)

	// Pre-seed a persisted-but-unbroadcast attempt with bogus
	// envelope bytes. The runner MUST rebroadcast THESE bytes,
	// not produce new ones via Signer.SignTx.
	persistedBytes := []byte{0x02, 0xfa, 0xfa, 0xfa} // sentinel
	persistedHash := "0xpersistedhash"
	_, _ = db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   broadcast_at_utc, confirmed_at_utc, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', ?, ?, 900000, 1, ?, ?, NULL, NULL, 0, ?)`,
		payoutID, strings.ToLower(canonicalHot), strings.ToLower(providerAddr),
		persistedBytes, persistedHash, NowUTC(),
	)

	var capturedRaw []byte
	s.primary.sendFn = func(_ context.Context, raw []byte) (string, error) {
		capturedRaw = append([]byte(nil), raw...)
		return persistedHash, nil
	}
	s.secondary.sendFn = func(_ context.Context, raw []byte) (string, error) {
		capturedRaw = append([]byte(nil), raw...)
		return persistedHash, nil
	}
	// Receipt poll deadline expires quickly — we just want to
	// verify the broadcast happened with the persisted bytes.
	s.runner.opts.ReceiptPollTimeout = 5 * time.Millisecond

	_, _ = s.runner.RunOnce(context.Background())

	if len(capturedRaw) == 0 {
		t.Fatal("rebroadcast did not happen — runner fell through to fresh allocation despite persisted bytes")
	}
	for i, b := range persistedBytes {
		if capturedRaw[i] != b {
			t.Fatalf("rebroadcast bytes differ from persisted at offset %d: got 0x%02x want 0x%02x",
				i, capturedRaw[i], b)
		}
	}
	// And broadcast_at_utc should have been stamped.
	var broadcastAt string
	_ = db.QueryRowContext(context.Background(),
		`SELECT COALESCE(broadcast_at_utc, '') FROM payout_attempts WHERE payout_id=? AND attempt_seq=1`, payoutID,
	).Scan(&broadcastAt)
	if broadcastAt == "" {
		t.Error("broadcast_at_utc should be stamped after successful rebroadcast")
	}
}

// TestVerifyCancelTxView locks codex round-3 [code:r3-3.1]
// MEDIUM closure: the cancel-branch tx-body invariants enforced
// against both primary and secondary eth_getTransactionByHash
// returns before MarkConfirmedAtTx fires.
func TestVerifyCancelTxView(t *testing.T) {
	hot := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	hotLower := strings.ToLower(hot)
	// Happy path.
	good := &Transaction{
		From:    hotLower,
		To:      hotLower,
		Value:   "0x1",
		Input:   nil,
		ChainID: BaseMainnetChainID,
	}
	if err := verifyCancelTxView(good, hot); err != nil {
		t.Fatalf("happy path: %v", err)
	}
	// Tolerate 0x01 / 0X1.
	for _, v := range []string{"0x01", "0X1", "0x0001"} {
		c := *good
		c.Value = v
		if err := verifyCancelTxView(&c, hot); err != nil {
			t.Errorf("value=%s should pass: %v", v, err)
		}
	}
	// Reject wrong from.
	c := *good
	c.From = "0x000000000000000000000000000000000000dead"
	if err := verifyCancelTxView(&c, hot); err == nil {
		t.Error("wrong from should reject")
	}
	// Reject wrong to.
	c = *good
	c.To = "0x000000000000000000000000000000000000dead"
	if err := verifyCancelTxView(&c, hot); err == nil {
		t.Error("wrong to should reject")
	}
	// Reject non-empty input.
	c = *good
	c.Input = []byte{0xa9, 0x05, 0x9c, 0xbb}
	if err := verifyCancelTxView(&c, hot); err == nil {
		t.Error("non-empty input should reject")
	}
	// Reject wrong value.
	c = *good
	c.Value = "0x2"
	if err := verifyCancelTxView(&c, hot); err == nil {
		t.Error("value != 1 wei should reject")
	}
	c.Value = "0x0"
	if err := verifyCancelTxView(&c, hot); err == nil {
		t.Error("value=0 should reject")
	}
}

// TestRunner_CancelPreCheck_LiveUnbroadcastBlocksFreshAllocation
// locks codex round-1 [code:1.2] MAJOR closure: a live unbroadcast
// cancel HALTS fresh non-cancel allocation for the same payout_id.
func TestRunner_CancelPreCheck_LiveUnbroadcastBlocksFreshAllocation(t *testing.T) {
	s := setupRunnerForTest(t)
	db := s.db
	canonicalHot, _ := CanonicalizeEIP55(s.hotAddr)
	past := time.Now().Add(-1 * time.Hour).UTC().Format(time.RFC3339Nano)
	providerAddr := "0x000000000000000000000000000000000000dEaD"
	_, _ = db.ExecContext(context.Background(), `
INSERT INTO provider_payout_addresses
  (provider_id, chain, address, payout_allowed, pending_until_utc,
   rotated_from, registered_at_utc, registered_against_hot_wallet)
VALUES ('p1', 'base-mainnet', ?, 1, ?, NULL, ?, ?)`,
		providerAddr, past, past, canonicalHot)
	payoutID := insertReadyRow(t, db, "p1", "settle:p1:w1")
	_, _ = db.ExecContext(context.Background(),
		`UPDATE ledger_payout_ready SET provider_credits = 900000, gross_credits = 1000000 WHERE id = ?`, payoutID)

	// Pre-seed a live unbroadcast cancel.
	_, _ = db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   broadcast_at_utc, confirmed_at_utc, is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', ?, ?, 1, 1, ?, ?, NULL, NULL, 1, ?)`,
		payoutID, strings.ToLower(canonicalHot), strings.ToLower(canonicalHot),
		[]byte{0x02, 0xca, 0xfe}, "0xcancelhash", NowUTC(),
	)

	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	// Fresh allocation MUST NOT have happened — no seq=2 row.
	var seqCount int
	_ = db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM payout_attempts WHERE payout_id=? AND attempt_seq=2`, payoutID,
	).Scan(&seqCount)
	if seqCount != 0 {
		t.Errorf("fresh non-cancel attempt allocated despite live unbroadcast cancel; seq=2 count=%d", seqCount)
	}
}
