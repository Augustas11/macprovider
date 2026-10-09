package main

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/rs/zerolog"
)

type fakeEarningsRollupRefresher struct {
	calls     atomic.Int64
	moreUntil int64
}

func (f *fakeEarningsRollupRefresher) RefreshProviderEarningsRollup(context.Context, int) (billing.ProviderEarningsRollupPass, error) {
	n := f.calls.Add(1)
	return billing.ProviderEarningsRollupPass{More: n < f.moreUntil, BackfillComplete: n >= f.moreUntil}, nil
}

// The refresher keeps passing while a pass reports more work (the backfill
// and first drain), then idles until the next tick, and stops with ctx.
func TestProviderEarningsRollupRefresherDrainsBacklogThenIdles(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	fake := &fakeEarningsRollupRefresher{moreUntil: 5}
	startProviderEarningsRollupRefresher(ctx, fake, zerolog.Nop())
	deadline := time.Now().Add(providerEarningsRollupTickBudget)
	for fake.calls.Load() < 5 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if got := fake.calls.Load(); got != 5 {
		t.Fatalf("passes during the first tick=%d want 5", got)
	}
	time.Sleep(100 * time.Millisecond)
	if got := fake.calls.Load(); got != 5 {
		t.Fatalf("refresher kept passing without work: %d calls", got)
	}
	cancel()
}
