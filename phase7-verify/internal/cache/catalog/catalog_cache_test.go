package catalogcache

import (
	"crypto/ed25519"
	"testing"
	"time"
)

// SPEC-015 §M.3.4 — three TTL bands.
func TestComputeTTLBands(t *testing.T) {
	base := time.Date(2026, 6, 24, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		name    string
		remain  time.Duration
		wantTTL time.Duration
	}{
		{"more-than-6h", 7 * time.Hour, 6 * time.Hour},
		{"exactly-6h", 6 * time.Hour, 6*time.Hour - 60*time.Second},
		{"3h", 3 * time.Hour, 3*time.Hour - 60*time.Second},
		{"61s", 61 * time.Second, time.Second},
		{"exactly-60s", 60 * time.Second, 0}, // do NOT cache
		{"30s", 30 * time.Second, 0},
		{"0s", 0, 0},
		{"negative-30s", -30 * time.Second, 0},
		{"negative-2h", -2 * time.Hour, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ComputeTTL(base.Add(tc.remain), base)
			if got != tc.wantTTL {
				t.Fatalf("ComputeTTL(R=%v) = %v, want %v", tc.remain, got, tc.wantTTL)
			}
		})
	}
}

func TestPutAndGetRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s := NewAt(dir)
	now := time.Date(2026, 6, 24, 12, 0, 0, 0, time.UTC)
	expires := now.Add(3 * time.Hour)
	pubkey := pubkeyFixture(t)
	entry, ok, err := s.Put("https://example/catalog/x", []byte(`{"catalog_id":"x"}`), pubkey, expires, now)
	if err != nil || !ok {
		t.Fatalf("Put: err=%v ok=%v", err, ok)
	}
	if entry == nil {
		t.Fatal("entry nil")
	}
	got, hit, err := s.Get("https://example/catalog/x", pubkey, now)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !hit {
		t.Fatal("expected hit")
	}
	if string(got.CatalogBytes) != `{"catalog_id":"x"}` {
		t.Fatalf("bytes = %s", got.CatalogBytes)
	}
}

func TestPutSkipsBelowMinTTL(t *testing.T) {
	dir := t.TempDir()
	s := NewAt(dir)
	now := time.Date(2026, 6, 24, 12, 0, 0, 0, time.UTC)
	_, ok, err := s.Put("u", []byte("{}"), pubkeyFixture(t), now.Add(30*time.Second), now)
	if err != nil {
		t.Fatalf("Put err: %v", err)
	}
	if ok {
		t.Fatal("Put with R=30s should NOT cache (below 60s minimum)")
	}
	// Confirm no file was written.
	_, hit, err := s.Get("u", pubkeyFixture(t), now)
	if err != nil {
		t.Fatalf("Get err: %v", err)
	}
	if hit {
		t.Fatal("Get hit after skipped Put")
	}
}

// SPEC-015 §M.3.4 — pubkey rotation invalidates the cache.
func TestGetMissOnPubkeyRotation(t *testing.T) {
	dir := t.TempDir()
	s := NewAt(dir)
	now := time.Date(2026, 6, 24, 12, 0, 0, 0, time.UTC)
	oldPubkey := pubkeyFixture(t)
	if _, ok, err := s.Put("u", []byte("{}"), oldPubkey, now.Add(time.Hour), now); err != nil || !ok {
		t.Fatalf("Put: err=%v ok=%v", err, ok)
	}
	// Rotate the pubkey — supply a different key.
	newPubkey := EncodePubkeyForCache(make([]byte, ed25519.PublicKeySize))
	_, hit, err := s.Get("u", newPubkey, now)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if hit {
		t.Fatal("Get hit after pubkey rotation (cache must invalidate)")
	}
}

// SPEC-015 §M.3.4 — stale cache entries MUST miss.
func TestGetMissOnStaleEntry(t *testing.T) {
	dir := t.TempDir()
	s := NewAt(dir)
	now := time.Date(2026, 6, 24, 12, 0, 0, 0, time.UTC)
	pubkey := pubkeyFixture(t)
	// Put with TTL of (3h - 60s) ≈ 2h59m.
	if _, ok, err := s.Put("u", []byte("{}"), pubkey, now.Add(3*time.Hour), now); err != nil || !ok {
		t.Fatalf("Put: %v", err)
	}
	// Advance well past the cache TTL.
	later := now.Add(4 * time.Hour)
	_, hit, err := s.Get("u", pubkey, later)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if hit {
		t.Fatal("Get hit on stale entry")
	}
}

func TestDeleteIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	s := NewAt(dir)
	if err := s.Delete("u"); err != nil {
		t.Fatalf("Delete on missing: %v", err)
	}
	now := time.Date(2026, 6, 24, 12, 0, 0, 0, time.UTC)
	if _, _, err := s.Put("u", []byte("{}"), pubkeyFixture(t), now.Add(time.Hour), now); err != nil {
		t.Fatalf("Put: %v", err)
	}
	if err := s.Delete("u"); err != nil {
		t.Fatalf("Delete after Put: %v", err)
	}
	if _, hit, _ := s.Get("u", pubkeyFixture(t), now); hit {
		t.Fatal("Get hit after Delete")
	}
}

func pubkeyFixture(t *testing.T) string {
	t.Helper()
	key := make([]byte, ed25519.PublicKeySize)
	for i := range key {
		key[i] = byte(i + 7)
	}
	return EncodePubkeyForCache(key)
}
