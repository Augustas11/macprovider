package billing

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestLogBillingJobErrorEmitsStructuredError(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })

	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	end := start.AddDate(0, 0, 7)
	logBillingJobError("weekly_settlement", errors.New("boom"), start, end)
	got := buf.String()
	for _, want := range []string{"billing background job failed", "weekly_settlement", "boom"} {
		if !strings.Contains(got, want) {
			t.Fatalf("log %q missing %q", got, want)
		}
	}
}

func TestRunSettlementCancelledContextFailsClosed(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	err := store.RunSettlement(ctx, SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, start, start.AddDate(0, 0, 7))
	if err == nil {
		t.Fatal("expected cancelled context to fail RunSettlement")
	}
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })
	logBillingJobError("weekly_settlement", err, start, start.AddDate(0, 0, 7))
	if !strings.Contains(buf.String(), "weekly_settlement") {
		t.Fatalf("log=%q", buf.String())
	}
}

func TestRunSettlementCommitsEmptyWindowMarker(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	start := time.Date(2026, 9, 21, 0, 0, 0, 0, time.UTC)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_settlement_windows`); got != 1 {
		t.Fatalf("settlement window markers=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 0 {
		t.Fatalf("empty settlement payout rows=%d want 0", got)
	}
}

func TestRunSettlementDoesNotCommitMarkerOnRollback(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	start := time.Date(2026, 9, 21, 0, 0, 0, 0, time.UTC)
	if err := store.RunSettlement(ctx, SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, start, start.AddDate(0, 0, 7)); err == nil {
		t.Fatal("cancelled settlement unexpectedly succeeded")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_settlement_windows`); got != 0 {
		t.Fatalf("rolled-back settlement window markers=%d want 0", got)
	}
}

func TestRunMissedSettlementsReplaysWindowsInOrder(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	firstEnd := time.Date(2026, 9, 14, 0, 0, 0, 0, time.UTC)
	if err := store.RunSettlement(context.Background(), cfg, firstEnd.AddDate(0, 0, -7), firstEnd); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	if err := store.RunMissedSettlements(context.Background(), cfg, now); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_settlement_windows`); got != 3 {
		t.Fatalf("settlement window markers=%d want 3", got)
	}
	var end string
	if err := store.db.QueryRow(`SELECT window_end_utc FROM ledger_settlement_windows ORDER BY window_end_utc DESC LIMIT 1`).Scan(&end); err != nil {
		t.Fatal(err)
	}
	if end != sqliteTimeText(time.Date(2026, 9, 28, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("last catch-up end=%q", end)
	}
}

func TestRunMissedSettlementsBootstrapsLatestClosedWindow(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	if err := store.RunMissedSettlements(context.Background(), cfg, now); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_settlement_windows`); got != 1 {
		t.Fatalf("bootstrap settlement window markers=%d want 1", got)
	}
}

func TestRunMissedSettlementsBootstrapsEveryHistoricalLedgerWindow(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	oldest := time.Date(2026, 9, 8, 12, 0, 0, 0, time.UTC)
	insertCreditWithRequest(t, store.db, "historical-unmarked", "provider-a", oldest, 100)
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	if err := store.RunMissedSettlements(context.Background(), cfg, now); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_settlement_windows`); got != 3 {
		t.Fatalf("historical settlement window markers=%d want 3", got)
	}
	var firstEnd string
	if err := store.db.QueryRow(`SELECT window_end_utc FROM ledger_settlement_windows ORDER BY window_end_utc LIMIT 1`).Scan(&firstEnd); err != nil {
		t.Fatal(err)
	}
	if firstEnd != sqliteTimeText(time.Date(2026, 9, 14, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("first historical catch-up end=%q", firstEnd)
	}
}

func TestRunMissedSettlementsRepairsMarkerHoleBeforeLatestMarker(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	oldest := time.Date(2026, 9, 8, 12, 0, 0, 0, time.UTC)
	insertCreditWithRequest(t, store.db, "marker-hole", "provider-a", oldest, 100)
	for _, end := range []time.Time{
		time.Date(2026, 9, 14, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 9, 28, 0, 0, 0, 0, time.UTC),
	} {
		if err := store.RunSettlement(context.Background(), cfg, end.AddDate(0, 0, -7), end); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.RunMissedSettlements(context.Background(), cfg, time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_settlement_windows`); got != 3 {
		t.Fatalf("settlement markers after hole repair=%d want 3", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_settlement_windows WHERE window_end_utc=?`, sqliteTimeText(time.Date(2026, 9, 21, 0, 0, 0, 0, time.UTC))); got != 1 {
		t.Fatalf("repaired September 21 marker count=%d want 1", got)
	}
}

func TestRunMissedSettlementsCapsPassAndResumesThroughMarkers(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	oldest := time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)
	insertCreditWithRequest(t, store.db, "bounded-catchup", "provider-a", oldest, 100)
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	err := store.RunMissedSettlements(context.Background(), cfg, now)
	if !errors.Is(err, ErrSettlementCatchUpIncomplete) {
		t.Fatalf("first historical catch-up error=%v want ErrSettlementCatchUpIncomplete", err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_settlement_windows`); got != settlementCatchUpMaxWindowsPerPass {
		t.Fatalf("first catch-up markers=%d want cap=%d", got, settlementCatchUpMaxWindowsPerPass)
	}
	for pass := 0; pass < 10; pass++ {
		err = store.RunMissedSettlements(context.Background(), cfg, now)
		if err == nil {
			break
		}
		if !errors.Is(err, ErrSettlementCatchUpIncomplete) {
			t.Fatalf("catch-up pass %d: %v", pass+2, err)
		}
	}
	if err != nil {
		t.Fatalf("bounded catch-up did not complete: %v", err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_settlement_windows`); got <= settlementCatchUpMaxWindowsPerPass {
		t.Fatalf("resumed catch-up markers=%d want more than one pass", got)
	}
}
