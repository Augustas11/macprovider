package onboarding

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

const registerNonceWindow = 65 * time.Second

type PGStore struct {
	db                     *sql.DB
	authPolicyRequestDB    *sql.DB
	authPolicyApproveDB    *sql.DB
	authPolicyCutoverDB    *sql.DB
	hardwareTrustRequestDB *sql.DB
	hardwareTrustApproveDB *sql.DB
}

func OpenPGStore(dsn string) (*PGStore, error) {
	db, err := openPostgresDB(dsn, "onboarding")
	if err != nil {
		return nil, err
	}
	return &PGStore{db: db}, nil
}

func OpenPGStoreWithAuthPolicyDSNs(onboardingDSN, requestDSN, approveDSN, cutoverDSN, hardwareTrustRequestDSN, hardwareTrustApproveDSN string) (*PGStore, error) {
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
	hardwareTrustRequestDB, err := openPostgresDB(hardwareTrustRequestDSN, "hardware trust request")
	if err != nil {
		_ = db.Close()
		_ = requestDB.Close()
		_ = approveDB.Close()
		_ = cutoverDB.Close()
		return nil, err
	}
	hardwareTrustApproveDB, err := openPostgresDB(hardwareTrustApproveDSN, "hardware trust approve")
	if err != nil {
		_ = db.Close()
		_ = requestDB.Close()
		_ = approveDB.Close()
		_ = cutoverDB.Close()
		_ = hardwareTrustRequestDB.Close()
		return nil, err
	}
	return &PGStore{
		db:                     db,
		authPolicyRequestDB:    requestDB,
		authPolicyApproveDB:    approveDB,
		authPolicyCutoverDB:    cutoverDB,
		hardwareTrustRequestDB: hardwareTrustRequestDB,
		hardwareTrustApproveDB: hardwareTrustApproveDB,
	}, nil
}

func openPostgresDB(dsn, name string) (*sql.DB, error) {
	dsn = strings.TrimSpace(dsn)
	if dsn == "" {
		return nil, fmt.Errorf("%s postgres dsn is required", name)
	}
	// lib/pq's sql.Open defers DSN parsing, so a malformed connection string does
	// not fail here — it surfaces later (e.g. at Smoke) as a net/url.Error that
	// echoes the credential-bearing URL into fatal startup logs. Build the
	// connector eagerly via pq.NewConnector so the parse happens now, and on
	// failure report ONLY the config handle name, never the raw driver error or
	// the DSN value (issue #582 FIX 6/FIX 9).
	connector, err := pq.NewConnector(dsn)
	if err != nil {
		return nil, fmt.Errorf("open %s postgres: invalid connection string (redacted)", name)
	}
	db := sql.OpenDB(connector)
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
	for _, db := range []*sql.DB{s.db, s.authPolicyRequestDB, s.authPolicyApproveDB, s.authPolicyCutoverDB, s.hardwareTrustRequestDB, s.hardwareTrustApproveDB} {
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
	if _, err := s.db.ExecContext(timeout, `SELECT chip_normalized FROM chip_hardware_profiles LIMIT 0`); err != nil {
		return fmt.Errorf("provider_onboarding smoke chip_hardware_profiles read: %w", err)
	}
	// FIX 7 (round-8, issue #582): exercise the FULL LatestVerified admission join
	// shape, including the EXISTS on hardware_verification_trust that the round-6
	// live-trust re-check added (internal/autotune/evidence_pg.go). Without the trust
	// EXISTS here a missing/drifted SELECT grant on hardware_verification_trust for
	// provider_onboarding would pass startup smoke and deploy, then break every gated
	// hello at runtime. LIMIT 0 keeps it a pure privilege/shape probe.
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
   AND EXISTS (
       SELECT 1
         FROM hardware_verification_trust t
        WHERE t.provider_id = j.provider_id
          AND t.hardware_identity_hash = j.evidence -> 'hardware' ->> 'hardware_identity_hash'
          AND t.chip_normalized = j.chip_normalized
          AND t.unified_memory_gb = j.unified_memory_gb
          AND (t.expires_at IS NULL OR t.expires_at > now())
   )
 LIMIT 0`); err != nil {
		return fmt.Errorf("provider_onboarding smoke autotune hello gate evidence read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT 1 FROM provider_register_nonces LIMIT 1`); err != nil {
		return fmt.Errorf("provider_onboarding smoke provider_register_nonces read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT 1 FROM provider_register_attempts LIMIT 1`); err != nil {
		return fmt.Errorf("provider_onboarding smoke provider_register_attempts read: %w", err)
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
	if s.hardwareTrustRequestDB != nil {
		if err := smokeHardwareTrustRole(timeout, s.hardwareTrustRequestDB, "hardware_trust_requester",
			[]string{"request_hardware_trust_approval(uuid,bigint,text,timestamp with time zone,text,text)"},
			"approve_hardware_trust_approval(uuid,text)",
			"revoke_hardware_trust_approval(uuid,text,text,text,text)"); err != nil {
			return err
		}
	}
	if s.hardwareTrustApproveDB != nil {
		// The approver role executes both approve and revoke; verify EXECUTE on
		// both and confirm it lacks request (issue #582).
		if err := smokeHardwareTrustRole(timeout, s.hardwareTrustApproveDB, "hardware_trust_approver",
			[]string{
				"approve_hardware_trust_approval(uuid,text)",
				"revoke_hardware_trust_approval(uuid,text,text,text,text)",
			},
			"request_hardware_trust_approval(uuid,bigint,text,timestamp with time zone,text,text)"); err != nil {
			return err
		}
	}
	return nil
}

// smokeHardwareTrustRole mirrors smokeAuthPolicyRole for the hardware-trust
// request/approve roles: it fails startup loudly if a DSN authenticates as the
// wrong role, carries role memberships, holds direct table privileges on the
// trust workflow tables, or lacks/holds the wrong function EXECUTE grants.
func smokeHardwareTrustRole(ctx context.Context, db *sql.DB, wantUser string, allowedFunctions []string, forbiddenFunctions ...string) error {
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
	for _, allowedFunction := range allowedFunctions {
		if err := db.QueryRowContext(ctx, `
SELECT has_function_privilege(current_user, $1::regprocedure, 'EXECUTE')`,
			allowedFunction,
		).Scan(&allowed); err != nil {
			return fmt.Errorf("%s smoke function privilege: %w", wantUser, err)
		}
		if !allowed {
			return fmt.Errorf("%s smoke lacks EXECUTE on %s", wantUser, allowedFunction)
		}
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
            ('hardware_trust_pending'),
            ('hardware_trust_grants'),
            ('hardware_verification_trust')
           ) AS t(table_name)
      CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS p(privilege_name)
     WHERE has_table_privilege(current_user, t.table_name, p.privilege_name)
)`).Scan(&hasDirectTablePrivilege); err != nil {
		return fmt.Errorf("%s smoke direct table privilege check: %w", wantUser, err)
	}
	if hasDirectTablePrivilege {
		return fmt.Errorf("%s smoke role must not have direct hardware-trust table privileges", wantUser)
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
   SET chip = $2,
       chip_normalized = $3,
       unified_memory_gb = $4,
       macos_version = $5,
       app_version = $6,
       source = 'app_register',
       last_reported_at = $7
 WHERE provider_hardware_profiles.last_reported_at <= $7`,
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

// PrepareProviderRegistration atomically records replay protection, provider
// identity, and an exact durable attempt marker. App-track referral minting
// happens first in SQLite but remains undisclosed behind a pending saga until
// this transaction is known to have committed.
func (s *PGStore) PrepareProviderRegistration(ctx context.Context, providerID, sourceIP, nonce string, observedAt, attemptTS time.Time, identityPubkey []byte, attested bool, appAttestKeyID []byte) error {
	if s == nil || s.db == nil {
		return errors.New("onboarding postgres store is nil")
	}
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return err
	}
	defer tx.Rollback()

	observedAt = observedAt.UTC()
	attemptTS = attemptTS.UTC()
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
RETURNING provider_id`, providerID, identityPubkey, attested, key).Scan(&out)
	if errors.Is(err, sql.ErrNoRows) {
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
	if _, err := tx.ExecContext(ctx, `
INSERT INTO provider_register_attempts (provider_id, nonce, ts_utc, source_ip)
VALUES ($1, $2, $3, $4)
ON CONFLICT (provider_id, nonce, ts_utc) DO NOTHING`, providerID, nonce, attemptTS, sourceIP); err != nil {
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

// ProviderRegistrationPrepared checks only replay-stable, signed fields. The
// source IP is diagnostic and deliberately excluded from the commitment key.
func (s *PGStore) ProviderRegistrationPrepared(ctx context.Context, providerID, nonce string, attemptTS time.Time) (bool, error) {
	if s == nil || s.db == nil {
		return false, errors.New("onboarding postgres store is nil")
	}
	var prepared bool
	err := s.db.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1 FROM provider_register_attempts
     WHERE provider_id = $1 AND nonce = $2 AND ts_utc = $3
)`, providerID, nonce, attemptTS.UTC()).Scan(&prepared)
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

// WaitingTrustJob is a hardware-verification job parked in status
// waiting_trust, awaiting an operator trust approval (issue #582).
type WaitingTrustJob struct {
	JobID                int64
	ProviderID           string
	Chip                 string
	ChipNormalized       string
	UnifiedMemoryGB      int
	HardwareIdentityHash string
	DecisionReason       string
	ChipProfilePresent   bool
	SubmittedAt          time.Time
}

// RequestHardwareTrustApproval opens a dual-control request bound to a
// waiting_trust job. The trust tuple is derived server-side from the job row by
// the SECURITY DEFINER function (never client-supplied) and returned so the
// caller can echo/audit it.
func (s *PGStore) RequestHardwareTrustApproval(ctx context.Context, pendingID string, jobID int64, requestedBy string, expiresAt *time.Time, reason, incidentID string) (providerID, hardwareIdentityHash, chipNormalized string, unifiedMemoryGB int, err error) {
	if s == nil || s.hardwareTrustRequestDB == nil {
		err = errors.New("hardware trust request postgres store is nil")
		return
	}
	var expires interface{}
	if expiresAt != nil {
		expires = expiresAt.UTC()
	}
	var outPending string
	// Output columns are out_*-prefixed (migration 019 FIX 1) to avoid the
	// RETURNS TABLE / plpgsql.variable_conflict=error 42702 collision; scan them
	// positionally into the same destinations.
	err = s.hardwareTrustRequestDB.QueryRowContext(ctx, `
SELECT out_pending_id::text, out_provider_id, out_hardware_identity_hash, out_chip_normalized, out_unified_memory_gb
  FROM request_hardware_trust_approval($1::uuid, $2, $3, $4, $5, NULLIF($6, ''))`,
		pendingID, jobID, requestedBy, expires, reason, incidentID,
	).Scan(&outPending, &providerID, &hardwareIdentityHash, &chipNormalized, &unifiedMemoryGB)
	if err != nil {
		return
	}
	if outPending != pendingID {
		err = fmt.Errorf("hardware_trust request returned pending_id %q, want %q", outPending, pendingID)
		return
	}
	return
}

// RevokeHardwareTrustApproval inactivates an operator_api trust root (sets
// expires_at = now()) and writes an action='revoke' ledger row. Trust-reducing,
// so a single operator actor is acceptable, but it is operator-authenticated
// and audited (issue #582). nowUntrusted reports whether the provider is now
// FULLY untrusted for the hardware tuple — no active trust root of ANY source
// remains after the operator_api root was expired — so the caller can evict the
// live session only when no inventory root still backs it (issue #582 FIX 1).
func (s *PGStore) RevokeHardwareTrustApproval(ctx context.Context, providerID, hardwareIdentityHash, revokedBy, reason string) (chipNormalized string, unifiedMemoryGB int, nowUntrusted bool, err error) {
	if s == nil || s.hardwareTrustApproveDB == nil {
		err = errors.New("hardware trust approve postgres store is nil")
		return
	}
	var outProvider, outHash string
	err = s.hardwareTrustApproveDB.QueryRowContext(ctx, `
SELECT out_provider_id, out_hardware_identity_hash, out_chip_normalized, out_unified_memory_gb, out_now_untrusted
  FROM revoke_hardware_trust_approval($1::uuid, $2, $3, $4, $5)`,
		uuid.NewString(), providerID, hardwareIdentityHash, revokedBy, reason,
	).Scan(&outProvider, &outHash, &chipNormalized, &unifiedMemoryGB, &nowUntrusted)
	return
}

// ApproveHardwareTrustApproval commits a dual-control approval. The SQL function
// rejects a job whose evidence aged past the verifier's evidence-age limit AT
// approval time so the approval never commits a trust root the verifier would
// then reject as stale_job (issue #582 FIX 5). That limit is a definer-owned
// invariant HARDCODED inside approve_hardware_trust_approval (7 days, kept in
// sync with hardwareverify.MaxEvidenceAgeDays) rather than a caller parameter, so
// it cannot be bypassed.
func (s *PGStore) ApproveHardwareTrustApproval(ctx context.Context, pendingID, approvedBy string) (providerID, hardwareIdentityHash, chipNormalized string, unifiedMemoryGB int, expiresAt *time.Time, reason, incidentID, source string, effectiveExpiresAt *time.Time, err error) {
	if s == nil || s.hardwareTrustApproveDB == nil {
		err = errors.New("hardware trust approve postgres store is nil")
		return
	}
	var requestedUntil sql.NullTime
	var incident sql.NullString
	// Terminal structural fix (issue #582): approval always writes the operator_api
	// trust row and never rides an inventory root, so out_source is always
	// 'operator_api' and out_effective_expires_at is always the operator_api row's
	// expiry (requested_until). The handler surfaces these; the grant is always
	// operator-revocable.
	var effectiveExpires sql.NullTime
	err = s.hardwareTrustApproveDB.QueryRowContext(ctx, `
SELECT out_provider_id, out_hardware_identity_hash, out_chip_normalized, out_unified_memory_gb, out_requested_until, out_reason, out_incident_id, out_source, out_effective_expires_at
  FROM approve_hardware_trust_approval($1::uuid, $2)`,
		pendingID, approvedBy,
	).Scan(&providerID, &hardwareIdentityHash, &chipNormalized, &unifiedMemoryGB, &requestedUntil, &reason, &incident, &source, &effectiveExpires)
	if err != nil {
		return
	}
	if requestedUntil.Valid {
		until := requestedUntil.Time.UTC()
		expiresAt = &until
	}
	if incident.Valid {
		incidentID = incident.String
	}
	if effectiveExpires.Valid {
		eff := effectiveExpires.Time.UTC()
		effectiveExpiresAt = &eff
	}
	return
}

// WaitingTrustJobsPageCap bounds the number of waiting_trust jobs returned in a
// single ListWaitingTrustJobs page (issue #582).
const WaitingTrustJobsPageCap = 200

// ListWaitingTrustJobs returns a bounded, id-ordered page of waiting_trust jobs.
// afterID is an exclusive cursor (0 = from the start); limit is clamped to
// WaitingTrustJobsPageCap. Rows are ordered by id so the max id in the page is a
// stable next cursor.
func (s *PGStore) ListWaitingTrustJobs(ctx context.Context, afterID int64, limit int) ([]WaitingTrustJob, error) {
	if s == nil || s.db == nil {
		return nil, errors.New("onboarding postgres store is nil")
	}
	if limit <= 0 || limit > WaitingTrustJobsPageCap {
		limit = WaitingTrustJobsPageCap
	}
	if afterID < 0 {
		afterID = 0
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT j.id, j.provider_id, j.chip, j.chip_normalized, j.unified_memory_gb,
       COALESCE(j.evidence #>> '{hardware,hardware_identity_hash}', ''),
       j.decision_reason,
       EXISTS (
         SELECT 1
           FROM chip_hardware_profiles ch
          WHERE ch.chip_normalized = j.chip_normalized
       ) AS chip_profile_present,
       j.submitted_at
  FROM hardware_verification_jobs j
 WHERE j.status = 'waiting_trust'
   AND j.id > $1
 ORDER BY j.id ASC
 LIMIT $2`, afterID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var jobs []WaitingTrustJob
	for rows.Next() {
		var job WaitingTrustJob
		if err := rows.Scan(
			&job.JobID,
			&job.ProviderID,
			&job.Chip,
			&job.ChipNormalized,
			&job.UnifiedMemoryGB,
			&job.HardwareIdentityHash,
			&job.DecisionReason,
			&job.ChipProfilePresent,
			&job.SubmittedAt,
		); err != nil {
			return nil, err
		}
		job.SubmittedAt = job.SubmittedAt.UTC()
		jobs = append(jobs, job)
	}
	return jobs, rows.Err()
}

// providerTrustActiveQuery builds the read-only predicate behind both the
// active-session trust-revalidation sweep (issue #582 FIX A) and the
// registration-time re-check (FIX B). It mirrors the EXACT trust join
// internal/autotune/evidence_pg.go LatestVerified applies at admission: the
// provider's verified hardware tuple (a status='verified' job matched to a
// verified provider_hardware_profiles row on chip_normalized + unified_memory_gb)
// must still be backed by an UNEXPIRED hardware_verification_trust root for the
// same (provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb)
// tuple. It deliberately OMITS the evidence-age (TTL) cutoff LatestVerified also
// applies: revalidation evicts only on a revoked/expired trust ROOT, never on
// benchmark staleness (which self-heals on the next verified pass and must not
// drop an otherwise-trusted live session). clockExpr is the wall clock compared
// against expires_at — a $-bind for the sweep (portable to the SQLite unit-test
// harness), clock_timestamp() for the advisory-locked re-check (sampled AFTER the
// lock, matching revoke_hardware_trust_approval's post-lock clock so a root that
// lapsed during the lock wait reads as inactive). This is a read as
// provider_onboarding: SELECT on hardware_verification_trust and the join tables
// is already granted (migration 019); no write/EXECUTE on the trust functions.
func providerTrustActiveQuery(clockExpr string) string {
	return `SELECT ` + providerTrustActivePredicate("$1", clockExpr)
}

// providerTrustActivePredicate returns the boolean EXISTS(...) SQL fragment that
// is TRUE when an ACTIVE (unexpired, unrevoked) hardware trust root still backs
// the provider bound to providerExpr. providerExpr is the provider_id term ($1
// for the per-provider re-check, the unnested column for the batched sweep) and
// clockExpr is the wall clock compared against expires_at. Both the locked
// per-provider re-check (FIX B) and the batched sweep (FIX A) build on this one
// fragment so their active-trust semantics can never drift apart. The
// decision_reason bind is $2 in both callers.
func providerTrustActivePredicate(providerExpr, clockExpr string) string {
	return `EXISTS (
    SELECT 1
      FROM hardware_verification_jobs j
      JOIN provider_hardware_profiles p
        ON p.provider_id = j.provider_id
       AND p.verified = TRUE
       AND p.chip_normalized = j.chip_normalized
       AND p.unified_memory_gb = j.unified_memory_gb
     WHERE j.provider_id = ` + providerExpr + `
       AND j.status = 'verified'
       AND j.decision_reason = $2
       AND ` + trustRootActiveExists(
		"j.provider_id",
		"j.evidence -> 'hardware' ->> 'hardware_identity_hash'",
		"j.chip_normalized",
		"j.unified_memory_gb",
		clockExpr,
	) + `
)`
}

// trustRootActiveExists returns the EXISTS(...) SQL fragment that is TRUE when an
// ACTIVE (unexpired, any source) hardware_verification_trust row exists for the
// (provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb) tuple
// bound by the four column expressions. Factored out so BOTH the provider-wide
// admission/re-check predicate (which binds these to the latest verified job's
// derived tuple) and the tuple-aware revalidation sweep (issue #582 FIX B, which
// binds them to each session's EXACT admitted tuple) share one definition of
// "an active trust root backs this tuple", so the two can never drift apart.
func trustRootActiveExists(providerExpr, hashExpr, chipExpr, memExpr, clockExpr string) string {
	return `EXISTS (
    SELECT 1
      FROM hardware_verification_trust t
     WHERE t.provider_id = ` + providerExpr + `
       AND t.hardware_identity_hash = ` + hashExpr + `
       AND t.chip_normalized = ` + chipExpr + `
       AND t.unified_memory_gb = ` + memExpr + `
       AND (t.expires_at IS NULL OR t.expires_at > ` + clockExpr + `)
)`
}

// AdmittedTuple identifies the EXACT hardware-trust root that authorized a live
// provider session at admission (issue #582 FIX B): the provider_id plus the
// verified hardware tuple (hardware_identity_hash, chip_normalized,
// unified_memory_gb). The revalidation sweep passes one per active session and
// gets back the subset whose tuple no longer has an active trust root.
type AdmittedTuple struct {
	ProviderID           string
	HardwareIdentityHash string
	ChipNormalized       string
	UnifiedMemoryGB      int
}

// sessionsWithoutActiveTrustQuery returns the batched read backing the bounded
// tuple-aware trust-revalidation sweep (issue #582 FIX B). It drives off four
// parallel arrays — one row per admitted session — and returns the subset whose
// EXACT admitted tuple no longer has an active hardware_verification_trust row
// (any source, unexpired). Binding the trust check to the admitted tuple (not
// merely provider_id) closes the multi-Mac gap: a second root B (different
// hardware_identity_hash, same provider_id) can no longer keep session A alive
// after root A — the tuple that admitted A — is revoked/expired. The clock binds
// to $5. Reuses trustRootActiveExists so its active-trust semantics match the
// admission/re-check predicate exactly.
func sessionsWithoutActiveTrustQuery() string {
	return `SELECT t.pid, t.hash, t.chip, t.mem
  FROM unnest($1::text[], $2::text[], $3::text[], $4::int[]) AS t(pid, hash, chip, mem)
 WHERE NOT ` + trustRootActiveExists("t.pid", "t.hash", "t.chip", "t.mem", "$5")
}

// SessionsWithoutActiveTrust returns the subset of admitted session tuples whose
// EXACT hardware tuple no longer has an ACTIVE (unexpired, any source) trust
// root. It is the single batched read backing the bounded trust-revalidation
// sweep (issue #582 FIX B): one round-trip classifies every active session under
// a single sweep-wide deadline. A query error is surfaced to the caller so the
// sweep can fail OPEN (skip this tick) rather than mass-evict on a transient DB
// blip. Read-only as provider_onboarding.
func (s *PGStore) SessionsWithoutActiveTrust(ctx context.Context, admitted []AdmittedTuple) ([]AdmittedTuple, error) {
	if s == nil || s.db == nil {
		return nil, errors.New("onboarding postgres store is nil")
	}
	if len(admitted) == 0 {
		return nil, nil
	}
	pids := make([]string, len(admitted))
	hashes := make([]string, len(admitted))
	chips := make([]string, len(admitted))
	mems := make([]int, len(admitted))
	for i, a := range admitted {
		pids[i] = a.ProviderID
		hashes[i] = a.HardwareIdentityHash
		chips[i] = a.ChipNormalized
		mems[i] = a.UnifiedMemoryGB
	}
	now := time.Now().UTC()
	rows, err := s.db.QueryContext(ctx, sessionsWithoutActiveTrustQuery(),
		pq.Array(pids), pq.Array(hashes), pq.Array(chips), pq.Array(mems), now)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var untrusted []AdmittedTuple
	for rows.Next() {
		var a AdmittedTuple
		if err := rows.Scan(&a.ProviderID, &a.HardwareIdentityHash, &a.ChipNormalized, &a.UnifiedMemoryGB); err != nil {
			return nil, err
		}
		untrusted = append(untrusted, a)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return untrusted, nil
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
