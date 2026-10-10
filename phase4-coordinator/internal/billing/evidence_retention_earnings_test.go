package billing_test

import (
	"context"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/rewards"
)

// SPEC-022 R-15.6 with the #1925 earnings rollup: archiving a provider's
// evidence rows marks the affected rollup hours dirty, the refresher
// recomputes them, and the provider's earnings and E1 verified-receipt count
// are exactly what they were before the rows left.
func TestEvidenceRetentionKeepsProviderEarningsAndVerifiedReceiptCountExact(t *testing.T) {
	ctx := context.Background()
	x := billing.NewRetentionEarningsFixtureForTest(t)
	provider := x.Seed(t, "first")
	for _, id := range []string{"b", "c", "d"} {
		if got := x.Seed(t, id); got != provider {
			t.Fatalf("fixture provider changed: %q vs %q", got, provider)
		}
	}
	x.Settle(t)
	x.DrainEarningsRollup(t)

	earningsBefore := x.Earnings(t, provider)
	var payable int64
	if err := x.DB().QueryRow(`SELECT COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits WHERE provider_id = ?`, provider).Scan(&payable); err != nil || payable <= 0 {
		t.Fatalf("fixture has no payable earnings: %d err=%v", payable, err)
	}
	receiptsBefore, err := rewards.CountVerifiedReceipts(ctx, x.DB(), provider)
	if err != nil {
		t.Fatal(err)
	}
	if receiptsBefore != 4 {
		t.Fatalf("verified receipts before retention=%d want 4", receiptsBefore)
	}

	report, err := x.Store().RunEvidenceRetention(ctx, x.Options(t.TempDir()))
	if err != nil {
		t.Fatal(err)
	}
	if report.DeletedRequests != 3 {
		t.Fatalf("retention report=%+v want 3 archived requests", report)
	}
	for _, id := range []string{"b", "c", "d"} {
		if x.HotRows(t, id) != 0 {
			t.Fatalf("request %s still hot", id)
		}
	}
	if x.DirtyEarningsBuckets(t, provider) == 0 {
		t.Fatal("archiving evidence rows marked no earnings rollup hour dirty")
	}
	// Served before the refresher runs (dirty hours read live) and after it
	// recomputes them from the tombstoned view.
	if got := x.Earnings(t, provider); got != earningsBefore {
		t.Fatalf("earnings with dirty hours changed:\nbefore:\n%s\nafter:\n%s", earningsBefore, got)
	}
	x.DrainEarningsRollup(t)
	if got := x.Earnings(t, provider); got != earningsBefore {
		t.Fatalf("earnings after recompute changed:\nbefore:\n%s\nafter:\n%s", earningsBefore, got)
	}
	receiptsAfter, err := rewards.CountVerifiedReceipts(ctx, x.DB(), provider)
	if err != nil {
		t.Fatal(err)
	}
	if receiptsAfter != receiptsBefore {
		t.Fatalf("verified_receipt_count after retention=%d want %d", receiptsAfter, receiptsBefore)
	}
	// The provider-index-less (unpinned) read serves the same count.
	if _, err := x.DB().Exec(`DROP INDEX idx_srv_provider_recent`); err != nil {
		t.Fatal(err)
	}
	if got, err := rewards.CountVerifiedReceipts(ctx, x.DB(), provider); err != nil || got != receiptsBefore {
		t.Fatalf("unpinned count=%d err=%v want %d", got, err, receiptsBefore)
	}
}
