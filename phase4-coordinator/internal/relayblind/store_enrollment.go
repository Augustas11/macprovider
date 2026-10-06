package relayblind

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// EnrollmentRevocationRetention keeps a revoked enrollment published as
// revoked in the identity directory (SPEC-049-R026).
const EnrollmentRevocationRetention = 30 * 24 * time.Hour

var (
	// ErrEnrollmentKeyChanged means the provider already has an active
	// enrollment with different keys (SPEC-049-R026).
	ErrEnrollmentKeyChanged = errors.New("relayblind: privacy enrollment key changed")
	// ErrEnrollmentKeyInUse means a key is actively enrolled for another
	// provider ID (SPEC-049-R025).
	ErrEnrollmentKeyInUse = errors.New("relayblind: privacy enrollment key in use by another provider")
	// ErrEnrollmentKeysStale means a key the enrolling posture listed is no
	// longer fresh for that session, for example after a reenroll.
	ErrEnrollmentKeysStale = errors.New("relayblind: privacy enrollment keys are not fresh")
)

// PrivacyEnrollment is one SPEC-049-R025 durable enrollment row. Keys are
// public: identity in canonical base64url, Secure Enclave in standard base64.
type PrivacyEnrollment struct {
	ProviderID          string
	IdentityPublicKey   string
	IdentityFingerprint string
	SEPublicKey         string
	SEFingerprint       string
	TeamID              string
	SigningIdentifier   string
	CodeCDHash          string
	BinaryVersion       string
	EnrolledAtUnix      int64
	RevokedAtUnix       int64
	RevokedReason       string
}

func (s *Store) ensureEnrollmentSchema(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS privacy_class_enrollment (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  provider_id TEXT NOT NULL,
  identity_public_key TEXT NOT NULL,
  identity_fingerprint TEXT NOT NULL,
  se_public_key TEXT NOT NULL,
  se_fingerprint TEXT NOT NULL,
  team_id TEXT NOT NULL,
  signing_identifier TEXT NOT NULL,
  code_cdhash TEXT NOT NULL,
  binary_version TEXT NOT NULL,
  enrolled_at_unix INTEGER NOT NULL,
  revoked_at_unix INTEGER NULL,
  revoked_reason TEXT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_privacy_enrollment_active_provider ON privacy_class_enrollment(provider_id) WHERE revoked_at_unix IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_privacy_enrollment_active_identity ON privacy_class_enrollment(identity_fingerprint) WHERE revoked_at_unix IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_privacy_enrollment_active_se ON privacy_class_enrollment(se_fingerprint) WHERE revoked_at_unix IS NULL;
CREATE INDEX IF NOT EXISTS idx_privacy_enrollment_revoked ON privacy_class_enrollment(revoked_at_unix);
CREATE TABLE IF NOT EXISTS privacy_class_operator_clear (
  provider_id TEXT PRIMARY KEY,
  cleared_at_unix INTEGER NOT NULL
);`)
	if err != nil {
		return fmt.Errorf("%w: migrate privacy enrollment: %v", ErrStoreUnavailable, err)
	}
	return nil
}

const enrollmentColumns = `provider_id,identity_public_key,identity_fingerprint,se_public_key,se_fingerprint,team_id,signing_identifier,code_cdhash,binary_version,enrolled_at_unix,COALESCE(revoked_at_unix,0),COALESCE(revoked_reason,'')`

func scanEnrollment(row rowScanner) (PrivacyEnrollment, error) {
	var e PrivacyEnrollment
	err := row.Scan(&e.ProviderID, &e.IdentityPublicKey, &e.IdentityFingerprint, &e.SEPublicKey, &e.SEFingerprint, &e.TeamID, &e.SigningIdentifier, &e.CodeCDHash, &e.BinaryVersion, &e.EnrolledAtUnix, &e.RevokedAtUnix, &e.RevokedReason)
	return e, err
}

// ActivePrivacyEnrollment returns the provider's one unrevoked enrollment.
func (s *Store) ActivePrivacyEnrollment(ctx context.Context, providerID string) (PrivacyEnrollment, bool, error) {
	if s == nil || s.db == nil {
		return PrivacyEnrollment{}, false, ErrStoreUnavailable
	}
	e, err := scanEnrollment(s.db.QueryRowContext(ctx, `SELECT `+enrollmentColumns+` FROM privacy_class_enrollment WHERE provider_id=? AND revoked_at_unix IS NULL`, providerID))
	if errors.Is(err, sql.ErrNoRows) {
		return PrivacyEnrollment{}, false, nil
	}
	if err != nil {
		return PrivacyEnrollment{}, false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return e, true, nil
}

// EnrollPrivacyIdentity inserts the provider's first active enrollment. An
// identical active enrollment is idempotent; a different one is
// ErrEnrollmentKeyChanged and is never overwritten; a key active for another
// provider is ErrEnrollmentKeyInUse.
func (s *Store) EnrollPrivacyIdentity(ctx context.Context, e PrivacyEnrollment) error {
	return s.enrollPrivacyIdentity(ctx, e, "", nil, time.Time{})
}

// EnrollPrivacyIdentityForSession enrolls only if every listed key digest is
// still fresh and unrevoked for assignedSession, checked inside the same
// transaction as the insert (SPEC-049-R025).
func (s *Store) EnrollPrivacyIdentityForSession(ctx context.Context, assignedSession string, digests []string, now time.Time, e PrivacyEnrollment) error {
	if strings.TrimSpace(assignedSession) == "" || len(digests) == 0 {
		return ErrEnrollmentKeysStale
	}
	return s.enrollPrivacyIdentity(ctx, e, assignedSession, digests, now)
}

func (s *Store) enrollPrivacyIdentity(ctx context.Context, e PrivacyEnrollment, assignedSession string, digests []string, now time.Time) error {
	if s == nil || s.db == nil {
		return ErrStoreUnavailable
	}
	if strings.TrimSpace(e.ProviderID) == "" || e.IdentityFingerprint == "" || e.SEFingerprint == "" {
		return fmt.Errorf("%w: enrollment fields", ErrInvalidPrivacy)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	for _, digest := range digests {
		var fresh int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM relay_blind_key_records WHERE provider_id=? AND assigned_session=? AND key_record_digest=? AND key_class=? AND revoked_at_unix IS NULL AND not_before_unix<=? AND expires_at_unix>?`, e.ProviderID, assignedSession, digest, KeyClassPrivacy, now.Unix(), now.Unix()).Scan(&fresh); err != nil {
			return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		if fresh == 0 {
			return ErrEnrollmentKeysStale
		}
	}
	existing, err := scanEnrollment(tx.QueryRowContext(ctx, `SELECT `+enrollmentColumns+` FROM privacy_class_enrollment WHERE provider_id=? AND revoked_at_unix IS NULL`, e.ProviderID))
	switch {
	case err == nil:
		if existing.IdentityPublicKey == e.IdentityPublicKey && existing.SEPublicKey == e.SEPublicKey {
			return nil
		}
		return ErrEnrollmentKeyChanged
	case !errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	var inUse int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM privacy_class_enrollment WHERE revoked_at_unix IS NULL AND provider_id<>? AND (identity_fingerprint=? OR se_fingerprint=?)`, e.ProviderID, e.IdentityFingerprint, e.SEFingerprint).Scan(&inUse); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if inUse > 0 {
		return ErrEnrollmentKeyInUse
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO privacy_class_enrollment(provider_id,identity_public_key,identity_fingerprint,se_public_key,se_fingerprint,team_id,signing_identifier,code_cdhash,binary_version,enrolled_at_unix) VALUES(?,?,?,?,?,?,?,?,?,?)`,
		e.ProviderID, e.IdentityPublicKey, e.IdentityFingerprint, e.SEPublicKey, e.SEFingerprint, e.TeamID, e.SigningIdentifier, e.CodeCDHash, e.BinaryVersion, e.EnrolledAtUnix); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return nil
}

// ReenrollPrivacyProvider is the SPEC-049-R026 operator re-enrollment: it
// revokes the active enrollment, revokes the provider's privacy key records,
// rejects its held predispatch privacy reservations, and clears its
// quarantine in one transaction. It reports whether an enrollment was active.
func (s *Store) ReenrollPrivacyProvider(ctx context.Context, providerID, reason string, now time.Time, replayRetention time.Duration) (bool, error) {
	if s == nil || s.db == nil {
		return false, ErrStoreUnavailable
	}
	if strings.TrimSpace(providerID) == "" {
		return false, fmt.Errorf("%w: provider id", ErrInvalidKeyRecord)
	}
	reason = boundPrivacyReason(reason)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `UPDATE privacy_class_enrollment SET revoked_at_unix=?,revoked_reason=? WHERE provider_id=? AND revoked_at_unix IS NULL`, now.Unix(), reason, providerID)
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	retainedUntil := now.Add(replayRetention).Unix()
	if _, err := tx.ExecContext(ctx, `UPDATE relay_blind_key_records SET revoked_at_unix=?,revocation_retained_until_unix=MAX(expires_at_unix,?) WHERE provider_id=? AND key_class=? AND revoked_at_unix IS NULL`, now.Unix(), retainedUntil, providerID, KeyClassPrivacy); err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE relay_blind_reservations SET state='rejected',terminal_code='relay_blind_key_expired',terminal_at_unix=? WHERE provider_id=? AND privacy_class=1 AND state IN ('reserved','consumed_predispatch')`, now.Unix(), providerID); err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM privacy_class_quarantine WHERE provider_id=?`, providerID); err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	if err := markOperatorClear(ctx, tx, providerID, now); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return changed > 0, nil
}

type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

// markOperatorClear records an operator unquarantine or reenroll, so an
// in-memory quarantine latch from before it is dropped, not re-applied.
func markOperatorClear(ctx context.Context, db execer, providerID string, now time.Time) error {
	if _, err := db.ExecContext(ctx, `INSERT INTO privacy_class_operator_clear(provider_id,cleared_at_unix) VALUES(?,?) ON CONFLICT(provider_id) DO UPDATE SET cleared_at_unix=excluded.cleared_at_unix`, providerID, now.Unix()); err != nil {
		return fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return nil
}

// OperatorClearedSince reports an operator unquarantine or reenroll of the
// provider at or after since.
func (s *Store) OperatorClearedSince(ctx context.Context, providerID string, since time.Time) (bool, error) {
	if s == nil || s.db == nil {
		return false, ErrStoreUnavailable
	}
	var cleared int64
	err := s.db.QueryRowContext(ctx, `SELECT cleared_at_unix FROM privacy_class_operator_clear WHERE provider_id=?`, providerID).Scan(&cleared)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return cleared >= since.Unix(), nil
}

// ListPrivacyEnrollments returns every active enrollment and every
// enrollment revoked at or after revokedSince, ordered by provider ID.
func (s *Store) ListPrivacyEnrollments(ctx context.Context, revokedSince time.Time) ([]PrivacyEnrollment, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreUnavailable
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+enrollmentColumns+` FROM privacy_class_enrollment WHERE revoked_at_unix IS NULL OR revoked_at_unix>=? ORDER BY provider_id,id`, revokedSince.Unix())
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	defer rows.Close()
	var out []PrivacyEnrollment
	for rows.Next() {
		e, err := scanEnrollment(rows)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return out, nil
}

// QuarantinedProviders returns the provider IDs whose quarantine is unexpired.
func (s *Store) QuarantinedProviders(ctx context.Context, now time.Time) (map[string]struct{}, error) {
	items, err := s.ListPrivacyQuarantines(ctx, now)
	if err != nil {
		return nil, err
	}
	out := make(map[string]struct{}, len(items))
	for _, item := range items {
		out[item.ProviderID] = struct{}{}
	}
	return out, nil
}
