package cache

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const testCoordinator = "coordinator.streamvc.live"

func TestOpenPutLookupRoundTrip(t *testing.T) {
	c := openTempCache(t)
	pubkey := testKey(1)
	prev := testKey(2)
	rotatedAt := time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
	expiresAt := rotatedAt.Add(TTL)

	err := c.Put(testCoordinator, "m1-anon", ResolverResponse{
		ProviderID:    "m1-anon",
		ReceiptPubkey: pubkey,
		ReceiptPubkeyPrev: &PreviousKeyResponse{
			Pubkey:    prev,
			RotatedAt: rotatedAt,
			ExpiresAt: expiresAt,
		},
	})
	if err != nil {
		t.Fatalf("Put: %v", err)
	}

	got, fresh, err := c.Lookup(testCoordinator, "m1-anon", pubkey)
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if got == nil {
		t.Fatal("Lookup returned nil entry")
	}
	if !fresh {
		t.Fatal("Lookup returned stale entry, want fresh")
	}
	if got.CoordinatorHost != testCoordinator || got.ProviderID != "m1-anon" {
		t.Fatalf("identity mismatch: %#v", got)
	}
	if !bytes.Equal(got.ReceiptPubkey, pubkey) {
		t.Fatalf("pubkey mismatch")
	}
	if got.ReceiptPubkeyPrev == nil || !bytes.Equal(got.ReceiptPubkeyPrev.Pubkey, prev) {
		t.Fatalf("previous key mismatch: %#v", got.ReceiptPubkeyPrev)
	}
	if !got.ReceiptPubkeyPrev.RotatedAt.Equal(rotatedAt) || !got.ReceiptPubkeyPrev.ExpiresAt.Equal(expiresAt) {
		t.Fatalf("previous timestamps mismatch: %#v", got.ReceiptPubkeyPrev)
	}
	if got.FetchedAt.IsZero() || got.FetchedAt.Location() != time.UTC {
		t.Fatalf("FetchedAt not set in UTC: %v", got.FetchedAt)
	}
}

func TestPutAtomicWriteFailureKeepsOldFile(t *testing.T) {
	c := openTempCache(t)
	oldKey := testKey(1)
	newKey := testKey(2)
	if err := c.Put(testCoordinator, "m1-anon", ResolverResponse{ProviderID: "m1-anon", ReceiptPubkey: oldKey}); err != nil {
		t.Fatalf("initial Put: %v", err)
	}
	oldBytes, err := os.ReadFile(c.Path())
	if err != nil {
		t.Fatalf("read old cache: %v", err)
	}

	orig := writeFileAtomic
	writeFileAtomic = func(path string, data []byte, perm os.FileMode) error {
		tmp, err := os.CreateTemp(filepath.Dir(path), ".fault-*")
		if err != nil {
			return err
		}
		defer os.Remove(tmp.Name())
		if _, err := tmp.Write(data[:len(data)/2]); err != nil {
			_ = tmp.Close()
			return err
		}
		_ = tmp.Close()
		return errors.New("simulated crash before rename")
	}
	defer func() { writeFileAtomic = orig }()

	err = c.Put(testCoordinator, "m1-anon", ResolverResponse{ProviderID: "m1-anon", ReceiptPubkey: newKey})
	if err == nil {
		t.Fatal("Put succeeded, want injected failure")
	}
	afterBytes, err := os.ReadFile(c.Path())
	if err != nil {
		t.Fatalf("read cache after failure: %v", err)
	}
	if !bytes.Equal(afterBytes, oldBytes) {
		t.Fatalf("cache file changed after failed atomic write\nold: %s\nafter: %s", oldBytes, afterBytes)
	}
	got, fresh, err := c.Lookup(testCoordinator, "m1-anon", oldKey)
	if err != nil {
		t.Fatalf("Lookup old key: %v", err)
	}
	if got == nil || !fresh {
		t.Fatalf("old key not preserved after failed write: got=%#v fresh=%v", got, fresh)
	}
}

func TestLookupStaleEntry(t *testing.T) {
	c := openTempCache(t)
	pubkey := testKey(3)
	writeDiskEntries(t, c.Path(), diskEntry{
		CoordinatorHost: testCoordinator,
		ProviderID:      "m1-anon",
		ReceiptPubkey:   b64(pubkey),
		FetchedAt:       time.Now().UTC().Add(-8 * 24 * time.Hour).Format(time.RFC3339),
	})

	got, fresh, err := c.Lookup(testCoordinator, "m1-anon", pubkey)
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if got == nil {
		t.Fatal("Lookup returned nil, want stale entry")
	}
	if fresh {
		t.Fatal("Lookup returned fresh=true for 8-day-old entry")
	}
}

func TestLookupByProviderIDReturnsMultipleRotatedEntries(t *testing.T) {
	c := openTempCache(t)
	oldKey := testKey(4)
	newKey := testKey(5)
	if err := c.Put(testCoordinator, "m1-anon", ResolverResponse{ProviderID: "m1-anon", ReceiptPubkey: oldKey}); err != nil {
		t.Fatalf("Put old: %v", err)
	}
	if err := c.Put(testCoordinator, "m1-anon", ResolverResponse{ProviderID: "m1-anon", ReceiptPubkey: newKey}); err != nil {
		t.Fatalf("Put new: %v", err)
	}

	entries, err := c.LookupByProviderID(testCoordinator, "m1-anon")
	if err != nil {
		t.Fatalf("LookupByProviderID: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("got %d entries, want 2", len(entries))
	}
	seen := map[string]bool{}
	for _, entry := range entries {
		seen[b64(entry.ReceiptPubkey)] = true
	}
	if !seen[b64(oldKey)] || !seen[b64(newKey)] {
		t.Fatalf("entries missing rotated keys: %v", seen)
	}
}

func TestPutReplacesSameTuple(t *testing.T) {
	c := openTempCache(t)
	pubkey := testKey(6)
	if err := c.Put(testCoordinator, "m1-anon", ResolverResponse{ProviderID: "m1-anon", ReceiptPubkey: pubkey}); err != nil {
		t.Fatalf("Put first: %v", err)
	}
	if err := c.Put(testCoordinator, "m1-anon", ResolverResponse{
		ProviderID:    "m1-anon",
		ReceiptPubkey: pubkey,
		ReceiptPubkeyPrev: &PreviousKeyResponse{
			Pubkey:    testKey(7),
			RotatedAt: time.Now().UTC().Add(-time.Hour),
			ExpiresAt: time.Now().UTC().Add(time.Hour),
		},
	}); err != nil {
		t.Fatalf("Put second: %v", err)
	}

	lines := readLines(t, c.Path())
	if len(lines) != 1 {
		t.Fatalf("got %d cache lines, want 1", len(lines))
	}
	got, _, err := c.Lookup(testCoordinator, "m1-anon", pubkey)
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if got.ReceiptPubkeyPrev == nil {
		t.Fatal("replacement did not update previous-key block")
	}
}

func TestOpenDefaultPathHonorsXDGAndHomeFallback(t *testing.T) {
	cacheDir := t.TempDir()
	t.Setenv("MACPROVIDER_CACHE_DIR", cacheDir)
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	c, err := Open("")
	if err != nil {
		t.Fatalf("Open with MACPROVIDER_CACHE_DIR: %v", err)
	}
	want := filepath.Join(cacheDir, "verify-cache.jsonl")
	if c.Path() != want {
		t.Fatalf("MACPROVIDER_CACHE_DIR path = %q, want %q", c.Path(), want)
	}

	xdg := t.TempDir()
	t.Setenv("MACPROVIDER_CACHE_DIR", "")
	t.Setenv("XDG_CONFIG_HOME", xdg)
	c, err = Open("")
	if err != nil {
		t.Fatalf("Open with XDG: %v", err)
	}
	want = filepath.Join(xdg, "macprovider", "verify-cache.jsonl")
	if c.Path() != want {
		t.Fatalf("XDG path = %q, want %q", c.Path(), want)
	}

	home := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("HOME", home)
	c, err = Open("")
	if err != nil {
		t.Fatalf("Open with HOME fallback: %v", err)
	}
	want = filepath.Join(home, ".config", "macprovider", "verify-cache.jsonl")
	if c.Path() != want {
		t.Fatalf("HOME fallback path = %q, want %q", c.Path(), want)
	}
}

func TestConcurrentLookupDoesNotRace(t *testing.T) {
	c := openTempCache(t)
	pubkey := testKey(8)
	if err := c.Put(testCoordinator, "m1-anon", ResolverResponse{ProviderID: "m1-anon", ReceiptPubkey: pubkey}); err != nil {
		t.Fatalf("Put: %v", err)
	}

	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				got, fresh, err := c.Lookup(testCoordinator, "m1-anon", pubkey)
				if err != nil {
					t.Errorf("Lookup: %v", err)
					return
				}
				if got == nil || !fresh {
					t.Errorf("Lookup got=%#v fresh=%v, want fresh entry", got, fresh)
					return
				}
			}
		}()
	}
	wg.Wait()
}

func TestCorruptedJSONLineIsSkipped(t *testing.T) {
	c := openTempCache(t)
	pubkey := testKey(9)
	writeDiskEntries(t, c.Path(), diskEntry{
		CoordinatorHost: testCoordinator,
		ProviderID:      "m1-anon",
		ReceiptPubkey:   b64(pubkey),
		FetchedAt:       time.Now().UTC().Format(time.RFC3339),
	})
	f, err := os.OpenFile(c.Path(), os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatalf("open append: %v", err)
	}
	if _, err := f.WriteString("{not-json}\n"); err != nil {
		t.Fatalf("append corruption: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close append: %v", err)
	}

	var logs bytes.Buffer
	old := log.Writer()
	log.SetOutput(&logs)
	defer log.SetOutput(old)

	got, fresh, err := c.Lookup(testCoordinator, "m1-anon", pubkey)
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if got == nil || !fresh {
		t.Fatalf("Lookup got=%#v fresh=%v, want fresh entry", got, fresh)
	}
	if !strings.Contains(logs.String(), "skipping corrupted line") {
		t.Fatalf("missing corruption log, got %q", logs.String())
	}
}

func TestOversizedCacheLineReturnsReadError(t *testing.T) {
	c := openTempCache(t)
	if err := os.WriteFile(c.Path(), append(bytes.Repeat([]byte("x"), 2*1024*1024), '\n'), 0o600); err != nil {
		t.Fatalf("write oversized cache line: %v", err)
	}
	if _, err := c.readEntries(); err == nil {
		t.Fatal("readEntries returned nil error for oversized cache line")
	}
}

func TestCacheWriteIncludesFormatVersion(t *testing.T) {
	c := openTempCache(t)
	pubkey := testKey(10)
	if err := c.Put(testCoordinator, "m1-anon", ResolverResponse{ProviderID: "m1-anon", ReceiptPubkey: pubkey}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	data, err := os.ReadFile(c.Path())
	if err != nil {
		t.Fatalf("read cache: %v", err)
	}
	var disk diskEntry
	if err := json.Unmarshal(bytes.TrimSpace(data), &disk); err != nil {
		t.Fatalf("unmarshal cache line: %v", err)
	}
	if disk.CacheFormatVersion != cacheFormatV1 {
		t.Fatalf("cache_format_version = %d, want %d in %s", disk.CacheFormatVersion, cacheFormatV1, data)
	}
	if !bytes.Contains(data, []byte(`"cache_format_version":1`)) {
		t.Fatalf("raw cache line missing cache_format_version: %s", data)
	}
}

func TestUnknownCacheFormatVersionIsSkipped(t *testing.T) {
	c := openTempCache(t)
	pubkey := testKey(11)
	writeDiskEntries(t, c.Path(), diskEntry{
		CacheFormatVersion: 99,
		CoordinatorHost:    testCoordinator,
		ProviderID:         "m1-anon",
		ReceiptPubkey:      b64(pubkey),
		FetchedAt:          time.Now().UTC().Format(time.RFC3339),
	})

	entries, err := c.LookupByProviderID(testCoordinator, "m1-anon")
	if err != nil {
		t.Fatalf("LookupByProviderID: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("got %d entries for unknown cache format version, want 0", len(entries))
	}
}

func TestLegacyCacheLineWithoutFormatVersionStillDecodes(t *testing.T) {
	c := openTempCache(t)
	pubkey := testKey(12)
	line := map[string]any{
		"coordinator_host":    testCoordinator,
		"provider_id":         "m1-anon",
		"receipt_pubkey":      b64(pubkey),
		"receipt_pubkey_prev": nil,
		"fetched_at":          time.Now().UTC().Format(time.RFC3339),
	}
	data, err := json.Marshal(line)
	if err != nil {
		t.Fatalf("marshal legacy cache line: %v", err)
	}
	if err := os.WriteFile(c.Path(), append(data, '\n'), 0o600); err != nil {
		t.Fatalf("write legacy cache line: %v", err)
	}

	got, fresh, err := c.Lookup(testCoordinator, "m1-anon", pubkey)
	if err != nil {
		t.Fatalf("Lookup legacy entry: %v", err)
	}
	if got == nil || !fresh {
		t.Fatalf("legacy entry lookup got=%#v fresh=%v, want fresh entry", got, fresh)
	}
}

func openTempCache(t *testing.T) *Cache {
	t.Helper()
	c, err := Open(filepath.Join(t.TempDir(), "verify-cache.jsonl"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return c
}

func writeDiskEntries(t *testing.T, path string, entries ...diskEntry) {
	t.Helper()
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	for _, entry := range entries {
		if err := enc.Encode(entry); err != nil {
			t.Fatalf("encode fixture: %v", err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir fixture: %v", err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
}

func readLines(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read cache: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return nil
	}
	return lines
}

func testKey(seed byte) []byte {
	key := make([]byte, 32)
	for i := range key {
		key[i] = seed + byte(i)
	}
	return key
}

func b64(raw []byte) string {
	return base64.StdEncoding.EncodeToString(raw)
}

func init() {
	log.SetOutput(io.Discard)
}
