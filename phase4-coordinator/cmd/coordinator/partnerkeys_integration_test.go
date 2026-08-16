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
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq"
	"github.com/rs/zerolog"
	tc "github.com/testcontainers/testcontainers-go"
	tcpg "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	"github.com/augstar/macprovider-coordinator/internal/stats"
	statsmigrations "github.com/augstar/macprovider-coordinator/internal/stats/migrations"
	statsstore "github.com/augstar/macprovider-coordinator/internal/stats/store"
)

// seedRotationHandlerFixture seeds the minimum rollup state
// needed for the Step 3 leaderboard handler to return 200
// instead of 503 stale: a fresh stats_components_health row
// for `leaderboard_24h` and a single stats_leaderboard_24h
// row. The handler reads through the stats_reader role, which
// is granted SELECT on these tables by Step 1's grants
// migration.
func seedRotationHandlerFixture(t *testing.T, adminDB *sql.DB) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// Round-3 CODE M1: the locked schema (001_stats_tables.up.sql)
	// uses:
	//   stats_rewards_populated.window_label (NOT singleton)
	//   stats_leaderboard_24h.rank_earnings/rank_tokens/rank_jobs +
	//       pseudonym + earnings_bucket (NOT a single `rank`,
	//       NOT active_accounts).
	// The bootstrap migration (002_*) already seeds the four
	// stats_rewards_populated window_label rows + the seven
	// stats_components_health components — so we only need to
	// refresh generated_at + insert a leaderboard row.
	for _, q := range []string{
		`UPDATE stats_components_health
		    SET generated_at = now()
		  WHERE component IN ('leaderboard_24h','overview',
		                      'timeseries_rpm','timeseries_tpm',
		                      'leaderboard_7d','leaderboard_30d',
		                      'leaderboard_all')`,
		`UPDATE stats_rewards_populated
		    SET generated_at = now()
		  WHERE window_label IN ('24h','7d','30d','all')`,
		`INSERT INTO stats_leaderboard_24h (
			provider_id, pseudonym, generated_at,
			rank_earnings, rank_tokens, rank_jobs,
			earnings_usd, earnings_work_usd, earnings_rewards_usd,
			earnings_bucket, tokens, jobs,
			first_seen_at, last_seen_at)
		 VALUES ('p1', 'pseud-p1', now(),
			1, 1, 1,
			1.0, 0.5, 0.5,
			'$1-$10', 100, 5,
			now()-interval '1 day', now())
		 ON CONFLICT (provider_id) DO UPDATE SET generated_at = now()`,
	} {
		if _, err := adminDB.ExecContext(ctx, q); err != nil {
			t.Fatalf("seed rotation fixture: %v\nquery: %s", err, q)
		}
	}
	// Also seed a fresh stats_overview_current row so the
	// handler's overview pre-check (which doesn't run on
	// /leaderboard, but the test exercises a partner key —
	// future expansion may hit other endpoints) does not 503.
	if _, err := adminDB.ExecContext(ctx,
		`INSERT INTO stats_overview_current (
			singleton, generated_at,
			tokens_in, tokens_out, requests,
			nodes_online, nodes_hardware_attested,
			bandwidth_gb_per_s, network_power_kw,
			network_utilization_pct,
			gpu_cores_total, cpu_cores_total,
			unified_ram_gb_total, models_serving)
		 VALUES (TRUE, now(),
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
		 ON CONFLICT (singleton) DO UPDATE SET generated_at = now()`,
	); err != nil {
		t.Fatalf("seed overview: %v", err)
	}
	// Rotate the stats_reader role to a known password so the
	// handler can connect through it (same pattern as Step 3's
	// applyMigrationsAndStubOLTP — runtime roles are created
	// NOLOGIN in the migration; test harness rotates them in
	// memory).
	if _, err := adminDB.ExecContext(ctx,
		`ALTER ROLE stats_reader WITH LOGIN PASSWORD 'cli-rotation-test-pw'`,
	); err != nil {
		t.Fatalf("rotate stats_reader: %v", err)
	}
}

func newStatsHandlerForCLIRotation(t *testing.T, fx *cliPgFixture) http.Handler {
	t.Helper()
	readerDSN := fmt.Sprintf("postgres://stats_reader:cli-rotation-test-pw@%s:%s/%s?sslmode=disable",
		fx.host, fx.port, fx.dbName)
	readerDB, err := sql.Open("postgres", readerDSN)
	if err != nil {
		t.Fatalf("open stats_reader: %v", err)
	}
	t.Cleanup(func() { _ = readerDB.Close() })
	mux := stats.NewMux(
		statsstore.New(readerDB),
		stats.CORSConfig{
			AccessControlMaxAgeSeconds: 60,
			PartnerOriginAllowlist:     nil,
		},
		"full",
		"",
		nil,
		zerolog.Nop(),
	)
	return mux.Handler()
}

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
	// GitHub Actions Linux runners have JOURNAL_STREAM set in
	// the base env (the runner itself runs under systemd-journal),
	// which trips the round-1 SECURITY H1 token-suppression check
	// in `partner-keys issue` and breaks every test that doesn't
	// explicitly set --token-out. Clear it here; tests that
	// intentionally exercise the JOURNAL_STREAM-suppressed path
	// (TestIssueJournalStreamSuppresses, TestIssueTokenOutWritesFile,
	// TestStep4C_StatsPartnerKeyIssuedEvent's JOURNAL_STREAM
	// sub-case) re-set it via t.Setenv AFTER startCLIPostgres,
	// and the later t.Setenv takes precedence + restores cleanly.
	t.Setenv("JOURNAL_STREAM", "")
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

// extractRawTokenLine returns the raw token line printed on
// stdout. Final adversarial audit (ARCH r2 HIGH 1) rewrote
// AC-17's stdout contract: stdout is now exactly one raw-token
// line, no metadata. The metadata (`id=... label=... ...`) moved
// to stderr so secret-ingestion scripts that capture stdout
// receive a single 47-char token and nothing else. This helper
// asserts stdout matches `^mpk_[A-Za-z0-9_-]{43}\n?$` and
// returns the token; tests that need a relaxed reading (e.g.
// JOURNAL_STREAM-suppressed paths where stdout is empty by
// design) should not use this helper.
func extractRawTokenLine(stdout string) string {
	s := strings.TrimRight(stdout, "\n")
	lines := strings.Split(s, "\n")
	if len(lines) == 0 {
		return ""
	}
	return lines[len(lines)-1]
}

// assertStdoutIsTokenOnly enforces the ARCH r2 HIGH 1 fix:
// stdout from `partner-keys issue` (without --token-out) MUST
// be exactly one raw-token line. Tests use this in place of
// `extractRawTokenLine` when they want to assert the strict
// AC-17 contract rather than tolerating extra lines.
func assertStdoutIsTokenOnly(t *testing.T, stdout string) {
	t.Helper()
	s := strings.TrimRight(stdout, "\n")
	if !tokenRegex.MatchString(s) {
		t.Fatalf("stdout is not exactly one mpk_ token (AC-17 contract): %q", stdout)
	}
	if strings.Contains(s, "\n") {
		t.Fatalf("stdout contains multiple lines (AC-17 contract: exactly one token line): %q", stdout)
	}
	for _, banned := range []string{"id=", "label=", "prefix=", "created_by=", "rotated_from_id=", "created_at="} {
		if strings.Contains(stdout, banned) {
			t.Errorf("stdout contains metadata fragment %q (must be on stderr per AC-17 fix): %q", banned, stdout)
		}
	}
}

// ===========================================================================
// AC-17 (subprocess) — round-2 CODE M1 closure: drive the locked SPEC
// command through `exec.Command(coordinatorBinary, ...)` so argv parsing,
// env, and the dispatcher all execute in the production code path.
//
// In-process variants below (`TestAC17_IssueLockedSPECCommand`,
// `TestAC17_IssueExplicitCreatedBy`, etc.) retain unit-style coverage
// of the same surface; this subprocess test additionally proves that
// `main()` correctly routes the verb and the binary's CSPRNG / sha256 /
// base64url assembly works end-to-end.
// ===========================================================================
func TestAC17_IssueLockedSPECCommand_Subprocess(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)
	bin := locateCoordinatorBinary(t)
	cmd := exec.Command(bin, "partner-keys", "issue",
		"--admin-dsn", fx.adminDSN(),
		"--label", "X")
	// Explicitly UNSET JOURNAL_STREAM so the test mirrors an
	// interactive operator invocation, not a systemd-captured
	// one (the journal-stream branch is exercised separately
	// in `TestIssueJournalStreamSuppresses`).
	cmd.Env = append(os.Environ(), "JOURNAL_STREAM=")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("subprocess AC-17 exit=%v stderr=%q", err, stderr.String())
	}
	raw := extractRawTokenLine(stdout.String())
	if !tokenRegex.MatchString(raw) {
		t.Fatalf("subprocess token %q does not match %s; stdout=%q",
			raw, tokenRegexRawString, stdout.String())
	}
	// Verify DB row landed.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var label, prefix string
	if err := adminDB.QueryRowContext(ctx,
		`SELECT label, prefix FROM partner_keys ORDER BY id DESC LIMIT 1`,
	).Scan(&label, &prefix); err != nil {
		t.Fatalf("select: %v", err)
	}
	if label != "X" || prefix != raw[:8] {
		t.Errorf("row mismatch: label=%q prefix=%q (raw[:8]=%q)", label, prefix, raw[:8])
	}
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
	// Final adversarial audit (ARCH r2 HIGH 1) — stdout MUST be
	// exactly one raw token line, no metadata. Metadata appears
	// on stderr instead.
	assertStdoutIsTokenOnly(t, stdout)
	raw := extractRawTokenLine(stdout)
	if len(raw) != 47 {
		t.Fatalf("issued token %q length %d, want 47", raw, len(raw))
	}
	// stderr MUST carry the operator-facing metadata.
	for _, want := range []string{"id=", "label=X", "prefix=" + raw[:8], "created_by=", "created_at="} {
		if !strings.Contains(stderr, want) {
			t.Errorf("stderr missing metadata fragment %q: %q", want, stderr)
		}
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
// Final adversarial audit (ARCH r3 + CODE r3 CRITICAL closure) —
// config-driven §6.6.2 sign-off gate. The deployed coordinator config is the
// source of truth for "is this coordinator production"; the operator's act
// of placing the signoff file at the configured path IS the gate. A
// wrapper-script that forgets a flag cannot bypass because production-vs-
// staging is decided by the deploy-time config, not the CLI invocation.
// ===========================================================================
func TestProductionSignoffPathGate(t *testing.T) {
	fx, _ := startCLIPostgres(t)
	tmp := t.TempDir()

	writeConfig := func(name, signoffPath string) string {
		p := tmp + "/" + name
		body := "stats:\n  partner_keys_admin_dsn: \"" + fx.adminDSN() + "\"\n"
		if signoffPath != "" {
			body += "  partner_keys:\n    production_signoff_path: \"" + signoffPath + "\"\n"
		}
		if err := os.WriteFile(p, []byte(body), 0600); err != nil {
			t.Fatalf("write config %s: %v", name, err)
		}
		return p
	}
	writeSignoff := func(name, body string) string {
		p := tmp + "/" + name
		if err := os.WriteFile(p, []byte(body), 0600); err != nil {
			t.Fatalf("write signoff %s: %v", name, err)
		}
		return p
	}

	t.Run("no signoff_path in config = staging (no gate)", func(t *testing.T) {
		cfg := writeConfig("staging.yaml", "")
		code, _, stderr, _, _ := runIssue(
			"--config", cfg,
			"--label", "staging-key",
		)
		if code != 0 {
			t.Fatalf("staging issue (no signoff_path) should succeed; got exit=%d stderr=%q", code, stderr)
		}
	})

	t.Run("signoff_path configured + file missing → fail-closed", func(t *testing.T) {
		cfg := writeConfig("prod-missing.yaml", tmp+"/nonexistent-signoff.txt")
		code, _, stderr, _, _ := runIssue(
			"--config", cfg,
			"--label", "prod-missing-file",
		)
		if code == 0 {
			t.Fatalf("missing signoff file MUST fail closed")
		}
		if !strings.Contains(stderr, "OPS.md") {
			t.Errorf("error should point at the runbook; got %q", stderr)
		}
	})

	t.Run("signoff_path configured + file empty → fail-closed", func(t *testing.T) {
		sig := writeSignoff("empty-signoff.txt", "")
		cfg := writeConfig("prod-empty.yaml", sig)
		code, _, stderr, _, _ := runIssue(
			"--config", cfg,
			"--label", "prod-empty-file",
		)
		if code == 0 {
			t.Fatalf("empty signoff file MUST fail closed")
		}
		if !strings.Contains(stderr, "empty") {
			t.Errorf("error should mention empty; got %q", stderr)
		}
	})

	t.Run("signoff_path configured + malformed → fail-closed (missing SHA)", func(t *testing.T) {
		sig := writeSignoff("no-sha.txt", "I acknowledge the §6.6.2 disclosure on 2026-09-01.")
		cfg := writeConfig("prod-no-sha.yaml", sig)
		code, _, stderr, _, _ := runIssue(
			"--config", cfg,
			"--label", "prod-no-sha",
		)
		if code == 0 {
			t.Fatalf("signoff without SPEC-014 SHA MUST fail")
		}
		if !strings.Contains(stderr, "SPEC-014") {
			t.Errorf("error should explain missing SHA; got %q", stderr)
		}
	})

	t.Run("signoff_path configured + malformed → fail-closed (missing date)", func(t *testing.T) {
		sig := writeSignoff("no-date.txt", "SPEC-014 sha=abc1234 acknowledged by ops@example.com")
		cfg := writeConfig("prod-no-date.yaml", sig)
		code, _, stderr, _, _ := runIssue(
			"--config", cfg,
			"--label", "prod-no-date",
		)
		if code == 0 {
			t.Fatalf("signoff without YYYY-MM-DD date MUST fail")
		}
		if !strings.Contains(stderr, "YYYY-MM-DD") {
			t.Errorf("error should explain missing date; got %q", stderr)
		}
	})

	t.Run("signoff_path configured + valid signoff → success + event carries content", func(t *testing.T) {
		sig := writeSignoff("good-signoff.txt",
			"SPEC-017 v0.1.8 §6.6.2 disclosure sign-off\n"+
				"SPEC-014 sha=abc1234de5f6789 disclosure-live=2026-09-01\n"+
				"acknowledged by ops@example.com")
		cfg := writeConfig("prod-good.yaml", sig)
		code, stdout, stderr, _, _ := runIssue(
			"--config", cfg,
			"--label", "prod-good-signoff",
		)
		if code != 0 {
			t.Fatalf("valid signoff should succeed; got exit=%d stderr=%q", code, stderr)
		}
		assertStdoutIsTokenOnly(t, stdout)
		if !strings.Contains(stderr, `"event":"stats_partner_key_issued"`) {
			t.Errorf("event missing: %q", stderr)
		}
		if !strings.Contains(stderr, `"production":true`) {
			t.Errorf("event missing production:true: %q", stderr)
		}
		if !strings.Contains(stderr, `"signoff_spec_6_6_2"`) {
			t.Errorf("event missing signoff_spec_6_6_2 field: %q", stderr)
		}
		if !strings.Contains(stderr, `"production_signoff_path"`) {
			t.Errorf("event missing production_signoff_path field: %q", stderr)
		}
		if !strings.Contains(stderr, "SPEC-014 sha=abc1234de5f6789") {
			t.Errorf("event missing the validated signoff content: %q", stderr)
		}
	})

	t.Run("admin-dsn override does NOT bypass the config gate", func(t *testing.T) {
		// A wrapper script that passes --admin-dsn directly must
		// still respect the --config signoff gate. The opt-in
		// flag bypass that r2 used is closed: the config is the
		// authority on production-vs-staging.
		cfg := writeConfig("prod-with-admin-override.yaml",
			tmp+"/nonexistent-signoff-bypass.txt")
		code, _, stderr, _, _ := runIssue(
			"--admin-dsn", fx.adminDSN(),
			"--config", cfg,
			"--label", "bypass-attempt",
		)
		if code == 0 {
			t.Fatalf("--admin-dsn override MUST NOT bypass the config-driven signoff gate; got exit=0 stderr=%q", stderr)
		}
		if !strings.Contains(stderr, "production_signoff_path") {
			t.Errorf("error should name the config field; got %q", stderr)
		}
	})
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
// SECURITY r1 H1 — JOURNAL_STREAM (systemd-journal stdout capture) suppresses
// the raw-token stdout print. With JOURNAL_STREAM set and no --token-out the
// CLI MUST refuse, exit non-zero, and tell the operator to revoke the orphan
// row.
// ===========================================================================
func TestIssueJournalStreamSuppresses(t *testing.T) {
	fx, _ := startCLIPostgres(t)
	t.Setenv("JOURNAL_STREAM", "1:2")
	code, stdout, stderr, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "journaltest",
	)
	if code == 0 {
		t.Fatalf("JOURNAL_STREAM should suppress stdout token; got exit 0 stdout=%q", stdout)
	}
	// Round-2 CODE M2: assert on the FULL 47-char raw token,
	// NOT the 8-char `mpk_xxxx` prefix. The metadata line
	// legitimately carries `prefix=mpk_xxxx` per SPEC §5.4.6
	// (prefix is operator-permitted; the random 43-char body
	// is the secret).
	if tokenRegex.FindString(stdout) != "" {
		t.Errorf("raw 47-char token leaked to stdout under JOURNAL_STREAM: %q", stdout)
	}
	if !strings.Contains(stderr, "JOURNAL_STREAM") {
		t.Errorf("stderr should explain journal-stream refusal; got %q", stderr)
	}
	if !strings.Contains(stderr, "--token-out") {
		t.Errorf("stderr should suggest --token-out remediation; got %q", stderr)
	}
}

// ===========================================================================
// SECURITY r1 H1 — --token-out FILE writes 0600 file + suppresses stdout.
// ===========================================================================
func TestIssueTokenOutWritesFile(t *testing.T) {
	fx, _ := startCLIPostgres(t)
	tmpDir := t.TempDir()
	tokenPath := tmpDir + "/secret.token"
	t.Setenv("JOURNAL_STREAM", "1:2")
	code, stdout, stderr, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "fileout",
		"--token-out", tokenPath,
	)
	if code != 0 {
		t.Fatalf("--token-out should succeed; got exit=%d stderr=%q", code, stderr)
	}
	// Round-2 CODE M2: same prefix-vs-full-token distinction.
	if tokenRegex.FindString(stdout) != "" {
		t.Errorf("raw 47-char token leaked to stdout despite --token-out: %q", stdout)
	}
	// Final adversarial audit (ARCH r2 HIGH 1) — with
	// --token-out, stdout is empty (the operator-facing
	// "token written to ..." diagnostic moved to stderr per
	// the AC-17 stdout-is-token-only contract).
	if strings.TrimSpace(stdout) != "" {
		t.Errorf("stdout MUST be empty when --token-out is used (AC-17 fix); got %q", stdout)
	}
	if !strings.Contains(stderr, "token written to "+tokenPath) {
		t.Errorf("stderr should carry the operator-facing token-out diagnostic; got %q", stderr)
	}
	info, err := os.Stat(tokenPath)
	if err != nil {
		t.Fatalf("stat token file: %v", err)
	}
	if info.Mode().Perm() != 0600 {
		t.Errorf("token file mode = %v, want 0600", info.Mode().Perm())
	}
	contents, err := os.ReadFile(tokenPath)
	if err != nil {
		t.Fatalf("read token file: %v", err)
	}
	tok := strings.TrimSpace(string(contents))
	if !tokenRegex.MatchString(tok) {
		t.Errorf("token-out file content %q does not match %s", tok, tokenRegexRawString)
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
	// `token_hash`. Round-2 CODE M2 strengthening: also assert
	// stderr does NOT contain ANY 43-char base64url body (the
	// failing run's generated body is unknowable to the test —
	// the structural assertion is "no 43-char body of any
	// shape leaks into stderr").
	if strings.Contains(stderrB, rawA) || strings.Contains(stderrB, bodyA) {
		t.Errorf("stderr leaked prior token / body: %q", stderrB)
	}
	if strings.Contains(stderrB, "token_hash =") || strings.Contains(stderrB, "token_hash:") {
		t.Errorf("stderr leaked token_hash field: %q", stderrB)
	}
	if anyBodyRegex.FindString(stderrB) != "" {
		t.Errorf("stderr contains a 43-char base64url body substring (potential token leak): %q", stderrB)
	}
}

// anyBodyRegex matches the 43-char base64url body shape of any
// `mpk_<body>` token. Used to scan stderr / error paths for
// "any token body" leaks — even one we didn't generate
// ourselves (because, by design, we cannot know what the
// failing run's CSPRNG produced).
var anyBodyRegex = regexp.MustCompile(`[A-Za-z0-9_-]{43}`)

// ===========================================================================
// AC-17 subprocess — explicit --created-by variant (CODE r2 M1).
// ===========================================================================
func TestAC17_IssueExplicitCreatedBy_Subprocess(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)
	bin := locateCoordinatorBinary(t)
	cmd := exec.Command(bin, "partner-keys", "issue",
		"--admin-dsn", fx.adminDSN(),
		"--label", "X",
		"--created-by", "ops@example.com")
	cmd.Env = append(os.Environ(), "JOURNAL_STREAM=")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("subprocess --created-by exit=%v stderr=%q", err, stderr.String())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var createdBy string
	if err := adminDB.QueryRowContext(ctx,
		`SELECT created_by FROM partner_keys ORDER BY id DESC LIMIT 1`,
	).Scan(&createdBy); err != nil {
		t.Fatalf("select: %v", err)
	}
	if createdBy != "ops@example.com" {
		t.Errorf("created_by = %q, want ops@example.com", createdBy)
	}
}

// ===========================================================================
// RFC 6454 idempotency subprocess (CODE r2 M1) — the canonical-passes /
// non-canonical-rejects cases through the compiled binary.
// ===========================================================================
func TestIssueAllowedOriginRFC6454_Subprocess(t *testing.T) {
	fx, _ := startCLIPostgres(t)
	bin := locateCoordinatorBinary(t)
	for _, c := range []struct {
		name     string
		origin   string
		wantPass bool
	}{
		{"canonical", "https://acme.example", true},
		{"mixed-case-trailing-slash", "HTTPS://Acme.Example/", false},
		{"default-port-443", "https://acme.example:443", false},
	} {
		c := c
		t.Run(c.name, func(t *testing.T) {
			cmd := exec.Command(bin, "partner-keys", "issue",
				"--admin-dsn", fx.adminDSN(),
				"--label", c.name,
				"--allowed-origin", c.origin)
			cmd.Env = append(os.Environ(), "JOURNAL_STREAM=")
			var stderr bytes.Buffer
			cmd.Stderr = &stderr
			err := cmd.Run()
			passed := err == nil
			if passed != c.wantPass {
				t.Errorf("origin %q passed=%v want %v stderr=%q",
					c.origin, passed, c.wantPass, stderr.String())
			}
		})
	}
}

// ===========================================================================
// --burst subprocess (CODE r2 M1) — v0.1.8 removed; flag must reject.
// ===========================================================================
func TestIssueBurstFlagRejected_Subprocess(t *testing.T) {
	fx, _ := startCLIPostgres(t)
	bin := locateCoordinatorBinary(t)
	cmd := exec.Command(bin, "partner-keys", "issue",
		"--admin-dsn", fx.adminDSN(),
		"--label", "X",
		"--burst", "100")
	cmd.Env = append(os.Environ(), "JOURNAL_STREAM=")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err == nil {
		t.Fatalf("--burst should be rejected; got exit 0 stderr=%q", stderr.String())
	}
	if !strings.Contains(stderr.String(), "burst") {
		t.Errorf("stderr should reference --burst; got %q", stderr.String())
	}
}

// ===========================================================================
// Revoke nonexistent subprocess (CODE r2 M1) — clean exit 1 + no panic.
// ===========================================================================
func TestRevokeNonexistent_Subprocess(t *testing.T) {
	fx, _ := startCLIPostgres(t)
	bin := locateCoordinatorBinary(t)
	cmd := exec.Command(bin, "partner-keys", "revoke",
		"--admin-dsn", fx.adminDSN(),
		"--id", "99999",
		"--reason", "test")
	cmd.Env = append(os.Environ(), "JOURNAL_STREAM=")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 1 {
		t.Fatalf("revoke nonexistent should exit 1; got %v stderr=%q", err, stderr.String())
	}
	if !strings.Contains(stderr.String(), "no row with id=99999") {
		t.Errorf("stderr should explain missing row; got %q", stderr.String())
	}
}

// ===========================================================================
// Rotation through Step 3 handler (CODE r2 M1) — issue A + B (--rotate-from
// A) via subprocess, hit the Step 3 leaderboard handler with both keys,
// assert both return 200 partner projection BEFORE revoking A. Then revoke
// A via subprocess, assert A → 401 and B → 200.
// ===========================================================================
func TestRotationThroughHandler_Subprocess(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)
	bin := locateCoordinatorBinary(t)

	issueViaCLI := func(label string, rotateFrom string) string {
		args := []string{"partner-keys", "issue",
			"--admin-dsn", fx.adminDSN(),
			"--label", label}
		if rotateFrom != "" {
			args = append(args, "--rotate-from", rotateFrom)
		}
		cmd := exec.Command(bin, args...)
		cmd.Env = append(os.Environ(), "JOURNAL_STREAM=")
		var stdout, stderr bytes.Buffer
		cmd.Stdout, cmd.Stderr = &stdout, &stderr
		if err := cmd.Run(); err != nil {
			t.Fatalf("issue %s: %v stderr=%q", label, err, stderr.String())
		}
		raw := extractRawTokenLine(stdout.String())
		if !tokenRegex.MatchString(raw) {
			t.Fatalf("issue %s: token %q does not match", label, raw)
		}
		return raw
	}

	rawA := issueViaCLI("A", "")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var aID int64
	if err := adminDB.QueryRowContext(ctx,
		`SELECT id FROM partner_keys WHERE label='A' ORDER BY id DESC LIMIT 1`,
	).Scan(&aID); err != nil {
		t.Fatalf("find A id: %v", err)
	}
	rawB := issueViaCLI("B", fmt.Sprintf("%d", aID))

	// Stand up the Step 3 handler against this DB. We seed the
	// leaderboard rollup just enough for the partner projection
	// to render (a single row in stats_leaderboard_24h + a fresh
	// stats_components_health entry) so the handler returns 200
	// instead of 503 stale.
	seedRotationHandlerFixture(t, adminDB)
	mux := newStatsHandlerForCLIRotation(t, fx)

	probe := func(token string) int {
		req := httptest.NewRequest(http.MethodGet,
			"http://stats.malibu.tech/v1/stats/leaderboard?window=24h", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec.Code
	}

	if got := probe(rawA); got != http.StatusOK {
		t.Fatalf("A pre-revoke: got %d, want 200", got)
	}
	if got := probe(rawB); got != http.StatusOK {
		t.Fatalf("B pre-revoke: got %d, want 200", got)
	}

	// Revoke A.
	cmd := exec.Command(bin, "partner-keys", "revoke",
		"--admin-dsn", fx.adminDSN(),
		"--id", fmt.Sprintf("%d", aID),
		"--reason", "rotation completed")
	cmd.Env = append(os.Environ(), "JOURNAL_STREAM=")
	var rstderr bytes.Buffer
	cmd.Stderr = &rstderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("revoke A: %v stderr=%q", err, rstderr.String())
	}

	if got := probe(rawA); got != http.StatusUnauthorized {
		t.Errorf("A post-revoke: got %d, want 401", got)
	}
	if got := probe(rawB); got != http.StatusOK {
		t.Errorf("B post-revoke: got %d, want 200", got)
	}
}

// ===========================================================================
// Step 4.C round-3 CODE r3 MEDIUM 3 — direct landing assertion that the
// `stats_partner_key_issued` event lands on stderr ONLY when the raw token
// has been successfully delivered to the operator (round-3 CODE M1 closes
// the success-boundary gap). Asserts:
//   - bare-stdout success path emits the event with the locked field set
//   - `--token-out` success path emits the event after writeFile succeeds
//   - JOURNAL_STREAM-suppressed exit-1 path does NOT emit the event
//   - the event NEVER carries `prefix`, `created_at`, `token_hash`,
//     the raw token, or any 43-char base64url body
//
// ===========================================================================
func TestStep4C_StatsPartnerKeyIssuedEvent(t *testing.T) {
	fx, _ := startCLIPostgres(t)

	// Bare-stdout success path — event MUST emit after the raw
	// token reaches stdout.
	code, _, stderr, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "step4c-evt",
	)
	if code != 0 {
		t.Fatalf("issue exit=%d stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, `"event":"stats_partner_key_issued"`) {
		t.Fatalf("missing stats_partner_key_issued event in stderr: %q", stderr)
	}
	if !strings.Contains(stderr, `"label":"step4c-evt"`) {
		t.Errorf("event missing label field: %q", stderr)
	}
	if !strings.Contains(stderr, `"created_by"`) {
		t.Errorf("event missing created_by field: %q", stderr)
	}
	// Locked field set forbids `prefix`, `created_at`, token_hash, raw token.
	for _, banned := range []string{`"prefix"`, `"created_at"`, "token_hash", "mpk_step4c"} {
		if strings.Contains(stderr, banned) {
			t.Errorf("event leaks forbidden substring %q: %q", banned, stderr)
		}
	}
	// No 43-char base64url body anywhere in stderr.
	if regexp.MustCompile(`[A-Za-z0-9_-]{43}`).MatchString(stderr) {
		t.Errorf("event leaks 43-char token body in stderr: %q", stderr)
	}

	// --token-out success path — event MUST emit after writeFile.
	tmpDir := t.TempDir()
	tokenPath := tmpDir + "/secret.token"
	t.Setenv("JOURNAL_STREAM", "1:2")
	code, _, stderr, _, _ = runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "step4c-tokenout",
		"--token-out", tokenPath,
	)
	if code != 0 {
		t.Fatalf("--token-out exit=%d stderr=%q", code, stderr)
	}
	if !strings.Contains(stderr, `"event":"stats_partner_key_issued"`) {
		t.Errorf("--token-out success path missing stats_partner_key_issued event: %q", stderr)
	}
	if !strings.Contains(stderr, `"label":"step4c-tokenout"`) {
		t.Errorf("--token-out path event missing label: %q", stderr)
	}

	// JOURNAL_STREAM suppression (no --token-out) — exit 1, NO event.
	code, _, stderr, _, _ = runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "step4c-suppressed",
	)
	if code == 0 {
		t.Fatalf("JOURNAL_STREAM should suppress; got exit=0 stderr=%q", stderr)
	}
	if strings.Contains(stderr, `"event":"stats_partner_key_issued"`) {
		t.Errorf("JOURNAL_STREAM-suppressed path MUST NOT emit stats_partner_key_issued; got stderr=%q", stderr)
	}
}

// ===========================================================================
// Step 4.C round-3 CODE r3 MEDIUM 3 — direct landing assertion that the
// `stats_partner_key_revoked` event lands on stderr after a successful
// revoke, with locked field set {id, reason, actor}.
// ===========================================================================
func TestStep4C_StatsPartnerKeyRevokedEvent(t *testing.T) {
	fx, adminDB := startCLIPostgres(t)

	code, _, stderr, _, _ := runIssue(
		"--admin-dsn", fx.adminDSN(),
		"--label", "revoke-evt-src",
	)
	if code != 0 {
		t.Fatalf("issue exit=%d stderr=%q", code, stderr)
	}
	var id int64
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := adminDB.QueryRowContext(ctx,
		`SELECT id FROM partner_keys WHERE label='revoke-evt-src' ORDER BY id DESC LIMIT 1`,
	).Scan(&id); err != nil {
		t.Fatalf("find issued id: %v", err)
	}

	code, _, rstderr := runRevoke(
		"--admin-dsn", fx.adminDSN(),
		"--id", fmt.Sprintf("%d", id),
		"--reason", "step4c-test-reason",
	)
	if code != 0 {
		t.Fatalf("revoke exit=%d stderr=%q", code, rstderr)
	}
	if !strings.Contains(rstderr, `"event":"stats_partner_key_revoked"`) {
		t.Fatalf("missing stats_partner_key_revoked event in stderr: %q", rstderr)
	}
	if !strings.Contains(rstderr, fmt.Sprintf(`"id":%d`, id)) {
		t.Errorf("event missing id field: %q", rstderr)
	}
	if !strings.Contains(rstderr, `"reason":"step4c-test-reason"`) {
		t.Errorf("event missing reason field: %q", rstderr)
	}
	if !strings.Contains(rstderr, `"actor"`) {
		t.Errorf("event missing actor field: %q", rstderr)
	}
	for _, banned := range []string{"token_hash", "mpk_"} {
		if strings.Contains(rstderr, banned) {
			t.Errorf("revoke event leaks forbidden substring %q: %q", banned, rstderr)
		}
	}
}
