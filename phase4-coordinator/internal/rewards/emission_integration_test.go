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

	cfg := rewards.Config{
		Enabled:                true,
		TickInterval:           time.Hour,
		ProviderDailyCapMALIBU: 25,
		WalletDailyCapMALIBU:   100,
		MaxSerializableRetries: 5,
	}
	runner, err := rewards.New(writerDB, cfg, zerolog.Nop())
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

	cfg := rewards.Config{
		Enabled:                true,
		TickInterval:           time.Minute,
		ProviderDailyCapMALIBU: 1000,
		WalletDailyCapMALIBU:   100,
		MaxSerializableRetries: 5,
	}
	runner, err := rewards.New(writerDB, cfg, zerolog.Nop())
	if err != nil {
		t.Fatalf("new runner: %v", err)
	}
	for i := 0; i < 12; i++ {
		if err := runner.RunEmissionTickOnce(ctx); err != nil {
			t.Fatalf("tick %d: %v", i, err)
		}
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
}
