package rewards

import (
	"sync"
	"time"
)

const rewardAuditLimiterTTL = 15 * time.Minute

// RewardAuditLimiter bounds provider-scoped audit reads before they reach
// PostgreSQL. Nginx handles unauthenticated IP floods; this guards the
// authenticated provider dimension inside the coordinator process.
type RewardAuditLimiter struct {
	mu             sync.Mutex
	perMinute      int
	maxConcurrency int
	buckets        map[string]*rewardAuditBucket
}

type rewardAuditBucket struct {
	windowMinute int64
	count        int
	inflight     int
	lastSeen     time.Time
}

func NewRewardAuditLimiter(perMinute, maxConcurrency int) *RewardAuditLimiter {
	if perMinute <= 0 {
		perMinute = 60
	}
	if maxConcurrency <= 0 {
		maxConcurrency = 4
	}
	return &RewardAuditLimiter{
		perMinute:      perMinute,
		maxConcurrency: maxConcurrency,
		buckets:        make(map[string]*rewardAuditBucket),
	}
}

func (l *RewardAuditLimiter) Allow(providerID string, now time.Time) (func(), bool) {
	if l == nil || providerID == "" {
		return func() {}, true
	}
	now = now.UTC()
	min := now.Unix() / 60
	l.mu.Lock()
	defer l.mu.Unlock()
	l.sweepLocked(now)
	b := l.buckets[providerID]
	if b == nil {
		b = &rewardAuditBucket{windowMinute: min, lastSeen: now}
		l.buckets[providerID] = b
	}
	if b.windowMinute != min {
		b.windowMinute = min
		b.count = 0
	}
	b.lastSeen = now
	if b.count >= l.perMinute || b.inflight >= l.maxConcurrency {
		return nil, false
	}
	b.count++
	b.inflight++
	return func() { l.release(providerID) }, true
}

func (l *RewardAuditLimiter) release(providerID string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if b := l.buckets[providerID]; b != nil && b.inflight > 0 {
		b.inflight--
	}
}

func (l *RewardAuditLimiter) sweepLocked(now time.Time) {
	cutoff := now.Add(-rewardAuditLimiterTTL)
	for providerID, b := range l.buckets {
		if b.inflight == 0 && b.lastSeen.Before(cutoff) {
			delete(l.buckets, providerID)
		}
	}
}
