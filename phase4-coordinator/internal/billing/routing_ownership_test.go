package billing

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

func TestBuyerOwnedProvidersUsesReaderDuringWriterTransaction(t *testing.T) {
	path := filepath.Join(t.TempDir(), "billing.db")
	requestLogStore, err := requestlog.OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer requestLogStore.Close()
	writer := requestLogStore.DB()
	writer.SetMaxOpenConns(1)
	writer.SetMaxIdleConns(1)
	store, err := NewStore(writer)
	if err != nil {
		t.Fatal(err)
	}
	execAll(t, writer, selfDealFixtureSchema, `INSERT INTO provider_ownership VALUES ('old',7),('linked',8)`)
	grantAllowance(t, store, AllowanceStake{AccountID: "seed", GitHubUserID: 8, Units: malibu(10)})
	reader, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	reader.SetMaxOpenConns(4)
	store.SetReadDB(reader)

	conn, err := writer.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	defer conn.ExecContext(context.Background(), `ROLLBACK`)
	for _, statement := range []string{
		`BEGIN IMMEDIATE`,
		`INSERT INTO allowance_grants (account_id, day, github_user_id, stake_units, raw_credits, granted_credits, created_at_utc)
		 SELECT 'acct', day, github_user_id, stake_units, raw_credits, granted_credits, created_at_utc FROM allowance_grants WHERE account_id = 'seed'`,
		`UPDATE provider_ownership SET github_user_id = 9 WHERE provider_id = 'old'`,
		`INSERT INTO provider_ownership VALUES ('new',8)`,
	} {
		if _, err := conn.ExecContext(context.Background(), statement); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	owned, err := store.BuyerOwnedProviders(ctx, "acct", []int64{7})
	if err != nil || len(owned) != 1 || !owned["old"] {
		t.Fatalf("committed ownership through reader while writer held: owned=%v err=%v", owned, err)
	}
	if _, err := conn.ExecContext(context.Background(), `COMMIT`); err != nil {
		t.Fatal(err)
	}
	// Keep the writer connection checked out: both fresh reads use the pool.
	owned, err = store.BuyerOwnedProviders(ctx, "acct", []int64{7})
	if err != nil || len(owned) != 2 || !owned["linked"] || !owned["new"] || owned["old"] {
		t.Fatalf("fresh grant and ownership after commit: owned=%v err=%v", owned, err)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	if owned, err := store.BuyerOwnedProviders(ctx, "acct", nil); err == nil || owned != nil {
		t.Fatalf("unavailable reader failed open: owned=%v err=%v", owned, err)
	}
}

func TestBuyerOwnedProvidersAllLinksAndNoLink(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	execAll(t, store.db, selfDealFixtureSchema,
		`INSERT INTO provider_ownership VALUES ('one',7),('two',7),('linked',8),('other',9)`,
	)
	grantAllowance(t, store, AllowanceStake{AccountID: "acct", GitHubUserID: 7, Units: malibu(10)})
	owned, err := store.BuyerOwnedProviders(context.Background(), "acct", []int64{8})
	if err != nil || len(owned) != 3 || !owned["one"] || !owned["two"] || !owned["linked"] || owned["other"] {
		t.Fatalf("owned=%v err=%v", owned, err)
	}
	empty, err := store.BuyerOwnedProviders(context.Background(), "ordinary", nil)
	if err != nil || len(empty) != 0 {
		t.Fatalf("no-link=%v err=%v", empty, err)
	}
	// No memoization: ownership changes affect the next dispatch lookup.
	execAll(t, store.db, `INSERT INTO provider_ownership VALUES ('new',7)`)
	owned, err = store.BuyerOwnedProviders(context.Background(), "acct", nil)
	if err != nil || !owned["new"] {
		t.Fatalf("fresh owned=%v err=%v", owned, err)
	}
	execAll(t, store.db, `DROP TABLE provider_ownership`)
	if _, err := store.BuyerOwnedProviders(context.Background(), "acct", nil); err == nil {
		t.Fatal("lookup failure became no-link success")
	}
}

func TestBuyerOwnedProvidersIncludesUnmaturedStake(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	execAll(t, store.db, selfDealFixtureSchema, `INSERT INTO provider_ownership VALUES ('own',7),('other',8)`)
	store.SetRoutingStakeIdentityLookup(func(_ context.Context, account string) (int64, error) {
		if account == "acct" {
			return 7, nil
		}
		return 0, nil
	})
	owned, err := store.BuyerOwnedProviders(context.Background(), "acct", nil)
	if err != nil || !owned["own"] || owned["other"] {
		t.Fatalf("owned=%v err=%v", owned, err)
	}
	owned, err = store.BuyerOwnedProviders(context.Background(), "unlinked", nil)
	if err != nil || len(owned) != 0 {
		t.Fatalf("no-link=%v err=%v", owned, err)
	}
	store.SetRoutingStakeIdentityLookup(func(context.Context, string) (int64, error) {
		return 0, errors.New("configured stake source unavailable")
	})
	if _, err = store.BuyerOwnedProviders(context.Background(), "unlinked", nil); err == nil {
		t.Fatal("stake lookup failed open")
	}
}
