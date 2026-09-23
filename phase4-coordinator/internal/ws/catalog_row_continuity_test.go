package ws_test

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"

	"github.com/gobwas/ws/wsutil"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"

	gobwas "github.com/gobwas/ws"
)

// SPEC-023-R010 / AC-CAT-22: an older signed document retained only as
// row-continuity evidence admits a provider whose selected row is unchanged.

const rowContinuitySmallModelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"

func rowContinuityCatalog(t *testing.T, current *autotune.Catalog, version string, edits ...[2]string) *autotune.Catalog {
	t.Helper()
	raw := bytes.Replace(current.RawJSON, []byte(`"version":"test"`), []byte(`"version":"`+version+`"`), 1)
	for _, edit := range edits {
		next := bytes.Replace(raw, []byte(edit[0]), []byte(edit[1]), 1)
		if bytes.Equal(next, raw) {
			t.Fatalf("edit %q did not apply", edit[0])
		}
		raw = next
	}
	catalog, err := autotune.ParseCatalog(raw)
	if err != nil {
		t.Fatalf("ParseCatalog(%s): %v", version, err)
	}
	catalog.SignerKeyID = current.SignerKeyID
	catalog.RowContinuityOnly = true
	return catalog
}

func dialHelloAck(t *testing.T, url string, hello map[string]any) map[string]any {
	t.Helper()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(url))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	return ack
}

func TestCatalogRowContinuityAdmitsOlderDocumentWithUnchangedRow(t *testing.T) {
	current := mustAutotuneCatalog(t)
	baked := rowContinuityCatalog(t, current, "published-2026-09-02-baked-v1")
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneCatalog(current, baked),
	}, func(*config.Config) {})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = rowContinuitySmallModelID
	addCatalogAdmissionMetadata(t, hello, baked)
	ack := dialHelloAck(t, h.HTTP.URL, hello)
	if ack["catalog_compatible"] != true ||
		ack["catalog_release_id"] != current.Version ||
		ack["catalog_candidate_sha256"] != current.SHA256 {
		t.Fatalf("row-continuity ack must advertise the active catalog: %+v", ack)
	}
	provider, ok := h.Registry.Resolve("m4-anon", ack["assigned_id"].(string))
	if !ok {
		t.Fatal("row-continuity provider not registered")
	}
	if provider.CatalogAdmissionMode != "row_continuity" ||
		provider.CatalogReleaseID != baked.Version ||
		provider.CandidateCatalogSHA256 != baked.SHA256 {
		t.Fatalf("row-continuity admission evidence = mode %q release %q sha %q",
			provider.CatalogAdmissionMode, provider.CatalogReleaseID, provider.CandidateCatalogSHA256)
	}
}

func TestCatalogRowContinuityFailsClosed(t *testing.T) {
	current := mustAutotuneCatalog(t)
	withoutSmall, err := autotune.ParseCatalog([]byte(`{
		"version":"test-no-small",
		"generated_at":"2026-07-08T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"policy_version":"autotune-policy-v1",
		"rows":{
			"large":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","model_revision":"6e302ea604ad9ab206367e2c501d1571023e7b6d","model_sha256":"10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0","min_ram_gb":28,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3000},"runtime_status":"recommendable"}
		}
	}`))
	if err != nil {
		t.Fatalf("ParseCatalog(withoutSmall): %v", err)
	}
	withoutSmall.SignerKeyID = current.SignerKeyID

	smallRuntimeStatus := [2]string{
		`"min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"`,
		`"min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"listed"`,
	}
	smallPolicy := func(policy string) [2]string {
		return [2]string{
			`"max_4k_ttft_ms":2500},"runtime_status":"recommendable"}`,
			`"max_4k_ttft_ms":2500},"runtime_status":"recommendable"` + policy + `}`,
		}
	}

	type fixture struct {
		name     string
		active   *autotune.Catalog
		loaded   func(t *testing.T) []*autotune.Catalog
		hello    func(t *testing.T) map[string]any
		mutateHi func(map[string]any)
	}
	baked := func(t *testing.T, edits ...[2]string) *autotune.Catalog {
		return rowContinuityCatalog(t, current, "published-2026-09-02-baked-v1", edits...)
	}
	helloFor := func(catalog *autotune.Catalog) map[string]any {
		hello := validHello("m4-anon")
		hello["model_id"] = rowContinuitySmallModelID
		addCatalogAdmissionMetadata(t, hello, catalog)
		return hello
	}

	cases := []fixture{
		{name: "no authenticated evidence for A", active: current,
			loaded: func(*testing.T) []*autotune.Catalog { return nil },
			hello:  func(t *testing.T) map[string]any { return helloFor(baked(t)) }},
		{name: "tombstoned A", active: current,
			loaded: func(t *testing.T) []*autotune.Catalog {
				return []*autotune.Catalog{rowContinuityCatalog(t, current, "published-2026-07-07-p2-qwen3-8b")}
			},
			hello: func(t *testing.T) map[string]any {
				return helloFor(rowContinuityCatalog(t, current, "published-2026-07-07-p2-qwen3-8b"))
			}},
		{name: "signer key lineage mismatch", active: current,
			loaded: func(t *testing.T) []*autotune.Catalog {
				other := baked(t)
				other.SignerKeyID = "other-trusted-key"
				return []*autotune.Catalog{other}
			},
			hello: func(t *testing.T) map[string]any { return helloFor(baked(t)) }},
		{name: "current row absent", active: withoutSmall,
			loaded: func(t *testing.T) []*autotune.Catalog { return []*autotune.Catalog{baked(t)} },
			hello:  func(t *testing.T) map[string]any { return helloFor(baked(t)) }},
		{name: "row identity mismatch min_ram_gb", active: current,
			loaded: func(t *testing.T) []*autotune.Catalog {
				return []*autotune.Catalog{baked(t, [2]string{`"min_ram_gb":4`, `"min_ram_gb":5`})}
			},
			hello: func(t *testing.T) map[string]any {
				return helloFor(baked(t, [2]string{`"min_ram_gb":4`, `"min_ram_gb":5`}))
			}},
		{name: "row identity mismatch runtime_status", active: current,
			loaded: func(t *testing.T) []*autotune.Catalog { return []*autotune.Catalog{baked(t, smallRuntimeStatus)} },
			hello:  func(t *testing.T) map[string]any { return helloFor(baked(t, smallRuntimeStatus)) }},
		{name: "policy mismatch draft_candidates", active: current,
			loaded: func(t *testing.T) []*autotune.Catalog {
				return []*autotune.Catalog{baked(t, smallPolicy(`,"draft_candidates":[{"draft_model":"mlx-community/draft","draft_model_artifact_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]`))}
			},
			hello: func(t *testing.T) map[string]any {
				return helloFor(baked(t, smallPolicy(`,"draft_candidates":[{"draft_model":"mlx-community/draft","draft_model_artifact_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]`)))
			}},
		{name: "policy mismatch workload_profiles", active: current,
			loaded: func(t *testing.T) []*autotune.Catalog {
				return []*autotune.Catalog{baked(t, smallPolicy(`,"workload_profiles":{"short_chat":{"8gb":{"status":"no_winner"}}}`))}
			},
			hello: func(t *testing.T) map[string]any {
				return helloFor(baked(t, smallPolicy(`,"workload_profiles":{"short_chat":{"8gb":{"status":"no_winner"}}}`)))
			}},
		{name: "hello row identity does not match A", active: current,
			loaded: func(t *testing.T) []*autotune.Catalog { return []*autotune.Catalog{baked(t)} },
			hello: func(t *testing.T) map[string]any {
				hello := helloFor(baked(t))
				hello["catalog_row_identity"] = "0000000000000000000000000000000000000000000000000000000000000000"
				return hello
			}},
	}
	for _, field := range []string{"catalog_release_id", "catalog_policy_version", "catalog_candidate_sha256", "catalog_signer_key_id", "catalog_row_identity"} {
		field := field
		cases = append(cases, fixture{name: "missing " + field, active: current,
			loaded: func(t *testing.T) []*autotune.Catalog { return []*autotune.Catalog{baked(t)} },
			hello: func(t *testing.T) map[string]any {
				hello := helloFor(baked(t))
				delete(hello, field)
				return hello
			}})
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
				providerws.WithAutotuneCatalog(tc.active, tc.loaded(t)...),
			}, func(*config.Config) {})
			defer h.HTTP.Close()
			code, reason := sendHelloExpectClose(t, h.HTTP.URL, tc.hello(t))
			if code != providerws.CloseInvalidHello || reason != "catalog_incompatible" {
				t.Fatalf("code=%d reason=%q", code, reason)
			}
		})
	}
}
