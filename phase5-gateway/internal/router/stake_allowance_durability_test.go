package router

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/settlement/journal"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

// flakyAllowanceStore fails chosen SPEC-050 writes a set number of times.
type flakyAllowanceStore struct {
	*sqlite.Store
	markFailures int
	noteFailures int
	settleErr    error
}

func (f *flakyAllowanceStore) MarkReservationFundingSource(ctx context.Context, accountID, requestID, source string) error {
	if f.markFailures > 0 {
		f.markFailures--
		return errors.New("database is locked")
	}
	return f.Store.MarkReservationFundingSource(ctx, accountID, requestID, source)
}

func (f *flakyAllowanceStore) NoteAllowanceDay(ctx context.Context, accountID, day string, active bool, now time.Time) error {
	if f.noteFailures > 0 {
		f.noteFailures--
		return errors.New("database is locked")
	}
	return f.Store.NoteAllowanceDay(ctx, accountID, day, active, now)
}

func (f *flakyAllowanceStore) SettleReservation(ctx context.Context, settlement storage.ReservationSettlement) error {
	if f.settleErr != nil {
		return f.settleErr
	}
	return f.Store.SettleReservation(ctx, settlement)
}

func newFlakyAllowanceServer(t *testing.T) (*Server, *flakyAllowanceStore, string, *journal.Journal) {
	t.Helper()
	cfg := journalTestConfig(t, nil)
	store, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	jnl := openTestJournal(t, cfg)
	flaky := &flakyAllowanceStore{Store: store}
	return New(cfg, flaky, fakeOAuth{}, WithNow(fixedNow), WithSettlementJournal(jnl)), flaky, cfg.Storage.DBPath, jnl
}

func requestWithID(id string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	return r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id))
}

func allowanceResponseHeaders() http.Header {
	h := http.Header{}
	h.Set(allowanceFundingHeader, "allowance")
	h.Set(allowanceActiveHeader, "1")
	return h
}

// The confirmed-funding mark is retried, so a transient failure does not
// leave an allowance request on the paid quota for recovery paths that read
// the reservation row (relay-blind finality and status reconciliation).
func TestAllowanceFundingMarkIsRetried(t *testing.T) {
	srv, flaky, _, _ := newFlakyAllowanceServer(t)
	seedJournalReservation(t, flaky.Store, "acct_retry", "req-retry", 100)
	flaky.markFailures = len(markFundingRetryDelays) - 1
	subject := usageSubject{AccountID: "acct_retry", ReservationCreatedAt: fixedNow()}
	srv.noteAllowanceResponse(requestWithID("req-retry"), &subject, allowanceResponseHeaders())
	if !subject.AllowanceFunded {
		t.Fatal("confirmed allowance not recorded on the subject")
	}
	if _, reserved, err := flaky.DailyUsage(context.Background(), "acct_retry", journalTestWindow); err != nil || reserved != 0 {
		t.Fatalf("reserved=%d err=%v: the retried mark must take the hold off the paid quota", reserved, err)
	}
}

// When the settlement fails and the confirmed funding cannot be persisted,
// the live fallback leaves the journaled effect for recovery instead of
// billing the paid quota; recovery then settles it on the allowance.
func TestLiveFallbackDefersWhenFundingIsNotDurable(t *testing.T) {
	srv, flaky, dbPath, jnl := newFlakyAllowanceServer(t)
	seedJournalReservation(t, flaky.Store, "acct_defer", "req-defer", 100)
	flaky.settleErr = errors.New("database is locked")
	flaky.markFailures = 100
	subject := usageSubject{AccountID: "acct_defer", ReservationCreatedAt: fixedNow(), AllowanceFunded: true}
	srv.settleAfterCommit(requestWithID("req-defer"), subject, 8, 12, 20, "provider_reported", "ok", journalTestWindow)
	state := gatewaySettlementSnapshot(t, dbPath, "acct_defer")
	if state.usageRows != 0 || state.activeRows != 1 {
		t.Fatalf("state=%+v: the fallback must not bill while the funding is not durable", state)
	}
	scan, _ := jnl.Scan()
	if len(scan.Unsealed) != 1 || scan.Unsealed[0].FundingSource != storage.FundingSourceAllowance {
		t.Fatalf("unsealed=%+v, want one effect journaled with allowance funding", scan.Unsealed)
	}
	flaky.settleErr, flaky.markFailures = nil, 0
	if _, err := srv.RecoverSettlementJournal(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	used, reserved, err := flaky.DailyUsage(context.Background(), "acct_defer", journalTestWindow)
	if err != nil || used != 0 || reserved != 0 {
		t.Fatalf("used=%d reserved=%d err=%v after recovery, want the usage on the allowance", used, reserved, err)
	}
}

// The journal recovery's usage-event rung leaves the effect unsealed while
// the funding write fails, and seals it once the write succeeds.
func TestJournalRecoveryRetriesUntilFundingIsDurable(t *testing.T) {
	srv, flaky, dbPath, jnl := newFlakyAllowanceServer(t)
	seedJournalReservation(t, flaky.Store, "acct_jretry", "req-jretry", 100)
	if err := flaky.RefundReservation(context.Background(), "acct_jretry", "req-jretry", fixedNow().Unix()); err != nil {
		t.Fatal(err)
	}
	rec := journalSettleEffect("acct_jretry", "req-jretry")
	rec.FundingSource = storage.FundingSourceAllowance
	if err := jnl.WriteEffect(rec); err != nil {
		t.Fatal(err)
	}
	flaky.markFailures = 1
	if _, err := srv.RecoverSettlementJournal(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	if state := gatewaySettlementSnapshot(t, dbPath, "acct_jretry"); state.usageRows != 0 {
		t.Fatalf("state=%+v: no usage row before the funding is durable", state)
	}
	if scan, _ := jnl.Scan(); len(scan.Unsealed) != 1 {
		t.Fatalf("unsealed=%d, want the effect kept for retry", len(scan.Unsealed))
	}
	if _, err := srv.RecoverSettlementJournal(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	if scan, _ := jnl.Scan(); len(scan.Unsealed) != 0 {
		t.Fatalf("unsealed=%d after the retry, want sealed", len(scan.Unsealed))
	}
	used, _, err := flaky.DailyUsage(context.Background(), "acct_jretry", journalTestWindow)
	if err != nil || used != 0 {
		t.Fatalf("used=%d err=%v: recovered allowance usage must leave the paid quota", used, err)
	}
}

// A positive allowance day enters the memory cache only after the shared
// table holds it.
func TestPositiveAllowanceDayIsCachedOnlyAfterItIsStored(t *testing.T) {
	srv, flaky, _, _ := newFlakyAllowanceServer(t)
	day := fixedNow().UTC().Format("2006-01-02")
	flaky.noteFailures = 1
	srv.noteAllowanceDay("acct_cache", day, true)
	if srv.allowance.has("acct_cache", day) {
		t.Fatal("a failed write must not be cached")
	}
	srv.noteAllowanceDay("acct_cache", day, true)
	if !srv.allowance.has("acct_cache", day) {
		t.Fatal("a stored positive answer must be cached")
	}
	if ok, err := flaky.AllowanceDayActive(context.Background(), "acct_cache", day); err != nil || !ok {
		t.Fatalf("shared table active=%v err=%v", ok, err)
	}
}
