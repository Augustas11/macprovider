package billing

import (
	"sync"
	"time"
)

// SPEC-005 v0.4 §11.6.6 / §11 — every authenticated `/admin/ledger/*`
// response path consumes the SAME rate-limit bucket. v0.4 IMPL ships
// a process-global token bucket keyed by the (single) operator-key
// principal. The bucket is intentionally simple: a token capacity + a
// refill cadence in tokens-per-second. Future spec versions may replace
// this with a multi-tenant or persistent limiter; v0.4 only needs to
// satisfy the "authenticated response consumes" property, not a
// sophisticated traffic shape.

const (
	// R3 fix (CODE-H1): SPEC AC-Q049 requires 64 concurrent POSTs to
	// reach the UNIQUE-race layer. With the previous 60-token cap,
	// the bucket drained before all 64 callers could hit the
	// resolution INSERT (4 received 429 instead of 409), which forced
	// AC-Q049 to test 32 threads instead of the SPEC-mandated 64.
	// Capacity is raised to 128 — comfortably admits the 64-thread
	// burst while still keeping a tight ceiling on operator-key abuse
	// (refill is still 60/sec so steady-state behavior is unchanged).
	adminBucketCapacity    = 128  // tokens
	adminBucketRefillPerS  = 60.0 // tokens/sec
	adminBucketWindowReset = 60 * time.Second
)

type adminRateLimiter struct {
	mu       sync.Mutex
	tokens   float64
	last     time.Time
	capacity float64
	refillPS float64
	now      func() time.Time
}

func newAdminRateLimiter() *adminRateLimiter {
	return &adminRateLimiter{
		tokens:   float64(adminBucketCapacity),
		last:     time.Now(),
		capacity: float64(adminBucketCapacity),
		refillPS: adminBucketRefillPerS,
		now:      time.Now,
	}
}

// Allow returns true if a token was consumed, false if the bucket
// is exhausted. SPEC §11.6.6 requires every authenticated response code
// path (200, 4xx, 5xx) to consume one token; unauthenticated failures
// are rejected before the operator-key bucket to avoid letting unauth
// traffic drain authenticated admin capacity.
func (b *adminRateLimiter) Allow() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	elapsed := now.Sub(b.last).Seconds()
	if elapsed > 0 {
		b.tokens += elapsed * b.refillPS
		if b.tokens > b.capacity {
			b.tokens = b.capacity
		}
		b.last = now
	}
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}
