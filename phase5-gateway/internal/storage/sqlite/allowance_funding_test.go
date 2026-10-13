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

// The settlement writes the coordinator-confirmed funding atomically, so a
// failed early update cannot leave allowance usage on the paid quota.
func TestSettlementWritesConfirmedFunding(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_settle")
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_settle", RequestID: "req_a", WindowDate: "2026-10-13",
		RequestedTokens: 50, DailyQuota: 100, CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_settle", RequestID: "req_a", PromptTokens: 10, CompletionTokens: 20,
		TokenSource: "provider_reported", Outcome: "ok", SettledAt: fixedTime().Add(time.Minute),
		FundingSource: storage.FundingSourceAllowance,
	}); err != nil {
		t.Fatal(err)
	}
	used, reserved, err := store.DailyUsage(ctx, "acct_settle", "2026-10-13")
	if err != nil || used != 0 || reserved != 0 {
		t.Fatalf("used=%d reserved=%d err=%v; allowance-confirmed usage must leave the paid quota", used, reserved, err)
	}
	// An allowance-only reservation the coordinator did not fund is put back
	// on the paid quota, even past its limit.
	if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
		AccountID: "acct_settle", RequestID: "req_b", WindowDate: "2026-10-13",
		RequestedTokens: 500, DailyQuota: 100, CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
		FundingSource: storage.FundingSourceAllowance,
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.MarkReservationFundingSource(ctx, "acct_settle", "req_b", storage.FundingSourceQuota); err != nil {
		t.Fatal(err)
	}
	if err := store.SettleReservation(ctx, storage.ReservationSettlement{
		AccountID: "acct_settle", RequestID: "req_b", PromptTokens: 100, CompletionTokens: 100,
		TokenSource: "provider_reported", Outcome: "ok", SettledAt: fixedTime().Add(time.Minute),
		FundingSource: storage.FundingSourceQuota,
	}); err != nil {
		t.Fatal(err)
	}
	if used, _, _ := store.DailyUsage(ctx, "acct_settle", "2026-10-13"); used != 200 {
		t.Fatalf("unfunded allowance-only request used=%d, want 200 on the paid quota", used)
	}
	if err := store.SettleReservation(ctx, storage.ReservationSettlement{AccountID: "acct_settle", RequestID: "req_b", FundingSource: "voucher"}); err == nil {
		t.Fatal("unknown funding source must be refused")
	}
}

func TestAllowanceActiveDaysPersistAndSchemaV19Gates(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	now := fixedTime()
	day := now.UTC().Format("2006-01-02")
	if ok, err := store.AllowanceDayActive(ctx, "acct_d", day); err != nil || ok {
		t.Fatalf("fresh active=%v err=%v", ok, err)
	}
	if err := store.NoteAllowanceDay(ctx, "acct_d", day, true, now); err != nil {
		t.Fatal(err)
	}
	if ok, _ := store.AllowanceDayActive(ctx, "acct_d", day); !ok {
		t.Fatal("noted day not active")
	}
	if err := store.NoteAllowanceDay(ctx, "acct_d", day, false, now); err != nil {
		t.Fatal(err)
	}
	if ok, _ := store.AllowanceDayActive(ctx, "acct_d", day); ok {
		t.Fatal("cleared day still active")
	}
	var version int64
	if err := store.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&version); err != nil || version != 19 {
		t.Fatalf("schema version=%d err=%v, want 19", version, err)
	}
	if err := store.checkSchemaVersionGateAt(ctx, 18); err == nil {
		t.Fatal("a v18 gateway accepted a database carrying SPEC-050 funding sources")
	}
}

// SPEC-050-R014: an allowance-only reservation is admitted past the paid
// quota's limit but stays on the paid quota until the coordinator's
// allowance funding is confirmed, so an unconfirmed one is charged there.
func TestAllowanceOnlyReservationStaysPaidUntilConfirmed(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_only")
	reserve := func(id string) {
		t.Helper()
		if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
			AccountID: "acct_only", RequestID: id, WindowDate: "2026-10-13",
			RequestedTokens: 500, DailyQuota: 100, CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(time.Hour),
			AllowanceOnly: true,
		}); err != nil {
			t.Fatalf("allowance-only reservation %s: %v", id, err)
		}
	}
	reserve("req_unconfirmed")
	if _, reserved, _ := store.DailyUsage(ctx, "acct_only", "2026-10-13"); reserved != 500 {
		t.Fatalf("unconfirmed allowance-only hold reserved=%d, want 500 on the paid quota", reserved)
	}
	reserve("req_confirmed")
	if err := store.MarkReservationFundingSource(ctx, "acct_only", "req_confirmed", storage.FundingSourceAllowance); err != nil {
		t.Fatal(err)
	}
	if _, reserved, _ := store.DailyUsage(ctx, "acct_only", "2026-10-13"); reserved != 500 {
		t.Fatalf("confirmed hold still on the paid quota: reserved=%d", reserved)
	}
}
