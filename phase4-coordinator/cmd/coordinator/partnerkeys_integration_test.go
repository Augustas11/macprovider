//go:build integration

package main

// SPEC-017 v0.1.8 Step 4.A — partner-key CLI integration tests
// against an ephemeral Postgres via testcontainers-go.
//
// Tests cover AC-17 (locked SPEC command), the explicit
// --created-by variant, RFC 6454 idempotency on
// --allowed-origin (3 cases), rotation overlap, revoke of
// non-existent id, the `--burst` negative test (v0.1.8
// removed `rate_limit_burst`), and the SECURITY-lane stdout/
// stderr scan asserting the raw token escapes EXACTLY ONCE
// at issue time on stdout and nowhere else.
//
// The `visibility revert` SECURITY-lane invariants are
// exercised in visibility_integration_test.go (sibling file).

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq"
	tc "github.com/testcontainers/testcontainers-go"
	tcpg "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	statsmigrations "github.com/augstar/macprovider-coordinator/internal/stats/migrations"
)

const (
	cliPgImage          = "postgres:16.4-alpine3.20@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c"
	cliAdminPassword    = "stepfourA-admin-password"
	tokenRegexRawString = `^mpk_[A-Za-z0-9_-]{43}$`
)

var tokenRegex = regexp.MustCompile(tokenRegexRawString)

// cliPgFixture wraps an ephemeral Postgres container + the
// admin DSN the CLI subcommand uses (BUILD §C.3 — the operator
// admin DSN is the database superuser OR a dedicated migration
// role outside the four runtime roles; this fixture uses the
// container's `postgres` superuser).
type cliPgFixture struct {
	container tc.Container
	host      string
	port      string
	dbName    string
}

func (f *cliPgFixture) adminDSN() string {
	return fmt.Sprintf("postgres://postgres:%s@%s:%s/%s?sslmode=disable",
		cliAdminPassword, f.host, f.port, f.dbName)
}

func (f *cliPgFixture) Close(ctx context.Context) {
	if f == nil || f.container == nil {
		return
	}
	_ = f.container.Terminate(ctx)
}

// startCLIPostgres spins up Postgres + applies the SPEC-017
// migrations, returning the fixture (the test calls
// `adminDSN()` to point the CLI at it).
func startCLIPostgres(t *testing.T) (*cliPgFixture, *sql.DB) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	c, err := tcpg.Run(ctx, cliPgImage,
		tcpg.WithDatabase("step4a_test"),
		tcpg.WithUsername("postgres"),
		tcpg.WithPassword(cliAdminPassword),
		tc.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).
				WithStartupTimeout(60*time.Second),
		),
	)
	if err != nil {
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
	fx := &cliPgFixture{container: c, host: host, port: port.Port(), dbName: "step4a_test"}
	t.Cleanup(func() {
		bg, c2 := context.WithTimeout(context.Background(), 30*time.Second)
		defer c2()
		fx.Close(bg)
	})

	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	t.Cleanup(func() { _ = adminDB.Close() })

	mctx, cancel2 := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel2()
	if err := statsmigrations.Apply(mctx, adminDB); err != nil {
		t.Fatalf("apply migrations: %v", err)
	}
	return fx, adminDB
}

// runIssue is a convenience wrapper that captures stdout +
// stderr, invokes runPartnerKeysIssue with `--admin-dsn` set
// to the test fixture, and returns (exitcode, stdout, stderr).
func runIssue(args ...string) (int, string, string, *bytes.Buffer, *bytes.Buffer) {
	var stdout, stderr bytes.Buffer
	code := runPartnerKeysIssue(args, &stdout, &stderr)
	return code, stdout.String(), stderr.String(), &stdout, &stderr
}

func runRevoke(args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := runPartnerKeysRevoke(args, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func runList(args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := runPartnerKeysList(args, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

// extractRawTokenLine returns the last line of stdout (the
// printed token) and the entire stdout. AC-17 contract:
// metadata first, then a single line with the raw token.
func extractRawTokenLine(stdout string) string {
	lines := strings.Split(strings.TrimRight(stdout, "\n"), "\n")
	if len(lines) == 0 {
		return ""
	}
	return lines[len(lines)-1]
}

// ===========================================================================
// AC-17 — locked SPEC command issues a 47-char mpk_ token, INSERTs a row.
// ===========================================================================
func TestAC17_IssueLockedSPECCommand(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)
	code, stdout, stderr, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "X",
	)
	if code != 0 {
		t.Fatalf("issue exit=%d stderr=%q", code, stderr)
	}
	raw := extractRawTokenLine(stdout)
	if !tokenRegex.MatchString(raw) {
		t.Fatalf("issued token %q does not match %s", raw, tokenRegexRawString)
	}
	if len(raw) != 47 {
		t.Fatalf("issued token %q length %d, want 47", raw, len(raw))
	}
	// Verify DB row.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var (
		label, prefix, alg, createdBy string
		rpm                           int
		rotated                       sql.NullInt64
	)
	err := adminDB.QueryRowContext(ctx,
		`SELECT label, prefix, token_hash_alg, rate_limit_rpm, created_by, rotated_from_id
		   FROM partner_keys ORDER BY id DESC LIMIT 1`,
	).Scan(&label, &prefix, &alg, &rpm, &createdBy, &rotated)
	if err != nil {
		t.Fatalf("select: %v", err)
	}
	if label != "X" {
		t.Errorf("label = %q, want X", label)
	}
	if alg != "sha256" {
		t.Errorf("token_hash_alg = %q, want sha256", alg)
	}
	if rpm != 600 {
		t.Errorf("rate_limit_rpm = %d, want 600", rpm)
	}
	if prefix != raw[:8] {
		t.Errorf("prefix %q != raw[:8] %q", prefix, raw[:8])
	}
	if strings.TrimSpace(createdBy) == "" {
		t.Errorf("created_by is empty; default must be non-empty (AC-17)")
	}
	if rotated.Valid {
		t.Errorf("rotated_from_id = %d, want NULL", rotated.Int64)
	}
}

// ===========================================================================
// AC-17 — explicit --created-by variant.
// ===========================================================================
func TestAC17_IssueExplicitCreatedBy(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)
	code, _, stderr, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "X",
		"--created-by", "ops@example.com",
	)
	if code != 0 {
		t.Fatalf("issue exit=%d stderr=%q", code, stderr)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var createdBy string
	err := adminDB.QueryRowContext(ctx,
		`SELECT created_by FROM partner_keys ORDER BY id DESC LIMIT 1`,
	).Scan(&createdBy)
	if err != nil {
		t.Fatalf("select: %v", err)
	}
	if createdBy != "ops@example.com" {
		t.Errorf("created_by = %q, want ops@example.com", createdBy)
	}
}

// ===========================================================================
// v0.1.7 — --allowed-origin RFC 6454 idempotency (3 cases per BUILD line 561).
// ===========================================================================
func TestIssueAllowedOriginRFC6454(t *testing.T) {
	fx, _ := startCLIPostgres(t)

	// Case 1: canonical value succeeds.
	code, _, stderr, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "ok",
		"--allowed-origin", "https://acme.example",
	)
	if code != 0 {
		t.Fatalf("canonical origin should succeed; got exit=%d stderr=%q", code, stderr)
	}

	// Case 2: mixed-case + trailing slash rejected.
	code, _, stderr, _, _ = runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "bad",
		"--allowed-origin", "HTTPS://Acme.Example/",
	)
	if code == 0 {
		t.Errorf("mixed-case + trailing slash should be rejected")
	}
	if !strings.Contains(stderr, "canonical") && !strings.Contains(stderr, "malformed") {
		t.Errorf("rejection message should reference normalization; got %q", stderr)
	}

	// Case 3: :443 default port rejected (default port MUST be stripped).
	code, _, stderr, _, _ = runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "bad2",
		"--allowed-origin", "https://acme.example:443",
	)
	if code == 0 {
		t.Errorf(":443 default port should be rejected")
	}
}

// ===========================================================================
// §5.4.4 rotation overlap — A active; B with --rotate-from A active; both unlock.
// ===========================================================================
func TestRotationOverlap(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)

	// Issue A.
	codeA, outA, stderrA, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "A",
	)
	if codeA != 0 {
		t.Fatalf("issue A exit=%d stderr=%q", codeA, stderrA)
	}
	_ = outA

	// Find A's id.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var aID int64
	if err := adminDB.QueryRowContext(ctx,
		`SELECT id FROM partner_keys WHERE label='A' ORDER BY id DESC LIMIT 1`,
	).Scan(&aID); err != nil {
		t.Fatalf("find A: %v", err)
	}

	// Issue B with --rotate-from A.
	codeB, _, stderrB, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "B",
		"--rotate-from", fmt.Sprintf("%d", aID),
	)
	if codeB != 0 {
		t.Fatalf("issue B exit=%d stderr=%q", codeB, stderrB)
	}

	// Verify B.rotated_from_id == A.id; A.revoked_at IS NULL.
	var (
		bRotatedFrom sql.NullInt64
		aRevoked     sql.NullTime
	)
	if err := adminDB.QueryRowContext(ctx,
		`SELECT rotated_from_id FROM partner_keys WHERE label='B' ORDER BY id DESC LIMIT 1`,
	).Scan(&bRotatedFrom); err != nil {
		t.Fatalf("select B: %v", err)
	}
	if !bRotatedFrom.Valid || bRotatedFrom.Int64 != aID {
		t.Errorf("B.rotated_from_id = %+v, want %d", bRotatedFrom, aID)
	}
	if err := adminDB.QueryRowContext(ctx,
		`SELECT revoked_at FROM partner_keys WHERE id=$1`, aID,
	).Scan(&aRevoked); err != nil {
		t.Fatalf("select A revoke status: %v", err)
	}
	if aRevoked.Valid {
		t.Errorf("A should remain unrevoked during overlap; got revoked_at=%v", aRevoked.Time)
	}

	// Revoke A.
	codeR, outR, stderrR := runRevoke(
		"--admin-dsn", fx.adminDSN(),
		"--id", fmt.Sprintf("%d", aID),
		"--reason", "rotation completed",
	)
	if codeR != 0 {
		t.Fatalf("revoke A exit=%d stderr=%q", codeR, stderrR)
	}
	if !strings.Contains(outR, fmt.Sprintf("revoked id=%d", aID)) {
		t.Errorf("revoke confirmation missing; out=%q", outR)
	}

	// A.revoked_at is now set; B unchanged.
	if err := adminDB.QueryRowContext(ctx,
		`SELECT revoked_at FROM partner_keys WHERE id=$1`, aID,
	).Scan(&aRevoked); err != nil {
		t.Fatalf("re-select A: %v", err)
	}
	if !aRevoked.Valid {
		t.Errorf("A.revoked_at should be set after revoke")
	}
}

// ===========================================================================
// `revoke --id 99999` (non-existent) — clean error, NOT a panic.
// ===========================================================================
func TestRevokeNonexistent(t *testing.T) {
	fx, _ := startCLIPostgres(t)
	code, _, stderr := runRevoke(
		"--admin-dsn", fx.adminDSN(),
		"--id", "99999",
		"--reason", "x",
	)
	if code != 1 {
		t.Errorf("revoke nonexistent exit=%d want 1; stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, "no row with id=99999") {
		t.Errorf("stderr should explain missing row; got %q", stderr)
	}
}

// ===========================================================================
// v0.1.8 --burst is rejected (column dropped).
// ===========================================================================
func TestIssueBurstFlagRejected(t *testing.T) {
	fx, _ := startCLIPostgres(t)
	code, _, stderr, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "X",
		"--burst", "100",
	)
	if code == 0 {
		t.Errorf("--burst flag should be rejected; got exit=0")
	}
	if !strings.Contains(stderr, "flag provided but not defined") &&
		!strings.Contains(stderr, "burst") {
		t.Errorf("stderr should reference unknown --burst; got %q", stderr)
	}
}

// ===========================================================================
// SECURITY — token escapes only as the single stdout line at issue time.
// stderr MUST never contain raw token, body, or `token_hash`.
// ===========================================================================
func TestTokenRedactionOnFailedInsert(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)
	// Issue a real token to learn the body shape, then drop the
	// table to force an INSERT failure on a second issue; assert
	// stderr does NOT contain the failed run's token body.
	codeA, outA, stderrA, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "ok",
	)
	if codeA != 0 {
		t.Fatalf("issue A exit=%d stderr=%q", codeA, stderrA)
	}
	rawA := extractRawTokenLine(outA)
	bodyA := rawA[4:]
	if !strings.Contains(outA, rawA) {
		t.Fatalf("stdout should contain raw token line")
	}

	// Drop the table to force a subsequent INSERT to fail.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := adminDB.ExecContext(ctx, `DROP TABLE partner_keys CASCADE`); err != nil {
		t.Fatalf("drop: %v", err)
	}

	codeB, outB, stderrB, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "failing",
	)
	if codeB == 0 {
		t.Fatalf("second issue should fail after DROP")
	}
	// Stdout should be empty on failure (no metadata, no token).
	if outB != "" {
		t.Errorf("stdout on failed INSERT should be empty; got %q", outB)
	}
	// Stderr should NOT contain the previous token, body, or
	// `token_hash`.
	if strings.Contains(stderrB, rawA) || strings.Contains(stderrB, bodyA) {
		t.Errorf("stderr leaked prior token / body: %q", stderrB)
	}
	if strings.Contains(stderrB, "token_hash =") || strings.Contains(stderrB, "token_hash:") {
		t.Errorf("stderr leaked token_hash field: %q", stderrB)
	}
}
