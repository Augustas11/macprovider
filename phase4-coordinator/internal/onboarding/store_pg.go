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
	db                  *sql.DB
	authPolicyRequestDB *sql.DB
	authPolicyApproveDB *sql.DB
	authPolicyCutoverDB *sql.DB
}

func OpenPGStore(dsn string) (*PGStore, error) {
	db, err := openPostgresDB(dsn, "onboarding")
	if err != nil {
		return nil, err
	}
	return &PGStore{db: db}, nil
}

func OpenPGStoreWithAuthPolicyDSNs(onboardingDSN, requestDSN, approveDSN, cutoverDSN string) (*PGStore, error) {
	db, err := openPostgresDB(onboardingDSN, "onboarding")
	if err != nil {
		return nil, err
	}
	requestDB, err := openPostgresDB(requestDSN, "provider auth policy request")
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	approveDB, err := openPostgresDB(approveDSN, "provider auth policy approve")
	if err != nil {
		_ = db.Close()
		_ = requestDB.Close()
		return nil, err
	}
	cutoverDB, err := openPostgresDB(cutoverDSN, "provider auth policy cutover")
	if err != nil {
		_ = db.Close()
		_ = requestDB.Close()
		_ = approveDB.Close()
		return nil, err
	}
	return &PGStore{
		db:                  db,
		authPolicyRequestDB: requestDB,
		authPolicyApproveDB: approveDB,
		authPolicyCutoverDB: cutoverDB,
	}, nil
}

func openPostgresDB(dsn, name string) (*sql.DB, error) {
	dsn = strings.TrimSpace(dsn)
	if dsn == "" {
		return nil, fmt.Errorf("%s postgres dsn is required", name)
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open %s postgres: %w", name, err)
	}
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(4)
	db.SetConnMaxLifetime(30 * time.Minute)
	db.SetConnMaxIdleTime(5 * time.Minute)
	return db, nil
}

func (s *PGStore) Close() error {
	if s == nil {
		return nil
	}
	var err error
	seen := map[*sql.DB]bool{}
	for _, db := range []*sql.DB{s.db, s.authPolicyRequestDB, s.authPolicyApproveDB, s.authPolicyCutoverDB} {
		if db == nil || seen[db] {
			continue
		}
		seen[db] = true
		err = errors.Join(err, db.Close())
	}
	return err
}

// DB exposes the primary onboarding postgres handle for read-only consumers
// such as the proof-of-weights autotune hello gate.
func (s *PGStore) DB() *sql.DB {
	if s == nil {
		return nil
	}
	return s.db
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
	if _, err := s.db.ExecContext(timeout, `SELECT provider_id, chip_normalized, unified_memory_gb, verified, last_reported_at FROM provider_hardware_profiles LIMIT 1`); err != nil {
		return fmt.Errorf("provider_onboarding smoke provider_hardware_profiles read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT id, status, decision_reason, evidence_sha256 FROM hardware_verification_jobs LIMIT 1`); err != nil {
		return fmt.Errorf("provider_onboarding smoke hardware_verification_jobs read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `
SELECT j.generated_at, j.evidence
  FROM hardware_verification_jobs j
  JOIN provider_hardware_profiles p
    ON p.provider_id = j.provider_id
   AND p.verified = TRUE
   AND p.chip_normalized = j.chip_normalized
   AND p.unified_memory_gb = j.unified_memory_gb
 WHERE j.provider_id = ''
   AND j.status = 'verified'
 LIMIT 0`); err != nil {
		return fmt.Errorf("provider_onboarding smoke autotune hello gate evidence read: %w", err)
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
	if s.authPolicyRequestDB != nil {
		if err := smokeAuthPolicyRole(timeout, s.authPolicyRequestDB, "provider_auth_policy_requester",
			"request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)",
			"approve_provider_auth_policy_exemption(uuid,text)",
			"seed_provider_auth_policy_cutover(timestamp with time zone,text[])"); err != nil {
			return err
		}
	}
	if s.authPolicyApproveDB != nil {
		if err := smokeAuthPolicyRole(timeout, s.authPolicyApproveDB, "provider_auth_policy_approver",
			"approve_provider_auth_policy_exemption(uuid,text)",
			"request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)",
			"seed_provider_auth_policy_cutover(timestamp with time zone,text[])"); err != nil {
			return err
		}
	}
	if s.authPolicyCutoverDB != nil {
		if err := smokeAuthPolicyRole(timeout, s.authPolicyCutoverDB, "provider_auth_policy_cutover",
			"seed_provider_auth_policy_cutover(timestamp with time zone,text[])",
			"request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)",
			"approve_provider_auth_policy_exemption(uuid,text)"); err != nil {
			return err
		}
	}
	return nil
}

func smokeAuthPolicyRole(ctx context.Context, db *sql.DB, wantUser, allowedFunction string, forbiddenFunctions ...string) error {
	var currentUser, sessionUser string
	var superUser, createDB, createRole, inherit, replication, bypassRLS bool
	if err := db.QueryRowContext(ctx, `
SELECT current_user, session_user, r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolinherit, r.rolreplication, r.rolbypassrls
  FROM pg_roles r
 WHERE r.rolname = current_user`).Scan(&currentUser, &sessionUser, &superUser, &createDB, &createRole, &inherit, &replication, &bypassRLS); err != nil {
		return fmt.Errorf("%s smoke current_user: %w", wantUser, err)
	}
	if currentUser != wantUser {
		return fmt.Errorf("%s smoke current_user = %q, want %s", wantUser, currentUser, wantUser)
	}
	if sessionUser != currentUser {
		return fmt.Errorf("%s smoke session_user = %q, want same as current_user", wantUser, sessionUser)
	}
	if superUser || createDB || createRole || inherit || replication || bypassRLS {
		return fmt.Errorf("%s smoke role has superuser=%t createdb=%t createrole=%t inherit=%t replication=%t bypassrls=%t",
			wantUser, superUser, createDB, createRole, inherit, replication, bypassRLS)
	}
	var allowed bool
	if err := db.QueryRowContext(ctx, `
SELECT has_function_privilege(current_user, $1::regprocedure, 'EXECUTE')`,
		allowedFunction,
	).Scan(&allowed); err != nil {
		return fmt.Errorf("%s smoke function privilege: %w", wantUser, err)
	}
	if !allowed {
		return fmt.Errorf("%s smoke lacks EXECUTE on %s", wantUser, allowedFunction)
	}
	var hasMembership bool
	if err := db.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1
      FROM pg_auth_members m
      JOIN pg_roles granted ON granted.oid = m.roleid
      JOIN pg_roles member ON member.oid = m.member
     WHERE member.rolname = current_user
        OR granted.rolname = current_user
)`).Scan(&hasMembership); err != nil {
		return fmt.Errorf("%s smoke role membership check: %w", wantUser, err)
	}
	if hasMembership {
		return fmt.Errorf("%s smoke role must not have role memberships", wantUser)
	}
	var hasDirectTablePrivilege bool
	if err := db.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1
      FROM (VALUES
            ('provider_identities'),
            ('provider_auth_policy'),
            ('provider_auth_policy_cutover_runs'),
            ('provider_auth_policy_pending'),
            ('provider_auth_policy_grants')
           ) AS t(table_name)
      CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS p(privilege_name)
     WHERE has_table_privilege(current_user, t.table_name, p.privilege_name)
)`).Scan(&hasDirectTablePrivilege); err != nil {
		return fmt.Errorf("%s smoke direct table privilege check: %w", wantUser, err)
	}
	if hasDirectTablePrivilege {
		return fmt.Errorf("%s smoke role must not have direct auth-policy table privileges", wantUser)
	}
	for _, functionSignature := range forbiddenFunctions {
		if err := db.QueryRowContext(ctx, `
SELECT has_function_privilege(current_user, $1::regprocedure, 'EXECUTE')`,
			functionSignature,
		).Scan(&allowed); err != nil {
			return fmt.Errorf("%s smoke forbidden function privilege: %w", wantUser, err)
		}
		if allowed {
			return fmt.Errorf("%s smoke unexpectedly has EXECUTE on %s", wantUser, functionSignature)
		}
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

func (s *PGStore) UpsertProviderHardwareProfile(ctx context.Context, providerID string, summary HardwareSummary, observedAt time.Time) error {
	if s == nil || s.db == nil {
		return errors.New("onboarding postgres store is nil")
	}
	chip := trimForStorage(summary.Chip, 120)
	normalized := normalizeChip(chip)
	macosVersion := trimForStorage(summary.MacOSVersion, 80)
	appVersion := trimForStorage(summary.AppVersion, 80)
	memoryGB := summary.UnifiedMemoryGB
	if memoryGB < 0 {
		memoryGB = 0
	}
	if memoryGB > 4096 {
		memoryGB = 4096
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO provider_hardware_profiles (
    provider_id, chip, chip_normalized, unified_memory_gb,
    macos_version, app_version, source, last_reported_at
) VALUES (
    $1, $2, $3, $4, $5, $6, 'app_register', $7
)
ON CONFLICT (provider_id) DO UPDATE
   SET chip = EXCLUDED.chip,
       chip_normalized = EXCLUDED.chip_normalized,
       unified_memory_gb = EXCLUDED.unified_memory_gb,
       macos_version = EXCLUDED.macos_version,
       app_version = EXCLUDED.app_version,
       source = EXCLUDED.source,
       last_reported_at = EXCLUDED.last_reported_at
 WHERE provider_hardware_profiles.last_reported_at <= EXCLUDED.last_reported_at`,
		providerID, chip, normalized, memoryGB, macosVersion, appVersion, observedAt.UTC(),
	)
	return err
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

// PrepareProviderRegistration commits replay protection and provider identity
// as one PostgreSQL unit before the SQLite credential authority is entered.
// A referral is preflighted before this method and authoritatively redeemed
// afterward, so PostgreSQL latency never runs under SQLite's writer lock.
func (s *PGStore) PrepareProviderRegistration(ctx context.Context, providerID, sourceIP, nonce string, observedAt time.Time, identityPubkey []byte, attested bool, appAttestKeyID []byte) error {
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

	var key any
	if len(appAttestKeyID) > 0 {
		key = appAttestKeyID
	}
	var out string
	err = tx.QueryRowContext(ctx, `
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

// ProviderRegistrationPrepared proves that the exact PostgreSQL half of a
// cross-store App-track registration committed. Checking both its nonce row
// and identity row avoids mistaking an older identity for the current attempt
// during crash recovery.
func (s *PGStore) ProviderRegistrationPrepared(ctx context.Context, providerID, sourceIP, nonce string, observedAt time.Time) (bool, error) {
	if s == nil || s.db == nil {
		return false, errors.New("onboarding postgres store is nil")
	}
	var prepared bool
	err := s.db.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1
      FROM provider_register_nonces n
      JOIN provider_identities i ON i.provider_id = n.provider_id
     WHERE n.provider_id = $1
       AND n.source_ip = $2
       AND n.nonce = $3
       AND n.ts_utc = $4
)`, providerID, sourceIP, nonce, observedAt.UTC()).Scan(&prepared)
	return prepared, err
}

func normalizeChip(chip string) string {
	chip = strings.ToLower(strings.TrimSpace(chip))
	return strings.Join(strings.Fields(chip), " ")
}

func trimForStorage(s string, maxRunes int) string {
	s = strings.TrimSpace(s)
	if maxRunes <= 0 {
		return s
	}
	runes := []rune(s)
	if len(runes) <= maxRunes {
		return s
	}
	return string(runes[:maxRunes])
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
	if s == nil || s.authPolicyRequestDB == nil {
		return errors.New("provider auth policy request postgres store is nil")
	}
	var out string
	err := s.authPolicyRequestDB.QueryRowContext(ctx, `
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
	if s == nil || s.authPolicyApproveDB == nil {
		err = errors.New("provider auth policy approve postgres store is nil")
		return
	}
	var incident sql.NullString
	err = s.authPolicyApproveDB.QueryRowContext(ctx, `
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
	if s == nil || s.authPolicyCutoverDB == nil {
		return 0, errors.New("provider auth policy cutover postgres store is nil")
	}
	var seeded int64
	err := s.authPolicyCutoverDB.QueryRowContext(ctx, `
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
