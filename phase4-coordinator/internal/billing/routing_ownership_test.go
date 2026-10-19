package billing

import (
	"context"
	"errors"
	"testing"
)

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
