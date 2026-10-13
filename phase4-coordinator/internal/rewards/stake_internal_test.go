package rewards

import (
	"errors"
	"reflect"
	"testing"
)

func TestParseMALIBUUnits(t *testing.T) {
	cases := map[string]int64{
		"1":           MALIBUUnitsPerToken,
		"0.00000001":  1,
		"12.5":        1_250_000_000,
		"10000000000": MaxStakeAmountUnits,
	}
	for raw, want := range cases {
		got, err := ParseMALIBUUnits(raw)
		if err != nil || got != want {
			t.Fatalf("ParseMALIBUUnits(%q) = %d, %v; want %d", raw, got, err, want)
		}
		if back, _ := ParseMALIBUUnits(FormatMALIBUUnits(got)); back != got {
			t.Fatalf("round trip %q -> %q", raw, FormatMALIBUUnits(got))
		}
	}
	for _, bad := range []string{"", "0", "0.0", "-1", "1.123456789", "01", "1e3", " 1", "10000000001", "99999999999", "1."} {
		if _, err := ParseMALIBUUnits(bad); !errors.Is(err, ErrStakeInvalidAmount) {
			t.Fatalf("ParseMALIBUUnits(%q) err = %v, want ErrStakeInvalidAmount", bad, err)
		}
	}
	if got := FormatMALIBUUnits(150_000_001); got != "1.50000001" {
		t.Fatalf("FormatMALIBUUnits = %q", got)
	}
}

func TestAllocateStakeIsAllOrNothingInOrder(t *testing.T) {
	slices := []stakeSlice{{"a", 5}, {"b", 0}, {"c", -3}, {"d", 10}}
	got, err := allocateStake(slices, 12)
	if err != nil {
		t.Fatal(err)
	}
	want := []stakeSlice{{"a", 5}, {"d", 7}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("allocation %v, want %v", got, want)
	}
	if got, err := allocateStake(slices, 16); !errors.Is(err, ErrStakeInsufficient) || got != nil {
		t.Fatalf("over-allocation = %v, %v; want nil, ErrStakeInsufficient", got, err)
	}
}

// SPEC-050-R004: maturity, unlock, relink, and per-provider single counting.
func TestComputeEarningStakes(t *testing.T) {
	const gh1, gh2 = 101, 202
	t.Run("matured lock minus unlocks", func(t *testing.T) {
		rows := []stakeEarningRow{{AccountID: "acct1", ProviderID: "p1", GitHubUserID: gh1, MaturedLock: 100, Unlocked: 30}}
		got := computeEarningStakes(rows, map[string]int64{"p1": 1000}, map[string]int64{"p1": gh1})
		if !reflect.DeepEqual(got, []AccountStake{{"acct1", gh1, 70}}) {
			t.Fatalf("got %v", got)
		}
	})
	t.Run("unlock beyond matured earns nothing", func(t *testing.T) {
		rows := []stakeEarningRow{{AccountID: "acct1", ProviderID: "p1", GitHubUserID: gh1, MaturedLock: 10, Unlocked: 30}}
		if got := computeEarningStakes(rows, map[string]int64{"p1": 1000}, map[string]int64{"p1": gh1}); len(got) != 0 {
			t.Fatalf("got %v", got)
		}
	})
	t.Run("relinked provider earns nothing for the old owner", func(t *testing.T) {
		rows := []stakeEarningRow{{AccountID: "acct1", ProviderID: "p1", GitHubUserID: gh1, MaturedLock: 100}}
		if got := computeEarningStakes(rows, map[string]int64{"p1": 1000}, map[string]int64{"p1": gh2}); len(got) != 0 {
			t.Fatalf("got %v", got)
		}
		if got := computeEarningStakes(rows, map[string]int64{"p1": 1000}, map[string]int64{}); len(got) != 0 {
			t.Fatalf("unowned provider: got %v", got)
		}
	})
	t.Run("provider MALIBU counted once across accounts", func(t *testing.T) {
		rows := []stakeEarningRow{
			{AccountID: "acct1", ProviderID: "p1", GitHubUserID: gh1, MaturedLock: 80},
			{AccountID: "acct2", ProviderID: "p1", GitHubUserID: gh1, MaturedLock: 80},
		}
		got := computeEarningStakes(rows, map[string]int64{"p1": 100}, map[string]int64{"p1": gh1})
		total := int64(0)
		for _, s := range got {
			total += s.Units
		}
		if total != 100 {
			t.Fatalf("total earning %d across accounts, want capped at 100 (%v)", total, got)
		}
	})
	t.Run("withdrawable decrease caps earning", func(t *testing.T) {
		rows := []stakeEarningRow{{AccountID: "acct1", ProviderID: "p1", GitHubUserID: gh1, MaturedLock: 500}}
		got := computeEarningStakes(rows, map[string]int64{"p1": 40}, map[string]int64{"p1": gh1})
		if !reflect.DeepEqual(got, []AccountStake{{"acct1", gh1, 40}}) {
			t.Fatalf("got %v", got)
		}
	})
	t.Run("sums providers per account", func(t *testing.T) {
		rows := []stakeEarningRow{
			{AccountID: "acct1", ProviderID: "p1", GitHubUserID: gh1, MaturedLock: 10},
			{AccountID: "acct1", ProviderID: "p2", GitHubUserID: gh1, MaturedLock: 15},
		}
		got := computeEarningStakes(rows, map[string]int64{"p1": 100, "p2": 100}, map[string]int64{"p1": gh1, "p2": gh1})
		if !reflect.DeepEqual(got, []AccountStake{{"acct1", gh1, 25}}) {
			t.Fatalf("got %v", got)
		}
	})
}

func TestStakeRequestDigestBindsKindAndAmount(t *testing.T) {
	req := StakeRequest{AccountID: "a", GitHubUserID: 1, AmountUnits: 5}
	if stakeRequestDigest("lock", req) == stakeRequestDigest("unlock", req) {
		t.Fatal("lock and unlock digests must differ")
	}
	other := req
	other.AmountUnits = 6
	if stakeRequestDigest("lock", req) == stakeRequestDigest("lock", other) {
		t.Fatal("digest must bind the amount")
	}
}
