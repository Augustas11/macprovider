package billing

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
)

// selfDealFixtureSchema mirrors the read-only columns of the auth, payout and
// referral tables the check reads.
const selfDealFixtureSchema = `
CREATE TABLE provider_ownership (provider_id TEXT PRIMARY KEY, github_user_id INTEGER NOT NULL);
CREATE TABLE provider_payout_addresses (provider_id TEXT NOT NULL, chain TEXT NOT NULL, address TEXT NOT NULL, UNIQUE(provider_id, chain));
CREATE TABLE referral_issuers (issuer_id TEXT PRIMARY KEY, code_type TEXT NOT NULL, provider_id TEXT);
CREATE TABLE referral_redemptions (campaign TEXT NOT NULL, provider_id TEXT NOT NULL, issuer_id TEXT NOT NULL, PRIMARY KEY(campaign, provider_id));
`

func execAll(t *testing.T, db *sql.DB, stmts ...string) {
	t.Helper()
	for _, stmt := range stmts {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
}

// SPEC-050-R010: owner, shared payout wallet, and referral cluster.
func TestAllowanceSelfDealingRelations(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	execAll(t, store.db, selfDealFixtureSchema,
		`INSERT INTO provider_ownership VALUES ('p_own', 7), ('p_own2', 7), ('p_other', 8), ('p_wallet', 9)`,
		`INSERT INTO provider_payout_addresses VALUES ('p_own', 'base-mainnet', '0xAbC0000000000000000000000000000000000001')`,
		`INSERT INTO provider_payout_addresses VALUES ('p_wallet', 'base-mainnet', '0xabc0000000000000000000000000000000000001')`,
		`INSERT INTO provider_payout_addresses VALUES ('p_other', 'base-mainnet', '0x0000000000000000000000000000000000000002')`,
		// p_own issued a provider code; p_ref redeemed it; p_ref2 redeemed
		// p_ref's code. p_seeded only used an operator seed code.
		`INSERT INTO referral_issuers VALUES ('iss_own', 'P', 'p_own'), ('iss_ref', 'P', 'p_ref'), ('iss_seed', 'S', NULL)`,
		`INSERT INTO referral_redemptions VALUES ('c', 'p_ref', 'iss_own'), ('c', 'p_ref2', 'iss_ref'), ('c', 'p_seeded', 'iss_seed'), ('c', 'p_own2', 'iss_seed')`,
	)
	grantAllowance(t, store,
		AllowanceStake{AccountID: "acct", GitHubUserID: 7, Units: malibu(10)},
		AllowanceStake{AccountID: "acct_noid", Units: malibu(10)},
	)
	admit(t, store, "acct", "req", 1, false)
	admit(t, store, "acct_noid", "req", 1, false)
	for provider, want := range map[string]bool{
		"p_own":     true,  // owned by the account's identity
		"p_wallet":  true,  // same payout address, different case
		"p_ref":     true,  // redeemed a code the account's provider issued
		"p_ref2":    true,  // two referral hops away
		"p_other":   false, // unrelated owner and wallet
		"p_seeded":  false, // operator seed codes link nobody
		"p_unknown": false,
	} {
		if got := store.AllowanceSelfDealing(ctx, "acct", "req", provider); got != want {
			t.Errorf("%s self-dealing=%v want %v", provider, got, want)
		}
	}
	// Fail safe: no grant, or a grant without an identity, counts as
	// self-dealt.
	if !store.AllowanceSelfDealing(ctx, "acct_nogrant", "req", "p_other") {
		t.Error("account without a grant must count as self-dealt")
	}
	if !store.AllowanceSelfDealing(ctx, "acct", "no-such-request", "p_other") {
		t.Error("request without an allowance hold must count as self-dealt")
	}
	if !store.AllowanceSelfDealing(ctx, "acct_noid", "req", "p_other") {
		t.Error("grant without an identity must count as self-dealt")
	}
	// The answer for a request follows the grant of its admission day, not
	// the wall clock at ledger insert.
	if store.AllowanceSelfDealing(ctx, "acct", "req", "p_other") {
		t.Error("memoized answer changed")
	}
}

func TestAllowanceSelfDealingFailsSafe(t *testing.T) {
	t.Run("missing tables", func(t *testing.T) {
		_, store := newRequestAndBillingStores(t)
		grantAllowance(t, store, AllowanceStake{AccountID: "acct", GitHubUserID: 7, Units: malibu(10)})
		admit(t, store, "acct", "req", 1, false)
		if !store.AllowanceSelfDealing(context.Background(), "acct", "req", "p_any") {
			t.Fatal("a failed lookup must count as self-dealt")
		}
	})
	t.Run("referral chain past the depth bound", func(t *testing.T) {
		_, store := newRequestAndBillingStores(t)
		execAll(t, store.db, selfDealFixtureSchema, `INSERT INTO provider_ownership VALUES ('p_own', 7)`)
		// p0 <- p1 <- ... <- p11: a chain longer than the walk bound that
		// never reaches an owned provider.
		for i := 0; i < 12; i++ {
			execAll(t, store.db,
				fmt.Sprintf(`INSERT INTO referral_issuers VALUES ('iss%d', 'P', 'p%d')`, i, i),
				fmt.Sprintf(`INSERT INTO referral_redemptions VALUES ('c', 'p%d', 'iss%d')`, i+1, i))
		}
		grantAllowance(t, store, AllowanceStake{AccountID: "acct", GitHubUserID: 7, Units: malibu(10)})
		admit(t, store, "acct", "req", 1, false)
		if !store.AllowanceSelfDealing(context.Background(), "acct", "req", "p0") {
			t.Fatal("an unbounded cluster walk must count as self-dealt")
		}
	})
}
