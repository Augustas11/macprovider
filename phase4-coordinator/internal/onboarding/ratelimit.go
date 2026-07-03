package onboarding

import (
	"sync"
	"time"
)

// MemoryRateLimiter is a fixed-window limiter for the small SPEC-026
// register surface. Production has one process per coordinator on Pearl, so
// process-local limiting is sufficient for Step 1's deploy-disabled path.
type MemoryRateLimiter struct {
	mu     sync.Mutex
	limit  int
	window time.Duration
	now    func() time.Time
	hits   map[string][]time.Time
}

func NewMemoryRateLimiter(limit int, window time.Duration) *MemoryRateLimiter {
	return &MemoryRateLimiter{
		limit:  limit,
		window: window,
		now:    time.Now,
		hits:   make(map[string][]time.Time),
	}
}

func (l *MemoryRateLimiter) Allow(key string) bool {
	if l == nil || l.limit <= 0 || l.window <= 0 {
		return false
	}
	now := l.now().UTC()
	cutoff := now.Add(-l.window)

	l.mu.Lock()
	defer l.mu.Unlock()

	existing := l.hits[key]
	kept := existing[:0]
	for _, ts := range existing {
		if ts.After(cutoff) {
			kept = append(kept, ts)
		}
	}
	if len(kept) >= l.limit {
		l.hits[key] = kept
		return false
	}
	kept = append(kept, now)
	l.hits[key] = kept
	return true
}
