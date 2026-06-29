package billing

import (
	"sync"
	"time"
)

// SPEC-005 v0.4 §11.6.6 / §11 — every `/admin/ledger/*` response
// path consumes the SAME rate-limit bucket. v0.4 IMPL ships a
// process-global token bucket keyed by the (single) operator-key
// principal. The bucket is intentionally simple: a token capacity
// + a refill cadence in tokens-per-second. Future spec versions
// may replace this with a multi-tenant or persistent limiter; v0.4
// only needs to satisfy the "every-response consumes" property,
// not a sophisticated traffic shape.

const (
	adminBucketCapacity    = 60   // tokens
	adminBucketRefillPerS  = 60.0 // tokens/sec (1/sec * 60 ≈ same as previous earnings limiter posture)
	adminBucketWindowReset = 60 * time.Second
)

type adminRateLimiter struct {
	mu        sync.Mutex
	tokens    float64
	last      time.Time
	capacity  float64
	refillPS  float64
	now       func() time.Time
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
// is exhausted. SPEC §11.6.6 requires EVERY response code path
// (200, 4xx, 5xx) to consume one token — failure responses do NOT
// bypass.
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
