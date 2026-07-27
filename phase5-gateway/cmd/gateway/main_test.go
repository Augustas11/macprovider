package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
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

// TestCoordinatorClientHasNoBodyTimeout is the production half of issue #760.
//
// The router's per-phase deadlines are invisible from inside the router tests,
// which inject their own Timeout-less http.Client. In production the real
// client used to carry Timeout = coordinator_request_seconds — a SECOND flat
// wall that covers BODY reads, so decomposing the request context alone would
// have been a no-op: a healthy stream would still have died at the same 300s.
//
// The test drives the real newCoordinatorClient against a real
// httptest.NewServer that commits headers immediately and then dribbles body
// bytes for longer than coordinator_request_seconds. If Client.Timeout is ever
// reintroduced, the body read fails here.
func TestCoordinatorClientHasNoBodyTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		flusher, _ := w.(http.Flusher)
		for i := 0; i < 6; i++ {
			_, _ = io.WriteString(w, "data: {\"delta\":\"x\"}\n\n")
			if flusher != nil {
				flusher.Flush()
			}
			time.Sleep(250 * time.Millisecond)
		}
	}))
	defer srv.Close()

	cfg := config.Default()
	// A 1s legacy wall: any request-spanning client timeout derived from it
	// cuts the ~1.5s body below.
	cfg.Timeouts.CoordinatorRequestSeconds = 1
	client := newCoordinatorClient(cfg)

	if client.Timeout != 0 {
		t.Fatalf("coordinator client Timeout=%s; it MUST be 0 — a client-level timeout is a hidden "+
			"second request wall that overrides the router's per-phase deadlines (#760)", client.Timeout)
	}
	transport, ok := client.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("coordinator transport is %T, want *http.Transport", client.Transport)
	}
	if transport.ResponseHeaderTimeout != cfg.CoordinatorHeaderTimeout() {
		t.Fatalf("ResponseHeaderTimeout=%s want %s — lowering it to the connect budget reintroduces the #92/#171 regression",
			transport.ResponseHeaderTimeout, cfg.CoordinatorHeaderTimeout())
	}
	if transport.TLSHandshakeTimeout != cfg.CoordinatorConnectTimeout() {
		t.Fatalf("TLSHandshakeTimeout=%s want the connect budget %s", transport.TLSHandshakeTimeout, cfg.CoordinatorConnectTimeout())
	}
	if transport.DialContext == nil {
		t.Fatal("DialContext is nil; the connect budget is not applied to dialling")
	}

	start := time.Now()
	resp, err := client.Get(srv.URL)
	if err != nil {
		t.Fatalf("coordinator request failed: %v", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("body read failed after %s: %v — a hidden client-level wall is back", elapsed, err)
	}
	if elapsed <= cfg.CoordinatorTimeout() {
		t.Fatalf("body completed in %s, which is within coordinator_request_seconds (%s) — the test "+
			"no longer exercises a body read that outlives the legacy wall", elapsed, cfg.CoordinatorTimeout())
	}
	if !strings.Contains(string(body), "data: ") {
		t.Fatalf("unexpected body %q", string(body))
	}
}
