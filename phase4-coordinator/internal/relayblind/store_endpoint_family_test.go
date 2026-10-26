package relayblind

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestReservationEndpointFamilyPersistsAndRejectsSubstitution(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_000, 0).UTC()
	path := filepath.Join(t.TempDir(), "families.sqlite")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	_, _, envelope, raw := storeFixture(t, store, now, "provider-family", "session-family")
	held, err := store.LookupReservation(ctx, envelope.ProviderBinding)
	if err != nil || held.EndpointFamily != EndpointChatCompletions {
		t.Fatalf("legacy default: %+v, %v", held, err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	held, err = store.LookupReservation(ctx, envelope.ProviderBinding)
	if err != nil || held.EndpointFamily != EndpointChatCompletions {
		t.Fatalf("family after reopen: %+v, %v", held, err)
	}
	envelope.EndpointFamily = EndpointResponses
	digest, _ := DigestEnvelopeBytes(raw)
	_, err = store.Consume(ctx, ConsumeInput{AccountID: "acct-a", WalletSession: "wallet-a", Envelope: envelope, EnvelopeDigest: digest, Now: now})
	if !errors.Is(err, ErrReservationMismatch) {
		t.Fatalf("substituted family consumed: %v", err)
	}
}
