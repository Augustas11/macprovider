//go:build integration

package rewards_test

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"

	_ "github.com/lib/pq"
	tc "github.com/testcontainers/testcontainers-go"
	tcpg "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	"github.com/augstar/macprovider-coordinator/internal/rewards"
	statsmigrations "github.com/augstar/macprovider-coordinator/internal/stats/migrations"
	"github.com/rs/zerolog"
)

const (
	pgImage             = "postgres:16.4-alpine3.20@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c"
	roleRuntimePassword = "rewards-test-runtime-pw"
	roleAdminPassword   = "rewards-test-admin-pw"
)

type pgFixture struct {
	container tc.Container
	host      string
	port      string
	dbName    string
}

type testConnectivity struct {
	ok bool
}

func (c *testConnectivity) HeartbeatOK(string, time.Time) bool {
	return c.ok
}

func (f *pgFixture) adminDSN() string {
	return fmt.Sprintf("postgres://postgres:%s@%s:%s/%s?sslmode=disable", roleAdminPassword, f.host, f.port, f.dbName)
}

func (f *pgFixture) roleDSN(role string) string {
	return fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable", role, roleRuntimePassword, f.host, f.port, f.dbName)
}

func startPostgres(t *testing.T) (*pgFixture, *sql.DB) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	c, err := tcpg.Run(ctx, pgImage,
		tcpg.WithDatabase("rewards_test"),
		tcpg.WithUsername("postgres"),
		tcpg.WithPassword(roleAdminPassword),
		tc.WithWaitStrategy(wait.ForLog("database system is ready to accept connections").WithOccurrence(2)),
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
		t.Fatalf("port: %v", err)
	}
	fx := &pgFixture{container: c, host: host, port: port.Port(), dbName: "rewards_test"}
	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	t.Cleanup(func() {
		_ = adminDB.Close()
		_ = c.Terminate(context.Background())
	})
	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("apply migrations: %v", err)
	}
	if _, err := adminDB.ExecContext(ctx, fmt.Sprintf(
		`ALTER ROLE rewards_writer WITH LOGIN PASSWORD '%s'`, roleRuntimePassword,
	)); err != nil {
		t.Fatalf("rotate rewards_writer: %v", err)
	}
	return fx, adminDB
}

func openRewardsWriter(t *testing.T, fx *pgFixture) *sql.DB {
	t.Helper()
	db, err := sql.Open("postgres", fx.roleDSN("rewards_writer"))
	if err != nil {
		t.Fatalf("open rewards_writer: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// testEmissionConfig builds a valid rewards.Config for tests that call
// rewards.New directly with an already-open *sql.DB. WriterDSN and
// SQLitePayoutDBPath are required by Config.Validate() but unused by
// RunEmissionTickOnce, which operates on the db passed to rewards.New.
func testEmissionConfig(tickInterval time.Duration, providerCap, walletCap float64) rewards.Config {
	return rewards.Config{
		Enabled:                true,
		WriterDSN:              "unused-in-test",
		SQLitePayoutDBPath:     "/dev/null",
		TickInterval:           tickInterval,
		ProviderDailyCapMALIBU: providerCap,
		WalletDailyCapMALIBU:   walletCap,
		MaxSerializableRetries: 5,
	}
}

func testSQLitePayoutDBPath(t *testing.T) string {
	t.Helper()
	path := t.TempDir() + "/payout.db"
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open sqlite payout db: %v", err)
	}
	defer func() { _ = db.Close() }()
	if _, err := db.Exec("PRAGMA user_version = 1"); err != nil {
		t.Fatalf("initialize sqlite payout db: %v", err)
	}
	return path
}

func TestProvisionalAccrualSetsWithdrawalHold(t *testing.T) {
	fx, adminDB := startPostgres(t)
	writerDB := openRewardsWriter(t, fx)
	ctx := context.Background()

	if _, err := writerDB.ExecContext(ctx, `
        INSERT INTO provider_emission_state (provider_id, trust_tier)
        VALUES ('p_test', 'provisional')
    `); err != nil {
		t.Fatalf("seed state: %v", err)
	}

	cfg := testEmissionConfig(time.Hour, 25, 100)
	runner, err := rewards.New(writerDB, cfg, zerolog.Nop(), rewards.RunnerDeps{})
	if err != nil {
		t.Fatalf("new runner: %v", err)
	}
	if err := runner.RunEmissionTickOnce(ctx); err != nil {
		t.Fatalf("emission tick: %v", err)
	}

	var hold string
	var amt string
	if err := adminDB.QueryRowContext(ctx, `
        SELECT withdrawal_hold_reason, amount_malibu::TEXT
          FROM provider_rewards_ledger
         WHERE provider_id = 'p_test'
         ORDER BY id DESC LIMIT 1
    `).Scan(&hold, &amt); err != nil {
		t.Fatalf("query ledger: %v", err)
	}
	if hold != rewards.HoldTrustTierProvisional {
		t.Fatalf("hold=%q want %q", hold, rewards.HoldTrustTierProvisional)
	}
	if amt == "" || amt == "0.00000000" {
		t.Fatalf("expected positive accrual, got %q", amt)
	}

	rows, err := rewards.SelectWithdrawableMALIBU(ctx, writerDB, "p_test", 10)
	if err != nil {
		t.Fatalf("withdrawable select: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("provisional rows must not be withdrawable, got %d", len(rows))
	}
}

func TestZeroWalletCapMarkerDoesNotBecomePermanentHold(t *testing.T) {
	fx, adminDB := startPostgres(t)
	writerDB := openRewardsWriter(t, fx)
	ctx := context.Background()

	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO provider_emission_state (provider_id, trust_tier, bound_wallet)
        VALUES ('p_zero_marker', 'trusted', '0xzero');

        INSERT INTO provider_rewards_ledger
            (provider_id, unix_ts, amount_malibu, withdrawal_hold_reason, reason, external_ref)
        VALUES
            ('p_zero_marker', extract(epoch from now() - interval '1 day')::BIGINT,
             0, $1, $2, 'spec022:req-zero:0:p_zero_marker');
    `, rewards.HoldPerWalletDailyCap, rewards.ReasonMalibuVerifiedUsefulWorkV02); err != nil {
		t.Fatalf("seed zero marker: %v", err)
	}

	bal, err := rewards.QueryAccrualBalance(ctx, writerDB, "p_zero_marker", testEmissionConfig(time.Hour, 25, 100))
	if err != nil {
		t.Fatalf("query accrual balance: %v", err)
	}
	if testContainsString(bal.HoldReasons, rewards.HoldPerWalletDailyCap) {
		t.Fatalf("hold reasons = %v, zero historical marker must not act as current cap", bal.HoldReasons)
	}
	eligibility := rewards.RewardEligibilityFromBalanceAndTrust(bal, rewards.TrustCriteriaStatus{
		WalletBound:          true,
		VerifiedReceiptCount: 999,
		AppAttested:          true,
	})
	if eligibility.PrimaryReason == rewards.ReasonHeldWalletDailyCap {
		t.Fatalf("primary_reason = %q, zero historical marker must not act as current cap", eligibility.PrimaryReason)
	}
}

func TestRewardAuditEventsAreProviderScopedPaginatedAndRedacted(t *testing.T) {
	fx, _ := startPostgres(t)
	writerDB := openRewardsWriter(t, fx)
	ctx := context.Background()

	for _, pid := range []string{"p_audit_a", "p_audit_b"} {
		if _, err := writerDB.ExecContext(ctx, `
            INSERT INTO provider_emission_state (provider_id, trust_tier)
            VALUES ($1, 'provisional')
        `, pid); err != nil {
			t.Fatalf("seed state %s: %v", pid, err)
		}
	}

	cfg := testEmissionConfig(time.Hour, 25, 100)
	runner, err := rewards.New(writerDB, cfg, zerolog.Nop(), rewards.RunnerDeps{})
	if err != nil {
		t.Fatalf("new runner: %v", err)
	}
	if err := runner.RunEmissionTickOnce(ctx); err != nil {
		t.Fatalf("emission tick: %v", err)
	}

	page, err := rewards.QueryRewardAuditEvents(ctx, writerDB, rewards.RewardAuditQuery{
		ProviderID: "p_audit_a",
		Limit:      1,
	})
	if err != nil {
		t.Fatalf("query provider audit: %v", err)
	}
	if len(page.Events) != 1 {
		t.Fatalf("events=%d want 1", len(page.Events))
	}
	firstID := page.Events[0].EventID
	if page.Events[0].ProviderID != "" {
		t.Fatalf("provider response leaked provider_id %q", page.Events[0].ProviderID)
	}
	if page.Events[0].OperatorCorrelation != nil {
		t.Fatalf("provider response leaked operator correlation: %#v", page.Events[0].OperatorCorrelation)
	}
	if page.Events[0].EventID == "" || page.NextBeforeID == "" {
		t.Fatalf("missing event id or next cursor: event=%q next=%q", page.Events[0].EventID, page.NextBeforeID)
	}

	beforeID, err := rewards.ParseAuditBeforeID(page.NextBeforeID)
	if err != nil {
		t.Fatalf("parse next cursor: %v", err)
	}
	nextPage, err := rewards.QueryRewardAuditEvents(ctx, writerDB, rewards.RewardAuditQuery{
		ProviderID: "p_audit_a",
		Limit:      10,
		BeforeID:   beforeID,
	})
	if err != nil {
		t.Fatalf("query next provider audit: %v", err)
	}
	if len(nextPage.Events) == 0 {
		t.Fatal("expected older audit event on next page")
	}
	if nextPage.Events[0].EventID == firstID {
		t.Fatalf("pagination repeated first event %q", firstID)
	}

	operatorPage, err := rewards.QueryRewardAuditEvents(ctx, writerDB, rewards.RewardAuditQuery{
		ProviderID:      "p_audit_a",
		Limit:           10,
		IncludeProvider: true,
		IncludeOperator: true,
	})
	if err != nil {
		t.Fatalf("query operator audit: %v", err)
	}
	for _, evt := range operatorPage.Events {
		if evt.ProviderID != "p_audit_a" {
			t.Fatalf("operator event provider_id=%q want p_audit_a", evt.ProviderID)
		}
		if evt.OperatorCorrelation == nil || evt.OperatorCorrelation["ledger_id"] == "" {
			t.Fatalf("operator event missing ledger correlation: %#v", evt.OperatorCorrelation)
		}
	}
}

func TestTrustTierTransitionsWriteRewardAuditEvents(t *testing.T) {
	fx, _ := startPostgres(t)
	writerDB := openRewardsWriter(t, fx)
	ctx := context.Background()

	providerID := "p_trust_audit"
	windowOpen := time.Now().UTC().Add(-73 * time.Hour)
	if _, err := writerDB.ExecContext(ctx, `
        INSERT INTO provider_emission_state (provider_id, trust_tier)
        VALUES ($1, 'provisional')
    `, providerID); err != nil {
		t.Fatalf("seed trust state: %v", err)
	}
	if _, err := writerDB.ExecContext(ctx, `
        INSERT INTO provider_trust_eval_state
            (provider_id, uptime_ok_since, unlock_pair_ok_since, last_eval_at, updated_at)
        VALUES ($1, $2, $2, now(), now())
    `, providerID, windowOpen); err != nil {
		t.Fatalf("seed trust eval state: %v", err)
	}
	if _, err := writerDB.ExecContext(ctx, `
        INSERT INTO provider_trust_operator_promotions
            (provider_id, promoted_by, reason, pending_id)
        VALUES ($1, 'integration-test', 'trust audit transition coverage', '00000000-0000-0000-0000-000000001021')
    `, providerID); err != nil {
		t.Fatalf("seed operator promotion: %v", err)
	}

	cfg := testEmissionConfig(time.Hour, 25, 100)
	cfg.SQLitePayoutDBPath = testSQLitePayoutDBPath(t)
	connectivity := &testConnectivity{ok: true}
	runner, err := rewards.New(writerDB, cfg, zerolog.Nop(), rewards.RunnerDeps{
		Connectivity: connectivity,
	})
	if err != nil {
		t.Fatalf("new runner: %v", err)
	}

	if err := runner.RunUnlockEvalOnce(ctx); err != nil {
		t.Fatalf("promote provider: %v", err)
	}

	connectivity.ok = false
	if err := runner.RunUnlockEvalOnce(ctx); err != nil {
		t.Fatalf("demote provider: %v", err)
	}

	if _, err := writerDB.ExecContext(ctx, `
        UPDATE provider_emission_state
           SET demotion_cooldown_until = now() - interval '1 hour'
         WHERE provider_id = $1
    `, providerID); err != nil {
		t.Fatalf("seed requalification cooldown: %v", err)
	}
	if _, err := writerDB.ExecContext(ctx, `
        UPDATE provider_trust_eval_state
           SET uptime_ok_since = $2,
               unlock_pair_ok_since = $2,
               updated_at = now()
         WHERE provider_id = $1
    `, providerID, windowOpen); err != nil {
		t.Fatalf("seed requalification window: %v", err)
	}
	connectivity.ok = true
	if err := runner.RunUnlockEvalOnce(ctx); err != nil {
		t.Fatalf("requalify provider: %v", err)
	}

	page, err := rewards.QueryRewardAuditEvents(ctx, writerDB, rewards.RewardAuditQuery{
		ProviderID:      providerID,
		Limit:           10,
		IncludeProvider: true,
		IncludeOperator: true,
	})
	if err != nil {
		t.Fatalf("query trust audit events: %v", err)
	}
	got := make([]string, 0, len(page.Events))
	for _, evt := range page.Events {
		if evt.ProviderID != providerID {
			t.Fatalf("event provider_id=%q want %q", evt.ProviderID, providerID)
		}
		if evt.OperatorCorrelation == nil || evt.OperatorCorrelation["transition"] != evt.EventType {
			t.Fatalf("missing trust transition correlation for %s: %#v", evt.EventType, evt.OperatorCorrelation)
		}
		got = append(got, evt.EventType)
	}
	want := []string{
		rewards.AuditEventTrustTierPromoted,
		rewards.AuditEventTrustTierDemoted,
		rewards.AuditEventTrustTierPromoted,
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("trust audit events = %v, want %v", got, want)
	}
}

func TestWalletDailyCapAcrossProviders(t *testing.T) {
	fx, adminDB := startPostgres(t)
	writerDB := openRewardsWriter(t, fx)
	ctx := context.Background()

	wallet := "0xabc123"
	for _, pid := range []string{"p_a", "p_b"} {
		if _, err := writerDB.ExecContext(ctx, `
            INSERT INTO provider_emission_state (provider_id, trust_tier, bound_wallet)
            VALUES ($1, 'provisional', $2)
        `, pid, wallet); err != nil {
			t.Fatalf("seed %s: %v", pid, err)
		}
	}

	today := time.Now().UTC().Truncate(24 * time.Hour)
	if _, err := writerDB.ExecContext(ctx, `
        INSERT INTO wallet_daily_malibu_emission (bound_wallet, emission_day, sum_malibu, updated_at)
        VALUES ($1, $2, 99, now())
    `, wallet, today); err != nil {
		t.Fatalf("seed wallet daily total: %v", err)
	}

	cfg := testEmissionConfig(time.Hour, 1000, 100)
	runner, err := rewards.New(writerDB, cfg, zerolog.Nop(), rewards.RunnerDeps{})
	if err != nil {
		t.Fatalf("new runner: %v", err)
	}
	if err := runner.RunEmissionTickOnce(ctx); err != nil {
		t.Fatalf("emission tick: %v", err)
	}

	var sum float64
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COALESCE(sum_malibu, 0)::FLOAT8
          FROM wallet_daily_malibu_emission
         WHERE bound_wallet = $1 AND emission_day = CURRENT_DATE
    `, wallet).Scan(&sum); err != nil {
		t.Fatalf("wallet sum: %v", err)
	}
	if sum > 100.0001 {
		t.Fatalf("wallet aggregate %v exceeds cap 100", sum)
	}

	var walletCapProvider string
	for _, pid := range []string{"p_a", "p_b"} {
		page, err := rewards.QueryRewardAuditEvents(ctx, writerDB, rewards.RewardAuditQuery{
			ProviderID: pid,
			Limit:      100,
		})
		if err != nil {
			t.Fatalf("query %s audit: %v", pid, err)
		}
		for _, evt := range page.Events {
			if evt.EventType == rewards.AuditEventWalletDailyCapApplied {
				walletCapProvider = pid
			}
		}
	}
	if walletCapProvider == "" {
		t.Fatal("expected wallet_daily_cap_applied audit event even while provisional hold remains primary")
	}
	for _, pid := range []string{"p_a", "p_b"} {
		bal, err := rewards.QueryAccrualBalance(ctx, writerDB, pid, cfg)
		if err != nil {
			t.Fatalf("query %s accrual balance: %v", pid, err)
		}
		hasWalletCap := testContainsString(bal.HoldReasons, rewards.HoldPerWalletDailyCap)
		if pid == walletCapProvider && !hasWalletCap {
			t.Fatalf("%s hold reasons = %v, want wallet cap hold", pid, bal.HoldReasons)
		}
		if pid != walletCapProvider && hasWalletCap {
			t.Fatalf("%s hold reasons = %v, must not expose shared-wallet cap state", pid, bal.HoldReasons)
		}
		eligibility := rewards.RewardEligibilityFromBalanceAndTrust(bal, rewards.TrustCriteriaStatus{
			WalletBound:          true,
			VerifiedReceiptCount: 999,
			AppAttested:          true,
		})
		if pid == walletCapProvider && eligibility.WithdrawalState != rewards.WithdrawalStateCapped {
			t.Fatalf("%s withdrawal_state = %q, want %q", pid, eligibility.WithdrawalState, rewards.WithdrawalStateCapped)
		}
		if pid == walletCapProvider && eligibility.PrimaryReason != rewards.ReasonHeldWalletDailyCap {
			t.Fatalf("%s primary_reason = %q, want %q", pid, eligibility.PrimaryReason, rewards.ReasonHeldWalletDailyCap)
		}
		if pid != walletCapProvider && eligibility.PrimaryReason == rewards.ReasonHeldWalletDailyCap {
			t.Fatalf("%s primary_reason must not expose shared-wallet cap state", pid)
		}
	}
}

func testContainsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func TestUsefulWorkAccrualVerifiedWorkCapsHoldsAndReplay(t *testing.T) {
	fx, adminDB := startPostgres(t)
	ctx := context.Background()

	if _, err := adminDB.ExecContext(ctx, `
        CREATE TABLE ledger_request_credits (
            id BIGSERIAL PRIMARY KEY,
            request_id TEXT NOT NULL,
            attempt_n INTEGER NOT NULL,
            provider_id TEXT NOT NULL,
            ts_utc TIMESTAMPTZ NOT NULL,
            provider_credits BIGINT NOT NULL,
            settlement_policy_mode TEXT NOT NULL DEFAULT 'enforce',
            spec022_verified BOOLEAN NOT NULL DEFAULT FALSE,
            UNIQUE(request_id, attempt_n, provider_id)
        );
        GRANT SELECT ON ledger_request_credits TO rewards_writer;
    `); err != nil {
		t.Fatalf("seed useful work mirror table: %v", err)
	}

	writerDB := openRewardsWriter(t, fx)
	wallet := "0xusefulwork"
	for _, seed := range []struct {
		providerID string
		tier       string
		wallet     string
	}{
		{"p_verified", rewards.TierTrusted, wallet},
		{"p_overflow", rewards.TierTrusted, wallet},
		{"p_provisional", rewards.TierProvisional, ""},
		{"p_unverified", rewards.TierTrusted, ""},
	} {
		if _, err := adminDB.ExecContext(ctx, `
            INSERT INTO provider_emission_state (provider_id, trust_tier, bound_wallet)
            VALUES ($1, $2, NULLIF($3, ''))
        `, seed.providerID, seed.tier, seed.wallet); err != nil {
			t.Fatalf("seed state %s: %v", seed.providerID, err)
		}
	}
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO ledger_request_credits
            (request_id, attempt_n, provider_id, ts_utc, provider_credits, spec022_verified)
        VALUES
            ('req-verified', 0, 'p_verified', now() - interval '4 minutes', 2000, TRUE),
            ('req-overflow', 0, 'p_overflow', now() - interval '3 minutes', 2000, TRUE),
            ('req-provisional', 0, 'p_provisional', now() - interval '2 minutes', 1000, TRUE),
            ('req-unverified', 0, 'p_unverified', now() - interval '1 minute', 9000, FALSE)
    `); err != nil {
		t.Fatalf("seed useful work rows: %v", err)
	}

	cfg := testEmissionConfig(time.Hour, 25, 3)
	cfg.UsefulWorkEnabled = true
	cfg.UsefulWorkMALIBUPer1KCredits = 1
	runner, err := rewards.New(writerDB, cfg, zerolog.Nop(), rewards.RunnerDeps{})
	if err != nil {
		t.Fatalf("new runner: %v", err)
	}
	if err := runner.RunUsefulWorkAccrualOnce(ctx); err != nil {
		t.Fatalf("useful work accrual: %v", err)
	}
	if err := runner.RunUsefulWorkAccrualOnce(ctx); err != nil {
		t.Fatalf("useful work replay accrual: %v", err)
	}

	var verifiedCount int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*)
          FROM provider_rewards_ledger
         WHERE reason = $1
    `, rewards.ReasonMalibuVerifiedUsefulWorkV02).Scan(&verifiedCount); err != nil {
		t.Fatalf("count useful rows: %v", err)
	}
	if verifiedCount != 3 {
		t.Fatalf("useful work ledger rows = %d, want 3 (verified, overflow, provisional only)", verifiedCount)
	}

	var amount, ref string
	if err := adminDB.QueryRowContext(ctx, `
        SELECT amount_malibu::TEXT, external_ref
          FROM provider_rewards_ledger
         WHERE provider_id = 'p_verified'
    `).Scan(&amount, &ref); err != nil {
		t.Fatalf("query verified reward: %v", err)
	}
	if amount != "2.00000000" {
		t.Fatalf("verified amount = %q, want 2.00000000", amount)
	}
	if ref != "spec022:req-verified:0:p_verified" {
		t.Fatalf("external_ref = %q", ref)
	}

	var overflowHold string
	var overflowAmount string
	if err := adminDB.QueryRowContext(ctx, `
        SELECT withdrawal_hold_reason, amount_malibu::TEXT
          FROM provider_rewards_ledger
         WHERE provider_id = 'p_overflow'
    `).Scan(&overflowHold, &overflowAmount); err != nil {
		t.Fatalf("query overflow reward: %v", err)
	}
	if overflowHold != rewards.HoldPerWalletDailyCap {
		t.Fatalf("overflow hold = %q, want %q", overflowHold, rewards.HoldPerWalletDailyCap)
	}
	if overflowAmount != "1.00000000" {
		t.Fatalf("overflow amount = %q, want 1.00000000", overflowAmount)
	}

	var provisionalHold string
	if err := adminDB.QueryRowContext(ctx, `
        SELECT withdrawal_hold_reason
          FROM provider_rewards_ledger
         WHERE provider_id = 'p_provisional'
    `).Scan(&provisionalHold); err != nil {
		t.Fatalf("query provisional reward: %v", err)
	}
	if provisionalHold != rewards.HoldTrustTierProvisional {
		t.Fatalf("provisional hold = %q, want %q", provisionalHold, rewards.HoldTrustTierProvisional)
	}

	withdrawable, err := rewards.SelectWithdrawableMALIBU(ctx, writerDB, "p_verified", 10)
	if err != nil {
		t.Fatalf("withdrawable verified: %v", err)
	}
	if len(withdrawable) != 1 {
		t.Fatalf("trusted useful work withdrawable rows = %d, want 1", len(withdrawable))
	}
	provisionalWithdrawable, err := rewards.SelectWithdrawableMALIBU(ctx, writerDB, "p_provisional", 10)
	if err != nil {
		t.Fatalf("withdrawable provisional: %v", err)
	}
	if len(provisionalWithdrawable) != 0 {
		t.Fatalf("provisional useful work withdrawable rows = %d, want 0", len(provisionalWithdrawable))
	}
}

func TestUsefulWorkAccrualMarksProviderAtDailyCap(t *testing.T) {
	fx, adminDB := startPostgres(t)
	ctx := context.Background()

	if _, err := adminDB.ExecContext(ctx, `
        CREATE TABLE ledger_request_credits (
            id BIGSERIAL PRIMARY KEY,
            request_id TEXT NOT NULL,
            attempt_n INTEGER NOT NULL,
            provider_id TEXT NOT NULL,
            ts_utc TIMESTAMPTZ NOT NULL,
            provider_credits BIGINT NOT NULL,
            settlement_policy_mode TEXT NOT NULL DEFAULT 'enforce',
            spec022_verified BOOLEAN NOT NULL DEFAULT FALSE,
            UNIQUE(request_id, attempt_n, provider_id)
        );
        GRANT SELECT ON ledger_request_credits TO rewards_writer;
    `); err != nil {
		t.Fatalf("seed useful work mirror table: %v", err)
	}

	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO provider_emission_state
            (provider_id, trust_tier, provider_day_malibu, emission_day)
        VALUES
            ('p_capped', 'trusted', 1, CURRENT_DATE),
            ('p_later', 'trusted', 0, CURRENT_DATE);

        INSERT INTO ledger_request_credits
            (request_id, attempt_n, provider_id, ts_utc, provider_credits, spec022_verified)
        SELECT 'req-capped-' || gs::TEXT, 0, 'p_capped',
               now() - interval '2 hours' + (gs || ' seconds')::interval,
               1000, TRUE
          FROM generate_series(1, 500) AS gs;

        INSERT INTO ledger_request_credits
            (request_id, attempt_n, provider_id, ts_utc, provider_credits, spec022_verified)
        VALUES ('req-later', 0, 'p_later', now(), 1000, TRUE);
    `); err != nil {
		t.Fatalf("seed capped useful work rows: %v", err)
	}

	writerDB := openRewardsWriter(t, fx)
	cfg := testEmissionConfig(time.Hour, 1, 100)
	cfg.UsefulWorkEnabled = true
	cfg.UsefulWorkMALIBUPer1KCredits = 1
	runner, err := rewards.New(writerDB, cfg, zerolog.Nop(), rewards.RunnerDeps{})
	if err != nil {
		t.Fatalf("new runner: %v", err)
	}
	if err := runner.RunUsefulWorkAccrualOnce(ctx); err != nil {
		t.Fatalf("useful work accrual: %v", err)
	}

	var cappedCount int
	var cappedSum string
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*), COALESCE(SUM(amount_malibu), 0)::TEXT
          FROM provider_rewards_ledger
         WHERE provider_id = 'p_capped'
           AND reason = $1
    `, rewards.ReasonMalibuVerifiedUsefulWorkV02).Scan(&cappedCount, &cappedSum); err != nil {
		t.Fatalf("count capped rewards: %v", err)
	}
	if cappedCount != 500 {
		t.Fatalf("p_capped terminal cap markers = %d, want 500", cappedCount)
	}
	if cappedSum != "0.00000000" {
		t.Fatalf("p_capped capped sum = %q, want 0.00000000", cappedSum)
	}
	bal, err := rewards.QueryAccrualBalance(ctx, writerDB, "p_capped", cfg)
	if err != nil {
		t.Fatalf("query capped balance: %v", err)
	}
	if !bal.ProviderDailyCapped {
		t.Fatal("p_capped should report provider daily cap active")
	}
	eligibility := rewards.RewardEligibilityFromBalanceAndTrust(bal, rewards.TrustCriteriaStatus{
		WalletBound:          true,
		VerifiedReceiptCount: 999,
		AppAttested:          true,
	})
	if eligibility.WithdrawalState != rewards.WithdrawalStateCapped {
		t.Fatalf("p_capped withdrawal_state = %q, want %q", eligibility.WithdrawalState, rewards.WithdrawalStateCapped)
	}
	if eligibility.PrimaryReason != rewards.ReasonHeldProviderDailyCap {
		t.Fatalf("p_capped primary_reason = %q, want %q", eligibility.PrimaryReason, rewards.ReasonHeldProviderDailyCap)
	}

	if err := runner.RunUsefulWorkAccrualOnce(ctx); err != nil {
		t.Fatalf("useful work accrual next batch: %v", err)
	}
	var laterCount int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*)
          FROM provider_rewards_ledger
         WHERE provider_id = 'p_later'
           AND reason = $1
    `, rewards.ReasonMalibuVerifiedUsefulWorkV02).Scan(&laterCount); err != nil {
		t.Fatalf("count later reward: %v", err)
	}
	if laterCount != 1 {
		t.Fatalf("p_later useful work rewards = %d, want 1", laterCount)
	}

	if _, err := adminDB.ExecContext(ctx, `
        UPDATE provider_emission_state
           SET provider_day_malibu = 0,
               emission_day = CURRENT_DATE - interval '1 day'
         WHERE provider_id = 'p_capped'
    `); err != nil {
		t.Fatalf("simulate next day: %v", err)
	}
	if err := runner.RunUsefulWorkAccrualOnce(ctx); err != nil {
		t.Fatalf("useful work accrual replay: %v", err)
	}
	var replayCount int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*)
          FROM provider_rewards_ledger
         WHERE provider_id = 'p_capped'
           AND reason = $1
    `, rewards.ReasonMalibuVerifiedUsefulWorkV02).Scan(&replayCount); err != nil {
		t.Fatalf("count replay capped rewards: %v", err)
	}
	if replayCount != cappedCount {
		t.Fatalf("p_capped replay markers = %d, want unchanged %d", replayCount, cappedCount)
	}
}

// TestCapReplayPendingDoesNotDesyncConnection is a regression test for the
// hardware-track (mp-*) accrual failure: `pq: unexpected Parse response
// "(C) CommandComplete"`. That error surfaced whenever a Trusted provider's
// wallet had cap_replay_pending=true (set by the SPEC-016 payout-address
// wallet mirror — a path mp-* providers exercise routinely) and an
// already-held ledger row qualified for replay during an accrual tick.
// replayCapPending used to run tx.ExecContext while its own tx.QueryContext
// *sql.Rows was still open, which desyncs the lib/pq wire protocol (lib/pq
// does not buffer results like libpq) and aborts the whole tick transaction
// for that provider — silently, since runEmissionTick only logs a Warn.
func TestCapReplayPendingDoesNotDesyncConnection(t *testing.T) {
	fx, adminDB := startPostgres(t)
	writerDB := openRewardsWriter(t, fx)
	ctx := context.Background()

	providerID := "mp-hw-test-1"
	wallet := "0xdeadbeef"

	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO provider_emission_state
            (provider_id, trust_tier, bound_wallet, cap_replay_pending, provider_day_malibu)
        VALUES ($1, 'trusted', $2, TRUE, 0)
    `, providerID, wallet); err != nil {
		t.Fatalf("seed state: %v", err)
	}

	heldUnixTS := time.Now().UTC().Add(-time.Hour).Unix()
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO provider_rewards_ledger
            (provider_id, unix_ts, amount_malibu, withdrawal_hold_reason, reason)
        VALUES ($1, $2, 10, $3, 'malibu_bootstrap_tick')
    `, providerID, heldUnixTS, rewards.HoldPerWalletDailyCap); err != nil {
		t.Fatalf("seed held ledger row: %v", err)
	}

	cfg := testEmissionConfig(time.Hour, 25, 100)
	runner, err := rewards.New(writerDB, cfg, zerolog.Nop(), rewards.RunnerDeps{})
	if err != nil {
		t.Fatalf("new runner: %v", err)
	}
	if err := runner.RunEmissionTickOnce(ctx); err != nil {
		t.Fatalf("emission tick: %v", err)
	}

	// The tick transaction must have committed (not silently rolled back
	// by a desynced connection): a new ledger row for this tick exists.
	var rowCount int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM provider_rewards_ledger WHERE provider_id = $1
    `, providerID).Scan(&rowCount); err != nil {
		t.Fatalf("count ledger rows: %v", err)
	}
	if rowCount != 2 {
		t.Fatalf("ledger rows for %s = %d, want 2 (pre-existing held row + new tick row)", providerID, rowCount)
	}

	// The pre-existing held row must have been replayed (hold cleared)
	// since running(0) + 10 <= walletCap(100).
	var holdReason sql.NullString
	if err := adminDB.QueryRowContext(ctx, `
        SELECT withdrawal_hold_reason FROM provider_rewards_ledger
         WHERE provider_id = $1 AND unix_ts = $2
    `, providerID, heldUnixTS).Scan(&holdReason); err != nil {
		t.Fatalf("query held row: %v", err)
	}
	if holdReason.Valid {
		t.Fatalf("held row hold_reason = %q, want cleared (NULL)", holdReason.String)
	}

	var capReplayPending bool
	if err := adminDB.QueryRowContext(ctx, `
        SELECT cap_replay_pending FROM provider_emission_state WHERE provider_id = $1
    `, providerID).Scan(&capReplayPending); err != nil {
		t.Fatalf("query state: %v", err)
	}
	if capReplayPending {
		t.Fatal("cap_replay_pending should be cleared after successful replay")
	}

	auditPage, err := rewards.QueryRewardAuditEvents(ctx, writerDB, rewards.RewardAuditQuery{
		ProviderID: providerID,
		Limit:      10,
	})
	if err != nil {
		t.Fatalf("query audit events: %v", err)
	}
	var sawHoldCleared bool
	for _, evt := range auditPage.Events {
		if evt.EventType == rewards.AuditEventMalibuHoldCleared {
			sawHoldCleared = true
		}
	}
	if !sawHoldCleared {
		t.Fatal("expected malibu_hold_cleared audit event after cap replay")
	}
}
