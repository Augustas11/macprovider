package sqlite

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func fallbackTestCandidate(t *testing.T, store *Store) storage.SettlementFallbackCandidate {
	t.Helper()
	createAccount(t, store, "acct_fallback")
	now := fixedTime()
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID: "acct_fallback", RequestID: "req_fallback", WindowDate: now.Format("2006-01-02"),
		RequestedTokens: 10, DailyQuota: 100, CreatedAt: now, ExpiresAt: now.Add(time.Minute),
	}); err != nil {
		t.Fatal(err)
	}
	return storage.SettlementFallbackCandidate{
		AccountID: "acct_fallback", RequestID: "req_fallback", ReservationCreatedAt: now,
		RequiredInternalRequestID: "internal_req_fallback",
		WindowDate:                now.Format("2006-01-02"), PromptTokens: 2, CompletionTokens: 3,
		MaxTotalTokens: 10, TokenSource: "gateway_estimated", Outcome: "unverified_streaming",
	}
}

func TestSettlementFallbackCandidateIdempotentAndReservationBound(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	candidate := fallbackTestCandidate(t, store)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err != nil {
				t.Errorf("save: %v", err)
			}
		}()
	}
	wg.Wait()
	for _, change := range []func(*storage.SettlementFallbackCandidate){
		func(c *storage.SettlementFallbackCandidate) { c.CompletionTokens++ },
		func(c *storage.SettlementFallbackCandidate) { c.RequiredInternalRequestID = "other_attempt" },
		func(c *storage.SettlementFallbackCandidate) { c.RequiredInternalRequestID = "" },
		func(c *storage.SettlementFallbackCandidate) {
			c.ReservationCreatedAt = c.ReservationCreatedAt.Add(time.Second)
		},
		func(c *storage.SettlementFallbackCandidate) { c.AccountID = "other" },
		func(c *storage.SettlementFallbackCandidate) { c.WindowDate = "2026-05-30" },
		func(c *storage.SettlementFallbackCandidate) { c.WalletSessionID = "other" },
		func(c *storage.SettlementFallbackCandidate) { c.MaxTotalTokens++ },
		func(c *storage.SettlementFallbackCandidate) { c.TokenSource = "coordinator_observed" },
		func(c *storage.SettlementFallbackCandidate) {
			c.CompletionTokens = 11
			c.DemoIdentity = "192.0.2.1"
			c.DemoTokenHash = "demo-hash"
		},
	} {
		changed := candidate
		change(&changed)
		if err := store.SaveSettlementFallbackCandidate(ctx, changed); err == nil {
			t.Fatal("mismatched candidate accepted")
		}
	}
	rows, err := store.ListSettlementHeldReservations(ctx, 10)
	if err != nil || len(rows) != 1 {
		t.Fatalf("holds=%d err=%v", len(rows), err)
	}
	got, err := store.LookupSettlementFallbackCandidate(ctx, rows[0])
	if err != nil || got != candidate {
		t.Fatalf("candidate=%+v err=%v", got, err)
	}
	if n, err := store.ReapExpiredReservations(ctx, fixedTime().Add(time.Hour)); err != nil || n != 0 {
		t.Fatalf("candidate hold reaped=%d err=%v", n, err)
	}
}

func TestSettlementFallbackCandidateWithoutCurrentInternalRequestRemainsHeld(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	candidate := fallbackTestCandidate(t, store)
	for _, invalid := range []string{"   ", strings.Repeat("x", 129)} {
		candidate.RequiredInternalRequestID = invalid
		if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err == nil {
			t.Fatal("candidate with invalid current internal request persisted")
		}
	}
	var count int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM settlement_fallback_candidates`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("invalid candidates=%d err=%v", count, err)
	}
	if rows, err := store.ListSettlementHeldReservations(ctx, 10); err != nil || len(rows) != 0 {
		t.Fatalf("invalid candidate changed holds=%d err=%v", len(rows), err)
	}
	candidate.RequiredInternalRequestID = ""
	if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err != nil {
		t.Fatal(err)
	}
	rows, err := store.ListSettlementHeldReservations(ctx, 10)
	if err != nil || len(rows) != 1 {
		t.Fatalf("quarantined holds=%d err=%v", len(rows), err)
	}
	got, err := store.LookupSettlementFallbackCandidate(ctx, rows[0])
	if err != nil || got != candidate {
		t.Fatalf("quarantined candidate=%+v err=%v", got, err)
	}
	if n, err := store.ReapExpiredReservations(ctx, fixedTime().Add(24*time.Hour)); err != nil || n != 0 {
		t.Fatalf("quarantined holds reaped=%d err=%v", n, err)
	}
	candidate.RequiredInternalRequestID = "inferred_later_attempt"
	if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err == nil {
		t.Fatal("quarantined candidate binding replaced")
	}
}

func TestSettlementFallbackCandidateSaveRollbackAndReusedID(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	candidate := fallbackTestCandidate(t, store)
	if _, err := store.db.Exec(`CREATE TRIGGER fail_fallback_hold BEFORE UPDATE ON quota_reservations BEGIN SELECT RAISE(ABORT, 'test failure'); END`); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err == nil {
		t.Fatal("save unexpectedly succeeded")
	}
	var count int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM settlement_fallback_candidates`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("rolled-back candidates=%d err=%v", count, err)
	}
	if _, err := store.db.Exec(`DROP TRIGGER fail_fallback_hold`); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err != nil {
		t.Fatal(err)
	}
	if err := store.RefundReservation(ctx, candidate.AccountID, candidate.RequestID, fixedTime().Unix()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`DELETE FROM quota_reservations WHERE account_id = ? AND request_id = ?`, candidate.AccountID, candidate.RequestID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: candidate.AccountID, RequestID: candidate.RequestID, WindowDate: candidate.WindowDate,
		RequestedTokens: 10, DailyQuota: 100, CreatedAt: fixedTime().Add(time.Second), ExpiresAt: fixedTime().Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err == nil {
		t.Fatal("old candidate accepted for reused request id")
	}
	if _, err := store.LookupSettlementFallbackCandidate(ctx, storage.ActiveReservation{
		AccountID: candidate.AccountID, RequestID: candidate.RequestID, CreatedAt: candidate.ReservationCreatedAt,
	}); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("stale lookup err=%v", err)
	}
	settlement := storage.ReservationSettlement{
		ExpectedReservationCreatedAt: candidate.ReservationCreatedAt, AccountID: candidate.AccountID,
		RequestID: candidate.RequestID, PromptTokens: 2, CompletionTokens: 3, TotalTokens: 5, MaxTotalTokens: 10,
		TokenSource: candidate.TokenSource, Outcome: candidate.Outcome,
	}
	if err := store.SettleReservation(ctx, settlement); !errors.Is(err, storage.ErrReservationNotFound) {
		t.Fatalf("stale account settlement err=%v", err)
	}
	if err := store.SettleDemoReservation(ctx, settlement, storage.DemoUsageEvent{}); !errors.Is(err, storage.ErrReservationNotFound) {
		t.Fatalf("stale demo settlement err=%v", err)
	}
	used, reserved, err := store.DailyUsage(ctx, candidate.AccountID, candidate.WindowDate)
	if err != nil || used != 0 || reserved != 10 {
		t.Fatalf("used=%d reserved=%d err=%v", used, reserved, err)
	}
}

func TestSettlementFallbackWalletGenerationFence(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_wallet_fallback", "ws_fallback", 100, 10)
	request := walletAdmission("acct_wallet_fallback", "ws_fallback", "req_wallet_fallback", 10)
	if _, err := store.AdmitWalletSessionInference(ctx, request); err != nil {
		t.Fatal(err)
	}
	candidate := storage.SettlementFallbackCandidate{
		AccountID: request.AccountID, RequestID: request.RequestID, WalletSessionID: request.SessionID,
		RequiredInternalRequestID: "internal_req_wallet_fallback",
		ReservationCreatedAt:      request.CreatedAt, WindowDate: request.WindowDate,
		PromptTokens: 2, CompletionTokens: 3, MaxTotalTokens: 10, TokenSource: "provider_reported", Outcome: "unverified_streaming",
	}
	if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err != nil {
		t.Fatal(err)
	}
	settlement := storage.WalletSessionReservationSettlement{
		ExpectedReservationCreatedAt: request.CreatedAt.Add(time.Second), AccountID: request.AccountID,
		SessionID: request.SessionID, RequestID: request.RequestID, PromptTokens: 2, CompletionTokens: 3,
		TotalTokens: 5, MaxTotalTokens: 10, TokenSource: candidate.TokenSource, Outcome: candidate.Outcome,
	}
	if err := store.FinalizeWalletSessionReservation(ctx, settlement); !errors.Is(err, storage.ErrReservationNotFound) {
		t.Fatalf("stale wallet settlement err=%v", err)
	}
	settlement.ExpectedReservationCreatedAt = request.CreatedAt
	if err := store.FinalizeWalletSessionReservation(ctx, settlement); err != nil {
		t.Fatal(err)
	}
	if err := store.FinalizeWalletSessionReservation(ctx, settlement); !errors.Is(err, storage.ErrReservationTerminal) {
		t.Fatalf("duplicate wallet settlement err=%v", err)
	}
}

func TestSettlementFallbackReconcileAttemptIsMonotonicAndGenerationBound(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	candidate := fallbackTestCandidate(t, store)
	reservation := storage.ActiveReservation{
		AccountID: candidate.AccountID, RequestID: candidate.RequestID, CreatedAt: candidate.ReservationCreatedAt,
	}
	if err := store.MarkSettlementReconcileAttempt(ctx, reservation); !errors.Is(err, storage.ErrReservationNotFound) {
		t.Fatalf("unheld mark err=%v", err)
	}
	if err := store.SaveSettlementFallbackCandidate(ctx, candidate); err != nil {
		t.Fatal(err)
	}
	sequence := func() int64 {
		t.Helper()
		var value int64
		if err := store.db.QueryRow(`SELECT COALESCE(MAX(attempt_sequence), 0) FROM settlement_reconcile_attempts`).Scan(&value); err != nil {
			t.Fatal(err)
		}
		return value
	}
	for i := 0; i < 2; i++ {
		if rows, err := store.ListSettlementHeldReservations(ctx, 10); err != nil || len(rows) != 1 {
			t.Fatalf("list rows=%d err=%v", len(rows), err)
		}
	}
	if got := sequence(); got != 0 {
		t.Fatalf("read-only listing changed sequence=%d", got)
	}
	if err := store.MarkSettlementReconcileAttempt(ctx, reservation); err != nil {
		t.Fatal(err)
	}
	first := sequence()
	if err := store.MarkSettlementReconcileAttempt(ctx, reservation); err != nil {
		t.Fatal(err)
	}
	second := sequence()
	if first == 0 || second <= first {
		t.Fatalf("retry sequence did not advance: %d -> %d", first, second)
	}
	stale := reservation
	stale.CreatedAt = stale.CreatedAt.Add(time.Second)
	if err := store.MarkSettlementReconcileAttempt(ctx, stale); !errors.Is(err, storage.ErrReservationNotFound) {
		t.Fatalf("stale generation mark err=%v", err)
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if err := store.MarkSettlementReconcileAttempt(canceled, reservation); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled mark err=%v", err)
	}
	if got := sequence(); got != second {
		t.Fatalf("failed mark changed sequence: %d -> %d", second, got)
	}
	if err := store.RefundReservation(ctx, candidate.AccountID, candidate.RequestID, fixedTime().Unix()); err != nil {
		t.Fatal(err)
	}
	if err := store.MarkSettlementReconcileAttempt(ctx, reservation); !errors.Is(err, storage.ErrReservationNotFound) {
		t.Fatalf("terminal mark err=%v", err)
	}
	if got := sequence(); got != second {
		t.Fatalf("terminal mark changed sequence: %d -> %d", second, got)
	}
}
