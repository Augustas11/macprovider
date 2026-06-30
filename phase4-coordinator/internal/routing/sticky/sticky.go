// Package sticky implements SPEC-004 §FR-SR-2 through §FR-SR-6
// sticky-affinity storage: in-memory keyed by gateway-authenticated
// `routing_internal.conversation_key`, TTL + LRU bounded eviction
// under a single mutex, with account-scoped purge (SPEC-006
// `DELETE /v1/sticky` contract).
//
// Phase A extraction: this package is the canonical home; the
// existing inline sticky helpers in internal/buyer/server.go will
// delegate to Map.Lookup / Map.Update / Map.PurgeAccount.
//
// SECURITY / DoS boundary (Phase A, BUILD prompt §Phase A): the
// `MaxEntries` cap is NOT cache hygiene; it is a release-blocker
// boundary. Unbounded growth or buggy eviction is HIGH severity.
// All five lifecycle operations FR-SR-5 paragraph 2 enumerates
// (read, write, last_used_at update, TTL expiry, LRU eviction)
// run under the SAME mutex; PurgeAccount and InvalidateClass also
// take it.
//
// Caller-supplied accountID is hard-pinned to the gateway-
// authenticated `X-MacProvider-Account` header per SPEC-006; this
// package treats it as an opaque string and does NOT validate
// authentication itself. Buyer-side code MUST verify the gateway
// auth-frame before calling Update with an accountID — see the
// PR #260 BUILD prompt's Pillar A gate tests for the boundary.
package sticky

import (
	"sync"
	"time"
)

// Entry captures one sticky-affinity record.
type Entry struct {
	ConversationKey string
	ProviderID      string
	AccountID       string
	ModelScope      string
	CreatedAt       time.Time
	LastUsedAt      time.Time
}

// Map is the bounded TTL + LRU sticky-affinity store. Zero-value
// Map is not usable — construct via NewMap.
type Map struct {
	mu         sync.Mutex
	entries    map[string]Entry
	ttl        time.Duration
	maxEntries int
	// now is injectable for tests; production callers pass time.Now
	// at construction.
	now func() time.Time
}

// Options configures a new Map. TTL and MaxEntries MUST be positive
// per SPEC-004 §5 validation (the buyer's config loader enforces
// this; NewMap does not re-validate but a zero TTL would make every
// Lookup a miss and a zero MaxEntries would evict on every Update).
type Options struct {
	TTL        time.Duration
	MaxEntries int
	Now        func() time.Time // if nil, defaults to time.Now
}

// NewMap returns a Map ready for concurrent use.
func NewMap(opts Options) *Map {
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	return &Map{
		entries:    make(map[string]Entry, opts.MaxEntries),
		ttl:        opts.TTL,
		maxEntries: opts.MaxEntries,
		now:        now,
	}
}

// LookupResult names the miss reasons FR-SR-3 enumerates. Hit
// returns ("", true); miss returns (reason, false).
type LookupResult struct {
	Entry      Entry
	Hit        bool
	MissReason string // "not_found" / "expired" — empty when Hit
}

// Lookup returns the Entry for conversationKey, refreshing its
// LastUsedAt on hit so LRU tracking reflects active use per FR-SR-5
// paragraph 2 ("last_used_at update").
func (m *Map) Lookup(conversationKey string) LookupResult {
	m.mu.Lock()
	defer m.mu.Unlock()
	entry, ok := m.entries[conversationKey]
	if !ok {
		return LookupResult{MissReason: "not_found"}
	}
	now := m.now()
	if now.Sub(entry.LastUsedAt) > m.ttl {
		delete(m.entries, conversationKey)
		return LookupResult{MissReason: "expired"}
	}
	entry.LastUsedAt = now
	m.entries[conversationKey] = entry
	return LookupResult{Entry: entry, Hit: true}
}

// Update inserts or refreshes the entry for conversationKey,
// performing TTL-then-LRU eviction if the map is at MaxEntries.
//
// accountID MUST come from the gateway-authenticated
// `X-MacProvider-Account` header; passing an unauthenticated
// header value here would let a hostile buyer pin themselves to a
// provider's sticky slot. The buyer-side call site is responsible
// for that check; this method treats accountID as an opaque
// attribution field that PurgeAccount uses for SPEC-006
// `DELETE /v1/sticky` matching.
func (m *Map) Update(conversationKey, accountID, providerID, modelScope string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	// Refresh path FIRST: if the conversationKey already exists, we
	// are not growing the map and MUST NOT evict an unrelated entry.
	// This also preserves CreatedAt per FR-SR-6 before any eviction
	// loop could accidentally drop the entry being refreshed.
	if existing, ok := m.entries[conversationKey]; ok {
		m.entries[conversationKey] = Entry{
			ConversationKey: conversationKey,
			ProviderID:      providerID,
			AccountID:       accountID,
			ModelScope:      modelScope,
			CreatedAt:       existing.CreatedAt,
			LastUsedAt:      now,
		}
		return
	}
	// Insert path: cap-eviction only when adding a NEW key would
	// push len past maxEntries.
	if len(m.entries) >= m.maxEntries {
		// Pass 1: drop TTL-expired entries (cheap and may free a slot).
		var oldestKey string
		var oldest time.Time
		for k, entry := range m.entries {
			if now.Sub(entry.LastUsedAt) > m.ttl {
				delete(m.entries, k)
				continue
			}
			if oldestKey == "" || entry.LastUsedAt.Before(oldest) {
				oldestKey = k
				oldest = entry.LastUsedAt
			}
		}
		// Pass 2: if still at cap, LRU-evict the oldest survivor.
		if len(m.entries) >= m.maxEntries && oldestKey != "" {
			delete(m.entries, oldestKey)
		}
	}
	m.entries[conversationKey] = Entry{
		ConversationKey: conversationKey,
		ProviderID:      providerID,
		AccountID:       accountID,
		ModelScope:      modelScope,
		CreatedAt:       now,
		LastUsedAt:      now,
	}
}

// PurgeAccount removes every entry attributable to accountID and
// returns the count removed. Underlying primitive for SPEC-006
// `DELETE /v1/sticky` ("MUST purge all sticky entries attributable
// to the caller's account_id"). Buyer-side handler is responsible
// for authenticating the caller's account_id before invoking this.
func (m *Map) PurgeAccount(accountID string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	removed := 0
	for key, entry := range m.entries {
		if entry.AccountID == accountID {
			delete(m.entries, key)
			removed++
		}
	}
	return removed
}

// InvalidateClass purges every entry whose ModelScope matches the
// given class name. SPEC-004 FR-SR-5 paragraph 2 names "invalidate
// on class reconfig" as a required operation; this is the primitive
// the buyer-side SIGHUP-driven config-reload path will call when
// `routing.model_classes` changes shape.
//
// Phase A ships the primitive; the SIGHUP-trigger wiring lands in
// a subsequent commit when the config-reload path is plumbed to
// detect class changes (out of Phase A scope per BUILD prompt
// §Phase A files-touched list).
func (m *Map) InvalidateClass(className string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	removed := 0
	for key, entry := range m.entries {
		if entry.ModelScope == className {
			delete(m.entries, key)
			removed++
		}
	}
	return removed
}

// Len returns the current entry count. Test-only / observability.
func (m *Map) Len() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.entries)
}
