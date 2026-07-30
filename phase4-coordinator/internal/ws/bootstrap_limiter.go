package ws

import (
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

const bootstrapBucketRetention = 2 * time.Hour

type bootstrapBucket struct {
	tokens   float64
	updated  time.Time
	lastSeen time.Time
}

// bootstrapMintLimiter is the cheap, in-memory abuse gate in front of the
// durable SQLite quota. Both the source-IP and provider-id buckets must have a
// token; consumption is atomic under one lock so a rejected provider cannot
// drain only the IP side (or vice versa). SQLite remains authoritative across
// restarts.
type bootstrapMintLimiter struct {
	mu              sync.Mutex
	perIPCapacity   int
	perIDCapacity   int
	ipBuckets       map[string]bootstrapBucket
	providerBuckets map[string]bootstrapBucket
}

func newBootstrapMintLimiter(cfg config.AuthConfig) *bootstrapMintLimiter {
	return &bootstrapMintLimiter{
		perIPCapacity:   cfg.CredentialBootstrapMintsPerIPHour,
		perIDCapacity:   cfg.CredentialBootstrapMintsPerIDHour,
		ipBuckets:       make(map[string]bootstrapBucket),
		providerBuckets: make(map[string]bootstrapBucket),
	}
}

func (l *bootstrapMintLimiter) allow(sourceIP, providerID string, now time.Time) bool {
	if l == nil || sourceIP == "" || providerID == "" || l.perIPCapacity <= 0 || l.perIDCapacity <= 0 {
		return false
	}
	now = now.UTC()
	l.mu.Lock()
	defer l.mu.Unlock()
	l.pruneLocked(now.Add(-bootstrapBucketRetention))
	ip := refillBootstrapBucket(l.ipBuckets[sourceIP], l.perIPCapacity, now)
	provider := refillBootstrapBucket(l.providerBuckets[providerID], l.perIDCapacity, now)
	if ip.tokens < 1 || provider.tokens < 1 {
		l.ipBuckets[sourceIP] = ip
		l.providerBuckets[providerID] = provider
		return false
	}
	ip.tokens--
	provider.tokens--
	l.ipBuckets[sourceIP] = ip
	l.providerBuckets[providerID] = provider
	return true
}

func refillBootstrapBucket(bucket bootstrapBucket, capacity int, now time.Time) bootstrapBucket {
	if bucket.updated.IsZero() {
		return bootstrapBucket{tokens: float64(capacity), updated: now, lastSeen: now}
	}
	elapsed := now.Sub(bucket.updated)
	if elapsed > 0 {
		bucket.tokens += elapsed.Hours() * float64(capacity)
		if bucket.tokens > float64(capacity) {
			bucket.tokens = float64(capacity)
		}
		bucket.updated = now
	}
	bucket.lastSeen = now
	return bucket
}

func (l *bootstrapMintLimiter) pruneLocked(cutoff time.Time) {
	for key, bucket := range l.ipBuckets {
		if bucket.lastSeen.Before(cutoff) {
			delete(l.ipBuckets, key)
		}
	}
	for key, bucket := range l.providerBuckets {
		if bucket.lastSeen.Before(cutoff) {
			delete(l.providerBuckets, key)
		}
	}
}
