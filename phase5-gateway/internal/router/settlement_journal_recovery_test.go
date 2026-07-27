package router

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/settlement/journal"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

// Durable settlement journal recovery (issue #763 / seam finding P1-2).
//
// The tests below are the executable half of the fix: the journal is only
// worth writing if an unsealed effect is re-driven into a durable bill, and
// only SAFE if every re-drive is idempotent. Each test names the property it
// pins in its own comment.

const journalTestWindow = "2026-05-29" // fixedNow()'s UTC date

func journalTestConfig(t *testing.T, mutate func(*config.Config)) config.Config {
	t.Helper()
	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Coordinator.OperatorKey = "operator-key"
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	// Most tests want recovery to act on the effect they just wrote; the
	// grace window has its own test.
	cfg.Settlement.JournalRecoveryGraceSeconds = 0
	if mutate != nil {
		mutate(&cfg)
	}
	return cfg
}

func openTestJournal(t *testing.T, cfg config.Config) *journal.Journal {
	t.Helper()
	j, err := journal.Open(journal.Options{
		Dir:             cfg.SettlementJournalDir(),
		Fsync:           cfg.Settlement.JournalFsync,
		SegmentMaxBytes: cfg.Settlement.JournalSegmentMaxBytes,
		MaxTotalBytes:   cfg.Settlement.JournalMaxTotalBytes,
		// Share the server's clock so the grace window is deterministic.
		Now: fixedNow,
	})
	if err != nil {
		t.Fatalf("journal.Open: %v", err)
	}
	t.Cleanup(func() { _ = j.Close() })
	return j
}

// newJournalHarness returns a Server wired to a real sqlite store and a real
// on-disk journal — no fakes on the money path.
func newJournalHarness(t *testing.T, mutate func(*config.Config), opts ...Option) (*Server, *sqlite.Store, string, *journal.Journal, config.Config) {
	t.Helper()
	cfg := journalTestConfig(t, mutate)
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	jnl := openTestJournal(t, cfg)
	allOpts := append([]Option{WithNow(fixedNow), WithSettlementJournal(jnl)}, opts...)
	return New(cfg, store, fakeOAuth{}, allOpts...), store, cfg.Storage.DBPath, jnl, cfg
}

func seedJournalReservation(t *testing.T, store *sqlite.Store, accountID, requestID string, tokens int64) {
	t.Helper()
	if err := store.CreateAccount(context.Background(), storage.Account{
		AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: fixedNow(),
	}); err != nil && !strings.Contains(err.Error(), "UNIQUE") {
		t.Fatalf("CreateAccount: %v", err)
	}
	if _, err := store.ReserveQuota(context.Background(), storage.ReservationRequest{
		AccountID:       accountID,
		RequestID:       requestID,
		WindowDate:      journalTestWindow,
		RequestedTokens: tokens,
		DailyQuota:      100000,
		CreatedAt:       fixedNow(),
		ExpiresAt:       fixedNow().Add(time.Hour),
	}); err != nil {
		t.Fatalf("ReserveQuota: %v", err)
	}
}

func journalSettleEffect(accountID, requestID string) journal.Record {
	return journal.Record{
		AccountID:        accountID,
		RequestID:        requestID,
		Effect:           journal.EffectSettle,
		WindowDate:       journalTestWindow,
		PromptTokens:     8,
		CompletionTokens: 12,
		TotalTokens:      20,
		MaxTotalTokens:   20,
		TokenSource:      "provider_reported",
		Outcome:          "ok",
	}
}

func journalEffectKey(rec journal.Record) journal.Key {
	return journal.Key{AccountID: rec.AccountID, RequestID: rec.RequestID, Effect: rec.Effect}
}

func demoUsageRows(t *testing.T, dbPath, requestID string) int64 {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	var count int64
	if err := db.QueryRow(`SELECT COUNT(*) FROM demo_usage_events WHERE request_id = ?`, requestID).Scan(&count); err != nil {
		t.Fatalf("query demo_usage_events: %v", err)
	}
	return count
}

// journalRecords reads the on-disk JSONL back with nothing but encoding/json,
// so the tests assert the persisted FORMAT and not just the writer's view of
// it. A record shape change that breaks an older process's ability to recover
// shows up here.
func journalRecords(t *testing.T, dir string) []journal.Record {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read journal dir: %v", err)
	}
	names := []string{}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "effects-") && strings.HasSuffix(entry.Name(), ".jsonl") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	var records []journal.Record
	for _, name := range names {
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("read segment %s: %v", name, err)
		}
		for _, line := range strings.Split(string(raw), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			var rec journal.Record
			if err := json.Unmarshal([]byte(line), &rec); err != nil {
				t.Fatalf("segment %s line %q is not a journal record: %v", name, line, err)
			}
			records = append(records, rec)
		}
	}
	return records
}

func usageTokenTotals(t *testing.T, dbPath, accountID string) (rows, total int64) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	if err := db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(total_tokens), 0) FROM usage_events WHERE account_id = ?`, accountID).
		Scan(&rows, &total); err != nil {
		t.Fatalf("query usage_events: %v", err)
	}
	return rows, total
}

// TestSettlementJournal_RecoveryRedrivesUnsealedEffect: the plain case — the
// process died between the arm and the settle, so the reservation is still
// active. Recovery settles it exactly as the request would have.
func TestSettlementJournal_RecoveryRedrivesUnsealedEffect(t *testing.T) {
	srv, store, dbPath, jnl, _ := newJournalHarness(t, nil)
	seedJournalReservation(t, store, "acct_redrive", "req-redrive", 100)
	if err := jnl.WriteEffect(journalSettleEffect("acct_redrive", "req-redrive")); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}

	summary, err := srv.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("RecoverSettlementJournal: %v", err)
	}
	if summary.Settled != 1 || summary.Recovered != 1 || summary.Errors != 0 {
		t.Fatalf("summary=%+v want settled=1 recovered=1 errors=0", summary)
	}
	state := gatewaySettlementSnapshot(t, dbPath, "acct_redrive")
	if state.usageRows != 1 || state.settledRows != 1 || state.activeRows != 0 {
		t.Fatalf("state=%+v want usageRows=1 settledRows=1 activeRows=0", state)
	}
	scan, _ := jnl.Scan()
	if len(scan.Unsealed) != 0 {
		t.Fatalf("Unsealed=%d want 0 — a recovered effect must be sealed", len(scan.Unsealed))
	}
}

// TestSettlementJournal_RefundedReservationRedrivesViaUsageEvent isolates the
// H7 shape: the double failure already refunded the reservation, so the
// reservation rung is dead and only the § 17.7 usage-event rung can restore
// the bill.
func TestSettlementJournal_RefundedReservationRedrivesViaUsageEvent(t *testing.T) {
	srv, store, dbPath, jnl, _ := newJournalHarness(t, nil)
	seedJournalReservation(t, store, "acct_refunded", "req-refunded", 100)
	if err := store.RefundReservation(context.Background(), "acct_refunded", "req-refunded", fixedNow().Unix()); err != nil {
		t.Fatalf("RefundReservation: %v", err)
	}
	if err := jnl.WriteEffect(journalSettleEffect("acct_refunded", "req-refunded")); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}

	summary, err := srv.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("RecoverSettlementJournal: %v", err)
	}
	if summary.UsageEvents != 1 || summary.Recovered != 1 {
		t.Fatalf("summary=%+v want usage_events=1 recovered=1", summary)
	}
	rows, total := usageTokenTotals(t, dbPath, "acct_refunded")
	if rows != 1 || total != 20 {
		t.Fatalf("usage rows=%d total=%d want 1 row of 20 tokens", rows, total)
	}
	state := gatewaySettlementSnapshot(t, dbPath, "acct_refunded")
	if state.refundedRows != 1 {
		t.Fatalf("state=%+v want the refund to stand (recovery must not resurrect the reservation)", state)
	}
	scan, _ := jnl.Scan()
	if len(scan.Unsealed) != 0 || scan.Seals != 1 {
		t.Fatalf("scan Unsealed=%d Seals=%d want 0/1", len(scan.Unsealed), scan.Seals)
	}
}

// TestSettlementJournal_SealedEffectNotRedriven: a seal is the "do not touch"
// marker. If it were ignored, every completed request would be re-driven on
// every pass.
func TestSettlementJournal_SealedEffectNotRedriven(t *testing.T) {
	srv, store, dbPath, jnl, _ := newJournalHarness(t, nil)
	seedJournalReservation(t, store, "acct_sealed", "req-sealed", 100)
	rec := journalSettleEffect("acct_sealed", "req-sealed")
	if err := jnl.WriteEffect(rec); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}
	if err := jnl.WriteSeal(journalEffectKey(rec), journal.SealSettled); err != nil {
		t.Fatalf("WriteSeal: %v", err)
	}

	summary, err := srv.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("RecoverSettlementJournal: %v", err)
	}
	if summary.Scanned != 0 || summary.Recovered != 0 {
		t.Fatalf("summary=%+v want a sealed effect to be skipped entirely", summary)
	}
	state := gatewaySettlementSnapshot(t, dbPath, "acct_sealed")
	if state.usageRows != 0 || state.activeRows != 1 {
		t.Fatalf("state=%+v want the store untouched (usageRows=0 activeRows=1)", state)
	}
}

// TestSettlementJournal_SettleLandedButSealLost is the NO-DOUBLE-BILL proof.
//
// Worst realistic crash window: SettleReservation committed (the buyer IS
// billed) and the process died before the seal, which is not fsynced by
// design. Recovery must find the reservation terminal, match the existing
// usage row through EnsureUsageEvent's payload verify, and seal — leaving
// exactly ONE bill. If the journaled payload ever drifts from what
// SettleReservation persists, this test goes red with a conflict instead.
func TestSettlementJournal_SettleLandedButSealLost(t *testing.T) {
	srv, store, dbPath, jnl, _ := newJournalHarness(t, nil)
	seedJournalReservation(t, store, "acct_seallost", "req-seallost", 100)
	rec := journalSettleEffect("acct_seallost", "req-seallost")
	if err := jnl.WriteEffect(rec); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}
	// The settle landed, exactly as settleRequest would have written it.
	if err := store.SettleReservation(context.Background(), storage.ReservationSettlement{
		AccountID: rec.AccountID, RequestID: rec.RequestID,
		PromptTokens: rec.PromptTokens, CompletionTokens: rec.CompletionTokens,
		MaxTotalTokens: rec.MaxTotalTokens, TokenSource: rec.TokenSource,
		Outcome: rec.Outcome, SettledAt: fixedNow(),
	}); err != nil {
		t.Fatalf("SettleReservation: %v", err)
	}
	// ...and the seal was lost.

	summary, err := srv.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("RecoverSettlementJournal: %v", err)
	}
	if summary.Quarantined != 0 || summary.Errors != 0 {
		t.Fatalf("summary=%+v — a re-drive over an already-settled request must be benign; a conflict here "+
			"means the journaled payload no longer reproduces what SettleReservation persists", summary)
	}
	if summary.UsageEvents != 1 {
		t.Fatalf("summary=%+v want the re-drive to resolve via the idempotent usage-event rung", summary)
	}
	rows, total := usageTokenTotals(t, dbPath, "acct_seallost")
	if rows != 1 || total != 20 {
		t.Fatalf("DOUBLE BILL: usage rows=%d total=%d want exactly 1 row of 20 tokens", rows, total)
	}
	scan, _ := jnl.Scan()
	if len(scan.Unsealed) != 0 {
		t.Fatalf("Unsealed=%d want 0", len(scan.Unsealed))
	}
}

// TestSettlementJournal_IdempotentAcrossTwoScans: recovery runs on a ticker,
// so "twice" is the normal case, not an edge case.
func TestSettlementJournal_IdempotentAcrossTwoScans(t *testing.T) {
	srv, store, dbPath, jnl, _ := newJournalHarness(t, nil)
	seedJournalReservation(t, store, "acct_twice", "req-twice", 100)
	if err := jnl.WriteEffect(journalSettleEffect("acct_twice", "req-twice")); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}
	if _, err := srv.RecoverSettlementJournal(context.Background(), 0); err != nil {
		t.Fatalf("first pass: %v", err)
	}
	second, err := srv.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("second pass: %v", err)
	}
	if second.Scanned != 0 || second.Recovered != 0 {
		t.Fatalf("second pass summary=%+v want a no-op", second)
	}
	rows, total := usageTokenTotals(t, dbPath, "acct_twice")
	if rows != 1 || total != 20 {
		t.Fatalf("DOUBLE BILL across two passes: rows=%d total=%d", rows, total)
	}
}

// TestSettlementJournal_ConflictQuarantines: when the durable row disagrees
// with the journaled payload, no amount of retrying resolves it. The effect
// must stop being retried, become operator-visible, and — critically — never
// write a second bill.
func TestSettlementJournal_ConflictQuarantines(t *testing.T) {
	srv, store, dbPath, jnl, _ := newJournalHarness(t, nil)
	seedJournalReservation(t, store, "acct_conflict", "req-conflict", 100)
	// The durable row says 8/12; the journal says 8/13.
	if err := store.SettleReservation(context.Background(), storage.ReservationSettlement{
		AccountID: "acct_conflict", RequestID: "req-conflict",
		PromptTokens: 8, CompletionTokens: 12, MaxTotalTokens: 100,
		TokenSource: "provider_reported", Outcome: "ok", SettledAt: fixedNow(),
	}); err != nil {
		t.Fatalf("SettleReservation: %v", err)
	}
	rec := journalSettleEffect("acct_conflict", "req-conflict")
	rec.CompletionTokens = 13
	rec.TotalTokens = 21
	rec.MaxTotalTokens = 100
	if err := jnl.WriteEffect(rec); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}

	for pass := 1; pass < settlementJournalMaxConflictAttempts; pass++ {
		summary, err := srv.RecoverSettlementJournal(context.Background(), 0)
		if err != nil {
			t.Fatalf("pass %d: %v", pass, err)
		}
		if summary.Retried != 1 || summary.Quarantined != 0 {
			t.Fatalf("pass %d summary=%+v want retried=1 quarantined=0", pass, summary)
		}
	}
	final, err := srv.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("final pass: %v", err)
	}
	if final.Quarantined != 1 {
		t.Fatalf("final summary=%+v want quarantined=1 after %d attempts", final, settlementJournalMaxConflictAttempts)
	}
	after, err := srv.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("post-quarantine pass: %v", err)
	}
	if after.Scanned != 0 {
		t.Fatalf("post-quarantine summary=%+v want the effect to stop being re-driven", after)
	}
	rows, total := usageTokenTotals(t, dbPath, "acct_conflict")
	if rows != 1 || total != 20 {
		t.Fatalf("conflict wrote a second bill: rows=%d total=%d want the original 1 row of 20", rows, total)
	}
	if snapshot := jnl.MetricsSnapshot(); snapshot.Quarantines != 1 {
		t.Fatalf("quarantines metric=%d want 1", snapshot.Quarantines)
	}
}

// TestSettlementJournal_GraceWindowSkipsYoungEntries: the arm happens BEFORE
// the settle, so a fresh effect usually belongs to a request that is still
// running. Re-driving it would race the live settle for the same reservation.
func TestSettlementJournal_GraceWindowSkipsYoungEntries(t *testing.T) {
	srv, store, dbPath, jnl, _ := newJournalHarness(t, func(cfg *config.Config) {
		cfg.Settlement.JournalRecoveryGraceSeconds = 60
	})
	seedJournalReservation(t, store, "acct_grace", "req-grace", 100)
	if err := jnl.WriteEffect(journalSettleEffect("acct_grace", "req-grace")); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}

	summary, err := srv.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("RecoverSettlementJournal: %v", err)
	}
	if summary.Skipped != 1 || summary.Scanned != 0 {
		t.Fatalf("summary=%+v want the young effect skipped", summary)
	}
	if state := gatewaySettlementSnapshot(t, dbPath, "acct_grace"); state.usageRows != 0 {
		t.Fatalf("state=%+v want no bill written inside the grace window", state)
	}
	// Past the window (same journal dir, a clock 10 minutes later) it recovers.
	later := New(srv.cfg, srv.store.(*sqlite.Store), fakeOAuth{},
		WithNow(func() time.Time { return fixedNow().Add(10 * time.Minute) }),
		WithSettlementJournal(jnl))
	summary, err = later.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("late pass: %v", err)
	}
	if summary.Recovered != 1 {
		t.Fatalf("late summary=%+v want recovered=1 once the grace window elapsed", summary)
	}
}

// TestSettlementJournal_WriteFailureDoesNotBlockSettle pins the fail-open
// residual: the buyer already has the bytes, so a journal outage must degrade
// recovery coverage, never billing. The write-failure metric is the signal.
func TestSettlementJournal_WriteFailureDoesNotBlockSettle(t *testing.T) {
	// Streaming, because settleAfterCommit — the only journaled path — is
	// reached only after a committed 200 stream. Non-streaming settles BEFORE
	// the response and 500s the buyer on failure, so it has no
	// delivered-but-unbilled window to journal.
	srv, store, dbPath, jnl, cfg := newJournalHarness(t, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(seamStreamingUpstream(func(pw *io.PipeWriter) {
		_, _ = io.WriteString(pw, `data: {"id":"c","usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20},"choices":[{"delta":{"content":"hi"}}]}`+
			"\n\n"+`data: [DONE]`+"\n\n")
		_ = pw.Close()
	})))
	// Make the journal directory read-only AFTER Open, so segment creation
	// fails on the first record — a disk that went read-only under a running
	// gateway.
	dir := cfg.SettlementJournalDir()
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatalf("chmod journal dir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

	h := srv.Handler()
	key := createAccountAndKey(t, store, cfg, "acct_jwfail")
	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	resp := postChat(t, h, key, body, map[string]string{"X-Request-ID": "abababab-abab-4bab-8bab-abababababab"})
	if resp.Code != 200 {
		t.Fatalf("chat status=%d body=%s", resp.Code, resp.Body.String())
	}

	rows, total := usageTokenTotals(t, dbPath, "acct_jwfail")
	if rows != 1 || total != 20 {
		t.Fatalf("journal write failure blocked settlement: usage rows=%d total=%d want 1/20", rows, total)
	}
	if snapshot := jnl.MetricsSnapshot(); snapshot.WriteFailures == 0 {
		t.Fatalf("write_failures=0 — a failed journal write must be visible in /metrics, not silent")
	}
}

// TestSettlementJournal_DemoRedriveWritesBothTables: demo traffic needs the
// demo_usage_events sibling row (SPEC-006 §4.5 / §14.3), on both rungs.
func TestSettlementJournal_DemoRedriveWritesBothTables(t *testing.T) {
	t.Run("settle rung", func(t *testing.T) {
		srv, store, dbPath, jnl, _ := newJournalHarness(t, nil)
		seedJournalReservation(t, store, "acct_demo1", "req-demo1", 100)
		rec := journalSettleEffect("acct_demo1", "req-demo1")
		rec.DemoIdentity = "203.0.113.9"
		rec.DemoTokenHash = "demo-hash-1"
		if err := jnl.WriteEffect(rec); err != nil {
			t.Fatalf("WriteEffect: %v", err)
		}
		summary, err := srv.RecoverSettlementJournal(context.Background(), 0)
		if err != nil {
			t.Fatalf("recover: %v", err)
		}
		if summary.Settled != 1 {
			t.Fatalf("summary=%+v want settled=1", summary)
		}
		if rows, _ := usageTokenTotals(t, dbPath, "acct_demo1"); rows != 1 {
			t.Fatalf("usage rows=%d want 1", rows)
		}
		if got := demoUsageRows(t, dbPath, "req-demo1"); got != 1 {
			t.Fatalf("demo_usage_events rows=%d want 1", got)
		}
	})

	t.Run("usage-event rung", func(t *testing.T) {
		srv, store, dbPath, jnl, _ := newJournalHarness(t, nil)
		seedJournalReservation(t, store, "acct_demo2", "req-demo2", 100)
		if err := store.RefundReservation(context.Background(), "acct_demo2", "req-demo2", fixedNow().Unix()); err != nil {
			t.Fatalf("RefundReservation: %v", err)
		}
		rec := journalSettleEffect("acct_demo2", "req-demo2")
		rec.DemoIdentity = "203.0.113.10"
		rec.DemoTokenHash = "demo-hash-2"
		if err := jnl.WriteEffect(rec); err != nil {
			t.Fatalf("WriteEffect: %v", err)
		}
		summary, err := srv.RecoverSettlementJournal(context.Background(), 0)
		if err != nil {
			t.Fatalf("recover: %v", err)
		}
		if summary.UsageEvents != 1 {
			t.Fatalf("summary=%+v want usage_events=1", summary)
		}
		if rows, _ := usageTokenTotals(t, dbPath, "acct_demo2"); rows != 1 {
			t.Fatalf("usage rows=%d want 1", rows)
		}
		if got := demoUsageRows(t, dbPath, "req-demo2"); got != 1 {
			t.Fatalf("demo_usage_events rows=%d want 1 — the demo audit row must be restored too", got)
		}
	})
}

// TestSettlementJournal_RecoveryRacesSPEC022Reconciler: the two loops share
// one write connection and one reservation table. In production they cannot
// contend for the same request (the SPEC-022 debit/hold paths never call
// settleAfterCommit, so no effect is armed for a held reservation), but the
// invariant must not DEPEND on that: running both over the same request
// concurrently still yields exactly one bill.
func TestSettlementJournal_RecoveryRacesSPEC022Reconciler(t *testing.T) {
	coordinator := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(200, http.Header{"Content-Type": []string{"application/json"}},
			`{"request_id":"req-race","mode":"enforce","policy_version":"v1","outcome":"verified",`+
				`"receipt_result":"valid","reason":"verified_settlement","closed":true,`+
				`"prompt_tokens":8,"completion_tokens":12,"total_tokens":20,"token_source":"coordinator_observed"}`), nil
	})}
	srv, store, dbPath, jnl, _ := newJournalHarness(t, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = "http://coordinator.test"
	}, WithHTTPClient(coordinator))
	seedJournalReservation(t, store, "acct_race", "req-race", 100)
	if err := store.MarkReservationSettlementHold(context.Background(), "acct_race", "req-race"); err != nil {
		t.Fatalf("MarkReservationSettlementHold: %v", err)
	}
	rec := journalSettleEffect("acct_race", "req-race")
	rec.TokenSource = "coordinator_observed"
	rec.Outcome = "spec022_verified"
	if err := jnl.WriteEffect(rec); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		if _, err := srv.RecoverSettlementJournal(context.Background(), 0); err != nil {
			t.Errorf("journal recovery: %v", err)
		}
	}()
	go func() {
		defer wg.Done()
		if _, err := srv.ReconcileSettlementHolds(context.Background(), 10); err != nil {
			t.Errorf("SPEC-022 reconcile: %v", err)
		}
	}()
	wg.Wait()

	rows, total := usageTokenTotals(t, dbPath, "acct_race")
	if rows != 1 || total != 20 {
		t.Fatalf("concurrent recovery + SPEC-022 reconcile produced rows=%d total=%d; want exactly one 20-token bill", rows, total)
	}
	state := gatewaySettlementSnapshot(t, dbPath, "acct_race")
	if state.activeRows != 0 {
		t.Fatalf("state=%+v want no reservation left active", state)
	}
}

// TestSettlementJournal_ReplayedIdlessRetryWritesNoEffect pins the #762
// interaction contract: a replayed id-less retry performs NO reserve and NO
// settle, so it must journal nothing. A journal entry there would describe a
// money effect that never happened, and recovery would then bill it.
func TestSettlementJournal_ReplayedIdlessRetryWritesNoEffect(t *testing.T) {
	// Streaming again: the after-commit settle is the only journaled path, so
	// a non-streaming pair would prove nothing about the interaction.
	var upstreamHits int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		upstreamHits++
		return responseWithBody(http.StatusOK,
			http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}},
			`data: {"id":"c","usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20},"choices":[{"delta":{"content":"hi"}}]}`+
				"\n\n"+`data: [DONE]`+"\n\n"), nil
	})}
	srv, store, dbPath, jnl, cfg := newJournalHarness(t, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	h := srv.Handler()
	key := createAccountAndKey(t, store, cfg, "acct_replay")

	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	if r := postChat(t, h, key, body, nil); r.Code != 200 {
		t.Fatalf("attempt 1 status=%d body=%s", r.Code, r.Body.String())
	}
	afterFirst, err := jnl.Scan()
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if afterFirst.Effects != 1 {
		t.Fatalf("effects after attempt 1 = %d, want exactly 1", afterFirst.Effects)
	}

	second := postChat(t, h, key, body, nil)
	if second.Code != 200 || second.Header().Get(idlessDedupeHeader) != idlessDedupeHeaderValue {
		t.Fatalf("attempt 2 was not a replay: status=%d dedupe=%q", second.Code, second.Header().Get(idlessDedupeHeader))
	}
	afterSecond, err := jnl.Scan()
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if afterSecond.Effects != afterFirst.Effects {
		t.Fatalf("the #762 replay wrote %d new journal effect(s); a replay performs no reserve/settle and must journal nothing",
			afterSecond.Effects-afterFirst.Effects)
	}
	if upstreamHits != 1 {
		t.Fatalf("upstream hits=%d want 1", upstreamHits)
	}
	rows, total := usageTokenTotals(t, dbPath, "acct_replay")
	if rows != 1 || total != 20 {
		t.Fatalf("replay billed twice: rows=%d total=%d", rows, total)
	}
}

// TestSettlementJournal_BatchLimitBoundsOnePass: recovery shares the store's
// single write connection with the money path, so a pass must be bounded.
func TestSettlementJournal_BatchLimitBoundsOnePass(t *testing.T) {
	srv, store, _, jnl, _ := newJournalHarness(t, nil)
	for _, id := range []string{"req-b1", "req-b2", "req-b3"} {
		seedJournalReservation(t, store, "acct_batch", id, 100)
		if err := jnl.WriteEffect(journalSettleEffect("acct_batch", id)); err != nil {
			t.Fatalf("WriteEffect %s: %v", id, err)
		}
	}
	summary, err := srv.RecoverSettlementJournal(context.Background(), 2)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if summary.Scanned != 2 || summary.Recovered != 2 {
		t.Fatalf("summary=%+v want the pass bounded at 2", summary)
	}
	scan, _ := jnl.Scan()
	if len(scan.Unsealed) != 1 {
		t.Fatalf("Unsealed=%d want 1 left for the next pass", len(scan.Unsealed))
	}
}

// TestSettlementJournal_MetricsExposedOnMetricsEndpoint keeps the journal
// observable: an unsealed backlog that nobody can see is the same operational
// blind spot as the dropped row it replaced.
func TestSettlementJournal_MetricsExposedOnMetricsEndpoint(t *testing.T) {
	srv, store, _, jnl, _ := newJournalHarness(t, nil)
	seedJournalReservation(t, store, "acct_metrics", "req-metrics", 100)
	if err := jnl.WriteEffect(journalSettleEffect("acct_metrics", "req-metrics")); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}
	if _, err := srv.RecoverSettlementJournal(context.Background(), 0); err != nil {
		t.Fatalf("recover: %v", err)
	}
	resp := assertStatus(t, srv.Handler(), http.MethodGet, "/metrics", "", "", "127.0.0.1", 200)
	out := resp.Body.String()
	for _, want := range []string{
		"gateway_settlement_journal_effects_total",
		"gateway_settlement_journal_seals_total",
		"gateway_settlement_journal_recovered_total{result=\"settled\"} 1",
		"gateway_settlement_journal_unsealed",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("/metrics missing %q", want)
		}
	}
}

// TestSettlementJournal_CrashBetweenUsageEventAndRefundRecovers pins the
// audit R1 code-HIGH crash window: the §17.7 fallback wrote the usage row,
// then the process crashed before RefundReservation. On restart the DB holds
// an ACTIVE reservation plus a matching usage row, so SettleReservation fails
// on the usage_events PK with an error that is neither NotFound nor Terminal.
// Recovery must fall through to the idempotent rung (verify → refund → seal)
// instead of wedging on the unclassified settle error while DailyUsage
// double-counts.
func TestSettlementJournal_CrashBetweenUsageEventAndRefundRecovers(t *testing.T) {
	srv, store, dbPath, jnl, _ := newJournalHarness(t, nil)
	seedJournalReservation(t, store, "acct_crashwin", "req-crashwin", 100)
	rec := journalSettleEffect("acct_crashwin", "req-crashwin")
	if err := jnl.WriteEffect(rec); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}
	// Simulate the crash window: the usage row exists (identical payload),
	// the reservation is still active, the effect is unsealed.
	if err := store.EnsureUsageEvent(context.Background(), storage.UsageEvent{
		RequestID: "req-crashwin", AccountID: "acct_crashwin",
		WindowDate: rec.WindowDate, PromptTokens: rec.PromptTokens,
		CompletionTokens: rec.CompletionTokens, TotalTokens: rec.TotalTokens,
		TokenSource: rec.TokenSource, Outcome: rec.Outcome, CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatalf("EnsureUsageEvent seed: %v", err)
	}

	summary, err := srv.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("RecoverSettlementJournal: %v", err)
	}
	if summary.UsageEvents != 1 || summary.Quarantined != 0 || summary.Errors != 0 {
		t.Fatalf("summary=%+v — the crash window must resolve via the idempotent rung, "+
			"not wedge on the unclassified settle error", summary)
	}
	rows, total := usageTokenTotals(t, dbPath, "acct_crashwin")
	if rows != 1 || total != 20 {
		t.Fatalf("rows=%d total=%d want exactly 1 row of 20 tokens", rows, total)
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_crashwin")
	if snap.activeRows != 0 || snap.activeReserved != 0 {
		t.Fatalf("reservation hold not released: %+v — DailyUsage would double-count "+
			"the usage row plus the active hold", snap)
	}
	scan, _ := jnl.Scan()
	if len(scan.Unsealed) != 0 {
		t.Fatalf("Unsealed=%d want 0 (sealed usage_event)", len(scan.Unsealed))
	}
}

// refundFailSpyStore drives the §17.7 branch (settle fails, usage-event
// fallback succeeds via the real store) with a failing RefundReservation.
type refundFailSpyStore struct {
	*sqlite.Store
}

func (s *refundFailSpyStore) SettleReservation(context.Context, storage.ReservationSettlement) error {
	return errors.New("injected settle failure (seal-gate test)")
}

func (s *refundFailSpyStore) RefundReservation(context.Context, string, string, int64) error {
	return errors.New("injected refund failure (seal-gate test)")
}

// TestSettlementJournal_RefundFailureLeavesEffectUnsealed pins the audit R1
// architect MEDIUM: the §17.7 fallback must NOT seal past a failed
// RefundReservation — a sealed effect suppresses recovery's retry, leaving
// the still-active hold double-counting against the buyer's quota until the
// reaper. Unsealed, recovery retries the refund and only then seals.
func TestSettlementJournal_RefundFailureLeavesEffectUnsealed(t *testing.T) {
	client := seamStreamingUpstream(func(pw *io.PipeWriter) {
		_, _ = io.WriteString(pw, `data: {"id":"c","usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20},"choices":[{"delta":{"content":"hi"}}]}`+
			"\n\n"+`data: [DONE]`+"\n\n")
		_ = pw.Close()
	})
	_, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Settlement.JournalRecoveryGraceSeconds = 0
	}, WithHTTPClient(client))
	jnl := openTestJournal(t, cfg)
	spy := &refundFailSpyStore{Store: store}
	h := New(cfg, spy, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client), WithSettlementJournal(jnl)).Handler()
	key := createAccountAndKey(t, store, cfg, "acct_refundfail")

	body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	resp := postChat(t, h, key, body, map[string]string{"X-Request-ID": "88888888-8888-4888-8888-888888888888"})
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}

	// The usage row landed (§17.7 fallback), the refund failed, so the effect
	// must remain UNSEALED for recovery.
	scan, err := jnl.Scan()
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(scan.Unsealed) != 1 {
		t.Fatalf("Unsealed=%d want 1 — sealing past a failed refund suppresses the retry", len(scan.Unsealed))
	}

	// Recovery over the real store retries: usage row verifies, refund
	// succeeds, seal lands, hold released, still exactly one bill.
	recovered := New(cfg, store, fakeOAuth{}, WithNow(fixedNow), WithSettlementJournal(jnl))
	summary, err := recovered.RecoverSettlementJournal(context.Background(), 0)
	if err != nil {
		t.Fatalf("RecoverSettlementJournal: %v", err)
	}
	if summary.UsageEvents != 1 {
		t.Fatalf("summary=%+v want one usage-event re-drive", summary)
	}
	rows, total := usageTokenTotals(t, dbPath, "acct_refundfail")
	if rows != 1 || total != 20 {
		t.Fatalf("rows=%d total=%d want 1/20", rows, total)
	}
	snap := gatewaySettlementSnapshot(t, dbPath, "acct_refundfail")
	if snap.activeRows != 0 || snap.activeReserved != 0 {
		t.Fatalf("hold not released after recovery: %+v", snap)
	}
	if scan, _ := jnl.Scan(); len(scan.Unsealed) != 0 {
		t.Fatalf("effect still unsealed after recovery")
	}
}
