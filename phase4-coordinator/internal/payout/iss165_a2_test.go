package payout

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// #165 A2 — ChronicOutageTracker locks the sliding-window
// per-label detector behavior.

func TestChronicOutageTracker_EmitsPageWhenThresholdCrossed(t *testing.T) {
	now := time.Date(2026, 6, 29, 12, 0, 0, 0, time.UTC)
	var buf bytes.Buffer
	log := zerolog.New(&buf)
	tracker := NewChronicOutageTracker(log, func() time.Time { return now }).
		WithWindow(10 * time.Minute).
		WithThreshold(0.5).
		WithMinSamples(10).
		WithCooldown(10 * time.Minute)
	for i := 0; i < 10; i++ {
		// 60% error rate on "primary".
		tracker.Record("primary", i%5 != 0 && i%5 != 1)
	}
	// Recompute: 6 of 10 are errs (i in {2,3,4,7,8,9}) — 60% > 50%.
	paged := tracker.Evaluate(context.Background(), now)
	if len(paged) != 1 || paged[0] != "primary" {
		t.Fatalf("paged=%v, want [primary]", paged)
	}
	var ev map[string]any
	for _, line := range strings.Split(strings.TrimRight(buf.String(), "\n"), "\n") {
		_ = json.Unmarshal([]byte(line), &ev)
		if ev["event"] == "payout_rpc_chronic_outage" {
			break
		}
		ev = nil
	}
	if ev == nil {
		t.Fatalf("no payout_rpc_chronic_outage event emitted; log=%q", buf.String())
	}
	if ev["rpc_label"] != "primary" {
		t.Errorf("rpc_label=%v, want primary", ev["rpc_label"])
	}
	if ev["severity"] != "PAGE" {
		t.Errorf("severity=%v, want PAGE", ev["severity"])
	}
	if rate, _ := ev["error_rate"].(float64); rate < 0.5 {
		t.Errorf("error_rate=%v, want >= 0.5", ev["error_rate"])
	}
}

func TestChronicOutageTracker_RespectsCooldown(t *testing.T) {
	now := time.Date(2026, 6, 29, 12, 0, 0, 0, time.UTC)
	var buf bytes.Buffer
	log := zerolog.New(&buf)
	tracker := NewChronicOutageTracker(log, func() time.Time { return now }).
		WithWindow(10 * time.Minute).
		WithThreshold(0.5).
		WithMinSamples(10).
		WithCooldown(10 * time.Minute)
	for i := 0; i < 10; i++ {
		tracker.Record("primary", true)
	}
	first := tracker.Evaluate(context.Background(), now)
	if len(first) != 1 {
		t.Fatalf("first evaluate paged=%v, want one", first)
	}
	// Second Evaluate within the cooldown MUST NOT page again.
	soon := now.Add(time.Minute)
	second := tracker.Evaluate(context.Background(), soon)
	if len(second) != 0 {
		t.Errorf("second evaluate within cooldown paged=%v, want zero", second)
	}
	// Past the cooldown — re-page allowed.
	later := now.Add(11 * time.Minute)
	// Records must still be inside the window for re-page; add fresh ones at `later`.
	tracker.nowFn = func() time.Time { return later }
	for i := 0; i < 10; i++ {
		tracker.Record("primary", true)
	}
	third := tracker.Evaluate(context.Background(), later)
	if len(third) != 1 {
		t.Errorf("third evaluate past cooldown paged=%v, want one", third)
	}
}

func TestChronicOutageTracker_RequiresMinSamples(t *testing.T) {
	now := time.Date(2026, 6, 29, 12, 0, 0, 0, time.UTC)
	var buf bytes.Buffer
	log := zerolog.New(&buf)
	tracker := NewChronicOutageTracker(log, func() time.Time { return now }).
		WithWindow(10 * time.Minute).
		WithThreshold(0.5).
		WithMinSamples(10).
		WithCooldown(10 * time.Minute)
	// 5 errors out of 5 is 100% rate but only 5 samples (< 10).
	for i := 0; i < 5; i++ {
		tracker.Record("primary", true)
	}
	paged := tracker.Evaluate(context.Background(), now)
	if len(paged) != 0 {
		t.Errorf("paged with %d samples, expected zero (below minSamples)", 5)
	}
	if strings.Contains(buf.String(), "payout_rpc_chronic_outage") {
		t.Errorf("PAGE emitted below minSamples; log=%q", buf.String())
	}
}

func TestChronicOutageTracker_PrunesStaleSamples(t *testing.T) {
	t0 := time.Date(2026, 6, 29, 12, 0, 0, 0, time.UTC)
	cur := t0
	tracker := NewChronicOutageTracker(zerolog.Nop(), func() time.Time { return cur }).
		WithWindow(10 * time.Minute).
		WithThreshold(0.5).
		WithMinSamples(10).
		WithCooldown(10 * time.Minute)
	// 10 errors at t0 — would page if still in window.
	for i := 0; i < 10; i++ {
		tracker.Record("primary", true)
	}
	// Jump 30 minutes; old samples are now outside the 10min window.
	cur = t0.Add(30 * time.Minute)
	paged := tracker.Evaluate(context.Background(), cur)
	if len(paged) != 0 {
		t.Errorf("paged=%v after window expiry, want zero (stale samples must be pruned)", paged)
	}
}

func TestChronicOutageTracker_PerLabelIsolation(t *testing.T) {
	now := time.Date(2026, 6, 29, 12, 0, 0, 0, time.UTC)
	tracker := NewChronicOutageTracker(zerolog.Nop(), func() time.Time { return now }).
		WithWindow(10 * time.Minute).
		WithThreshold(0.5).
		WithMinSamples(10).
		WithCooldown(10 * time.Minute)
	for i := 0; i < 10; i++ {
		tracker.Record("primary", true) // 100% err
	}
	for i := 0; i < 10; i++ {
		tracker.Record("secondary", false) // 0% err
	}
	paged := tracker.Evaluate(context.Background(), now)
	if len(paged) != 1 || paged[0] != "primary" {
		t.Errorf("paged=%v, want [primary] (secondary is healthy)", paged)
	}
}

func TestChronicOutageTracker_NilSafeAndConcurrent(t *testing.T) {
	// nil receiver MUST be safe (defensive — the wrapper passes the
	// inner client through when tracker is nil, but Record may still
	// be called by tests via the wrapper path).
	var t0 *ChronicOutageTracker
	t0.Record("primary", true) // must not panic

	tracker := NewChronicOutageTracker(zerolog.Nop(), nil)
	// 100 goroutines × 10 records each — race detector clean.
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 10; j++ {
				tracker.Record("primary", j%2 == 0)
			}
		}()
	}
	wg.Wait()
	tracker.mu.Lock()
	got := len(tracker.states["primary"].samples)
	tracker.mu.Unlock()
	if got != 1000 {
		t.Errorf("samples=%d, want 1000", got)
	}
}

// TestTrackingRPCClient_RecordsSuccessAndError pins the wrapper's
// classification: only non-nil errors count as errors; the
// (nil, nil) "not found" success path does not.
func TestTrackingRPCClient_RecordsSuccessAndError(t *testing.T) {
	now := time.Date(2026, 6, 29, 12, 0, 0, 0, time.UTC)
	tracker := NewChronicOutageTracker(zerolog.Nop(), func() time.Time { return now })
	inner := &mockRPCClient{label: "primary"}
	// First call: nil receipt + nil error → SUCCESS (not an err).
	inner.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, nil }
	wrapped := NewTrackingRPCClient(inner, tracker)
	if _, err := wrapped.TransactionReceipt(context.Background(), "0xabc"); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	// Second call: real error.
	inner.receiptFn = func(_ context.Context, _ string) (*Receipt, error) { return nil, errors.New("boom") }
	if _, err := wrapped.TransactionReceipt(context.Background(), "0xabc"); err == nil {
		t.Fatalf("expected err, got nil")
	}
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	st := tracker.states["primary"]
	if st == nil || len(st.samples) != 2 {
		t.Fatalf("samples=%v, want 2", st)
	}
	if st.samples[0].isErr {
		t.Errorf("sample 0: (nil, nil) classified as error, want success")
	}
	if !st.samples[1].isErr {
		t.Errorf("sample 1: non-nil err classified as success, want error")
	}
}

// TestTrackingRPCClient_NilTrackerReturnsInner pins the zero-value
// short-circuit: a nil tracker MUST return the inner client
// unchanged so test paths that don't wire a tracker stay zero-cost.
func TestTrackingRPCClient_NilTrackerReturnsInner(t *testing.T) {
	inner := &mockRPCClient{label: "primary"}
	got := NewTrackingRPCClient(inner, nil)
	if got != inner {
		t.Errorf("nil tracker did not return inner client; got %T", got)
	}
}
