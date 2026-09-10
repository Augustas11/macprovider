package relayblind

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

// Authority authenticates provider key advertisements against the operator's
// provider-ID keyed Ed25519 pins before making them reservable.
type Authority struct {
	store           *Store
	publicKeys      map[string]ed25519.PublicKey
	maxRecords      int
	replayRetention time.Duration
}

func NewAuthority(store *Store, configured map[string]string, maxRecords int, retention ...time.Duration) (*Authority, error) {
	if store == nil {
		return nil, ErrStoreUnavailable
	}
	keys := make(map[string]ed25519.PublicKey, len(configured))
	for rawProviderID, encoded := range configured {
		providerID := strings.TrimSpace(rawProviderID)
		decoded, err := base64.RawURLEncoding.DecodeString(encoded)
		if providerID == "" || err != nil || len(decoded) != ed25519.PublicKeySize || base64.RawURLEncoding.EncodeToString(decoded) != encoded {
			return nil, fmt.Errorf("relayblind: invalid identity pin for provider %q", rawProviderID)
		}
		keys[providerID] = append(ed25519.PublicKey(nil), decoded...)
	}
	if len(keys) == 0 {
		return nil, fmt.Errorf("relayblind: no operator identity pins")
	}
	replayRetention := 5 * time.Minute
	if len(retention) > 0 && retention[0] > 0 {
		replayRetention = retention[0]
	}
	return &Authority{store: store, publicKeys: keys, maxRecords: maxRecords, replayRetention: replayRetention}, nil
}

func (a *Authority) AcceptProviderKeys(ctx context.Context, providerID, assignedSession string, records []KeyRecord, now time.Time) error {
	if a == nil || a.store == nil {
		return ErrStoreUnavailable
	}
	publicKey, ok := a.publicKeys[providerID]
	if !ok {
		if len(records) == 0 {
			return nil
		}
		return fmt.Errorf("%w: provider has no operator pin", ErrInvalidPin)
	}
	if assignedSession == "" {
		return ErrStaleSession
	}
	if a.maxRecords > 0 && len(records) > a.maxRecords {
		return ErrCapacity
	}

	type accepted struct {
		record          KeyRecord
		immutableDigest string
	}
	verified := make([]accepted, 0, len(records))
	seen := make(map[string]struct{}, len(records))
	for _, record := range records {
		if _, duplicate := seen[record.KID]; duplicate {
			return fmt.Errorf("%w: duplicate kid", ErrInvalidKeyRecord)
		}
		seen[record.KID] = struct{}{}
		fingerprint := sha256.Sum256(publicKey)
		pin := IdentityPin{
			Version:           PinVersion,
			IdentityPublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
			Fingerprint:       base64.RawURLEncoding.EncodeToString(fingerprint[:]),
			Models:            append([]string(nil), record.Models...),
			EndpointFamilies:  []string{EndpointChatCompletions},
			NotBeforeUnix:     0,
			ExpiresAtUnix:     math.MaxInt64,
		}
		if err := record.Verify(pin, now); err != nil {
			return err
		}
		if previous, found, err := a.store.ExistingKeyRecord(ctx, providerID, record.KID); err != nil {
			return err
		} else if found && previous.KeyRecordDigest != record.KeyRecordDigest {
			if err := ValidateKeyRenewal(previous, record, pin, now); err != nil {
				return err
			}
		}
		framing, err := record.ImmutableFraming()
		if err != nil {
			return err
		}
		digest := sha256.Sum256(framing)
		verified = append(verified, accepted{record: record, immutableDigest: base64.RawURLEncoding.EncodeToString(digest[:])})
	}
	// Stable ordering keeps renewal behavior deterministic across reconnects.
	sort.Slice(verified, func(i, j int) bool { return verified[i].record.KID < verified[j].record.KID })
	for _, item := range verified {
		if err := a.store.UpsertKeyRecord(ctx, providerID, assignedSession, item.record, item.immutableDigest, now, a.maxRecords, a.replayRetention); err != nil {
			return err
		}
	}
	activeKids := make([]string, 0, len(verified))
	for _, item := range verified {
		activeKids = append(activeKids, item.record.KID)
	}
	return a.store.RevokeMissingKeys(ctx, providerID, activeKids, now, a.replayRetention)
}

func (a *Authority) RevokeProviderKey(ctx context.Context, providerID, kid string, now time.Time, replayRetention time.Duration) error {
	if a == nil || a.store == nil {
		return ErrStoreUnavailable
	}
	if _, ok := a.publicKeys[providerID]; !ok {
		return ErrInvalidPin
	}
	return a.store.RevokeKey(ctx, providerID, kid, now, replayRetention)
}
