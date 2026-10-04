package relayblind

import (
	"context"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"
)

// SPEC-049 §4.12 reason codes. They are written to the store and the
// coordinator log only; none is buyer-facing.
const (
	ReasonAppAttestAttestationInvalid = "app_attest_attestation_invalid"
	ReasonAppAttestACLMismatch        = "app_attest_acl_mismatch"
	ReasonAppAttestBindingMismatch    = "app_attest_binding_mismatch"
	ReasonAppAttestAssertionInvalid   = "app_attest_assertion_invalid"
	ReasonAppAttestCounterRegression  = "app_attest_counter_regression"
	ReasonSupervisorChildCheckFailed  = "supervisor_child_check_failed"
	ReasonAssuranceMismatch           = "assurance_mismatch"
	ReasonAssuranceRegression         = "assurance_regression"
	ReasonSuperseded                  = "superseded"
	ReasonBindingStale                = "binding_stale"
	ReasonCounterExhausted            = "counter_exhausted"
	ReasonOperatorRevoked             = "operator_revoked"

	AppAttestKeyActive  = "active"
	AppAttestKeyRevoked = "revoked"

	// MaxAppAttestCounter is the largest u32 assertion counter.
	MaxAppAttestCounter = uint32(math.MaxUint32)
)

var (
	ErrAppAttestKeyExists          = errors.New("relayblind: app attest key already enrolled")
	ErrAppAttestCounterNotAdvanced = errors.New("relayblind: app attest counter not advanced")
	ErrAppAttestKeyNotActive       = errors.New("relayblind: app attest key not active")
)

// AppAttestReasonQuarantines reports whether a §4.12 reason code is marked
// for quarantine. Unknown codes are not reason codes.
func AppAttestReasonQuarantines(reason string) (quarantine, known bool) {
	switch reason {
	case ReasonAppAttestAttestationInvalid, ReasonAppAttestACLMismatch, ReasonAppAttestBindingMismatch,
		ReasonAppAttestAssertionInvalid, ReasonAppAttestCounterRegression, ReasonSupervisorChildCheckFailed,
		ReasonAssuranceMismatch, ReasonAssuranceRegression:
		return true, true
	case ReasonSuperseded, ReasonBindingStale, ReasonCounterExhausted, ReasonOperatorRevoked:
		return false, true
	default:
		return false, false
	}
}

// AppAttestKey is one privacy_app_attest_keys row. PublicKey is the public
// 65-byte uncompressed P-256 point; no private material is ever stored.
type AppAttestKey struct {
	KeyID                   []byte
	ProviderID              string
	PublicKey               []byte
	TeamID                  string
	SEPublicKeySHA256       []byte
	IdentityPublicKeySHA256 []byte
	EnrolledAtUnix          int64
	LastCounter             uint32
	State                   string
	RevokedReason           string
	RevokedAtUnix           int64
}

func (s *Store) ensureAppAttestSchema(ctx context.Context) error {
	// A reservation records the label it was granted; it is never upgraded
	// or downgraded (SPEC-049-R032). Rows from before v0.2 hold ''.
	if err := s.addColumnIfMissing(ctx, "relay_blind_reservations", "privacy_assurance", `ALTER TABLE relay_blind_reservations ADD COLUMN privacy_assurance TEXT NOT NULL DEFAULT ''`); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS privacy_app_attest_keys (
  app_attest_key_id BLOB PRIMARY KEY CHECK(length(app_attest_key_id)=32),
  provider_id TEXT NOT NULL,
  public_key BLOB NOT NULL CHECK(length(public_key)=65),
  team_id TEXT NOT NULL,
  se_public_key_sha256 BLOB NOT NULL CHECK(length(se_public_key_sha256)=32),
  identity_public_key_sha256 BLOB NOT NULL CHECK(length(identity_public_key_sha256)=32),
  enrolled_at_unix INTEGER NOT NULL,
  last_counter INTEGER NOT NULL DEFAULT 0 CHECK(last_counter BETWEEN 0 AND 4294967295),
  state TEXT NOT NULL CHECK(state IN ('active','revoked')),
  revoked_reason TEXT NULL,
  revoked_at_unix INTEGER NULL,
  CHECK((state='active' AND revoked_reason IS NULL AND revoked_at_unix IS NULL) OR (state='revoked' AND revoked_reason IS NOT NULL AND revoked_at_unix IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_privacy_app_attest_one_active ON privacy_app_attest_keys(provider_id) WHERE state='active';
CREATE TRIGGER IF NOT EXISTS privacy_app_attest_no_reactivate BEFORE UPDATE OF state ON privacy_app_attest_keys
WHEN OLD.state='revoked' AND NEW.state<>'revoked'
BEGIN SELECT RAISE(ABORT, 'revoked app attest key cannot become active'); END;
CREATE TRIGGER IF NOT EXISTS privacy_app_attest_counter_monotonic BEFORE UPDATE OF last_counter ON privacy_app_attest_keys
WHEN NEW.last_counter <= OLD.last_counter
BEGIN SELECT RAISE(ABORT, 'app attest counter must increase'); END;
CREATE TABLE IF NOT EXISTS privacy_app_attest_challenges (
  provider_id TEXT NOT NULL,
  issued_at_unix INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_privacy_app_attest_challenges ON privacy_app_attest_challenges(provider_id,issued_at_unix);`)
	if err != nil {
		return fmt.Errorf("%w: migrate app attest: %v", ErrStoreUnavailable, err)
	}
	return nil
}

const appAttestSelect = `SELECT app_attest_key_id,provider_id,public_key,team_id,se_public_key_sha256,identity_public_key_sha256,enrolled_at_unix,last_counter,state,COALESCE(revoked_reason,''),COALESCE(revoked_at_unix,0) FROM privacy_app_attest_keys`

func scanAppAttestKey(row rowScanner) (AppAttestKey, error) {
	var key AppAttestKey
	var counter int64
	err := row.Scan(&key.KeyID, &key.ProviderID, &key.PublicKey, &key.TeamID, &key.SEPublicKeySHA256, &key.IdentityPublicKeySHA256, &key.EnrolledAtUnix, &counter, &key.State, &key.RevokedReason, &key.RevokedAtUnix)
	if err != nil {
		return AppAttestKey{}, err
	}
	if counter < 0 || counter > math.MaxUint32 {
		return AppAttestKey{}, fmt.Errorf("%w: app attest counter out of range", ErrStoreUnavailable)
	}
	key.LastCounter = uint32(counter)
	return key, nil
}

// AppAttestKeyByID returns the row for a keyId in any state.
func (s *Store) AppAttestKeyByID(ctx context.Context, keyID []byte) (AppAttestKey, bool, error) {
	if s == nil || s.db == nil {
		return AppAttestKey{}, false, ErrStoreUnavailable
	}
	key, err := scanAppAttestKey(s.db.QueryRowContext(ctx, appAttestSelect+` WHERE app_attest_key_id=?`, keyID))
	if errors.Is(err, sql.ErrNoRows) {
		return AppAttestKey{}, false, nil
	}
	if err != nil {
		return AppAttestKey{}, false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return key, true, nil
}

// EnrollAppAttestKey revokes any other active key of the provider as
// superseded and inserts key as active with counter 0, in one transaction
// (SPEC-049-R027). A keyId that already exists is never re-inserted.
func (s *Store) EnrollAppAttestKey(ctx context.Context, key AppAttestKey, now time.Time) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	if len(key.KeyID) != 32 || len(key.PublicKey) != 65 || strings.TrimSpace(key.ProviderID) == "" || len(key.SEPublicKeySHA256) != 32 || len(key.IdentityPublicKeySHA256) != 32 || key.TeamID == "" {
		return fmt.Errorf("%w: app attest key", ErrInvalidPrivacy)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	var existing int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM privacy_app_attest_keys WHERE app_attest_key_id=?`, key.KeyID).Scan(&existing); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if existing != 0 {
		return ErrAppAttestKeyExists
	}
	if _, err := tx.ExecContext(ctx, `UPDATE privacy_app_attest_keys SET state='revoked',revoked_reason=?,revoked_at_unix=? WHERE provider_id=? AND state='active'`, ReasonSuperseded, now.Unix(), key.ProviderID); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO privacy_app_attest_keys(app_attest_key_id,provider_id,public_key,team_id,se_public_key_sha256,identity_public_key_sha256,enrolled_at_unix,last_counter,state) VALUES(?,?,?,?,?,?,?,0,'active')`,
		key.KeyID, key.ProviderID, key.PublicKey, key.TeamID, key.SEPublicKeySHA256, key.IdentityPublicKeySHA256, now.Unix()); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return nil
}

// AdvanceAppAttestCounter durably commits a strictly greater counter for
// the provider's active key with one conditional UPDATE (SPEC-049-R031
// step 6). Zero updated rows is ErrAppAttestCounterNotAdvanced.
func (s *Store) AdvanceAppAttestCounter(ctx context.Context, providerID string, keyID []byte, counter uint32) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	result, err := s.db.ExecContext(ctx, `UPDATE privacy_app_attest_keys SET last_counter=? WHERE app_attest_key_id=? AND provider_id=? AND state='active' AND last_counter<?`, int64(counter), keyID, providerID, int64(counter))
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	n, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if n != 1 {
		return ErrAppAttestCounterNotAdvanced
	}
	return nil
}

// RevokeAppAttestKey revokes one active key of a provider with a §4.12
// reason. It reports whether a row changed.
func (s *Store) RevokeAppAttestKey(ctx context.Context, providerID string, keyID []byte, reason string, now time.Time) (bool, error) {
	if s == nil || s.db == nil {
		return false, ErrStoreUnavailable
	}
	if _, known := AppAttestReasonQuarantines(reason); !known {
		return false, fmt.Errorf("%w: app attest reason", ErrInvalidPrivacy)
	}
	result, err := s.db.ExecContext(ctx, `UPDATE privacy_app_attest_keys SET state='revoked',revoked_reason=?,revoked_at_unix=? WHERE app_attest_key_id=? AND provider_id=? AND state='active'`, reason, now.Unix(), keyID, providerID)
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	n, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return n == 1, nil
}

// RevokeActiveAppAttestKey revokes the provider's active key, if any.
func (s *Store) RevokeActiveAppAttestKey(ctx context.Context, providerID, reason string, now time.Time) (bool, error) {
	if s == nil || s.db == nil {
		return false, ErrStoreUnavailable
	}
	if _, known := AppAttestReasonQuarantines(reason); !known {
		return false, fmt.Errorf("%w: app attest reason", ErrInvalidPrivacy)
	}
	result, err := s.db.ExecContext(ctx, `UPDATE privacy_app_attest_keys SET state='revoked',revoked_reason=?,revoked_at_unix=? WHERE provider_id=? AND state='active'`, reason, now.Unix(), providerID)
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	n, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return n == 1, nil
}

// RecordAppAttestChallenge records one enrollment challenge unless the
// provider already received max challenges in the trailing 24 hours.
func (s *Store) RecordAppAttestChallenge(ctx context.Context, providerID string, now time.Time, max int) (bool, error) {
	if s == nil || s.db == nil {
		return false, ErrStoreUnavailable
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	cutoff := now.Add(-24 * time.Hour).Unix()
	if _, err := tx.ExecContext(ctx, `DELETE FROM privacy_app_attest_challenges WHERE issued_at_unix<=?`, cutoff); err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	var count int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM privacy_app_attest_challenges WHERE provider_id=?`, providerID).Scan(&count); err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if count >= max {
		return false, nil
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO privacy_app_attest_challenges(provider_id,issued_at_unix) VALUES(?,?)`, providerID, now.Unix()); err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return true, nil
}

// AppAttestKeyStatus is the operator-visible key state. It carries no
// private material; KeyID is canonical base64url of the public keyId.
type AppAttestKeyStatus struct {
	ProviderID    string
	KeyID         string
	State         string
	LastCounter   uint32
	RevokedReason string
}

func (s *Store) ListAppAttestKeys(ctx context.Context) ([]AppAttestKeyStatus, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreUnavailable
	}
	rows, err := s.db.QueryContext(ctx, appAttestSelect+` ORDER BY provider_id,enrolled_at_unix,app_attest_key_id`)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer rows.Close()
	var out []AppAttestKeyStatus
	for rows.Next() {
		key, err := scanAppAttestKey(rows)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		out = append(out, AppAttestKeyStatus{
			ProviderID: key.ProviderID, KeyID: base64.RawURLEncoding.EncodeToString(key.KeyID),
			State: key.State, LastCounter: key.LastCounter, RevokedReason: key.RevokedReason,
		})
	}
	return out, rows.Err()
}
