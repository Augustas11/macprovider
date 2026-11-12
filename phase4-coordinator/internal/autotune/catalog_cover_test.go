package autotune_test

import (
	"reflect"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
)

func coverCatalogJSON(rows string) string {
	return `{"version":"v","source":"operator_curated_autotune_candidate_catalog","rows":` + rows + `}`
}

func TestParseCatalogRejectsInvalidDocuments(t *testing.T) {
	t.Parallel()
	row := func(extra string) string {
		return coverCatalogJSON(`{"k":{"model_id":"m","min_ram_gb":4` + extra + `}}`)
	}
	cases := map[string]struct{ raw, want string }{
		"empty":        {"", "empty"},
		"bad json":     {"{", "parse"},
		"bad source":   {`{"version":"v","source":"x","rows":{"k":{"model_id":"m"}}}`, "source"},
		"no version":   {`{"source":"operator_curated_autotune_candidate_catalog","rows":{"k":{"model_id":"m"}}}`, "version"},
		"no rows":      {coverCatalogJSON(`{}`), "rows are required"},
		"blank key":    {coverCatalogJSON(`{"  ":{"model_id":"m"}}`), "row key"},
		"no model id":  {coverCatalogJSON(`{"k":{"model_id":" "}}`), "model_id is required"},
		"negative ram": {coverCatalogJSON(`{"k":{"model_id":"m","min_ram_gb":-1}}`), "min_ram_gb"},
		"negative tps": {row(`,"bench_gate":{"min_sustained_tps":-1}`), "min_sustained_tps"},
		"negative ttf": {row(`,"bench_gate":{"max_4k_ttft_ms":-5}`), "max_4k_ttft_ms"},
	}
	for name, tc := range cases {
		_, err := autotune.ParseCatalog([]byte(tc.raw))
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want containing %q", name, err, tc.want)
		}
	}
}

func TestParseCatalogDefaultsPolicyVersionAndCopiesRaw(t *testing.T) {
	t.Parallel()
	raw := []byte(coverCatalogJSON(`{"k":{"model_id":"M"}}`))
	c, err := autotune.ParseCatalog(raw)
	if err != nil {
		t.Fatal(err)
	}
	if c.PolicyVersion != "legacy-spec-023" {
		t.Fatalf("PolicyVersion = %q", c.PolicyVersion)
	}
	raw[0] = 'X'
	if string(c.RawJSON[0]) != "{" {
		t.Fatal("RawJSON aliases the caller's buffer")
	}
}

func TestCatalogKeysSortedAndNilSafe(t *testing.T) {
	t.Parallel()
	c := mustCatalog(t, coverCatalogJSON(`{"b":{"model_id":"m1"},"a":{"model_id":"m2"},"c":{"model_id":"m3"}}`))
	if got := c.Keys(); !reflect.DeepEqual(got, []string{"a", "b", "c"}) {
		t.Fatalf("Keys = %v", got)
	}
	var nilCat *autotune.Catalog
	if nilCat.Keys() != nil {
		t.Fatal("nil catalog Keys should be nil")
	}
	if _, ok := nilCat.Row("a"); ok {
		t.Fatal("nil catalog Row should miss")
	}
	if _, _, ok := nilCat.HighestClaimedTier("m1"); ok {
		t.Fatal("nil catalog HighestClaimedTier should miss")
	}
}

func TestNormalizeModelIDTrimsAndLowercases(t *testing.T) {
	t.Parallel()
	if got := autotune.NormalizeModelID("  Org/Model-4BIT \n"); got != "org/model-4bit" {
		t.Fatalf("got %q", got)
	}
}

func TestHighestClaimedTierPicksLargestRAMThenSmallestKey(t *testing.T) {
	t.Parallel()
	c := mustCatalog(t, coverCatalogJSON(`{
		"z-big":{"model_id":"Org/M","min_ram_gb":32},
		"a-big":{"model_id":"org/m","min_ram_gb":32},
		"small":{"model_id":"ORG/M","min_ram_gb":8},
		"direct":{"model_id":"other","min_ram_gb":1}}`))
	key, row, ok := c.HighestClaimedTier(" Org/M ")
	if !ok || key != "a-big" || row.MinRAMGB != 32 {
		t.Fatalf("got %q %+v %v", key, row, ok)
	}
	// A row key equal to the normalized id wins even when other rows share the model.
	key, _, ok = c.HighestClaimedTier("direct")
	if !ok || key != "direct" {
		t.Fatalf("direct lookup got %q %v", key, ok)
	}
	if _, _, ok := c.HighestClaimedTier("unknown"); ok {
		t.Fatal("unknown model should miss")
	}
}

func TestRowIdentityAndPolicyEquivalence(t *testing.T) {
	t.Parallel()
	base := `"model_id":"m","min_ram_gb":4`
	plain := mustCatalog(t, coverCatalogJSON(`{"k":{`+base+`}}`))
	nullPolicy := mustCatalog(t, coverCatalogJSON(`{"k":{`+base+`,"draft_candidates":null,"workload_profiles":null}}`))
	drafts := mustCatalog(t, coverCatalogJSON(`{"k":{`+base+`,"draft_candidates":[{"draft_model":"d","draft_model_artifact_sha256":"ab"}]}}`))
	drafts2 := mustCatalog(t, coverCatalogJSON(`{"k":{`+base+`,"draft_candidates":[{"draft_model":"d","draft_model_artifact_sha256":"cd"}]}}`))
	profiles := mustCatalog(t, coverCatalogJSON(`{"k":{`+base+`,"workload_profiles":{"chat":{"c":{"status":"ok","no_winner_reason":"r","candidate_source":"s","source":"x",
		"recommended":{"kv_bits":4,"max_context_override":8,"max_concurrency_override":2,"draft_model":"d","draft_model_artifact_sha256":"ab","num_draft_tokens":3},
		"gate_policy":{"min_samples":3,"max_p95_ttft_ms":10,"max_stop_token_leak_rate":0.1,"min_median_tps":5},
		"profile_metrics":{"median_tps":6,"sample_count":4}}}}}}`))

	if !plain.PolicyEquivalent("k", nullPolicy, "k") {
		t.Error("omitted and null policy must be equivalent")
	}
	idPlain, _ := plain.RowIdentity("k")
	idNull, _ := nullPolicy.RowIdentity("k")
	if idPlain != idNull {
		t.Error("identity differs between omitted and null policy")
	}
	if plain.PolicyEquivalent("k", drafts, "k") {
		t.Error("draft candidates must change policy")
	}
	if drafts.PolicyEquivalent("k", drafts2, "k") {
		t.Error("different draft artifact digest must change policy")
	}
	if !drafts.PolicyEquivalent("k", drafts, "k") {
		t.Error("same policy must be equivalent")
	}
	idDrafts, _ := drafts.RowIdentity("k")
	idDrafts2, _ := drafts2.RowIdentity("k")
	idProfiles, ok := profiles.RowIdentity("k")
	if !ok || idProfiles == idPlain || idDrafts == idPlain || idDrafts == idDrafts2 {
		t.Errorf("policy must be bound into identity: %v %v %v %v", idPlain, idDrafts, idDrafts2, idProfiles)
	}
	if plain.PolicyEquivalent("missing", plain, "k") || plain.PolicyEquivalent("k", plain, "missing") {
		t.Error("missing rows are never equivalent")
	}
	if _, ok := plain.RowIdentity("missing"); ok {
		t.Error("missing row has no identity")
	}
}

func TestRowIdentityRejectsMalformedPolicy(t *testing.T) {
	t.Parallel()
	base := `"model_id":"m","min_ram_gb":4`
	for _, extra := range []string{
		`"draft_candidates":"nope"`,
		`"workload_profiles":[1]`,
	} {
		c := mustCatalog(t, coverCatalogJSON(`{"k":{`+base+`,`+extra+`}}`))
		if id, ok := c.RowIdentity("k"); ok || id != "" {
			t.Errorf("%s: malformed policy must yield no identity, got %q %v", extra, id, ok)
		}
		if c.PolicyEquivalent("k", c, "k") {
			t.Errorf("%s: malformed policy must not be equivalent", extra)
		}
		good := mustCatalog(t, coverCatalogJSON(`{"k":{`+base+`}}`))
		if good.PolicyEquivalent("k", c, "k") || c.PolicyEquivalent("k", good, "k") {
			t.Errorf("%s: malformed policy on either side must not be equivalent", extra)
		}
	}
}

func TestIsPermanentlyRejectedReleaseID(t *testing.T) {
	t.Parallel()
	if !autotune.IsPermanentlyRejectedReleaseID("published-2026-07-07-p2-qwen3-8b") {
		t.Error("known rejected id not rejected")
	}
	if autotune.IsPermanentlyRejectedReleaseID("published-2026-07-07-p2-qwen3-8b-x") || autotune.IsPermanentlyRejectedReleaseID("") {
		t.Error("unrelated id rejected")
	}
}
