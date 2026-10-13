package sqlite

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// SPEC-050-R007: an allowance-funded reservation is admitted whatever the
// paid quota's remainder and never counts against it, before or after
// settlement.
func TestAllowanceFundedReservationDoesNotDrawPaidQuota(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_allow")
	reserve := func(id string, tokens int64, funding string) (storage.QuotaDecision, error) {
		return store.ReserveQuota(ctx, storage.ReservationRequest{
			AccountID: "acct_allow", RequestID: id, WindowDate: "2026-10-13",
			RequestedTokens: tokens, DailyQuota: 100, CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
			FundingSource: funding,
		})
	}
	if _, err := reserve("req_paid", 90, ""); err != nil {
		t.Fatalf("paid reservation: %v", err)
	}
	// Paid quota now has 10 left; an allowance request bigger than that is
	// still admitted and does not move the paid remainder.
	decision, err := reserve("req_allow", 500, storage.FundingSourceAllowance)
	if err != nil || !decision.Admitted || decision.RemainingTokens != 10 || decision.ReservedTokens != 90 {
		t.Fatalf("allowance reservation = %+v, %v", decision, err)
	}
	if _, err := reserve("req_paid_2", 20, storage.FundingSourceQuota); !errors.Is(err, storage.ErrQuotaExceeded) {
		t.Fatalf("paid reservation over remainder err = %v", err)
	}
	if err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_allow", RequestID: "req_allow", PromptTokens: 200, CompletionTokens: 250,
		TokenSource: "provider_reported", Outcome: "ok", SettledAt: fixedTime().Add(time.Minute),
	}); err != nil {
		t.Fatalf("settle allowance reservation: %v", err)
	}
	used, reserved, err := store.DailyUsage(ctx, "acct_allow", "2026-10-13")
	if err != nil || used != 0 || reserved != 90 {
		t.Fatalf("paid quota used=%d reserved=%d err=%v; allowance usage must not count", used, reserved, err)
	}
	if _, err := reserve("req_bad", 1, "voucher"); err == nil {
		t.Fatal("unknown funding source must be refused")
	}
}
