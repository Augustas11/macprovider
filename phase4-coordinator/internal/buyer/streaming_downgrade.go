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
	mu      sync.Mutex
	entries map[string]streamingDowngradeEntry
}

type streamingDowngradeEntry struct {
	malformed      []time.Time
	downgradeUntil time.Time
}

func newStreamingDowngradeStore() *streamingDowngradeStore {
	return &streamingDowngradeStore{entries: map[string]streamingDowngradeEntry{}}
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
			delete(s.entries, key)
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
		delete(s.entries, key)
	}
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
