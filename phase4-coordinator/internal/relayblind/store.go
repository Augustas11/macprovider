package relayblind

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const (
	ReservationStateReserved            = "reserved"
	ReservationStateConsumedPredispatch = "consumed_predispatch"
	ReservationStateDispatched          = "dispatched"
	ReservationStateTerminal            = "terminal"
	ReservationStateRejected            = "rejected"
	ReservationStateUnknownPostdispatch = "unknown_postdispatch"

	KeyClassRelayBlind = "relay_blind"
	KeyClassPrivacy    = "privacy"
)

var (
	ErrStoreUnavailable    = errors.New("relayblind: durable store unavailable")
	ErrReplay              = errors.New("relayblind: reservation already consumed")
	ErrReservationExpired  = errors.New("relayblind: reservation expired")
	ErrReservationMismatch = errors.New("relayblind: reservation binding mismatch")
	ErrKeyRevoked          = errors.New("relayblind: key revoked")
	ErrStaleSession        = errors.New("relayblind: provider session stale")
	ErrCapacity            = errors.New("relayblind: reservation capacity exhausted")
	ErrEvidenceMismatch    = errors.New("relayblind: provider evidence mismatch")
)

type Store struct {
	db *sql.DB
}

type Reservation struct {
	ProviderBinding          string
	BuyerBinding             string
	AccountID                string
	WalletSession            string
	ProviderID               string
	AssignedSession          string
	KeyRecordDigest          string
	KID                      string
	Model                    string
	ProviderModel            string
	Stream                   bool
	MaxEncryptedRequestBytes int64
	MaxOutputTokens          int64
	InputTokenUpperBound     int64
	ReservationTokenCap      int64
	ExpiresAtUnix            int64
	State                    string
	EnvelopeDigest           string
	ExecutionAuthDigest      string
	RequestID                string
	ValidatedInputTokens     *int64
	EffectivePrivacyOutcome  string
	InternalRequestID        string
	CompletionTokens         *int64
	PrivacyClass             bool
}

// KeySession is one provider session that currently holds a fresh key of a class.
type KeySession struct {
	ProviderID      string
	AssignedSession string
}

type ReservationCreate struct {
	AccountID                string
	WalletSession            string
	ProviderID               string
	AssignedSession          string
	KeyRecord                KeyRecord
	Model                    string
	ProviderModel            string
	Stream                   bool
	MaxEncryptedRequestBytes int64
	MaxOutputTokens          int64
	InputTokenUpperBound     int64
	ExpiresAtUnix            int64
	MaxActive                int
	ReplayRetention          time.Duration
	PrivacyClass             bool
}

type ConsumeInput struct {
	AccountID      string
	WalletSession  string
	Envelope       Envelope
	EnvelopeDigest string
	Now            time.Time
}

type Evidence struct {
	ExecutionAuthDigest   string `json:"execution_auth_digest"`
	EnvelopeDigest        string `json:"envelope_digest"`
	KID                   string `json:"kid"`
	ProviderBindingDigest string `json:"provider_binding_digest"`
	BuyerBindingDigest    string `json:"buyer_binding_digest"`
	AssignedSession       string `json:"assigned_session"`
	RequestID             string `json:"request_id"`
	State                 string `json:"state"`
	InputTokens           int64  `json:"input_tokens"`
	InputTokenUpperBound  int64  `json:"input_token_upper_bound"`
	MaxOutputTokens       int64  `json:"max_output_tokens"`
	CompletionTokens      int64  `json:"-"`
	ErrorCode             string `json:"error_code,omitempty"`
}

func OpenStore(path string) (*Store, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil, fmt.Errorf("%w: path is required", ErrStoreUnavailable)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("%w: create directory: %v", ErrStoreUnavailable, err)
	}
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func NewStore(db *sql.DB) (*Store, error) {
	if db == nil {
		return nil, ErrStoreUnavailable
	}
	s := &Store{db: db}
	if err := s.migrate(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *Store) migrate(ctx context.Context) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	var mode string
	if err := s.db.QueryRowContext(ctx, `PRAGMA journal_mode=WAL`).Scan(&mode); err != nil {
		return fmt.Errorf("%w: enable WAL: %v", ErrStoreUnavailable, err)
	}
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS relay_blind_key_records (
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
  key_class TEXT NOT NULL DEFAULT 'relay_blind',
  PRIMARY KEY(provider_id,kid)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_relay_blind_key_digest ON relay_blind_key_records(provider_id,key_record_digest);
CREATE INDEX IF NOT EXISTS idx_relay_blind_key_expiry ON relay_blind_key_records(expires_at_unix);

CREATE TABLE IF NOT EXISTS relay_blind_reservations (
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
  terminal_at_unix INTEGER NULL,
  privacy_class INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_relay_blind_reservation_expiry ON relay_blind_reservations(state,expires_at_unix);
CREATE INDEX IF NOT EXISTS idx_relay_blind_reservation_session ON relay_blind_reservations(provider_id,assigned_session,state);
CREATE INDEX IF NOT EXISTS idx_relay_blind_reservation_account ON relay_blind_reservations(account_id,wallet_session,state);
`)
	if err != nil {
		return fmt.Errorf("%w: migrate: %v", ErrStoreUnavailable, err)
	}
	return s.ensurePrivacySchema(ctx)
}

func (s *Store) UpsertKeyRecord(ctx context.Context, providerID, assignedSession string, record KeyRecord, immutableDigest string, now time.Time, maxRecords int, replayRetention time.Duration) error {
	return s.UpsertKeyRecordClass(ctx, providerID, assignedSession, record, immutableDigest, now, maxRecords, replayRetention, KeyClassRelayBlind)
}

func (s *Store) UpsertKeyRecordClass(ctx context.Context, providerID, assignedSession string, record KeyRecord, immutableDigest string, now time.Time, maxRecords int, replayRetention time.Duration, class string) error {
	if err := validKeyClass(class); err != nil {
		return err
	}
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	raw, err := json.Marshal(record)
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	if replayRetention <= 0 {
		replayRetention = 5 * time.Minute
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM relay_blind_key_records AS keys
WHERE ((keys.revoked_at_unix IS NOT NULL AND COALESCE(keys.revocation_retained_until_unix,keys.expires_at_unix+?)<=?)
    OR (keys.revoked_at_unix IS NULL AND keys.expires_at_unix+?<=?))
  AND NOT EXISTS (
      SELECT 1 FROM relay_blind_reservations reservations
       WHERE reservations.provider_id=keys.provider_id
         AND reservations.kid=keys.kid
         AND reservations.key_record_digest=keys.key_record_digest
  )`, int64(replayRetention/time.Second), now.Unix(), int64(replayRetention/time.Second), now.Unix()); err != nil {
		return fmt.Errorf("%w: purge key records: %v", ErrStoreUnavailable, err)
	}
	var existingImmutable, existingDigest, existingClass string
	var existingExpiry int64
	err = tx.QueryRowContext(ctx, `SELECT immutable_digest,key_record_digest,expires_at_unix,key_class FROM relay_blind_key_records WHERE provider_id=? AND kid=?`, providerID, record.KID).Scan(&existingImmutable, &existingDigest, &existingExpiry, &existingClass)
	if err == nil {
		// key_class is immutable on the shared (provider_id, kid) primary key.
		// A cross-class advertisement must not rewrite the row.
		if existingClass != class || existingImmutable != immutableDigest || record.ExpiresAtUnix < existingExpiry {
			return ErrReservationMismatch
		}
		if existingDigest != record.KeyRecordDigest {
			var active int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM relay_blind_reservations WHERE provider_id=? AND kid=? AND key_record_digest=? AND state IN ('reserved','consumed_predispatch','dispatched')`, providerID, record.KID, existingDigest).Scan(&active); err != nil {
				return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
			}
			if active > 0 {
				return ErrCapacity
			}
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	} else {
		var count int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM relay_blind_key_records WHERE provider_id=? AND expires_at_unix>? AND key_class=?`, providerID, now.Unix(), class).Scan(&count); err != nil {
			return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		if maxRecords > 0 && count >= maxRecords {
			return ErrCapacity
		}
	}
	result, err := tx.ExecContext(ctx, `INSERT INTO relay_blind_key_records(provider_id,kid,assigned_session,record_json,key_record_digest,immutable_digest,not_before_unix,expires_at_unix,accepted_at_unix,key_class)
VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(provider_id,kid) DO UPDATE SET assigned_session=excluded.assigned_session,record_json=excluded.record_json,key_record_digest=excluded.key_record_digest,not_before_unix=excluded.not_before_unix,expires_at_unix=excluded.expires_at_unix,accepted_at_unix=excluded.accepted_at_unix
WHERE relay_blind_key_records.revoked_at_unix IS NULL`, providerID, record.KID, assignedSession, raw, record.KeyRecordDigest, immutableDigest, record.NotBeforeUnix, record.ExpiresAtUnix, now.Unix(), class)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if changed != 1 {
		return ErrKeyRevoked
	}
	return tx.Commit()
}

func (s *Store) ExistingKeyRecord(ctx context.Context, providerID, kid string) (KeyRecord, bool, error) {
	var raw []byte
	err := s.db.QueryRowContext(ctx, `SELECT record_json FROM relay_blind_key_records WHERE provider_id=? AND kid=? AND revoked_at_unix IS NULL`, providerID, kid).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return KeyRecord{}, false, nil
	}
	if err != nil {
		return KeyRecord{}, false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	record, err := ParseKeyRecord(raw)
	if err != nil {
		return KeyRecord{}, false, fmt.Errorf("%w: corrupt key record", ErrStoreUnavailable)
	}
	return record, true, nil
}

func (s *Store) RevokeKey(ctx context.Context, providerID, kid string, now time.Time, replayRetention time.Duration) error {
	retainedUntil := now.Add(replayRetention).Unix()
	_, err := s.db.ExecContext(ctx, `UPDATE relay_blind_key_records SET revoked_at_unix=COALESCE(revoked_at_unix,?), revocation_retained_until_unix=MAX(expires_at_unix,?) WHERE provider_id=? AND kid=?`, now.Unix(), retainedUntil, providerID, kid)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	_, err = s.db.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code='relay_blind_key_expired',terminal_at_unix=? WHERE provider_id=? AND kid=? AND state IN ('reserved','consumed_predispatch')`, now.Unix(), providerID, kid)
	return err
}

// RevokeMissingKeys treats an authenticated provider advertisement as the
// complete active key set. This makes the provider's durable local revoke
// command effective at the coordinator on its next hello or heartbeat,
// including an explicitly advertised empty array.
func (s *Store) RevokeMissingKeys(ctx context.Context, providerID string, activeKids []string, now time.Time, replayRetention time.Duration, class string) error {
	if err := validKeyClass(class); err != nil {
		return err
	}
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	active := make(map[string]struct{}, len(activeKids))
	for _, kid := range activeKids {
		active[kid] = struct{}{}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	privacyFlag := reservationPrivacyFlag(class)
	rows, err := tx.QueryContext(ctx, `SELECT kid,expires_at_unix FROM relay_blind_key_records WHERE provider_id=? AND revoked_at_unix IS NULL AND key_class=?`, providerID, class)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	type omittedKey struct {
		kid     string
		expires int64
	}
	var omitted []omittedKey
	for rows.Next() {
		var item omittedKey
		if err := rows.Scan(&item.kid, &item.expires); err != nil {
			rows.Close()
			return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		if _, ok := active[item.kid]; !ok {
			omitted = append(omitted, item)
		}
	}
	if err := rows.Close(); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	for _, item := range omitted {
		retainedUntil := now.Add(replayRetention).Unix()
		if item.expires > retainedUntil {
			retainedUntil = item.expires
		}
		if _, err := tx.ExecContext(ctx, `UPDATE relay_blind_key_records SET revoked_at_unix=?,revocation_retained_until_unix=? WHERE provider_id=? AND kid=? AND key_class=? AND revoked_at_unix IS NULL`, now.Unix(), retainedUntil, providerID, item.kid, class); err != nil {
			return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		if _, err := tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code='relay_blind_key_expired',terminal_at_unix=? WHERE provider_id=? AND kid=? AND privacy_class=? AND state IN ('reserved','consumed_predispatch')`, now.Unix(), providerID, item.kid, privacyFlag); err != nil {
			return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return nil
}

func (s *Store) FreshKeyRecords(ctx context.Context, providerID, assignedSession, model string, encryptedBytes int64, now time.Time, class string) ([]KeyRecord, error) {
	if err := validKeyClass(class); err != nil {
		return nil, err
	}
	if s == nil || s.db == nil {
		return nil, ErrStoreUnavailable
	}
	rows, err := s.db.QueryContext(ctx, `SELECT record_json FROM relay_blind_key_records WHERE provider_id=? AND assigned_session=? AND revoked_at_unix IS NULL AND not_before_unix<=? AND expires_at_unix>? AND key_class=? ORDER BY expires_at_unix DESC,kid`, providerID, assignedSession, now.Unix(), now.Unix(), class)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer rows.Close()
	var out []KeyRecord
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		record, err := ParseKeyRecord(raw)
		if err != nil {
			return nil, fmt.Errorf("%w: corrupt key record", ErrStoreUnavailable)
		}
		if int64(record.MaxEncryptedRequestBytes) < encryptedBytes || !containsString(record.Models, model) || !containsString(record.EndpointFamilies, EndpointChatCompletions) {
			continue
		}
		out = append(out, record)
	}
	return out, rows.Err()
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func (s *Store) CreateReservation(ctx context.Context, in ReservationCreate, now time.Time) (Reservation, error) {
	providerBinding, err := randomBinding()
	if err != nil {
		return Reservation{}, err
	}
	buyerBinding, err := randomBinding()
	if err != nil {
		return Reservation{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code='relay_blind_key_expired',terminal_at_unix=? WHERE expires_at_unix<=? AND state IN ('reserved','consumed_predispatch')`, now.Unix(), now.Unix()); err != nil {
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	retention := in.ReplayRetention
	if retention <= 0 {
		retention = 5 * time.Minute
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM relay_blind_reservations WHERE state IN ('terminal','rejected','unknown_postdispatch') AND COALESCE(terminal_at_unix,expires_at_unix)+?<=?`, int64(retention/time.Second), now.Unix()); err != nil {
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if in.MaxActive > 0 {
		var count int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM relay_blind_reservations WHERE state IN ('reserved','consumed_predispatch','dispatched') AND expires_at_unix>?`, now.Unix()).Scan(&count); err != nil {
			return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		if count >= in.MaxActive {
			return Reservation{}, ErrCapacity
		}
		var total int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM relay_blind_reservations`).Scan(&total); err != nil {
			return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		if total >= in.MaxActive*4 {
			return Reservation{}, ErrCapacity
		}
	}
	cap := in.InputTokenUpperBound + in.MaxOutputTokens
	_, err = tx.ExecContext(ctx, `INSERT INTO relay_blind_reservations(provider_binding,buyer_binding,account_id,wallet_session,provider_id,assigned_session,key_record_digest,kid,model,provider_model,stream,max_encrypted_request_bytes,max_output_tokens,input_token_upper_bound,reservation_token_cap,expires_at_unix,state,created_at_unix,privacy_class) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, providerBinding, buyerBinding, in.AccountID, in.WalletSession, in.ProviderID, in.AssignedSession, in.KeyRecord.KeyRecordDigest, in.KeyRecord.KID, in.Model, in.ProviderModel, boolInt(in.Stream), in.MaxEncryptedRequestBytes, in.MaxOutputTokens, in.InputTokenUpperBound, cap, in.ExpiresAtUnix, ReservationStateReserved, now.Unix(), boolInt(in.PrivacyClass))
	if err != nil {
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if err := tx.Commit(); err != nil {
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return Reservation{ProviderBinding: providerBinding, BuyerBinding: buyerBinding, AccountID: in.AccountID, WalletSession: in.WalletSession, ProviderID: in.ProviderID, AssignedSession: in.AssignedSession, KeyRecordDigest: in.KeyRecord.KeyRecordDigest, KID: in.KeyRecord.KID, Model: in.Model, ProviderModel: in.ProviderModel, Stream: in.Stream, MaxEncryptedRequestBytes: in.MaxEncryptedRequestBytes, MaxOutputTokens: in.MaxOutputTokens, InputTokenUpperBound: in.InputTokenUpperBound, ReservationTokenCap: cap, ExpiresAtUnix: in.ExpiresAtUnix, State: ReservationStateReserved, PrivacyClass: in.PrivacyClass}, nil
}

func (s *Store) Consume(ctx context.Context, in ConsumeInput) (ConsumeResponse, error) {
	now := in.Now.UTC()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ConsumeResponse{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	reservation, err := scanReservation(tx.QueryRowContext(ctx, reservationSelect+` WHERE provider_binding=?`, in.Envelope.ProviderBinding))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ConsumeResponse{}, ErrReservationMismatch
		}
		return ConsumeResponse{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if reservation.State != ReservationStateReserved {
		return ConsumeResponse{}, ErrReplay
	}
	if reservation.ExpiresAtUnix <= now.Unix() {
		_, _ = tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code='relay_blind_key_expired',terminal_at_unix=? WHERE provider_binding=? AND state='reserved'`, now.Unix(), reservation.ProviderBinding)
		_ = tx.Commit()
		return ConsumeResponse{}, ErrReservationExpired
	}
	if !reservationMatchesEnvelope(reservation.Reservation, in) {
		_, _ = tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',envelope_digest=?,terminal_code='relay_blind_route_reservation_invalid',terminal_at_unix=? WHERE provider_binding=? AND state='reserved'`, nullString(in.EnvelopeDigest), now.Unix(), reservation.ProviderBinding)
		_ = tx.Commit()
		return ConsumeResponse{}, ErrReservationMismatch
	}
	authorization, authDigest, err := randomAuthorization()
	if err != nil {
		return ConsumeResponse{}, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='consumed_predispatch',envelope_digest=?,execution_auth_digest=?,request_id=?,consumed_at_unix=? WHERE provider_binding=? AND state='reserved'`, in.EnvelopeDigest, authDigest, in.Envelope.RequestID, now.Unix(), reservation.ProviderBinding)
	if err != nil {
		return ConsumeResponse{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	changed, _ := result.RowsAffected()
	if changed != 1 {
		return ConsumeResponse{}, ErrReplay
	}
	if err := tx.Commit(); err != nil {
		return ConsumeResponse{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return ConsumeResponse{Version: ConsumeVersion, ProviderBinding: reservation.ProviderBinding, BuyerBinding: reservation.BuyerBinding, EnvelopeDigest: in.EnvelopeDigest, ExecutionAuthorization: authorization, ConsumedAtUnix: now.Unix(), ExpiresAtUnix: reservation.ExpiresAtUnix}, nil
}

func reservationMatchesEnvelope(r Reservation, in ConsumeInput) bool {
	e := in.Envelope
	return r.AccountID == in.AccountID && r.WalletSession == in.WalletSession && r.BuyerBinding == e.BuyerBinding && r.KeyRecordDigest == e.KeyRecordDigest && r.KID == e.KID && r.Model == e.Model && r.ProviderModel == e.ProviderModel && r.Stream == e.Stream && r.MaxOutputTokens == e.MaxOutputTokens && r.InputTokenUpperBound == e.InputTokenUpperBound && r.ReservationTokenCap == e.ReservationTokenCap && int64(lenDecoded(e.Ciphertext)) <= r.MaxEncryptedRequestBytes
}

func (s *Store) ArmDispatch(ctx context.Context, accountID, walletSession, authorization string, now time.Time) (Reservation, error) {
	return s.armDispatch(ctx, accountID, walletSession, authorization, "", now)
}

func (s *Store) ArmDispatchWithRequestID(ctx context.Context, accountID, walletSession, authorization, internalRequestID string, now time.Time) (Reservation, error) {
	if strings.TrimSpace(internalRequestID) == "" {
		return Reservation{}, ErrReservationMismatch
	}
	return s.armDispatch(ctx, accountID, walletSession, authorization, internalRequestID, now)
}

func (s *Store) armDispatch(ctx context.Context, accountID, walletSession, authorization, internalRequestID string, now time.Time) (Reservation, error) {
	authDigest := digestText(authorization)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Reservation{}, err
	}
	defer tx.Rollback()
	r, err := scanReservation(tx.QueryRowContext(ctx, reservationSelect+` WHERE execution_auth_digest=?`, authDigest))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Reservation{}, ErrReservationMismatch
		}
		return Reservation{}, err
	}
	if r.State != ReservationStateConsumedPredispatch {
		return Reservation{}, ErrReplay
	}
	if r.AccountID != accountID || r.WalletSession != walletSession {
		return Reservation{}, ErrReservationMismatch
	}
	if r.ExpiresAtUnix <= now.Unix() {
		_, _ = tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code='relay_blind_key_expired',terminal_at_unix=? WHERE provider_binding=? AND state='consumed_predispatch'`, now.Unix(), r.ProviderBinding)
		_ = tx.Commit()
		return Reservation{}, ErrReservationExpired
	}
	var revoked sql.NullInt64
	var keySession string
	if err := tx.QueryRowContext(ctx, `SELECT assigned_session,revoked_at_unix FROM relay_blind_key_records WHERE provider_id=? AND kid=? AND key_record_digest=?`, r.ProviderID, r.KID, r.KeyRecordDigest).Scan(&keySession, &revoked); err != nil {
		return Reservation{}, ErrKeyRevoked
	}
	if revoked.Valid {
		return Reservation{}, ErrKeyRevoked
	}
	if keySession != r.AssignedSession {
		return Reservation{}, ErrStaleSession
	}
	res, err := tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='dispatched',dispatched_at_unix=?,internal_request_id=CASE WHEN ?='' THEN internal_request_id ELSE ? END WHERE provider_binding=? AND state='consumed_predispatch'`, now.Unix(), internalRequestID, internalRequestID, r.ProviderBinding)
	if err != nil {
		return Reservation{}, err
	}
	changed, _ := res.RowsAffected()
	if changed != 1 {
		return Reservation{}, ErrReplay
	}
	if err := tx.Commit(); err != nil {
		return Reservation{}, err
	}
	r.State = ReservationStateDispatched
	r.ExecutionAuthDigest = authDigest
	r.InternalRequestID = internalRequestID
	return r.Reservation, nil
}

// LookupConsumedAuthorization authenticates a one-time execution token without
// changing its state. Callers use it for live-session and quota checks, then
// ArmDispatch performs the atomic consumed-to-dispatched transition.
func (s *Store) LookupConsumedAuthorization(ctx context.Context, accountID, walletSession, authorization string, now time.Time) (Reservation, error) {
	if s == nil || s.db == nil || strings.TrimSpace(authorization) == "" {
		return Reservation{}, ErrReservationMismatch
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	r, err := scanReservation(tx.QueryRowContext(ctx, reservationSelect+` WHERE execution_auth_digest=?`, digestText(authorization)))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Reservation{}, ErrReservationMismatch
		}
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if r.State != ReservationStateConsumedPredispatch {
		return Reservation{}, ErrReplay
	}
	if r.AccountID != accountID || r.WalletSession != walletSession {
		return Reservation{}, ErrReservationMismatch
	}
	if r.ExpiresAtUnix <= now.Unix() {
		_, _ = tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code='relay_blind_key_expired',terminal_at_unix=? WHERE provider_binding=? AND state='consumed_predispatch'`, now.Unix(), r.ProviderBinding)
		_ = tx.Commit()
		return Reservation{}, ErrReservationExpired
	}
	if err := tx.Commit(); err != nil {
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return r.Reservation, nil
}

func (s *Store) LookupKeyRecord(ctx context.Context, providerID, assignedSession, kid, digest string, now time.Time) (KeyRecord, error) {
	if s == nil || s.db == nil {
		return KeyRecord{}, ErrStoreUnavailable
	}
	var raw []byte
	var revoked sql.NullInt64
	var notBefore, expires int64
	err := s.db.QueryRowContext(ctx, `SELECT record_json,revoked_at_unix,not_before_unix,expires_at_unix FROM relay_blind_key_records WHERE provider_id=? AND assigned_session=? AND kid=? AND key_record_digest=?`, providerID, assignedSession, kid, digest).Scan(&raw, &revoked, &notBefore, &expires)
	if err != nil || revoked.Valid {
		return KeyRecord{}, ErrKeyRevoked
	}
	if notBefore > now.Unix() || expires <= now.Unix() {
		return KeyRecord{}, ErrReservationExpired
	}
	record, err := ParseKeyRecord(raw)
	if err != nil {
		return KeyRecord{}, fmt.Errorf("%w: corrupt key record", ErrStoreUnavailable)
	}
	return record, nil
}

func (s *Store) ActiveKeyModels(ctx context.Context, now time.Time) (map[string]map[string]map[string]struct{}, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT provider_id,assigned_session,record_json FROM relay_blind_key_records WHERE revoked_at_unix IS NULL AND not_before_unix<=? AND expires_at_unix>? AND key_class=?`, now.Unix(), now.Unix(), KeyClassRelayBlind)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer rows.Close()
	out := make(map[string]map[string]map[string]struct{})
	for rows.Next() {
		var providerID, assignedSession string
		var raw []byte
		if err := rows.Scan(&providerID, &assignedSession, &raw); err != nil {
			return nil, err
		}
		record, err := ParseKeyRecord(raw)
		if err != nil {
			return nil, fmt.Errorf("%w: corrupt key record", ErrStoreUnavailable)
		}
		sessions := out[providerID]
		if sessions == nil {
			sessions = make(map[string]map[string]struct{})
			out[providerID] = sessions
		}
		models := sessions[assignedSession]
		if models == nil {
			models = make(map[string]struct{})
			sessions[assignedSession] = models
		}
		for _, model := range record.Models {
			models[model] = struct{}{}
		}
	}
	return out, rows.Err()
}

func (s *Store) RejectPredispatch(ctx context.Context, providerBinding, code string, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code=?,terminal_at_unix=? WHERE provider_binding=? AND state IN ('reserved','consumed_predispatch')`, code, now.Unix(), providerBinding)
	return err
}

func (s *Store) RejectArmedPredispatch(ctx context.Context, providerBinding, code string, now time.Time) error {
	result, err := s.db.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',effective_privacy_outcome='relay_blind_unavailable',terminal_code=?,terminal_at_unix=? WHERE provider_binding=? AND state='dispatched' AND validated_at_unix IS NULL`, code, now.Unix(), providerBinding)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if changed != 1 {
		return ErrReplay
	}
	return nil
}

func (s *Store) PersistEvidence(ctx context.Context, providerID, assignedSession string, evidence Evidence, terminalCode string, now time.Time) (Reservation, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Reservation{}, err
	}
	defer tx.Rollback()
	r, err := scanReservation(tx.QueryRowContext(ctx, reservationSelect+` WHERE envelope_digest=?`, evidence.EnvelopeDigest))
	if err != nil {
		return Reservation{}, ErrEvidenceMismatch
	}
	if r.ProviderID != providerID || r.AssignedSession != assignedSession || r.State != ReservationStateDispatched || !evidenceMatches(r, evidence) {
		return Reservation{}, ErrEvidenceMismatch
	}
	switch evidence.State {
	case "validated":
		if r.ValidatedInputTokens.Valid || evidence.InputTokens < 0 || evidence.InputTokens > r.InputTokenUpperBound {
			return Reservation{}, ErrEvidenceMismatch
		}
		var result sql.Result
		result, err = tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET validated_input_tokens=?,effective_privacy_outcome='relay_blind_satisfied',validated_at_unix=? WHERE provider_binding=? AND state='dispatched' AND validated_at_unix IS NULL`, evidence.InputTokens, now.Unix(), r.ProviderBinding)
		if err == nil {
			changed, rowsErr := result.RowsAffected()
			if rowsErr != nil || changed != 1 {
				return Reservation{}, ErrEvidenceMismatch
			}
		}
	case "terminal":
		if !r.ValidatedInputTokens.Valid || evidence.InputTokens != r.ValidatedInputTokens.Int64 {
			return Reservation{}, ErrEvidenceMismatch
		}
		if evidence.CompletionTokens < 0 || evidence.CompletionTokens > r.MaxOutputTokens {
			return Reservation{}, ErrEvidenceMismatch
		}
		_, err = tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='terminal',completion_tokens=?,effective_privacy_outcome='relay_blind_satisfied',terminal_code=?,terminal_at_unix=? WHERE provider_binding=? AND state='dispatched' AND validated_at_unix IS NOT NULL`, evidence.CompletionTokens, nullString(terminalCode), now.Unix(), r.ProviderBinding)
	case "rejected":
		if r.ValidatedInputTokens.Valid || evidence.InputTokens != 0 || !acceptedBoundRejection(r.PrivacyClass, evidence.ErrorCode) {
			return Reservation{}, ErrEvidenceMismatch
		}
		_, err = tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',effective_privacy_outcome='relay_blind_unavailable',terminal_code=?,terminal_at_unix=? WHERE provider_binding=? AND state='dispatched' AND validated_at_unix IS NULL`, evidence.ErrorCode, now.Unix(), r.ProviderBinding)
	default:
		return Reservation{}, ErrEvidenceMismatch
	}
	if err != nil {
		return Reservation{}, err
	}
	if err := tx.Commit(); err != nil {
		return Reservation{}, err
	}
	return s.LookupReservation(ctx, r.ProviderBinding)
}

func evidenceMatches(r reservationRow, e Evidence) bool {
	return r.ExecutionAuthDigest == e.ExecutionAuthDigest && r.EnvelopeDigest == e.EnvelopeDigest && r.KID == e.KID && digestText(r.ProviderBinding) == e.ProviderBindingDigest && digestText(r.BuyerBinding) == e.BuyerBindingDigest && r.AssignedSession == e.AssignedSession && r.RequestID == e.RequestID && r.InputTokenUpperBound == e.InputTokenUpperBound && r.MaxOutputTokens == e.MaxOutputTokens
}

func (s *Store) MarkUnknownPostdispatch(ctx context.Context, providerBinding, code string, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='unknown_postdispatch',effective_privacy_outcome=CASE WHEN validated_at_unix IS NULL THEN 'relay_blind_unavailable' ELSE effective_privacy_outcome END,terminal_code=?,terminal_at_unix=? WHERE provider_binding=? AND state='dispatched'`, code, now.Unix(), providerBinding)
	return err
}

func (s *Store) BindInternalRequestID(ctx context.Context, providerBinding, internalRequestID string) error {
	if strings.TrimSpace(internalRequestID) == "" {
		return ErrReservationMismatch
	}
	result, err := s.db.ExecContext(ctx, `UPDATE relay_blind_reservations SET internal_request_id=? WHERE provider_binding=? AND state='dispatched' AND internal_request_id IS NULL`, internalRequestID, providerBinding)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	changed, _ := result.RowsAffected()
	if changed != 1 {
		return ErrReplay
	}
	return nil
}

func (s *Store) LookupStatus(ctx context.Context, accountID, walletSession, providerBindingDigest, envelopeDigest string, now time.Time) (Reservation, error) {
	if _, err := s.db.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code='relay_blind_key_expired',terminal_at_unix=? WHERE account_id=? AND wallet_session=? AND envelope_digest=? AND expires_at_unix<=? AND state IN ('reserved','consumed_predispatch')`, now.Unix(), accountID, walletSession, envelopeDigest, now.Unix()); err != nil {
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	rows, err := s.db.QueryContext(ctx, reservationSelect+` WHERE account_id=? AND wallet_session=? AND envelope_digest=?`, accountID, walletSession, envelopeDigest)
	if err != nil {
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer rows.Close()
	for rows.Next() {
		r, err := scanReservation(rows)
		if err != nil {
			return Reservation{}, err
		}
		if subtle.ConstantTimeCompare([]byte(digestText(r.ProviderBinding)), []byte(providerBindingDigest)) == 1 {
			return r.Reservation, nil
		}
	}
	return Reservation{}, ErrReservationMismatch
}

func (s *Store) LookupReservation(ctx context.Context, providerBinding string) (Reservation, error) {
	row, err := scanReservation(s.db.QueryRowContext(ctx, reservationSelect+` WHERE provider_binding=?`, providerBinding))
	if err != nil {
		return Reservation{}, err
	}
	return row.Reservation, nil
}

func (s *Store) RecoverUncertain(ctx context.Context, now time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx, `UPDATE relay_blind_reservations SET state=CASE WHEN state='dispatched' THEN 'unknown_postdispatch' ELSE 'rejected' END,terminal_code=CASE WHEN state='dispatched' THEN 'relay_blind_execution_uncertain' ELSE 'relay_blind_required_unavailable' END,terminal_at_unix=? WHERE state IN ('consumed_predispatch','dispatched')`, now.Unix())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

const reservationSelect = `SELECT provider_binding,buyer_binding,account_id,wallet_session,provider_id,assigned_session,key_record_digest,kid,model,provider_model,stream,max_encrypted_request_bytes,max_output_tokens,input_token_upper_bound,reservation_token_cap,expires_at_unix,state,COALESCE(envelope_digest,''),COALESCE(execution_auth_digest,''),COALESCE(request_id,''),validated_input_tokens,effective_privacy_outcome,COALESCE(internal_request_id,''),completion_tokens,privacy_class FROM relay_blind_reservations`

type reservationRow struct {
	Reservation
	ValidatedInputTokens sql.NullInt64
	CompletionTokens     sql.NullInt64
}
type rowScanner interface{ Scan(...any) error }

func scanReservation(row rowScanner) (reservationRow, error) {
	var r reservationRow
	var stream, privacyClass int
	err := row.Scan(&r.ProviderBinding, &r.BuyerBinding, &r.AccountID, &r.WalletSession, &r.ProviderID, &r.AssignedSession, &r.KeyRecordDigest, &r.KID, &r.Model, &r.ProviderModel, &stream, &r.MaxEncryptedRequestBytes, &r.MaxOutputTokens, &r.InputTokenUpperBound, &r.ReservationTokenCap, &r.ExpiresAtUnix, &r.State, &r.EnvelopeDigest, &r.ExecutionAuthDigest, &r.RequestID, &r.ValidatedInputTokens, &r.EffectivePrivacyOutcome, &r.InternalRequestID, &r.CompletionTokens, &privacyClass)
	r.Stream = stream == 1
	r.PrivacyClass = privacyClass != 0
	if r.ValidatedInputTokens.Valid {
		v := r.ValidatedInputTokens.Int64
		r.Reservation.ValidatedInputTokens = &v
	}
	if r.CompletionTokens.Valid {
		v := r.CompletionTokens.Int64
		r.Reservation.CompletionTokens = &v
	}
	return r, err
}

func randomBinding() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
func randomAuthorization() (string, string, error) {
	token, err := randomBinding()
	if err != nil {
		return "", "", err
	}
	return token, digestText(token), nil
}
func digestText(value string) string {
	sum := sha256.Sum256([]byte(value))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}
func BindingDigest(value string) string { return digestText(value) }
func ConstantTimeAuthorizationDigest(authorization, digest string) bool {
	return subtle.ConstantTimeCompare([]byte(digestText(authorization)), []byte(digest)) == 1
}
func lenDecoded(value string) int { b, _ := base64.RawURLEncoding.DecodeString(value); return len(b) }
func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
func nullString(v string) any {
	if v == "" {
		return nil
	}
	return v
}

func validKeyClass(class string) error {
	if class != KeyClassRelayBlind && class != KeyClassPrivacy {
		return fmt.Errorf("%w: key class", ErrInvalidKeyRecord)
	}
	return nil
}

func reservationPrivacyFlag(class string) int {
	if class == KeyClassPrivacy {
		return 1
	}
	return 0
}

func acceptedBoundRejection(privacy bool, code string) bool {
	switch code {
	case "relay_blind_ciphertext_invalid", "relay_blind_decrypt_failed", "unsupported_sampling_penalty":
		return true
	case "privacy_class_posture_stale", "privacy_class_downgrade_rejected":
		return privacy
	default:
		return false
	}
}

func (s *Store) ensurePrivacySchema(ctx context.Context) error {
	if err := s.addColumnIfMissing(ctx, "relay_blind_key_records", "key_class", `ALTER TABLE relay_blind_key_records ADD COLUMN key_class TEXT NOT NULL DEFAULT 'relay_blind'`); err != nil {
		return err
	}
	if err := s.addColumnIfMissing(ctx, "relay_blind_reservations", "privacy_class", `ALTER TABLE relay_blind_reservations ADD COLUMN privacy_class INTEGER NOT NULL DEFAULT 0`); err != nil {
		return err
	}
	// Attestation bytes stay on the key row. The in-memory authority only
	// keeps the cdhash, and a reservation response has to echo the signed
	// attestation without reading provider traffic.
	if err := s.addColumnIfMissing(ctx, "relay_blind_key_records", "privacy_attestation_json", `ALTER TABLE relay_blind_key_records ADD COLUMN privacy_attestation_json TEXT NULL`); err != nil {
		return err
	}
	if err := s.addColumnIfMissing(ctx, "relay_blind_key_records", "privacy_attestation_signature", `ALTER TABLE relay_blind_key_records ADD COLUMN privacy_attestation_signature TEXT NULL`); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS privacy_class_quarantine (
  provider_id TEXT PRIMARY KEY,
  reason TEXT NOT NULL,
  quarantined_at_unix INTEGER NOT NULL,
  expires_at_unix INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS privacy_class_control (
  id INTEGER PRIMARY KEY CHECK(id=1),
  disabled INTEGER NOT NULL,
  reason TEXT NOT NULL,
  updated_at_unix INTEGER NOT NULL
);`)
	if err != nil {
		return fmt.Errorf("%w: migrate privacy class: %v", ErrStoreUnavailable, err)
	}
	return nil
}

func (s *Store) addColumnIfMissing(ctx context.Context, table, column, alter string) error {
	exists, err := s.columnExists(ctx, table, column)
	if err != nil || exists {
		return err
	}
	if _, err := s.db.ExecContext(ctx, alter); err != nil {
		return fmt.Errorf("%w: add %s.%s: %v", ErrStoreUnavailable, table, column, err)
	}
	return nil
}

func (s *Store) columnExists(ctx context.Context, table, column string) (bool, error) {
	var query string
	switch table {
	case "relay_blind_key_records":
		query = `PRAGMA table_info(relay_blind_key_records)`
	case "relay_blind_reservations":
		query = `PRAGMA table_info(relay_blind_reservations)`
	default:
		return false, fmt.Errorf("%w: unknown table", ErrStoreUnavailable)
	}
	rows, err := s.db.QueryContext(ctx, query)
	if err != nil {
		return false, fmt.Errorf("%w: table info: %v", ErrStoreUnavailable, err)
	}
	defer rows.Close()
	for rows.Next() {
		var cid, notnull, pk int
		var name, typ string
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &typ, &notnull, &dflt, &pk); err != nil {
			return false, fmt.Errorf("%w: table info: %v", ErrStoreUnavailable, err)
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

func boundPrivacyReason(reason string) string {
	reason = strings.TrimSpace(reason)
	if reason == "" || len(reason) > 128 {
		return "unspecified"
	}
	for i := 0; i < len(reason); i++ {
		if reason[i] < 0x20 || reason[i] > 0x7e {
			return "unspecified"
		}
	}
	return reason
}

func (s *Store) Quarantine(ctx context.Context, providerID, reason string, now time.Time, dur time.Duration) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	if strings.TrimSpace(providerID) == "" {
		return fmt.Errorf("%w: provider id", ErrInvalidKeyRecord)
	}
	if dur <= 0 {
		dur = 86400 * time.Second
	}
	reason = boundPrivacyReason(reason)
	expires := now.Add(dur).Unix()
	_, err := s.db.ExecContext(ctx, `INSERT INTO privacy_class_quarantine(provider_id,reason,quarantined_at_unix,expires_at_unix) VALUES(?,?,?,?) ON CONFLICT(provider_id) DO UPDATE SET reason=excluded.reason, quarantined_at_unix=excluded.quarantined_at_unix, expires_at_unix=excluded.expires_at_unix`, providerID, reason, now.Unix(), expires)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return nil
}

// QuarantineAndRevokePrivacy writes the quarantine row, revokes every
// unrevoked privacy-class key, and rejects that provider's predispatch
// privacy reservations in one transaction. A failure commits none of them.
func (s *Store) QuarantineAndRevokePrivacy(ctx context.Context, providerID, reason string, now time.Time, dur, replayRetention time.Duration) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	if strings.TrimSpace(providerID) == "" {
		return fmt.Errorf("%w: provider id", ErrInvalidKeyRecord)
	}
	if dur <= 0 {
		dur = 86400 * time.Second
	}
	reason = boundPrivacyReason(reason)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	expires := now.Add(dur).Unix()
	if _, err := tx.ExecContext(ctx, `INSERT INTO privacy_class_quarantine(provider_id,reason,quarantined_at_unix,expires_at_unix) VALUES(?,?,?,?) ON CONFLICT(provider_id) DO UPDATE SET reason=excluded.reason, quarantined_at_unix=excluded.quarantined_at_unix, expires_at_unix=excluded.expires_at_unix`, providerID, reason, now.Unix(), expires); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	rows, err := tx.QueryContext(ctx, `SELECT kid,expires_at_unix FROM relay_blind_key_records WHERE provider_id=? AND revoked_at_unix IS NULL AND key_class=?`, providerID, KeyClassPrivacy)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	type privacyKey struct {
		kid     string
		expires int64
	}
	var keys []privacyKey
	for rows.Next() {
		var item privacyKey
		if err := rows.Scan(&item.kid, &item.expires); err != nil {
			rows.Close()
			return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		keys = append(keys, item)
	}
	if err := rows.Close(); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	for _, item := range keys {
		retainedUntil := now.Add(replayRetention).Unix()
		if item.expires > retainedUntil {
			retainedUntil = item.expires
		}
		if _, err := tx.ExecContext(ctx, `UPDATE relay_blind_key_records SET revoked_at_unix=?,revocation_retained_until_unix=? WHERE provider_id=? AND kid=? AND key_class=? AND revoked_at_unix IS NULL`, now.Unix(), retainedUntil, providerID, item.kid, KeyClassPrivacy); err != nil {
			return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
	}
	if _, err := tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code='relay_blind_key_expired',terminal_at_unix=? WHERE provider_id=? AND privacy_class=1 AND state IN ('reserved','consumed_predispatch')`, now.Unix(), providerID); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return nil
}

func (s *Store) IsQuarantined(ctx context.Context, providerID string, now time.Time) (bool, error) {
	if s == nil || s.db == nil {
		return false, ErrStoreUnavailable
	}
	var expires int64
	err := s.db.QueryRowContext(ctx, `SELECT expires_at_unix FROM privacy_class_quarantine WHERE provider_id=?`, providerID).Scan(&expires)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return expires > now.Unix(), nil
}

func (s *Store) Unquarantine(ctx context.Context, providerID string) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM privacy_class_quarantine WHERE provider_id=?`, providerID)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return nil
}

func (s *Store) SetPrivacyDisabled(ctx context.Context, disabled bool, reason string, now time.Time) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	reason = boundPrivacyReason(reason)
	flag := 0
	if disabled {
		flag = 1
	} else if reason == "unspecified" {
		reason = "enabled"
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO privacy_class_control(id,disabled,reason,updated_at_unix) VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET disabled=excluded.disabled, reason=excluded.reason, updated_at_unix=excluded.updated_at_unix`, flag, reason, now.Unix())
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return nil
}

// DisablePrivacyAndRejectPredispatch sets the kill switch and rejects held
// privacy reservations in one transaction. Enable stays on SetPrivacyDisabled.
func (s *Store) DisablePrivacyAndRejectPredispatch(ctx context.Context, reason string, now time.Time) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	reason = boundPrivacyReason(reason)
	code := boundPrivacyReason("privacy_class_disabled")
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO privacy_class_control(id,disabled,reason,updated_at_unix) VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET disabled=excluded.disabled, reason=excluded.reason, updated_at_unix=excluded.updated_at_unix`, 1, reason, now.Unix()); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code=?,terminal_at_unix=? WHERE privacy_class=1 AND state IN ('reserved','consumed_predispatch')`, code, now.Unix()); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return nil
}

func (s *Store) PrivacyDisabled(ctx context.Context) (bool, error) {
	if s == nil || s.db == nil {
		return false, ErrStoreUnavailable
	}
	var disabled int
	err := s.db.QueryRowContext(ctx, `SELECT disabled FROM privacy_class_control WHERE id=1`).Scan(&disabled)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return disabled != 0, nil
}

func (s *Store) RejectHeldPrivacyPredispatch(ctx context.Context, code string, now time.Time) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	code = boundPrivacyReason(code)
	_, err := s.db.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code=?,terminal_at_unix=? WHERE privacy_class=1 AND state IN ('reserved','consumed_predispatch')`, code, now.Unix())
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return nil
}

func (s *Store) FreshKeySessions(ctx context.Context, now time.Time, class string) ([]KeySession, error) {
	if err := validKeyClass(class); err != nil {
		return nil, err
	}
	if s == nil || s.db == nil {
		return nil, ErrStoreUnavailable
	}
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT provider_id,assigned_session FROM relay_blind_key_records WHERE key_class=? AND revoked_at_unix IS NULL AND not_before_unix<=? AND expires_at_unix>?`, class, now.Unix(), now.Unix())
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer rows.Close()
	var out []KeySession
	for rows.Next() {
		var item KeySession
		if err := rows.Scan(&item.ProviderID, &item.AssignedSession); err != nil {
			return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) StorePrivacyAttestation(ctx context.Context, providerID, kid, digest string, attestation PrivacyKeyAttestation, signature string) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	if err := attestation.validate(); err != nil {
		return err
	}
	if attestation.KeyRecordDigest != digest {
		return fmt.Errorf("%w: key attestation binding", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(signature, ed25519.SignatureSize); err != nil {
		return fmt.Errorf("%w: key attestation signature", ErrInvalidPrivacy)
	}
	raw, err := json.Marshal(attestation)
	if err != nil {
		return fmt.Errorf("%w: privacy attestation", ErrStoreUnavailable)
	}
	result, err := s.db.ExecContext(ctx, `UPDATE relay_blind_key_records SET privacy_attestation_json=?,privacy_attestation_signature=? WHERE provider_id=? AND kid=? AND key_record_digest=? AND key_class=? AND revoked_at_unix IS NULL`, string(raw), signature, providerID, kid, digest, KeyClassPrivacy)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if changed != 1 {
		return fmt.Errorf("%w: privacy attestation", ErrStoreUnavailable)
	}
	return nil
}

func (s *Store) LookupPrivacyAttestation(ctx context.Context, providerID, kid, digest string) (PrivacyKeyAttestation, string, error) {
	if s == nil || s.db == nil {
		return PrivacyKeyAttestation{}, "", ErrStoreUnavailable
	}
	var raw, signature sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT privacy_attestation_json,privacy_attestation_signature FROM relay_blind_key_records WHERE provider_id=? AND kid=? AND key_record_digest=? AND key_class=? AND revoked_at_unix IS NULL`, providerID, kid, digest, KeyClassPrivacy).Scan(&raw, &signature)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return PrivacyKeyAttestation{}, "", fmt.Errorf("%w: privacy attestation", ErrInvalidPrivacy)
		}
		return PrivacyKeyAttestation{}, "", fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if !raw.Valid || !signature.Valid || raw.String == "" || signature.String == "" {
		return PrivacyKeyAttestation{}, "", fmt.Errorf("%w: privacy attestation", ErrInvalidPrivacy)
	}
	var attestation PrivacyKeyAttestation
	if err := decodeClosed([]byte(raw.String), &attestation, []string{"version", "key_record_digest", "privacy_class", "assurance", "binary_version", "code_cdhash", "not_before_unix", "expires_at_unix"}); err != nil {
		return PrivacyKeyAttestation{}, "", fmt.Errorf("%w: privacy attestation", ErrInvalidPrivacy)
	}
	if err := attestation.validate(); err != nil {
		return PrivacyKeyAttestation{}, "", err
	}
	if attestation.KeyRecordDigest != digest {
		return PrivacyKeyAttestation{}, "", fmt.Errorf("%w: key attestation binding", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(signature.String, ed25519.SignatureSize); err != nil {
		return PrivacyKeyAttestation{}, "", fmt.Errorf("%w: key attestation signature", ErrInvalidPrivacy)
	}
	return attestation, signature.String, nil
}

// PeekAuthorization reads a reservation by execution-authorization digest in
// any state. It does not change the row and does not weaken the consumed-only
// check in LookupConsumedAuthorization.
func (s *Store) PeekAuthorization(ctx context.Context, accountID, walletSession, authorization string) (Reservation, error) {
	if s == nil || s.db == nil || strings.TrimSpace(authorization) == "" {
		return Reservation{}, ErrReservationMismatch
	}
	row, err := scanReservation(s.db.QueryRowContext(ctx, reservationSelect+` WHERE execution_auth_digest=?`, digestText(authorization)))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Reservation{}, ErrReservationMismatch
		}
		return Reservation{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if row.AccountID != accountID || row.WalletSession != walletSession {
		return Reservation{}, ErrReservationMismatch
	}
	return row.Reservation, nil
}

// PrivacyControlStatus is the durable kill-switch row. Present is false when
// the operator has never written the control row.
type PrivacyControlStatus struct {
	Present       bool
	Disabled      bool
	Reason        string
	UpdatedAtUnix int64
}

func (s *Store) PrivacyControl(ctx context.Context) (PrivacyControlStatus, error) {
	if s == nil || s.db == nil {
		return PrivacyControlStatus{}, ErrStoreUnavailable
	}
	var disabled int
	var reason string
	var updated int64
	err := s.db.QueryRowContext(ctx, `SELECT disabled,reason,updated_at_unix FROM privacy_class_control WHERE id=1`).Scan(&disabled, &reason, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return PrivacyControlStatus{}, nil
	}
	if err != nil {
		return PrivacyControlStatus{}, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return PrivacyControlStatus{Present: true, Disabled: disabled != 0, Reason: reason, UpdatedAtUnix: updated}, nil
}

// PrivacyQuarantine is one unexpired provider quarantine row.
type PrivacyQuarantine struct {
	ProviderID        string
	Reason            string
	QuarantinedAtUnix int64
	ExpiresAtUnix     int64
}

func (s *Store) ListPrivacyQuarantines(ctx context.Context, now time.Time) ([]PrivacyQuarantine, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreUnavailable
	}
	rows, err := s.db.QueryContext(ctx, `SELECT provider_id,reason,quarantined_at_unix,expires_at_unix FROM privacy_class_quarantine WHERE expires_at_unix>? ORDER BY provider_id`, now.Unix())
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer rows.Close()
	var out []PrivacyQuarantine
	for rows.Next() {
		var item PrivacyQuarantine
		if err := rows.Scan(&item.ProviderID, &item.Reason, &item.QuarantinedAtUnix, &item.ExpiresAtUnix); err != nil {
			return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) CountReservations(ctx context.Context) (int, error) {
	if s == nil || s.db == nil {
		return 0, ErrStoreUnavailable
	}
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM relay_blind_reservations`).Scan(&count); err != nil {
		return 0, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return count, nil
}

func (s *Store) PrivacyKeyFresh(ctx context.Context, providerID, assignedSession, digest string, now time.Time) (bool, error) {
	if s == nil || s.db == nil {
		return false, ErrStoreUnavailable
	}
	var count int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM relay_blind_key_records WHERE provider_id=? AND assigned_session=? AND key_record_digest=? AND key_class=? AND revoked_at_unix IS NULL AND not_before_unix<=? AND expires_at_unix>?`, providerID, assignedSession, digest, KeyClassPrivacy, now.Unix(), now.Unix()).Scan(&count)
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return count > 0, nil
}
