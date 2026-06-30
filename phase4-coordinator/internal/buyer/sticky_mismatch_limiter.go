package buyer

import (
	"sync"
	"time"
)

// stickyMismatchLimiter throttles the `sticky_account_mismatch`
// warn-log emitted from stickyStore. Issue #266 deferred operational-
// hygiene item: the warn fires on every cross-account refresh refusal,
// which a hostile or buggy gateway client could drive at arbitrary
// rate. The limiter caps emission to one warn per conversation_key
// per window.
//
// Bounded by maxEntries so a runaway gateway cannot cause unbounded
// memory growth keyed on conv-id values it controls. When at capacity
// AND a brand-new key arrives, the oldest entry (by lastWarnAt) is
// evicted before insertion. The eviction is O(n) per cap-bound insert,
// which is acceptable because maxEntries is bounded by the existing
// sticky-map MaxEntries config (default 10000) and inserts at the cap
// are themselves rate-limited by the hostile-traffic budget the
// caller is trying to defend against.
type stickyMismatchLimiter struct {
	mu         sync.Mutex
	window     time.Duration
	maxEntries int
	entries    map[string]time.Time
	now        func() time.Time
}

func newStickyMismatchLimiter(window time.Duration, maxEntries int) *stickyMismatchLimiter {
	if window <= 0 {
		window = time.Minute
	}
	if maxEntries <= 0 {
		maxEntries = 10000
	}
	return &stickyMismatchLimiter{
		window:     window,
		maxEntries: maxEntries,
		entries:    make(map[string]time.Time),
		now:        time.Now,
	}
}

// allow reports whether the caller should emit a sticky_account_mismatch
// warn for the supplied conversation_key. Returns true on the first
// call for a key, and on the first call after `window` has elapsed
// since the prior allow. Empty key falls back to a single shared
// bucket so an unkeyed caller still gets throttled (defensive — the
// real caller always has a non-empty key).
func (l *stickyMismatchLimiter) allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if last, ok := l.entries[key]; ok {
		if now.Sub(last) < l.window {
			return false
		}
		l.entries[key] = now
		return true
	}
	if len(l.entries) >= l.maxEntries {
		l.evictOldestLocked(now)
	}
	l.entries[key] = now
	return true
}

func (l *stickyMismatchLimiter) evictOldestLocked(now time.Time) {
	// First sweep: drop every entry older than window (expired —
	// future calls would allow regardless). This keeps the map
	// trim under sustained pressure without paying full O(n) every
	// time at the cap.
	for k, last := range l.entries {
		if now.Sub(last) >= l.window {
			delete(l.entries, k)
		}
	}
	if len(l.entries) < l.maxEntries {
		return
	}
	// Sweep did not free space (every entry is within-window).
	// Evict the single oldest to make room.
	var oldestKey string
	var oldestAt time.Time
	first := true
	for k, last := range l.entries {
		if first || last.Before(oldestAt) {
			oldestKey = k
			oldestAt = last
			first = false
		}
	}
	if oldestKey != "" {
		delete(l.entries, oldestKey)
	}
}

// len returns the current number of tracked entries — for tests.
func (l *stickyMismatchLimiter) lenLocked() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.entries)
}
