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
