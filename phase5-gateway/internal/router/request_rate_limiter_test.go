package router

import (
	"fmt"
	"testing"
	"time"
)

func TestRequestRateLimiterPreservesPerSecondRefill(t *testing.T) {
	limiter := newRequestRateLimiter()
	start := time.Unix(1_700_000_000, 0)
	for i, tc := range []struct {
		elapsed time.Duration
		admit   bool
	}{
		{0, true}, {0, true}, {0, false},
		{499 * time.Millisecond, false}, {500 * time.Millisecond, true},
		{500 * time.Millisecond, false}, {time.Second, true},
	} {
		got := limiter.allow("account", 2, start.Add(tc.elapsed))
		if got.Admitted != tc.admit || (!tc.admit && got.RetryAfterSeconds != 1) {
			t.Fatalf("step %d: decision=%+v want admitted=%t", i, got, tc.admit)
		}
	}
}

func TestRequestRateLimiterPerMinuteRefill(t *testing.T) {
	for _, limit := range []int{1, 2, 120} {
		t.Run(fmt.Sprint(limit), func(t *testing.T) {
			limiter := newRequestRateLimiter()
			start := time.Unix(1_700_000_000, 0)
			for i := 0; i < limit; i++ {
				if got := limiter.allowPerMinute("account", limit, start); !got.Admitted || got.Remaining != limit-i-1 {
					t.Fatalf("burst %d: %+v", i, got)
				}
			}
			interval := time.Minute / time.Duration(limit)
			for elapsed := time.Second; elapsed < interval; elapsed += time.Second {
				got := limiter.allowPerMinute("account", limit, start.Add(elapsed))
				wantRetry := int((interval - elapsed + time.Second - 1) / time.Second)
				if got.Admitted || got.RetryAfterSeconds != wantRetry {
					t.Errorf("at %s: %+v want retry=%d", elapsed, got, wantRetry)
				}
			}
			for i := 1; i < 100; i++ {
				if got := limiter.allowPerMinute("account", limit, start.Add(interval*time.Duration(i)/100)); got.Admitted {
					t.Fatalf("probe %d refilled early: %+v", i, got)
				}
			}
			if got := limiter.allowPerMinute("account", limit, start.Add(interval-time.Millisecond)); got.Admitted || got.RetryAfterSeconds != 1 {
				t.Fatalf("before refill: %+v", got)
			}
			if got := limiter.allowPerMinute("account", limit, start.Add(interval)); !got.Admitted || got.Remaining != 0 {
				t.Fatalf("at refill: %+v", got)
			}
			if got := limiter.allowPerMinute("account", limit, start.Add(interval)); got.Admitted {
				t.Fatalf("extra token after refill: %+v", got)
			}
		})
	}
}

func TestRequestRateLimiterCapsDistinctBuckets(t *testing.T) {
	limiter := newRequestRateLimiter()
	now := time.Unix(1_700_000_000, 0)

	for i := 0; i < requestRateMaxBuckets+128; i++ {
		decision := limiter.allow(fmt.Sprintf("acct-%04d", i), 1, now.Add(time.Duration(i)*time.Millisecond))
		if !decision.Admitted {
			t.Fatalf("new key %d rejected: %+v", i, decision)
		}
	}

	if got := len(limiter.buckets); got != requestRateMaxBuckets {
		t.Fatalf("bucket count=%d want hard cap %d", got, requestRateMaxBuckets)
	}
	if _, ok := limiter.buckets["acct-0000"]; ok {
		t.Fatal("oldest bucket was not evicted at hard cap")
	}
	if _, ok := limiter.buckets[fmt.Sprintf("acct-%04d", requestRateMaxBuckets+127)]; !ok {
		t.Fatal("newest bucket missing after cap eviction")
	}
}

func TestRequestRateLimiterPrunesExpiredBeforeEvicting(t *testing.T) {
	limiter := newRequestRateLimiter()
	now := time.Unix(1_700_000_000, 0)

	for i := 0; i < requestRateMaxBuckets; i++ {
		limiter.allow(fmt.Sprintf("old-%04d", i), 1, now)
	}
	limiter.allow("fresh", 1, now.Add(requestRateBucketTTL+time.Second))

	if got := len(limiter.buckets); got != 1 {
		t.Fatalf("bucket count after stale prune=%d want 1", got)
	}
	if _, ok := limiter.buckets["fresh"]; !ok {
		t.Fatal("fresh bucket missing after stale prune")
	}
}
