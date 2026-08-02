package payout

import (
	"sync"
	"time"
)

// SPEC-016 §3.3:833 requires a provider-scoped rate limit on the
// payout-address registration POST: default 6 registrations per
// hour, returning 429 with a §7.1 log line. A reusable per-key
// fixed-window limiter already exists in the coordinator
// (onboarding.MemoryRateLimiter), but wiring it here would make the
// money-path `payout` package import the unrelated `onboarding`
// package and break the deliberately one-way import graph documented
// in addresses.go. We therefore ship a minimal, self-contained
// per-provider fixed-window limiter local to this package. It is
// process-local, which is sufficient: production runs a single
// coordinator process per Pearl VPS (same assumption
// onboarding.MemoryRateLimiter documents).
const (
	// registrationRateLimitDefault is the SPEC-016 §3.3:833
	// default cap of 6 registrations per provider per window.
	registrationRateLimitDefault = 6
	// registrationRateWindow is the §3.3:833 window (1 hour).
	registrationRateWindow = time.Hour
)

// registrationRateLimiter is a per-provider fixed-window limiter for
// the §3.3 registration POST. The zero value is not usable; construct
// with newRegistrationRateLimiter.
type registrationRateLimiter struct {
	mu        sync.Mutex
	limit     int
	window    time.Duration
	hits      map[string][]time.Time
	lastSweep time.Time
}

func newRegistrationRateLimiter(limit int, window time.Duration) *registrationRateLimiter {
	return &registrationRateLimiter{
		limit:  limit,
		window: window,
		hits:   make(map[string][]time.Time),
	}
}

// allow records a registration attempt for providerID at time now and
// reports whether it is within the window budget. It returns false
// once the provider has reached `limit` attempts inside the trailing
// `window` (→ HTTP 429). Callers MUST pass the service clock (s.Now)
// so injected test clocks and skew handling stay consistent. M3: a nil
// or mis-configured (zero limit/window) limiter FAILS CLOSED (returns
// false → the registration is rejected) rather than silently disabling
// the abuse-control gate. Production never hits this — NewAddressesService
// constructs a valid limiter and rejects invalid config at construction.
func (l *registrationRateLimiter) allow(providerID string, now time.Time) bool {
	if l == nil || l.limit <= 0 || l.window <= 0 {
		return false
	}
	now = now.UTC()
	cutoff := now.Add(-l.window)

	l.mu.Lock()
	defer l.mu.Unlock()

	// M2: periodic global sweep so the map does not grow unbounded under
	// provider churn. A provider that stops registering is only ever
	// re-touched by this sweep; without it, its (eventually empty) slice
	// would be retained forever. Runs at most once per window. Matches
	// onboarding.MemoryRateLimiter's eviction pattern.
	if l.lastSweep.IsZero() || !now.Before(l.lastSweep.Add(l.window)) {
		for key, timestamps := range l.hits {
			kept := timestamps[:0]
			for _, ts := range timestamps {
				if ts.After(cutoff) {
					kept = append(kept, ts)
				}
			}
			if len(kept) == 0 {
				delete(l.hits, key)
			} else {
				l.hits[key] = kept
			}
		}
		l.lastSweep = now
	}

	existing := l.hits[providerID]
	kept := existing[:0]
	for _, ts := range existing {
		if ts.After(cutoff) {
			kept = append(kept, ts)
		}
	}
	if len(kept) >= l.limit {
		l.hits[providerID] = kept
		return false
	}
	kept = append(kept, now)
	l.hits[providerID] = kept
	return true
}
