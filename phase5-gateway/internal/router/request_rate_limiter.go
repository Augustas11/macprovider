package router

import (
	"math"
	"sync"
	"time"
)

const (
	requestRateMaxBuckets    = 4096
	requestRateBucketTTL     = 5 * time.Minute
	requestRatePruneInterval = time.Minute
)

type requestRateDecision struct {
	Admitted          bool
	Limit             int
	Remaining         int
	RetryAfterSeconds int
}

type requestRateLimiter struct {
	mu         sync.Mutex
	buckets    map[string]*requestRateBucket
	lastPruned time.Time
}

type requestRateBucket struct {
	tokens   float64
	last     time.Time
	lastSeen time.Time
}

func newRequestRateLimiter() *requestRateLimiter {
	return &requestRateLimiter{buckets: make(map[string]*requestRateBucket)}
}

func (l *requestRateLimiter) allow(key string, limit int, now time.Time) requestRateDecision {
	if limit <= 0 || key == "" {
		return requestRateDecision{Admitted: true, Limit: limit}
	}
	l.mu.Lock()
	defer l.mu.Unlock()

	capacity := float64(limit)
	bucket := l.buckets[key]
	if bucket == nil {
		l.pruneForInsertLocked(now)
		bucket = &requestRateBucket{tokens: capacity, last: now}
		l.buckets[key] = bucket
	}
	if elapsed := now.Sub(bucket.last).Seconds(); elapsed > 0 {
		bucket.tokens = math.Min(capacity, bucket.tokens+elapsed*capacity)
		bucket.last = now
	}
	bucket.lastSeen = now

	if bucket.tokens >= 1 {
		bucket.tokens--
		return requestRateDecision{
			Admitted:  true,
			Limit:     limit,
			Remaining: int(math.Floor(bucket.tokens)),
		}
	}

	retryAfter := int(math.Ceil((1 - bucket.tokens) / capacity))
	if retryAfter < 1 {
		retryAfter = 1
	}
	return requestRateDecision{
		Admitted:          false,
		Limit:             limit,
		Remaining:         0,
		RetryAfterSeconds: retryAfter,
	}
}

func (l *requestRateLimiter) pruneForInsertLocked(now time.Time) {
	if len(l.buckets) < requestRateMaxBuckets {
		if !l.lastPruned.IsZero() && now.Sub(l.lastPruned) < requestRatePruneInterval {
			return
		}
		l.pruneExpiredLocked(now)
		return
	}
	l.pruneExpiredLocked(now)
	for len(l.buckets) >= requestRateMaxBuckets {
		l.evictOldestLocked()
	}
}

func (l *requestRateLimiter) pruneExpiredLocked(now time.Time) {
	if !l.lastPruned.IsZero() && now.Sub(l.lastPruned) < requestRatePruneInterval && len(l.buckets) < requestRateMaxBuckets {
		return
	}
	l.lastPruned = now
	cutoff := now.Add(-requestRateBucketTTL)
	for key, bucket := range l.buckets {
		if bucket.lastSeen.Before(cutoff) {
			delete(l.buckets, key)
		}
	}
}

func (l *requestRateLimiter) evictOldestLocked() {
	var oldestKey string
	var oldestSeen time.Time
	for key, bucket := range l.buckets {
		if oldestKey == "" || bucket.lastSeen.Before(oldestSeen) {
			oldestKey = key
			oldestSeen = bucket.lastSeen
		}
	}
	if oldestKey != "" {
		delete(l.buckets, oldestKey)
	}
}
