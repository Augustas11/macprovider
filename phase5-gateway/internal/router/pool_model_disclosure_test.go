package router

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func poolModelDisclosureHeaders() http.Header {
	return http.Header{
		poolModelDisclosureResponseHeader:    []string{poolModelDisclosureClass},
		poolManifestCoreDigestResponseHeader: []string{strings.Repeat("d", 64)},
	}
}

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

func TestPoolModelDisclosureHeadersStrippedWhenRouteContextDoesNotAllowThem(t *testing.T) {
	for name, copyFn := range map[string]func(http.Header, http.Header){
		"clean":            copyCleanHeadersWithoutPoolModelDisclosure,
		"receipt eligible": copyReceiptEligibleHeadersWithoutPoolModelDisclosure,
	} {
		dst := poolModelDisclosureHeaders()
		copyFn(dst, poolModelDisclosureHeaders())
		if got := dst.Get(poolModelDisclosureResponseHeader); got != "" {
			t.Fatalf("%s copied pool disclosure %q without served pool-model context", name, got)
		}
		if got := dst.Get(poolManifestCoreDigestResponseHeader); got != "" {
			t.Fatalf("%s copied pool digest %q without served pool-model context", name, got)
		}
	}
}

// SPEC-006-R018: a pool/ model id survives /v1/models sanitization only with
// its closed pool-model object in that pool's view; the default view drops it.
func TestSanitizeModelsResponsePoolView(t *testing.T) {
	poolID := "QpsclmzwdJaWJTk3zowcXQ"
	otherPoolID := "AAAAAAAAAAAAAAAAAAAAAA"
	modelID := "pool/" + poolID + "/creator-model"
	otherModelID := "pool/" + otherPoolID + "/creator-model"
	build := func(mutators ...func(map[string]any)) map[string]any {
		raw := `{"object":"list","data":[{"id":"model-a","object":"model","owned_by":"macprovider","created":1},` +
			`{"id":"class/a","object":"model","owned_by":"macprovider","created":1},` +
			`{"id":"` + modelID + `","object":"model","owned_by":"macprovider","created":1,"macprovider_pool_model":{` +
			`"pool_id":"` + poolID + `","pool_model_id":"` + modelID + `","disclosure_class":"pool_attested_unverified",` +
			`"disclosure_text":"Pool-attested, not network-verified","runtime_sources":["mlx_cache"],` +
			`"artifact_hash_algorithm":"macprovider.snapshot-manifest.v1","artifact_hash":"` + strings.Repeat("a", 64) + `",` +
			`"max_context_tokens":8192,"price":{"prompt_rate_per_mtok":1,"prompt_cache_hit_rate_per_mtok":1,"completion_rate_per_mtok":2,"global_multiplier_ppm":1000000},` +
			`"price_source":"pool_creator_signed","manifest_version":5,"manifest_core_digest":"` + strings.Repeat("d", 64) + `"}},` +
			`{"id":"` + otherModelID + `","object":"model","owned_by":"macprovider","created":1,"macprovider_pool_model":{` +
			`"pool_id":"` + otherPoolID + `","pool_model_id":"` + otherModelID + `","disclosure_class":"pool_attested_unverified",` +
			`"disclosure_text":"Pool-attested, not network-verified","runtime_sources":["mlx_cache"],` +
			`"artifact_hash_algorithm":"macprovider.snapshot-manifest.v1","artifact_hash":"` + strings.Repeat("b", 64) + `",` +
			`"max_context_tokens":8192,"price":{"prompt_rate_per_mtok":1,"prompt_cache_hit_rate_per_mtok":1,"completion_rate_per_mtok":2,"global_multiplier_ppm":1000000},` +
			`"price_source":"pool_creator_signed","manifest_version":5,"manifest_core_digest":"` + strings.Repeat("e", 64) + `"}},` +
			`{"id":"pool/` + poolID + `/malformed","object":"model","owned_by":"macprovider","created":1}]}`
		var body map[string]any
		if err := json.Unmarshal([]byte(raw), &body); err != nil {
			t.Fatal(err)
		}
		for _, mutate := range mutators {
			mutate(body)
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
	if got := ids(global); len(got) != 2 || got[0] != "model-a" || got[1] != "class/a" {
		t.Fatalf("default view ids = %v", got)
	}
	globalDuplicate := build(func(body map[string]any) {
		data := body["data"].([]any)
		duplicate := make(map[string]any, len(data[0].(map[string]any)))
		for key, value := range data[0].(map[string]any) {
			duplicate[key] = value
		}
		body["data"] = append(data, duplicate)
	})
	sanitizeModelsResponse(globalDuplicate, "")
	if got := ids(globalDuplicate); len(got) != 3 || got[0] != "model-a" || got[1] != "class/a" || got[2] != "model-a" {
		t.Fatalf("default view duplicate ids = %v", got)
	}
	view := build()
	sanitizeModelsResponse(view, poolID)
	got := ids(view)
	if len(got) != 1 || got[0] != modelID {
		t.Fatalf("pool view ids = %v", got)
	}
	other := build()
	sanitizeModelsResponse(other, otherPoolID)
	if got := ids(other); len(got) != 1 || got[0] != otherModelID {
		t.Fatalf("other pool view ids = %v", got)
	}
	for name, mutate := range map[string]func(map[string]any){
		"embedded pool mismatch": func(body map[string]any) {
			pm := body["data"].([]any)[2].(map[string]any)["macprovider_pool_model"].(map[string]any)
			pm["pool_model_id"] = "pool/AAAAAAAAAAAAAAAAAAAAAA/creator-model"
		},
		"bad slug grammar": func(body map[string]any) {
			pm := body["data"].([]any)[2].(map[string]any)["macprovider_pool_model"].(map[string]any)
			pm["pool_model_id"] = "pool/" + poolID + "/Creator_Model"
		},
		"duplicate selected id": func(body map[string]any) {
			data := body["data"].([]any)
			original := data[2].(map[string]any)
			duplicate := make(map[string]any, len(original))
			for key, value := range original {
				duplicate[key] = value
			}
			pm := original["macprovider_pool_model"].(map[string]any)
			duplicatePM := make(map[string]any, len(pm))
			for key, value := range pm {
				duplicatePM[key] = value
			}
			duplicatePM["manifest_core_digest"] = strings.Repeat("c", 64)
			duplicate["macprovider_pool_model"] = duplicatePM
			body["data"] = append(data, duplicate)
		},
		"catalog id with pool object": func(body map[string]any) {
			data := body["data"].([]any)
			model := data[0].(map[string]any)
			model["macprovider_pool_model"] = data[2].(map[string]any)["macprovider_pool_model"]
			body["data"] = []any{model}
		},
	} {
		body := build(mutate)
		sanitizeModelsResponse(body, poolID)
		if got := ids(body); len(got) != 0 {
			t.Fatalf("%s kept malformed pool view entries: %v", name, got)
		}
	}
}

func TestPoolModelDisclosureHeadersBoundToServedPoolModelRoute(t *testing.T) {
	for _, tc := range []struct {
		name     string
		model    string
		pool     string
		stream   bool
		provider bool
		wantHdr  bool
	}{
		{name: "pool model nonstream", model: "pool/" + testPoolID + "/creator-model", pool: testPoolID, provider: true, wantHdr: true},
		{name: "pool model stream", model: "pool/" + testPoolID + "/creator-model", pool: testPoolID, stream: true, provider: true, wantHdr: true},
		{name: "pool model without provider spoof", model: "pool/" + testPoolID + "/creator-model", pool: testPoolID, wantHdr: false},
		{name: "global model spoof", model: "model-a", pool: "", wantHdr: false},
		{name: "selected pool catalog spoof", model: "model-a", pool: testPoolID, provider: true, wantHdr: false},
		{name: "other pool model spoof", model: "pool/AAAAAAAAAAAAAAAAAAAAAA/creator-model", pool: testPoolID, provider: true, wantHdr: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				switch r.URL.Path {
				case "/internal/routing":
					return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"pools":{"enabled":true,"routeable_pools":["`+testPoolID+`"]}}`), nil
				case "/v1/chat/completions":
					headers := http.Header{"Content-Type": []string{"application/json"}}
					for key, values := range poolModelDisclosureHeaders() {
						for _, value := range values {
							headers.Add(key, value)
						}
					}
					if tc.provider {
						headers.Set("X-MacProvider-Provider", "provider-for-route")
					}
					body := poolChatOK
					if tc.stream {
						headers.Set("Content-Type", "text/event-stream; charset=utf-8")
						body = `data: {"id":"chatcmpl_pool","object":"chat.completion.chunk","model":"` + tc.model + `","choices":[{"delta":{"content":"ok"},"index":0}]}`
						body += "\n\n" + `data: {"id":"chatcmpl_pool","object":"chat.completion.chunk","model":"` + tc.model + `","choices":[{"delta":{},"finish_reason":"stop","index":0}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}`
						body += "\n\ndata: [DONE]\n\n"
					}
					return responseWithBody(http.StatusOK, headers, body), nil
				default:
					t.Fatalf("unexpected coordinator path %s", r.URL.Path)
					return nil, nil
				}
			})}
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
				cfg.Coordinator.OperatorURL = "http://operator.test"
				cfg.Features.TrustedPools = config.TrustedPoolsConfig{
					Enabled:      true,
					AccountPools: map[string][]string{"acct_pool": {testPoolID}},
				}
			}, WithHTTPClient(client))
			key := createAccountAndKey(t, store, cfg, "acct_pool")
			body := `{"model":"` + tc.model + `","max_tokens":20,"stream":` + map[bool]string{false: "false", true: "true"}[tc.stream] + `,"messages":[{"role":"user","content":"hi"}]}`
			headers := map[string]string{}
			if tc.pool != "" {
				headers[poolSelectHeader] = tc.pool
			}

			resp := postChat(t, h, key, body, headers)

			if resp.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			gotDisclosure := resp.Header().Get(poolModelDisclosureResponseHeader)
			gotDigest := resp.Header().Get(poolManifestCoreDigestResponseHeader)
			if tc.wantHdr {
				if gotDisclosure != poolModelDisclosureClass || gotDigest != strings.Repeat("d", 64) {
					t.Fatalf("pool disclosure headers = %q/%q, want valid pair", gotDisclosure, gotDigest)
				}
			} else if gotDisclosure != "" || gotDigest != "" {
				t.Fatalf("spoofed pool disclosure headers leaked = %q/%q", gotDisclosure, gotDigest)
			}
		})
	}
}

func TestPoolModelDisclosureHeadersStrippedFromChatRefusals(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(map[bool]string{false: "nonstream", true: "stream"}[stream], func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				headers := markedNoProviderHeaders()
				for key, values := range poolModelDisclosureHeaders() {
					for _, value := range values {
						headers.Add(key, value)
					}
				}
				return responseWithBody(http.StatusServiceUnavailable, headers, noProviderBody()), nil
			})}
			h, store, dbPath, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
				cfg.Retry503.Enabled = false
			})
			accountID := "acct_pool_disclosure_refusal"
			if stream {
				accountID += "_stream"
			}
			key := createAccountAndKey(t, store, cfg, accountID)

			resp := postChat(t, h, key, chatBody(stream), nil)

			if resp.Code != http.StatusServiceUnavailable {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "no_provider_available")
			if got := resp.Header().Get(poolModelDisclosureResponseHeader); got != "" {
				t.Fatalf("refusal leaked disclosure header %q", got)
			}
			if got := resp.Header().Get(poolManifestCoreDigestResponseHeader); got != "" {
				t.Fatalf("refusal leaked digest header %q", got)
			}
			assertRefundedNoProviderAudit(t, dbPath, accountID)
		})
	}
}

// #1880 item 5: an authorized selected-pool GET /v1/models lists only that
// pool's signed pool models, never a global catalog entry, and forwards the
// pool to the coordinator; the unselected view lists no pool model.
func TestModelsSelectedPoolViewExcludesGlobalCatalog(t *testing.T) {
	poolModelID := "pool/" + testPoolID + "/creator-model"
	models := `{"object":"list","data":[{"id":"model-a","object":"model","owned_by":"macprovider","created":1},` +
		`{"id":"` + poolModelID + `","object":"model","owned_by":"macprovider","created":1,"macprovider_pool_model":{` +
		`"pool_id":"` + testPoolID + `","pool_model_id":"` + poolModelID + `","disclosure_class":"pool_attested_unverified",` +
		`"disclosure_text":"Pool-attested, not network-verified","runtime_sources":["mlx_cache"],` +
		`"artifact_hash_algorithm":"macprovider.snapshot-manifest.v1","artifact_hash":"` + strings.Repeat("a", 64) + `",` +
		`"max_context_tokens":8192,"price":{"prompt_rate_per_mtok":1,"prompt_cache_hit_rate_per_mtok":1,"completion_rate_per_mtok":2,"global_multiplier_ppm":1000000},` +
		`"price_source":"pool_creator_signed","manifest_version":5,"manifest_core_digest":"` + strings.Repeat("d", 64) + `"}}]}`
	var emitted []string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/internal/routing":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"pools":{"enabled":true,"routeable_pools":["`+testPoolID+`"]}}`), nil
		case "/v1/models":
			emitted = append(emitted, r.Header.Get(poolEmitHeader))
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, models), nil
		}
		return responseWithBody(http.StatusNotFound, nil, `{}`), nil
	})}
	h, st, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Features.TrustedPools = config.TrustedPoolsConfig{Enabled: true, AccountPools: map[string][]string{"acct_pool": {testPoolID}}}
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, st, cfg, "acct_pool")
	list := func(selector string) []string {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
		req.Header.Set("Authorization", "Bearer "+key)
		if selector != "" {
			req.Header.Set(poolSelectHeader, selector)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("selector=%q status=%d body=%s", selector, rec.Code, rec.Body.String())
		}
		if rec.Header().Get(poolModelDisclosureResponseHeader) != "" || rec.Header().Get(poolManifestCoreDigestResponseHeader) != "" {
			t.Fatalf("/v1/models carried pool-model disclosure headers: %v", rec.Header())
		}
		var body struct {
			Data []struct {
				ID string `json:"id"`
			} `json:"data"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		var ids []string
		for _, item := range body.Data {
			ids = append(ids, item.ID)
		}
		return ids
	}
	if ids := list(testPoolID); len(ids) != 1 || ids[0] != poolModelID {
		t.Fatalf("selected-pool view = %v, want only %s", ids, poolModelID)
	}
	if ids := list(""); len(ids) != 1 || ids[0] != "model-a" {
		t.Fatalf("default view = %v, want only the global entry", ids)
	}
	if len(emitted) != 2 || emitted[0] != testPoolID || emitted[1] != "" {
		t.Fatalf("coordinator pool emit headers = %q", emitted)
	}
}
