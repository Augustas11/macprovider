package billing

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

var allowanceTestNow = time.Date(2026, 10, 13, 9, 0, 0, 0, time.UTC)

func grantAllowance(t *testing.T, store *Store, stakes ...AllowanceStake) {
	t.Helper()
	if _, _, err := store.RefreshAllowanceDay(context.Background(), allowanceTestNow, &fakeAllowanceSource{stakes: stakes}, testAllowancePolicy()); err != nil {
		t.Fatal(err)
	}
}

func admit(t *testing.T, store *Store, account, requestID string, bound int64, required bool) AllowanceDecision {
	t.Helper()
	d, err := store.AdmitAllowance(context.Background(), AllowanceAdmission{
		AccountID: account, RequestID: requestID, Model: "model-a", BoundCredits: bound, Required: required, Now: allowanceTestNow,
	})
	if err != nil {
		t.Fatalf("admit %s: %v", requestID, err)
	}
	return d
}

// SPEC-050-R007: allowance first, then paid with overage on, refused with
// overage off, and allowance-only when the paid quota is exhausted.
func TestAdmitAllowanceSpendOrderingAndOverage(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	grantAllowance(t, store, AllowanceStake{AccountID: "acct", Units: malibu(100)}) // 100,000 credits

	if d := admit(t, store, "acct", "r1", 60_000, false); d.Funding != AllowanceFundingAllowance || d.RemainingCredits != 40_000 || !d.HasAllowance {
		t.Fatalf("r1 %+v", d)
	}
	// 50,000 does not fit the 40,000 left: overage on goes paid.
	if d := admit(t, store, "acct", "r2", 50_000, false); d.Funding != AllowanceFundingPaid || d.RemainingCredits != 40_000 {
		t.Fatalf("r2 %+v", d)
	}
	// Paid quota exhausted: only the allowance may fund it, even with
	// overage on.
	if d := admit(t, store, "acct", "r3", 50_000, true); d.Funding != AllowanceFundingRefused {
		t.Fatalf("r3 %+v", d)
	}
	if d := admit(t, store, "acct", "r4", 40_000, true); d.Funding != AllowanceFundingAllowance || d.RemainingCredits != 0 {
		t.Fatalf("r4 %+v", d)
	}
	if err := store.SetAllowanceOverage(ctx, "acct", false, allowanceTestNow); err != nil {
		t.Fatal(err)
	}
	if d := admit(t, store, "acct", "r5", 1, false); d.Funding != AllowanceFundingRefused || d.OverageEnabled {
		t.Fatalf("r5 with overage off %+v", d)
	}
	// A gateway retry of r1 keeps its first decision and its hold.
	if d := admit(t, store, "acct", "r1", 60_000, false); d.Funding != AllowanceFundingAllowance {
		t.Fatalf("r1 retry %+v", d)
	}
	status, err := store.AllowanceStatusFor(ctx, "acct", allowanceTestNow)
	if err != nil || status.HeldCredits != 100_000 || status.RemainingCredits != 0 || status.OverageEnabled {
		t.Fatalf("status %+v err %v", status, err)
	}
	// An account without an allowance is paid and leaves no reservation.
	if d := admit(t, store, "other", "x1", 5, false); d.Funding != AllowanceFundingPaid || d.HasAllowance {
		t.Fatalf("other %+v", d)
	}
	var rows int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM allowance_reservations WHERE account_id = 'other'`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("other reservations=%d err=%v", rows, err)
	}
	if err := store.SetAllowanceOverage(ctx, "other", false, allowanceTestNow); err != nil {
		t.Fatal(err)
	}
	if d := admit(t, store, "other", "x2", 5, false); d.Funding != AllowanceFundingRefused {
		t.Fatalf("other with overage off %+v", d)
	}
}

func TestConcurrentAdmissionsNeverOverholdTheGrant(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	grantAllowance(t, store, AllowanceStake{AccountID: "acct", Units: malibu(100)}) // 100,000
	var wg sync.WaitGroup
	results := make([]string, 20)
	for i := range results {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			d, err := store.AdmitAllowance(context.Background(), AllowanceAdmission{
				AccountID: "acct", RequestID: "c" + string(rune('a'+i)), Model: "m", BoundCredits: 30_000, Now: allowanceTestNow,
			})
			if err != nil {
				t.Error(err)
				return
			}
			results[i] = d.Funding
		}(i)
	}
	wg.Wait()
	funded := 0
	for _, f := range results {
		if f == AllowanceFundingAllowance {
			funded++
		}
	}
	if funded != 3 {
		t.Fatalf("%d of 20 requests held 30,000 of a 100,000 grant, want 3", funded)
	}
}

func writeAllowanceAttempt(t *testing.T, reqStore *requestlog.Store, store *Store, account, external, requestID string, attempt int64, provider string) int64 {
	t.Helper()
	input, row := testHotPathInput(t, store)
	row.RequestID, row.AccountID, row.ExternalRequestID = requestID, account, external
	row.ProviderAssignedID = "assigned-" + provider
	input.RequestID, input.AttemptN, input.ProviderID, input.ProviderAssignedID = requestID, int(attempt), provider, row.ProviderAssignedID
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatalf("hot path: %v", err)
	}
	var gross int64
	if err := store.db.QueryRowContext(context.Background(), `SELECT gross_credits FROM ledger_request_credits WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`, requestID, attempt, provider).Scan(&gross); err != nil {
		t.Fatal(err)
	}
	return gross
}

// SPEC-050-R008/R009: the spend is the ledger's gross credits, one split per
// ledger row, and the provider credit is untouched.
func TestCloseAllowanceRecordsSplitsFromTheLedger(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	grantAllowance(t, store, AllowanceStake{AccountID: "acct", Units: malibu(250)}) // 250,000
	admit(t, store, "acct", "ext-1", 10_000, false)
	gross := writeAllowanceAttempt(t, reqStore, store, "acct", "ext-1", "coord-1", 0, "provider-a")
	if gross <= 0 {
		t.Fatalf("fixture gross %d", gross)
	}
	var providerCreditsBefore int64
	if err := store.db.QueryRowContext(ctx, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = 'coord-1'`).Scan(&providerCreditsBefore); err != nil {
		t.Fatal(err)
	}
	if err := store.CloseAllowanceReservation(ctx, "acct", "ext-1", allowanceTestNow); err != nil {
		t.Fatal(err)
	}
	status, _ := store.AllowanceStatusFor(ctx, "acct", allowanceTestNow)
	if status.SpentCredits != gross || status.HeldCredits != 0 || status.RemainingCredits != 250_000-gross {
		t.Fatalf("status %+v gross %d", status, gross)
	}
	// A gateway retry adds a second attempt; closing again counts both.
	admit(t, store, "acct", "ext-1", 10_000, false)
	gross2 := writeAllowanceAttempt(t, reqStore, store, "acct", "ext-1", "coord-2", 0, "provider-b")
	if err := store.CloseAllowanceReservation(ctx, "acct", "ext-1", allowanceTestNow); err != nil {
		t.Fatal(err)
	}
	if err := store.CloseAllowanceReservation(ctx, "acct", "ext-1", allowanceTestNow); err != nil {
		t.Fatal(err)
	}
	status, _ = store.AllowanceStatusFor(ctx, "acct", allowanceTestNow)
	if status.SpentCredits != gross+gross2 {
		t.Fatalf("spent %d want %d", status.SpentCredits, gross+gross2)
	}
	var splits, allowanceSum, paidSum int64
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*), SUM(allowance_credits), SUM(paid_credits) FROM allowance_request_splits WHERE external_request_id = 'ext-1'`).Scan(&splits, &allowanceSum, &paidSum); err != nil {
		t.Fatal(err)
	}
	if splits != 2 || allowanceSum != gross+gross2 || paidSum != 0 {
		t.Fatalf("splits=%d allowance=%d paid=%d", splits, allowanceSum, paidSum)
	}
	var providerCreditsAfter int64
	if err := store.db.QueryRowContext(ctx, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = 'coord-1'`).Scan(&providerCreditsAfter); err != nil {
		t.Fatal(err)
	}
	if providerCreditsAfter != providerCreditsBefore {
		t.Fatalf("provider credit changed %d -> %d", providerCreditsBefore, providerCreditsAfter)
	}
	// A paid request of an allowance account records a paid split.
	admit(t, store, "acct", "ext-paid", 1_000_000, false)
	paidGross := writeAllowanceAttempt(t, reqStore, store, "acct", "ext-paid", "coord-3", 0, "provider-a")
	if err := store.CloseAllowanceReservation(ctx, "acct", "ext-paid", allowanceTestNow); err != nil {
		t.Fatal(err)
	}
	var funding string
	var paid, allowanceCredits int64
	if err := store.db.QueryRowContext(ctx, `SELECT funding, paid_credits, allowance_credits FROM allowance_request_splits WHERE external_request_id = 'ext-paid'`).Scan(&funding, &paid, &allowanceCredits); err != nil {
		t.Fatal(err)
	}
	if funding != AllowanceFundingPaid || paid != paidGross || allowanceCredits != 0 {
		t.Fatalf("paid split funding=%s paid=%d allowance=%d", funding, paid, allowanceCredits)
	}
	if err := store.SetAllowanceOverage(ctx, "acct", false, allowanceTestNow); err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{`UPDATE allowance_request_splits SET paid_credits = 0`, `DELETE FROM allowance_request_splits`, `DELETE FROM allowance_overage_events`} {
		if _, err := store.db.ExecContext(ctx, stmt); err == nil {
			t.Fatalf("%q must be refused", stmt)
		}
	}
}

func TestReapAllowanceClosesOnlyHoldsFromEarlierProcesses(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	grantAllowance(t, store, AllowanceStake{AccountID: "acct", Units: malibu(100)})
	admit(t, store, "acct", "ext-crash", 50_000, false)
	gross := writeAllowanceAttempt(t, reqStore, store, "acct", "ext-crash", "coord-9", 0, "provider-a")
	// A hold created by this process (after startedAt) is never reaped,
	// however old: its own handler closes it.
	closed, err := store.ReapAllowanceReservations(ctx, allowanceTestNow.Add(48*time.Hour), allowanceTestNow.Add(-time.Minute))
	if err != nil || closed != 0 {
		t.Fatalf("live hold reaped: %d %v", closed, err)
	}
	// After a restart every earlier hold is orphaned and closed from the
	// ledger.
	closed, err = store.ReapAllowanceReservations(ctx, allowanceTestNow.Add(time.Hour), allowanceTestNow.Add(time.Minute))
	if err != nil || closed != 1 {
		t.Fatalf("orphaned hold not reaped: %d %v", closed, err)
	}
	status, _ := store.AllowanceStatusFor(ctx, "acct", allowanceTestNow)
	if status.HeldCredits != 0 || status.SpentCredits != gross {
		t.Fatalf("status %+v", status)
	}
}

func TestAllowanceCreditBoundCoversTheLedgerGross(t *testing.T) {
	rate := RateCardEntry{PromptCreditsPerMtok: 1_000_000, CompletionCreditsPerMtok: 2_000_000}
	for _, mult := range []int64{1_000_000, 1_234_567} {
		for _, p := range []int64{0, 1, 3, 999, 100_000} {
			for _, c := range []int64{0, 1, 7, 32_768} {
				p, c := p, c
				gross := ComputeCredits(&p, &c, nil, UsageProviderReported, FaultNone, rate, mult, 9000).GrossCredits
				if bound := AllowanceCreditBound(rate, mult, p, c); bound < gross {
					t.Fatalf("bound %d < gross %d for p=%d c=%d mult=%d", bound, gross, p, c, mult)
				}
			}
		}
	}
	if got := AllowanceCreditBound(rate, 1_000_000, 0, 0); got != 0 {
		t.Fatalf("empty bound %d", got)
	}
	// Out-of-range counts give a large bound, never zero.
	if got := AllowanceCreditBound(rate, 1_000_000, 1<<62, 1<<62); got != 1<<63-1 {
		t.Fatalf("huge bound %d", got)
	}
}

// A gateway retry of an allowance request whose first attempt already closed
// holds the bound again while it runs (SPEC-050-R007).
func TestRetriedAllowanceRequestIsHeldAgain(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	grantAllowance(t, store, AllowanceStake{AccountID: "acct", Units: malibu(100)}) // 100,000
	admit(t, store, "acct", "ext-r", 60_000, false)
	gross := writeAllowanceAttempt(t, reqStore, store, "acct", "ext-r", "coord-r1", 0, "provider-a")
	if err := store.CloseAllowanceReservation(ctx, "acct", "ext-r", allowanceTestNow); err != nil {
		t.Fatal(err)
	}
	if d := admit(t, store, "acct", "ext-r", 60_000, false); d.Funding != AllowanceFundingAllowance || d.RemainingCredits != 100_000-gross-60_000 {
		t.Fatalf("retry decision %+v (gross %d)", d, gross)
	}
	// While the retry holds its bound, a concurrent request cannot take it.
	if d := admit(t, store, "acct", "ext-other", 60_000, false); d.Funding != AllowanceFundingPaid {
		t.Fatalf("concurrent request took the retry's hold: %+v", d)
	}
	gross2 := writeAllowanceAttempt(t, reqStore, store, "acct", "ext-r", "coord-r2", 0, "provider-a")
	if err := store.CloseAllowanceReservation(ctx, "acct", "ext-r", allowanceTestNow); err != nil {
		t.Fatal(err)
	}
	status, _ := store.AllowanceStatusFor(ctx, "acct", allowanceTestNow)
	if status.SpentCredits != gross+gross2 || status.HeldCredits != 0 {
		t.Fatalf("status %+v want spent %d", status, gross+gross2)
	}
}

func TestOverageRecordsOnlyChangesAndIsBounded(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	count := func() int {
		var n int
		if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM allowance_overage_events WHERE account_id = 'acct'`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	for i := 0; i < 5; i++ {
		if err := store.SetAllowanceOverage(ctx, "acct", true, allowanceTestNow); err != nil {
			t.Fatal(err)
		}
	}
	if n := count(); n != 0 {
		t.Fatalf("setting the default recorded %d events", n)
	}
	var err error
	for i := 0; i < maxOverageChangesPerDay; i++ {
		if err = store.SetAllowanceOverage(ctx, "acct", i%2 == 1, allowanceTestNow); err != nil {
			t.Fatalf("change %d: %v", i, err)
		}
	}
	if err := store.SetAllowanceOverage(ctx, "acct", false, allowanceTestNow); !errors.Is(err, ErrAllowanceOverageRateLimited) {
		t.Fatalf("change past the bound err = %v", err)
	}
	if n := count(); n != maxOverageChangesPerDay {
		t.Fatalf("events %d", n)
	}
}
