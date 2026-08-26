package router

import (
	"net/http"
	"sort"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// TestPoolRejectionTimingFloor_EnforcedAndUniform covers SPEC-043-R007: every
// pool-selection rejection honors the active timing floor, and unknown vs
// unauthorized rejection latency stays inside the p95/p99 delta bounds.
func TestPoolRejectionTimingFloor_EnforcedAndUniform(t *testing.T) {
	const floor = 50 * time.Millisecond
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true}}`, func(cfg *config.Config) {
		cfg.Features.TrustedPools.RejectionTimingFloorMS = 50
		cfg.Quotas.AccountRequestRatePerSecond = 1000
	})

	measure := func(selector string) time.Duration {
		t.Helper()
		start := time.Now()
		resp := postChat(t, h, key, poolChatBody, selectHeader(selector))
		elapsed := time.Since(start)
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("status=%d body=%s, want 503", resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "pool_unavailable")
		if elapsed+5*time.Millisecond < floor {
			t.Fatalf("elapsed=%s below floor=%s for selector=%q", elapsed, floor, selector)
		}
		return elapsed
	}

	const samples = 16
	unknown := make([]time.Duration, 0, samples)
	unauthorized := make([]time.Duration, 0, samples)
	for i := 0; i < samples; i++ {
		unknown = append(unknown, measure("zzzzzzzzzzzzzzzzzzzzzz"))
		unauthorized = append(unauthorized, measure("bbbbbbbbbbbbbbbbbbbbbb"))
	}
	if cap.chatHits != 0 || cap.routingHits != 0 {
		t.Fatalf("rejection path consulted coordinator chat=%d routing=%d", cap.chatHits, cap.routingHits)
	}

	p95Delta := absDuration(percentileDuration(unknown, 0.95) - percentileDuration(unauthorized, 0.95))
	p99Delta := absDuration(percentileDuration(unknown, 0.99) - percentileDuration(unauthorized, 0.99))
	if p95Delta > 15*time.Millisecond {
		t.Fatalf("p95 delta=%s exceeds 15ms unknown=%v unauthorized=%v", p95Delta, unknown, unauthorized)
	}
	if p99Delta > 25*time.Millisecond {
		t.Fatalf("p99 delta=%s exceeds 25ms unknown=%v unauthorized=%v", p99Delta, unknown, unauthorized)
	}
}

func percentileDuration(values []time.Duration, p float64) time.Duration {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]time.Duration(nil), values...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	idx := int(float64(len(sorted)-1) * p)
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func absDuration(d time.Duration) time.Duration {
	if d < 0 {
		return -d
	}
	return d
}
