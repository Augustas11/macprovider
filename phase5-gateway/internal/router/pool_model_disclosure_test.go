package router

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// SPEC-006-R018 (#1816): the pool-model disclosure headers survive the
// X-MacProvider-* strip only as the exact literal / 64 lowercase hex.
func TestPoolModelDisclosureHeadersAllowlisted(t *testing.T) {
	digest := strings.Repeat("d", 64)
	for name, tc := range map[string]struct {
		disclosure, digest         string
		wantDisclosure, wantDigest string
	}{
		"valid":            {"pool_attested_unverified", digest, "pool_attested_unverified", digest},
		"bad disclosure":   {"network_verified", digest, "", digest},
		"uppercase digest": {"pool_attested_unverified", strings.ToUpper(digest), "pool_attested_unverified", ""},
		"short digest":     {"pool_attested_unverified", "abc", "pool_attested_unverified", ""},
		"injected":         {"pool_attested_unverified\r\nX-Evil: 1", digest + "\r\n", "", ""},
	} {
		dst := http.Header{}
		copyCleanHeaders(dst, http.Header{
			poolModelDisclosureResponseHeader:    []string{tc.disclosure},
			poolManifestCoreDigestResponseHeader: []string{tc.digest},
		})
		if got := dst.Get(poolModelDisclosureResponseHeader); got != tc.wantDisclosure {
			t.Errorf("%s: disclosure=%q want %q", name, got, tc.wantDisclosure)
		}
		if got := dst.Get(poolManifestCoreDigestResponseHeader); got != tc.wantDigest {
			t.Errorf("%s: digest=%q want %q", name, got, tc.wantDigest)
		}
	}
	// Any other X-MacProvider-* header is still stripped.
	dst := http.Header{}
	copyCleanHeaders(dst, http.Header{"X-MacProvider-Pool-Secret": []string{"x"}})
	if len(dst) != 0 {
		t.Fatalf("strip regressed: %v", dst)
	}
}

// SPEC-006-R018: a pool/ model id survives /v1/models sanitization only with
// its closed pool-model object in that pool's view; the default view drops it.
func TestSanitizeModelsResponsePoolView(t *testing.T) {
	poolID := "QpsclmzwdJaWJTk3zowcXQ"
	modelID := "pool/" + poolID + "/creator-model"
	build := func() map[string]any {
		raw := `{"object":"list","data":[{"id":"model-a","object":"model","owned_by":"macprovider","created":1},` +
			`{"id":"` + modelID + `","object":"model","owned_by":"macprovider","created":1,"macprovider_pool_model":{` +
			`"pool_id":"` + poolID + `","pool_model_id":"` + modelID + `","disclosure_class":"pool_attested_unverified",` +
			`"disclosure_text":"Pool-attested, not network-verified","runtime_sources":["mlx_cache"],` +
			`"artifact_hash_algorithm":"macprovider.snapshot-manifest.v1","artifact_hash":"` + strings.Repeat("a", 64) + `",` +
			`"max_context_tokens":8192,"price":{"prompt_rate_per_mtok":1,"prompt_cache_hit_rate_per_mtok":1,"completion_rate_per_mtok":2,"global_multiplier_ppm":1000000},` +
			`"price_source":"pool_creator_signed","manifest_version":5,"manifest_core_digest":"` + strings.Repeat("d", 64) + `"}}]}`
		var body map[string]any
		if err := json.Unmarshal([]byte(raw), &body); err != nil {
			t.Fatal(err)
		}
		return body
	}
	ids := func(body map[string]any) []string {
		var out []string
		for _, item := range body["data"].([]any) {
			out = append(out, item.(map[string]any)["id"].(string))
		}
		return out
	}
	global := build()
	sanitizeModelsResponse(global, "")
	if got := ids(global); len(got) != 1 || got[0] != "model-a" {
		t.Fatalf("default view ids = %v", got)
	}
	view := build()
	sanitizeModelsResponse(view, poolID)
	got := ids(view)
	if len(got) != 2 {
		t.Fatalf("pool view ids = %v", got)
	}
	other := build()
	sanitizeModelsResponse(other, "AAAAAAAAAAAAAAAAAAAAAA")
	if got := ids(other); len(got) != 1 {
		t.Fatalf("other pool's view kept the pool model: %v", got)
	}
}
