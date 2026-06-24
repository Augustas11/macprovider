// Package catalogcache implements the SPEC-015 v0.3 §M.3.4
// catalog-bytes cache. Three-band TTL: a fresh catalog caches for
// up to 6 hours; a near-expiry catalog caches for (expires_at -
// now() - 60s); a catalog accepted only via the §M.3.2 step 5 60s
// skew grace, OR one whose remaining lifetime is < 60s, MUST NOT
// be cached so the next verification re-checks expiry against a
// fresh wall-clock reading.
//
// Cache layout (one file per (catalog_url, catalog_pubkey
// fingerprint)):
//
//	~/.macprovider/verify/catalogs/<sha256-hex-of-catalog-url>.json
//
// Cache entry shape includes the resolved pubkey so a rotation
// (pubkey changes server-side) invalidates the cache miss-on-read.
package catalogcache

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Per SPEC-015 §M.3.4: upper TTL band ceiling = 6h.
const maxTTL = 6 * time.Hour

// Per SPEC-015 §M.3.4: the (60s, 6h] band caches for `R - 60s`;
// catalogs with `R <= 60s` are never cached.
const minTTL = 60 * time.Second

// Entry is the on-disk cache record. Field names mirror the
// SPEC-015 §M.3.4 contract verbatim. `catalog_pubkey_b64` is the
// base64.RawURLEncoding form (the catalog signer + coordinator
// both use this encoding); the "b64" suffix is the §M.3.4 name.
// `expires_at` is the catalog's OWN expires_at (from the parsed
// signed body, propagated unchanged); `cache_expires_at` is the
// computed §M.3.4 TTL ceiling. Both are persisted so Step 5
// diagnostics can distinguish "catalog itself expired" from
// "cache slot expired."
type Entry struct {
	CatalogURL      string    `json:"catalog_url"`
	CatalogBytes    []byte    `json:"catalog_bytes"`
	CatalogPubkey   string    `json:"catalog_pubkey_b64"`
	FetchedAt       time.Time `json:"fetched_at"`
	ExpiresAt       time.Time `json:"expires_at"`
	CacheExpiresAt  time.Time `json:"cache_expires_at"`
}

// Store is a simple on-disk cache rooted at Dir.
type Store struct {
	Dir string
}

// New returns a Store rooted at <home>/.macprovider/verify/catalogs.
// If home cannot be resolved, the returned Store is unusable.
func New() (*Store, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("catalogcache: resolve home: %w", err)
	}
	return &Store{Dir: filepath.Join(home, ".macprovider", "verify", "catalogs")}, nil
}

// NewAt returns a Store rooted at dir (test seam).
func NewAt(dir string) *Store {
	return &Store{Dir: dir}
}

// ComputeTTL applies the §M.3.4 three-band rule. R = expires_at -
// now() in seconds. Returns the cache TTL; zero (or negative) means
// "do not cache." The implementation is pure arithmetic so it can be
// unit-tested without disk.
func ComputeTTL(expiresAt, now time.Time) time.Duration {
	r := expiresAt.Sub(now)
	if r <= minTTL {
		return 0
	}
	if r > maxTTL {
		return maxTTL
	}
	return r - minTTL
}

// Put writes the catalog bytes + pubkey into the cache, computing
// the TTL per §M.3.4. Returns (nil, false) without writing if the
// computed TTL is zero (do-not-cache band). Returns (entry, true)
// on a successful write.
func (s *Store) Put(catalogURL string, catalogBytes []byte, pubkeyBase64URL string, expiresAt, now time.Time) (*Entry, bool, error) {
	if s.Dir == "" {
		return nil, false, errors.New("catalogcache: store has empty Dir")
	}
	ttl := ComputeTTL(expiresAt, now)
	if ttl <= 0 {
		return nil, false, nil
	}
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return nil, false, fmt.Errorf("catalogcache: mkdir: %w", err)
	}
	entry := &Entry{
		CatalogURL:     catalogURL,
		CatalogBytes:   append([]byte(nil), catalogBytes...),
		CatalogPubkey:  pubkeyBase64URL,
		FetchedAt:      now.UTC(),
		ExpiresAt:      expiresAt.UTC(),
		CacheExpiresAt: now.Add(ttl).UTC(),
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return nil, false, fmt.Errorf("catalogcache: marshal: %w", err)
	}
	path := s.pathFor(catalogURL)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return nil, false, fmt.Errorf("catalogcache: write tmp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return nil, false, fmt.Errorf("catalogcache: rename: %w", err)
	}
	return entry, true, nil
}

// Get returns a cache hit if all three conditions hold:
//  1. an entry exists for catalogURL,
//  2. the cached entry has not exceeded its own TTL (ExpiresAtCache),
//  3. the cached entry's pubkey matches the supplied expectedPubkey.
//
// Returns (entry, true) on hit, (nil, false) on miss (including the
// rotation case where the pubkey changed). Errors only on I/O or
// corrupt-cache; a corrupt entry is silently treated as a miss and
// the bad file is removed.
func (s *Store) Get(catalogURL, expectedPubkeyBase64URL string, now time.Time) (*Entry, bool, error) {
	if s.Dir == "" {
		return nil, false, errors.New("catalogcache: store has empty Dir")
	}
	path := s.pathFor(catalogURL)
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("catalogcache: read: %w", err)
	}
	var entry Entry
	if err := json.Unmarshal(data, &entry); err != nil {
		// Corrupt entry — remove and miss.
		_ = os.Remove(path)
		return nil, false, nil
	}
	if entry.CatalogURL != catalogURL {
		// Hash collision OR cross-URL pollution — treat as miss.
		_ = os.Remove(path)
		return nil, false, nil
	}
	if entry.CatalogPubkey != expectedPubkeyBase64URL {
		// Pubkey rotation — invalidate.
		return nil, false, nil
	}
	if !now.Before(entry.CacheExpiresAt) {
		// Stale — invalidate.
		return nil, false, nil
	}
	return &entry, true, nil
}

// Delete removes the cache entry for catalogURL. Idempotent.
func (s *Store) Delete(catalogURL string) error {
	if s.Dir == "" {
		return errors.New("catalogcache: store has empty Dir")
	}
	path := s.pathFor(catalogURL)
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("catalogcache: remove: %w", err)
	}
	return nil
}

// pathFor returns the filesystem path for the URL's cache entry.
// Keyed by SHA-256(catalogURL) so unusual characters in the URL
// (query strings, encoded chars) don't break filename rules. The
// pubkey is NOT part of the key — pubkey rotation is detected by
// comparing the stored CatalogPubkey on read, which lets a single
// cache slot survive across rotation events with explicit miss.
func (s *Store) pathFor(catalogURL string) string {
	sum := sha256.Sum256([]byte(catalogURL))
	return filepath.Join(s.Dir, hex.EncodeToString(sum[:])+".json")
}

// EncodePubkeyForCache normalizes a catalog pubkey to its
// base64.RawURLEncoding form so the cache key is consistent
// across verify invocations even when callers vary in how they
// supplied --catalog-pubkey vs --catalog-pubkey-url.
func EncodePubkeyForCache(raw []byte) string {
	return base64.RawURLEncoding.EncodeToString(raw)
}
