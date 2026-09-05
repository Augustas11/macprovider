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
	if _, err := s.db.ExecContext(timeout, `SELECT provider_id, observed_at, outcome FROM provider_autoupdate_events LIMIT 0`); err != nil {
		return fmt.Errorf("provider_onboarding smoke provider_autoupdate_events read: %w", err)
	}
	if _, err := s.db.ExecContext(timeout, `SELECT provider_id, boot_id, last_seq FROM provider_supervisor_events LIMIT 0`); err != nil {
		return fmt.Errorf("provider_onboarding smoke provider_supervisor_events read: %w", err)
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

// RefreshProviderHardwareProfile keeps provider_hardware_profiles from going
// stale for a provider that stays connected across an autoupdate without ever
// re-registering or re-submitting autotune evidence (Epic #1235 Child B / B1).
// Unlike UpsertProviderHardwareProfile this is UPDATE-only and never inserts:
// a heartbeat carries neither macos_version nor a value valid for the `source`
// CHECK constraint (app_register/cli_hello/operator), so seeding a fresh row
// from it would fabricate a profile the provider never actually submitted at
// onboarding. An unknown provider_id is left absent; empty/non-positive
// arguments leave the corresponding column untouched (COALESCE-style) so a
// heartbeat that omits hardware_summary still advances last_reported_at and
// app_version without blanking a chip/memory value learned at registration.
func (s *PGStore) RefreshProviderHardwareProfile(ctx context.Context, providerID, appVersion string, observedAt time.Time) error {
	if s == nil || s.db == nil {
		return errors.New("onboarding postgres store is nil")
	}
	appVersion = trimForStorage(appVersion, 80)
	// Observe-only: refresh ONLY the freshness (last_reported_at) and reported
	// version (app_version). Keep the SQL within provider_onboarding's
	// column-limited grants: reading app_version in an ELSE branch requires SELECT
	// on that column, so split the empty-version case instead of widening grants.
	var err error
	if strings.TrimSpace(appVersion) == "" {
		_, err = s.db.ExecContext(ctx, `
UPDATE provider_hardware_profiles
   SET last_reported_at = $2
 WHERE provider_id = $1
   AND last_reported_at <= $2`,
			providerID, observedAt.UTC(),
		)
		return err
	}
	_, err = s.db.ExecContext(ctx, `
UPDATE provider_hardware_profiles
   SET app_version = $2,
       last_reported_at = $3
 WHERE provider_id = $1
   AND last_reported_at <= $3`,
		providerID, appVersion, observedAt.UTC(),
	)
	return err
}

// AutoupdateOutcomeRecord is one coordinator-observed autoupdate event
// reported by a provider's heartbeat/state_update `last_autoupdate_event`
// field (Epic #1235 Child B / B2). Phase/outcome/reason/failure_class/
// current_version/target_version are free-form client-reported text with NO
// enum CHECK, mirroring provider_hardware_profiles.macos_version/app_version:
// the client-side taxonomy (AutoUpdateEvent.swift) evolves independently of
// this schema.
type AutoupdateOutcomeRecord struct {
	ProviderID     string
	ObservedAt     time.Time
	UpdateID       string
	CurrentVersion string
	TargetVersion  string
	Source         string
	Phase          string
	Outcome        string
	Reason         string
	FailureClass   string
}

// RecordAutoupdateOutcome durably ingests one DISTINCT autoupdate event so
// fleet-wide autoupdate convergence is queryable. Callers are expected to
// de-duplicate repeated heartbeat echoes of the same event before calling
// this (see internal/ws heartbeat handling) — this method always inserts.
func (s *PGStore) RecordAutoupdateOutcome(ctx context.Context, rec AutoupdateOutcomeRecord) error {
	if s == nil || s.db == nil {
		return errors.New("onboarding postgres store is nil")
	}
	if strings.TrimSpace(rec.ProviderID) == "" {
		return errors.New("autoupdate outcome provider_id is required")
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO provider_autoupdate_events (
    provider_id, observed_at, update_id, current_version, target_version,
    source, phase, outcome, reason, failure_class
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
		rec.ProviderID,
		rec.ObservedAt.UTC(),
		trimForStorage(rec.UpdateID, 128),
		trimForStorage(rec.CurrentVersion, 80),
		trimForStorage(rec.TargetVersion, 80),
		trimForStorage(rec.Source, 40),
		trimForStorage(rec.Phase, 40),
		trimForStorage(rec.Outcome, 40),
		trimForStorage(rec.Reason, 256),
		trimForStorage(rec.FailureClass, 80),
	)
	return err
}

// SupervisorEventRecord is one coordinator-observed supervisor telemetry beacon
// projected from a provider's heartbeat/state_update `last_supervisor_event`
// field (RFC-001 §7 / F5, #1386; SPEC-025 §5.4). It is SEPARATE from
// AutoupdateOutcomeRecord and never merged into provider_autoupdate_events.
// Observability-only: persisting it changes no admission/routing/serving/trust
// authority. Free-form text fields carry no enum CHECK; the client taxonomy
// evolves independently.
type SupervisorEventRecord struct {
	ProviderID        string
	ObservedAt        time.Time
	BootID            string
	Schema            string
	Kind              string
	Seq               int64
	SupervisorLabel   string
	SupervisorVersion string
	RestartsTotal     int64
	DeferralsTotal    int64
	// Sticky last_restart detail (LastRestartSeq == 0 means no restart yet).
	LastRestartSeq           int64
	LastRestartTS            string
	LastRestartCooldown      string
	LastRestartInstance      string // "" == null
	LastRestartModelLiveness string // JSON object text, "" == null
	// Sticky last_deferral detail (LastDeferralSeq == 0 means none yet).
	LastDeferralSeq int64
	LastDeferralTS  string
	// CurrentServiceInstance is THIS heartbeat's service_instance_id (the NEW
	// post-restart instance). A restart is promoted to "held" only once the
	// coordinator observes a new instance whose id differs from the restart's
	// old targeted instance for the full dwell threshold (SPEC-025 §5.4
	// correlation rule); "" leaves correlation unproven.
	CurrentServiceInstance string
	// ServingEligible is the coordinator's own pool-view verdict that the provider
	// is serving-eligible (ready/busy) at this observation. A restart is promoted
	// to "held" only from serving-eligible observations, so a degraded/draining
	// frame can never accrue a false recovery-held signal (SPEC-025 §5.4 dwell).
	ServingEligible bool
	// DwellThreshold is the coordinator-owned sustained-serving window used to
	// finalize a prior restart as held vs flap. Zero falls back to the default.
	DwellThreshold time.Duration
	// StalenessThreshold bounds the gap between two accepted observations before
	// the coordinator treats dwell continuity as broken (a heartbeat-miss/gap),
	// resetting the timer so a silent-then-return provider is never back-filled
	// as held. Zero falls back to the default.
	StalenessThreshold time.Duration
}

// DefaultSupervisorDwellThreshold is the coordinator-owned sustained-serving
// window a post-restart instance must clear before a restart counts as "held".
// Below it, a subsequent restart is a flap. This is an implementation constant
// (SPEC-025 §5.4 leaves the concrete value to the coordinator).
const DefaultSupervisorDwellThreshold = 5 * time.Minute

// DefaultSupervisorStalenessThreshold bounds the gap between two accepted
// beacons before dwell continuity is considered broken. Providers heartbeat far
// more often than this; a longer gap means the coordinator did not continuously
// observe the instance, so an in-flight dwell timer is reset (never back-filled).
const DefaultSupervisorStalenessThreshold = 90 * time.Second

// maxSupervisorSeqStep / maxSupervisorCounterStep bound how far a single beacon
// may advance seq or a counter beyond the stored high-water within a boot. A
// legitimate watchdog advances seq once per tick and counters by one per event,
// so these are generous; a beacon exceeding them is a forged/corrupt jump and is
// quarantined rather than adopted as the new high-water (anti-pinning).
const (
	maxSupervisorSeqStep     = int64(100_000)
	maxSupervisorCounterStep = int64(100_000)
)

// RecordSupervisorEvent upserts the ONE row per (provider_id, boot_id) supervisor
// telemetry state, ordered by `seq` alone (latest-wins; provider timestamps never
// gate). A seq <= the stored seq is a full no-op. A higher-seq beacon that
// regresses a monotonic counter is treated as malformed and skipped
// non-blockingly. When a new last_restart_seq advances, the coordinator finalizes
// the prior restart (flap if the correlated instance had not cleared the dwell
// threshold, else held) and anchors last_restart_observed_at to coordinator
// wall-clock; a non-advancing beacon promotes a pending restart to held once the
// threshold elapses. Callers de-duplicate identical heartbeat echoes upstream.
func (s *PGStore) RecordSupervisorEvent(ctx context.Context, rec SupervisorEventRecord) error {
	if s == nil || s.db == nil {
		return errors.New("onboarding postgres store is nil")
	}
	providerID := strings.TrimSpace(rec.ProviderID)
	bootID := strings.TrimSpace(rec.BootID)
	if providerID == "" || bootID == "" {
		return errors.New("supervisor event provider_id and boot_id are required")
	}
	// Defense in depth (the ws ingest validator is the first gate): never store a
	// non-positive/negative-counter/inconsistent beacon. A nested action seq must
	// not exceed the top seq. Drop non-blockingly.
	if rec.Seq <= 0 || rec.RestartsTotal < 0 || rec.DeferralsTotal < 0 ||
		rec.LastRestartSeq < 0 || rec.LastRestartSeq > rec.Seq ||
		rec.LastDeferralSeq < 0 || rec.LastDeferralSeq > rec.Seq {
		return nil
	}
	threshold := rec.DwellThreshold
	if threshold <= 0 {
		threshold = DefaultSupervisorDwellThreshold
	}
	staleness := rec.StalenessThreshold
	if staleness <= 0 {
		staleness = DefaultSupervisorStalenessThreshold
	}
	observedAt := rec.ObservedAt.UTC()

	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var (
		exStored               bool
		exLastSeq              int64
		exRestarts, exDeferral int64
		exLastRestartSeq       int64
		exLastObserved         time.Time
		exRestartObserved      sql.NullTime
		exFlaps                int64
		exLastFlap             sql.NullTime
		exDwellState           string
		exLastRestartInstance  string
		exLastRestartTS        string
		exLastRestartCooldown  string
		exLastRestartML        sql.NullString
		exLastDeferralSeq      int64
		exLastDeferralTS       string
		exDwellInstance        string
		exDwellStarted         sql.NullTime
	)
	err = tx.QueryRowContext(ctx, `
SELECT last_seq, restarts_total, deferrals_total, last_restart_seq,
       last_observed_at, last_restart_observed_at, flaps_total, last_flap_observed_at,
       last_restart_dwell_state, last_restart_service_instance,
       last_restart_ts, last_restart_cooldown_state, last_restart_model_liveness,
       last_deferral_seq, last_deferral_ts, dwell_instance, dwell_started_at
  FROM provider_supervisor_events
 WHERE provider_id = $1 AND boot_id = $2
   FOR UPDATE`, providerID, bootID).Scan(
		&exLastSeq, &exRestarts, &exDeferral, &exLastRestartSeq,
		&exLastObserved, &exRestartObserved, &exFlaps, &exLastFlap, &exDwellState,
		&exLastRestartInstance, &exLastRestartTS, &exLastRestartCooldown, &exLastRestartML,
		&exLastDeferralSeq, &exLastDeferralTS, &exDwellInstance, &exDwellStarted)
	switch {
	case err == sql.ErrNoRows:
		exStored = false
	case err != nil:
		return err
	default:
		exStored = true
	}

	// Anti-pinning sanity ceiling applies to BOTH first insert (treat stored
	// high-water as 0) and subsequent beacons: a forged/corrupt beacon that jumps
	// seq or a counter absurdly far cannot pin the row and blind later telemetry.
	// A legitimate first F5 beacon always starts at a small seq (the per-boot
	// counters are F5-owned state that begins at 0), so this never false-rejects.
	baseSeq, baseRestarts, baseDeferrals := int64(0), int64(0), int64(0)
	if exStored {
		// Latest-wins: a stale or duplicate (seq <= stored) beacon is a full no-op.
		if rec.Seq <= exLastSeq {
			return tx.Commit()
		}
		// Monotonic counters within a boot: a higher-seq beacon that regresses a
		// counter is malformed — skip non-blockingly rather than adopt it.
		if rec.RestartsTotal < exRestarts || rec.DeferralsTotal < exDeferral {
			return tx.Commit()
		}
		baseSeq, baseRestarts, baseDeferrals = exLastSeq, exRestarts, exDeferral
	}
	if rec.Seq-baseSeq > maxSupervisorSeqStep ||
		rec.RestartsTotal-baseRestarts > maxSupervisorCounterStep ||
		rec.DeferralsTotal-baseDeferrals > maxSupervisorCounterStep {
		return tx.Commit()
	}

	// Sticky detail is preserved on regression: a higher top-level seq beacon that
	// carries a lower/missing nested action seq must NOT erase the previously
	// observed restart/deferral detail (the watchdog always re-carries it; a
	// regressed value is corrupt/forged).
	lastRestartSeq, lastRestartTS := rec.LastRestartSeq, rec.LastRestartTS
	lastRestartCooldown, lastRestartInstance := rec.LastRestartCooldown, rec.LastRestartInstance
	lastRestartML := rec.LastRestartModelLiveness
	newRestartObserved := rec.LastRestartSeq > 0 && rec.LastRestartSeq > exLastRestartSeq
	if exStored && rec.LastRestartSeq < exLastRestartSeq {
		lastRestartSeq, lastRestartTS = exLastRestartSeq, exLastRestartTS
		lastRestartCooldown, lastRestartInstance = exLastRestartCooldown, exLastRestartInstance
		lastRestartML = ""
		if exLastRestartML.Valid {
			lastRestartML = exLastRestartML.String
		}
	}
	lastDeferralSeq, lastDeferralTS := rec.LastDeferralSeq, rec.LastDeferralTS
	if exStored && rec.LastDeferralSeq < exLastDeferralSeq {
		lastDeferralSeq, lastDeferralTS = exLastDeferralSeq, exLastDeferralTS
	}

	modelLiveness := sql.NullString{}
	if ml := strings.TrimSpace(lastRestartML); ml != "" {
		modelLiveness = sql.NullString{String: ml, Valid: true}
	}
	instance := trimForStorage(lastRestartInstance, 128)

	// Rollup / dwell-continuity state.
	var (
		flapsTotal      = int64(0)
		lastFlap        sql.NullTime
		dwellState      = ""
		restartObserved sql.NullTime
		dwellInstance   = ""
		dwellStarted    sql.NullTime
		prevRestarts    = int64(0)
		prevDeferrals   = int64(0)
		prevObserved    sql.NullTime
	)
	if exStored {
		flapsTotal = exFlaps
		lastFlap = exLastFlap
		dwellState = exDwellState
		restartObserved = exRestartObserved
		dwellInstance = exDwellInstance
		dwellStarted = exDwellStarted
		prevRestarts = exRestarts
		prevDeferrals = exDeferral
		prevObserved = sql.NullTime{Time: exLastObserved, Valid: true}
	}
	currentInstance := strings.TrimSpace(rec.CurrentServiceInstance)
	// Continuity is broken by a heartbeat gap larger than the staleness window.
	staleGap := exStored && observedAt.Sub(exLastObserved.UTC()) > staleness

	if newRestartObserved {
		// Finalize the PRIOR restart on the record's own dwell_state: it is a flap
		// ONLY if it was still correlated_pending (never reached held) and no
		// artifact-write confounded its window. A prior already-held restart, or an
		// artifact_confounded/unknown one, is not counted as a supervisor flap.
		if exStored && exDwellState == supervisorDwellPending && exRestartObserved.Valid {
			confounded, err := supervisorArtifactWriteInWindow(ctx, tx, providerID,
				exRestartObserved.Time.UTC(), exRestartObserved.Time.UTC().Add(threshold))
			if err != nil {
				return err
			}
			if !confounded {
				flapsTotal++
				lastFlap = sql.NullTime{Time: observedAt, Valid: true}
			}
		}
		// Start a fresh pending window for the NEW restart; dwell timing has not
		// begun until a correlated new instance is observed serving-eligible.
		restartObserved = sql.NullTime{Time: observedAt, Valid: true}
		dwellInstance = ""
		dwellStarted = sql.NullTime{}
		if lastRestartInstance != "" {
			dwellState = supervisorDwellPending
		} else {
			dwellState = supervisorDwellUnknown
		}
	} else if exStored && exDwellState == supervisorDwellPending && exRestartObserved.Valid {
		// No new restart: advance dwell CONTINUITY. Held is reached only after the
		// coordinator observes a genuinely new correlated instance stay
		// serving-eligible, without a heartbeat gap, for the full dwell threshold.
		correlated := currentInstance != "" && exLastRestartInstance != "" &&
			currentInstance != exLastRestartInstance
		if !rec.ServingEligible || !correlated || staleGap {
			// Continuity broken (non-serving / uncorrelated / gap): reset the timer
			// but stay pending — a later clean run can still establish held.
			dwellInstance = ""
			dwellStarted = sql.NullTime{}
		} else if exDwellInstance != currentInstance || !exDwellStarted.Valid {
			// Begin (or restart) timing this correlated instance now.
			dwellInstance = currentInstance
			dwellStarted = sql.NullTime{Time: observedAt, Valid: true}
		} else if observedAt.Sub(exDwellStarted.Time.UTC()) >= threshold {
			// Continuously observed serving-eligible for the full window: held,
			// unless an artifact-write confounds the restart window.
			confounded, err := supervisorArtifactWriteInWindow(ctx, tx, providerID,
				exRestartObserved.Time.UTC(), exRestartObserved.Time.UTC().Add(threshold))
			if err != nil {
				return err
			}
			if confounded {
				dwellState = supervisorDwellArtifactConfounded
			} else {
				dwellState = supervisorDwellHeld
			}
		}
	}

	if _, err := tx.ExecContext(ctx, `
INSERT INTO provider_supervisor_events (
    provider_id, boot_id, schema, first_seen_at, last_observed_at, prev_observed_at,
    last_seq, kind, supervisor_label, supervisor_version,
    restarts_total, deferrals_total, prev_restarts_total, prev_deferrals_total,
    last_restart_seq, last_restart_ts, last_restart_cooldown_state,
    last_restart_service_instance, last_restart_model_liveness, last_restart_observed_at,
    last_deferral_seq, last_deferral_ts,
    flaps_total, last_flap_observed_at, last_restart_dwell_state,
    dwell_instance, dwell_started_at
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25, $26, $27)
ON CONFLICT (provider_id, boot_id) DO UPDATE SET
    schema = excluded.schema,
    last_observed_at = excluded.last_observed_at,
    prev_observed_at = excluded.prev_observed_at,
    last_seq = excluded.last_seq,
    kind = excluded.kind,
    supervisor_label = excluded.supervisor_label,
    supervisor_version = excluded.supervisor_version,
    restarts_total = excluded.restarts_total,
    deferrals_total = excluded.deferrals_total,
    prev_restarts_total = excluded.prev_restarts_total,
    prev_deferrals_total = excluded.prev_deferrals_total,
    last_restart_seq = excluded.last_restart_seq,
    last_restart_ts = excluded.last_restart_ts,
    last_restart_cooldown_state = excluded.last_restart_cooldown_state,
    last_restart_service_instance = excluded.last_restart_service_instance,
    last_restart_model_liveness = excluded.last_restart_model_liveness,
    last_restart_observed_at = excluded.last_restart_observed_at,
    last_deferral_seq = excluded.last_deferral_seq,
    last_deferral_ts = excluded.last_deferral_ts,
    flaps_total = excluded.flaps_total,
    last_flap_observed_at = excluded.last_flap_observed_at,
    last_restart_dwell_state = excluded.last_restart_dwell_state,
    dwell_instance = excluded.dwell_instance,
    dwell_started_at = excluded.dwell_started_at`,
		providerID,
		bootID,
		trimForStorage(rec.Schema, 64),
		observedAt, // first_seen_at (ignored on conflict update)
		observedAt, // last_observed_at
		prevObserved,
		rec.Seq,
		trimForStorage(rec.Kind, 32),
		trimForStorage(rec.SupervisorLabel, 64),
		trimForStorage(rec.SupervisorVersion, 64),
		rec.RestartsTotal,
		rec.DeferralsTotal,
		prevRestarts,
		prevDeferrals,
		lastRestartSeq,
		trimForStorage(lastRestartTS, 64),
		trimForStorage(lastRestartCooldown, 32),
		instance,
		modelLiveness,
		restartObserved,
		lastDeferralSeq,
		trimForStorage(lastDeferralTS, 64),
		flapsTotal,
		lastFlap,
		trimForStorage(dwellState, 32),
		trimForStorage(dwellInstance, 128),
		dwellStarted,
	); err != nil {
		return err
	}
	return tx.Commit()
}

// supervisorDwell* are the coordinator-derived dwell-state values (SPEC-025 §5.4).
const (
	supervisorDwellUnknown            = "unknown"
	supervisorDwellPending            = "correlated_pending"
	supervisorDwellHeld               = "held"
	supervisorDwellArtifactConfounded = "artifact_confounded"
)

// supervisorArtifactWriteInWindow reports whether the coordinator observed an
// artifact-mutating autoupdate event for providerID in [from, to). The predicate
// mirrors SPEC-025 §5.4 exactly: a provider_autoupdate_events row (migration 026)
// whose phase is backup/swap/rollback with outcome success/in_progress, keyed on
// the coordinator-observation timestamp observed_at (never a provider-reported
// time). Used to mark a restart window artifact_confounded rather than falsely
// attributing recovery to the watchdog.
func supervisorArtifactWriteInWindow(ctx context.Context, tx *sql.Tx, providerID string, from, to time.Time) (bool, error) {
	var exists bool
	err := tx.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1 FROM provider_autoupdate_events
     WHERE provider_id = $1
       AND observed_at >= $2 AND observed_at < $3
       AND phase IN ('backup', 'swap', 'rollback')
       AND outcome IN ('success', 'in_progress')
)`, providerID, from, to).Scan(&exists)
	if err != nil {
		return false, err
	}
	return exists, nil
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
	return `SELECT admitted.pid, admitted.hash, admitted.chip, admitted.mem
  FROM unnest($1::text[], $2::text[], $3::text[], $4::int[]) AS admitted(pid, hash, chip, mem)
 WHERE NOT ` + trustRootActiveExists("admitted.pid", "admitted.hash", "admitted.chip", "admitted.mem", "$5")
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
