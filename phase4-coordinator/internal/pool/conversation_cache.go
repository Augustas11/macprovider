package pool

import "time"

// ConversationCacheTelemetry is observe-only, cumulative provider process data.
// It conveys no admission, billing, or buyer-facing cache guarantee.
type ConversationCacheTelemetry struct {
	ProcessID string                   `json:"process_id"`
	Models    []ConversationCacheModel `json:"models"`
}

type ConversationCacheModel struct {
	ModelID            string            `json:"model_id"`
	Lookups            uint64            `json:"lookups"`
	Hits               uint64            `json:"hits"`
	CachedPromptTokens uint64            `json:"cached_prompt_tokens"`
	Misses             map[string]uint64 `json:"misses"`
	Evictions          map[string]uint64 `json:"evictions"`
	ColdSnapshotSkips  uint64            `json:"cold_snapshot_skips"`
	DiskHits           uint64            `json:"disk_hits"`
	DiskWrites         uint64            `json:"disk_writes"`
	Entries            uint64            `json:"entries"`
	Tokens             uint64            `json:"tokens"`
	Bytes              uint64            `json:"bytes"`
	HotByteLimit       uint64            `json:"hot_byte_limit"`
}

// ConversationCacheObservation uses coordinator receipt time, never provider
// wall time. History is volatile, bounded to 24 hours at minute resolution,
// and includes the latest heartbeat. Missing coverage is not a zero rate.
type ConversationCacheObservation struct {
	ObservedAt time.Time `json:"observed_at"`
	ConversationCacheTelemetry
	estimatedBytes int
}

const conversationCacheHistoryLimit = 1441

func (c *ConversationCacheTelemetry) Valid() bool {
	if c == nil || len(c.ProcessID) == 0 || len(c.ProcessID) > 128 || len(c.Models) > 256 {
		return false
	}
	seen := make(map[string]bool, len(c.Models))
	for _, m := range c.Models {
		if m.ModelID == "" || len(m.ModelID) > maxModelIDByteLen || seen[m.ModelID] || m.Hits > m.Lookups || len(m.Misses) > 16 || len(m.Evictions) > 16 {
			return false
		}
		seen[m.ModelID] = true
		for _, reasons := range []map[string]uint64{m.Misses, m.Evictions} {
			for reason := range reasons {
				if reason == "" || len(reason) > 64 {
					return false
				}
			}
		}
	}
	return true
}

func cloneCacheReasons(in map[string]uint64) map[string]uint64 {
	out := make(map[string]uint64, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func cloneCacheObservation(in ConversationCacheObservation) ConversationCacheObservation {
	in.Models = append([]ConversationCacheModel(nil), in.Models...)
	for i := range in.Models {
		in.Models[i].Misses = cloneCacheReasons(in.Models[i].Misses)
		in.Models[i].Evictions = cloneCacheReasons(in.Models[i].Evictions)
	}
	return in
}

// Called under Registry.mu. Published observations and history slices are
// immutable, so Registry snapshots may safely copy their pointers.
func (p *Provider) recordConversationCache(c *ConversationCacheTelemetry, at time.Time) {
	if !c.Valid() {
		return
	}
	current := cloneCacheObservation(ConversationCacheObservation{ObservedAt: at.UTC(), ConversationCacheTelemetry: *c})
	current.estimatedBytes = cacheObservationSize(current)
	p.conversationCache = &current
	h := p.conversationCacheHistory
	if len(h) > 0 && at.Before(h[len(h)-1].ObservedAt.Add(time.Minute)) && h[len(h)-1].ProcessID == c.ProcessID {
		return
	}
	first := 0
	bytes := current.estimatedBytes
	for _, sample := range h {
		bytes += sample.estimatedBytes
	}
	for first < len(h) && (at.Sub(h[first].ObservedAt) > 24*time.Hour || len(h)-first >= conversationCacheHistoryLimit || bytes > 8*1024*1024) {
		bytes -= h[first].estimatedBytes
		first++
	}
	next := make([]ConversationCacheObservation, len(h)-first, len(h)-first+1)
	copy(next, h[first:])
	p.conversationCacheHistory = append(next, current)
}

// ConversationCacheObservations projects immutable pool data for operator
// handlers. Returned maps/slices are independent of the registry's storage.
func (p Provider) ConversationCacheObservations() (*ConversationCacheObservation, []ConversationCacheObservation) {
	if p.conversationCache == nil {
		return nil, nil
	}
	latest := cloneCacheObservation(*p.conversationCache)
	history := make([]ConversationCacheObservation, 0, len(p.conversationCacheHistory)+1)
	for _, sample := range p.conversationCacheHistory {
		history = append(history, cloneCacheObservation(sample))
	}
	if len(history) == 0 || !history[len(history)-1].ObservedAt.Equal(latest.ObservedAt) {
		history = append(history, cloneCacheObservation(latest))
	}
	return &latest, history
}

// ConversationCacheObservation returns only the latest sample, for normal
// operator views that do not request the larger history projection.
func (p Provider) ConversationCacheObservation() *ConversationCacheObservation {
	if p.conversationCache == nil {
		return nil
	}
	latest := cloneCacheObservation(*p.conversationCache)
	return &latest
}

// Retention survives provider session removal, but not coordinator restart.
// Both key churn and total snapshots are bounded, independent of live pool size.
type retainedConversationCache struct {
	latest  *ConversationCacheObservation
	history []ConversationCacheObservation
}

const retainedCacheProviders = 128
const retainedCacheSamples = 8192

// Registry.mu is held by the heartbeat mutation.
func (r *Registry) retainConversationCacheLocked(p *Provider, at time.Time) {
	if r.conversationCaches == nil {
		r.conversationCaches = make(map[string]retainedConversationCache)
	}
	r.conversationCaches[p.ProviderID] = retainedConversationCache{p.conversationCache, p.conversationCacheHistory}
	samples := 0
	bytes := 0
	for id, c := range r.conversationCaches {
		if at.Sub(c.latest.ObservedAt) > 24*time.Hour {
			delete(r.conversationCaches, id)
			continue
		}
		samples += len(c.history) + 1
		bytes += c.latest.estimatedBytes
		for _, sample := range c.history {
			bytes += sample.estimatedBytes
		}
	}
	for len(r.conversationCaches) > retainedCacheProviders || samples > retainedCacheSamples || bytes > 64*1024*1024 {
		oldestID := ""
		var oldest time.Time
		for id, c := range r.conversationCaches {
			if oldestID == "" || c.latest.ObservedAt.Before(oldest) || c.latest.ObservedAt.Equal(oldest) && id < oldestID {
				oldestID = id
				oldest = c.latest.ObservedAt
			}
		}
		if oldestID == "" {
			break
		}
		evicted := r.conversationCaches[oldestID]
		samples -= len(evicted.history) + 1
		bytes -= evicted.latest.estimatedBytes
		for _, sample := range evicted.history {
			bytes -= sample.estimatedBytes
		}
		delete(r.conversationCaches, oldestID)
	}
}

// RetainedConversationCache supplies operator-only views, including offline
// providers. Immutable snapshots allow deep copying after the read lock ends.
func (r *Registry) RetainedConversationCache(providerID string, at time.Time, includeHistory bool) (*ConversationCacheObservation, []ConversationCacheObservation) {
	r.mu.RLock()
	retained, ok := r.conversationCaches[providerID]
	r.mu.RUnlock()
	if !ok || retained.latest == nil || at.Sub(retained.latest.ObservedAt) > 24*time.Hour {
		return nil, nil
	}
	p := Provider{conversationCache: retained.latest, conversationCacheHistory: retained.history}
	if includeHistory {
		return p.ConversationCacheObservations()
	}
	return p.ConversationCacheObservation(), nil
}

// Conservative budget for Go structs, maps, strings and slice storage. This
// keeps high-cardinality histories bounded as well as bounding snapshot count.
func cacheObservationSize(c ConversationCacheObservation) int {
	n := 256 + len(c.ProcessID)
	for _, m := range c.Models {
		n += 512 + len(m.ModelID)
		for _, reasons := range []map[string]uint64{m.Misses, m.Evictions} {
			for reason := range reasons {
				n += 128 + len(reason)
			}
		}
	}
	return n
}
