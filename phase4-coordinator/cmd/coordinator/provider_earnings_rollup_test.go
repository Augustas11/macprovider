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
	// slow makes every pass block until its context ends.
	slow bool
}

func (f *fakeEarningsRollupRefresher) RefreshProviderEarningsRollup(ctx context.Context, _ int) (billing.ProviderEarningsRollupPass, error) {
	n := f.calls.Add(1)
	if f.slow {
		<-ctx.Done()
		return billing.ProviderEarningsRollupPass{More: true}, nil
	}
	return billing.ProviderEarningsRollupPass{More: n < f.moreUntil, BackfillComplete: n >= f.moreUntil}, nil
}

func (f *fakeEarningsRollupRefresher) ProviderEarningsRollupBacklog(context.Context) (billing.ProviderEarningsRollupBacklog, error) {
	return billing.ProviderEarningsRollupBacklog{BackfillComplete: true}, nil
}

type busyIdleTracker struct{}

func (busyIdleTracker) IdleFor(time.Time) time.Duration { return 0 }

// The refresher keeps passing while a pass reports more work (the backfill
// and first drain), then idles until the next tick, and stops with ctx.
func TestProviderEarningsRollupRefresherDrainsBacklogThenIdles(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fake := &fakeEarningsRollupRefresher{moreUntil: 5}
	startProviderEarningsRollupRefresher(ctx, fake, nil, zerolog.Nop())
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
}

// A pass that never finishes on its own is cut at the tick budget, and the
// next tick waits for the ticker (and, under money-path traffic, the yield
// gate) instead of starting at once.
func TestProviderEarningsRollupRefresherEnforcesTickBudget(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fake := &fakeEarningsRollupRefresher{slow: true}
	start := time.Now()
	startProviderEarningsRollupRefresher(ctx, fake, busyIdleTracker{}, zerolog.Nop())
	time.Sleep(providerEarningsRollupTickBudget + providerEarningsRollupTick + 500*time.Millisecond)
	if got := fake.calls.Load(); got != 1 {
		t.Fatalf("passes=%d within %s; want one budget-bounded pass while traffic defers the next", got, time.Since(start))
	}
}
