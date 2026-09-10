package relayblind

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestStoreReservationReplayEvidenceAndRestart(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_000, 0).UTC()
	path := filepath.Join(t.TempDir(), "relay-blind.sqlite")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	record, identityPublic, envelope, raw := storeFixture(t, store, now, "provider-a", "session-a")
	digest, _ := DigestEnvelopeBytes(raw)

	consume, err := store.Consume(ctx, ConsumeInput{AccountID: "acct-a", WalletSession: "wallet-a", Envelope: envelope, EnvelopeDigest: digest, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Consume(ctx, ConsumeInput{AccountID: "acct-a", WalletSession: "wallet-a", Envelope: envelope, EnvelopeDigest: digest, Now: now}); !errors.Is(err, ErrReplay) {
		t.Fatalf("second consume = %v, want replay", err)
	}
	if _, err := store.LookupConsumedAuthorization(ctx, "acct-b", "wallet-a", consume.ExecutionAuthorization, now); !errors.Is(err, ErrReservationMismatch) {
		t.Fatalf("cross-account authorization = %v", err)
	}
	reservation, err := store.ArmDispatch(ctx, "acct-a", "wallet-a", consume.ExecutionAuthorization, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BindInternalRequestID(ctx, reservation.ProviderBinding, "internal-a"); err != nil {
		t.Fatal(err)
	}
	evidence := fixtureEvidence(reservation, "validated", 19)
	if _, err := store.PersistEvidence(ctx, "provider-a", "session-a", evidence, "", now); err != nil {
		t.Fatal(err)
	}
	evidence.State = "terminal"
	evidence.CompletionTokens = 7
	if _, err := store.PersistEvidence(ctx, "provider-a", "session-a", evidence, "", now); err != nil {
		t.Fatal(err)
	}
	status, err := store.LookupStatus(ctx, "acct-a", "wallet-a", BindingDigest(reservation.ProviderBinding), digest, now)
	if err != nil || status.State != ReservationStateTerminal || status.InternalRequestID != "internal-a" || status.ValidatedInputTokens == nil || *status.ValidatedInputTokens != 19 || status.CompletionTokens == nil || *status.CompletionTokens != 7 {
		t.Fatalf("status = %#v, err=%v", status, err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if _, err := reopened.LookupKeyRecord(ctx, "provider-a", "session-a", record.KID, record.KeyRecordDigest, now); err != nil {
		t.Fatal(err)
	}
	_ = identityPublic
}

func TestStoreConsumeRaceAndRevocation(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_100, 0).UTC()
	store, err := OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	record, _, envelope, raw := storeFixture(t, store, now, "provider-a", "session-a")
	digest, _ := DigestEnvelopeBytes(raw)
	var successes atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := store.Consume(ctx, ConsumeInput{AccountID: "acct-a", WalletSession: "wallet-a", Envelope: envelope, EnvelopeDigest: digest, Now: now}); err == nil {
				successes.Add(1)
			} else if !errors.Is(err, ErrReplay) {
				t.Errorf("race consume: %v", err)
			}
		}()
	}
	wg.Wait()
	if successes.Load() != 1 {
		t.Fatalf("successful consumes = %d", successes.Load())
	}
	if err := store.RevokeKey(ctx, "provider-a", record.KID, now, 5*time.Minute); err != nil {
		t.Fatal(err)
	}
	if _, err := store.LookupKeyRecord(ctx, "provider-a", "session-a", record.KID, record.KeyRecordDigest, now); !errors.Is(err, ErrKeyRevoked) {
		t.Fatalf("revoked key lookup = %v", err)
	}
}

func TestActiveKeyModelsRemainBoundToAdvertisedSession(t *testing.T) {
	now := time.Unix(1_800_000_125, 0).UTC()
	store, err := OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	storeFixture(t, store, now, "provider-a", "session-a")

	active, err := store.ActiveKeyModels(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := active["provider-a"]["session-a"]["model-a"]; !ok {
		t.Fatalf("advertised session missing from active map: %#v", active)
	}
	if _, ok := active["provider-a"]["session-b"]["model-a"]; ok {
		t.Fatalf("unadvertised reconnect session became capable: %#v", active)
	}
}

func TestAuthenticatedEmptyAdvertisementRevokesOutstandingReservation(t *testing.T) {
	now := time.Unix(1_800_000_150, 0).UTC()
	store, err := OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	record, identityPublic, envelope, raw := storeFixture(t, store, now, "provider-a", "session-a")
	authority, err := NewAuthority(store, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(identityPublic)}, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := authority.AcceptProviderKeys(context.Background(), "provider-a", "session-a", []KeyRecord{}, now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.LookupKeyRecord(context.Background(), "provider-a", "session-a", record.KID, record.KeyRecordDigest, now.Add(time.Second)); !errors.Is(err, ErrKeyRevoked) {
		t.Fatalf("omitted key lookup=%v", err)
	}
	digest, _ := DigestEnvelopeBytes(raw)
	if _, err := store.Consume(context.Background(), ConsumeInput{AccountID: "acct-a", WalletSession: "wallet-a", Envelope: envelope, EnvelopeDigest: digest, Now: now.Add(time.Second)}); !errors.Is(err, ErrReplay) {
		t.Fatalf("revoked reservation consume=%v, want replay fence", err)
	}
}

func TestKeyRenewalCannotChangeReservationDigest(t *testing.T) {
	now := time.Unix(1_800_000_175, 0).UTC()
	store, err := OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	identityPublic, identityPrivate, _ := ed25519.GenerateKey(nil)
	providerPrivate, _ := ecdh.X25519().GenerateKey(nil)
	record, err := NewSignedKeyRecord(providerPrivate.PublicKey().Bytes(), identityPrivate, []string{"model-a"}, 4096, now.Add(-time.Minute), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	authority, err := NewAuthority(store, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(identityPublic)}, 8)
	if err != nil {
		t.Fatal(err)
	}
	if err := authority.AcceptProviderKeys(context.Background(), "provider-a", "session-a", []KeyRecord{record}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateReservation(context.Background(), ReservationCreate{AccountID: "acct-a", WalletSession: "wallet-a", ProviderID: "provider-a", AssignedSession: "session-a", KeyRecord: record, Model: "model-a", ProviderModel: "model-a", MaxEncryptedRequestBytes: 512, MaxOutputTokens: 32, InputTokenUpperBound: 96, ExpiresAtUnix: now.Add(30 * time.Second).Unix(), MaxActive: 10}, now); err != nil {
		t.Fatal(err)
	}
	renewed, err := NewSignedKeyRecord(providerPrivate.PublicKey().Bytes(), identityPrivate, record.Models, record.MaxEncryptedRequestBytes, time.Unix(record.NotBeforeUnix, 0), time.Unix(record.ExpiresAtUnix+60, 0))
	if err != nil {
		t.Fatal(err)
	}
	if err := authority.AcceptProviderKeys(context.Background(), "provider-a", "session-a", []KeyRecord{renewed}, now); !errors.Is(err, ErrCapacity) {
		t.Fatalf("renewal during reservation=%v, want capacity fence", err)
	}
	stored, err := store.LookupKeyRecord(context.Background(), "provider-a", "session-a", record.KID, record.KeyRecordDigest, now)
	if err != nil || stored.KeyRecordDigest != record.KeyRecordDigest {
		t.Fatalf("stored digest changed: %#v err=%v", stored, err)
	}
}

func TestRevokedKeyPurgeHonorsRetentionAndRestart(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_190, 0).UTC()
	path := filepath.Join(t.TempDir(), "relay-blind.sqlite")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	identityPublic, identityPrivate, _ := ed25519.GenerateKey(nil)
	providerPrivate, _ := ecdh.X25519().GenerateKey(nil)
	record, err := NewSignedKeyRecord(providerPrivate.PublicKey().Bytes(), identityPrivate, []string{"model-a"}, 4096, now.Add(-time.Minute), now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	authority, err := NewAuthority(store, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(identityPublic)}, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := authority.AcceptProviderKeys(ctx, "provider-a", "session-a", []KeyRecord{record}, now); err != nil {
		t.Fatal(err)
	}
	if err := authority.AcceptProviderKeys(ctx, "provider-a", "session-a", []KeyRecord{}, now); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	authority, err = NewAuthority(store, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(identityPublic)}, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	triggerPrivate, _ := ecdh.X25519().GenerateKey(nil)
	trigger, err := NewSignedKeyRecord(triggerPrivate.PublicKey().Bytes(), identityPrivate, []string{"model-a"}, 4096, now.Add(4*time.Minute), now.Add(10*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if err := authority.AcceptProviderKeys(ctx, "provider-a", "session-a", []KeyRecord{trigger}, now.Add(5*time.Minute-time.Second)); err != nil {
		t.Fatal(err)
	}
	var retained int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM relay_blind_key_records WHERE kid=?`, record.KID).Scan(&retained); err != nil || retained != 1 {
		t.Fatalf("before retention count=%d err=%v", retained, err)
	}
	if err := authority.AcceptProviderKeys(ctx, "provider-a", "session-a", []KeyRecord{trigger}, now.Add(5*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM relay_blind_key_records WHERE kid=?`, record.KID).Scan(&retained); err != nil || retained != 0 {
		t.Fatalf("at retention count=%d err=%v", retained, err)
	}
}

func TestStoreRecoveryBurnsConsumedAndDispatched(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_200, 0).UTC()
	path := filepath.Join(t.TempDir(), "relay-blind.sqlite")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	_, _, envelope, raw := storeFixture(t, store, now, "provider-a", "session-a")
	digest, _ := DigestEnvelopeBytes(raw)
	consume, err := store.Consume(ctx, ConsumeInput{AccountID: "acct-a", WalletSession: "wallet-a", Envelope: envelope, EnvelopeDigest: digest, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ArmDispatch(ctx, "acct-a", "wallet-a", consume.ExecutionAuthorization, now); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if changed, err := store.RecoverUncertain(ctx, now.Add(time.Second)); err != nil || changed != 1 {
		t.Fatalf("RecoverUncertain = %d,%v", changed, err)
	}
	status, err := store.LookupReservation(ctx, envelope.ProviderBinding)
	if err != nil || status.State != ReservationStateUnknownPostdispatch || status.EffectivePrivacyOutcome == "relay_blind_satisfied" {
		t.Fatalf("recovered status = %#v, %v", status, err)
	}
}

func TestStoreStatusExpiryFencesDispatchAndPersistsAcrossRestart(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_300, 0).UTC()
	path := filepath.Join(t.TempDir(), "relay-blind.sqlite")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	_, _, envelope, raw := storeFixture(t, store, now, "provider-a", "session-a")
	digest, _ := DigestEnvelopeBytes(raw)
	consume, err := store.Consume(ctx, ConsumeInput{AccountID: "acct-a", WalletSession: "wallet-a", Envelope: envelope, EnvelopeDigest: digest, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	expiry := time.Unix(consume.ExpiresAtUnix, 0)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		if _, err := store.LookupStatus(ctx, "acct-a", "wallet-a", BindingDigest(envelope.ProviderBinding), digest, expiry); err != nil {
			t.Errorf("status at expiry: %v", err)
		}
	}()
	go func() {
		defer wg.Done()
		if _, err := store.ArmDispatch(ctx, "acct-a", "wallet-a", consume.ExecutionAuthorization, expiry); err == nil {
			t.Error("dispatch at expiry unexpectedly succeeded")
		} else if !errors.Is(err, ErrReservationExpired) && !errors.Is(err, ErrReplay) {
			t.Errorf("dispatch at expiry = %v", err)
		}
	}()
	wg.Wait()
	status, err := store.LookupStatus(ctx, "acct-a", "wallet-a", BindingDigest(envelope.ProviderBinding), digest, expiry)
	if err != nil || status.State != ReservationStateRejected {
		t.Fatalf("expired status = %#v, %v", status, err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	status, err = reopened.LookupStatus(ctx, "acct-a", "wallet-a", BindingDigest(envelope.ProviderBinding), digest, expiry.Add(time.Second))
	if err != nil || status.State != ReservationStateRejected {
		t.Fatalf("restarted expired status = %#v, %v", status, err)
	}
}

func TestStoreDispatchImmediatelyBeforeExpiryRemainsIrreversible(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_400, 0).UTC()
	store, err := OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, _, envelope, raw := storeFixture(t, store, now, "provider-a", "session-a")
	digest, _ := DigestEnvelopeBytes(raw)
	consume, err := store.Consume(ctx, ConsumeInput{AccountID: "acct-a", WalletSession: "wallet-a", Envelope: envelope, EnvelopeDigest: digest, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	justBeforeExpiry := time.Unix(consume.ExpiresAtUnix, 0).Add(-time.Nanosecond)
	if _, err := store.ArmDispatch(ctx, "acct-a", "wallet-a", consume.ExecutionAuthorization, justBeforeExpiry); err != nil {
		t.Fatalf("dispatch before expiry: %v", err)
	}
	status, err := store.LookupStatus(ctx, "acct-a", "wallet-a", BindingDigest(envelope.ProviderBinding), digest, time.Unix(consume.ExpiresAtUnix, 0))
	if err != nil || status.State != ReservationStateDispatched {
		t.Fatalf("post-dispatch expiry status = %#v, %v", status, err)
	}
}

func TestStoreEvidenceRequiresOneValidatedFrameAndMatchingTerminalUsage(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_500, 0).UTC()
	store, err := OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, _, envelope, raw := storeFixture(t, store, now, "provider-a", "session-a")
	digest, _ := DigestEnvelopeBytes(raw)
	consume, err := store.Consume(ctx, ConsumeInput{AccountID: "acct-a", WalletSession: "wallet-a", Envelope: envelope, EnvelopeDigest: digest, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := store.ArmDispatch(ctx, "acct-a", "wallet-a", consume.ExecutionAuthorization, now)
	if err != nil {
		t.Fatal(err)
	}
	terminal := fixtureEvidence(reservation, "terminal", 19)
	terminal.CompletionTokens = 7
	if _, err := store.PersistEvidence(ctx, "provider-a", "session-a", terminal, "", now); !errors.Is(err, ErrEvidenceMismatch) {
		t.Fatalf("terminal before validation = %v", err)
	}
	validated := fixtureEvidence(reservation, "validated", 19)
	if _, err := store.PersistEvidence(ctx, "provider-a", "session-a", validated, "", now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.PersistEvidence(ctx, "provider-a", "session-a", validated, "", now); !errors.Is(err, ErrEvidenceMismatch) {
		t.Fatalf("duplicate validation = %v", err)
	}
	terminal.InputTokens = 20
	if _, err := store.PersistEvidence(ctx, "provider-a", "session-a", terminal, "", now); !errors.Is(err, ErrEvidenceMismatch) {
		t.Fatalf("terminal input mismatch = %v", err)
	}
	terminal.InputTokens = 19
	terminal.CompletionTokens = reservation.MaxOutputTokens + 1
	if _, err := store.PersistEvidence(ctx, "provider-a", "session-a", terminal, "", now); !errors.Is(err, ErrEvidenceMismatch) {
		t.Fatalf("terminal output above cap = %v", err)
	}
}

func storeFixture(t *testing.T, store *Store, now time.Time, providerID, assignedSession string) (KeyRecord, ed25519.PublicKey, Envelope, []byte) {
	t.Helper()
	identityPublic, identityPrivate, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	providerPrivate, err := ecdh.X25519().GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	record, err := NewSignedKeyRecord(providerPrivate.PublicKey().Bytes(), identityPrivate, []string{"model-a"}, 4096, now.Add(-time.Minute), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	authority, err := NewAuthority(store, map[string]string{providerID: base64.RawURLEncoding.EncodeToString(identityPublic)}, 8)
	if err != nil {
		t.Fatal(err)
	}
	if err := authority.AcceptProviderKeys(context.Background(), providerID, assignedSession, []KeyRecord{record}, now); err != nil {
		t.Fatal(err)
	}
	created, err := store.CreateReservation(context.Background(), ReservationCreate{AccountID: "acct-a", WalletSession: "wallet-a", ProviderID: providerID, AssignedSession: assignedSession, KeyRecord: record, Model: "model-a", ProviderModel: "model-a", MaxEncryptedRequestBytes: 512, MaxOutputTokens: 32, InputTokenUpperBound: 96, ExpiresAtUnix: now.Add(30 * time.Second).Unix(), MaxActive: 10}, now)
	if err != nil {
		t.Fatal(err)
	}
	response := ReservationResponse{Version: ReservationVersion, ProviderBinding: created.ProviderBinding, BuyerBinding: created.BuyerBinding, KeyRecordDigest: record.KeyRecordDigest, KeyRecord: record, KID: record.KID, EndpointFamily: EndpointChatCompletions, Model: "model-a", ProviderModel: "model-a", MaxEncryptedRequestBytes: 512, MaxOutputTokens: 32, InputTokenUpperBound: 96, ReservationTokenCap: 128, ExpiresAtUnix: created.ExpiresAtUnix, CachePolicy: CachePolicyNoStore, FailoverPolicy: FailoverPolicyDisabled}
	envelope, err := response.NewEnvelope("request-a", now, bytes.Repeat([]byte{0x55}, 32))
	if err != nil {
		t.Fatal(err)
	}
	buyerPrivate, err := ecdh.X25519().GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	envelope, err = envelope.Encrypt([]byte(`{"model":"model-a","messages":[{"role":"user","content":"secret"}]}`), providerPrivate.PublicKey().Bytes(), buyerPrivate.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	return record, identityPublic, envelope, raw
}

func fixtureEvidence(reservation Reservation, state string, inputTokens int64) Evidence {
	return Evidence{ExecutionAuthDigest: reservation.ExecutionAuthDigest, EnvelopeDigest: reservation.EnvelopeDigest, KID: reservation.KID, ProviderBindingDigest: BindingDigest(reservation.ProviderBinding), BuyerBindingDigest: BindingDigest(reservation.BuyerBinding), AssignedSession: reservation.AssignedSession, RequestID: reservation.RequestID, State: state, InputTokens: inputTokens, InputTokenUpperBound: reservation.InputTokenUpperBound, MaxOutputTokens: reservation.MaxOutputTokens}
}
