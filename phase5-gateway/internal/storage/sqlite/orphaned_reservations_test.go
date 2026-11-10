package sqlite

import (
	"context"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// #2268: a gateway restarted mid-request must release the reservations the
// previous process left active, so the Pearl drain does not wait 24 h.

func reserveOrphanFixture(t *testing.T, store *Store, accountID, requestID string, tokens int64, created time.Time) {
	t.Helper()
	ctx := context.Background()
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: accountID, RequestID: requestID, WindowDate: "2026-05-29",
		RequestedTokens: tokens, DailyQuota: 1000, CreatedAt: created, ExpiresAt: created.Add(24 * time.Hour),
	}); err != nil {
		t.Fatalf("ReserveQuota %s: %v", requestID, err)
	}
	if _, err := store.AcquireConcurrency(ctx, storage.ConcurrencyRequest{
		AccountID: accountID, RequestID: requestID, Limit: 10, CreatedAt: created, ExpiresAt: created.Add(time.Hour),
	}); err != nil {
		t.Fatalf("AcquireConcurrency %s: %v", requestID, err)
	}
}

func reservationStatuses(t *testing.T, store *Store, accountID, requestID string) (quota string, hold int, concurrency string) {
	t.Helper()
	if err := store.db.QueryRow(`SELECT status, settlement_hold FROM quota_reservations WHERE account_id = ? AND request_id = ?`,
		accountID, requestID).Scan(&quota, &hold); err != nil {
		t.Fatalf("quota status %s: %v", requestID, err)
	}
	if err := store.db.QueryRow(`SELECT status FROM concurrency_reservations WHERE account_id = ? AND request_id = ?`,
		accountID, requestID).Scan(&concurrency); err != nil {
		t.Fatalf("concurrency status %s: %v", requestID, err)
	}
	return quota, hold, concurrency
}

func TestReleaseOrphanedReservationsExpiresPreviousProcessRows(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_orphan")
	bootedAt := fixedTime()
	// Left by the previous process, 5 s before this one started: active,
	// no settlement hold, 24 h of expiry left.
	reserveOrphanFixture(t, store, "acct_orphan", "req_orphan", 300, bootedAt.Add(-5*time.Second))
	// Admitted by this process.
	reserveOrphanFixture(t, store, "acct_orphan", "req_current", 200, bootedAt.Add(2*time.Second))
	// Same second as boot: kept, created_at only sorts to the second.
	reserveOrphanFixture(t, store, "acct_orphan", "req_boot_second", 100, bootedAt.Add(400*time.Millisecond))

	_, reservedBefore, err := store.DailyUsage(ctx, "acct_orphan", bootedAt.Format("2006-01-02"))
	if err != nil {
		t.Fatalf("DailyUsage before: %v", err)
	}
	if reservedBefore != 600 {
		t.Fatalf("reserved before=%d want 600", reservedBefore)
	}
	// The 24 h reaper leaves it: expiry is far away.
	if reaped, err := store.ReapExpiredReservations(ctx, bootedAt.Add(3*time.Second)); err != nil || reaped != 0 {
		t.Fatalf("ReapExpiredReservations reaped=%d err=%v, want 0", reaped, err)
	}

	releasedAt := bootedAt.Add(3 * time.Second)
	quota, concurrency, err := store.ReleaseOrphanedReservations(ctx, bootedAt, releasedAt)
	if err != nil {
		t.Fatalf("ReleaseOrphanedReservations: %v", err)
	}
	if quota != 1 || concurrency != 1 {
		t.Fatalf("released quota=%d concurrency=%d, want 1 and 1", quota, concurrency)
	}

	q, hold, c := reservationStatuses(t, store, "acct_orphan", "req_orphan")
	if q != "expired" || hold != 0 || c != "expired" {
		t.Fatalf("orphan quota=%s hold=%d concurrency=%s, want expired/0/expired", q, hold, c)
	}
	var settledTokens int64
	var settledAt, releasedAtRaw string
	if err := store.db.QueryRow(`SELECT settled_tokens, settled_at FROM quota_reservations WHERE request_id = 'req_orphan'`).
		Scan(&settledTokens, &settledAt); err != nil {
		t.Fatalf("orphan quota row: %v", err)
	}
	if settledTokens != 0 || !decodeTime(settledAt).Equal(releasedAt) {
		t.Fatalf("orphan settled_tokens=%d settled_at=%s, want 0 at %s", settledTokens, settledAt, releasedAt)
	}
	if err := store.db.QueryRow(`SELECT released_at FROM concurrency_reservations WHERE request_id = 'req_orphan'`).
		Scan(&releasedAtRaw); err != nil {
		t.Fatalf("orphan concurrency row: %v", err)
	}
	if !decodeTime(releasedAtRaw).Equal(releasedAt) {
		t.Fatalf("orphan released_at=%s want %s", releasedAtRaw, releasedAt)
	}
	for _, requestID := range []string{"req_current", "req_boot_second"} {
		if q, hold, c := reservationStatuses(t, store, "acct_orphan", requestID); q != "active" || hold != 0 || c != "active" {
			t.Fatalf("%s quota=%s hold=%d concurrency=%s, want untouched active", requestID, q, hold, c)
		}
	}
	_, reservedAfter, err := store.DailyUsage(ctx, "acct_orphan", bootedAt.Format("2006-01-02"))
	if err != nil {
		t.Fatalf("DailyUsage after: %v", err)
	}
	if reservedAfter != 300 {
		t.Fatalf("reserved after=%d want 300 (orphan's 300 returned)", reservedAfter)
	}

	// Idempotent: a second sweep finds nothing.
	if quota, concurrency, err := store.ReleaseOrphanedReservations(ctx, bootedAt, releasedAt); err != nil || quota != 0 || concurrency != 0 {
		t.Fatalf("second sweep quota=%d concurrency=%d err=%v, want 0/0/nil", quota, concurrency, err)
	}
}

func TestReleaseOrphanedReservationsLeavesSettlementHoldsToReconciler(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_orphan_held")
	bootedAt := fixedTime()
	reserveOrphanFixture(t, store, "acct_orphan_held", "req_held", 40, bootedAt.Add(-time.Minute))
	if err := store.MarkReservationSettlementHold(ctx, "acct_orphan_held", "req_held"); err != nil {
		t.Fatalf("MarkReservationSettlementHold: %v", err)
	}

	quota, concurrency, err := store.ReleaseOrphanedReservations(ctx, bootedAt, bootedAt)
	if err != nil {
		t.Fatalf("ReleaseOrphanedReservations: %v", err)
	}
	if quota != 0 || concurrency != 1 {
		t.Fatalf("released quota=%d concurrency=%d, want 0 and 1", quota, concurrency)
	}
	q, hold, c := reservationStatuses(t, store, "acct_orphan_held", "req_held")
	if q != "active" || hold != 1 {
		t.Fatalf("held quota=%s hold=%d, want active/1 for the SPEC-022 reconciler", q, hold)
	}
	if c != "expired" {
		t.Fatalf("held row concurrency=%s want expired (the stream is gone)", c)
	}
	held, err := store.ListSettlementHeldReservations(ctx, 10)
	if err != nil {
		t.Fatalf("ListSettlementHeldReservations: %v", err)
	}
	if len(held) != 1 || held[0].RequestID != "req_held" {
		t.Fatalf("held reservations=%+v, want req_held", held)
	}
}

func TestReleaseOrphanedReservationsLeavesWalletSessionRowsToWalletRecovery(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_orphan_wallet", "ws_orphan", 100, 50)
	if _, err := store.AdmitWalletSessionInference(ctx, walletAdmission("acct_orphan_wallet", "ws_orphan", "req_orphan_wallet", 20)); err != nil {
		t.Fatalf("AdmitWalletSessionInference: %v", err)
	}

	quota, _, err := store.ReleaseOrphanedReservations(ctx, fixedTime().Add(time.Hour), fixedTime().Add(time.Hour))
	if err != nil {
		t.Fatalf("ReleaseOrphanedReservations: %v", err)
	}
	if quota != 0 {
		t.Fatalf("released quota=%d want 0 for a wallet-session reservation", quota)
	}
	var status string
	if err := store.db.QueryRow(`SELECT status FROM quota_reservations WHERE request_id = 'req_orphan_wallet'`).Scan(&status); err != nil {
		t.Fatalf("wallet quota row: %v", err)
	}
	if status != "active" {
		t.Fatalf("wallet quota status=%s want active", status)
	}
}

func TestReleaseOrphanedReservationsRejectsZeroBootTime(t *testing.T) {
	store := newTestStore(t)
	if _, _, err := store.ReleaseOrphanedReservations(context.Background(), time.Time{}, fixedTime()); err == nil {
		t.Fatal("ReleaseOrphanedReservations with zero bootedAt succeeded; want an error")
	}
}
