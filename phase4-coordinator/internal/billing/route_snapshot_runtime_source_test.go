package billing

import (
	"strings"
	"testing"
)

// SPEC-022-R012.1 (v0.2.0): runtime_source, pool_generation, and
// pool_operator_account_id bind into the digest only when runtime_source is
// non-empty, so global and native-pool digests stay byte-identical.
func externalRuntimeRouteSnapshot() RouteSnapshot {
	r := testRouteSnapshot()
	r.PoolID = "pool-abc"
	r.ManifestVersion = 2
	r.ManifestCoreDigest = strings.Repeat("d", 64)
	return r
}

func TestRouteSnapshotRuntimeSourceDigestedOnlyWhenPresent(t *testing.T) {
	global, _, err := testRouteSnapshot().Digest()
	if err != nil || global != goldenGlobalRouteSnapshotDigest {
		t.Fatalf("poolless digest=%s err=%v, want golden %s", global, err, goldenGlobalRouteSnapshotDigest)
	}
	native := externalRuntimeRouteSnapshot()
	nativeDigest, _, err := native.Digest()
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"runtime_source", "pool_generation", "pool_operator_account_id"} {
		if _, ok := native.Value()[key]; ok {
			t.Fatalf("native pool snapshot must not carry %s", key)
		}
	}
	external := externalRuntimeRouteSnapshot()
	external.RuntimeSource = "llamacpp_loopback"
	external.PoolGeneration = 7
	external.PoolOperatorAccountID = "creator-a"
	externalDigest, _, err := external.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if externalDigest == nativeDigest {
		t.Fatal("R012 members must bind the digest")
	}
	value := external.Value()
	if value["runtime_source"] != "llamacpp_loopback" || value["pool_generation"] != int64(7) || value["pool_operator_account_id"] != "creator-a" {
		t.Fatalf("external snapshot value=%#v", value)
	}
	for name, mutate := range map[string]func(*RouteSnapshot){
		"generation": func(r *RouteSnapshot) { r.PoolGeneration = 8 },
		"operator":   func(r *RouteSnapshot) { r.PoolOperatorAccountID = "creator-b" },
		"runtime":    func(r *RouteSnapshot) { r.RuntimeSource = "ollama_loopback" },
	} {
		changed := external
		mutate(&changed)
		if d, _, err := changed.Digest(); err != nil || d == externalDigest {
			t.Errorf("%s change did not move the digest (err=%v)", name, err)
		}
	}
}

func TestRouteSnapshotRuntimeSourceValidateFailsClosed(t *testing.T) {
	valid := externalRuntimeRouteSnapshot()
	valid.RuntimeSource = "llamacpp_loopback"
	valid.PoolGeneration = 7
	valid.PoolOperatorAccountID = "creator-a"
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid external snapshot: %v", err)
	}
	for name, mutate := range map[string]func(*RouteSnapshot){
		"native runtime class":      func(r *RouteSnapshot) { r.RuntimeSource = "mlx_cache" },
		"no pool_id":                func(r *RouteSnapshot) { r.PoolID = ""; r.ManifestVersion = 0; r.ManifestCoreDigest = "" },
		"no manifest labels":        func(r *RouteSnapshot) { r.ManifestVersion = 0; r.ManifestCoreDigest = "" },
		"no generation":             func(r *RouteSnapshot) { r.PoolGeneration = 0 },
		"no operator account":       func(r *RouteSnapshot) { r.PoolOperatorAccountID = "" },
		"generation without source": func(r *RouteSnapshot) { r.RuntimeSource = "" },
	} {
		bad := valid
		mutate(&bad)
		if err := bad.Validate(); err == nil {
			t.Errorf("%s: invalid external snapshot validated", name)
		}
	}
}
