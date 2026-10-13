package billing

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

type fakeAllowanceSource struct {
	stakes []AllowanceStake
	err    error
	calls  int
}

func (f *fakeAllowanceSource) Name() string { return "fake_source" }

func (f *fakeAllowanceSource) EarningStakes(context.Context, time.Time, time.Duration) ([]AllowanceStake, error) {
	f.calls++
	return f.stakes, f.err
}

func malibu(n int64) int64 { return n * AllowanceUnitsPerMALIBU }

func testAllowancePolicy() AllowancePolicy {
	return AllowancePolicy{DailyBudgetCredits: 1_000_000, CreditsPerMALIBU: 1000, PerAccountDailyCapCredits: 250_000, MinStakeAge: 24 * time.Hour}
}

// SPEC-050-R005: rate, per-account cap, floor, and budget pro rata.
func TestComputeAllowanceGrantsRateCapAndProRata(t *testing.T) {
	policy := testAllowancePolicy()
	t.Run("under budget grants raw", func(t *testing.T) {
		grants, totals := ComputeAllowanceGrants([]AllowanceStake{
			{"b", malibu(100)},
			{"a", malibu(1000) + 12_345}, // fraction of a MALIBU floors away
			{"c", malibu(10_000)},        // capped at 250,000
			{"d", 0},
			{"e", 99_999}, // under one credit
		}, policy)
		want := []AllowanceGrant{
			{"a", malibu(1000) + 12_345, 250_000, 250_000},
			{"b", malibu(100), 100_000, 100_000},
			{"c", malibu(10_000), 250_000, 250_000},
		}
		if !reflect.DeepEqual(grants, want) {
			t.Fatalf("grants %+v\nwant %+v", grants, want)
		}
		if totals.TotalRawCredits != 600_000 || totals.TotalGrantedCredits != 600_000 || totals.ScalePPM != 1_000_000 {
			t.Fatalf("totals %+v", totals)
		}
	})
	t.Run("over budget scales pro rata with floor", func(t *testing.T) {
		policy := policy
		policy.DailyBudgetCredits = 100_000
		grants, totals := ComputeAllowanceGrants([]AllowanceStake{{"a", malibu(100)}, {"b", malibu(200)}}, policy)
		// raw 100,000 + 200,000 = 300,000; scale = 1/3.
		if grants[0].GrantedCredits != 33_333 || grants[1].GrantedCredits != 66_666 {
			t.Fatalf("grants %+v", grants)
		}
		if totals.TotalGrantedCredits > policy.DailyBudgetCredits || totals.ScalePPM != 333_333 {
			t.Fatalf("totals %+v", totals)
		}
	})
	t.Run("zero budget grants nothing", func(t *testing.T) {
		policy := policy
		policy.DailyBudgetCredits = 0
		grants, totals := ComputeAllowanceGrants([]AllowanceStake{{"a", malibu(100)}}, policy)
		if len(grants) != 1 || grants[0].GrantedCredits != 0 || totals.TotalGrantedCredits != 0 || totals.ScalePPM != 0 {
			t.Fatalf("grants %+v totals %+v", grants, totals)
		}
	})
	t.Run("huge stakes do not overflow", func(t *testing.T) {
		policy := AllowancePolicy{DailyBudgetCredits: 1 << 50, CreditsPerMALIBU: 1 << 40, PerAccountDailyCapCredits: 1 << 62}
		grants, totals := ComputeAllowanceGrants([]AllowanceStake{{"a", 1 << 62}, {"b", 1 << 62}}, policy)
		if totals.TotalGrantedCredits > policy.DailyBudgetCredits || grants[0].GrantedCredits <= 0 {
			t.Fatalf("grants %+v totals %+v", grants, totals)
		}
	})
}

// SPEC-050-R005/R006: one run per UTC day, recorded atomically, never
// changed by a second run.
func TestRefreshAllowanceDayIsIdempotentPerAccountDay(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 0, 0, 30, 0, time.UTC)
	src := &fakeAllowanceSource{stakes: []AllowanceStake{{"acct_a", malibu(100)}, {"acct_b", malibu(50)}}}
	created, totals, err := store.RefreshAllowanceDay(ctx, now, src, testAllowancePolicy())
	if err != nil || !created || totals.TotalGrantedCredits != 150_000 {
		t.Fatalf("first run created=%v totals=%+v err=%v", created, totals, err)
	}
	// A later run on the same day with a different stake changes nothing,
	// and does not even ask the source.
	src.stakes = []AllowanceStake{{"acct_a", malibu(200)}, {"acct_c", malibu(5)}}
	created, _, err = store.RefreshAllowanceDay(ctx, now.Add(10*time.Hour), src, testAllowancePolicy())
	if err != nil || created || src.calls != 1 {
		t.Fatalf("second run created=%v calls=%d err=%v", created, src.calls, err)
	}
	for account, want := range map[string]int64{"acct_a": 100_000, "acct_b": 50_000, "acct_c": 0} {
		got, err := store.AllowanceGrantFor(ctx, account, now)
		if err != nil || got != want {
			t.Fatalf("%s grant %d err %v, want %d", account, got, err, want)
		}
	}
	// Next day: a new run, no rollover.
	created, _, err = store.RefreshAllowanceDay(ctx, now.Add(24*time.Hour), src, testAllowancePolicy())
	if err != nil || !created {
		t.Fatalf("next day created=%v err=%v", created, err)
	}
	if got, _ := store.AllowanceGrantFor(ctx, "acct_a", now.Add(24*time.Hour)); got != 200_000 {
		t.Fatalf("next day acct_a grant %d", got)
	}
	if got, _ := store.AllowanceGrantFor(ctx, "acct_b", now.Add(24*time.Hour)); got != 0 {
		t.Fatalf("next day acct_b rolled over %d", got)
	}
	var runs int
	var stakeSource string
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*), MIN(stake_source) FROM allowance_refresh_runs`).Scan(&runs, &stakeSource); err != nil || runs != 2 || stakeSource != "fake_source" {
		t.Fatalf("runs=%d source=%q err=%v", runs, stakeSource, err)
	}
}

func TestRefreshAllowanceDayRecordsNothingWhenSourceFails(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 1, 0, 0, 0, time.UTC)
	if _, _, err := store.RefreshAllowanceDay(ctx, now, nil, testAllowancePolicy()); !errors.Is(err, ErrAllowanceStakeSourceUnavailable) {
		t.Fatalf("nil source err = %v", err)
	}
	src := &fakeAllowanceSource{err: errors.New("postgres down")}
	if _, _, err := store.RefreshAllowanceDay(ctx, now, src, testAllowancePolicy()); err == nil {
		t.Fatal("source failure must surface")
	}
	src.err, src.stakes = nil, []AllowanceStake{{"acct_a", malibu(1)}}
	created, _, err := store.RefreshAllowanceDay(ctx, now, src, testAllowancePolicy())
	if err != nil || !created {
		t.Fatalf("retry created=%v err=%v", created, err)
	}
}

func TestAllowanceAuditTablesAreAppendOnly(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 1, 0, 0, 0, time.UTC)
	if _, _, err := store.RefreshAllowanceDay(ctx, now, &fakeAllowanceSource{stakes: []AllowanceStake{{"acct_a", malibu(1)}}}, testAllowancePolicy()); err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`UPDATE allowance_grants SET granted_credits = 999`,
		`DELETE FROM allowance_grants`,
		`UPDATE allowance_refresh_runs SET budget_credits = 1`,
		`DELETE FROM allowance_refresh_runs`,
	} {
		if _, err := store.db.ExecContext(ctx, stmt); err == nil {
			t.Fatalf("%q must be refused", stmt)
		}
	}
}

func TestNextAllowanceRefreshIsNextUTCMidnight(t *testing.T) {
	got := NextAllowanceRefresh(time.Date(2026, 10, 13, 23, 59, 59, 0, time.FixedZone("x", -5*3600)))
	if want := time.Date(2026, 10, 15, 0, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Fatalf("got %v want %v", got, want)
	}
}
