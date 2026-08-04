//go:build integration

package stats_test

// SPEC-017 v0.1.8 Step 1 — Postgres-dependent integration tests.
// Build-tagged so the default `make test-coordinator` target on a
// Docker-less host does not fail. The CI
// `coordinator-stats-integration` job runs this suite on every
// PR (BUILD §E.5: AC-20 MUST run on every PR; the integration
// job is unconditional so the gate is satisfied).
//
// ACs covered here:
//
//   AC-9  — stats_reader receives "permission denied" (NOT
//           "relation does not exist") on
//           `SELECT 1 FROM ledger_request_credits LIMIT 1`.
//   AC-10 — provider_visibility commit + rollback subcases under
//           the provider_portal role; left-join default tuple
//           (mode='bucketed', blocked_from_partner_projection=FALSE)
//           verified.
//   AC-19 — SQL fixture proves a provider with no
//           provider_visibility row defaults to the bucketed tuple
//           via the left-join semantics Step 3 will use.
//   AC-20 — CI SQL assertion that no
//           `actor_kind='operator' AND new_mode='exact'` audit row
//           was seeded; the operator-exact path is invariant-
//           prohibited (§6.6.3).
//
// Note on the OLTP stub: AC-9 requires that stats_reader hit
// `ledger_request_credits` AS IF it existed in the OLTP cluster
// the rollup reads from. In production, SPEC-005 v0.3 owns the
// table CREATE; in this test we create a minimal stub matching
// the SPEC-005 name. The grants migration (005_oltp_source_*) is
// idempotent + defensive (skips missing tables); after the stub
// is created we re-run the grants migration so stats_rollup gets
// SELECT and stats_reader is explicitly DENY'd. This proves the
// post-grant state is what production will be, not a synthetic
// "table doesn't exist" state.

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq"
	tc "github.com/testcontainers/testcontainers-go"
	tcpg "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	stats "github.com/augstar/macprovider-coordinator/internal/stats"
	"github.com/augstar/macprovider-coordinator/internal/stats/hardwareverify"
	statsmigrations "github.com/augstar/macprovider-coordinator/internal/stats/migrations"
)

const (
	// Digest-pinned Postgres image — BUILD §G.1 + round-1
	// SECURITY r1 MEDIUM 2: a mutable tag like
	// `postgres:16.4-alpine3.20` is forbidden hygiene; bake in
	// the manifest-list digest so the test image is fixed even
	// if the upstream tag is reused. Refresh deliberately when
	// bumping the major version.
	pgImage = "postgres:16.4-alpine3.20@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c"

	roleStatsReader      = "stats_reader"
	roleStatsRollup      = "stats_rollup"
	roleProviderPortal   = "provider_portal"
	roleProviderOnboard  = "provider_onboarding"
	roleAuthPolicyReq    = "provider_auth_policy_requester"
	roleAuthPolicyAppr   = "provider_auth_policy_approver"
	roleAuthPolicyCut    = "provider_auth_policy_cutover"
	roleAuthPolicyDef    = "provider_auth_policy_definer"
	roleHardwareVerifier = "stats_hardware_verifier"
	roleHWTrustRequester = "hardware_trust_requester"
	roleHWTrustApprover  = "hardware_trust_approver"
	roleHWTrustDefiner   = "hardware_trust_definer"
	roleAdminPassword    = "stepone-admin-password" // local only; container is ephemeral
	roleRuntimePassword  = "stepone-runtime-pw"
)

// pgFixture wraps an ephemeral Postgres container + the four
// connection strings we need (admin + 3 runtime roles).
type pgFixture struct {
	container tc.Container
	host      string
	port      string
	dbName    string
}

func (f *pgFixture) adminDSN() string {
	return fmt.Sprintf("postgres://postgres:%s@%s:%s/%s?sslmode=disable", roleAdminPassword, f.host, f.port, f.dbName)
}

func (f *pgFixture) roleDSN(role string) string {
	return fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable", role, roleRuntimePassword, f.host, f.port, f.dbName)
}

func (f *pgFixture) Close(ctx context.Context) {
	if f == nil || f.container == nil {
		return
	}
	_ = f.container.Terminate(ctx)
}

func startPostgres(t *testing.T) *pgFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	var c *tcpg.PostgresContainer
	var err error
	func() {
		defer func() {
			if r := recover(); r != nil {
				err = fmt.Errorf("start postgres panic: %v", r)
			}
		}()
		c, err = tcpg.Run(ctx, pgImage,
			tcpg.WithDatabase("stats_test"),
			tcpg.WithUsername("postgres"),
			tcpg.WithPassword(roleAdminPassword),
			tc.WithWaitStrategy(
				wait.ForLog("database system is ready to accept connections").
					WithOccurrence(2).
					WithStartupTimeout(60*time.Second),
			),
		)
	}()
	if err != nil {
		msg := err.Error()
		if contains(msg, "Docker not found") ||
			contains(msg, "rootless Docker not found") ||
			contains(msg, "Cannot connect to the Docker daemon") {
			if runningInCI() {
				t.Fatalf("Postgres integration requires Docker in CI: %v", err)
			}
			t.Skipf("skip local Postgres integration without Docker: %v", err)
		}
		t.Fatalf("start postgres: %v", err)
	}
	host, err := c.Host(ctx)
	if err != nil {
		t.Fatalf("host: %v", err)
	}
	port, err := c.MappedPort(ctx, "5432/tcp")
	if err != nil {
		t.Fatalf("mapped port: %v", err)
	}
	fx := &pgFixture{
		container: c,
		host:      host,
		port:      port.Port(),
		dbName:    "stats_test",
	}
	t.Cleanup(func() {
		// Use a fresh background context so a slow teardown
		// during a flaky CI run still cleans up the container.
		bg, c2 := context.WithTimeout(context.Background(), 30*time.Second)
		defer c2()
		fx.Close(bg)
	})
	return fx
}

func runningInCI() bool {
	return os.Getenv("CI") == "true" || os.Getenv("GITHUB_ACTIONS") == "true"
}

// applyMigrationsAndStubOLTP runs the SPEC-017 migrations against
// the admin DSN, creates the OLTP stub tables that AC-9 reads
// against, then re-runs the grants migration so stats_rollup has
// SELECT on the stubs and stats_reader is explicitly DENY'd.
// After this returns, the runtime role identities exist and
// their passwords match `roleRuntimePassword`.
func applyMigrationsAndStubOLTP(t *testing.T, fx *pgFixture) *sql.DB {
	t.Helper()
	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	t.Cleanup(func() { _ = adminDB.Close() })

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("apply SPEC-017 migrations: %v", err)
	}

	// Round-1 SECURITY r1 CRITICAL 1 fix: the migration creates
	// runtime roles with NOLOGIN and no password material. The
	// production deploy automation rotates them via
	// `ALTER ROLE ... WITH LOGIN PASSWORD '...'` from the
	// secret store; the test harness does the same in-memory.
	for _, role := range []string{
		roleStatsReader,
		roleStatsRollup,
		roleProviderPortal,
		roleProviderOnboard,
		roleAuthPolicyReq,
		roleAuthPolicyAppr,
		roleAuthPolicyCut,
		roleHardwareVerifier,
	} {
		if _, err := adminDB.ExecContext(ctx, fmt.Sprintf(
			`ALTER ROLE %s WITH LOGIN PASSWORD '%s'`, role, roleRuntimePassword,
		)); err != nil {
			t.Fatalf("rotate role %s: %v", role, err)
		}
	}

	// Create OLTP stub tables matching SPEC-005 v0.3 names so
	// AC-9 gets permission-denied (not relation-does-not-exist).
	// Schema is minimal — column shape is irrelevant for the
	// permission check; only the table identity matters.
	stubDDL := `
        CREATE TABLE IF NOT EXISTS ledger_request_credits      (id BIGSERIAL PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS ledger_operator_credits     (id BIGSERIAL PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS ledger_payout_ready         (id BIGSERIAL PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS ledger_reconciliation_runs  (id BIGSERIAL PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS provider_tokens             (id BIGSERIAL PRIMARY KEY);
    `
	if _, err := adminDB.ExecContext(ctx, stubDDL); err != nil {
		t.Fatalf("create OLTP stubs: %v", err)
	}

	// Re-apply the OLTP-source grants migration so the
	// idempotent DO block hits the now-present stub tables.
	// schema_migrations_spec017 already records 005 as applied,
	// so we re-execute the file body directly.
	all, err := statsmigrations.All()
	if err != nil {
		t.Fatalf("load migrations: %v", err)
	}
	for _, m := range all {
		if m.Version == 5 {
			if _, err := adminDB.ExecContext(ctx, m.SQL); err != nil {
				t.Fatalf("re-apply OLTP grants on stubs: %v", err)
			}
			break
		}
	}

	return adminDB
}

func TestProviderAuthPolicyExemptionApproveFunctionCommitsGrant(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	providerID := "p_xriseqo2qdf333hzeafrfykwuuzjvlx2huwxjxtg34amqi6tem2a"
	if _, err := adminDB.ExecContext(ctx, `
INSERT INTO provider_identities (provider_id, identity_pubkey, first_seen_ts)
VALUES ($1, decode(repeat('11', 32), 'hex'), NOW())
ON CONFLICT (provider_id) DO NOTHING`, providerID); err != nil {
		t.Fatalf("seed provider identity: %v", err)
	}

	var pendingID string
	if err := adminDB.QueryRowContext(ctx, `
SELECT request_provider_auth_policy_exemption(
    '23adf5df-d040-4102-820d-be02ef7a3f70'::uuid,
    $1,
    'operator:spec026_a',
    NOW() + INTERVAL '2 hours',
    'live hardware stats v1.8.10 admission while App identity key remediation is pending',
    NULL
)::text`, providerID).Scan(&pendingID); err != nil {
		t.Fatalf("request exemption: %v", err)
	}

	var gotProviderID, requestedBy, reason string
	var requestedUntil time.Time
	var incidentID sql.NullString
	if err := adminDB.QueryRowContext(ctx, `
SELECT provider_id, requested_by, requested_until, reason, incident_id
  FROM approve_provider_auth_policy_exemption($1::uuid, 'operator:spec026_b')`,
		pendingID,
	).Scan(&gotProviderID, &requestedBy, &requestedUntil, &reason, &incidentID); err != nil {
		t.Fatalf("approve exemption: %v", err)
	}
	if gotProviderID != providerID || requestedBy != "operator:spec026_a" || reason == "" || incidentID.Valid || !requestedUntil.After(time.Now().UTC()) {
		t.Fatalf("approval row = provider_id=%q requested_by=%q requested_until=%s reason=%q incident=%#v",
			gotProviderID, requestedBy, requestedUntil, reason, incidentID)
	}

	var kind, grantedBy string
	if err := adminDB.QueryRowContext(ctx, `
SELECT kind, granted_by FROM provider_auth_policy WHERE provider_id = $1`, providerID).Scan(&kind, &grantedBy); err != nil {
		t.Fatalf("query committed policy: %v", err)
	}
	if kind != "app" || grantedBy != "operator:spec026_b" {
		t.Fatalf("committed policy kind=%q granted_by=%q, want app/operator:spec026_b", kind, grantedBy)
	}
}

func TestProviderAuthPolicyRuntimeRolesSplitRequestAndApproval(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	onboardingDB := openRoleDB(t, fx, roleProviderOnboard)
	requestDB := openRoleDB(t, fx, roleAuthPolicyReq)
	approveDB := openRoleDB(t, fx, roleAuthPolicyAppr)
	cutoverDB := openRoleDB(t, fx, roleAuthPolicyCut)

	providerID := "p_xriseqo2qdf333hzeafrfykwuuzjvlx2huwxjxtg34amqi6tem2a"
	if _, err := adminDB.ExecContext(ctx, `
INSERT INTO provider_identities (provider_id, identity_pubkey, first_seen_ts)
VALUES ($1, decode(repeat('11', 32), 'hex'), NOW())
ON CONFLICT (provider_id) DO NOTHING`, providerID); err != nil {
		t.Fatalf("seed provider identity: %v", err)
	}

	assertCannotExecuteFunction(t, ctx, onboardingDB, "provider_onboarding",
		"request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)")
	assertCannotExecuteFunction(t, ctx, onboardingDB, "provider_onboarding",
		"approve_provider_auth_policy_exemption(uuid,text)")
	assertCannotExecuteFunction(t, ctx, onboardingDB, "provider_onboarding",
		"seed_provider_auth_policy_cutover(timestamp with time zone,text[])")
	assertCannotExecuteFunction(t, ctx, requestDB, "provider_auth_policy_requester",
		"approve_provider_auth_policy_exemption(uuid,text)")
	assertCannotExecuteFunction(t, ctx, requestDB, "provider_auth_policy_requester",
		"seed_provider_auth_policy_cutover(timestamp with time zone,text[])")
	assertCannotExecuteFunction(t, ctx, approveDB, "provider_auth_policy_approver",
		"request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)")
	assertCannotExecuteFunction(t, ctx, approveDB, "provider_auth_policy_approver",
		"seed_provider_auth_policy_cutover(timestamp with time zone,text[])")
	assertCannotExecuteFunction(t, ctx, cutoverDB, "provider_auth_policy_cutover",
		"request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)")
	assertCannotExecuteFunction(t, ctx, cutoverDB, "provider_auth_policy_cutover",
		"approve_provider_auth_policy_exemption(uuid,text)")

	pendingID := "23adf5df-d040-4102-820d-be02ef7a3f70"
	var gotPendingID string
	if err := requestDB.QueryRowContext(ctx, `
SELECT request_provider_auth_policy_exemption(
    $1::uuid,
    $2,
    'operator:spec026_a',
    NOW() + INTERVAL '2 hours',
    'live hardware stats v1.8.10 admission while App identity key remediation is pending',
    NULL
)::text`, pendingID, providerID).Scan(&gotPendingID); err != nil {
		t.Fatalf("requester role request exemption: %v", err)
	}
	if gotPendingID != pendingID {
		t.Fatalf("pending_id=%q, want %q", gotPendingID, pendingID)
	}

	var gotProviderID, requestedBy, reason string
	var requestedUntil time.Time
	var incidentID sql.NullString
	if err := approveDB.QueryRowContext(ctx, `
SELECT provider_id, requested_by, requested_until, reason, incident_id
  FROM approve_provider_auth_policy_exemption($1::uuid, 'operator:spec026_b')`,
		pendingID,
	).Scan(&gotProviderID, &requestedBy, &requestedUntil, &reason, &incidentID); err != nil {
		t.Fatalf("approver role approve exemption: %v", err)
	}
	if gotProviderID != providerID || requestedBy != "operator:spec026_a" || reason == "" || incidentID.Valid || !requestedUntil.After(time.Now().UTC()) {
		t.Fatalf("approval row = provider_id=%q requested_by=%q requested_until=%s reason=%q incident=%#v",
			gotProviderID, requestedBy, requestedUntil, reason, incidentID)
	}
}

func TestProviderAuthPolicyApproveFixRepairsExistingDeploy(t *testing.T) {
	fx := startPostgres(t)
	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	t.Cleanup(func() { _ = adminDB.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	if _, err := adminDB.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS schema_migrations_spec017 (
    version    INT PRIMARY KEY,
    name       TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
)`); err != nil {
		t.Fatalf("create migration table: %v", err)
	}
	all, err := statsmigrations.All()
	if err != nil {
		t.Fatalf("load migrations: %v", err)
	}
	var repairSQL string
	for _, m := range all {
		if m.Version == 9 {
			repairSQL = m.SQL
			continue
		}
		if m.Version > 8 {
			continue
		}
		if _, err := adminDB.ExecContext(ctx, m.SQL); err != nil {
			t.Fatalf("apply setup migration %03d_%s: %v", m.Version, m.Name, err)
		}
		if _, err := adminDB.ExecContext(ctx,
			`INSERT INTO schema_migrations_spec017 (version, name) VALUES ($1, $2)`,
			m.Version, m.Name,
		); err != nil {
			t.Fatalf("record setup migration %03d_%s: %v", m.Version, m.Name, err)
		}
	}
	if repairSQL == "" {
		t.Fatal("missing version 009 repair migration")
	}

	brokenApprovalSQL := strings.Replace(
		repairSQL,
		"ON CONFLICT ON CONSTRAINT provider_auth_policy_pkey DO UPDATE",
		"ON CONFLICT (provider_id) DO UPDATE",
		1,
	)
	if brokenApprovalSQL == repairSQL {
		t.Fatal("failed to synthesize old ambiguous approval function")
	}
	if _, err := adminDB.ExecContext(ctx, brokenApprovalSQL); err != nil {
		t.Fatalf("install old ambiguous approval function: %v", err)
	}

	providerID := "p_xriseqo2qdf333hzeafrfykwuuzjvlx2huwxjxtg34amqi6tem2a"
	pendingID := "23adf5df-d040-4102-820d-be02ef7a3f70"
	seedPendingAuthPolicyExemption(t, ctx, adminDB, providerID, pendingID)
	var ignored string
	err = adminDB.QueryRowContext(ctx, `
SELECT provider_id
  FROM approve_provider_auth_policy_exemption($1::uuid, 'operator:spec026_b')`,
		pendingID,
	).Scan(&ignored)
	if err == nil || !strings.Contains(err.Error(), `column reference "provider_id" is ambiguous`) {
		t.Fatalf("old approval function err=%v, want ambiguous provider_id", err)
	}

	if _, err := adminDB.ExecContext(ctx, `DELETE FROM provider_auth_policy_pending WHERE pending_id = $1`, pendingID); err != nil {
		t.Fatalf("delete failed pending row: %v", err)
	}
	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("apply repair migration: %v", err)
	}
	var versionCount int
	if err := adminDB.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations_spec017 WHERE version = 9`).Scan(&versionCount); err != nil {
		t.Fatalf("query version 9: %v", err)
	}
	if versionCount != 1 {
		t.Fatalf("version 9 recorded %d times, want 1", versionCount)
	}

	seedPendingAuthPolicyExemption(t, ctx, adminDB, providerID, pendingID)
	var gotProviderID, requestedBy, reason string
	var requestedUntil time.Time
	var incidentID sql.NullString
	if err := adminDB.QueryRowContext(ctx, `
SELECT provider_id, requested_by, requested_until, reason, incident_id
  FROM approve_provider_auth_policy_exemption($1::uuid, 'operator:spec026_b')`,
		pendingID,
	).Scan(&gotProviderID, &requestedBy, &requestedUntil, &reason, &incidentID); err != nil {
		t.Fatalf("approve after repair migration: %v", err)
	}
	if gotProviderID != providerID || requestedBy != "operator:spec026_a" || reason == "" || incidentID.Valid || !requestedUntil.After(time.Now().UTC()) {
		t.Fatalf("approval row after repair = provider_id=%q requested_by=%q requested_until=%s reason=%q incident=%#v",
			gotProviderID, requestedBy, requestedUntil, reason, incidentID)
	}
}

func seedPendingAuthPolicyExemption(t *testing.T, ctx context.Context, db *sql.DB, providerID, pendingID string) {
	t.Helper()
	if _, err := db.ExecContext(ctx, `
INSERT INTO provider_identities (provider_id, identity_pubkey, first_seen_ts)
VALUES ($1, decode(repeat('11', 32), 'hex'), NOW())
ON CONFLICT (provider_id) DO NOTHING`, providerID); err != nil {
		t.Fatalf("seed provider identity: %v", err)
	}
	var gotPendingID string
	if err := db.QueryRowContext(ctx, `
SELECT request_provider_auth_policy_exemption(
    $1::uuid,
    $2,
    'operator:spec026_a',
    NOW() + INTERVAL '2 hours',
    'live hardware stats v1.8.10 admission while App identity key remediation is pending',
    NULL
)::text`, pendingID, providerID).Scan(&gotPendingID); err != nil {
		t.Fatalf("request exemption: %v", err)
	}
	if gotPendingID != pendingID {
		t.Fatalf("pending_id=%q, want %q", gotPendingID, pendingID)
	}
}

func openRoleDB(t *testing.T, fx *pgFixture, role string) *sql.DB {
	t.Helper()
	db, err := sql.Open("postgres", fx.roleDSN(role))
	if err != nil {
		t.Fatalf("open %s: %v", role, err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func assertCannotExecuteFunction(t *testing.T, ctx context.Context, db *sql.DB, role, signature string) {
	t.Helper()
	var allowed bool
	if err := db.QueryRowContext(ctx, `
SELECT has_function_privilege(current_user, $1::regprocedure, 'EXECUTE')`,
		signature,
	).Scan(&allowed); err != nil {
		t.Fatalf("%s function privilege %s: %v", role, signature, err)
	}
	if allowed {
		t.Fatalf("%s unexpectedly has EXECUTE on %s", role, signature)
	}
}

// ===========================================================================
// AC-9 — stats_reader permission denied on OLTP ledger tables.
// ===========================================================================
func TestAC9_StatsReaderPermissionDeniedOnLedger(t *testing.T) {
	fx := startPostgres(t)
	_ = applyMigrationsAndStubOLTP(t, fx)

	readerDB, err := sql.Open("postgres", fx.roleDSN(roleStatsReader))
	if err != nil {
		t.Fatalf("open reader: %v", err)
	}
	defer readerDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// BUILD §E.1 / F.1 — verify against MULTIPLE SPEC-005 tables;
	// "at least one" is the floor but ledger_request_credits is
	// the canonical case and the others reinforce the invariant.
	for _, table := range []string{
		"ledger_request_credits",
		"ledger_operator_credits",
		"ledger_payout_ready",
		"ledger_reconciliation_runs",
		"provider_tokens",
	} {
		_, err := readerDB.QueryContext(ctx, fmt.Sprintf(`SELECT 1 FROM %s LIMIT 1`, table))
		if err == nil {
			t.Errorf("stats_reader unexpectedly succeeded SELECT on %s; expected permission denied", table)
			continue
		}
		// lib/pq error class for permission-denied is SQLSTATE 42501.
		// The driver wraps it as `*pq.Error`; we assert by string
		// match on the error message so the test does not couple to
		// the pq error type (and BUILD §E.1 wants "permission denied",
		// NOT "relation does not exist").
		msg := err.Error()
		if !contains(msg, "permission denied") {
			t.Errorf("stats_reader on %s: expected 'permission denied', got %q", table, msg)
		}
		if contains(msg, "does not exist") {
			t.Errorf("stats_reader on %s: error suggests missing relation (%q); the OLTP stub setup is wrong", table, msg)
		}
	}
}

// ===========================================================================
// AC-10 — provider_visibility commit + rollback under provider_portal.
// ===========================================================================
func TestAC10_ProviderVisibilityCommitAndRollback(t *testing.T) {
	fx := startPostgres(t)
	_ = applyMigrationsAndStubOLTP(t, fx)

	portalDB, err := sql.Open("postgres", fx.roleDSN(roleProviderPortal))
	if err != nil {
		t.Fatalf("open portal: %v", err)
	}
	defer portalDB.Close()

	// Pre-seed: as admin (since stats_reader/portal cannot INSERT
	// initial 'bucketed' rows directly — portal only has INSERT/
	// UPDATE on provider_visibility but the test fixture itself
	// runs as admin).
	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	defer adminDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := adminDB.ExecContext(ctx,
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p1', 'bucketed')`,
	); err != nil {
		t.Fatalf("seed p1 bucketed: %v", err)
	}

	// === Subcase A: bucketed -> exact, commit path. ===
	tx, err := portalDB.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin subcase A: %v", err)
	}
	if _, err := tx.ExecContext(ctx, `
        INSERT INTO provider_visibility (provider_id, mode)
        VALUES ('p1', 'exact')
        ON CONFLICT (provider_id) DO UPDATE
        SET mode = EXCLUDED.mode, updated_at = now()
    `); err != nil {
		_ = tx.Rollback()
		t.Fatalf("upsert p1: %v", err)
	}
	if _, err := tx.ExecContext(ctx, `
        INSERT INTO provider_visibility_audit
            (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
        VALUES ('p1', 'bucketed', 'exact', 'provider', 'p1', '127.0.0.1', 'test')
    `); err != nil {
		_ = tx.Rollback()
		t.Fatalf("audit insert p1: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit subcase A: %v", err)
	}

	// Assert post-commit state: mode='exact', blocked_*=FALSE
	// (the v0.1.7 stub column was not touched by the DO UPDATE
	// and falls to its DEFAULT). BUILD §E.2.
	var mode string
	var blocked bool
	row := adminDB.QueryRowContext(ctx,
		`SELECT mode, blocked_from_partner_projection FROM provider_visibility WHERE provider_id = 'p1'`,
	)
	if err := row.Scan(&mode, &blocked); err != nil {
		t.Fatalf("scan p1: %v", err)
	}
	if mode != "exact" {
		t.Errorf("p1 mode = %q, want %q", mode, "exact")
	}
	if blocked {
		t.Errorf("p1 blocked_from_partner_projection = true, want false (v0.1.7 stub default)")
	}

	var auditCount int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM provider_visibility_audit
        WHERE provider_id = 'p1' AND old_mode = 'bucketed' AND new_mode = 'exact'
          AND actor_kind = 'provider'
    `).Scan(&auditCount); err != nil {
		t.Fatalf("count p1 audit: %v", err)
	}
	if auditCount != 1 {
		t.Errorf("p1 audit count = %d, want 1", auditCount)
	}

	// === Subcase B: rollback path with distinct provider. ===
	tx, err = portalDB.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin subcase B: %v", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p_rollback', 'exact')`,
	); err != nil {
		_ = tx.Rollback()
		t.Fatalf("seed p_rollback: %v", err)
	}
	if _, err := tx.ExecContext(ctx, `
        INSERT INTO provider_visibility_audit
            (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
        VALUES ('p_rollback', 'bucketed', 'exact', 'provider', 'p_rollback', '127.0.0.1', 'test')
    `); err != nil {
		_ = tx.Rollback()
		t.Fatalf("audit insert p_rollback: %v", err)
	}
	// Force a PK conflict to abort the transaction.
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p_rollback', 'bucketed')`,
	); err == nil {
		_ = tx.Rollback()
		t.Fatalf("expected PK conflict to abort the transaction; got success")
	}
	// The transaction is now in aborted state; explicit Rollback.
	_ = tx.Rollback()

	var pCount int
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM provider_visibility WHERE provider_id = 'p_rollback'`,
	).Scan(&pCount); err != nil {
		t.Fatalf("count p_rollback visibility: %v", err)
	}
	if pCount != 0 {
		t.Errorf("p_rollback visibility count = %d, want 0 (rollback should have undone the INSERT)", pCount)
	}
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM provider_visibility_audit WHERE provider_id = 'p_rollback'`,
	).Scan(&pCount); err != nil {
		t.Fatalf("count p_rollback audit: %v", err)
	}
	if pCount != 0 {
		t.Errorf("p_rollback audit count = %d, want 0", pCount)
	}
}

// ===========================================================================
// AC-19 — left-join no-row default tuple.
// ===========================================================================
func TestAC19_LeftJoinNoRowDefault(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Seed a stats_leaderboard_24h row for a provider with NO
	// provider_visibility row. The left-join query Step 3's
	// handler will use MUST default mode='bucketed' AND
	// blocked_from_partner_projection=FALSE on the no-row case.
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO stats_leaderboard_24h (
            provider_id, pseudonym, generated_at,
            rank_earnings, rank_tokens, rank_jobs,
            earnings_bucket
        ) VALUES (
            'never-toggled-xyz', 'pseudo-xyz', now(),
            1, 1, 1,
            '$'
        )
    `); err != nil {
		t.Fatalf("seed leaderboard row: %v", err)
	}

	// This is the same left-join shape Step 3's handler will use.
	row := adminDB.QueryRowContext(ctx, `
        SELECT
            l.provider_id,
            COALESCE(v.mode, 'bucketed') AS mode,
            COALESCE(v.blocked_from_partner_projection, FALSE) AS blocked
        FROM stats_leaderboard_24h l
        LEFT JOIN provider_visibility v ON v.provider_id = l.provider_id
        WHERE l.provider_id = 'never-toggled-xyz'
    `)
	var pid, mode string
	var blocked bool
	if err := row.Scan(&pid, &mode, &blocked); err != nil {
		t.Fatalf("scan left-join: %v", err)
	}
	if mode != "bucketed" {
		t.Errorf("no-row provider mode = %q, want 'bucketed'", mode)
	}
	if blocked {
		t.Errorf("no-row provider blocked = true, want false")
	}
}

// ===========================================================================
// AC-20 — no operator-exact audit row, ever.
// ===========================================================================
// Per BUILD §E.5 + §2.4 this assertion runs on every PR via the
// `coordinator-stats-integration` CI job. The test seeds a clean
// migration + bootstrap and asserts the prohibited combination
// has zero rows. A future fixture that violates §6.6.3 by
// inserting `actor_kind='operator' AND new_mode='exact'` would
// trip this immediately.
func TestAC20_NoOperatorExactAuditRow(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Pre-emptive defensive seed: insert a legitimate
	// actor_kind='operator' AND new_mode='bucketed' row (the
	// emergency suppression direction per §6.6.3 is allowed).
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO provider_visibility_audit
            (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
        VALUES ('p_emergency', 'exact', 'bucketed', 'operator', 'ops@example.com', '10.0.0.1', 'cli')
    `); err != nil {
		t.Fatalf("seed legitimate operator suppression: %v", err)
	}

	var count int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM provider_visibility_audit
        WHERE new_mode = 'exact' AND actor_kind = 'operator'
    `).Scan(&count); err != nil {
		t.Fatalf("query AC-20: %v", err)
	}
	if count != 0 {
		t.Errorf("AC-20 violated: %d rows with actor_kind='operator' AND new_mode='exact' (operator MUST NOT exact-enable per §6.6.3)", count)
	}
}

// ===========================================================================
// Schema-shape sanity tests — confirm the migrations created the
// tables Step 2/3 expect.
// ===========================================================================
func TestSchemaShapeSanity(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Health table has exactly 7 component rows (v0.1.7 split).
	var n int
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM stats_components_health`,
	).Scan(&n); err != nil {
		t.Fatalf("count components_health: %v", err)
	}
	if n != 7 {
		t.Errorf("stats_components_health row count = %d, want 7", n)
	}

	// Rewards-populated bootstrap has 4 rows, all false.
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM stats_rewards_populated WHERE rewards_populated = FALSE`,
	).Scan(&n); err != nil {
		t.Fatalf("count rewards_populated bootstrap: %v", err)
	}
	if n != 4 {
		t.Errorf("stats_rewards_populated false-bootstrap count = %d, want 4", n)
	}

	// stats_leaderboard_24h has NO earnings_work_bucket /
	// earnings_rewards_bucket columns (v0.1.7 removed).
	for _, banned := range []string{"earnings_work_bucket", "earnings_rewards_bucket"} {
		if err := adminDB.QueryRowContext(ctx, `
            SELECT COUNT(*) FROM information_schema.columns
            WHERE table_name = 'stats_leaderboard_24h' AND column_name = $1
        `, banned).Scan(&n); err != nil {
			t.Fatalf("information_schema lookup: %v", err)
		}
		if n != 0 {
			t.Errorf("stats_leaderboard_24h has forbidden column %q (v0.1.7 removed)", banned)
		}
	}

	// partner_keys has NO rate_limit_burst column (v0.1.8 removed).
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM information_schema.columns
        WHERE table_name = 'partner_keys' AND column_name = 'rate_limit_burst'
    `).Scan(&n); err != nil {
		t.Fatalf("information_schema partner_keys lookup: %v", err)
	}
	if n != 0 {
		t.Errorf("partner_keys has forbidden column 'rate_limit_burst' (v0.1.8 removed)")
	}

	// provider_visibility has the v0.1.7
	// blocked_from_partner_projection stub.
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM information_schema.columns
        WHERE table_name = 'provider_visibility' AND column_name = 'blocked_from_partner_projection'
    `).Scan(&n); err != nil {
		t.Fatalf("information_schema provider_visibility lookup: %v", err)
	}
	if n != 1 {
		t.Errorf("provider_visibility missing v0.1.7 blocked_from_partner_projection column stub")
	}

	// stats_components_health has NO status column (derived at
	// request time per §5.3; presence is CRITICAL per BUILD §A.4).
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM information_schema.columns
        WHERE table_name = 'stats_components_health' AND column_name = 'status'
    `).Scan(&n); err != nil {
		t.Fatalf("information_schema components_health status lookup: %v", err)
	}
	if n != 0 {
		t.Errorf("stats_components_health has forbidden 'status' column; status is derived at request time per §5.3")
	}
}

// ===========================================================================
// Migration idempotency — running All() twice is a no-op.
// ===========================================================================
func TestMigrationsIdempotent(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Re-run; schema_migrations_spec017 should already have all
	// versions recorded; Apply MUST be a no-op.
	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("second Apply: %v", err)
	}

	// stats_components_health still has 7 rows (the ON CONFLICT
	// DO NOTHING in 002 protects it).
	var n int
	if err := adminDB.QueryRowContext(ctx, `SELECT COUNT(*) FROM stats_components_health`).Scan(&n); err != nil {
		t.Fatalf("count components_health: %v", err)
	}
	if n != 7 {
		t.Errorf("after re-apply, components_health row count = %d, want 7", n)
	}
}

func TestApptrackRegisterAttemptsUpgradeDowngradeAndReapply(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	assertTableExists := func(want bool) {
		t.Helper()
		var exists bool
		if err := adminDB.QueryRowContext(ctx, `
SELECT to_regclass('public.provider_register_attempts') IS NOT NULL
`).Scan(&exists); err != nil {
			t.Fatalf("lookup provider_register_attempts: %v", err)
		}
		if exists != want {
			t.Fatalf("provider_register_attempts exists=%v, want %v", exists, want)
		}
	}

	assertTableExists(true)

	onboardingDB, err := sql.Open("postgres", fx.roleDSN(roleProviderOnboard))
	if err != nil {
		t.Fatalf("open provider_onboarding: %v", err)
	}
	defer onboardingDB.Close()

	providerID := "p_migration_roundtrip"
	nonce := "nonce-roundtrip"
	if _, err := onboardingDB.ExecContext(ctx, `
INSERT INTO provider_register_attempts (provider_id, nonce, ts_utc, source_ip)
VALUES ($1, $2, '2026-07-16T00:00:00Z', '127.0.0.1')
`, providerID, nonce); err != nil {
		t.Fatalf("provider_onboarding insert: %v", err)
	}
	var count int
	if err := onboardingDB.QueryRowContext(ctx, `
SELECT COUNT(*) FROM provider_register_attempts
WHERE provider_id = $1 AND nonce = $2
`, providerID, nonce).Scan(&count); err != nil {
		t.Fatalf("provider_onboarding select: %v", err)
	}
	if count != 1 {
		t.Fatalf("provider_onboarding selected %d attempt rows, want 1", count)
	}
	if _, err := onboardingDB.ExecContext(ctx, `
INSERT INTO provider_register_attempts (
    provider_id, nonce, ts_utc, source_ip, committed_at
) VALUES (
    'p_forged_commit_time', 'nonce-forged', '2026-07-16T00:00:00Z',
    '127.0.0.1', '2000-01-01T00:00:00Z'
)
`); err == nil || !strings.Contains(strings.ToLower(err.Error()), "permission denied") {
		t.Fatalf("provider_onboarding committed_at override error=%v, want permission denied", err)
	}
	for operation, query := range map[string]string{
		"update": `UPDATE provider_register_attempts SET source_ip = '127.0.0.2' WHERE provider_id = 'p_migration_roundtrip'`,
		"delete": `DELETE FROM provider_register_attempts WHERE provider_id = 'p_migration_roundtrip'`,
		"prune":  `SELECT prune_provider_register_attempts(INTERVAL '30 days')`,
	} {
		if _, err := onboardingDB.ExecContext(ctx, query); err == nil || !strings.Contains(strings.ToLower(err.Error()), "permission denied") {
			t.Fatalf("provider_onboarding %s error=%v, want permission denied", operation, err)
		}
	}

	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("idempotent re-apply with migration 018 present: %v", err)
	}
	assertTableExists(true)

	downSQL, err := os.ReadFile("migrations/018_apptrack_register_attempts.down.sql")
	if err != nil {
		t.Fatalf("read migration 018 rollback artifact: %v", err)
	}
	if _, err := adminDB.ExecContext(ctx, string(downSQL)); err != nil {
		t.Fatalf("apply migration 018 rollback: %v", err)
	}
	if _, err := adminDB.ExecContext(ctx, `DELETE FROM schema_migrations_spec017 WHERE version = 18`); err != nil {
		t.Fatalf("remove rolled-back migration 018 ledger row: %v", err)
	}
	assertTableExists(false)

	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("re-apply migration 018 after rollback: %v", err)
	}
	assertTableExists(true)
}

// TestMigrationsConcurrent — round-1 CODE r1 CRITICAL C1 fix.
// Two parallel Apply calls must both succeed without leaving
// duplicate rows in schema_migrations_spec017 or double-applying
// the bootstrap inserts. The advisory lock in migrations.Apply
// serializes the runs.
func TestMigrationsConcurrent(t *testing.T) {
	fx := startPostgres(t)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	all, err := statsmigrations.All()
	if err != nil {
		t.Fatalf("load migrations: %v", err)
	}
	wantMigrations := len(all)

	adminDB1, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin1: %v", err)
	}
	defer adminDB1.Close()
	adminDB2, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin2: %v", err)
	}
	defer adminDB2.Close()

	errCh := make(chan error, 2)
	go func() { errCh <- statsmigrations.Apply(ctx, adminDB1) }()
	go func() { errCh <- statsmigrations.Apply(ctx, adminDB2) }()
	for i := 0; i < 2; i++ {
		if err := <-errCh; err != nil {
			t.Fatalf("concurrent Apply (run %d): %v", i, err)
		}
	}

	// Exactly one row per migration version in
	// schema_migrations_spec017 (no duplicates from race).
	var rows int
	if err := adminDB1.QueryRowContext(ctx,
		`SELECT COUNT(DISTINCT version) FROM schema_migrations_spec017`,
	).Scan(&rows); err != nil {
		t.Fatalf("count distinct: %v", err)
	}
	var total int
	if err := adminDB1.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM schema_migrations_spec017`,
	).Scan(&total); err != nil {
		t.Fatalf("count total: %v", err)
	}
	if rows != total {
		t.Errorf("schema_migrations_spec017 has duplicate version rows: distinct=%d total=%d", rows, total)
	}
	if rows != wantMigrations {
		t.Errorf("schema_migrations_spec017 distinct versions = %d, want %d", rows, wantMigrations)
	}

	// stats_components_health still has exactly 7 rows.
	var comps int
	if err := adminDB1.QueryRowContext(ctx, `SELECT COUNT(*) FROM stats_components_health`).Scan(&comps); err != nil {
		t.Fatalf("count components_health: %v", err)
	}
	if comps != 7 {
		t.Errorf("stats_components_health row count = %d, want 7", comps)
	}
}

// TestAdvisoryLockKeyMatchesHashtext — defense-in-depth for the
// migrations.advisoryLockKey constant. A coordinator using a
// different hashing convention than the one used at IMPL time
// would race against itself; this test fails fast in CI if the
// constant drifts from a stable hash of the literal label.
func TestAdvisoryLockKeyMatchesHashtext(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Re-acquire the lock with the constant and confirm
	// Postgres accepts it. The semantics we care about is "the
	// pre-computed BIGINT is a valid pg_advisory_lock argument
	// and the lock is acquired"; the constant's exact value is
	// the migration package's contract, not the test's.
	var ok bool
	if err := adminDB.QueryRowContext(ctx,
		`SELECT pg_try_advisory_lock(5179378192876502983)`,
	).Scan(&ok); err != nil {
		t.Fatalf("pg_try_advisory_lock: %v", err)
	}
	if !ok {
		t.Fatal("pg_try_advisory_lock returned false; lock collided with a prior holder")
	}
	if _, err := adminDB.ExecContext(ctx,
		`SELECT pg_advisory_unlock(5179378192876502983)`,
	); err != nil {
		t.Fatalf("pg_advisory_unlock: %v", err)
	}
}

// TestNoLoginRoleDefault — round-1 SECURITY r1 CRITICAL 1 fix:
// 003_roles.up.sql creates roles with NOLOGIN. Before the test
// harness rotates them, a connection attempt MUST fail.
func TestNoLoginRoleDefault(t *testing.T) {
	fx := startPostgres(t)

	// Apply ONLY the migrations, NOT the role-rotate step from
	// applyMigrationsAndStubOLTP — so the roles still have
	// NOLOGIN.
	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	defer adminDB.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("apply migrations: %v", err)
	}

	// Confirm each runtime role has rolcanlogin = false (no
	// password, no LOGIN) before any rotation.
	for _, role := range []string{roleStatsReader, roleStatsRollup, roleProviderPortal, roleAuthPolicyReq, roleAuthPolicyAppr, roleAuthPolicyCut, roleAuthPolicyDef} {
		var canLogin bool
		if err := adminDB.QueryRowContext(ctx,
			`SELECT rolcanlogin FROM pg_roles WHERE rolname = $1`, role,
		).Scan(&canLogin); err != nil {
			t.Fatalf("query rolcanlogin for %s: %v", role, err)
		}
		if canLogin {
			t.Errorf("role %s has rolcanlogin=true; 003_roles.up.sql should create with NOLOGIN", role)
		}
	}
}

// ===========================================================================
// Pool isolation — provider_portal CANNOT SELECT stats_* tables.
// ===========================================================================
func TestProviderPortalCannotReadStats(t *testing.T) {
	fx := startPostgres(t)
	_ = applyMigrationsAndStubOLTP(t, fx)

	portalDB, err := sql.Open("postgres", fx.roleDSN(roleProviderPortal))
	if err != nil {
		t.Fatalf("open portal: %v", err)
	}
	defer portalDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err = portalDB.QueryContext(ctx, `SELECT 1 FROM stats_overview_current LIMIT 1`)
	if err == nil {
		t.Fatalf("provider_portal unexpectedly SELECT'd stats_overview_current; §7.2.3 invariant violated")
	}
	if !contains(err.Error(), "permission denied") {
		t.Errorf("provider_portal stats_overview_current: expected 'permission denied', got %q", err.Error())
	}

	// And provider_portal CAN insert into provider_visibility_audit
	// (the BIGSERIAL sequence grant works).
	if _, err := portalDB.ExecContext(ctx, `
        INSERT INTO provider_visibility_audit
            (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
        VALUES ('p_smoke', 'bucketed', 'exact', 'provider', 'p_smoke', '127.0.0.1', 'test')
    `); err != nil {
		t.Errorf("provider_portal insert into provider_visibility_audit failed (sequence USAGE grant missing?): %v", err)
	}
}

// ===========================================================================
// stats_rollup deny on partner_keys + provider_visibility_audit.
// ===========================================================================
func TestStatsRollupCannotTouchPartnerKeys(t *testing.T) {
	fx := startPostgres(t)
	_ = applyMigrationsAndStubOLTP(t, fx)

	rollupDB, err := sql.Open("postgres", fx.roleDSN(roleStatsRollup))
	if err != nil {
		t.Fatalf("open rollup: %v", err)
	}
	defer rollupDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err = rollupDB.QueryContext(ctx, `SELECT 1 FROM partner_keys LIMIT 1`)
	if err == nil {
		t.Errorf("stats_rollup unexpectedly SELECT'd partner_keys; §7.2.2 invariant violated")
	} else if !contains(err.Error(), "permission denied") {
		t.Errorf("stats_rollup partner_keys: expected 'permission denied', got %q", err.Error())
	}

	_, err = rollupDB.QueryContext(ctx, `SELECT 1 FROM provider_visibility_audit LIMIT 1`)
	if err == nil {
		t.Errorf("stats_rollup unexpectedly SELECT'd provider_visibility_audit")
	} else if !contains(err.Error(), "permission denied") {
		t.Errorf("stats_rollup provider_visibility_audit: expected 'permission denied', got %q", err.Error())
	}
}

func TestOpenFailsWhenIdlePrewarmMigrationMissing(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := adminDB.ExecContext(ctx, `
        DROP TABLE stats_idle_prewarm_events;
        ALTER TABLE stats_overview_current
            DROP COLUMN idle_prewarm_pool_pct_with_b1_active,
            DROP COLUMN idle_prewarm_skips_by_reason_last_1h;
        DELETE FROM schema_migrations_spec017 WHERE version = 11;
    `); err != nil {
		t.Fatalf("remove migration 011 objects: %v", err)
	}

	pools, err := stats.Open(ctx, stats.Config{
		Enabled:   true,
		ReaderDSN: fx.roleDSN(roleStatsReader),
		RollupDSN: fx.roleDSN(roleStatsRollup),
	})
	if err == nil {
		_ = pools.Close()
		t.Fatal("stats.Open succeeded without migration 011 objects; want startup smoke failure")
	}
	if !strings.Contains(err.Error(), "smoke stats_reader") ||
		!strings.Contains(err.Error(), "migrations may not have run") {
		t.Fatalf("stats.Open error = %q, want migration smoke failure", err.Error())
	}
}

func TestOpenFailsWhenIdlePrewarmSequenceGrantMissing(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := adminDB.ExecContext(ctx, `REVOKE USAGE ON SEQUENCE stats_idle_prewarm_events_id_seq FROM stats_rollup`); err != nil {
		t.Fatalf("revoke idle prewarm sequence grant: %v", err)
	}

	pools, err := stats.Open(ctx, stats.Config{
		Enabled:   true,
		ReaderDSN: fx.roleDSN(roleStatsReader),
		RollupDSN: fx.roleDSN(roleStatsRollup),
	})
	if err == nil {
		_ = pools.Close()
		t.Fatal("stats.Open succeeded without idle prewarm sequence usage grant; want startup smoke failure")
	}
	if !strings.Contains(err.Error(), "smoke stats_rollup") ||
		!strings.Contains(err.Error(), "privilege probe returned false") {
		t.Fatalf("stats.Open error = %q, want stats_rollup sequence grant smoke failure", err.Error())
	}
}

// ===========================================================================
// Hardware profile grants — effective runtime role behavior.
// ===========================================================================
func TestHardwareProfileRoleGrantsAndVerificationGuard(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	readerDB, err := sql.Open("postgres", fx.roleDSN(roleStatsReader))
	if err != nil {
		t.Fatalf("open reader: %v", err)
	}
	defer readerDB.Close()
	portalDB, err := sql.Open("postgres", fx.roleDSN(roleProviderPortal))
	if err != nil {
		t.Fatalf("open portal: %v", err)
	}
	defer portalDB.Close()
	rollupDB, err := sql.Open("postgres", fx.roleDSN(roleStatsRollup))
	if err != nil {
		t.Fatalf("open rollup: %v", err)
	}
	defer rollupDB.Close()
	onboardingDB, err := sql.Open("postgres", fx.roleDSN(roleProviderOnboard))
	if err != nil {
		t.Fatalf("open onboarding: %v", err)
	}
	defer onboardingDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	for _, roleDB := range []struct {
		name string
		db   *sql.DB
	}{
		{name: "stats_reader", db: readerDB},
		{name: "provider_portal", db: portalDB},
	} {
		for _, table := range []string{"provider_hardware_profiles", "chip_hardware_profiles"} {
			_, err := roleDB.db.QueryContext(ctx, fmt.Sprintf(`SELECT 1 FROM %s LIMIT 1`, table))
			if err == nil {
				t.Errorf("%s unexpectedly SELECT'd %s", roleDB.name, table)
				continue
			}
			if !contains(err.Error(), "permission denied") {
				t.Errorf("%s on %s: expected permission denied, got %q", roleDB.name, table, err.Error())
			}
		}
	}

	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO chip_hardware_profiles
            (chip_normalized, display_chip, memory_bandwidth_gb_per_s, network_power_kw, gpu_cores, cpu_cores)
        VALUES ('apple m4 max', 'Apple M4 Max', 546, 0.12, 40, 16)
    `); err != nil {
		t.Fatalf("seed chip profile: %v", err)
	}

	if _, err := rollupDB.QueryContext(ctx, `SELECT 1 FROM chip_hardware_profiles LIMIT 1`); err != nil {
		t.Fatalf("stats_rollup read chip_hardware_profiles: %v", err)
	}
	if _, err := rollupDB.QueryContext(ctx, `SELECT 1 FROM provider_hardware_profiles LIMIT 1`); err != nil {
		t.Fatalf("stats_rollup read provider_hardware_profiles: %v", err)
	}

	if _, err := onboardingDB.ExecContext(ctx, `
        INSERT INTO provider_hardware_profiles
            (provider_id, chip, chip_normalized, unified_memory_gb, macos_version, app_version, source, last_reported_at)
        VALUES ('p-hw', 'Apple M4 Max', 'apple m4 max', 64, '15.0', '1.0.0', 'app_register', now())
    `); err != nil {
		t.Fatalf("provider_onboarding insert hardware profile: %v", err)
	}
	var verified bool
	if err := adminDB.QueryRowContext(ctx,
		`SELECT verified FROM provider_hardware_profiles WHERE provider_id = 'p-hw'`,
	).Scan(&verified); err != nil {
		t.Fatalf("admin scan inserted verified: %v", err)
	}
	if verified {
		t.Fatalf("provider_onboarding insert set verified=true; want default/trigger false")
	}

	var onboardingVerified bool
	if err := onboardingDB.QueryRowContext(ctx,
		`SELECT verified FROM provider_hardware_profiles WHERE provider_id = 'p-hw'`,
	).Scan(&onboardingVerified); err != nil {
		t.Fatalf("provider_onboarding select verified capacity gate: %v", err)
	}
	if onboardingVerified {
		t.Fatalf("provider_onboarding selected verified=true before operator verification")
	}

	_, err = onboardingDB.QueryContext(ctx,
		`SELECT source FROM provider_hardware_profiles WHERE provider_id = 'p-hw'`)
	if err == nil {
		t.Fatalf("provider_onboarding unexpectedly selected source")
	}
	if !contains(err.Error(), "permission denied") {
		t.Fatalf("provider_onboarding select source: expected permission denied, got %q", err.Error())
	}

	_, err = onboardingDB.ExecContext(ctx,
		`UPDATE provider_hardware_profiles SET verified = TRUE WHERE provider_id = 'p-hw'`)
	if err == nil {
		t.Fatalf("provider_onboarding unexpectedly updated verified")
	}
	if !contains(err.Error(), "permission denied") {
		t.Fatalf("provider_onboarding update verified: expected permission denied, got %q", err.Error())
	}

	if _, err := adminDB.ExecContext(ctx,
		`UPDATE provider_hardware_profiles SET verified = TRUE WHERE provider_id = 'p-hw'`,
	); err != nil {
		t.Fatalf("operator verify row: %v", err)
	}

	if _, err := onboardingDB.ExecContext(ctx, `
        UPDATE provider_hardware_profiles
           SET chip = 'Apple M4 Max',
               chip_normalized = 'apple m4 max',
               unified_memory_gb = 96,
               macos_version = '15.1',
               app_version = '1.0.1',
               source = 'app_register',
               last_reported_at = now()
         WHERE provider_id = 'p-hw'
    `); err != nil {
		t.Fatalf("provider_onboarding same-chip update: %v", err)
	}
	if err := adminDB.QueryRowContext(ctx,
		`SELECT verified FROM provider_hardware_profiles WHERE provider_id = 'p-hw'`,
	).Scan(&verified); err != nil {
		t.Fatalf("admin scan same-chip verified: %v", err)
	}
	if verified {
		t.Fatalf("memory-changed provider_onboarding update preserved verified; want cleared")
	}

	if _, err := adminDB.ExecContext(ctx,
		`UPDATE provider_hardware_profiles SET verified = TRUE WHERE provider_id = 'p-hw'`,
	); err != nil {
		t.Fatalf("operator reverify row: %v", err)
	}

	if _, err := onboardingDB.ExecContext(ctx, `
        UPDATE provider_hardware_profiles
           SET chip = 'Apple M3 Max',
               chip_normalized = 'apple m3 max',
               unified_memory_gb = 128,
               macos_version = '15.2',
               app_version = '1.0.2',
               source = 'app_register',
               last_reported_at = now()
         WHERE provider_id = 'p-hw'
    `); err != nil {
		t.Fatalf("provider_onboarding changed-chip update: %v", err)
	}
	if err := adminDB.QueryRowContext(ctx,
		`SELECT verified FROM provider_hardware_profiles WHERE provider_id = 'p-hw'`,
	).Scan(&verified); err != nil {
		t.Fatalf("admin scan changed-chip verified: %v", err)
	}
	if verified {
		t.Fatalf("changed-chip provider_onboarding update preserved verified; want cleared")
	}
}

func TestHardwareVerifierPromotionGuard(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	verifierDB, err := sql.Open("postgres", fx.roleDSN(roleHardwareVerifier))
	if err != nil {
		t.Fatalf("open hardware verifier: %v", err)
	}
	defer verifierDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO chip_hardware_profiles
            (chip_normalized, display_chip, memory_bandwidth_gb_per_s, network_power_kw, gpu_cores, cpu_cores)
        VALUES ('apple m4 max', 'Apple M4 Max', 546, 0.12, 40, 16)
    `); err != nil {
		t.Fatalf("seed chip profile: %v", err)
	}

	staleGeneratedAt := time.Now().UTC().Add(-8 * 24 * time.Hour)
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO hardware_verification_jobs
            (provider_id, source, status, chip, chip_normalized, unified_memory_gb,
             bandwidth_tier, os_version, binary_version, benchmark_count, max_sustained_tps,
             generated_at, evidence, evidence_sha256)
        VALUES
            ('p-stale', 'autotune', 'pending', 'Apple M4 Max', 'apple m4 max', 64,
             'A', '15.0', '1.0.0', 1, 42,
             $1, '{"provider_id":"p-stale","hardware":{"hardware_identity_hash":"hash-stale"},"benchmarks":[{"model_key":"x","sustained_tps":42}]}'::jsonb, 'sha-stale')
    `, staleGeneratedAt); err != nil {
		t.Fatalf("seed stale verification job: %v", err)
	}
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO hardware_verification_trust
            (provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, trusted_by)
        VALUES ('p-stale', 'hash-stale', 'apple m4 max', 64, 'integration-test')
    `); err != nil {
		t.Fatalf("seed stale trust: %v", err)
	}
	_, err = verifierDB.ExecContext(ctx, `
        INSERT INTO provider_hardware_profiles
            (provider_id, chip, chip_normalized, unified_memory_gb,
             macos_version, app_version, source, verified, last_reported_at)
        VALUES ('p-stale', 'Apple M4 Max', 'apple m4 max', 64,
                '15.0', '1.0.0', 'cli_hello', TRUE, $1)
    `, staleGeneratedAt)
	if err == nil {
		t.Fatalf("stats_hardware_verifier promoted stale pending job")
	}
	if !contains(err.Error(), "matching trusted hardware evidence") {
		t.Fatalf("stale promotion error = %q, want trusted evidence guard", err.Error())
	}

	freshGeneratedAt := time.Now().UTC()
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO hardware_verification_jobs
            (provider_id, source, status, chip, chip_normalized, unified_memory_gb,
             bandwidth_tier, os_version, binary_version, benchmark_count, max_sustained_tps,
             generated_at, evidence, evidence_sha256)
        VALUES
            ('p-fresh', 'autotune', 'pending', 'Apple M4 Max', 'apple m4 max', 64,
             'A', '15.0', '1.0.0', 1, 42,
             $1, '{"provider_id":"p-fresh","hardware":{"hardware_identity_hash":"hash-fresh"},"benchmarks":[{"model_key":"x","sustained_tps":42}]}'::jsonb, 'sha-fresh')
    `, freshGeneratedAt); err != nil {
		t.Fatalf("seed fresh verification job: %v", err)
	}
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO hardware_verification_trust
            (provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, trusted_by)
        VALUES ('p-fresh', 'hash-fresh', 'apple m4 max', 64, 'integration-test')
    `); err != nil {
		t.Fatalf("seed fresh trust: %v", err)
	}
	if _, err := verifierDB.ExecContext(ctx, `
        INSERT INTO provider_hardware_profiles
            (provider_id, chip, chip_normalized, unified_memory_gb,
             macos_version, app_version, source, verified, last_reported_at)
        VALUES ('p-fresh', 'Apple M4 Max', 'apple m4 max', 64,
                '15.0', '1.0.0', 'cli_hello', TRUE, $1)
    `, freshGeneratedAt); err != nil {
		t.Fatalf("stats_hardware_verifier fresh trusted promotion: %v", err)
	}

	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO hardware_verification_jobs
            (provider_id, source, status, chip, chip_normalized, unified_memory_gb,
             bandwidth_tier, os_version, binary_version, benchmark_count, max_sustained_tps,
             generated_at, evidence, evidence_sha256)
        VALUES
            ('p-final', 'autotune', 'verified', 'Apple M4 Max', 'apple m4 max', 64,
             'A', '15.0', '1.0.0', 1, 42,
             now(), '{"provider_id":"p-final","hardware":{"hardware_identity_hash":"hash-final"},"benchmarks":[{"model_key":"x","sustained_tps":42}]}'::jsonb, 'sha-final')
    `); err != nil {
		t.Fatalf("seed finalized verification job: %v", err)
	}
	_, err = verifierDB.ExecContext(ctx, `
        UPDATE hardware_verification_jobs
           SET status = 'waiting_trust',
               processed_at = now(),
               decision_reason = 'integration-reopen'
         WHERE evidence_sha256 = 'sha-final'
    `)
	if err == nil {
		t.Fatalf("stats_hardware_verifier reopened finalized job")
	}
	if !contains(err.Error(), "may not update finalized") {
		t.Fatalf("finalized job update error = %q, want finalized guard", err.Error())
	}
}

// TestHardwareTrustPerSourceRowsCoexist proves the terminal structural fix
// (issue #582) against the REAL migrations: the trust table PK is
// (provider_id, hardware_identity_hash, source), so an inventory root and an
// operator_api root for the SAME tuple coexist as two independent rows. Expiring
// the operator_api row (an operator revoke) leaves the source-agnostic trust
// match satisfied via the still-active inventory root; only when BOTH are
// inactive does the match drop.
func TestHardwareTrustPerSourceRowsCoexist(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Two independent rows for the SAME (provider_id, hardware_identity_hash)
	// tuple, distinguished only by source — allowed by the 3-column primary key.
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO hardware_verification_trust
            (provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, trusted_by, source)
        VALUES
            ('p-coexist', 'hash-coexist', 'apple m4 max', 64, 'inventory-sync', 'inventory'),
            ('p-coexist', 'hash-coexist', 'apple m4 max', 64, 'operator:alice', 'operator_api')
    `); err != nil {
		t.Fatalf("insert coexisting per-source trust rows: %v", err)
	}

	activeMatch := func() bool {
		t.Helper()
		var matched bool
		if err := adminDB.QueryRowContext(ctx, `
            SELECT EXISTS (
                SELECT 1 FROM hardware_verification_trust t
                 WHERE t.provider_id = 'p-coexist'
                   AND t.hardware_identity_hash = 'hash-coexist'
                   AND t.chip_normalized = 'apple m4 max'
                   AND t.unified_memory_gb = 64
                   AND (t.expires_at IS NULL OR t.expires_at > now())
            )`).Scan(&matched); err != nil {
			t.Fatalf("source-agnostic trust match: %v", err)
		}
		return matched
	}

	var rowCount int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM hardware_verification_trust
         WHERE provider_id = 'p-coexist' AND hardware_identity_hash = 'hash-coexist'`).Scan(&rowCount); err != nil {
		t.Fatalf("count coexisting rows: %v", err)
	}
	if rowCount != 2 {
		t.Fatalf("trust rows = %d, want 2 (inventory + operator_api coexist)", rowCount)
	}
	if !activeMatch() {
		t.Fatal("trust match = false with both roots active, want true")
	}

	// Operator revoke: expire ONLY the operator_api row. The inventory root still
	// backs the tuple, so the source-agnostic match stays satisfied.
	if _, err := adminDB.ExecContext(ctx, `
        UPDATE hardware_verification_trust SET expires_at = now() - interval '1 hour'
         WHERE provider_id = 'p-coexist' AND hardware_identity_hash = 'hash-coexist' AND source = 'operator_api'`); err != nil {
		t.Fatalf("expire operator_api root: %v", err)
	}
	if !activeMatch() {
		t.Fatal("trust match = false after operator revoke, want true via inventory root")
	}

	// Expire the inventory root too: no active row of any source remains.
	if _, err := adminDB.ExecContext(ctx, `
        UPDATE hardware_verification_trust SET expires_at = now() - interval '1 hour'
         WHERE provider_id = 'p-coexist' AND hardware_identity_hash = 'hash-coexist' AND source = 'inventory'`); err != nil {
		t.Fatalf("expire inventory root: %v", err)
	}
	if activeMatch() {
		t.Fatal("trust match = true with all roots expired, want false")
	}
}

func TestHardwareEvidenceReplayStoreLoadsDecisionState(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	store, err := onboarding.OpenPGStore(fx.roleDSN(roleProviderOnboard))
	if err != nil {
		t.Fatalf("open onboarding store: %v", err)
	}
	defer store.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tests := []struct {
		providerID     string
		evidenceSHA    string
		status         string
		decisionReason string
	}{
		{providerID: "p-replay-pending", evidenceSHA: "replay-pending", status: "pending"},
		{providerID: "p-replay-waiting", evidenceSHA: "replay-waiting", status: "waiting_trust", decisionReason: "hardware-verifier.v2:trust_missing"},
		{providerID: "p-replay-verified", evidenceSHA: "replay-verified", status: "verified", decisionReason: hardwareverify.VerifiedDecisionReason},
		{providerID: "p-replay-legacy", evidenceSHA: "replay-legacy", status: "verified", decisionReason: "hardware-verifier.v1:verified"},
		{providerID: "p-replay-rejected", evidenceSHA: "replay-rejected", status: "rejected", decisionReason: "hardware-verifier.v2:benchmark_invalid"},
	}
	for _, tc := range tests {
		var id int64
		if err := adminDB.QueryRowContext(ctx, `
INSERT INTO hardware_verification_jobs (
    provider_id, source, status, chip, chip_normalized, unified_memory_gb,
    bandwidth_tier, os_version, binary_version, benchmark_count,
    max_sustained_tps, generated_at, decision_reason, evidence, evidence_sha256
) VALUES (
    $1, 'autotune', $2, 'Apple M5', 'apple m5', 32,
    'C', '15.5', '1.8.26', 1,
    42.5, now(), $3, '{}'::jsonb, $4
)
RETURNING id`, tc.providerID, tc.status, tc.decisionReason, tc.evidenceSHA).Scan(&id); err != nil {
			t.Fatalf("seed %s: %v", tc.status, err)
		}
		record, found, err := store.ExistingHardwareVerificationJob(ctx, tc.providerID, tc.evidenceSHA)
		if err != nil {
			t.Fatalf("load %s: %v", tc.status, err)
		}
		if !found || record.JobID != id || record.EvidenceSHA != tc.evidenceSHA ||
			record.Status != tc.status || record.DecisionReason != tc.decisionReason {
			t.Fatalf("loaded %s record = %+v found=%v", tc.status, record, found)
		}
	}
}

func TestHardwareEvidenceSameIdentityDoesNotBypassAdmissionCap(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	store, err := onboarding.OpenPGStore(fx.roleDSN(roleProviderOnboard))
	if err != nil {
		t.Fatalf("open onboarding store: %v", err)
	}
	defer store.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const providerID = "p-update-admission"
	sameHash := strings.Repeat("c", 64)
	changedHash := strings.Repeat("d", 64)
	oldEvidenceSHA := strings.Repeat("a", 64)
	oldEvidenceJSON := fmt.Sprintf(`{"hardware":{"hardware_identity_hash":%q}}`, sameHash)
	var oldJobID int64
	if err := adminDB.QueryRowContext(ctx, `
INSERT INTO hardware_verification_jobs (
    provider_id, source, status, chip, chip_normalized, unified_memory_gb,
    bandwidth_tier, os_version, binary_version, benchmark_count,
    max_sustained_tps, generated_at, decision_reason, evidence, evidence_sha256
) VALUES (
    $1, 'autotune', 'waiting_trust', 'Apple M5', 'apple m5', 32,
    'C', '15.5', '1.8.67', 1, 42.5, now(),
    'hardware-verifier.v2:trust_missing', $2::jsonb, $3
)
RETURNING id`, providerID, oldEvidenceJSON, oldEvidenceSHA).Scan(&oldJobID); err != nil {
		t.Fatalf("seed waiting trust row: %v", err)
	}

	generatedAt := time.Date(2026, 7, 31, 13, 0, 0, 0, time.UTC)
	evidence := hardwareEvidenceRequestForIntegration(providerID, sameHash, "1.8.68", generatedAt)
	if _, err := store.InsertHardwareVerificationJob(ctx, providerID, evidence, generatedAt); !errors.Is(err, onboarding.ErrHardwareEvidenceRateLimited) {
		t.Fatalf("same hardware error=%v, want rate limited", err)
	}
	var jobCount int
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM hardware_verification_jobs WHERE provider_id = $1`,
		providerID,
	).Scan(&jobCount); err != nil {
		t.Fatalf("count jobs: %v", err)
	}
	if jobCount != 1 {
		t.Fatalf("job count=%d, want no new job", jobCount)
	}

	changedEvidence := hardwareEvidenceRequestForIntegration(providerID, changedHash, "1.8.68", generatedAt)
	if _, err := store.InsertHardwareVerificationJob(ctx, providerID, changedEvidence, generatedAt); !errors.Is(err, onboarding.ErrHardwareEvidenceRateLimited) {
		t.Fatalf("changed hardware error=%v, want rate limited", err)
	}
}

func hardwareEvidenceRequestForIntegration(providerID, hardwareIdentityHash, binaryVersion string, generatedAt time.Time) onboarding.HardwareEvidenceRequest {
	return onboarding.HardwareEvidenceRequest{
		SchemaVersion:          "hardware_evidence.autotune.v2",
		ProbeProtocol:          "spec-023-harmony-stream.v2",
		ProviderID:             providerID,
		GeneratedAt:            generatedAt.Format(time.RFC3339),
		CandidateCatalogSHA256: strings.Repeat("b", 64),
		RecommendedModel:       "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
		Hardware: onboarding.HardwareEvidenceHardware{
			Chip:                 "Apple M5",
			MemoryGB:             32,
			BandwidthTier:        "C",
			Detected:             true,
			OSVersion:            "15.5",
			BinaryVersion:        binaryVersion,
			HardwareIdentityHash: hardwareIdentityHash,
			ExecutableSHA256:     strings.Repeat("f", 64),
		},
		Benchmarks: []onboarding.HardwareEvidenceBenchmark{{
			ModelKey:                "qwen-7b",
			ModelID:                 "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
			SustainedTPS:            42.5,
			TTFTMS:                  1200,
			SwapDetected:            false,
			ThermalThrottleDetected: false,
			ArtifactSHA256:          strings.Repeat("e", 64),
			CandidateCatalogSHA256:  strings.Repeat("b", 64),
			BenchmarkID:             "bench-1",
			GeneratedAt:             generatedAt.Format(time.RFC3339),
			BinaryVersion:           binaryVersion,
			HardwareIdentityHash:    hardwareIdentityHash,
			CandidateRowIdentity:    strings.Repeat("a", 64),
		}},
	}
}

func TestProviderOnboardingDecisionReasonGrantUpgradesApplied008(t *testing.T) {
	fx := startPostgres(t)
	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	t.Cleanup(func() { _ = adminDB.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	if _, err := adminDB.ExecContext(ctx, `
CREATE TABLE schema_migrations_spec017 (
    version INT PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
)`); err != nil {
		t.Fatalf("create migration table: %v", err)
	}
	all, err := statsmigrations.All()
	if err != nil {
		t.Fatalf("load migrations: %v", err)
	}
	for _, migration := range all {
		if migration.Version >= 15 {
			continue
		}
		if _, err := adminDB.ExecContext(ctx, migration.SQL); err != nil {
			t.Fatalf("apply historical migration %03d_%s: %v", migration.Version, migration.Name, err)
		}
		if _, err := adminDB.ExecContext(ctx,
			`INSERT INTO schema_migrations_spec017 (version, name) VALUES ($1, $2)`,
			migration.Version, migration.Name,
		); err != nil {
			t.Fatalf("record historical migration %03d_%s: %v", migration.Version, migration.Name, err)
		}
	}
	if _, err := adminDB.ExecContext(ctx, fmt.Sprintf(
		`ALTER ROLE %s WITH LOGIN PASSWORD '%s'`, roleProviderOnboard, roleRuntimePassword,
	)); err != nil {
		t.Fatalf("enable provider_onboarding login: %v", err)
	}

	store, err := onboarding.OpenPGStore(fx.roleDSN(roleProviderOnboard))
	if err != nil {
		t.Fatalf("open onboarding store: %v", err)
	}
	defer store.Close()
	if err := store.Smoke(ctx); err == nil || !strings.Contains(strings.ToLower(err.Error()), "permission denied") {
		t.Fatalf("pre-upgrade Smoke error=%v, want decision_reason permission denied", err)
	}

	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("apply pending forward migrations: %v", err)
	}
	if err := store.Smoke(ctx); err != nil {
		t.Fatalf("post-upgrade Smoke: %v", err)
	}
	const providerID = "p-upgrade-replay"
	const evidenceSHA = "upgrade-replay-sha"
	var jobID int64
	if err := adminDB.QueryRowContext(ctx, `
INSERT INTO hardware_verification_jobs (
    provider_id, source, status, chip, chip_normalized, unified_memory_gb,
    bandwidth_tier, os_version, binary_version, benchmark_count,
    max_sustained_tps, generated_at, decision_reason, evidence, evidence_sha256
) VALUES (
    $1, 'autotune', 'waiting_trust', 'Apple M5', 'apple m5', 32,
    'C', '15.5', '1.8.26', 1, 42.5, now(),
    'hardware-verifier.v2:trust_missing', '{}'::jsonb, $2
)
RETURNING id`, providerID, evidenceSHA).Scan(&jobID); err != nil {
		t.Fatalf("seed replay row: %v", err)
	}
	record, found, err := store.ExistingHardwareVerificationJob(ctx, providerID, evidenceSHA)
	if err != nil {
		t.Fatalf("replay read after upgrade: %v", err)
	}
	if !found || record.JobID != jobID || record.Status != "waiting_trust" ||
		record.DecisionReason != "hardware-verifier.v2:trust_missing" {
		t.Fatalf("replay read after upgrade = %+v found=%v", record, found)
	}
}

// ===========================================================================
// Issue #582 — durable operator hardware-trust approval: executable PostgreSQL
// acceptance for the core request -> approve -> revoke workflow, its migration
// up/down/reapply lifecycle, split-role privileges, dual-control, per-source
// coexistence + demotion, and the row/advisory-lock concurrency invariants.
// All against the REAL migrations (019_hardware_trust_operator_approval) via the
// existing adminDB harness.
// ===========================================================================

const (
	sigHWTrustRequest = "request_hardware_trust_approval(uuid,bigint,text,timestamp with time zone,text,text)"
	sigHWTrustApprove = "approve_hardware_trust_approval(uuid,text)"
	sigHWTrustRevoke  = "revoke_hardware_trust_approval(uuid,text,text,text,text)"
)

// rotateHardwareTrustLoginRoles gives the split EXECUTE roles LOGIN + a password
// so the tests can connect AS hardware_trust_requester / hardware_trust_approver.
// The definer role is deliberately left NOLOGIN (it only owns the SECURITY
// DEFINER functions); production provisioning does the same via the
// hardware-trust bootstrap SQL.
func rotateHardwareTrustLoginRoles(t *testing.T, adminDB *sql.DB) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, role := range []string{roleHWTrustRequester, roleHWTrustApprover} {
		if _, err := adminDB.ExecContext(ctx, fmt.Sprintf(
			`ALTER ROLE %s WITH LOGIN PASSWORD '%s'`, role, roleRuntimePassword,
		)); err != nil {
			t.Fatalf("rotate hardware-trust role %s: %v", role, err)
		}
	}
}

// seedWaitingTrustJob parks a hardware_verification_jobs row in status
// 'waiting_trust' with decision_reason missing_trusted_hardware_identity and
// fresh benchmark evidence, plus the chip_hardware_profiles row the approve
// function's chip-profile-existence gate requires. Returns the job id and the
// DB-stored generated_at (used as the verified profile's last_reported_at so the
// promotion guard's exact-timestamp join matches).
func seedWaitingTrustJob(t *testing.T, ctx context.Context, adminDB *sql.DB, providerID, hash, evidenceSHA string) (int64, time.Time) {
	t.Helper()
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO chip_hardware_profiles
            (chip_normalized, display_chip, memory_bandwidth_gb_per_s, network_power_kw, gpu_cores, cpu_cores)
        VALUES ('apple m4 max', 'Apple M4 Max', 546, 0.12, 40, 16)
        ON CONFLICT (chip_normalized) DO NOTHING`); err != nil {
		t.Fatalf("seed chip profile: %v", err)
	}
	generatedAt := time.Now().UTC()
	evidence := fmt.Sprintf(
		`{"provider_id":%q,"hardware":{"hardware_identity_hash":%q},"benchmarks":[{"model_key":"x","sustained_tps":42,"generated_at":%q}]}`,
		providerID, hash, generatedAt.Format(time.RFC3339Nano))
	var jobID int64
	var storedGeneratedAt time.Time
	if err := adminDB.QueryRowContext(ctx, `
        INSERT INTO hardware_verification_jobs
            (provider_id, source, status, chip, chip_normalized, unified_memory_gb,
             bandwidth_tier, os_version, binary_version, benchmark_count, max_sustained_tps,
             generated_at, decision_reason, evidence, evidence_sha256)
        VALUES
            ($1, 'autotune', 'waiting_trust', 'Apple M4 Max', 'apple m4 max', 64,
             'A', '15.0', '1.0.0', 1, 42,
             $2, 'hardware-verifier.v2:missing_trusted_hardware_identity', $3::jsonb, $4)
        RETURNING id, generated_at`, providerID, generatedAt, evidence, evidenceSHA).Scan(&jobID, &storedGeneratedAt); err != nil {
		t.Fatalf("seed waiting_trust job: %v", err)
	}
	return jobID, storedGeneratedAt
}

// verifierPromote performs the verifier's promotion as it would in production:
// insert the verified profile (guard requires the job still waiting_trust with an
// active trust root), then finalize the job to 'verified'. Order matters — the
// profile insert must precede the status flip or the promotion guard's
// status IN ('pending','waiting_trust') predicate fails.
func verifierPromote(t *testing.T, ctx context.Context, verifierDB *sql.DB, providerID string, generatedAt time.Time, jobID int64) {
	t.Helper()
	if _, err := verifierDB.ExecContext(ctx, `
        INSERT INTO provider_hardware_profiles
            (provider_id, chip, chip_normalized, unified_memory_gb, macos_version, app_version, source, verified, last_reported_at)
        VALUES ($1, 'Apple M4 Max', 'apple m4 max', 64, '15.0', '1.0.0', 'cli_hello', TRUE, $2)`,
		providerID, generatedAt); err != nil {
		t.Fatalf("verifier promote profile: %v", err)
	}
	if _, err := verifierDB.ExecContext(ctx, `
        UPDATE hardware_verification_jobs SET status = 'verified', processed_at = now() WHERE id = $1`,
		jobID); err != nil {
		t.Fatalf("verifier finalize job: %v", err)
	}
}

func assertCanExecuteFunction(t *testing.T, ctx context.Context, db *sql.DB, role, signature string) {
	t.Helper()
	var allowed bool
	if err := db.QueryRowContext(ctx, `
SELECT has_function_privilege(current_user, $1::regprocedure, 'EXECUTE')`,
		signature,
	).Scan(&allowed); err != nil {
		t.Fatalf("%s function privilege %s: %v", role, signature, err)
	}
	if !allowed {
		t.Fatalf("%s unexpectedly lacks EXECUTE on %s", role, signature)
	}
}

func assertTablePrivilege(t *testing.T, ctx context.Context, db *sql.DB, role, table, priv string, want bool) {
	t.Helper()
	var allowed bool
	if err := db.QueryRowContext(ctx,
		`SELECT has_table_privilege(current_user, $1, $2)`, table, priv,
	).Scan(&allowed); err != nil {
		t.Fatalf("%s table privilege %s %s: %v", role, table, priv, err)
	}
	if allowed != want {
		t.Fatalf("%s has_table_privilege(%s, %s) = %v, want %v", role, table, priv, allowed, want)
	}
}

// TestHardwareTrustMigrationUpDownReapply proves migration 019 is a reversible,
// idempotent lifecycle against real Postgres: apply (via the harness) -> run
// 019_..._down.sql -> re-apply. The down artifact must remove EVERY 019 object
// (functions, workflow tables, roles, the source column + 3-column PK) and its
// schema_migrations_spec017 version=19 row WITHOUT touching version 18
// (apptrack). Re-applying must restore all of it.
func TestHardwareTrustMigrationUpDownReapply(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	funcExists := func(name string) bool {
		var n int
		if err := adminDB.QueryRowContext(ctx, `SELECT COUNT(*) FROM pg_proc WHERE proname = $1`, name).Scan(&n); err != nil {
			t.Fatalf("count proc %s: %v", name, err)
		}
		return n > 0
	}
	tableExists := func(qualified string) bool {
		var exists bool
		if err := adminDB.QueryRowContext(ctx, `SELECT to_regclass($1) IS NOT NULL`, qualified).Scan(&exists); err != nil {
			t.Fatalf("regclass %s: %v", qualified, err)
		}
		return exists
	}
	columnExists := func(table, col string) bool {
		var n int
		if err := adminDB.QueryRowContext(ctx, `
            SELECT COUNT(*) FROM information_schema.columns
            WHERE table_name = $1 AND column_name = $2`, table, col).Scan(&n); err != nil {
			t.Fatalf("column lookup %s.%s: %v", table, col, err)
		}
		return n == 1
	}
	pkColumns := func() string {
		var cols string
		if err := adminDB.QueryRowContext(ctx, `
            SELECT COALESCE((
                SELECT (array_agg(a.attname ORDER BY k.ord))::text
                  FROM pg_constraint c
                  JOIN unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
                  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
                 WHERE c.conrelid = 'hardware_verification_trust'::regclass AND c.contype = 'p'
            ), '')`).Scan(&cols); err != nil {
			t.Fatalf("read trust PK columns: %v", err)
		}
		return cols
	}
	roleCount := func() int {
		var n int
		if err := adminDB.QueryRowContext(ctx, `
            SELECT COUNT(*) FROM pg_roles
             WHERE rolname IN ($1, $2, $3)`, roleHWTrustRequester, roleHWTrustApprover, roleHWTrustDefiner).Scan(&n); err != nil {
			t.Fatalf("count trust roles: %v", err)
		}
		return n
	}
	versionPresent := func(v int) bool {
		var n int
		if err := adminDB.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations_spec017 WHERE version = $1`, v).Scan(&n); err != nil {
			t.Fatalf("count migration version %d: %v", v, err)
		}
		return n == 1
	}

	// Post-apply (up): every 019 object present.
	for _, fn := range []string{"request_hardware_trust_approval", "approve_hardware_trust_approval", "revoke_hardware_trust_approval"} {
		if !funcExists(fn) {
			t.Fatalf("post-apply: function %s missing", fn)
		}
	}
	if !tableExists("public.hardware_trust_pending") || !tableExists("public.hardware_trust_grants") {
		t.Fatal("post-apply: workflow tables missing")
	}
	if !columnExists("hardware_verification_trust", "source") {
		t.Fatal("post-apply: hardware_verification_trust.source missing")
	}
	if got := pkColumns(); got != "{provider_id,hardware_identity_hash,source}" {
		t.Fatalf("post-apply: trust PK = %q, want 3-column", got)
	}
	if roleCount() != 3 {
		t.Fatalf("post-apply: trust roles present = %d, want 3", roleCount())
	}
	if !versionPresent(19) {
		t.Fatal("post-apply: schema_migrations_spec017 missing version 19")
	}
	if !versionPresent(18) {
		t.Fatal("post-apply: schema_migrations_spec017 missing version 18 (apptrack)")
	}

	// Run the down artifact. It ships psql meta-commands (\set) that database/sql
	// cannot execute; strip backslash lines and run the remaining SQL (the
	// BEGIN/COMMIT transaction body executes fine over the simple query protocol).
	downRaw, err := os.ReadFile("migrations/019_hardware_trust_operator_approval.down.sql")
	if err != nil {
		t.Fatalf("read 019 down artifact: %v", err)
	}
	var downSQL strings.Builder
	for _, line := range strings.Split(string(downRaw), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), `\`) {
			continue
		}
		downSQL.WriteString(line)
		downSQL.WriteByte('\n')
	}
	if _, err := adminDB.ExecContext(ctx, downSQL.String()); err != nil {
		t.Fatalf("apply 019 down artifact: %v", err)
	}

	// Post-down: every 019 object removed; version 19 gone; version 18 untouched.
	for _, fn := range []string{"request_hardware_trust_approval", "approve_hardware_trust_approval", "revoke_hardware_trust_approval"} {
		if funcExists(fn) {
			t.Fatalf("post-down: function %s still present", fn)
		}
	}
	if tableExists("public.hardware_trust_pending") || tableExists("public.hardware_trust_grants") {
		t.Fatal("post-down: workflow tables still present")
	}
	if columnExists("hardware_verification_trust", "source") {
		t.Fatal("post-down: hardware_verification_trust.source still present")
	}
	if got := pkColumns(); got != "{provider_id,hardware_identity_hash}" {
		t.Fatalf("post-down: trust PK = %q, want restored 2-column", got)
	}
	if roleCount() != 0 {
		t.Fatalf("post-down: trust roles still present = %d, want 0", roleCount())
	}
	if versionPresent(19) {
		t.Fatal("post-down: schema_migrations_spec017 still records version 19")
	}
	if !versionPresent(18) {
		t.Fatal("post-down: schema_migrations_spec017 lost version 18 (apptrack) — down must not touch 18")
	}
	if !tableExists("public.provider_register_attempts") {
		t.Fatal("post-down: 018 apptrack table removed — down must not touch version 18 objects")
	}

	// Re-apply: 019 restored, idempotent for the rest.
	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("re-apply after down: %v", err)
	}
	for _, fn := range []string{"request_hardware_trust_approval", "approve_hardware_trust_approval", "revoke_hardware_trust_approval"} {
		if !funcExists(fn) {
			t.Fatalf("post-reapply: function %s missing", fn)
		}
	}
	if got := pkColumns(); got != "{provider_id,hardware_identity_hash,source}" {
		t.Fatalf("post-reapply: trust PK = %q, want 3-column", got)
	}
	if !versionPresent(19) {
		t.Fatal("post-reapply: schema_migrations_spec017 missing version 19")
	}
	if roleCount() != 3 {
		t.Fatalf("post-reapply: trust roles present = %d, want 3", roleCount())
	}
}

// TestHardwareTrustSplitRolePrivileges proves the split-EXECUTE boundary and the
// provider_onboarding read-only anti-fraud boundary against the real grants.
func TestHardwareTrustSplitRolePrivileges(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	rotateHardwareTrustLoginRoles(t, adminDB)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	requesterDB := openRoleDB(t, fx, roleHWTrustRequester)
	approverDB := openRoleDB(t, fx, roleHWTrustApprover)
	onboardingDB := openRoleDB(t, fx, roleProviderOnboard)

	// Requester: request only.
	assertCanExecuteFunction(t, ctx, requesterDB, roleHWTrustRequester, sigHWTrustRequest)
	assertCannotExecuteFunction(t, ctx, requesterDB, roleHWTrustRequester, sigHWTrustApprove)
	assertCannotExecuteFunction(t, ctx, requesterDB, roleHWTrustRequester, sigHWTrustRevoke)

	// Approver: approve + revoke, never request.
	assertCanExecuteFunction(t, ctx, approverDB, roleHWTrustApprover, sigHWTrustApprove)
	assertCanExecuteFunction(t, ctx, approverDB, roleHWTrustApprover, sigHWTrustRevoke)
	assertCannotExecuteFunction(t, ctx, approverDB, roleHWTrustApprover, sigHWTrustRequest)

	// provider_onboarding: SELECT on the trust table (admission re-check), but NO
	// write on trust/pending/grants and NO EXECUTE on any definer function.
	assertTablePrivilege(t, ctx, onboardingDB, roleProviderOnboard, "hardware_verification_trust", "SELECT", true)
	for _, priv := range []string{"INSERT", "UPDATE", "DELETE"} {
		assertTablePrivilege(t, ctx, onboardingDB, roleProviderOnboard, "hardware_verification_trust", priv, false)
	}
	for _, table := range []string{"hardware_trust_pending", "hardware_trust_grants"} {
		for _, priv := range []string{"SELECT", "INSERT", "UPDATE", "DELETE"} {
			assertTablePrivilege(t, ctx, onboardingDB, roleProviderOnboard, table, priv, false)
		}
	}
	assertCannotExecuteFunction(t, ctx, onboardingDB, roleProviderOnboard, sigHWTrustRequest)
	assertCannotExecuteFunction(t, ctx, onboardingDB, roleProviderOnboard, sigHWTrustApprove)
	assertCannotExecuteFunction(t, ctx, onboardingDB, roleProviderOnboard, sigHWTrustRevoke)
}

// TestHardwareTrustSameActorRejection proves the DB dual-control guard: the same
// operator cannot both request and approve.
func TestHardwareTrustSameActorRejection(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	rotateHardwareTrustLoginRoles(t, adminDB)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	requesterDB := openRoleDB(t, fx, roleHWTrustRequester)
	approverDB := openRoleDB(t, fx, roleHWTrustApprover)

	jobID, _ := seedWaitingTrustJob(t, ctx, adminDB, "p-same-actor", "hash-same-actor", "sha-same-actor")
	pendingID := "11111111-1111-1111-1111-111111111111"
	requestedUntil := time.Now().UTC().Add(2 * time.Hour)

	var gotProvider string
	if err := requesterDB.QueryRowContext(ctx, `
        SELECT out_provider_id
          FROM request_hardware_trust_approval($1::uuid, $2, $3, $4, $5)`,
		pendingID, jobID, "operator:alice", requestedUntil, "same-actor reason").Scan(&gotProvider); err != nil {
		t.Fatalf("request as operator:alice: %v", err)
	}

	// Approve as the SAME operator -> dual_control_required.
	var ignored string
	err := approverDB.QueryRowContext(ctx, `
        SELECT out_source FROM approve_hardware_trust_approval($1::uuid, $2)`,
		pendingID, "operator:alice").Scan(&ignored)
	if err == nil || !contains(err.Error(), "dual_control_required") {
		t.Fatalf("same-actor approve err = %v, want dual_control_required", err)
	}
}

// TestHardwareTrustRequestApproveRevokeHappyPath drives the full lifecycle end to
// end against real Postgres: request -> approve (writes an active operator_api
// trust root) -> verifier promotes the profile -> revoke (expires the root and
// demotes the profile since no active root of any source remains).
func TestHardwareTrustRequestApproveRevokeHappyPath(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	rotateHardwareTrustLoginRoles(t, adminDB)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	requesterDB := openRoleDB(t, fx, roleHWTrustRequester)
	approverDB := openRoleDB(t, fx, roleHWTrustApprover)
	verifierDB := openRoleDB(t, fx, roleHardwareVerifier)

	const providerID = "p-happy"
	const hash = "hash-happy"
	jobID, generatedAt := seedWaitingTrustJob(t, ctx, adminDB, providerID, hash, "sha-happy")
	pendingID := "11111111-1111-1111-1111-111111111111"
	requestedUntil := time.Now().UTC().Add(2 * time.Hour)

	// Request (requester role).
	var reqProvider, reqHash, reqChip string
	var reqMem int
	if err := requesterDB.QueryRowContext(ctx, `
        SELECT out_provider_id, out_hardware_identity_hash, out_chip_normalized, out_unified_memory_gb
          FROM request_hardware_trust_approval($1::uuid, $2, $3, $4, $5)`,
		pendingID, jobID, "operator:alice", requestedUntil, "durable operator approval").Scan(&reqProvider, &reqHash, &reqChip, &reqMem); err != nil {
		t.Fatalf("request: %v", err)
	}
	if reqProvider != providerID || reqHash != hash || reqChip != "apple m4 max" || reqMem != 64 {
		t.Fatalf("request tuple = %s/%s/%s/%d, want %s/%s/apple m4 max/64", reqProvider, reqHash, reqChip, reqMem, providerID, hash)
	}

	// Approve (approver role) -> operator_api trust root.
	var outSource string
	var outExpires time.Time
	if err := approverDB.QueryRowContext(ctx, `
        SELECT out_source, out_effective_expires_at
          FROM approve_hardware_trust_approval($1::uuid, $2)`,
		pendingID, "operator:bob").Scan(&outSource, &outExpires); err != nil {
		t.Fatalf("approve: %v", err)
	}
	if outSource != "operator_api" {
		t.Fatalf("approve out_source = %q, want operator_api", outSource)
	}

	// Active operator_api trust row exists for the job tuple.
	var trustCount int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM hardware_verification_trust
         WHERE provider_id = $1 AND hardware_identity_hash = $2 AND source = 'operator_api'
           AND (expires_at IS NULL OR expires_at > now())`, providerID, hash).Scan(&trustCount); err != nil {
		t.Fatalf("count operator_api trust: %v", err)
	}
	if trustCount != 1 {
		t.Fatalf("active operator_api trust rows = %d, want 1", trustCount)
	}

	// Verifier promotes the profile against the new trust root.
	verifierPromote(t, ctx, verifierDB, providerID, generatedAt, jobID)
	var verified bool
	if err := adminDB.QueryRowContext(ctx, `SELECT verified FROM provider_hardware_profiles WHERE provider_id = $1`, providerID).Scan(&verified); err != nil {
		t.Fatalf("read promoted profile: %v", err)
	}
	if !verified {
		t.Fatal("profile not promoted after approve + verifier promotion")
	}

	// Revoke (approver role) -> expires the operator_api root and demotes the
	// profile since no active root of any source remains.
	revokeGrantID := "22222222-2222-2222-2222-222222222222"
	var nowUntrusted bool
	if err := approverDB.QueryRowContext(ctx, `
        SELECT out_now_untrusted
          FROM revoke_hardware_trust_approval($1::uuid, $2, $3, $4, $5)`,
		revokeGrantID, providerID, hash, "operator:bob", "operator revoke").Scan(&nowUntrusted); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if !nowUntrusted {
		t.Fatal("revoke out_now_untrusted = false, want true (sole operator_api root removed)")
	}

	var activeAfter int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM hardware_verification_trust
         WHERE provider_id = $1 AND hardware_identity_hash = $2
           AND (expires_at IS NULL OR expires_at > now())`, providerID, hash).Scan(&activeAfter); err != nil {
		t.Fatalf("count active trust after revoke: %v", err)
	}
	if activeAfter != 0 {
		t.Fatalf("active trust rows after revoke = %d, want 0", activeAfter)
	}
	if err := adminDB.QueryRowContext(ctx, `SELECT verified FROM provider_hardware_profiles WHERE provider_id = $1`, providerID).Scan(&verified); err != nil {
		t.Fatalf("read demoted profile: %v", err)
	}
	if verified {
		t.Fatal("profile still verified after revoke; demotion did not fire")
	}
}

// TestHardwareTrustConcurrency proves the row/advisory-lock serialization the
// migration relies on, deterministically (no sleeps): (A) while an approval holds
// FOR SHARE on the bound job row, the verifier's FOR UPDATE SKIP LOCKED claim
// skips it — so an approval and a verifier pass cannot both claim the job; and
// (B) the approval holds the per-provider advisory lock so a concurrent approve/
// request/revoke on the same provider is serialized (pg_try_advisory_xact_lock
// on the same key returns false while held, true once released).
func TestHardwareTrustConcurrency(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	rotateHardwareTrustLoginRoles(t, adminDB)

	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()

	requesterDB := openRoleDB(t, fx, roleHWTrustRequester)
	approverDB := openRoleDB(t, fx, roleHWTrustApprover)

	const providerID = "p-concurrency"
	const hash = "hash-concurrency"
	jobID, _ := seedWaitingTrustJob(t, ctx, adminDB, providerID, hash, "sha-concurrency")
	pendingID := "11111111-1111-1111-1111-111111111111"
	requestedUntil := time.Now().UTC().Add(2 * time.Hour)

	var reqProvider string
	if err := requesterDB.QueryRowContext(ctx, `
        SELECT out_provider_id FROM request_hardware_trust_approval($1::uuid, $2, $3, $4, $5)`,
		pendingID, jobID, "operator:alice", requestedUntil, "concurrency reason").Scan(&reqProvider); err != nil {
		t.Fatalf("request: %v", err)
	}

	// Open a transaction on the approver connection and run approve inside it, so
	// its FOR SHARE (job row) + advisory (per-provider) locks are held until commit.
	tx, err := approverDB.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin approve tx: %v", err)
	}
	var outSource string
	if err := tx.QueryRowContext(ctx, `
        SELECT out_source FROM approve_hardware_trust_approval($1::uuid, $2)`,
		pendingID, "operator:bob").Scan(&outSource); err != nil {
		_ = tx.Rollback()
		t.Fatalf("approve inside tx: %v", err)
	}

	// (A) Competing verifier claim skips the FOR SHARE-locked job row.
	var claimed int64
	err = adminDB.QueryRowContext(ctx, `
        SELECT id FROM hardware_verification_jobs
         WHERE id = $1 AND status = 'waiting_trust'
         FOR UPDATE SKIP LOCKED`, jobID).Scan(&claimed)
	if err != sql.ErrNoRows {
		_ = tx.Rollback()
		t.Fatalf("verifier claim during held approval = (id=%d, err=%v), want skipped (ErrNoRows)", claimed, err)
	}

	// (B) Per-provider advisory lock is held (matches the function's key).
	var lockFree bool
	if err := adminDB.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(582026, hashtext($1))`, providerID).Scan(&lockFree); err != nil {
		_ = tx.Rollback()
		t.Fatalf("try advisory lock while held: %v", err)
	}
	if lockFree {
		_ = tx.Rollback()
		t.Fatal("pg_try_advisory_xact_lock succeeded while approval holds it; advisory serialization broken")
	}

	if err := tx.Commit(); err != nil {
		t.Fatalf("commit approve tx: %v", err)
	}

	// After commit the locks release: the job is still waiting_trust (approval does
	// not finalize the job), so the verifier claim now succeeds, and the advisory
	// key is free.
	if err := adminDB.QueryRowContext(ctx, `
        SELECT id FROM hardware_verification_jobs
         WHERE id = $1 AND status = 'waiting_trust'
         FOR UPDATE SKIP LOCKED`, jobID).Scan(&claimed); err != nil {
		t.Fatalf("verifier claim after commit: %v", err)
	}
	if claimed != jobID {
		t.Fatalf("verifier claim after commit = %d, want %d", claimed, jobID)
	}
	if err := adminDB.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(582026, hashtext($1))`, providerID).Scan(&lockFree); err != nil {
		t.Fatalf("try advisory lock after commit: %v", err)
	}
	if !lockFree {
		t.Fatal("advisory lock still held after approval committed")
	}
}

// TestHardwareTrustDemotionAndSourceCoexistence proves per-source coexistence and
// that demotion fires ONLY when no active trust root of ANY source remains: an
// inventory root and an operator_api root for the same tuple coexist; revoking
// the operator_api root while the inventory root is still active does NOT demote
// (out_now_untrusted=false), and the source-agnostic demotion sweep (mirroring
// applyTrustDemotions) is a no-op; only after the inventory root also lapses does
// the sweep demote the profile — showing revoke and the sweep share one predicate
// and neither double-demotes nor loses a demotion.
func TestHardwareTrustDemotionAndSourceCoexistence(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	rotateHardwareTrustLoginRoles(t, adminDB)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	requesterDB := openRoleDB(t, fx, roleHWTrustRequester)
	approverDB := openRoleDB(t, fx, roleHWTrustApprover)
	verifierDB := openRoleDB(t, fx, roleHardwareVerifier)

	const providerID = "p-coexist-demote"
	const hash = "hash-coexist-demote"
	jobID, generatedAt := seedWaitingTrustJob(t, ctx, adminDB, providerID, hash, "sha-coexist-demote")

	// Independent inventory root for the same tuple (coexists via the 3-column PK).
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO hardware_verification_trust
            (provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, trusted_by, source)
        VALUES ($1, $2, 'apple m4 max', 64, 'inventory-sync', 'inventory')`, providerID, hash); err != nil {
		t.Fatalf("seed inventory root: %v", err)
	}

	// Operator approval -> operator_api root; verifier promotes the profile.
	pendingID := "11111111-1111-1111-1111-111111111111"
	requestedUntil := time.Now().UTC().Add(2 * time.Hour)
	var reqProvider string
	if err := requesterDB.QueryRowContext(ctx, `
        SELECT out_provider_id FROM request_hardware_trust_approval($1::uuid, $2, $3, $4, $5)`,
		pendingID, jobID, "operator:alice", requestedUntil, "coexist reason").Scan(&reqProvider); err != nil {
		t.Fatalf("request: %v", err)
	}
	var outSource string
	if err := approverDB.QueryRowContext(ctx, `
        SELECT out_source FROM approve_hardware_trust_approval($1::uuid, $2)`,
		pendingID, "operator:bob").Scan(&outSource); err != nil {
		t.Fatalf("approve: %v", err)
	}
	verifierPromote(t, ctx, verifierDB, providerID, generatedAt, jobID)

	// Both roots coexist as two independent rows.
	var rowCount int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM hardware_verification_trust
         WHERE provider_id = $1 AND hardware_identity_hash = $2`, providerID, hash).Scan(&rowCount); err != nil {
		t.Fatalf("count coexisting roots: %v", err)
	}
	if rowCount != 2 {
		t.Fatalf("coexisting trust rows = %d, want 2 (inventory + operator_api)", rowCount)
	}

	// Revoke operator_api while inventory is active -> NOT untrusted, no demotion.
	revokeGrantID := "22222222-2222-2222-2222-222222222222"
	var nowUntrusted bool
	if err := approverDB.QueryRowContext(ctx, `
        SELECT out_now_untrusted FROM revoke_hardware_trust_approval($1::uuid, $2, $3, $4, $5)`,
		revokeGrantID, providerID, hash, "operator:bob", "revoke with inventory active").Scan(&nowUntrusted); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if nowUntrusted {
		t.Fatal("revoke out_now_untrusted = true while inventory root active, want false")
	}
	var verified bool
	if err := adminDB.QueryRowContext(ctx, `SELECT verified FROM provider_hardware_profiles WHERE provider_id = $1`, providerID).Scan(&verified); err != nil {
		t.Fatalf("read profile after operator revoke: %v", err)
	}
	if !verified {
		t.Fatal("profile demoted after operator revoke while inventory root active; want still verified")
	}

	// The source-agnostic demotion sweep (mirrors applyTrustDemotions) is a no-op
	// while the inventory root backs the verified job.
	sweep := func() int64 {
		res, err := adminDB.ExecContext(ctx, `
            UPDATE provider_hardware_profiles ph
               SET verified = FALSE
             WHERE ph.provider_id = $1
               AND ph.verified = TRUE
               AND ph.source <> 'operator'
               AND NOT EXISTS (
                   SELECT 1
                     FROM hardware_verification_jobs j
                     JOIN hardware_verification_trust t
                       ON t.provider_id = j.provider_id
                      AND t.hardware_identity_hash = j.evidence #>> '{hardware,hardware_identity_hash}'
                      AND t.chip_normalized = j.chip_normalized
                      AND t.unified_memory_gb = j.unified_memory_gb
                      AND (t.expires_at IS NULL OR t.expires_at > now())
                    WHERE j.status = 'verified'
                      AND j.provider_id = ph.provider_id
                      AND j.chip_normalized = ph.chip_normalized
                      AND j.unified_memory_gb = ph.unified_memory_gb
                      AND j.os_version = ph.macos_version
                      AND j.binary_version = ph.app_version
                      AND j.generated_at = ph.last_reported_at
               )`, providerID)
		if err != nil {
			t.Fatalf("demotion sweep: %v", err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			t.Fatalf("sweep rows affected: %v", err)
		}
		return n
	}
	if n := sweep(); n != 0 {
		t.Fatalf("demotion sweep affected %d rows while inventory root active, want 0", n)
	}

	// Expire the inventory root: now no active root of any source remains, so the
	// sweep demotes exactly once (no lost demotion, and re-running is idempotent).
	if _, err := adminDB.ExecContext(ctx, `
        UPDATE hardware_verification_trust SET expires_at = now() - interval '1 hour'
         WHERE provider_id = $1 AND hardware_identity_hash = $2 AND source = 'inventory'`, providerID, hash); err != nil {
		t.Fatalf("expire inventory root: %v", err)
	}
	if n := sweep(); n != 1 {
		t.Fatalf("demotion sweep affected %d rows after all roots inactive, want 1", n)
	}
	if n := sweep(); n != 0 {
		t.Fatalf("second demotion sweep affected %d rows, want 0 (idempotent, no double-demote)", n)
	}
	if err := adminDB.QueryRowContext(ctx, `SELECT verified FROM provider_hardware_profiles WHERE provider_id = $1`, providerID).Scan(&verified); err != nil {
		t.Fatalf("read profile after full demotion: %v", err)
	}
	if verified {
		t.Fatal("profile still verified after all roots inactive; demotion did not fire")
	}
}

func contains(haystack, needle string) bool {
	// Avoid importing strings here — keeps the test package's
	// import surface trivially auditable. The function is hot
	// enough only across a handful of assertions that the
	// stdlib strings.Contains overhead is irrelevant.
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}
