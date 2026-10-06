package relayblind

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"syscall"
	"time"
)

// identityDirectoryCacheTTL bounds how long one signed envelope is reused
// (SPEC-049-R028).
const identityDirectoryCacheTTL = 15 * time.Second

const maxIdentityDirectoryKeyFileBytes = 256

// IdentityDirectoryService signs the SPEC-049-R028 directory with the online
// directory key. The private key never leaves this value.
type IdentityDirectoryService struct {
	authority *PrivacyAuthority
	key       ed25519.PrivateKey
	ttl       time.Duration

	mu       sync.Mutex
	cached   []byte
	cachedAt time.Time
}

func NewIdentityDirectoryService(authority *PrivacyAuthority, key ed25519.PrivateKey, ttl time.Duration) (*IdentityDirectoryService, error) {
	if authority == nil || authority.store == nil {
		return nil, ErrStoreUnavailable
	}
	if len(key) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("%w: signing key", ErrInvalidDirectory)
	}
	if ttl < MinIdentityDirectoryTTL || ttl > MaxIdentityDirectoryTTL {
		return nil, fmt.Errorf("%w: ttl", ErrInvalidDirectory)
	}
	return &IdentityDirectoryService{authority: authority, key: key, ttl: ttl}, nil
}

// KeyID is the public directory key fingerprint buyers pin.
func (s *IdentityDirectoryService) KeyID() string {
	return PublicKeyFingerprint(s.key.Public().(ed25519.PublicKey))
}

// Envelope returns signed directory bytes, reusing one envelope for at most
// identityDirectoryCacheTTL. A build or signing error is never cached.
func (s *IdentityDirectoryService) Envelope(ctx context.Context, now time.Time) ([]byte, error) {
	if s == nil {
		return nil, ErrStoreUnavailable
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cached != nil && !now.Before(s.cachedAt) && now.Sub(s.cachedAt) < identityDirectoryCacheTTL {
		return append([]byte(nil), s.cached...), nil
	}
	directory, err := s.authority.BuildIdentityDirectory(ctx, now, s.ttl)
	if err != nil {
		return nil, err
	}
	raw, err := SignIdentityDirectory(directory, s.key)
	if err != nil {
		return nil, err
	}
	s.cached, s.cachedAt = raw, now
	return append([]byte(nil), raw...), nil
}

type directoryCandidate struct {
	entry  IdentityDirectoryEntry
	active bool
}

// BuildIdentityDirectory lists every provider whose two keys resolve from
// configuration pins or an active enrollment, revoked while quarantined, and
// every enrollment revoked within EnrollmentRevocationRetention as revoked.
// A store error fails the whole directory; it is never partial.
func (a *PrivacyAuthority) BuildIdentityDirectory(ctx context.Context, now time.Time, ttl time.Duration) (IdentityDirectory, error) {
	if a == nil || a.store == nil {
		return IdentityDirectory{}, ErrStoreUnavailable
	}
	ctx = privacyCtx(ctx)
	enrollments, err := a.store.ListPrivacyEnrollments(ctx, now.Add(-EnrollmentRevocationRetention))
	if err != nil {
		return IdentityDirectory{}, err
	}
	quarantined, err := a.store.QuarantinedProviders(ctx, now)
	if err != nil {
		return IdentityDirectory{}, err
	}
	candidates := make(map[string]directoryCandidate)
	add := func(entry IdentityDirectoryEntry, active bool) {
		existing, ok := candidates[entry.Fingerprint]
		switch {
		case !ok:
			candidates[entry.Fingerprint] = directoryCandidate{entry: entry, active: active}
		case active && !existing.active:
			candidates[entry.Fingerprint] = directoryCandidate{entry: entry, active: true}
		case active && existing.active:
			// One identity resolving for two providers is ambiguous, so it is
			// published as revoked rather than trusted for either.
			existing.entry.Revoked = true
			candidates[entry.Fingerprint] = existing
		}
	}
	for providerID, se := range a.sePins {
		identity, ok := a.identity[providerID]
		if !ok {
			continue
		}
		_, isQuarantined := quarantined[providerID]
		add(IdentityDirectoryEntry{
			IdentityPublicKey:      encodeBase64URL(identity),
			Fingerprint:            PublicKeyFingerprint(identity),
			SEPublicKeyFingerprint: PublicKeyFingerprint(se),
			Source:                 IdentityDirectorySourceOperatorPin,
			Revoked:                isQuarantined,
		}, true)
	}
	for _, enrollment := range enrollments {
		if enrollment.RevokedAtUnix != 0 {
			add(IdentityDirectoryEntry{
				IdentityPublicKey:      enrollment.IdentityPublicKey,
				Fingerprint:            enrollment.IdentityFingerprint,
				SEPublicKeyFingerprint: enrollment.SEFingerprint,
				Source:                 IdentityDirectorySourceEnrolled,
				EnrolledAtUnix:         enrollment.EnrolledAtUnix,
				Revoked:                true,
			}, false)
			continue
		}
		_, idPinned := a.identity[enrollment.ProviderID]
		_, sePinned := a.sePins[enrollment.ProviderID]
		if idPinned && sePinned {
			continue
		}
		identityKey := enrollment.IdentityPublicKey
		if idPinned {
			identityKey = encodeBase64URL(a.identity[enrollment.ProviderID])
		}
		identity, err := decodeBase64URLFixed(identityKey, ed25519.PublicKeySize)
		if err != nil {
			return IdentityDirectory{}, fmt.Errorf("%w: stored enrollment identity", ErrStoreUnavailable)
		}
		_, isQuarantined := quarantined[enrollment.ProviderID]
		add(IdentityDirectoryEntry{
			IdentityPublicKey:      identityKey,
			Fingerprint:            PublicKeyFingerprint(identity),
			SEPublicKeyFingerprint: enrollment.SEFingerprint,
			Source:                 IdentityDirectorySourceEnrolled,
			EnrolledAtUnix:         enrollment.EnrolledAtUnix,
			Revoked:                isQuarantined,
		}, true)
	}
	if len(candidates) > MaxIdentityDirectoryEntries {
		return IdentityDirectory{}, fmt.Errorf("%w: more than %d entries", ErrInvalidDirectory, MaxIdentityDirectoryEntries)
	}
	entries := make([]IdentityDirectoryEntry, 0, len(candidates))
	for _, candidate := range candidates {
		entries = append(entries, candidate.entry)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Fingerprint < entries[j].Fingerprint })
	directory := IdentityDirectory{
		Version:       IdentityDirectoryVersion,
		PrivacyClass:  PrivacyClassV1,
		IssuedAtUnix:  now.Unix(),
		ExpiresAtUnix: now.Add(ttl).Unix(),
		Entries:       entries,
	}
	if err := directory.Validate(); err != nil {
		return IdentityDirectory{}, err
	}
	return directory, nil
}

// LoadIdentityDirectorySigningKey reads the canonical base64url Ed25519 seed
// from a regular, non-symlink file with mode 0600 or 0400 owned by this user
// or root (SPEC-049-R028). Errors never include key bytes.
func LoadIdentityDirectorySigningKey(path string) (ed25519.PrivateKey, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("relayblind: directory signing key path must be absolute")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, errors.New("relayblind: directory signing key is unreadable")
	}
	if !info.Mode().IsRegular() || info.Size() > maxIdentityDirectoryKeyFileBytes {
		return nil, errors.New("relayblind: directory signing key must be a small regular file")
	}
	if perm := info.Mode().Perm(); perm != 0o600 && perm != 0o400 {
		return nil, errors.New("relayblind: directory signing key mode must be 0600 or 0400")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || (stat.Uid != uint32(os.Geteuid()) && stat.Uid != 0) {
		return nil, errors.New("relayblind: directory signing key must be owned by this user or root")
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, errors.New("relayblind: directory signing key is unreadable")
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return nil, errors.New("relayblind: directory signing key changed while opening")
	}
	raw, err := io.ReadAll(io.LimitReader(file, maxIdentityDirectoryKeyFileBytes+1))
	if err != nil || len(raw) > maxIdentityDirectoryKeyFileBytes {
		return nil, errors.New("relayblind: directory signing key is unreadable")
	}
	seed, err := decodeBase64URLFixed(string(bytes.TrimSuffix(raw, []byte("\n"))), ed25519.SeedSize)
	if err != nil {
		return nil, errors.New("relayblind: directory signing key must be a canonical base64url 32-byte seed")
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

// GenerateIdentityDirectorySigningKey creates a new seed file with mode 0600
// by exclusive create and returns only the public key.
func GenerateIdentityDirectorySigningKey(path string) (ed25519.PublicKey, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("relayblind: directory signing key path must be absolute")
	}
	seed := make([]byte, ed25519.SeedSize)
	if _, err := io.ReadFull(rand.Reader, seed); err != nil {
		return nil, err
	}
	defer func() {
		for i := range seed {
			seed[i] = 0
		}
	}()
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, fmt.Errorf("relayblind: create directory signing key: %w", err)
	}
	encoded := encodeBase64URL(seed) + "\n"
	if _, err := file.WriteString(encoded); err != nil {
		file.Close()
		_ = os.Remove(path)
		return nil, errors.New("relayblind: write directory signing key failed")
	}
	// Mode is fixed on the open descriptor, never by path after close.
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		_ = os.Remove(path)
		return nil, errors.New("relayblind: chmod directory signing key failed")
	}
	if err := file.Sync(); err != nil {
		file.Close()
		_ = os.Remove(path)
		return nil, errors.New("relayblind: sync directory signing key failed")
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return nil, errors.New("relayblind: close directory signing key failed")
	}
	return ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey), nil
}
