package payout

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"testing"
)

// R2-HIGH recovery-only regression suite (architect Option A + targeting
// rider). Common shape: cursor = N+1, chain pending = N, a rebroadcastable
// crash-recovery attempt R at nonce N for payout P_rec, plus a second ready
// row P2 with NO existing attempt and a payout-allowed address — so P2 WOULD
// fresh-allocate if the gate leaked. checkNonceGap therefore returns
// gapRecoveryOnly; the cycle must drive R's rebroadcast + suppress ALL fresh
// allocation.

// countingSigner wraps a Signer to prove the fresh-allocation path (the ONLY
// SignTx caller) is never reached in a recovery-only cycle. Rebroadcast
// re-sends persisted bytes and never signs.
type countingSigner struct {
	inner Signer
	calls int
}

func (c *countingSigner) FromAddress() string { return c.inner.FromAddress() }

func (c *countingSigner) SignTx(ctx context.Context, unsignedTxBytes []byte) ([]byte, string, error) {
	c.calls++
	return c.inner.SignTx(ctx, unsignedTxBytes)
}

// recoveryRawBytes mirrors the raw_signed_tx seeded by
// seedLivePersistedUnbroadcast (X'0102'). A broadcast of exactly these bytes
// is the recovery rebroadcast; anything else is a FRESH broadcast.
var recoveryRawBytes = []byte{0x01, 0x02}

// broadcastRecorder classifies each SendRawTransaction call as a recovery
// rebroadcast (raw == X'0102') or a fresh broadcast (a real signed tx).
type broadcastRecorder struct {
	recovery int
	fresh    int
}

func (s *nonceGapSetup) installSigner(t *testing.T) *countingSigner {
	t.Helper()
	cs := &countingSigner{inner: s.runner.opts.Signer}
	s.runner.opts.Signer = cs
	return cs
}

// installBroadcastRecorder wires both RPC sendFns to classify broadcasts.
// recoveryOK controls whether the recovery rebroadcast is accepted (T2/T4) or
// rejected on both RPCs (T1). Fresh broadcasts always "succeed" so a leaked
// fresh allocation would be unmistakably visible.
func (s *nonceGapSetup) installBroadcastRecorder(t *testing.T, recoveryOK bool) *broadcastRecorder {
	t.Helper()
	rec := &broadcastRecorder{}
	fn := func(_ context.Context, raw []byte) (string, error) {
		if bytes.Equal(raw, recoveryRawBytes) {
			rec.recovery++
			if !recoveryOK {
				// Non nonce-too-low rejection on both RPCs → acceptedAny=false.
				return "", fmt.Errorf("rpc rejected rebroadcast")
			}
			return "0xrecoveryhash", nil
		}
		rec.fresh++
		*s.sent = true
		return "0xfreshhash", nil
	}
	s.runner.opts.RPCs.Primary.(*mockRPCClient).sendFn = fn
	s.runner.opts.RPCs.Secondary.(*mockRPCClient).sendFn = fn
	return rec
}

// rpcCallCounts tallies the confirmation/verification RPC calls a cycle makes
// so a test can prove WHICH dispatch path ran (not merely its outcome):
//   - receipt   → TransactionReceipt: the poll path (pollCancelOnce for a
//     broadcast-unconfirmed cancel, pollAndConfirm for the normal USDC path).
//   - txByHash  → TransactionByHash: reached only inside the verification
//     bodies (verifyCancelTxView / verifyChainSideTransfer) after a confirmed
//     receipt — i.e. the ERC-20 Transfer-log / cancel-tx-body verification.
//   - callUSDC  → CallContract to the USDC contract: balance/verify reads.
type rpcCallCounts struct {
	receipt  int
	txByHash int
	callUSDC int
}

// installRPCCallCounters wires counting closures onto both RPCs' receipt,
// tx-by-hash, and call-contract methods. Each closure preserves the mock's
// default "absent" return (receipt/tx nil, empty call result) so runner
// behavior is unchanged — only observability is added. Sequential RPC use
// (BroadcastBoth / pollAndConfirm / pollCancelOnce all call Primary then
// Secondary in-goroutine) makes the plain int counters race-safe.
func (s *nonceGapSetup) installRPCCallCounters(t *testing.T) *rpcCallCounts {
	t.Helper()
	c := &rpcCallCounts{}
	for _, rpc := range []*mockRPCClient{
		s.runner.opts.RPCs.Primary.(*mockRPCClient),
		s.runner.opts.RPCs.Secondary.(*mockRPCClient),
	} {
		rpc.receiptFn = func(context.Context, string) (*Receipt, error) { c.receipt++; return nil, nil }
		rpc.txByHashFn = func(context.Context, string) (*Transaction, error) { c.txByHash++; return nil, nil }
		rpc.callFn = func(context.Context, string, []byte) ([]byte, error) { c.callUSDC++; return nil, nil }
	}
	return c
}

// broadcastAtNull reports whether the attempt at (hot wallet, nonce) still has
// a NULL broadcast_at_utc.
func (s *nonceGapSetup) broadcastAtNull(t *testing.T, nonce uint64) bool {
	t.Helper()
	var isNull int
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT broadcast_at_utc IS NULL FROM payout_attempts
		  WHERE from_address = ? AND nonce = ? ORDER BY attempt_seq DESC LIMIT 1`,
		strings.ToLower(s.hotAddr), int64(nonce)).Scan(&isNull); err != nil {
		t.Fatalf("broadcastAtNull query: %v", err)
	}
	return isNull == 1
}

// insertPayoutAddressAllowed inserts a provider_payout_addresses row with an
// explicit payout_allowed flag (insertPayoutAddress hardcodes allowed=1).
func insertPayoutAddressAllowed(t *testing.T, s *nonceGapSetup, providerID string, allowed int) {
	t.Helper()
	canonicalHot, err := CanonicalizeEIP55(s.hotAddr)
	if err != nil {
		t.Fatalf("canonicalize hot wallet: %v", err)
	}
	past := "2026-01-01T00:00:00Z"
	providerAddr := "0x000000000000000000000000000000000000dEaD"
	if _, err := s.db.ExecContext(context.Background(), `
INSERT INTO provider_payout_addresses
  (provider_id, chain, address, payout_allowed, pending_until_utc,
   rotated_from, registered_at_utc, registered_against_hot_wallet)
VALUES (?, 'base-mainnet', ?, ?, ?, NULL, ?, ?)`,
		providerID, providerAddr, allowed, past, past, canonicalHot); err != nil {
		t.Fatalf("insert payout address: %v", err)
	}
}

// TestRecoveryOnly_T1_RebroadcastFailsBoth_NoFreshAlloc: R's rebroadcast is
// rejected on both RPCs; P2 must still NOT fresh-allocate. Proves the
// pre-fix HIGH bug (fresh-alloc past the hole when recovery fails) is closed.
func TestRecoveryOnly_T1_RebroadcastFailsBoth_NoFreshAlloc(t *testing.T) {
	const N = uint64(4)
	s := setupNonceGapRunner(t, N+1) // cursor = expected = N+1
	insertPayoutAddress(t, s.db, "p_rec", s.hotAddr)
	insertPayoutAddress(t, s.db, "p2", s.hotAddr)
	pRec := insertReadyRow(t, s.db, "p_rec", "settle:p_rec:t1")
	_ = insertReadyRow(t, s.db, "p2", "settle:p2:t1")
	s.seedLivePersistedUnbroadcast(t, pRec, N) // rebroadcastable R at N
	s.setPending(N)                            // observed = N < expected = N+1

	cs := s.installSigner(t)
	rec := s.installBroadcastRecorder(t, false /*recoveryOK*/)
	baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)

	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if !s.broadcastAtNull(t, N) {
		t.Error("R.broadcast_at_utc was stamped despite both-RPC rejection")
	}
	assertNoAllocation(t, s, baseCount, baseCursor) // no P2 attempt, cursor unmoved
	if cs.calls != 0 {
		t.Errorf("SignTx calls = %d, want 0 (no fresh allocation in recovery-only)", cs.calls)
	}
	if rec.fresh != 0 {
		t.Errorf("fresh broadcasts = %d, want 0", rec.fresh)
	}
	if rec.recovery == 0 {
		t.Error("recovery rebroadcast was never attempted")
	}
	if findEvent(t, s.buf, "payout_nonce_gap_recovery_only") == nil {
		t.Errorf("payout_nonce_gap_recovery_only not emitted; log=%s", s.buf.String())
	}
}

// TestRecoveryOnly_T2_RecoveryExcluded_PausesFailClosed: P_rec is absent from
// SelectReadyPayouts (payout_allowed=0, then LIMIT off-page). With the R2
// targeting rider deleted, an UNSELECTABLE recovery is no longer driven
// out-of-band — the wallet PAUSES fail-closed: zero fresh allocation for the
// second ready row P2, cursor unchanged, no signing, no broadcast at all, and
// the per-cycle payout_nonce_gap_recovery_only WARN fires so the stuck hole is
// visible to the operator until they intervene. (The intentional round-2
// "rider drives recovery despite exclusion" behavior is removed as defective.)
func TestRecoveryOnly_T2_RecoveryExcluded_PausesFailClosed(t *testing.T) {
	const N = uint64(4)

	assertPaused := func(t *testing.T, s *nonceGapSetup, cs *countingSigner, rec *broadcastRecorder, baseCount int, baseCursor uint64) {
		t.Helper()
		if cs.calls != 0 {
			t.Errorf("SignTx calls = %d, want 0 (fail-closed pause: no fresh allocation)", cs.calls)
		}
		if rec.fresh != 0 {
			t.Errorf("fresh broadcasts = %d, want 0", rec.fresh)
		}
		if rec.recovery != 0 {
			t.Errorf("recovery rebroadcasts = %d, want 0 (unselectable recovery is NOT driven out-of-band)", rec.recovery)
		}
		if *s.sent {
			t.Error("a transaction was broadcast during a fail-closed recovery-only pause")
		}
		// P2 must have zero new attempt; the cursor must not bump. R's row
		// existed at baseline, so baseCount already includes it.
		assertNoAllocation(t, s, baseCount, baseCursor)
		if findEvent(t, s.buf, "payout_nonce_gap_recovery_only") == nil {
			t.Errorf("payout_nonce_gap_recovery_only WARN not emitted on fail-closed pause; log=%s", s.buf.String())
		}
	}

	t.Run("payout_allowed_0", func(t *testing.T) {
		s := setupNonceGapRunner(t, N+1)
		insertPayoutAddressAllowed(t, s, "p_rec", 0)  // NOT selectable
		insertPayoutAddress(t, s.db, "p2", s.hotAddr) // allowed
		pRec := insertReadyRow(t, s.db, "p_rec", "settle:p_rec:t2a")
		_ = insertReadyRow(t, s.db, "p2", "settle:p2:t2a")
		s.seedLivePersistedUnbroadcast(t, pRec, N)
		s.setPending(N)

		cs := s.installSigner(t)
		rec := s.installBroadcastRecorder(t, true /*recoveryOK*/)
		baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)

		if _, err := s.runner.RunOnce(context.Background()); err != nil {
			t.Fatalf("RunOnce: %v", err)
		}
		assertPaused(t, s, cs, rec, baseCount, baseCursor)
	})

	t.Run("off_page_via_limit", func(t *testing.T) {
		s := setupNonceGapRunner(t, N+1)
		s.runner.opts.MaxRowsPerRun = 1 // only the first row by id is selected
		// P2 gets the lower id so it fills the single SELECT slot; P_rec is
		// off-page. With the rider gone it is unreachable this cycle → pause.
		insertPayoutAddress(t, s.db, "p2", s.hotAddr)
		insertPayoutAddress(t, s.db, "p_rec", s.hotAddr)
		_ = insertReadyRow(t, s.db, "p2", "settle:p2:t2b")
		pRec := insertReadyRow(t, s.db, "p_rec", "settle:p_rec:t2b")
		s.seedLivePersistedUnbroadcast(t, pRec, N)
		s.setPending(N)

		cs := s.installSigner(t)
		rec := s.installBroadcastRecorder(t, true /*recoveryOK*/)
		baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)

		if _, err := s.runner.RunOnce(context.Background()); err != nil {
			t.Fatalf("RunOnce: %v", err)
		}
		assertPaused(t, s, cs, rec, baseCount, baseCursor)
	})
}

// TestRecoveryOnly_T3_Liveness_FreshAllocProceeds proves recovery-only mode
// does NOT leak into the steady-state happy path: observed==expected →
// gapProceed → a fresh allocation happens (attempt inserted + cursor bumped +
// fresh broadcast). This is the guard against a gate that latches safe forever.
func TestRecoveryOnly_T3_Liveness_FreshAllocProceeds(t *testing.T) {
	const N = uint64(5)
	s := setupNonceGapRunner(t, N) // cursor == chain pending == steady state
	insertPayoutAddress(t, s.db, "p1", s.hotAddr)
	_ = insertReadyRow(t, s.db, "p1", "settle:p1:t3")
	s.setPending(N) // observed == expected → gapProceed

	cs := s.installSigner(t)
	rec := s.installBroadcastRecorder(t, true)
	baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)

	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if got := s.attemptCount(t); got != baseCount+1 {
		t.Errorf("attempt count = %d, want %d (fresh allocation must insert one attempt)", got, baseCount+1)
	}
	if got := s.cursorNow(t); got != baseCursor+1 {
		t.Errorf("cursor = %d, want %d (fresh allocation must bump the cursor)", got, baseCursor+1)
	}
	if cs.calls != 1 {
		t.Errorf("SignTx calls = %d, want 1 (one fresh allocation)", cs.calls)
	}
	if rec.fresh != 2 { // both RPCs
		t.Errorf("fresh broadcasts = %d, want 2 (both RPCs, one fresh tx)", rec.fresh)
	}
	if findEvent(t, s.buf, "payout_nonce_gap_recovery_only") != nil {
		t.Error("steady state must NOT emit payout_nonce_gap_recovery_only")
	}
}

// TestRecoveryOnly_T4_Convergence: cycle 1 accepts R's rebroadcast (stamps
// broadcast_at) but does NOT fresh-allocate P2 that same cycle; cycle 2 (now
// observed==expected) proceeds normally and P2 fresh-allocates. Proves the
// gate does not half-open mid-cycle and converges the next cycle.
func TestRecoveryOnly_T4_Convergence(t *testing.T) {
	const N = uint64(4)
	s := setupNonceGapRunner(t, N+1)
	insertPayoutAddress(t, s.db, "p_rec", s.hotAddr)
	insertPayoutAddress(t, s.db, "p2", s.hotAddr)
	pRec := insertReadyRow(t, s.db, "p_rec", "settle:p_rec:t4")
	_ = insertReadyRow(t, s.db, "p2", "settle:p2:t4")
	s.seedLivePersistedUnbroadcast(t, pRec, N)
	s.setPending(N) // observed = N < expected = N+1 → recovery-only

	cs := s.installSigner(t)
	rec := s.installBroadcastRecorder(t, true /*recoveryOK*/)
	baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)

	// --- Cycle 1: recovery-only ---
	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce cycle1: %v", err)
	}
	if s.broadcastAtNull(t, N) {
		t.Error("cycle1: R.broadcast_at_utc not stamped after accepted rebroadcast")
	}
	if rec.recovery == 0 {
		t.Error("cycle1: recovery rebroadcast not attempted")
	}
	if cs.calls != 0 {
		t.Errorf("cycle1: SignTx calls = %d, want 0 (no fresh alloc mid-recovery)", cs.calls)
	}
	if rec.fresh != 0 {
		t.Errorf("cycle1: fresh broadcasts = %d, want 0", rec.fresh)
	}
	if got := s.attemptCount(t); got != baseCount {
		t.Errorf("cycle1: attempt count = %d, want %d (P2 must NOT fresh-allocate this cycle)", got, baseCount)
	}
	if got := s.cursorNow(t); got != baseCursor {
		t.Errorf("cycle1: cursor = %d, want %d (must not bump mid-recovery)", got, baseCursor)
	}

	// --- Cycle 2: chain now includes N (R broadcast) → observed = N+1 == expected ---
	s.buf.Reset()
	s.setPending(N + 1)
	cycle2BaseCount := s.attemptCount(t)
	cycle2BaseCursor := s.cursorNow(t)
	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce cycle2: %v", err)
	}
	if findEvent(t, s.buf, "payout_nonce_gap_recovery_only") != nil {
		t.Error("cycle2: must NOT re-enter recovery-only once observed==expected")
	}
	if got := s.attemptCount(t); got != cycle2BaseCount+1 {
		t.Errorf("cycle2: attempt count = %d, want %d (P2 fresh-allocates now)", got, cycle2BaseCount+1)
	}
	if got := s.cursorNow(t); got != cycle2BaseCursor+1 {
		t.Errorf("cycle2: cursor = %d, want %d (fresh allocation bumps cursor)", got, cycle2BaseCursor+1)
	}
	if cs.calls != 1 {
		t.Errorf("cycle2: cumulative SignTx calls = %d, want 1 (one fresh alloc across both cycles)", cs.calls)
	}
}

// seedLivePersistedUnbroadcastCancel inserts a persisted-but-unbroadcast
// cancel-self-transfer (is_cancel_self_transfer=1) occupying `nonce`: raw bytes
// = recoveryRawBytes (so installBroadcastRecorder classifies a rebroadcast of
// it as "recovery", never "fresh"), tx_hash present, broadcast/confirmed/
// abandoned all NULL. This matches rebroadcastableAttemptExists' predicate (no
// is_cancel_self_transfer filter), so checkNonceGap enters gapRecoveryOnly.
func (s *nonceGapSetup) seedLivePersistedUnbroadcastCancel(t *testing.T, payoutID int64, nonce uint64) {
	t.Helper()
	now := NowUTC()
	if _, err := s.db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   is_cancel_self_transfer, updated_at_utc)
VALUES (?, 2, 'base-mainnet', ?, ?,
        1, ?, X'0102', '0xcancelhash', 1, ?)`,
		payoutID, strings.ToLower(s.hotAddr), strings.ToLower(s.hotAddr),
		int64(nonce), now); err != nil {
		t.Fatalf("seed live persisted-unbroadcast cancel: %v", err)
	}
}

// TestRecoveryOnly_CancelAtObserved_UsesCancelPath (R3 regression for the
// deleted rider's cancel-misrouting bug): a persisted-unbroadcast CANCEL
// (is_cancel_self_transfer=1) sits at the on-chain pending nonce and its payout
// IS selectable. checkNonceGap → gapRecoveryOnly, and the NORMAL row loop must
// rebroadcast it via the CANCEL dispatch (rebroadcastCancel), NEVER through the
// generic provider-USDC verification path and NEVER ClaimPayoutReady. The
// deleted rider routed every recovery through rebroadcastAndPoll→pollAndConfirm
// (USDC-transfer verification), which would false-alarm payout_chain_value_mismatch
// on a 1-wei self-transfer. This proves that misrouting is gone.
func TestRecoveryOnly_CancelAtObserved_UsesCancelPath(t *testing.T) {
	const N = uint64(4)
	s := setupNonceGapRunner(t, N+1) // cursor = expected = N+1
	insertPayoutAddress(t, s.db, "p_cancel", s.hotAddr)
	pCancel := insertReadyRow(t, s.db, "p_cancel", "settle:p_cancel:cancelobs")
	s.seedLivePersistedUnbroadcastCancel(t, pCancel, N)
	s.setPending(N) // observed = N < expected = N+1 → recovery-only

	cs := s.installSigner(t)
	rec := s.installBroadcastRecorder(t, true /*recoveryOK*/)
	counts := s.installRPCCallCounters(t)
	claimer := s.runner.opts.Claimer.(*mockClaimer)
	baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)

	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// The cancel was rebroadcast (its raw bytes == recoveryRawBytes → counted
	// as a "recovery" broadcast, not a fresh one) via the CANCEL path.
	if rec.recovery == 0 {
		t.Error("cancel was never rebroadcast via the normal loop's cancel dispatch")
	}
	if rec.fresh != 0 {
		t.Errorf("fresh broadcasts = %d, want 0 (a cancel must not fresh-allocate)", rec.fresh)
	}
	if cs.calls != 0 {
		t.Errorf("SignTx calls = %d, want 0 (cancel rebroadcast re-sends persisted bytes)", cs.calls)
	}
	// R4 MEDIUM (prove the PATH, not just the outcome): an unbroadcast cancel
	// at observed is dispatched through rebroadcastCancel (a pure
	// SendRawTransaction of the persisted envelope — counted above as
	// rec.recovery), and MUST NOT be routed through the generic USDC
	// confirmation/verification path (pollAndConfirm → verifyChainSideTransfer).
	// TransactionReceipt (the poll) and TransactionByHash (the chain-side value
	// verification body) are made ONLY by that path in this cycle, so ZERO such
	// reads proves the misrouting the deleted rider introduced (every recovery
	// through pollAndConfirm's ERC-20 Transfer-log verification, which
	// false-alarms on a 1-wei self-transfer) is gone. (pollCancelOnce itself is
	// unreachable here: it fires only for a broadcast-unconfirmed cancel,
	// whereas checkNonceGap enters recovery-only only for an *unbroadcast*
	// rebroadcastable attempt — so the cancel is dispatched via
	// rebroadcastCancel, never pollCancelOnce. CallContract is NOT asserted: it
	// is the per-cycle hot-wallet USDC balance pre-flight, not part of either
	// dispatch path.)
	if counts.receipt != 0 {
		t.Errorf("TransactionReceipt calls = %d, want 0 (USDC/cancel poll path must not run for a rebroadcast-only cancel)", counts.receipt)
	}
	if counts.txByHash != 0 {
		t.Errorf("TransactionByHash calls = %d, want 0 (chain-side value verification must not run for a cancel)", counts.txByHash)
	}
	// NEVER claim: cancels do NOT consume ledger_payout_ready.
	if len(claimer.calls) != 0 {
		t.Errorf("ClaimPayoutReady calls = %d, want 0 (a cancel must never be claimed)", len(claimer.calls))
	}
	// NEVER the generic USDC-transfer value verification → no false mismatch.
	if ev := findEvent(t, s.buf, "payout_chain_value_mismatch"); ev != nil {
		t.Errorf("payout_chain_value_mismatch wrongly emitted for a cancel: %v", ev)
	}
	// broadcast_at stamped on the cancel (accepted); zero fresh allocation.
	if s.broadcastAtNull(t, N) {
		t.Error("cancel.broadcast_at_utc not stamped after accepted rebroadcast")
	}
	assertNoAllocation(t, s, baseCount, baseCursor)
	if findEvent(t, s.buf, "payout_nonce_gap_recovery_only") == nil {
		t.Errorf("payout_nonce_gap_recovery_only not emitted; log=%s", s.buf.String())
	}
}

// TestRecoveryOnly_DelayedReceipt_PolledByNormalLoop (R3 regression for the
// deleted rider's "accepted-but-delayed recovery left permanently unpolled"
// bug): a recovery rebroadcast is accepted (broadcast_at stamped) but its
// receipt is not yet present. The recovery attempt must keep being polled by
// the NORMAL row loop on subsequent cycles (never stranded), must NOT be
// double-claimed while unconfirmed, and must NOT leak a fresh allocation while
// the hole persists.
func TestRecoveryOnly_DelayedReceipt_PolledByNormalLoop(t *testing.T) {
	const N = uint64(4)
	s := setupNonceGapRunner(t, N+1) // cursor = expected = N+1
	insertPayoutAddress(t, s.db, "p_rec", s.hotAddr)
	pRec := insertReadyRow(t, s.db, "p_rec", "settle:p_rec:delayed")
	s.seedLivePersistedUnbroadcast(t, pRec, N)
	s.setPending(N) // observed = N < expected = N+1 → recovery-only

	cs := s.installSigner(t)
	rec := s.installBroadcastRecorder(t, true /*recoveryOK*/)
	claimer := s.runner.opts.Claimer.(*mockClaimer)
	// Receipt stays absent for the whole test (the counting closures return
	// nil, matching the default receiptFn == nil), so R is accepted into the
	// mempool but never confirms. The counters prove the NORMAL poll path is
	// actually exercised (poll counter > 0) rather than silently skipped —
	// otherwise the "not double-claimed / not stranded" asserts could pass
	// vacuously if polling never ran at all.
	counts := s.installRPCCallCounters(t)
	baseCount, baseCursor := s.attemptCount(t), s.cursorNow(t)

	// --- Cycle 1: recovery-only; rebroadcast accepted + stamped, unconfirmed ---
	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce cycle1: %v", err)
	}
	if s.broadcastAtNull(t, N) {
		t.Error("cycle1: R.broadcast_at_utc not stamped after accepted rebroadcast")
	}
	if rec.recovery == 0 {
		t.Error("cycle1: recovery rebroadcast not attempted")
	}
	if rec.fresh != 0 || cs.calls != 0 {
		t.Errorf("cycle1: fresh=%d SignTx=%d, want 0/0 (no fresh alloc mid-recovery)", rec.fresh, cs.calls)
	}
	if len(claimer.calls) != 0 {
		t.Errorf("cycle1: claim calls = %d, want 0 (receipt absent → not confirmed)", len(claimer.calls))
	}
	// R4 MEDIUM: cycle 1 rebroadcasts R then transitions to pollAndConfirm
	// (the normal poll path), which polls the receipt — so the poll counter
	// must have advanced. A regression that skipped polling would leave it 0.
	if counts.receipt == 0 {
		t.Error("cycle1: normal poll path never invoked (TransactionReceipt count == 0)")
	}
	assertNoAllocation(t, s, baseCount, baseCursor)

	// --- Cycle 2: hole still open (pending lags at N), R now broadcast so no
	// longer rebroadcastable → fail-closed halt; still zero alloc, no claim. ---
	s.buf.Reset()
	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce cycle2: %v", err)
	}
	if len(claimer.calls) != 0 {
		t.Errorf("cycle2: claim calls = %d, want 0", len(claimer.calls))
	}
	assertNoAllocation(t, s, baseCount, baseCursor)

	// --- Cycle 3: pending advances to N+1 (tx reflected) but receipt STILL
	// absent → gapProceed; the NORMAL loop polls R via pollAndConfirm. R stays
	// unconfirmed (not stranded, not double-claimed), no fresh alloc leaks. ---
	s.buf.Reset()
	s.setPending(N + 1)
	pollsBeforeC3 := counts.receipt
	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce cycle3: %v", err)
	}
	// R4 MEDIUM: cycle 3 is gapProceed; the NORMAL row loop must re-poll R via
	// pollAndConfirm. Proven by a fresh TransactionReceipt read this cycle — R
	// is not stranded/left permanently unpolled once the pending nonce catches
	// up. A regression that dropped R from the normal loop would leave this 0.
	if counts.receipt <= pollsBeforeC3 {
		t.Errorf("cycle3: R was not re-polled by the normal loop (receipt count %d, want > %d)", counts.receipt, pollsBeforeC3)
	}
	if len(claimer.calls) != 0 {
		t.Errorf("cycle3: claim calls = %d, want 0 (receipt still absent)", len(claimer.calls))
	}
	// R is still broadcast-but-unconfirmed and was re-polled by the normal
	// loop, not left permanently unpolled.
	if s.broadcastAtNull(t, N) {
		t.Error("cycle3: R.broadcast_at_utc unexpectedly cleared")
	}
	// No fresh attempt was allocated (R is the only ready row); cursor holds.
	assertNoAllocation(t, s, baseCount, baseCursor)
}

// TestRecoveryOnly_MalformedEmptyHash_NotRebroadcast (R2-LOW-2): an attempt
// with non-empty raw_signed_tx but an EMPTY tx_hash is malformed and must NOT
// be rebroadcast — the Go precondition must match the tightened
// rebroadcastableAttemptExists SQL (tx_hash <> ”). It falls through to a
// fail-closed invariant violation, broadcasting nothing.
func TestRecoveryOnly_MalformedEmptyHash_NotRebroadcast(t *testing.T) {
	const N = uint64(5)
	s := setupNonceGapRunner(t, N) // steady state cursor; no gap
	insertPayoutAddress(t, s.db, "p1", s.hotAddr)
	pid := insertReadyRow(t, s.db, "p1", "settle:p1:malformed")
	// Seed an attempt with raw bytes present but tx_hash = '' (empty string,
	// NOT NULL). broadcast/confirmed/abandoned all NULL → processRow's
	// rebroadcast branch (len(raw)>0 && !broadcast && !abandoned) is entered.
	now := NowUTC()
	if _, err := s.db.ExecContext(context.Background(), `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   is_cancel_self_transfer, updated_at_utc)
VALUES (?, 1, 'base-mainnet', ?, '0x00000000000000000000000000000000000000to',
        100, ?, X'0102', '', 0, ?)`,
		pid, strings.ToLower(s.hotAddr), int64(N-1), now); err != nil {
		t.Fatalf("seed malformed attempt: %v", err)
	}
	s.setPending(N) // observed == expected → gapProceed → processRow runs

	if _, err := s.runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if *s.sent {
		t.Error("a malformed empty-tx_hash attempt was rebroadcast (must fail closed)")
	}
	ev := findEvent(t, s.buf, "payout_invariant_violation")
	if ev == nil {
		t.Fatalf("expected payout_invariant_violation for malformed empty-hash row; log=%s", s.buf.String())
	}
	if ev["where"] != "raw_signed_tx_without_hash" {
		t.Errorf("invariant where = %v, want raw_signed_tx_without_hash", ev["where"])
	}
}
