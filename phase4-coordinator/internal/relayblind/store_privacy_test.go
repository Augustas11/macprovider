package relayblind

import (
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
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
