//go:build integration

package rewards_test

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/rewards"
)

// SPEC-050 stake ledger against the real migrations and the rewards_writer
// role.

func seedWithdrawableMALIBU(t *testing.T, db *sql.DB, providerID, amount string) {
	t.Helper()
	if _, err := db.ExecContext(context.Background(), `
        INSERT INTO provider_rewards_ledger (provider_id, unix_ts, amount_malibu, withdrawal_hold_reason, reason)
        VALUES ($1, $2, $3::NUMERIC, NULL, $4)`,
		providerID, time.Now().UTC().Unix(), amount, rewards.ReasonMalibuBootstrapTick); err != nil {
		t.Fatalf("seed ledger: %v", err)
	}
}

func staticOwner(owners map[string]int64) rewards.ProviderOwnerFunc {
	return func(_ context.Context, providerID string) (int64, bool, error) {
		gh, ok := owners[providerID]
		return gh, ok, nil
	}
}

func mustUnits(t *testing.T, raw string) int64 {
	t.Helper()
	u, err := rewards.ParseMALIBUUnits(raw)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

func TestStakeLockIsBoundedIdempotentAndNettedFromWithdrawable(t *testing.T) {
	fx, _ := startPostgres(t)
	db := openRewardsWriter(t, fx)
	ctx := context.Background()
	seedWithdrawableMALIBU(t, db, "p_a", "10")
	seedWithdrawableMALIBU(t, db, "p_b", "5")
	// Held MALIBU is never stakeable (SPEC-050-R001).
	if _, err := db.ExecContext(ctx, `
        INSERT INTO provider_rewards_ledger (provider_id, unix_ts, amount_malibu, withdrawal_hold_reason, reason)
        VALUES ('p_a', $1, 100, 'trust_tier_provisional', $2)`, time.Now().Unix(), rewards.ReasonMalibuBootstrapTick); err != nil {
		t.Fatal(err)
	}
	ledger, err := rewards.NewStakeLedger(db, 168*time.Hour, staticOwner(map[string]int64{"p_a": 7, "p_b": 7}))
	if err != nil {
		t.Fatal(err)
	}
	req := rewards.StakeRequest{AccountID: "acct_1", GitHubUserID: 7, OwnedProviderIDs: []string{"p_b", "p_a"}, AmountUnits: mustUnits(t, "12"), IdempotencyKey: "k1"}
	res, err := ledger.Lock(ctx, req)
	if err != nil {
		t.Fatalf("lock: %v", err)
	}
	if len(res.Events) != 2 || res.Events[0].ProviderID != "p_a" || res.Events[0].AmountUnits != mustUnits(t, "10") || res.Events[1].AmountUnits != mustUnits(t, "2") {
		t.Fatalf("lock events %+v, want p_a 10 then p_b 2", res.Events)
	}
	replay, err := ledger.Lock(ctx, req)
	if err != nil || !replay.Replayed || len(replay.Events) != 2 {
		t.Fatalf("replay = %+v, %v", replay, err)
	}
	reused := req
	reused.AmountUnits = mustUnits(t, "1")
	if _, err := ledger.Lock(ctx, reused); !errors.Is(err, rewards.ErrStakeIdempotencyReused) {
		t.Fatalf("reused key err = %v", err)
	}
	over := req
	over.IdempotencyKey, over.AmountUnits = "k2", mustUnits(t, "3.00000001")
	if _, err := ledger.Lock(ctx, over); !errors.Is(err, rewards.ErrStakeInsufficient) {
		t.Fatalf("over-lock err = %v, want ErrStakeInsufficient", err)
	}
	bal, err := rewards.QueryAccrualBalance(ctx, db, "p_a", testEmissionConfig(time.Hour, 25, 100))
	if err != nil {
		t.Fatal(err)
	}
	if bal.LockedMALIBU != "10.00000000" || bal.WithdrawableMALIBU != "0.00000000" {
		t.Fatalf("p_a locked=%s withdrawable=%s, want 10 locked and 0 withdrawable", bal.LockedMALIBU, bal.WithdrawableMALIBU)
	}
	// A withdrawal runner sees no row of the fully locked provider and only
	// the rows of p_b that the 2 locked MALIBU do not cover.
	if rows, err := rewards.SelectWithdrawableMALIBU(ctx, db, "p_a", 10); err != nil || len(rows) != 0 {
		t.Fatalf("p_a withdrawable rows %v err %v", rows, err)
	}
	seedWithdrawableMALIBU(t, db, "p_b", "1")
	seedWithdrawableMALIBU(t, db, "p_b", "10")
	// p_b holds 5 + 1 + 10 = 16 with 2 locked: 14 may leave, so the 5 and
	// 1 rows are selectable and the 10 row, which the lock partly covers,
	// is not.
	if rows, err := rewards.SelectWithdrawableMALIBU(ctx, db, "p_b", 10); err != nil || len(rows) != 2 || rows[0].AmountMALIBU != "5.00000000" || rows[1].AmountMALIBU != "1.00000000" {
		t.Fatalf("p_b withdrawable rows %v err %v, want the 5 and 1 MALIBU rows", rows, err)
	}
	pos, err := ledger.Position(ctx, "acct_1", []string{"p_a", "p_b"})
	if err != nil {
		t.Fatal(err)
	}
	if pos.StakedUnits != mustUnits(t, "12") || pos.AvailableUnits != mustUnits(t, "14") {
		t.Fatalf("position %+v", pos)
	}
}

func TestConcurrentStakeLocksCannotLockTheSameMALIBUTwice(t *testing.T) {
	fx, _ := startPostgres(t)
	db := openRewardsWriter(t, fx)
	ctx := context.Background()
	seedWithdrawableMALIBU(t, db, "p_c", "10")
	ledger, err := rewards.NewStakeLedger(db, 168*time.Hour, staticOwner(map[string]int64{"p_c": 9}))
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make([]error, 8)
	for i := range results {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, results[i] = ledger.Lock(ctx, rewards.StakeRequest{
				AccountID: fmt.Sprintf("acct_%d", i), GitHubUserID: 9, OwnedProviderIDs: []string{"p_c"},
				AmountUnits: mustUnits(t, "4"), IdempotencyKey: "k",
			})
		}(i)
	}
	wg.Wait()
	ok := 0
	for _, err := range results {
		if err == nil {
			ok++
		} else if !errors.Is(err, rewards.ErrStakeInsufficient) {
			t.Fatalf("unexpected error %v", err)
		}
	}
	if ok != 2 {
		t.Fatalf("%d locks of 4 MALIBU succeeded on 10 MALIBU, want 2", ok)
	}
}

func TestStakeUnlockCooldownAndEarningStake(t *testing.T) {
	fx, _ := startPostgres(t)
	db := openRewardsWriter(t, fx)
	ctx := context.Background()
	seedWithdrawableMALIBU(t, db, "p_d", "100")
	owners := map[string]int64{"p_d": 11}
	ledger, err := rewards.NewStakeLedger(db, 168*time.Hour, staticOwner(owners))
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	clock := t0
	ledger.SetNowForTest(func() time.Time { return clock })
	lock := rewards.StakeRequest{AccountID: "acct_d", GitHubUserID: 11, OwnedProviderIDs: []string{"p_d"}, AmountUnits: mustUnits(t, "60"), IdempotencyKey: "lock-1"}
	if _, err := ledger.Lock(ctx, lock); err != nil {
		t.Fatal(err)
	}
	day := func(d int) time.Time { return time.Date(2026, 10, d, 0, 0, 0, 0, time.UTC) }
	earning := func(dayStart time.Time) int64 {
		t.Helper()
		stakes, err := ledger.EarningStakes(ctx, dayStart, 24*time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		var sum int64
		for _, s := range stakes {
			sum += s.Units
		}
		return sum
	}
	// Locked at Oct 1 12:00 with a 24h minimum age: Oct 2 00:00 is too
	// early, Oct 3 00:00 counts.
	if got := earning(day(2)); got != 0 {
		t.Fatalf("immature stake earned %d", got)
	}
	if got := earning(day(3)); got != mustUnits(t, "60") {
		t.Fatalf("matured stake earned %d", got)
	}
	clock = time.Date(2026, 10, 3, 6, 0, 0, 0, time.UTC)
	unlock := rewards.StakeRequest{AccountID: "acct_d", GitHubUserID: 11, AmountUnits: mustUnits(t, "20"), IdempotencyKey: "unlock-1"}
	res, err := ledger.Unlock(ctx, unlock)
	if err != nil {
		t.Fatal(err)
	}
	if res.Events[0].ReleaseAt == nil || !res.Events[0].ReleaseAt.Equal(clock.Add(168*time.Hour)) {
		t.Fatalf("release_at %v", res.Events[0].ReleaseAt)
	}
	if got := earning(day(4)); got != mustUnits(t, "40") {
		t.Fatalf("after unlock earned %d, want 40", got)
	}
	// Still locked during the cooldown, so it is neither withdrawable nor
	// stakeable again.
	pos, err := ledger.Position(ctx, "acct_d", []string{"p_d"})
	if err != nil {
		t.Fatal(err)
	}
	if pos.StakedUnits != mustUnits(t, "40") || pos.UnlockingUnits != mustUnits(t, "20") || pos.AvailableUnits != mustUnits(t, "40") {
		t.Fatalf("position during cooldown %+v", pos)
	}
	clock = clock.Add(169 * time.Hour)
	pos, err = ledger.Position(ctx, "acct_d", []string{"p_d"})
	if err != nil {
		t.Fatal(err)
	}
	if pos.UnlockingUnits != 0 || pos.AvailableUnits != mustUnits(t, "60") {
		t.Fatalf("position after cooldown %+v", pos)
	}
	// Relink: once another identity owns the provider, the old stake earns
	// nothing.
	owners["p_d"] = 99
	if got := earning(day(20)); got != 0 {
		t.Fatalf("relinked provider earned %d for the old owner", got)
	}
	if _, err := ledger.Unlock(ctx, rewards.StakeRequest{AccountID: "acct_d", GitHubUserID: 11, AmountUnits: mustUnits(t, "40.00000001"), IdempotencyKey: "unlock-2"}); !errors.Is(err, rewards.ErrStakeInsufficient) {
		t.Fatalf("over-unlock err = %v", err)
	}
}

func TestStakeLedgerIsAppendOnlyAndRoleBounded(t *testing.T) {
	fx, adminDB := startPostgres(t)
	db := openRewardsWriter(t, fx)
	ctx := context.Background()
	seedWithdrawableMALIBU(t, db, "p_e", "1")
	ledger, err := rewards.NewStakeLedger(db, 168*time.Hour, staticOwner(map[string]int64{"p_e": 1}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ledger.Lock(ctx, rewards.StakeRequest{AccountID: "acct_e", GitHubUserID: 1, OwnedProviderIDs: []string{"p_e"}, AmountUnits: mustUnits(t, "1"), IdempotencyKey: "k"}); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE malibu_stake_events SET amount_units = 1`); err == nil {
		t.Fatal("rewards_writer must not update stake events")
	}
	if _, err := db.ExecContext(ctx, `DELETE FROM malibu_stake_events`); err == nil {
		t.Fatal("rewards_writer must not delete stake events")
	}
	if _, err := adminDB.ExecContext(ctx, `UPDATE malibu_stake_events SET amount_units = 1`); err == nil {
		t.Fatal("stake events must be append-only even for the admin role")
	}
	for _, role := range []string{"stats_reader", "stats_rollup"} {
		var can bool
		if err := adminDB.QueryRowContext(ctx, `SELECT has_table_privilege($1, 'malibu_stake_events', 'SELECT')`, role).Scan(&can); err != nil {
			t.Fatal(err)
		}
		if can {
			t.Fatalf("%s must not read malibu_stake_events", role)
		}
	}
}

func TestStakeChangesAreRateLimitedPerAccount(t *testing.T) {
	fx, _ := startPostgres(t)
	db := openRewardsWriter(t, fx)
	ctx := context.Background()
	seedWithdrawableMALIBU(t, db, "p_rate", "1")
	ledger, err := rewards.NewStakeLedger(db, 168*time.Hour, staticOwner(map[string]int64{"p_rate": 3}))
	if err != nil {
		t.Fatal(err)
	}
	lock := func(i int) error {
		_, err := ledger.Lock(ctx, rewards.StakeRequest{AccountID: "acct_rate", GitHubUserID: 3, OwnedProviderIDs: []string{"p_rate"}, AmountUnits: 1, IdempotencyKey: fmt.Sprintf("k%d", i)})
		return err
	}
	for i := 0; i < 200; i++ {
		if err := lock(i); err != nil {
			t.Fatalf("lock %d: %v", i, err)
		}
	}
	if err := lock(200); !errors.Is(err, rewards.ErrStakeRateLimited) {
		t.Fatalf("lock past the daily bound err = %v", err)
	}
	// A replay of an applied key is still answered.
	if err := lock(5); err != nil {
		t.Fatalf("replay after the bound: %v", err)
	}
}

// SPEC-050-R002: ownership is re-read under the provider lock, a former
// owner's lock does not block the current owner, the staking identity is
// fixed, and unlock needs no current identity.
func TestStakeOwnershipAndIdentityRules(t *testing.T) {
	fx, _ := startPostgres(t)
	db := openRewardsWriter(t, fx)
	ctx := context.Background()
	seedWithdrawableMALIBU(t, db, "p_own", "10")
	owners := map[string]int64{"p_own": 1}
	ledger, err := rewards.NewStakeLedger(db, 168*time.Hour, staticOwner(owners))
	if err != nil {
		t.Fatal(err)
	}
	// The caller's ownership list is stale: the provider now belongs to 2.
	owners["p_own"] = 2
	if _, err := ledger.Lock(ctx, rewards.StakeRequest{AccountID: "acct_old", GitHubUserID: 1, OwnedProviderIDs: []string{"p_own"}, AmountUnits: mustUnits(t, "1"), IdempotencyKey: "stale"}); !errors.Is(err, rewards.ErrStakeNoOwnedProviders) {
		t.Fatalf("stale-ownership lock err = %v", err)
	}
	owners["p_own"] = 1
	if _, err := ledger.Lock(ctx, rewards.StakeRequest{AccountID: "acct_old", GitHubUserID: 1, OwnedProviderIDs: []string{"p_own"}, AmountUnits: mustUnits(t, "8"), IdempotencyKey: "a"}); err != nil {
		t.Fatal(err)
	}
	// Ownership moves to identity 2: the former owner's lock no longer keeps
	// the new owner from staking the provider's MALIBU.
	owners["p_own"] = 2
	if _, err := ledger.Lock(ctx, rewards.StakeRequest{AccountID: "acct_new", GitHubUserID: 2, OwnedProviderIDs: []string{"p_own"}, AmountUnits: mustUnits(t, "10"), IdempotencyKey: "b"}); err != nil {
		t.Fatalf("new owner lock: %v", err)
	}
	// Withdrawal netting stays conservative: every lock in force counts.
	bal, err := rewards.QueryAccrualBalance(ctx, db, "p_own", testEmissionConfig(time.Hour, 25, 100))
	if err != nil || bal.WithdrawableMALIBU != "0.00000000" {
		t.Fatalf("withdrawable %s err %v", bal.WithdrawableMALIBU, err)
	}
	// The staking identity of an account is fixed.
	if _, err := ledger.Lock(ctx, rewards.StakeRequest{AccountID: "acct_old", GitHubUserID: 2, OwnedProviderIDs: []string{"p_own"}, AmountUnits: 1, IdempotencyKey: "c"}); !errors.Is(err, rewards.ErrStakeIdentityChanged) {
		t.Fatalf("identity change err = %v", err)
	}
	// The former owner can still unlock with no identity on the request.
	res, err := ledger.Unlock(ctx, rewards.StakeRequest{AccountID: "acct_old", AmountUnits: mustUnits(t, "8"), IdempotencyKey: "u"})
	if err != nil || len(res.Events) != 1 || res.Events[0].GitHubUserID != 1 {
		t.Fatalf("unlock without identity %+v err %v", res, err)
	}
	if _, err := ledger.Unlock(ctx, rewards.StakeRequest{AccountID: "acct_never", AmountUnits: 1, IdempotencyKey: "u"}); !errors.Is(err, rewards.ErrStakeInsufficient) {
		t.Fatalf("unlock with no stake err = %v", err)
	}
}

func TestStakeRateBoundCountsEveryAppendedEvent(t *testing.T) {
	fx, _ := startPostgres(t)
	db := openRewardsWriter(t, fx)
	ctx := context.Background()
	seedWithdrawableMALIBU(t, db, "p_r1", "1")
	seedWithdrawableMALIBU(t, db, "p_r2", "1")
	ledger, err := rewards.NewStakeLedger(db, 168*time.Hour, staticOwner(map[string]int64{"p_r1": 4, "p_r2": 4}))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 199; i++ {
		if _, err := ledger.Lock(ctx, rewards.StakeRequest{AccountID: "acct_r", GitHubUserID: 4, OwnedProviderIDs: []string{"p_r1"}, AmountUnits: 1, IdempotencyKey: fmt.Sprintf("k%d", i)}); err != nil {
			t.Fatalf("lock %d: %v", i, err)
		}
	}
	// p_r1 has 1 MALIBU - 199 units free; this lock spans both providers and
	// would append two events, taking the account past 200.
	if _, err := ledger.Lock(ctx, rewards.StakeRequest{AccountID: "acct_r", GitHubUserID: 4, OwnedProviderIDs: []string{"p_r1", "p_r2"}, AmountUnits: mustUnits(t, "1"), IdempotencyKey: "split"}); !errors.Is(err, rewards.ErrStakeRateLimited) {
		t.Fatalf("two-event lock at 199 err = %v", err)
	}
	if _, err := ledger.Lock(ctx, rewards.StakeRequest{AccountID: "acct_r", GitHubUserID: 4, OwnedProviderIDs: []string{"p_r1"}, AmountUnits: 1, IdempotencyKey: "last"}); err != nil {
		t.Fatalf("single-event lock at 199: %v", err)
	}
}
