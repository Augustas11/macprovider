package sqlite

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestRelayBlindReplaySurvivesReopenAndHonorsOriginalRetention(t *testing.T) {
	for _, scope := range []struct {
		name      string
		sessionID string
	}{
		{name: "account"},
		{name: "wallet_session", sessionID: "ws_relay_blind_reopen"},
	} {
		t.Run(scope.name, func(t *testing.T) {
			ctx := context.Background()
			path := filepath.Join(t.TempDir(), "gateway.db")
			store, err := Open(ctx, path)
			if err != nil {
				t.Fatalf("Open: %v", err)
			}
			t.Cleanup(func() {
				if err := store.Close(); err != nil {
					t.Errorf("Close: %v", err)
				}
			})
			createAccount(t, store, "acct_relay_blind_reopen")
			now := fixedTime()
			original := storage.RelayBlindReplayMaterial{
				AccountID:                     "acct_relay_blind_reopen",
				WalletSessionID:               scope.sessionID,
				RequestID:                     "req-original",
				RequestReplayNonceDigest:      []byte("nonce-original"),
				BuyerEphemeralPublicKeyDigest: []byte("buyer-key-original"),
				ProviderBindingDigest:         []byte("provider-binding"),
				KIDDigest:                     []byte("kid"),
				EnvelopeDigest:                []byte("envelope-original"),
				EnvelopeBytes:                 128,
				RetentionExpiresAt:            now.Add(time.Hour),
				MaxReplayRows:                 1,
				MaxReplayBytes:                128,
				CreatedAt:                     now,
			}
			if err := store.RecordRelayBlindReplay(ctx, original); err != nil {
				t.Fatalf("record original: %v", err)
			}
			if err := store.Close(); err != nil {
				t.Fatalf("close before reopen: %v", err)
			}
			reopened, err := Open(ctx, path)
			if err != nil {
				t.Fatalf("reopen: %v", err)
			}
			store = reopened

			unique := original
			unique.RequestID = "req-new"
			unique.RequestReplayNonceDigest = []byte("nonce-new")
			unique.BuyerEphemeralPublicKeyDigest = []byte("buyer-key-new")
			unique.EnvelopeDigest = []byte("envelope-new")
			unique.CreatedAt = now.Add(time.Minute)
			unique.RetentionExpiresAt = now.Add(2 * time.Minute)
			if seen, err := store.RelayBlindReplaySeen(ctx, unique); err != nil || seen {
				t.Fatalf("unique lookup seen=%v err=%v, want false and nil", seen, err)
			}
			if err := store.RecordRelayBlindReplay(ctx, unique); !errors.Is(err, storage.ErrRateLimit) {
				t.Fatalf("unique over retained capacity: %v, want ErrRateLimit", err)
			}

			for _, collision := range []string{"exact", "request_id", "nonce", "ephemeral_key", "envelope_digest"} {
				t.Run(collision, func(t *testing.T) {
					replay := unique
					switch collision {
					case "exact":
						replay = original
					case "request_id":
						replay.RequestID = original.RequestID
					case "nonce":
						replay.RequestReplayNonceDigest = original.RequestReplayNonceDigest
					case "ephemeral_key":
						replay.BuyerEphemeralPublicKeyDigest = original.BuyerEphemeralPublicKeyDigest
					case "envelope_digest":
						replay.EnvelopeDigest = original.EnvelopeDigest
					}
					// A shorter current retention setting cannot shorten the persisted window.
					for _, at := range []time.Time{now.Add(time.Minute), original.RetentionExpiresAt.Add(-time.Second)} {
						replay.CreatedAt = at
						replay.RetentionExpiresAt = at.Add(time.Minute)
						if seen, err := store.RelayBlindReplaySeen(ctx, replay); err != nil || !seen {
							t.Fatalf("retained lookup at %s seen=%v err=%v, want true and nil", at, seen, err)
						}
						if err := store.RecordRelayBlindReplay(ctx, replay); !errors.Is(err, storage.ErrRelayBlindReplay) {
							t.Fatalf("retained duplicate at %s: %v, want ErrRelayBlindReplay before capacity", at, err)
						}
					}
				})
			}

			original.CreatedAt = original.RetentionExpiresAt
			original.RetentionExpiresAt = original.CreatedAt.Add(time.Minute)
			if seen, err := store.RelayBlindReplaySeen(ctx, original); err != nil || seen {
				t.Fatalf("expired lookup seen=%v err=%v, want false and nil", seen, err)
			}
			if err := store.RecordRelayBlindReplay(ctx, original); err != nil {
				t.Fatalf("record after original retention expires: %v", err)
			}
		})
	}
}
