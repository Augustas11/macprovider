package router

import (
	"sync"
	"time"
)

const (
	publicStatsRateLimitWindow = time.Minute
	publicStatsRateMaxBuckets  = 4096
)

type publicStatsRateDecision struct {
	Admitted          bool
	RetryAfterSeconds int
}

type publicStatsRateLimiter struct {
	mu      sync.Mutex
	buckets map[string]publicStatsRateBucket
}

type publicStatsRateBucket struct {
	windowStart time.Time
	count       int
	lastSeen    time.Time
}

func newPublicStatsRateLimiter() *publicStatsRateLimiter {
	return &publicStatsRateLimiter{buckets: make(map[string]publicStatsRateBucket)}
}

func (l *publicStatsRateLimiter) allow(key string, now time.Time) publicStatsRateDecision {
	if l == nil || key == "" {
		return publicStatsRateDecision{Admitted: true}
	}
	l.mu.Lock()
	defer l.mu.Unlock()

	bucket := l.buckets[key]
	if bucket.windowStart.IsZero() && len(l.buckets) >= publicStatsRateMaxBuckets {
		l.pruneLocked(now)
		for len(l.buckets) >= publicStatsRateMaxBuckets {
			l.evictOldestLocked()
		}
	}
	if bucket.windowStart.IsZero() || now.Sub(bucket.windowStart) >= publicStatsRateLimitWindow || now.Before(bucket.windowStart) {
		bucket = publicStatsRateBucket{windowStart: now}
	}
	bucket.lastSeen = now
	if bucket.count < publicStatsRPM {
		bucket.count++
		l.buckets[key] = bucket
		return publicStatsRateDecision{Admitted: true}
	}
	l.buckets[key] = bucket
	retryAfter := int(bucket.windowStart.Add(publicStatsRateLimitWindow).Sub(now).Seconds())
	if retryAfter < 1 {
		retryAfter = 1
	}
	l.pruneLocked(now)
	return publicStatsRateDecision{Admitted: false, RetryAfterSeconds: retryAfter}
}

func (l *publicStatsRateLimiter) pruneLocked(now time.Time) {
	cutoff := now.Add(-publicStatsRateLimitWindow)
	for key, bucket := range l.buckets {
		if len(l.buckets) <= publicStatsRateMaxBuckets {
			return
		}
		if bucket.lastSeen.Before(cutoff) {
			delete(l.buckets, key)
		}
	}
	for len(l.buckets) > publicStatsRateMaxBuckets {
		l.evictOldestLocked()
	}
}

func (l *publicStatsRateLimiter) evictOldestLocked() {
	var oldestKey string
	var oldestSeen time.Time
	for key, bucket := range l.buckets {
		if oldestKey == "" || bucket.lastSeen.Before(oldestSeen) {
			oldestKey = key
			oldestSeen = bucket.lastSeen
		}
	}
	delete(l.buckets, oldestKey)
}
