package billing

import (
	"context"
	"database/sql"
	"fmt"
	"reflect"
	"testing"
)

// RetentionEarningsFixture exposes the settled-evidence retention fixture to
// the external billing_test package, which can also import rewards.
type RetentionEarningsFixture struct {
	f *retentionFixture
}

func NewRetentionEarningsFixtureForTest(t *testing.T) *RetentionEarningsFixture {
	return &RetentionEarningsFixture{f: newRetentionFixture(t, false)}
}

func (x *RetentionEarningsFixture) Store() *Store { return x.f.store }

func (x *RetentionEarningsFixture) DB() *sql.DB { return x.f.store.db }

// Seed writes one settled-to-be enforce request and returns its provider.
func (x *RetentionEarningsFixture) Seed(t *testing.T, suffix string) string {
	return x.f.seed(t, suffix).ProviderID
}

func (x *RetentionEarningsFixture) Settle(t *testing.T) { x.f.settle(t) }

func (x *RetentionEarningsFixture) HotRows(t *testing.T, suffix string) int64 {
	return x.f.hotRows(t, suffix)
}

func (x *RetentionEarningsFixture) Options(dir string) EvidenceRetentionOptions {
	return retentionTestOptions(dir, nil)
}

// DrainEarningsRollup recomputes every dirty earnings bucket.
func (x *RetentionEarningsFixture) DrainEarningsRollup(t *testing.T) { drainRollup(t, x.f.store) }

// DirtyEarningsBuckets counts the provider's buckets awaiting recompute.
func (x *RetentionEarningsFixture) DirtyEarningsBuckets(t *testing.T, providerID string) int64 {
	return scalar(t, x.f.store.db, `SELECT COUNT(*) FROM provider_earnings_rollup_buckets WHERE provider_id = ? AND gen != computed_gen`, providerID)
}

// Earnings returns the provider's earnings figures over every endpoint window
// shape, read through the rollup path. It fails the test unless the rollup
// serves them and they equal a live read of the payable view.
func (x *RetentionEarningsFixture) Earnings(t *testing.T, providerID string) string {
	t.Helper()
	ctx := context.Background()
	out := ""
	for i, win := range rollupTestWindows(x.f.store.nowUTC()) {
		got, ok, err := x.f.store.providerEarningsFromRollup(ctx, providerID, win)
		if err != nil || !ok {
			t.Fatalf("window %d: rollup read ok=%v err=%v", i, ok, err)
		}
		want, err := viewEarningsReference(ctx, x.f.store.db, providerID, win)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("window %d: rollup=%+v view=%+v", i, got, want)
		}
		out += fmt.Sprintf("%d:%+v\n", i, got)
	}
	return out
}
