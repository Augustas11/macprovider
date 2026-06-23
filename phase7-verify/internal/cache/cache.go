// Package cache stores coordinator receipt pubkeys for offline verification.
package cache

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/receipt"
)

// TTL is the maximum age of a cache entry before the resolver must refresh it.
const TTL = 7 * 24 * time.Hour

// Entry is one decoded cache entry.
type Entry struct {
	CoordinatorHost   string
	ProviderID        string
	ReceiptPubkey     []byte
	ReceiptPubkeyPrev *PreviousKey
	FetchedAt         time.Time
}

// PreviousKey is the coordinator-attested previous key grace-window block.
type PreviousKey struct {
	Pubkey    []byte
	RotatedAt time.Time
	ExpiresAt time.Time
}

// ResolverResponse is the decoded /v1/receipt-keys response shape accepted by Put.
type ResolverResponse struct {
	ProviderID        string
	ReceiptPubkey     []byte
	ReceiptPubkeyPrev *PreviousKeyResponse
	FetchedAt         time.Time
}

// PreviousKeyResponse is the previous-key block from /v1/receipt-keys.
type PreviousKeyResponse struct {
	Pubkey    []byte
	RotatedAt time.Time
	ExpiresAt time.Time
}

// Cache is the on-disk pubkey cache. Backed by a JSON-Lines file.
type Cache struct {
	path string
}

type diskEntry struct {
	CoordinatorHost   string        `json:"coordinator_host"`
	ProviderID        string        `json:"provider_id"`
	ReceiptPubkey     string        `json:"receipt_pubkey"`
	ReceiptPubkeyPrev *diskPrevious `json:"receipt_pubkey_prev"`
	FetchedAt         string        `json:"fetched_at"`
}

type diskPrevious struct {
	Pubkey    string `json:"pubkey"`
	RotatedAt string `json:"rotated_at"`
	ExpiresAt string `json:"expires_at"`
}

var writeFileAtomic = writeFileAtomicImpl

// Open returns a Cache rooted at path, creating parent directories as needed.
// When path is empty, Open uses $XDG_CONFIG_HOME/macprovider/verify-cache.jsonl,
// falling back to ~/.config/macprovider/verify-cache.jsonl.
func Open(path string) (*Cache, error) {
	resolved, err := resolvePath(path)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(resolved), 0o700); err != nil {
		return nil, fmt.Errorf("create cache directory: %w", err)
	}
	return &Cache{path: resolved}, nil
}

// Lookup returns the freshest entry matching the coordinator, provider_id, and pubkey.
func (c *Cache) Lookup(coordinatorHost, providerID string, pubkey []byte) (*Entry, bool, error) {
	entries, err := c.readEntries()
	if err != nil {
		return nil, false, err
	}
	var freshest *Entry
	for _, entry := range entries {
		if entry.CoordinatorHost != coordinatorHost || entry.ProviderID != providerID {
			continue
		}
		if !bytes.Equal(entry.ReceiptPubkey, pubkey) {
			continue
		}
		if freshest == nil || entry.FetchedAt.After(freshest.FetchedAt) {
			freshest = entry
		}
	}
	if freshest == nil {
		return nil, false, nil
	}
	return cloneEntry(freshest), isFresh(freshest.FetchedAt, time.Now().UTC()), nil
}

// LookupByProviderID returns every entry for coordinator/provider_id, newest first.
func (c *Cache) LookupByProviderID(coordinatorHost, providerID string) ([]*Entry, error) {
	entries, err := c.readEntries()
	if err != nil {
		return nil, err
	}
	matches := make([]*Entry, 0)
	for _, entry := range entries {
		if entry.CoordinatorHost == coordinatorHost && entry.ProviderID == providerID {
			matches = append(matches, cloneEntry(entry))
		}
	}
	sort.SliceStable(matches, func(i, j int) bool {
		return matches[i].FetchedAt.After(matches[j].FetchedAt)
	})
	return matches, nil
}

// Put writes a fresh cache entry, replacing an existing entry with the same
// (coordinator_host, provider_id, receipt_pubkey) tuple and preserving other keys.
func (c *Cache) Put(coordinatorHost, providerID string, resp ResolverResponse) error {
	if c == nil {
		return errors.New("nil cache")
	}
	if providerID == "" {
		providerID = resp.ProviderID
	}
	if len(resp.ReceiptPubkey) != 32 {
		return fmt.Errorf("%w: got %d bytes", receipt.ErrPubkeyLength, len(resp.ReceiptPubkey))
	}
	if resp.ReceiptPubkeyPrev != nil && len(resp.ReceiptPubkeyPrev.Pubkey) != 32 {
		return fmt.Errorf("%w: previous got %d bytes", receipt.ErrPubkeyLength, len(resp.ReceiptPubkeyPrev.Pubkey))
	}

	entries, err := c.readEntries()
	if err != nil {
		return err
	}
	replacement := &Entry{
		CoordinatorHost:   coordinatorHost,
		ProviderID:        providerID,
		ReceiptPubkey:     cloneBytes(resp.ReceiptPubkey),
		ReceiptPubkeyPrev: previousResponseToEntry(resp.ReceiptPubkeyPrev),
		FetchedAt:         time.Now().UTC(),
	}

	replaced := false
	for i, entry := range entries {
		if entry.CoordinatorHost == coordinatorHost &&
			entry.ProviderID == providerID &&
			bytes.Equal(entry.ReceiptPubkey, resp.ReceiptPubkey) {
			entries[i] = replacement
			replaced = true
		}
	}
	if !replaced {
		entries = append(entries, replacement)
	}

	data, err := encodeEntries(entries)
	if err != nil {
		return err
	}
	return writeFileAtomic(c.path, data, 0o600)
}

// Path returns the absolute cache file path.
func (c *Cache) Path() string {
	if c == nil {
		return ""
	}
	return c.path
}

func resolvePath(path string) (string, error) {
	if path == "" {
		base := os.Getenv("XDG_CONFIG_HOME")
		if base == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				return "", fmt.Errorf("resolve home directory: %w", err)
			}
			base = filepath.Join(home, ".config")
		}
		path = filepath.Join(base, "macprovider", "verify-cache.jsonl")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve cache path: %w", err)
	}
	return abs, nil
}

func (c *Cache) readEntries() ([]*Entry, error) {
	file, err := os.Open(c.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("open cache: %w", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	var entries []*Entry
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		entry, err := decodeEntry(line)
		if err != nil {
			log.Printf("macprovider verify cache: skipping corrupted line %d in %s: %v", lineNo, c.path, err)
			continue
		}
		entries = append(entries, entry)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read cache: %w", err)
	}
	return entries, nil
}

func decodeEntry(line []byte) (*Entry, error) {
	var disk diskEntry
	if err := json.Unmarshal(line, &disk); err != nil {
		return nil, err
	}
	if disk.CoordinatorHost == "" || disk.ProviderID == "" || disk.ReceiptPubkey == "" || disk.FetchedAt == "" {
		return nil, errors.New("missing required field")
	}
	pubkey, err := receipt.ParsePubkey(disk.ReceiptPubkey)
	if err != nil {
		return nil, err
	}
	fetchedAt, err := time.Parse(time.RFC3339, disk.FetchedAt)
	if err != nil {
		return nil, fmt.Errorf("parse fetched_at: %w", err)
	}
	entry := &Entry{
		CoordinatorHost: disk.CoordinatorHost,
		ProviderID:      disk.ProviderID,
		ReceiptPubkey:   pubkey,
		FetchedAt:       fetchedAt.UTC(),
	}
	if disk.ReceiptPubkeyPrev != nil {
		prev, err := decodePrevious(disk.ReceiptPubkeyPrev)
		if err != nil {
			return nil, err
		}
		entry.ReceiptPubkeyPrev = prev
	}
	return entry, nil
}

func decodePrevious(disk *diskPrevious) (*PreviousKey, error) {
	if disk.Pubkey == "" || disk.RotatedAt == "" || disk.ExpiresAt == "" {
		return nil, errors.New("missing previous key field")
	}
	pubkey, err := receipt.ParsePubkey(disk.Pubkey)
	if err != nil {
		return nil, err
	}
	rotatedAt, err := time.Parse(time.RFC3339, disk.RotatedAt)
	if err != nil {
		return nil, fmt.Errorf("parse rotated_at: %w", err)
	}
	expiresAt, err := time.Parse(time.RFC3339, disk.ExpiresAt)
	if err != nil {
		return nil, fmt.Errorf("parse expires_at: %w", err)
	}
	return &PreviousKey{
		Pubkey:    pubkey,
		RotatedAt: rotatedAt.UTC(),
		ExpiresAt: expiresAt.UTC(),
	}, nil
}

func encodeEntries(entries []*Entry) ([]byte, error) {
	var buf bytes.Buffer
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	for _, entry := range entries {
		if err := encoder.Encode(entryToDisk(entry)); err != nil {
			return nil, fmt.Errorf("encode cache entry: %w", err)
		}
	}
	return buf.Bytes(), nil
}

func entryToDisk(entry *Entry) diskEntry {
	disk := diskEntry{
		CoordinatorHost: entry.CoordinatorHost,
		ProviderID:      entry.ProviderID,
		ReceiptPubkey:   base64.StdEncoding.EncodeToString(entry.ReceiptPubkey),
		FetchedAt:       entry.FetchedAt.UTC().Format(time.RFC3339),
	}
	if entry.ReceiptPubkeyPrev != nil {
		disk.ReceiptPubkeyPrev = &diskPrevious{
			Pubkey:    base64.StdEncoding.EncodeToString(entry.ReceiptPubkeyPrev.Pubkey),
			RotatedAt: entry.ReceiptPubkeyPrev.RotatedAt.UTC().Format(time.RFC3339),
			ExpiresAt: entry.ReceiptPubkeyPrev.ExpiresAt.UTC().Format(time.RFC3339),
		}
	}
	return disk
}

func previousResponseToEntry(prev *PreviousKeyResponse) *PreviousKey {
	if prev == nil {
		return nil
	}
	return &PreviousKey{
		Pubkey:    cloneBytes(prev.Pubkey),
		RotatedAt: prev.RotatedAt.UTC(),
		ExpiresAt: prev.ExpiresAt.UTC(),
	}
}

func cloneEntry(entry *Entry) *Entry {
	if entry == nil {
		return nil
	}
	cloned := &Entry{
		CoordinatorHost: entry.CoordinatorHost,
		ProviderID:      entry.ProviderID,
		ReceiptPubkey:   cloneBytes(entry.ReceiptPubkey),
		FetchedAt:       entry.FetchedAt,
	}
	if entry.ReceiptPubkeyPrev != nil {
		cloned.ReceiptPubkeyPrev = &PreviousKey{
			Pubkey:    cloneBytes(entry.ReceiptPubkeyPrev.Pubkey),
			RotatedAt: entry.ReceiptPubkeyPrev.RotatedAt,
			ExpiresAt: entry.ReceiptPubkeyPrev.ExpiresAt,
		}
	}
	return cloned
}

func cloneBytes(in []byte) []byte {
	if in == nil {
		return nil
	}
	out := make([]byte, len(in))
	copy(out, in)
	return out
}

func isFresh(fetchedAt, now time.Time) bool {
	return now.Sub(fetchedAt.UTC()) <= TTL
}

func writeFileAtomicImpl(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create cache directory: %w", err)
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create temp cache file: %w", err)
	}
	tmpName := tmp.Name()
	removeTemp := true
	defer func() {
		if removeTemp {
			_ = os.Remove(tmpName)
		}
	}()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write temp cache file: %w", err)
	}
	if err := tmp.Chmod(perm); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("chmod temp cache file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("sync temp cache file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp cache file: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("rename temp cache file: %w", err)
	}
	removeTemp = false

	if dirHandle, err := os.Open(dir); err == nil {
		_ = dirHandle.Sync()
		_ = dirHandle.Close()
	}
	return nil
}
