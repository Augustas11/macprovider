package relayblind

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestKeyClassIsolation(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_000, 0).UTC()
	store, err := OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, identity, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	relayRecord := signedStoreRecord(t, identity, "model-relay", now)
	privacyRecord := signedStoreRecord(t, identity, "model-privacy", now)
	if err := store.UpsertKeyRecord(ctx, "provider-a", "session-a", relayRecord, immutableDigest(t, relayRecord), now, 8, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := store.UpsertKeyRecordClass(ctx, "provider-a", "session-a", privacyRecord, immutableDigest(t, privacyRecord), now, 8, time.Minute, KeyClassPrivacy); err != nil {
		t.Fatal(err)
	}
	if err := store.UpsertKeyRecordClass(ctx, "provider-a", "session-a", privacyRecord, immutableDigest(t, privacyRecord), now, 8, time.Minute, "nope"); err == nil {
		t.Fatal("unknown class upsert succeeded")
	}
	if err := store.RevokeMissingKeys(ctx, "provider-a", nil, now, time.Minute, "nope"); err == nil {
		t.Fatal("unknown class revoke succeeded")
	}
	relayFresh, err := store.FreshKeyRecords(ctx, "provider-a", "session-a", "model-relay", 1, now, KeyClassRelayBlind)
	if err != nil || len(relayFresh) != 1 || relayFresh[0].KID != relayRecord.KID {
		t.Fatalf("relay fresh = %#v, %v", relayFresh, err)
	}
	privacyFresh, err := store.FreshKeyRecords(ctx, "provider-a", "session-a", "model-privacy", 1, now, KeyClassPrivacy)
	if err != nil || len(privacyFresh) != 1 || privacyFresh[0].KID != privacyRecord.KID {
		t.Fatalf("privacy fresh = %#v, %v", privacyFresh, err)
	}
	if crossed, err := store.FreshKeyRecords(ctx, "provider-a", "session-a", "model-privacy", 1, now, KeyClassRelayBlind); err != nil || len(crossed) != 0 {
		t.Fatalf("relay class returned privacy records %#v, %v", crossed, err)
	}
	models, err := store.ActiveKeyModels(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := models["provider-a"]["session-a"]["model-relay"]; !ok {
		t.Fatalf("relay model missing: %#v", models)
	}
	if _, ok := models["provider-a"]["session-a"]["model-privacy"]; ok {
		t.Fatal("privacy model is relay-blind capable")
	}
	relayReservation, err := store.CreateReservation(ctx, ReservationCreate{
		AccountID: "acct-a", WalletSession: "wallet-a", ProviderID: "provider-a", AssignedSession: "session-a",
		KeyRecord: relayRecord, Model: "model-relay", ProviderModel: "model-relay",
		MaxEncryptedRequestBytes: 512, MaxOutputTokens: 32, InputTokenUpperBound: 96,
		ExpiresAtUnix: now.Add(time.Minute).Unix(), MaxActive: 10,
	}, now)
	if err != nil || relayReservation.PrivacyClass {
		t.Fatalf("relay reservation = %+v, %v", relayReservation, err)
	}
	privacyReservation, err := store.CreateReservation(ctx, ReservationCreate{
		AccountID: "acct-b", WalletSession: "wallet-b", ProviderID: "provider-a", AssignedSession: "session-a",
		KeyRecord: privacyRecord, Model: "model-privacy", ProviderModel: "model-privacy",
		MaxEncryptedRequestBytes: 512, MaxOutputTokens: 32, InputTokenUpperBound: 96,
		ExpiresAtUnix: now.Add(time.Minute).Unix(), MaxActive: 10, PrivacyClass: true,
	}, now)
	if err != nil || !privacyReservation.PrivacyClass {
		t.Fatalf("privacy reservation = %+v, %v", privacyReservation, err)
	}
	if err := store.RejectHeldPrivacyPredispatch(ctx, "privacy_class_disabled", now); err != nil {
		t.Fatal(err)
	}
	if state, class := reservationState(t, store, relayReservation.ProviderBinding); state != ReservationStateReserved || class != 0 {
		t.Fatalf("relay reservation after reject = %s class %d", state, class)
	}
	if state, class := reservationState(t, store, privacyReservation.ProviderBinding); state != ReservationStateRejected || class != 1 {
		t.Fatalf("privacy reservation after reject = %s class %d", state, class)
	}
	if err := store.RevokeMissingKeys(ctx, "provider-a", nil, now, time.Minute, KeyClassPrivacy); err != nil {
		t.Fatal(err)
	}
	if left, err := store.FreshKeyRecords(ctx, "provider-a", "session-a", "model-privacy", 1, now, KeyClassPrivacy); err != nil || len(left) != 0 {
		t.Fatalf("privacy keys after revoke = %#v, %v", left, err)
	}
	if left, err := store.FreshKeyRecords(ctx, "provider-a", "session-a", "model-relay", 1, now, KeyClassRelayBlind); err != nil || len(left) != 1 {
		t.Fatalf("relay keys after privacy revoke = %#v, %v", left, err)
	}
}

func TestMigrationIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.sqlite")
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(legacyRelayBlindSchema); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO relay_blind_key_records(provider_id,kid,assigned_session,record_json,key_record_digest,immutable_digest,not_before_unix,expires_at_unix,accepted_at_unix) VALUES('provider-a','kid-a','session-a',X'7b7d','digest-a','immutable-a',1,2,1)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO relay_blind_reservations(provider_binding,buyer_binding,account_id,wallet_session,provider_id,assigned_session,key_record_digest,kid,model,provider_model,stream,max_encrypted_request_bytes,max_output_tokens,input_token_upper_bound,reservation_token_cap,expires_at_unix,state,created_at_unix) VALUES('pb','bb','acct','wallet','provider-a','session-a','digest-a','kid-a','model-a','model-a',0,1,1,1,1,10,'reserved',1)`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	assertLegacyPrivacyColumns(t, store)
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	assertLegacyPrivacyColumns(t, reopened)
}

func assertLegacyPrivacyColumns(t *testing.T, store *Store) {
	t.Helper()
	var class string
	if err := store.db.QueryRow(`SELECT key_class FROM relay_blind_key_records WHERE kid='kid-a'`).Scan(&class); err != nil || class != KeyClassRelayBlind {
		t.Fatalf("key_class = %q, %v", class, err)
	}
	var privacyClass int
	var providerID string
	if err := store.db.QueryRow(`SELECT privacy_class, provider_id FROM relay_blind_reservations WHERE provider_binding='pb'`).Scan(&privacyClass, &providerID); err != nil || privacyClass != 0 || providerID != "provider-a" {
		t.Fatalf("privacy_class = %d provider %q, %v", privacyClass, providerID, err)
	}
	var tables int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('privacy_class_quarantine','privacy_class_control')`).Scan(&tables); err != nil || tables != 2 {
		t.Fatalf("privacy tables = %d, %v", tables, err)
	}
}

func TestPrivacyBoundRejectionEvidence(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_000, 0).UTC()
	store := openPrivacyStore(t)
	privacy := dispatchedClassReservation(t, store, now, "provider-a", "session-a", "acct-privacy", "privacy-reject", true)
	plain := dispatchedClassReservation(t, store, now, "provider-a", "session-a", "acct-plain", "plain-reject", false)
	for _, code := range []string{"privacy_class_posture_stale", "privacy_class_downgrade_rejected"} {
		evidence := fixtureEvidence(privacy, "rejected", 0)
		evidence.ErrorCode = code
		got, err := store.PersistEvidence(ctx, privacy.ProviderID, privacy.AssignedSession, evidence, "", now)
		if err != nil || got.State != ReservationStateRejected || !got.PrivacyClass {
			t.Fatalf("%s persist = %+v, %v", code, got, err)
		}
		state, terminal := reservationTerminal(t, store, privacy.ProviderBinding)
		if state != ReservationStateRejected || terminal != code {
			t.Fatalf("%s row state=%s code=%s", code, state, terminal)
		}
		privacy = dispatchedClassReservation(t, store, now, "provider-a", "session-a", "acct-privacy-"+code, "privacy-"+code, true)
		plainEvidence := fixtureEvidence(plain, "rejected", 0)
		plainEvidence.ErrorCode = code
		if _, err := store.PersistEvidence(ctx, plain.ProviderID, plain.AssignedSession, plainEvidence, "", now); !errors.Is(err, ErrEvidenceMismatch) {
			t.Fatalf("non-privacy %s = %v", code, err)
		}
		state, terminal = reservationTerminal(t, store, plain.ProviderBinding)
		if state != ReservationStateDispatched || terminal != "" {
			t.Fatalf("non-privacy %s row state=%s code=%s", code, state, terminal)
		}
	}
	kept := fixtureEvidence(plain, "rejected", 0)
	kept.ErrorCode = "relay_blind_ciphertext_invalid"
	got, err := store.PersistEvidence(ctx, plain.ProviderID, plain.AssignedSession, kept, "", now)
	if err != nil || got.State != ReservationStateRejected || got.PrivacyClass {
		t.Fatalf("ciphertext rejection = %+v, %v", got, err)
	}
	if _, code := reservationTerminal(t, store, plain.ProviderBinding); code != "relay_blind_ciphertext_invalid" {
		t.Fatalf("ciphertext terminal code = %s", code)
	}
}

func TestQuarantineAndRevokePrivacyIsAtomic(t *testing.T) {
	now := time.Unix(1_800_000_000, 0).UTC()
	ctx := context.Background()
	store := openPrivacyStore(t)
	_, identity, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	privacyKey := signedStoreRecord(t, identity, "model-privacy", now)
	relayKey := signedStoreRecord(t, identity, "model-relay", now)
	if err := store.UpsertKeyRecordClass(ctx, "provider-a", "session-a", privacyKey, immutableDigest(t, privacyKey), now, 8, time.Minute, KeyClassPrivacy); err != nil {
		t.Fatal(err)
	}
	if err := store.UpsertKeyRecord(ctx, "provider-a", "session-a", relayKey, immutableDigest(t, relayKey), now, 8, time.Minute); err != nil {
		t.Fatal(err)
	}
	reserved := mustReserve(t, store, privacyKey, "acct-reserved", true, now)
	consumed := mustReserve(t, store, privacyKey, "acct-consumed", true, now)
	dispatched := mustReserve(t, store, privacyKey, "acct-dispatched", true, now)
	relayReserved := mustReserve(t, store, relayKey, "acct-relay", false, now)
	if _, err := store.db.Exec(`UPDATE relay_blind_reservations SET state='consumed_predispatch' WHERE provider_binding=?`, consumed.ProviderBinding); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE relay_blind_reservations SET state='dispatched' WHERE provider_binding=?`, dispatched.ProviderBinding); err != nil {
		t.Fatal(err)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if err := store.QuarantineAndRevokePrivacy(cancelled, "provider-a", "review", now, time.Hour, time.Minute); err == nil {
		t.Fatal("cancelled quarantine committed")
	}
	if quarantined, err := store.IsQuarantined(ctx, "provider-a", now); err != nil || quarantined {
		t.Fatalf("quarantined after cancel = %v, %v", quarantined, err)
	}
	if revoked, _, _ := keyRevocation(t, store, privacyKey.KID); revoked {
		t.Fatal("cancelled quarantine revoked a privacy key")
	}
	if state, _ := reservationState(t, store, reserved.ProviderBinding); state != ReservationStateReserved {
		t.Fatalf("reserved after cancel = %s", state)
	}
	if err := store.QuarantineAndRevokePrivacy(ctx, "provider-a", "review", now, time.Hour, time.Minute); err != nil {
		t.Fatal(err)
	}
	if quarantined, err := store.IsQuarantined(ctx, "provider-a", now); err != nil || !quarantined {
		t.Fatalf("quarantined = %v, %v", quarantined, err)
	}
	revoked, revokedAt, retained := keyRevocation(t, store, privacyKey.KID)
	if !revoked || revokedAt != now.Unix() || retained != privacyKey.ExpiresAtUnix {
		t.Fatalf("privacy revocation revoked=%v at=%d retained=%d expires=%d", revoked, revokedAt, retained, privacyKey.ExpiresAtUnix)
	}
	if revoked, _, _ := keyRevocation(t, store, relayKey.KID); revoked {
		t.Fatal("quarantine revoked the relay-blind key")
	}
	for _, binding := range []string{reserved.ProviderBinding, consumed.ProviderBinding} {
		state, code := reservationTerminal(t, store, binding)
		if state != ReservationStateRejected || code != "relay_blind_key_expired" {
			t.Fatalf("predispatch %s state=%s code=%s", binding, state, code)
		}
	}
	if state, _ := reservationState(t, store, dispatched.ProviderBinding); state != ReservationStateDispatched {
		t.Fatalf("dispatched privacy reservation = %s", state)
	}
	if state, _ := reservationState(t, store, relayReserved.ProviderBinding); state != ReservationStateReserved {
		t.Fatalf("relay reservation = %s", state)
	}
}

func TestDisablePrivacyAndRejectPredispatchIsAtomic(t *testing.T) {
	now := time.Unix(1_800_000_000, 0).UTC()
	ctx := context.Background()
	store := openPrivacyStore(t)
	privacy := mustReserve(t, store, KeyRecord{KID: "kid-privacy", KeyRecordDigest: "digest-privacy"}, "acct-privacy", true, now)
	relay := mustReserve(t, store, KeyRecord{KID: "kid-relay", KeyRecordDigest: "digest-relay"}, "acct-relay", false, now)
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if err := store.DisablePrivacyAndRejectPredispatch(cancelled, "maintenance", now); err == nil {
		t.Fatal("cancelled disable committed")
	}
	if disabled, err := store.PrivacyDisabled(ctx); err != nil || disabled {
		t.Fatalf("disabled after cancel = %v, %v", disabled, err)
	}
	if state, _ := reservationState(t, store, privacy.ProviderBinding); state != ReservationStateReserved {
		t.Fatalf("privacy after cancel = %s", state)
	}
	if err := store.DisablePrivacyAndRejectPredispatch(ctx, "maintenance", now); err != nil {
		t.Fatal(err)
	}
	if disabled, err := store.PrivacyDisabled(ctx); err != nil || !disabled {
		t.Fatalf("disabled = %v, %v", disabled, err)
	}
	state, code := reservationTerminal(t, store, privacy.ProviderBinding)
	if state != ReservationStateRejected || code != "privacy_class_disabled" {
		t.Fatalf("privacy disable state=%s code=%s", state, code)
	}
	if state, _ := reservationState(t, store, relay.ProviderBinding); state != ReservationStateReserved {
		t.Fatalf("relay after disable = %s", state)
	}
	if err := store.SetPrivacyDisabled(ctx, false, "enabled", now); err != nil {
		t.Fatal(err)
	}
	if disabled, err := store.PrivacyDisabled(ctx); err != nil || disabled {
		t.Fatalf("enabled = %v, %v", disabled, err)
	}
	if state, _ := reservationState(t, store, relay.ProviderBinding); state != ReservationStateReserved {
		t.Fatalf("relay after enable = %s", state)
	}
}

func TestKeyClassIsImmutableAndRevocationIsIsolated(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1_800_000_000, 0).UTC()
	store := openPrivacyStore(t)
	_, identity, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	privacyKey := signedStoreRecord(t, identity, "model-privacy", now)
	relayKey := signedStoreRecord(t, identity, "model-relay", now)
	if err := store.UpsertKeyRecordClass(ctx, "provider-a", "session-a", privacyKey, immutableDigest(t, privacyKey), now, 8, time.Minute, KeyClassPrivacy); err != nil {
		t.Fatal(err)
	}
	if err := store.UpsertKeyRecord(ctx, "provider-a", "session-a", relayKey, immutableDigest(t, relayKey), now, 8, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := store.UpsertKeyRecordClass(ctx, "provider-a", "session-a", privacyKey, immutableDigest(t, privacyKey), now, 8, time.Minute, KeyClassRelayBlind); !errors.Is(err, ErrReservationMismatch) {
		t.Fatalf("cross-class upsert = %v", err)
	}
	class, digest := keyClassDigest(t, store, privacyKey.KID)
	if class != KeyClassPrivacy || digest != privacyKey.KeyRecordDigest {
		t.Fatalf("privacy key after cross-class upsert class=%s digest=%s", class, digest)
	}
	if err := store.UpsertKeyRecordClass(ctx, "provider-a", "session-a", privacyKey, immutableDigest(t, privacyKey), now, 8, time.Minute, KeyClassPrivacy); err != nil {
		t.Fatalf("same-class refresh = %v", err)
	}
	privacyReservation := mustReserve(t, store, privacyKey, "acct-privacy", true, now)
	relayReservation := mustReserve(t, store, relayKey, "acct-relay", false, now)
	sameKidRelayReservation := mustReserve(t, store, privacyKey, "acct-same-kid", false, now)
	if err := store.RevokeMissingKeys(ctx, "provider-a", nil, now, time.Minute, KeyClassRelayBlind); err != nil {
		t.Fatal(err)
	}
	if revoked, _, _ := keyRevocation(t, store, relayKey.KID); !revoked {
		t.Fatal("relay key was not revoked")
	}
	if revoked, _, _ := keyRevocation(t, store, privacyKey.KID); revoked {
		t.Fatal("relay revocation revoked the privacy key")
	}
	if state, _ := reservationState(t, store, relayReservation.ProviderBinding); state != ReservationStateRejected {
		t.Fatalf("relay reservation = %s", state)
	}
	if state, _ := reservationState(t, store, privacyReservation.ProviderBinding); state != ReservationStateReserved {
		t.Fatalf("privacy reservation after relay revoke = %s", state)
	}
	if state, classFlag := reservationState(t, store, sameKidRelayReservation.ProviderBinding); state != ReservationStateReserved || classFlag != 0 {
		t.Fatalf("same-kid relay reservation = %s class %d", state, classFlag)
	}
	if err := store.RevokeMissingKeys(ctx, "provider-a", nil, now, time.Minute, KeyClassPrivacy); err != nil {
		t.Fatal(err)
	}
	if state, _ := reservationState(t, store, privacyReservation.ProviderBinding); state != ReservationStateRejected {
		t.Fatalf("privacy reservation after privacy revoke = %s", state)
	}
	if state, _ := reservationState(t, store, sameKidRelayReservation.ProviderBinding); state != ReservationStateReserved {
		t.Fatalf("same-kid relay reservation after privacy revoke = %s", state)
	}
	if revoked, _, _ := keyRevocation(t, store, privacyKey.KID); !revoked {
		t.Fatal("privacy key was not revoked")
	}
}

func openPrivacyStore(t *testing.T) *Store {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func mustReserve(t *testing.T, store *Store, record KeyRecord, account string, privacy bool, now time.Time) Reservation {
	t.Helper()
	created, err := store.CreateReservation(context.Background(), ReservationCreate{
		AccountID: account, WalletSession: "wallet-a", ProviderID: "provider-a", AssignedSession: "session-a",
		KeyRecord: record, Model: "model-a", ProviderModel: "model-a",
		MaxEncryptedRequestBytes: 512, MaxOutputTokens: 32, InputTokenUpperBound: 96,
		ExpiresAtUnix: now.Add(time.Minute).Unix(), MaxActive: 20, PrivacyClass: privacy,
	}, now)
	if err != nil {
		t.Fatal(err)
	}
	return created
}

func reservationTerminal(t *testing.T, store *Store, binding string) (string, string) {
	t.Helper()
	var state, code string
	if err := store.db.QueryRow(`SELECT state, COALESCE(terminal_code,'') FROM relay_blind_reservations WHERE provider_binding=?`, binding).Scan(&state, &code); err != nil {
		t.Fatal(err)
	}
	return state, code
}

func keyRevocation(t *testing.T, store *Store, kid string) (bool, int64, int64) {
	t.Helper()
	var revoked, retained sql.NullInt64
	if err := store.db.QueryRow(`SELECT revoked_at_unix, revocation_retained_until_unix FROM relay_blind_key_records WHERE kid=?`, kid).Scan(&revoked, &retained); err != nil {
		t.Fatal(err)
	}
	return revoked.Valid, revoked.Int64, retained.Int64
}

func keyClassDigest(t *testing.T, store *Store, kid string) (string, string) {
	t.Helper()
	var class, digest string
	if err := store.db.QueryRow(`SELECT key_class, key_record_digest FROM relay_blind_key_records WHERE kid=?`, kid).Scan(&class, &digest); err != nil {
		t.Fatal(err)
	}
	return class, digest
}

func dispatchedClassReservation(t *testing.T, store *Store, now time.Time, providerID, session, account, requestID string, privacy bool) Reservation {
	t.Helper()
	ctx := context.Background()
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
	class := KeyClassRelayBlind
	if privacy {
		class = KeyClassPrivacy
	}
	if err := store.UpsertKeyRecordClass(ctx, providerID, session, record, immutableDigest(t, record), now, 8, time.Minute, class); err != nil {
		t.Fatal(err)
	}
	created, err := store.CreateReservation(ctx, ReservationCreate{
		AccountID: account, WalletSession: "wallet-a", ProviderID: providerID, AssignedSession: session,
		KeyRecord: record, Model: "model-a", ProviderModel: "model-a", Stream: privacy,
		MaxEncryptedRequestBytes: 512, MaxOutputTokens: 32, InputTokenUpperBound: 96,
		ExpiresAtUnix: now.Add(30 * time.Second).Unix(), MaxActive: 20, PrivacyClass: privacy,
	}, now)
	if err != nil {
		t.Fatal(err)
	}
	response := ReservationResponse{
		Version: ReservationVersion, ProviderBinding: created.ProviderBinding, BuyerBinding: created.BuyerBinding,
		KeyRecordDigest: record.KeyRecordDigest, KeyRecord: record, KID: record.KID, EndpointFamily: EndpointChatCompletions,
		Model: "model-a", ProviderModel: "model-a", Stream: privacy, MaxEncryptedRequestBytes: 512, MaxOutputTokens: 32,
		InputTokenUpperBound: 96, ReservationTokenCap: 128, ExpiresAtUnix: created.ExpiresAtUnix,
		CachePolicy: CachePolicyNoStore, FailoverPolicy: FailoverPolicyDisabled,
	}
	envelope, err := response.NewEnvelope(requestID, now, bytes.Repeat([]byte{0x55}, 32))
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
	digest, err := DigestEnvelopeBytes(raw)
	if err != nil {
		t.Fatal(err)
	}
	consume, err := store.Consume(ctx, ConsumeInput{AccountID: account, WalletSession: "wallet-a", Envelope: envelope, EnvelopeDigest: digest, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := store.ArmDispatch(ctx, account, "wallet-a", consume.ExecutionAuthorization, now)
	if err != nil {
		t.Fatal(err)
	}
	if reservation.PrivacyClass != privacy {
		t.Fatalf("dispatched privacy flag = %v", reservation.PrivacyClass)
	}
	_ = identityPublic
	return reservation
}

func reservationState(t *testing.T, store *Store, binding string) (string, int) {
	t.Helper()
	var state string
	var class int
	if err := store.db.QueryRow(`SELECT state, privacy_class FROM relay_blind_reservations WHERE provider_binding=?`, binding).Scan(&state, &class); err != nil {
		t.Fatal(err)
	}
	return state, class
}

func signedStoreRecord(t *testing.T, identity ed25519.PrivateKey, model string, now time.Time) KeyRecord {
	t.Helper()
	provider, err := ecdh.X25519().GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	record, err := NewSignedKeyRecord(provider.PublicKey().Bytes(), identity, []string{model}, 4096, now.Add(-time.Minute), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	return record
}

func immutableDigest(t *testing.T, record KeyRecord) string {
	t.Helper()
	framing, err := record.ImmutableFraming()
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(framing)
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

const legacyRelayBlindSchema = `
CREATE TABLE relay_blind_key_records (
  provider_id TEXT NOT NULL,
  kid TEXT NOT NULL,
  assigned_session TEXT NOT NULL,
  record_json BLOB NOT NULL,
  key_record_digest TEXT NOT NULL,
  immutable_digest TEXT NOT NULL,
  not_before_unix INTEGER NOT NULL,
  expires_at_unix INTEGER NOT NULL,
  accepted_at_unix INTEGER NOT NULL,
  revoked_at_unix INTEGER NULL,
  revocation_retained_until_unix INTEGER NULL,
  PRIMARY KEY(provider_id,kid)
);
CREATE UNIQUE INDEX idx_relay_blind_key_digest ON relay_blind_key_records(provider_id,key_record_digest);
CREATE INDEX idx_relay_blind_key_expiry ON relay_blind_key_records(expires_at_unix);
CREATE TABLE relay_blind_reservations (
  provider_binding TEXT PRIMARY KEY,
  buyer_binding TEXT NOT NULL UNIQUE,
  account_id TEXT NOT NULL,
  wallet_session TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  assigned_session TEXT NOT NULL,
  key_record_digest TEXT NOT NULL,
  kid TEXT NOT NULL,
  model TEXT NOT NULL,
  provider_model TEXT NOT NULL,
  stream INTEGER NOT NULL CHECK(stream IN (0,1)),
  max_encrypted_request_bytes INTEGER NOT NULL CHECK(max_encrypted_request_bytes > 0),
  max_output_tokens INTEGER NOT NULL CHECK(max_output_tokens > 0),
  input_token_upper_bound INTEGER NOT NULL CHECK(input_token_upper_bound > 0),
  reservation_token_cap INTEGER NOT NULL CHECK(reservation_token_cap > 0),
  expires_at_unix INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('reserved','consumed_predispatch','dispatched','terminal','rejected','unknown_postdispatch')),
  envelope_digest TEXT NULL UNIQUE,
  execution_auth_digest TEXT NULL UNIQUE,
  request_id TEXT NULL,
  validated_input_tokens INTEGER NULL CHECK(validated_input_tokens IS NULL OR validated_input_tokens >= 0),
  effective_privacy_outcome TEXT NOT NULL DEFAULT 'relay_blind_unavailable',
  terminal_code TEXT NULL,
  internal_request_id TEXT NULL,
  completion_tokens INTEGER NULL CHECK(completion_tokens IS NULL OR completion_tokens >= 0),
  created_at_unix INTEGER NOT NULL,
  consumed_at_unix INTEGER NULL,
  dispatched_at_unix INTEGER NULL,
  validated_at_unix INTEGER NULL,
  terminal_at_unix INTEGER NULL
);
CREATE INDEX idx_relay_blind_reservation_expiry ON relay_blind_reservations(state,expires_at_unix);
CREATE INDEX idx_relay_blind_reservation_session ON relay_blind_reservations(provider_id,assigned_session,state);
CREATE INDEX idx_relay_blind_reservation_account ON relay_blind_reservations(account_id,wallet_session,state);
`
