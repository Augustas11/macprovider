package onboarding

import (
	"fmt"
	"testing"
	"time"
)

func TestMemoryRateLimiterSweepsExpiredOneShotKeys(t *testing.T) {
	now := time.Date(2026, 7, 17, 12, 0, 0, 0, time.UTC)
	limiter := NewMemoryRateLimiter(5, time.Minute)
	limiter.now = func() time.Time { return now }

	for i := range 100 {
		if !limiter.Allow(fmt.Sprintf("provider-%d", i)) {
			t.Fatalf("one-shot key %d unexpectedly denied", i)
		}
	}
	if got := len(limiter.hits); got != 100 {
		t.Fatalf("tracked keys=%d want 100 before expiry", got)
	}

	now = now.Add(time.Minute + time.Second)
	if !limiter.Allow("current-provider") {
		t.Fatal("current key unexpectedly denied after sweep")
	}
	if got := len(limiter.hits); got != 1 {
		t.Fatalf("tracked keys=%d want 1 after expired-key sweep", got)
	}
}
