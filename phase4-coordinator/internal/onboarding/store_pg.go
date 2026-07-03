package onboarding

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/lib/pq"
)

const registerNonceWindow = 65 * time.Second

type PGStore struct {
	db *sql.DB
}

func OpenPGStore(dsn string) (*PGStore, error) {
	dsn = strings.TrimSpace(dsn)
	if dsn == "" {
		return nil, errors.New("onboarding postgres dsn is required")
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open onboarding postgres: %w", err)
	}
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(4)
	db.SetConnMaxLifetime(30 * time.Minute)
	db.SetConnMaxIdleTime(5 * time.Minute)
	return &PGStore{db: db}, nil
}

func (s *PGStore) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *PGStore) Smoke(ctx context.Context) error {
	if s == nil || s.db == nil {
		return errors.New("onboarding postgres store is nil")
	}
	timeout, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var currentUser string
	if err := s.db.QueryRowContext(timeout, `SELECT current_user`).Scan(&currentUser); err != nil {
		return fmt.Errorf("provider_onboarding smoke current_user: %w", err)
	}
	if currentUser != "provider_onboarding" {
		return fmt.Errorf("provider_onboarding smoke current_user = %q, want provider_onboarding", currentUser)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT 1 FROM provider_identities LIMIT 1`); err != nil {
		return fmt.Errorf("provider_onboarding smoke provider_identities read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT 1 FROM provider_register_nonces LIMIT 1`); err != nil {
		return fmt.Errorf("provider_onboarding smoke provider_register_nonces read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT 1 FROM provider_auth_policy LIMIT 1`); err != nil {
		return fmt.Errorf("provider_onboarding smoke provider_auth_policy read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT 1 FROM provider_auth_policy_pending LIMIT 1`); err == nil {
		return errors.New("provider_onboarding smoke unexpectedly read provider_auth_policy_pending")
	} else if !strings.Contains(strings.ToLower(err.Error()), "permission denied") {
		return fmt.Errorf("provider_onboarding smoke provider_auth_policy_pending deny check: %w", err)
	}
	return nil
}

func (s *PGStore) UpsertProviderIdentity(ctx context.Context, providerID string, identityPubkey []byte, attested bool, appAttestKeyID []byte) error {
	if s == nil || s.db == nil {
		return errors.New("onboarding postgres store is nil")
	}
	var key any
	if len(appAttestKeyID) > 0 {
		key = appAttestKeyID
	}
	var out string
	err := s.db.QueryRowContext(ctx, `
INSERT INTO provider_identities (provider_id, identity_pubkey, attested, app_attest_key_id)
VALUES ($1, $2, $3, $4)
ON CONFLICT (provider_id) DO UPDATE
   SET attested = provider_identities.attested OR EXCLUDED.attested,
       app_attest_key_id = COALESCE(provider_identities.app_attest_key_id, EXCLUDED.app_attest_key_id)
 WHERE provider_identities.identity_pubkey = EXCLUDED.identity_pubkey
RETURNING provider_id`,
		providerID, identityPubkey, attested, key,
	).Scan(&out)
	if err == sql.ErrNoRows {
		return ErrTOFUConflict
	}
	if err != nil {
		if isUniqueViolation(err) {
			return ErrAttestKeyReused
		}
		return err
	}
	return nil
}

func (s *PGStore) InsertRegisterNonce(ctx context.Context, providerID, sourceIP, nonce string, observedAt time.Time) error {
	if s == nil || s.db == nil {
		return errors.New("onboarding postgres store is nil")
	}
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	observedAt = observedAt.UTC()
	cutoffStart := observedAt.Add(-registerNonceWindow)
	cutoffEnd := observedAt.Add(registerNonceWindow)
	var exists bool
	if err := tx.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1 FROM provider_register_nonces
     WHERE provider_id = $1 AND nonce = $2 AND ts_utc BETWEEN $3 AND $4
)`, providerID, nonce, cutoffStart, cutoffEnd).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return ErrNonceReplay
	}
	if err := tx.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1 FROM provider_register_nonces
     WHERE source_ip = $1 AND nonce = $2 AND ts_utc BETWEEN $3 AND $4
)`, sourceIP, nonce, cutoffStart, cutoffEnd).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return ErrNonceReplay
	}
	if _, err := tx.ExecContext(ctx, `
INSERT INTO provider_register_nonces (provider_id, source_ip, nonce, ts_utc)
VALUES ($1, $2, $3, $4)`, providerID, sourceIP, nonce, observedAt); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		if isSerializationFailure(err) {
			return ErrNonceReplay
		}
		return err
	}
	return nil
}

func (s *PGStore) CheckAppAttestKeyIDUnique(ctx context.Context, keyID []byte, providerID string) error {
	if len(keyID) == 0 {
		return nil
	}
	var existing string
	err := s.db.QueryRowContext(ctx, `
SELECT provider_id FROM provider_identities
 WHERE app_attest_key_id = $1 AND provider_id <> $2
 LIMIT 1`, keyID, providerID).Scan(&existing)
	if err == sql.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	return ErrAttestKeyReused
}

func (s *PGStore) LookupProviderAuthPolicy(ctx context.Context, providerID string) (*time.Time, string, bool, error) {
	if s == nil || s.db == nil {
		return nil, "", false, errors.New("onboarding postgres store is nil")
	}
	var exempt sql.NullTime
	var grantedBy string
	err := s.db.QueryRowContext(ctx, `
SELECT signature_exempt_until, granted_by
  FROM provider_auth_policy
 WHERE provider_id = $1`, providerID).Scan(&exempt, &grantedBy)
	if err == sql.ErrNoRows {
		return nil, "", false, nil
	}
	if err != nil {
		return nil, "", false, err
	}
	if !exempt.Valid {
		return nil, grantedBy, true, nil
	}
	t := exempt.Time.UTC()
	return &t, grantedBy, true, nil
}

func (s *PGStore) LookupProviderIdentityPubkey(ctx context.Context, providerID string) ([]byte, bool, error) {
	if s == nil || s.db == nil {
		return nil, false, errors.New("onboarding postgres store is nil")
	}
	var pubkey []byte
	err := s.db.QueryRowContext(ctx, `
SELECT identity_pubkey
  FROM provider_identities
 WHERE provider_id = $1`, providerID).Scan(&pubkey)
	if err == sql.ErrNoRows {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return append([]byte(nil), pubkey...), true, nil
}

func (s *PGStore) RequestProviderAuthPolicyExemption(ctx context.Context, pendingID, providerID, requestedBy string, requestedUntil time.Time, reason, incidentID string) error {
	if s == nil || s.db == nil {
		return errors.New("onboarding postgres store is nil")
	}
	var out string
	err := s.db.QueryRowContext(ctx, `
SELECT request_provider_auth_policy_exemption($1::uuid, $2, $3, $4, $5, NULLIF($6, ''))::text`,
		pendingID, providerID, requestedBy, requestedUntil.UTC(), reason, incidentID,
	).Scan(&out)
	if err != nil {
		return err
	}
	if out != pendingID {
		return fmt.Errorf("provider_auth_policy request returned pending_id %q, want %q", out, pendingID)
	}
	return nil
}

func (s *PGStore) ApproveProviderAuthPolicyExemption(ctx context.Context, pendingID, approvedBy string) (providerID, requestedBy string, requestedUntil time.Time, reason, incidentID string, err error) {
	if s == nil || s.db == nil {
		err = errors.New("onboarding postgres store is nil")
		return
	}
	var incident sql.NullString
	err = s.db.QueryRowContext(ctx, `
SELECT provider_id, requested_by, requested_until, reason, incident_id
  FROM approve_provider_auth_policy_exemption($1::uuid, $2)`,
		pendingID, approvedBy,
	).Scan(&providerID, &requestedBy, &requestedUntil, &reason, &incident)
	if incident.Valid {
		incidentID = incident.String
	}
	requestedUntil = requestedUntil.UTC()
	return
}

func (s *PGStore) SeedProviderAuthPolicyCutover(ctx context.Context, cutover time.Time, cliProviderIDs []string) (int64, error) {
	if s == nil || s.db == nil {
		return 0, errors.New("onboarding postgres store is nil")
	}
	var seeded int64
	err := s.db.QueryRowContext(ctx, `
SELECT seed_provider_auth_policy_cutover($1, $2::text[])`,
		cutover.UTC(), pq.Array(cliProviderIDs),
	).Scan(&seeded)
	return seeded, err
}

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "duplicate key") || strings.Contains(msg, "unique constraint")
}

func isSerializationFailure(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "could not serialize") || strings.Contains(msg, "serialization")
}
