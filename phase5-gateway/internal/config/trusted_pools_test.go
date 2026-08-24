package config

import "testing"

const (
	testPoolA = "abcdefghijklmnopqrstuv"
	testPoolB = "ABCDEFGHIJKLMNOPQRSTUV"
	testPoolC = "0123456789abcdefghijkl"
)

func TestTrustedPoolsAuthorizes(t *testing.T) {
	tp := TrustedPoolsConfig{
		Enabled: true,
		AccountPools: map[string][]string{
			"acct_a": {testPoolA, testPoolB},
			"acct_b": {testPoolC},
		},
	}
	cases := []struct {
		account, pool string
		want          bool
	}{
		{"acct_a", testPoolA, true},
		{"acct_a", testPoolB, true},
		{"acct_a", testPoolC, false}, // not in acct_a's list (no cross-account)
		{"acct_b", testPoolC, true},
		{"acct_b", testPoolA, false},
		{"acct_unknown", testPoolA, false}, // account absent -> fail closed
		{"", testPoolA, false},             // empty account
		{"acct_a", "", false},              // empty pool
	}
	for _, tc := range cases {
		if got := tp.Authorizes(tc.account, tc.pool); got != tc.want {
			t.Errorf("Authorizes(%q,%q)=%v want %v", tc.account, tc.pool, got, tc.want)
		}
	}
	// A nil-map config authorizes nothing.
	if (TrustedPoolsConfig{Enabled: true}).Authorizes("acct_a", testPoolA) {
		t.Error("nil AccountPools authorized a pool; want fail-closed")
	}
	if (TrustedPoolsConfig{Enabled: true, CoordinatorAuthorizes: true}).Authorizes("acct_a", testPoolA) {
		t.Error("static Authorizes used coordinator_authorizes without account_pools scope")
	}
	if !(TrustedPoolsConfig{Enabled: true, CoordinatorAuthorizes: true, AccountPools: map[string][]string{"acct_a": {testPoolA}}}).Authorizes("acct_a", testPoolA) {
		t.Error("static Authorizes rejected locally scoped account/pool pair")
	}
	if (TrustedPoolsConfig{Enabled: true, CoordinatorAuthorizes: true}).Authorizes("acct_a", "pool.one") {
		t.Error("static Authorizes accepted a non-canonical pool id")
	}
	if (TrustedPoolsConfig{Enabled: true, CoordinatorAuthorizes: true}).Authorizes("acct_a", "poolone") {
		t.Error("static Authorizes accepted a short non-derived pool id")
	}
	if (TrustedPoolsConfig{Enabled: true, CoordinatorAuthorizes: true}).Authorizes("", testPoolA) {
		t.Error("static Authorizes accepted an empty account")
	}
	if (TrustedPoolsConfig{Enabled: true, CoordinatorAuthorizes: true}).Authorizes("acct_a", "") {
		t.Error("static Authorizes accepted an empty pool")
	}
}

func TestValidateTrustedPoolsConfig(t *testing.T) {
	base := func(tp TrustedPoolsConfig) Config {
		c := Default()
		c.Features.TrustedPools = tp
		return c
	}

	t.Run("disabled is inert even with junk", func(t *testing.T) {
		cfg := base(TrustedPoolsConfig{Enabled: false, AccountPools: map[string][]string{
			"": {"\x01bad"}, // not validated while disabled
		}})
		if err := validateTrustedPoolsConfig(cfg); err != nil {
			t.Fatalf("disabled config rejected: %v", err)
		}
	})

	t.Run("enabled accepts base64url ids", func(t *testing.T) {
		cfg := base(TrustedPoolsConfig{Enabled: true, AccountPools: map[string][]string{
			"acct_a": {testPoolA},
		}})
		if err := validateTrustedPoolsConfig(cfg); err != nil {
			t.Fatalf("valid config rejected: %v", err)
		}
	})

	t.Run("coordinator authorizes may boot with empty static map fail closed", func(t *testing.T) {
		cfg := base(TrustedPoolsConfig{Enabled: true, CoordinatorAuthorizes: true})
		if err := validateTrustedPoolsConfig(cfg); err != nil {
			t.Fatalf("coordinator-authorized config rejected: %v", err)
		}
	})

	t.Run("enabled rejects empty account id", func(t *testing.T) {
		cfg := base(TrustedPoolsConfig{Enabled: true, AccountPools: map[string][]string{
			"  ": {testPoolA},
		}})
		if err := validateTrustedPoolsConfig(cfg); err == nil {
			t.Fatal("empty account id accepted")
		}
	})

	t.Run("enabled rejects empty pool id", func(t *testing.T) {
		cfg := base(TrustedPoolsConfig{Enabled: true, AccountPools: map[string][]string{
			"acct_a": {""},
		}})
		if err := validateTrustedPoolsConfig(cfg); err == nil {
			t.Fatal("empty pool id accepted")
		}
	})

	t.Run("enabled rejects header-unsafe pool id (spill guard)", func(t *testing.T) {
		// A control byte would be dropped to empty by the coordinator's opaque
		// header sanitizer and routed as GLOBAL — a silent pool->global spill.
		cfg := base(TrustedPoolsConfig{Enabled: true, AccountPools: map[string][]string{
			"acct_a": {"pool\x01id"},
		}})
		if err := validateTrustedPoolsConfig(cfg); err == nil {
			t.Fatal("header-unsafe pool id accepted")
		}
	})

	t.Run("enabled rejects header-safe but non-base64url pool id", func(t *testing.T) {
		// "pool.id" / "pool+id" pass the header-safety check (printable ASCII)
		// but are outside the base64url alphabet, so they cannot be a canonical
		// SPEC-042-R001 pool_id. This case fails ONLY because of the base64url
		// shape check, not PoolIDHeaderSafe.
		for _, bad := range []string{"pool.id", "pool+id", "pool one", "pool/id"} {
			cfg := base(TrustedPoolsConfig{Enabled: true, AccountPools: map[string][]string{
				"acct_a": {bad},
			}})
			if err := validateTrustedPoolsConfig(cfg); err == nil {
				t.Fatalf("non-base64url pool id %q accepted", bad)
			}
		}
	})

	t.Run("enabled rejects base64url but short pool id", func(t *testing.T) {
		cfg := base(TrustedPoolsConfig{Enabled: true, AccountPools: map[string][]string{
			"acct_a": {"poolone"},
		}})
		if err := validateTrustedPoolsConfig(cfg); err == nil {
			t.Fatal("short non-derived pool id accepted")
		}
	})
}

func TestPoolIDHeaderSafe(t *testing.T) {
	if !PoolIDHeaderSafe(testPoolA) {
		t.Error("base64url id rejected")
	}
	if PoolIDHeaderSafe("") {
		t.Error("empty accepted")
	}
	if PoolIDHeaderSafe("pool\x01id") {
		t.Error("C0 control byte accepted")
	}
	if PoolIDHeaderSafe("pool\x9bid") {
		t.Error("C1 control byte accepted")
	}
	long := make([]byte, 129)
	for i := range long {
		long[i] = 'a'
	}
	if PoolIDHeaderSafe(string(long)) {
		t.Error("over-128-byte id accepted")
	}
}
