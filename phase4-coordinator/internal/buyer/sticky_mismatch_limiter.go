package buyer

import (
	"sync"
	"time"
)

// stickyMismatchLimiter throttles the `sticky_account_mismatch`
// warn-log emitted from stickyStore. Issue #266 T1 operational-
// hygiene item: the warn fires on every cross-account refresh refusal,
// which a hostile or buggy gateway client could drive at arbitrary
// rate. The limiter caps emission to one warn per conversation_key
// per window.
//
// Bounded by maxEntries so a runaway gateway cannot cause unbounded
// memory growth keyed on conv-id values it controls. When the entries
// table is at capacity AND a brand-new key arrives, `allow` first
// sweeps every entry that has aged past the window; if that frees a
// slot, the new key takes it. If the sweep frees nothing (every
// existing entry is still within-window), `allow` DENIES the new
// key — no legitimate in-window entry is evicted. This bounds the
// aggregate per-window warn rate to MaxEntries across all unique
// keys under hostile unique-key rotation. R1 CODE audit MEDIUM fix.
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
//
// Cap-bound hostile-rotation defence: when the entries table is at
// MaxEntries AND every entry is still within-window, allow() DENIES
// the brand-new key (returns false). This bounds the per-second
// warn rate under unique-key-rotation pressure to the rate of
// expirations — i.e., at steady state, at most MaxEntries warns
// per window across all unique keys. Without this guard, a hostile
// gateway rotating unique conv-keys faster than `window` could
// drive one warn per request (each new key falls through the
// at-cap eviction path and emits its first warn). Issue #266 T1
// R1 CODE audit MEDIUM finding.
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
		l.sweepExpiredLocked(now)
		if len(l.entries) >= l.maxEntries {
			// Cap still full after sweep — every existing entry is
			// within-window. Deny the new key rather than evicting a
			// legitimate one; aggregate warn rate stays bounded to
			// MaxEntries per window across all unique keys. R1 CODE
			// audit MEDIUM fix.
			return false
		}
	}
	l.entries[key] = now
	return true
}

// sweepExpiredLocked drops every entry older than the window. This
// is the only path that removes entries: callers at-cap with an
// all-within-window map are explicitly DENIED rather than evicting
// a legitimate in-window entry. Caller must hold l.mu.
func (l *stickyMismatchLimiter) sweepExpiredLocked(now time.Time) {
	for k, last := range l.entries {
		if now.Sub(last) >= l.window {
			delete(l.entries, k)
		}
	}
}

// len returns the current number of tracked entries — for tests.
func (l *stickyMismatchLimiter) lenLocked() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.entries)
}
