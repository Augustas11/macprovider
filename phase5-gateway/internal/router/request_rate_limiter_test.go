package router

import (
	"fmt"
	"testing"
	"time"
)

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
