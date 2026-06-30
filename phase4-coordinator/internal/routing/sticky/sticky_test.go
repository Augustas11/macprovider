package sticky_test

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/routing/sticky"
)

// fakeClock is monotonic + test-controlled; SPEC-004 §FR-SR-5
// TTL/LRU assertions need deterministic time.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 6, 30, 12, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func newTestMap(ttl time.Duration, maxEntries int, clock *fakeClock) *sticky.Map {
	return sticky.NewMap(sticky.Options{TTL: ttl, MaxEntries: maxEntries, Now: clock.Now})
}

func TestMap_LookupNotFoundReturnsExpectedMissReason(t *testing.T) {
	t.Parallel()
	m := newTestMap(time.Minute, 10, newClock())
	res := m.Lookup("conv:absent")
	if res.Hit {
		t.Fatalf("absent key: want miss")
	}
	if res.MissReason != "not_found" {
		t.Errorf("missReason: want not_found, got %q", res.MissReason)
	}
}

func TestMap_UpdateThenLookupHits(t *testing.T) {
	t.Parallel()
	clock := newClock()
	m := newTestMap(time.Minute, 10, clock)
	m.Update("conv:abc", "acc-1", "prov-1", "model-A")
	res := m.Lookup("conv:abc")
	if !res.Hit {
		t.Fatalf("post-Update Lookup: want hit, got miss=%q", res.MissReason)
	}
	if res.Entry.ProviderID != "prov-1" || res.Entry.AccountID != "acc-1" || res.Entry.ModelScope != "model-A" {
		t.Errorf("entry fields: got %+v", res.Entry)
	}
}

func TestMap_TTLExpiryEvictsOnNextLookup(t *testing.T) {
	t.Parallel()
	clock := newClock()
	m := newTestMap(30*time.Second, 10, clock)
	m.Update("conv:abc", "acc-1", "prov-1", "model-A")
	clock.Advance(31 * time.Second)
	res := m.Lookup("conv:abc")
	if res.Hit {
		t.Fatalf("post-TTL Lookup: want miss")
	}
	if res.MissReason != "expired" {
		t.Errorf("missReason: want expired, got %q", res.MissReason)
	}
	if m.Len() != 0 {
		t.Errorf("expired entry should be evicted; Len=%d", m.Len())
	}
}

func TestMap_LookupRefreshesLastUsedAtSoLRUTracksUse(t *testing.T) {
	t.Parallel()
	clock := newClock()
	m := newTestMap(time.Hour, 10, clock)
	m.Update("conv:abc", "acc-1", "prov-1", "model-A")
	clock.Advance(10 * time.Minute)
	m.Lookup("conv:abc") // touches LastUsedAt → now()
	clock.Advance(50 * time.Minute)
	// Total elapsed since Update = 60 min; since Lookup = 50 min < 60 min TTL.
	res := m.Lookup("conv:abc")
	if !res.Hit {
		t.Fatalf("Lookup-refresh should keep entry within TTL; got miss=%q", res.MissReason)
	}
}

func TestMap_BoundedMapEvictsLRUWhenAtCap(t *testing.T) {
	// SECURITY/DoS boundary: insert N+1 distinct keys with N=MaxEntries,
	// assert the OLDEST entry is evicted (LRU) — never grow past N.
	t.Parallel()
	clock := newClock()
	m := newTestMap(time.Hour, 3, clock)
	m.Update("conv:1", "acc", "prov-1", "model-A")
	clock.Advance(time.Second)
	m.Update("conv:2", "acc", "prov-2", "model-A")
	clock.Advance(time.Second)
	m.Update("conv:3", "acc", "prov-3", "model-A")
	clock.Advance(time.Second)
	// At cap; next Update evicts conv:1 (oldest LastUsedAt).
	m.Update("conv:4", "acc", "prov-4", "model-A")
	if m.Len() != 3 {
		t.Fatalf("Len after N+1 inserts: want 3 (cap), got %d", m.Len())
	}
	if r := m.Lookup("conv:1"); r.Hit {
		t.Errorf("conv:1 (oldest) MUST be LRU-evicted")
	}
	for _, k := range []string{"conv:2", "conv:3", "conv:4"} {
		if r := m.Lookup(k); !r.Hit {
			t.Errorf("%s should still be in map; missReason=%q", k, r.MissReason)
		}
	}
}

func TestMap_BoundedMapDropsExpiredBeforeLRU(t *testing.T) {
	// When at cap and an Update fires, expired entries get dropped
	// in pass 1; LRU eviction in pass 2 only runs if still over cap.
	t.Parallel()
	clock := newClock()
	m := newTestMap(time.Minute, 3, clock)
	m.Update("conv:1", "acc", "prov-1", "model-A")
	m.Update("conv:2", "acc", "prov-2", "model-A")
	m.Update("conv:3", "acc", "prov-3", "model-A")
	// All three expire.
	clock.Advance(2 * time.Minute)
	// Next Update: pass 1 evicts all three expired, then inserts.
	m.Update("conv:new", "acc", "prov-new", "model-A")
	if m.Len() != 1 {
		t.Fatalf("Len after all-expired + 1 new: want 1, got %d", m.Len())
	}
	if r := m.Lookup("conv:new"); !r.Hit {
		t.Errorf("conv:new should be present after TTL-driven eviction; missReason=%q", r.MissReason)
	}
}

func TestMap_PurgeAccountRemovesOnlyMatchingAccountEntries(t *testing.T) {
	// SPEC-006 DELETE /v1/sticky contract: purge MUST scope to the
	// caller's account_id only. A purge for account-A MUST NOT
	// touch account-B's entries.
	t.Parallel()
	m := newTestMap(time.Hour, 10, newClock())
	m.Update("conv:a1", "acc-A", "prov-1", "model-A")
	m.Update("conv:a2", "acc-A", "prov-2", "model-A")
	m.Update("conv:b1", "acc-B", "prov-3", "model-A")
	removed := m.PurgeAccount("acc-A")
	if removed != 2 {
		t.Errorf("PurgeAccount(acc-A): want 2 removed, got %d", removed)
	}
	if r := m.Lookup("conv:b1"); !r.Hit {
		t.Errorf("acc-B's entry MUST survive account-A purge; missReason=%q", r.MissReason)
	}
	for _, k := range []string{"conv:a1", "conv:a2"} {
		if r := m.Lookup(k); r.Hit {
			t.Errorf("%s should be purged", k)
		}
	}
}

func TestMap_PurgeAccountUnknownAccountReturnsZero(t *testing.T) {
	t.Parallel()
	m := newTestMap(time.Hour, 10, newClock())
	m.Update("conv:1", "acc-A", "prov-1", "model-A")
	if removed := m.PurgeAccount("acc-NONEXISTENT"); removed != 0 {
		t.Errorf("PurgeAccount unknown: want 0, got %d", removed)
	}
}

func TestMap_PurgeAccountEmptyAccountReturnsZero(t *testing.T) {
	// Defense-in-depth: PurgeAccount("") MUST NOT wipe entries with
	// empty AccountID. The buyer-side handler guards on accountID != ""
	// before invoking, but the primitive's own guard prevents a
	// future caller from silently wiping the map. Adversarial / FULL-
	// IMPL R1 finding M7.
	t.Parallel()
	m := newTestMap(time.Hour, 10, newClock())
	// Force-write entries with empty AccountID via direct Update
	// (simulates legacy entries pre-X-MacProvider-Account-required).
	m.Update("conv:1", "", "prov-1", "model-A")
	m.Update("conv:2", "", "prov-2", "model-A")
	if removed := m.PurgeAccount(""); removed != 0 {
		t.Errorf("PurgeAccount(empty): want 0 (defense-in-depth), got %d", removed)
	}
	if m.Len() != 2 {
		t.Errorf("entries with empty AccountID MUST survive PurgeAccount(empty); Len=%d", m.Len())
	}
}

func TestMap_UpdateRejectsAccountIDMismatchOnRefresh(t *testing.T) {
	// Adversarial / FULL-IMPL R1 finding M5: pre-fix, sticky.Map.Update
	// silently overwrote AccountID on refresh, opening a cross-account
	// attribution corruption vector. Post-fix: refresh with mismatched
	// accountID returns mismatch=true AND leaves the existing entry
	// intact.
	t.Parallel()
	m := newTestMap(time.Hour, 10, newClock())
	if mismatch := m.Update("conv:1", "acc-A", "prov-1", "model-A"); mismatch {
		t.Fatalf("initial Update: want mismatch=false, got true")
	}
	// Hostile attempt: same conv key, different accountID.
	if mismatch := m.Update("conv:1", "acc-ATTACKER", "prov-2", "model-A"); !mismatch {
		t.Fatalf("refresh-with-different-accountID: want mismatch=true, got false")
	}
	// Verify the existing entry was NOT clobbered.
	res := m.Lookup("conv:1")
	if !res.Hit {
		t.Fatalf("entry should remain after mismatch refusal; got missReason=%q", res.MissReason)
	}
	if res.Entry.AccountID != "acc-A" {
		t.Errorf("AccountID MUST be preserved (acc-A); got %q", res.Entry.AccountID)
	}
	if res.Entry.ProviderID != "prov-1" {
		t.Errorf("ProviderID MUST be preserved (prov-1); got %q", res.Entry.ProviderID)
	}
}

func TestMap_UpdateAllowsRefreshWhenExistingAccountIDIsEmpty(t *testing.T) {
	// Refresh from empty AccountID to a real AccountID is allowed
	// (legacy entry being upgraded). The mismatch guard only fires
	// when BOTH sides are non-empty AND differ.
	t.Parallel()
	m := newTestMap(time.Hour, 10, newClock())
	m.Update("conv:1", "", "prov-1", "model-A")
	if mismatch := m.Update("conv:1", "acc-A", "prov-1", "model-A"); mismatch {
		t.Fatalf("refresh from empty AccountID: want mismatch=false (upgrade allowed), got true")
	}
	res := m.Lookup("conv:1")
	if res.Entry.AccountID != "acc-A" {
		t.Errorf("AccountID should be upgraded to acc-A; got %q", res.Entry.AccountID)
	}
}

func TestMap_InvalidateClassRemovesOnlyMatchingModelScope(t *testing.T) {
	t.Parallel()
	m := newTestMap(time.Hour, 10, newClock())
	m.Update("conv:1", "acc", "prov-1", "fast-class")
	m.Update("conv:2", "acc", "prov-2", "accurate-class")
	m.Update("conv:3", "acc", "prov-3", "fast-class")
	removed := m.InvalidateClass("fast-class")
	if removed != 2 {
		t.Errorf("InvalidateClass(fast-class): want 2 removed, got %d", removed)
	}
	if r := m.Lookup("conv:2"); !r.Hit {
		t.Errorf("accurate-class entry MUST survive fast-class invalidation")
	}
}

func TestMap_ConcurrentMixedOperationsNoRaceNoOvergrow(t *testing.T) {
	// SECURITY/DoS boundary regression: N goroutines hammering
	// Lookup / Update / PurgeAccount simultaneously MUST NOT panic,
	// MUST NOT exceed MaxEntries, and MUST NOT corrupt the map.
	// This is the "all five operations under one mutex" assertion
	// from BUILD prompt §Phase A.
	t.Parallel()
	const maxEntries = 50
	const goroutines = 32
	const opsPerGoroutine = 200
	m := newTestMap(time.Hour, maxEntries, newClock())
	var wg sync.WaitGroup
	var maxObserved int64
	for g := 0; g < goroutines; g++ {
		g := g
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < opsPerGoroutine; i++ {
				switch i % 4 {
				case 0:
					m.Update(fmt.Sprintf("conv:%d-%d", g, i), fmt.Sprintf("acc-%d", g%4), fmt.Sprintf("prov-%d", i%5), "model-A")
				case 1:
					m.Lookup(fmt.Sprintf("conv:%d-%d", g, i-1))
				case 2:
					m.PurgeAccount(fmt.Sprintf("acc-%d", g%4))
				case 3:
					m.InvalidateClass("model-A")
				}
				cur := int64(m.Len())
				for {
					prev := atomic.LoadInt64(&maxObserved)
					if cur <= prev || atomic.CompareAndSwapInt64(&maxObserved, prev, cur) {
						break
					}
				}
			}
		}()
	}
	wg.Wait()
	if observed := atomic.LoadInt64(&maxObserved); observed > maxEntries {
		t.Fatalf("Len exceeded MaxEntries cap during concurrent ops: observed %d, cap %d", observed, maxEntries)
	}
	if m.Len() > maxEntries {
		t.Errorf("post-race Len > cap: %d > %d", m.Len(), maxEntries)
	}
}

func TestMap_RefreshAtCapDoesNotEvictUnrelatedEntries(t *testing.T) {
	// Regression for the D+A R1 ARCH-M1 bug: when refreshing an
	// existing conversationKey at MaxEntries, the eviction loop
	// MUST NOT fire — the map size is unchanged. Pre-fix, an at-cap
	// refresh could drop an unrelated LRU entry.
	t.Parallel()
	clock := newClock()
	m := newTestMap(time.Hour, 2, clock)
	m.Update("conv:1", "acc", "prov-1", "model-A") // LRU
	clock.Advance(time.Second)
	m.Update("conv:2", "acc", "prov-2", "model-A")
	clock.Advance(time.Second)
	// Refresh conv:2 (already present at cap). conv:1 (LRU) MUST survive.
	m.Update("conv:2", "acc", "prov-2-refreshed", "model-A")
	if r := m.Lookup("conv:1"); !r.Hit {
		t.Fatalf("conv:1 (LRU) MUST survive refresh of conv:2 at cap; missReason=%q", r.MissReason)
	}
	if r := m.Lookup("conv:2"); !r.Hit || r.Entry.ProviderID != "prov-2-refreshed" {
		t.Fatalf("conv:2 refresh: want hit + new ProviderID, got %+v", r)
	}
}

func TestMap_UpdatePreservesCreatedAtOnRefresh(t *testing.T) {
	// CreatedAt MUST be preserved across re-Updates of the same key
	// (refresh-on-success per FR-SR-6); only LastUsedAt advances.
	t.Parallel()
	clock := newClock()
	m := newTestMap(time.Hour, 10, clock)
	m.Update("conv:1", "acc", "prov-1", "model-A")
	originalCreated := m.Lookup("conv:1").Entry.CreatedAt
	clock.Advance(5 * time.Minute)
	m.Update("conv:1", "acc", "prov-1", "model-A")
	entry := m.Lookup("conv:1").Entry
	if !entry.CreatedAt.Equal(originalCreated) {
		t.Errorf("CreatedAt MUST be preserved across refresh: original=%v, now=%v", originalCreated, entry.CreatedAt)
	}
	if !entry.LastUsedAt.After(originalCreated) {
		t.Errorf("LastUsedAt MUST advance on refresh: %v not after %v", entry.LastUsedAt, originalCreated)
	}
}
