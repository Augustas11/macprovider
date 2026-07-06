package buyer

import (
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const (
	streamingModeIncremental               = "incremental"
	streamingModeBufferedKillSwitch        = "buffered_kill_switch"
	streamingModeBufferedProviderDowngrade = "buffered_provider_downgrade"
	streamingModeHeader                    = "X-MacProvider-Streaming-Mode"
)

type streamingDowngradeStore struct {
	mu         sync.Mutex
	entries    map[string]streamingDowngradeEntry
	order      []string
	maxEntries int
	evictions  int64
}

type streamingDowngradeEntry struct {
	malformed      []time.Time
	downgradeUntil time.Time
}

func newStreamingDowngradeStore() *streamingDowngradeStore {
	return newStreamingDowngradeStoreWithLimit(defaultStreamingMetricMaxSamples)
}

func newStreamingDowngradeStoreWithLimit(maxEntries int) *streamingDowngradeStore {
	if maxEntries <= 0 {
		maxEntries = defaultStreamingMetricMaxSamples
	}
	return &streamingDowngradeStore{
		entries:    map[string]streamingDowngradeEntry{},
		maxEntries: maxEntries,
	}
}

func (s *streamingDowngradeStore) isDowngraded(buyerID, providerID string, now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := buyerID + "\x00" + providerID
	entry := s.entries[key]
	if entry.downgradeUntil.After(now) {
		return true
	}
	if !entry.downgradeUntil.IsZero() || len(entry.malformed) > 0 {
		entry.downgradeUntil = time.Time{}
		entry.malformed = pruneMalformed(entry.malformed, now)
		if len(entry.malformed) == 0 {
			s.deleteLocked(key)
		} else {
			s.entries[key] = entry
		}
	}
	return false
}

func (s *streamingDowngradeStore) recordMalformed(buyerID, providerID string, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := buyerID + "\x00" + providerID
	entry := s.entries[key]
	entry.malformed = append(pruneMalformed(entry.malformed, now), now)
	if len(entry.malformed) >= 3 {
		entry.downgradeUntil = now.Add(10 * time.Minute)
	}
	s.entries[key] = entry
	s.rememberLocked(key)
}

func (s *streamingDowngradeStore) recordClean(buyerID, providerID string, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := buyerID + "\x00" + providerID
	entry := s.entries[key]
	if entry.downgradeUntil.IsZero() {
		return
	}
	if now.Sub(entry.downgradeUntil.Add(-10*time.Minute)) >= 10*time.Minute {
		s.deleteLocked(key)
	}
}

func (s *streamingDowngradeStore) rememberLocked(key string) {
	if _, ok := s.entries[key]; !ok {
		return
	}
	for _, existing := range s.order {
		if existing == key {
			return
		}
	}
	s.order = append(s.order, key)
	for len(s.entries) > s.maxEntries && len(s.order) > 0 {
		victim := s.order[0]
		s.order = s.order[1:]
		if _, ok := s.entries[victim]; ok {
			delete(s.entries, victim)
			s.evictions++
		}
	}
}

func (s *streamingDowngradeStore) deleteLocked(key string) {
	delete(s.entries, key)
	for i, existing := range s.order {
		if existing == key {
			copy(s.order[i:], s.order[i+1:])
			s.order = s.order[:len(s.order)-1]
			return
		}
	}
}

func (s *streamingDowngradeStore) sizeForTest() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.entries)
}

func (s *streamingDowngradeStore) orderSizeForTest() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.order)
}

func (s *streamingDowngradeStore) evictionsForTest() int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.evictions
}

func pruneMalformed(values []time.Time, now time.Time) []time.Time {
	cutoff := now.Add(-5 * time.Minute)
	out := values[:0]
	for _, ts := range values {
		if !ts.Before(cutoff) {
			out = append(out, ts)
		}
	}
	return out
}

func (s *Server) streamingMode(r *http.Request, provider pool.Provider) string {
	if os.Getenv("COORDINATOR_STREAMING_FORCE_BUFFERED") == "1" {
		return streamingModeBufferedKillSwitch
	}
	if s.streamingDowngrade != nil && s.streamingDowngrade.isDowngraded(s.streamingBuyerKey(r), provider.ProviderID, s.now()) {
		return streamingModeBufferedProviderDowngrade
	}
	return streamingModeIncremental
}

func (s *Server) streamingBuyerKey(r *http.Request) string {
	if account := r.Header.Get("X-MacProvider-Account"); account != "" {
		return "account:" + account
	}
	return "ip:" + s.poolCheckClientKey(r)
}
