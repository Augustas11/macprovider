package main

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/router"
)

func TestNewHTTPServerAppliesTimeouts(t *testing.T) {
	server := newHTTPServer("127.0.0.1:0", http.NewServeMux())
	if server.ReadHeaderTimeout != 10*time.Second {
		t.Fatalf("ReadHeaderTimeout=%s want 10s", server.ReadHeaderTimeout)
	}
	if server.ReadTimeout != 30*time.Second {
		t.Fatalf("ReadTimeout=%s want 30s", server.ReadTimeout)
	}
	if server.IdleTimeout != 120*time.Second {
		t.Fatalf("IdleTimeout=%s want 120s", server.IdleTimeout)
	}
}

type fakeSettlementReconciler struct {
	calls chan int
}

func (f *fakeSettlementReconciler) ReconcileSettlementHolds(ctx context.Context, limit int) (router.SettlementReconcileSummary, error) {
	select {
	case <-ctx.Done():
		return router.SettlementReconcileSummary{}, ctx.Err()
	case f.calls <- limit:
		return router.SettlementReconcileSummary{Scanned: 1, Verified: 1}, nil
	}
}

type fakeOAuthPruner struct {
	stateCalls   chan time.Time
	handoffCalls chan time.Time
}

func (f *fakeOAuthPruner) PruneExpiredOAuthState(ctx context.Context, now time.Time) (int64, error) {
	select {
	case <-ctx.Done():
		return 0, ctx.Err()
	case f.stateCalls <- now:
		return 1, nil
	}
}

func (f *fakeOAuthPruner) PruneExpiredOAuthHandoffs(ctx context.Context, now time.Time) (int64, error) {
	select {
	case <-ctx.Done():
		return 0, ctx.Err()
	case f.handoffCalls <- now:
		return 1, nil
	}
}

func TestRunOAuthStatePrunerRunsAndStops(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	fake := &fakeOAuthPruner{stateCalls: make(chan time.Time, 2), handoffCalls: make(chan time.Time, 2)}
	done := make(chan struct{})
	go func() {
		defer close(done)
		runOAuthStatePruner(ctx, fake, time.Hour)
	}()

	select {
	case <-fake.stateCalls:
	case <-time.After(time.Second):
		t.Fatal("oauth state pruner did not run immediately")
	}
	select {
	case <-fake.handoffCalls:
	case <-time.After(time.Second):
		t.Fatal("oauth handoff pruner did not run immediately")
	}

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("oauth state pruner did not stop after context cancellation")
	}
}

func TestRunSettlementReconcilerRunsImmediately(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	fake := &fakeSettlementReconciler{calls: make(chan int, 2)}
	done := make(chan struct{})
	go func() {
		defer close(done)
		runSettlementReconciler(ctx, fake, time.Hour, 17, time.Second)
	}()

	select {
	case got := <-fake.calls:
		if got != 17 {
			t.Fatalf("reconcile limit=%d want 17", got)
		}
	case <-time.After(time.Second):
		t.Fatal("settlement reconciler did not run immediately")
	}

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("settlement reconciler did not stop after context cancellation")
	}
}

func TestRunSettlementReconcilerRunsOnInterval(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fake := &fakeSettlementReconciler{calls: make(chan int, 4)}
	done := make(chan struct{})
	go func() {
		defer close(done)
		runSettlementReconciler(ctx, fake, 10*time.Millisecond, 23, time.Second)
	}()

	for i := 0; i < 2; i++ {
		select {
		case got := <-fake.calls:
			if got != 23 {
				t.Fatalf("reconcile call %d limit=%d want 23", i+1, got)
			}
		case <-time.After(time.Second):
			t.Fatalf("settlement reconciler call %d did not arrive", i+1)
		}
	}

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("settlement reconciler did not stop after interval test cancellation")
	}
}
