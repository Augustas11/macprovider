package payout

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// nonceGapSetup wires a runner with a capture buffer so tests can
// assert exactly which §7.1 events the payout_nonce_gap pre-check
// emits, plus a `sent` flag proving the cycle broadcasts NOTHING when
// it halts on a gap.
type nonceGapSetup struct {
	runner  *Runner
	db      *sql.DB
	buf     *bytes.Buffer
	hotAddr string
	sent    *bool
}

func setupNonceGapRunner(t *testing.T, cursor uint64) *nonceGapSetup {
	t.Helper()
	db := openTestDB(t)
	rawHex := "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
	raw, _ := hex.DecodeString(rawHex)
	signer, err := NewLocalFileSignerFromKey(raw)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	hotAddr := signer.FromAddress()

	buf := &bytes.Buffer{}
	logger := zerolog.New(buf)
	state, _, err := Acquire(context.Background(), db, testRunInterval, logger)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := UpsertNonceCursor(context.Background(), db, hotAddr, cursor, 0, 0, NowUTC()); err != nil {
		t.Fatalf("UpsertNonceCursor: %v", err)
	}

	sent := false
	markSent := func(_ context.Context, _ []byte) (string, error) {
		sent = true
		return "0xdeadbeef", nil
	}
	primary := &mockRPCClient{label: "primary", sendFn: markSent}
	secondary := &mockRPCClient{label: "secondary", sendFn: markSent}

	opts := RunnerOptions{
		DB:                    db,
		Security:              SecurityConfig{HotWalletAddress: hotAddr},
		RPCs:                  TwoRPCs{Primary: primary, Secondary: secondary},
		Signer:                signer,
		Claimer:               &mockClaimer{claimed: true},
		Logger:                logger,
		RunInterval:           testRunInterval,
		MaxRowsPerRun:         50,
		ConfirmationBlocks:    5,
		PerPayoutCapBaseUnits: 1_000_000_000_000,
		PerDayCapBaseUnits:    10_000_000_000_000,
		ReceiptPollInterval:   1 * time.Millisecond,
		ReceiptPollTimeout:    100 * time.Millisecond,
		NowFn:                 func() time.Time { return time.Now().UTC() },
	}
	runner, err := NewRunner(opts, state)
	if err != nil {
		t.Fatalf("NewRunner: %v", err)
	}
	// Default: both RPCs agree on pending nonce == cursor (steady state).
	primary.txCountFn = pendingFn(cursor)
	secondary.txCountFn = pendingFn(cursor)
	return &nonceGapSetup{runner: runner, db: db, buf: buf, hotAddr: hotAddr, sent: &sent}
}

// setPending makes both RPCs report the same pending nonce.
func (s *nonceGapSetup) setPending(n uint64) {
	s.runner.opts.RPCs.Primary.(*mockRPCClient).txCountFn = pendingFn(n)
	s.runner.opts.RPCs.Secondary.(*mockRPCClient).txCountFn = pendingFn(n)
}

// setPendingSplit makes the two RPCs disagree (a on primary, b on
// secondary).
func (s *nonceGapSetup) setPendingSplit(a, b uint64) {
	s.runner.opts.RPCs.Primary.(*mockRPCClient).txCountFn = pendingFn(a)
	s.runner.opts.RPCs.Secondary.(*mockRPCClient).txCountFn = pendingFn(b)
}

// seedAbandonedNonCancel inserts an abandoned, unconfirmed, non-cancel
// attempt occupying `nonce` — the CAUSE of a nonce_gap (an operator
// abandon WITHOUT a cancel per §4.6).
func (s *nonceGapSetup) seedAbandonedNonCancel(t *testing.T, payoutID int64, nonce uint64) {
	t.Helper()
	now := NowUTC()
	if _, err := s.db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, is_cancel_self_transfer,
   abandoned_at_utc, abandoned_reason, updated_at_utc)
VALUES (?, 1, 'base-mainnet', ?, '0x00000000000000000000000000000000000000to',
        100, ?, 0, ?, 'operator-abandon-no-cancel', ?)`,
		payoutID, strings.ToLower(s.hotAddr), int64(nonce), now, now); err != nil {
		t.Fatalf("seed abandoned non-cancel: %v", err)
	}
}

// seedLivePersistedUnbroadcast inserts a crash-recovery attempt
// (raw_signed_tx present, not broadcast, not confirmed, not abandoned)
// occupying `nonce`.
func (s *nonceGapSetup) seedLivePersistedUnbroadcast(t *testing.T, payoutID int64, nonce uint64) {
	t.Helper()
	now := NowUTC()
	if _, err := s.db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   is_cancel_self_transfer, updated_at_utc)
VALUES (?, 2, 'base-mainnet', ?, '0x00000000000000000000000000000000000000to',
        100, ?, X'0102', '0xhash', 0, ?)`,
		payoutID, strings.ToLower(s.hotAddr), int64(nonce), now); err != nil {
		t.Fatalf("seed live persisted-unbroadcast: %v", err)
	}
}

// seedConfirmedCancel inserts a confirmed cancel-self-transfer filling
// `nonce`.
func (s *nonceGapSetup) seedConfirmedCancel(t *testing.T, payoutID int64, nonce uint64) {
	t.Helper()
	now := NowUTC()
	if _, err := s.db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, tx_hash, broadcast_at_utc, confirmed_at_utc,
   is_cancel_self_transfer, updated_at_utc)
VALUES (?, 3, 'base-mainnet', ?, ?, 1, ?, '0xcancelhash', ?, ?, 1, ?)`,
		payoutID, strings.ToLower(s.hotAddr), strings.ToLower(s.hotAddr),
		int64(nonce), now, now, now); err != nil {
		t.Fatalf("seed confirmed cancel: %v", err)
	}
}

func pendingFn(n uint64) func(context.Context, string) (uint64, error) {
	return func(context.Context, string) (uint64, error) { return n, nil }
}

// attemptCount returns the total payout_attempts row count — the
// R2-MEDIUM zero-ALLOCATION probe: a fail-closed / recovery-only cycle
// must never INSERT a fresh attempt row.
func (s *nonceGapSetup) attemptCount(t *testing.T) int {
	t.Helper()
	var n int
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM payout_attempts`).Scan(&n); err != nil {
		t.Fatalf("count payout_attempts: %v", err)
	}
	return n
}

// cursorNow reads the current wallet_nonce_cursor.next_nonce — the other
// half of the R2-MEDIUM zero-ALLOCATION probe: a fresh allocation bumps
// this cursor, so an unchanged cursor proves no nonce was allocated.
func (s *nonceGapSetup) cursorNow(t *testing.T) uint64 {
	t.Helper()
	cur, ok, err := ReadNonceCursor(context.Background(), s.db, s.hotAddr)
	if err != nil || !ok {
		t.Fatalf("ReadNonceCursor: ok=%v err=%v", ok, err)
	}
	return cur
}

// assertNoAllocation asserts that neither a new payout_attempts row was
// INSERTed nor the nonce cursor bumped since the baseline snapshot — the
// R2-MEDIUM assertion that a fail-closed / recovery-only cycle allocates
// ZERO nonces (not merely broadcasts nothing).
func assertNoAllocation(t *testing.T, s *nonceGapSetup, wantCount int, wantCursor uint64) {
	t.Helper()
	if got := s.attemptCount(t); got != wantCount {
		t.Errorf("payout_attempts count = %d, want %d (cycle must NOT allocate a fresh attempt)", got, wantCount)
	}
	if got := s.cursorNow(t); got != wantCursor {
		t.Errorf("nonce cursor = %d, want %d (cycle must NOT bump the cursor)", got, wantCursor)
	}
}

// findEvent returns the first newline-delimited JSON log line whose
// "event" field equals name, or nil.
func findEvent(t *testing.T, buf *bytes.Buffer, name string) map[string]any {
	t.Helper()
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			continue
		}
		if ev["event"] == name {
			return ev
		}
	}
	return nil
}

// TestRunner_NonceGap_DetectedHaltsAndEmits is the core regression: an
// operator abandon WITHOUT a cancel (the latent-stall bug) leaves an
// abandoned non-cancel attempt at nonce N while the DB cursor advanced
// to N+1. With both RPCs reporting pending == N (observed < expected),
// RunOnce MUST halt the whole cycle, emit payout_nonce_gap (WARN) with
// from_address / expected_nonce=N+1 / observed_pending_nonce=N, and
// broadcast NOTHING.
func TestRunner_NonceGap_DetectedHaltsAndEmits(t *testing.T) {
	const N = uint64(7)
	s := setupNonceGapRunner(t, N+1) // cursor = expected = N+1
	pid := insertReadyRow(t, s.db, "p1", "settle:p1:gap")
	s.seedAbandonedNonCancel(t, pid, N)
	// R4 MEDIUM (non-vacuous zero-allocation): seed a SELECTABLE ready
	// payout for a DIFFERENT provider (payout-allowed address + ready row)
	// so a regression that failed to halt WOULD fresh-allocate a nonce and
	// broadcast it (markSent flips *s.sent). Without a selectable candidate
	// the zero-alloc / zero-broadcast asserts below could pass vacuously —
	// nothing would allocate regardless of whether the halt fired.
	insertPayoutAddress(t, s.db, "p2", s.hotAddr)
	insertReadyRow(t, s.db, "p2", "settle:p2:gap-selectable")
	s.setPending(N) // observed = N < expected = N+1

	baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)
	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	// R3 MEDIUM: a detected-gap halt must allocate ZERO nonces (no fresh
	// attempt row, cursor unmoved) — not merely broadcast nothing.
	assertNoAllocation(t, s, baseCount, baseCursor)

	ev := findEvent(t, s.buf, "payout_nonce_gap")
	if ev == nil {
		t.Fatalf("payout_nonce_gap not emitted; log=%s", s.buf.String())
	}
	if ev["severity"] != "WARN" {
		t.Errorf("severity = %v, want WARN", ev["severity"])
	}
	if ev["level"] != "warn" {
		t.Errorf("level = %v, want warn", ev["level"])
	}
	if got := ev["from_address"]; got != strings.ToLower(s.hotAddr) {
		t.Errorf("from_address = %v, want %s", got, strings.ToLower(s.hotAddr))
	}
	if got, ok := ev["expected_nonce"].(float64); !ok || uint64(got) != N+1 {
		t.Errorf("expected_nonce = %v, want %d", ev["expected_nonce"], N+1)
	}
	if got, ok := ev["observed_pending_nonce"].(float64); !ok || uint64(got) != N {
		t.Errorf("observed_pending_nonce = %v, want %d", ev["observed_pending_nonce"], N)
	}
	if _, ok := ev["ts_utc"]; !ok {
		t.Error("missing ts_utc")
	}
	if *s.sent {
		t.Error("cycle broadcast a transaction on a halted nonce-gap cycle")
	}
}

// TestRunner_NonceGap_FailClosed locks the §7.1 gate's fail-CLOSED
// semantics after the audit-round-1 fix: the ONLY path that proceeds to
// allocation in the observed<expected branch is a benign
// rebroadcastable crash-recovery. Everything uncertain HALTS the cycle
// and broadcasts NOTHING. Each subtest seeds a payout-allowed address +
// ready row so a SPURIOUS proceed WOULD broadcast — asserting
// sent==false is therefore a real "zero broadcast" proof, not a vacuous
// one.
func TestRunner_NonceGap_FailClosed(t *testing.T) {
	// runCycle executes one cycle and fails on unexpected errors.
	runCycle := func(t *testing.T, s *nonceGapSetup) {
		t.Helper()
		if _, err := s.runner.RunOnce(context.Background()); err != nil {
			t.Fatalf("RunOnce: %v", err)
		}
	}
	assertNoGapAlert := func(t *testing.T, s *nonceGapSetup) {
		t.Helper()
		if ev := findEvent(t, s.buf, "payout_nonce_gap"); ev != nil {
			t.Fatalf("payout_nonce_gap wrongly emitted: %v", ev)
		}
	}
	assertZeroBroadcast := func(t *testing.T, s *nonceGapSetup) {
		t.Helper()
		if *s.sent {
			t.Error("cycle broadcast a transaction on a halted nonce-gap cycle")
		}
	}

	// --- PROCEED paths (no halt, cycle continues) ------------------------

	t.Run("steady_state", func(t *testing.T) {
		// observed == expected → early return, normal cycle, no gap.
		s := setupNonceGapRunner(t, 5)
		s.setPending(5)
		runCycle(t, s)
		assertNoGapAlert(t, s)
		if findEvent(t, s.buf, "payout_nonce_gap_reorg_suspect") != nil {
			t.Error("steady state must not emit reorg_suspect")
		}
	})

	t.Run("observed_greater_than_expected", func(t *testing.T) {
		// observed > expected is an out-of-band-spend class, NOT a gap;
		// early return, no halt.
		s := setupNonceGapRunner(t, 5)
		s.setPending(9)
		runCycle(t, s)
		assertNoGapAlert(t, s)
		if findEvent(t, s.buf, "payout_nonce_gap_reorg_suspect") != nil {
			t.Error("observed>expected must not emit reorg_suspect")
		}
	})

	t.Run("crash_recovery_rebroadcastable_proceeds", func(t *testing.T) {
		// A live persisted-but-unbroadcast attempt fills the nonce (D4):
		// the ONLY proceed path in the observed<expected branch. With the
		// address row present the cycle actually continues and REACHES the
		// broadcast path (rebroadcast of the persisted bytes) — proving the
		// gate let it through rather than silently processing zero rows.
		const N = uint64(4)
		s := setupNonceGapRunner(t, N+1)
		insertPayoutAddress(t, s.db, "p1", s.hotAddr)
		pid := insertReadyRow(t, s.db, "p1", "settle:p1:crash")
		s.seedAbandonedNonCancel(t, pid, N)       // CAUSE present
		s.seedLivePersistedUnbroadcast(t, pid, N) // but rebroadcastable at N
		s.setPending(N)
		runCycle(t, s)
		assertNoGapAlert(t, s)
		if findEvent(t, s.buf, "payout_nonce_gap_reorg_suspect") != nil {
			t.Errorf("crash-recovery must not emit reorg_suspect; log=%s", s.buf.String())
		}
		if !*s.sent {
			t.Error("crash-recovery proceed did not reach the broadcast path (rebroadcast)")
		}
	})

	// --- HALT paths (fail closed, zero broadcast) ------------------------

	t.Run("rpc_disagreement_gt1_halts", func(t *testing.T) {
		// |a-b| > 1 → nonce state unverifiable → HALT fail-closed. Emit
		// precheck_skipped, no payout_nonce_gap, and broadcast NOTHING even
		// though a ready payout is waiting.
		s := setupNonceGapRunner(t, 9)
		insertPayoutAddress(t, s.db, "p1", s.hotAddr)
		pid := insertReadyRow(t, s.db, "p1", "settle:p1:disagree")
		s.seedAbandonedNonCancel(t, pid, 7)
		s.setPendingSplit(7, 12) // diff = 5 > 1
		baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)
		runCycle(t, s)
		assertNoGapAlert(t, s)
		assertZeroBroadcast(t, s)
		assertNoAllocation(t, s, baseCount, baseCursor)
		if findEvent(t, s.buf, "payout_nonce_gap_precheck_skipped") == nil {
			t.Errorf("expected payout_nonce_gap_precheck_skipped; log=%s", s.buf.String())
		}
	})

	t.Run("rpc_hard_error_halts_and_redacts", func(t *testing.T) {
		// A hard RPC error (secret-bearing URL) → HALT fail-closed, zero
		// broadcast, and the emitted diagnostic must NOT leak the raw
		// error/URL (F4 redaction).
		const secret = "https://mainnet.rpc.example/v2/SUPERSECRETKEY123"
		s := setupNonceGapRunner(t, 9)
		insertPayoutAddress(t, s.db, "p1", s.hotAddr)
		pid := insertReadyRow(t, s.db, "p1", "settle:p1:hard")
		s.seedAbandonedNonCancel(t, pid, 8)
		hardErr := func(context.Context, string) (uint64, error) {
			return 0, fmt.Errorf("dial %s: connection refused", secret)
		}
		s.runner.opts.RPCs.Primary.(*mockRPCClient).txCountFn = hardErr
		s.runner.opts.RPCs.Secondary.(*mockRPCClient).txCountFn = hardErr
		baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)
		runCycle(t, s)
		assertNoGapAlert(t, s)
		assertZeroBroadcast(t, s)
		assertNoAllocation(t, s, baseCount, baseCursor)
		ev := findEvent(t, s.buf, "payout_nonce_gap_precheck_skipped")
		if ev == nil {
			t.Fatalf("expected payout_nonce_gap_precheck_skipped; log=%s", s.buf.String())
		}
		if _, ok := ev["error_class"]; !ok {
			t.Error("precheck_skipped must carry a classified error_class")
		}
		if strings.Contains(s.buf.String(), secret) || strings.Contains(s.buf.String(), "SUPERSECRETKEY") {
			t.Errorf("diagnostic leaked the raw RPC URL/secret; log=%s", s.buf.String())
		}
	})

	t.Run("confirmed_cancel_at_observed_halts_reorg_suspect", func(t *testing.T) {
		// A CONFIRMED cancel row sits at observed. Since observed is not yet
		// mined, that confirmed_at_utc is stale-by-definition (reorged-out),
		// so it must NOT suppress the gap. No abandon CAUSE present → step 3
		// → HALT as reorg_suspect, zero broadcast.
		const N = uint64(3)
		s := setupNonceGapRunner(t, N+1)
		insertPayoutAddress(t, s.db, "p1", s.hotAddr)
		pid := insertReadyRow(t, s.db, "p1", "settle:p1:cancel")
		s.seedConfirmedCancel(t, pid, N) // confirmed cancel at N, no abandon cause
		s.setPending(N)
		baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)
		runCycle(t, s)
		assertNoGapAlert(t, s)
		assertZeroBroadcast(t, s)
		assertNoAllocation(t, s, baseCount, baseCursor)
		assertReorgSuspect(t, s, s.hotAddr, N+1, N)
	})

	t.Run("cause_absent_halts_reorg_suspect", func(t *testing.T) {
		// observed < expected but NOTHING sits at observed → chain-
		// contradicted / unexplained → HALT fail-closed as reorg_suspect,
		// zero broadcast (previously fell through to allocation).
		const N = uint64(6)
		s := setupNonceGapRunner(t, 8)
		insertPayoutAddress(t, s.db, "p1", s.hotAddr)
		_ = insertReadyRow(t, s.db, "p1", "settle:p1:absent")
		s.setPending(N)
		baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)
		runCycle(t, s)
		assertNoGapAlert(t, s)
		assertZeroBroadcast(t, s)
		assertNoAllocation(t, s, baseCount, baseCursor)
		assertReorgSuspect(t, s, s.hotAddr, 8, N)
	})

	t.Run("dual_cause_and_confirmed_emits_nonce_gap", func(t *testing.T) {
		// Architect dual scenario: a real abandon CAUSE and a stale
		// confirmed cancel BOTH at observed. CAUSE check precedes the
		// reorg-suspect fallback, so this reports the more specific
		// payout_nonce_gap (WARN) and HALTs, zero broadcast.
		const N = uint64(3)
		s := setupNonceGapRunner(t, N+1)
		insertPayoutAddress(t, s.db, "p1", s.hotAddr)
		pid := insertReadyRow(t, s.db, "p1", "settle:p1:dual")
		s.seedAbandonedNonCancel(t, pid, N)
		s.seedConfirmedCancel(t, pid, N)
		s.setPending(N)
		baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)
		runCycle(t, s)
		assertZeroBroadcast(t, s)
		assertNoAllocation(t, s, baseCount, baseCursor)
		if findEvent(t, s.buf, "payout_nonce_gap") == nil {
			t.Errorf("dual case must emit payout_nonce_gap; log=%s", s.buf.String())
		}
		if findEvent(t, s.buf, "payout_nonce_gap_reorg_suspect") != nil {
			t.Error("dual case must NOT emit reorg_suspect (cause takes precedence)")
		}
	})
}

// assertReorgSuspect asserts a payout_nonce_gap_reorg_suspect info event
// fired with the expected redacted fields and no raw RPC error/URL.
func assertReorgSuspect(t *testing.T, s *nonceGapSetup, hotAddr string, expected, observed uint64) {
	t.Helper()
	ev := findEvent(t, s.buf, "payout_nonce_gap_reorg_suspect")
	if ev == nil {
		t.Fatalf("payout_nonce_gap_reorg_suspect not emitted; log=%s", s.buf.String())
	}
	if got := ev["from_address"]; got != strings.ToLower(hotAddr) {
		t.Errorf("from_address = %v, want %s", got, strings.ToLower(hotAddr))
	}
	if got, ok := ev["expected_nonce"].(float64); !ok || uint64(got) != expected {
		t.Errorf("expected_nonce = %v, want %d", ev["expected_nonce"], expected)
	}
	if got, ok := ev["observed_pending_nonce"].(float64); !ok || uint64(got) != observed {
		t.Errorf("observed_pending_nonce = %v, want %d", ev["observed_pending_nonce"], observed)
	}
	if _, ok := ev["ts_utc"]; !ok {
		t.Error("missing ts_utc")
	}
	// reorg_suspect must not carry a severity field (info diagnostic, not
	// an alert) and must not leak a raw error string.
	if _, ok := ev["severity"]; ok {
		t.Error("reorg_suspect must not carry a severity field (it is a non-alert info event)")
	}
	if _, ok := ev["error"]; ok {
		t.Error("reorg_suspect must not carry a raw error field")
	}
}

// TestRunner_NonceGap_RestartCursorMonotonic (F2) proves the cold-start
// cursor is monotonic: a restart whose chosen RPC nonce LAGS the stored
// cursor (because an abandoned-unfilled hole advanced the cursor past the
// chain's pending nonce) must NOT drop the cursor and erase the hole.
// Before the MAX() fix, UpsertNonceCursor overwrote the cursor to N,
// making expected==observed==N so the very next checkNonceGap saw no gap
// and allocated into the hole. After the fix the cursor stays N+1 and the
// gap is still detected + halted.
func TestRunner_NonceGap_RestartCursorMonotonic(t *testing.T) {
	const N = uint64(7)
	s := setupNonceGapRunner(t, N+1) // stored cursor = expected = N+1
	pid := insertReadyRow(t, s.db, "p1", "settle:p1:restart")
	s.seedAbandonedNonCancel(t, pid, N) // abandoned-unfilled hole at N

	// Simulate a process restart: ColdStartNonceSync chose N (the chain
	// pending nonce lags the DB cursor by 1). UpsertNonceCursor must keep
	// the higher stored value.
	if err := UpsertNonceCursor(context.Background(), s.db, s.hotAddr, N, N, N, NowUTC()); err != nil {
		t.Fatalf("UpsertNonceCursor (restart): %v", err)
	}
	cur, ok, err := ReadNonceCursor(context.Background(), s.db, s.hotAddr)
	if err != nil || !ok {
		t.Fatalf("ReadNonceCursor: ok=%v err=%v", ok, err)
	}
	if cur != N+1 {
		t.Fatalf("cursor regressed to %d after lagging restart, want %d (MAX must hold the hole)", cur, N+1)
	}

	// R4 MEDIUM (non-vacuous zero-allocation): seed a SELECTABLE ready
	// payout for a DIFFERENT provider so a regression that dropped the
	// cursor / erased the hole WOULD fresh-allocate + broadcast it. Makes
	// the zero-alloc / zero-broadcast asserts below non-vacuous.
	insertPayoutAddress(t, s.db, "p2", s.hotAddr)
	insertReadyRow(t, s.db, "p2", "settle:p2:restart-selectable")

	// The gap is still detectable + halts.
	s.setPending(N) // observed = N < expected = N+1
	baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)
	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if findEvent(t, s.buf, "payout_nonce_gap") == nil {
		t.Fatalf("payout_nonce_gap not detected after monotonic restart; log=%s", s.buf.String())
	}
	if *s.sent {
		t.Error("cycle broadcast on a halted nonce-gap cycle after restart")
	}
	// R3 MEDIUM: the restart-monotonicity halt must also allocate ZERO nonces.
	assertNoAllocation(t, s, baseCount, baseCursor)
}
