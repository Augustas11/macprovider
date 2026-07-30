package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/router"
	"github.com/augstar/macprovider-gateway/internal/settlement/journal"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
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

type fakeSettlementJournalRecoverer struct {
	calls chan int
}

func (f *fakeSettlementJournalRecoverer) RecoverSettlementJournal(ctx context.Context, limit int) (router.SettlementJournalRecoverySummary, error) {
	select {
	case <-ctx.Done():
		return router.SettlementJournalRecoverySummary{}, ctx.Err()
	case f.calls <- limit:
		return router.SettlementJournalRecoverySummary{Scanned: 1, Recovered: 1}, nil
	}
}

func TestRunSettlementJournalRecoveryRunsImmediatelyAndOnInterval(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	fake := &fakeSettlementJournalRecoverer{calls: make(chan int, 4)}
	done := make(chan struct{})
	go func() {
		defer close(done)
		runSettlementJournalRecovery(ctx, fake, 10*time.Millisecond, 41, time.Second)
	}()
	for i := 0; i < 2; i++ {
		select {
		case got := <-fake.calls:
			if got != 41 {
				t.Fatalf("recovery call %d limit=%d want 41", i+1, got)
			}
		case <-time.After(time.Second):
			t.Fatalf("settlement journal recovery call %d did not arrive", i+1)
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("settlement journal recovery did not stop after context cancellation")
	}
}

// TestGatewayRouterCarriesSettlementJournal is the wiring tripwire for #763.
//
// The router falls back to a DISCARD journal when none is registered, and a
// discard journal has no symptom: requests succeed, /metrics stays at zero,
// and settlement durability is simply off. So the production assembly path is
// exercised end to end — open the real journal, build the router the way
// main() does, write an effect, and prove the Server can recover it. A
// dropped WithSettlementJournal option turns this red.
func TestGatewayRouterCarriesSettlementJournal(t *testing.T) {
	dir := t.TempDir()
	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Storage.DBPath = filepath.Join(dir, "gateway.db")
	cfg.Settlement.JournalRecoveryGraceSeconds = 0

	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer store.Close()

	settlementJournal, err := openSettlementJournal(cfg)
	if err != nil {
		t.Fatalf("openSettlementJournal: %v", err)
	}
	defer settlementJournal.Close()
	if got := settlementJournal.Dir(); got != filepath.Join(dir, "settlement-journal") {
		t.Fatalf("journal dir=%q want the sqlite sibling", got)
	}

	gatewayRouter := newGatewayRouter(cfg, store, store, nil, http.DefaultClient, settlementJournal)
	if err := settlementJournal.WriteEffect(journal.Record{
		AccountID:        "acct_wiring",
		RequestID:        "req-wiring",
		Effect:           journal.EffectSettle,
		WindowDate:       "2026-05-29",
		PromptTokens:     8,
		CompletionTokens: 12,
		TotalTokens:      20,
		MaxTotalTokens:   20,
		TokenSource:      "provider_reported",
		Outcome:          "ok",
	}); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}

	summary, err := gatewayRouter.RecoverSettlementJournal(context.Background(), cfg.Settlement.JournalRecoveryBatchLimit)
	if err != nil {
		t.Fatalf("RecoverSettlementJournal: %v", err)
	}
	if summary.Scanned != 1 {
		t.Fatalf("summary=%+v — the router did not see the journal main() opened; the real journal is not wired "+
			"into router.New and settlement durability is silently disabled", summary)
	}
}

// TestOpenSettlementJournalFailsClosed: main() exits when this errors, which
// is the only thing standing between a misconfigured journal directory and a
// gateway that serves with durability off.
func TestOpenSettlementJournalFailsClosed(t *testing.T) {
	locked := filepath.Join(t.TempDir(), "locked")
	if err := os.Mkdir(locked, 0o500); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o700) })
	cfg := config.Default()
	cfg.Settlement.JournalDir = filepath.Join(locked, "settlement-journal")
	if _, err := openSettlementJournal(cfg); err == nil {
		t.Fatal("openSettlementJournal accepted an unwritable directory; main() would boot without durability")
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
