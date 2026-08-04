package autotune_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
)

func TestParseCatalogFromDistStatic(t *testing.T) {
	t.Parallel()
	path := filepath.Join("..", "..", "..", "phase3-binary", "dist", "static", "autotune-candidates.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read catalog: %v", err)
	}
	catalog, err := autotune.ParseCatalog(raw)
	if err != nil {
		t.Fatalf("ParseCatalog: %v", err)
	}
	if catalog.Version == "" {
		t.Fatal("catalog version is empty")
	}
	if len(catalog.SHA256) != 64 {
		t.Fatalf("catalog sha256 len = %d, want 64", len(catalog.SHA256))
	}
	if _, _, ok := catalog.HighestClaimedTier("mlx-community/Qwen3-8B-4bit"); !ok {
		t.Fatal("expected qwen3-8b model_id lookup")
	}
}

func TestEvaluateHelloGateUnderTierAllowedOverTierRejected(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"test",
		"generated_at":"2026-07-08T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"},
			"large":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","model_revision":"6e302ea604ad9ab206367e2c501d1571023e7b6d","model_sha256":"10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0","min_ram_gb":28,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3000},"runtime_status":"recommendable"}
		}
	}`)
	smallIdentity := mustRowIdentity(t, catalog, "small")
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey:               "small",
				ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
				SustainedTPS:           20,
				TTFTMS:                 1000,
				ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
				CandidateCatalogSHA256: catalog.SHA256,
				CandidateRowIdentity:   smallIdentity,
			},
		},
	}
	allowed := autotune.EvaluateHelloGate(catalog, evidence, "mlx-community/Llama-3.2-3B-Instruct-4bit")
	if !allowed.Allowed || allowed.MaxAdmittedModelKey != "small" {
		t.Fatalf("under-tier hello: %+v", allowed)
	}
	rejected := autotune.EvaluateHelloGate(catalog, evidence, "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit")
	if rejected.Allowed || rejected.Reason != "autotune_model_cap_exceeded" {
		t.Fatalf("over-tier hello: %+v", rejected)
	}
}

func TestEvaluateHelloGateAcceptsCatalogRowKeyHelloModelID(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"test",
		"generated_at":"2026-07-08T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"qwen3-coder-30b-a3b-instruct":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","model_revision":"6e302ea604ad9ab206367e2c501d1571023e7b6d","model_sha256":"10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0","min_ram_gb":28,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3500},"runtime_status":"recommendable"}
		}
	}`)
	rowIdentity := mustRowIdentity(t, catalog, "qwen3-coder-30b-a3b-instruct")
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey:               "qwen3-coder-30b-a3b-instruct",
				ModelID:                "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
				SustainedTPS:           45.9,
				TTFTMS:                 3064,
				ArtifactSHA256:         "10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0",
				CandidateCatalogSHA256: catalog.SHA256,
				CandidateRowIdentity:   rowIdentity,
			},
		},
	}
	allowed := autotune.EvaluateHelloGate(catalog, evidence, "qwen3-coder-30b-a3b-instruct")
	if !allowed.Allowed || allowed.ClaimedModelKey != "qwen3-coder-30b-a3b-instruct" {
		t.Fatalf("catalog-key hello: %+v", allowed)
	}
}

func TestEvaluateHelloGateRejectsThermalThrottle(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"test",
		"generated_at":"2026-07-08T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"}
		}
	}`)
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey:                "small",
				ModelID:                 "mlx-community/Llama-3.2-3B-Instruct-4bit",
				SustainedTPS:            20,
				TTFTMS:                  1000,
				ThermalThrottleDetected: true,
				ArtifactSHA256:          "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
				CandidateCatalogSHA256:  catalog.SHA256,
			},
		},
	}
	decision := autotune.EvaluateHelloGate(catalog, evidence, "mlx-community/Llama-3.2-3B-Instruct-4bit")
	if decision.Allowed || decision.Reason != "autotune_evidence_invalid" {
		t.Fatalf("decision = %+v", decision)
	}
}

func TestEvaluateHelloGateRejectsSwapDetected(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"test",
		"generated_at":"2026-07-08T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"}
		}
	}`)
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey:               "small",
				ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
				SustainedTPS:           20,
				TTFTMS:                 1000,
				SwapDetected:           true,
				ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
				CandidateCatalogSHA256: catalog.SHA256,
			},
		},
	}
	decision := autotune.EvaluateHelloGate(catalog, evidence, "mlx-community/Llama-3.2-3B-Instruct-4bit")
	if decision.Allowed || decision.Reason != "autotune_evidence_invalid" {
		t.Fatalf("decision = %+v", decision)
	}
}

func TestEvaluateHelloGateIgnoresSwappedHigherTierBenchmark(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"test",
		"generated_at":"2026-07-08T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"},
			"large":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","model_revision":"6e302ea604ad9ab206367e2c501d1571023e7b6d","model_sha256":"10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0","min_ram_gb":28,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3000},"runtime_status":"recommendable"}
		}
	}`)
	smallIdentity := mustRowIdentity(t, catalog, "small")
	largeIdentity := mustRowIdentity(t, catalog, "large")
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey:               "small",
				ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
				SustainedTPS:           20,
				TTFTMS:                 1000,
				ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
				CandidateCatalogSHA256: catalog.SHA256,
				CandidateRowIdentity:   smallIdentity,
			},
			{
				ModelKey:               "large",
				ModelID:                "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
				SustainedTPS:           30,
				TTFTMS:                 1000,
				SwapDetected:           true,
				ArtifactSHA256:         "10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0",
				CandidateCatalogSHA256: catalog.SHA256,
				CandidateRowIdentity:   largeIdentity,
			},
		},
	}
	allowed := autotune.EvaluateHelloGate(catalog, evidence, "mlx-community/Llama-3.2-3B-Instruct-4bit")
	if !allowed.Allowed || allowed.MaxAdmittedModelKey != "small" {
		t.Fatalf("under-tier hello: %+v", allowed)
	}
	rejected := autotune.EvaluateHelloGate(catalog, evidence, "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit")
	if rejected.Allowed || rejected.Reason != "autotune_model_cap_exceeded" {
		t.Fatalf("swapped higher tier raised cap: %+v", rejected)
	}
}

func TestEvaluateHelloGateTreatsTPSAndTTFTMissesAsAdvisory(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"test",
		"generated_at":"2026-07-08T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"}
		}
	}`)
	smallIdentity := mustRowIdentity(t, catalog, "small")
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey:               "small",
				ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
				SustainedTPS:           1,
				TTFTMS:                 12_000,
				ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
				CandidateCatalogSHA256: catalog.SHA256,
				CandidateRowIdentity:   smallIdentity,
			},
		},
	}
	decision := autotune.EvaluateHelloGate(catalog, evidence, "mlx-community/Llama-3.2-3B-Instruct-4bit")
	if !decision.Allowed || decision.MaxAdmittedModelKey != "small" {
		t.Fatalf("TPS/TTFT advisory miss rejected: %+v", decision)
	}
}

func TestEvaluateHelloGateRejectsMissingModelOrArtifactBinding(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"test",
		"generated_at":"2026-07-08T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"}
		}
	}`)
	for _, benchmark := range []autotune.VerifiedBenchmark{
		{
			ModelKey:               "small",
			SustainedTPS:           20,
			TTFTMS:                 1000,
			ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
			CandidateCatalogSHA256: catalog.SHA256,
		},
		{
			ModelKey:               "small",
			ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
			SustainedTPS:           20,
			TTFTMS:                 1000,
			CandidateCatalogSHA256: catalog.SHA256,
		},
	} {
		evidence := autotune.VerifiedEvidence{
			CandidateCatalogSHA256: catalog.SHA256,
			Benchmarks:             []autotune.VerifiedBenchmark{benchmark},
		}
		decision := autotune.EvaluateHelloGate(catalog, evidence, "mlx-community/Llama-3.2-3B-Instruct-4bit")
		if decision.Allowed || decision.Reason != "autotune_evidence_invalid" {
			t.Fatalf("decision = %+v", decision)
		}
	}
}

func TestEvaluateHelloGateAcceptsUnchangedRowIdentityAcrossCatalogRelease(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"release-2",
		"policy_version":"autotune-policy-v1",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"}
		}
	}`)
	rowIdentity, ok := catalog.RowIdentity("small")
	if !ok {
		t.Fatal("missing row identity")
	}
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{{
			ModelKey:               "small",
			ModelID:                "mlx-community/Llama-3.2-3B-Instruct-4bit",
			SustainedTPS:           20,
			TTFTMS:                 1000,
			ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
			CandidateCatalogSHA256: catalog.SHA256,
			CandidateRowIdentity:   rowIdentity,
		}},
	}

	decision := autotune.EvaluateHelloGate(catalog, evidence, "mlx-community/Llama-3.2-3B-Instruct-4bit")
	if !decision.Allowed {
		t.Fatalf("unchanged row identity rejected: %+v", decision)
	}
	evidence.Benchmarks[0].CandidateRowIdentity = "changed"
	decision = autotune.EvaluateHelloGate(catalog, evidence, "mlx-community/Llama-3.2-3B-Instruct-4bit")
	if decision.Allowed || decision.Reason != "autotune_evidence_invalid" {
		t.Fatalf("changed row identity accepted: %+v", decision)
	}
}

func TestRowIdentityBindsCanonicalDraftAndWorkloadPolicy(t *testing.T) {
	t.Parallel()
	raw := `{"version":"policy-identity-v1","generated_at":"2026-07-10T20:00:00Z","source":"operator_curated_autotune_candidate_catalog","policy_version":"autotune-policy-v1","rows":{"fixture":{"model_id":"mlx-community/Fixture-4bit","model_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","model_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","min_ram_gb":8,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommendable","draft_candidates":[{"draft_model":"mlx-community/Fixture-Draft-4bit","draft_model_artifact_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}],"workload_profiles":{"short_chat":{"8gb":{"status":"no_winner","no_winner_reason":"no_cells_evaluated","gate_policy":{"min_samples":20,"max_p95_ttft_ms":8000,"max_stop_token_leak_rate":0,"min_median_tps":null},"profile_metrics":{"median_tps":null,"p95_ttft_ms":null,"stop_token_leak_rate":null,"spec_decode_acceptance_rate":null,"sample_count":0},"source":"shared-schema-corpus"}}}}}}`
	catalog := mustCatalog(t, raw)
	identity, ok := catalog.RowIdentity("fixture")
	if !ok {
		t.Fatal("missing fixture row identity")
	}
	if identity != "e6591bdf9f126f3b3013daf325e1cfbd33a8d5c08f35f785569b5ed1a46b1acf" {
		t.Fatalf("row identity = %q", identity)
	}
	equivalent := strings.Replace(raw, `"source":"shared-schema-corpus"`, `"source":"shared-schema-corpus","candidate_source":null,"ignored_nested":true`, 1)
	equivalentCatalog := mustCatalog(t, equivalent)
	if equivalentIdentity, equivalentOK := equivalentCatalog.RowIdentity("fixture"); !equivalentOK || equivalentIdentity != identity {
		t.Fatalf("semantically equivalent identity = %q, ok=%v", equivalentIdentity, equivalentOK)
	}

	for name, changed := range map[string]string{
		"draft":    strings.Replace(raw, strings.Repeat("0", 64), strings.Repeat("1", 64), 1),
		"workload": strings.Replace(raw, "shared-schema-corpus", "changed-source", 1),
	} {
		t.Run(name, func(t *testing.T) {
			changedCatalog := mustCatalog(t, changed)
			changedIdentity, changedOK := changedCatalog.RowIdentity("fixture")
			if !changedOK || changedIdentity == identity {
				t.Fatalf("changed identity = %q, ok=%v", changedIdentity, changedOK)
			}
		})
	}
}

func TestPolicyEquivalentTreatsOmittedAndNullOptionalPolicyAsEqual(t *testing.T) {
	t.Parallel()
	base := `{"version":"release-a","policy_version":"autotune-policy-v1","source":"operator_curated_autotune_candidate_catalog","rows":{"fixture":{"model_id":"model-a","min_ram_gb":8,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommendable"}}}`
	explicitNull := strings.Replace(base, `"runtime_status":"recommendable"`, `"runtime_status":"recommendable","draft_candidates":null,"workload_profiles":null`, 1)
	omittedCatalog := mustCatalog(t, base)
	nullCatalog := mustCatalog(t, explicitNull)
	if !omittedCatalog.PolicyEquivalent("fixture", nullCatalog, "fixture") ||
		!nullCatalog.PolicyEquivalent("fixture", omittedCatalog, "fixture") {
		t.Fatal("omitted and explicit-null optional policy fields must be equivalent")
	}

	nestedOmitted := `{
		"version":"release-a",
		"policy_version":"autotune-policy-v1",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{"fixture":{
			"model_id":"model-a",
			"min_ram_gb":8,
			"min_bandwidth_tier":"C",
			"bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},
			"runtime_status":"recommendable",
			"workload_profiles":{"short_chat":{"8gb":{
				"recommended":{"kv_bits":8,"max_context_override":4096,"max_concurrency_override":1},
				"gate_policy":{"min_samples":20,"max_p95_ttft_ms":8000,"max_stop_token_leak_rate":0,"min_median_tps":null},
				"profile_metrics":{"median_tps":12,"p95_ttft_ms":1000,"stop_token_leak_rate":0,"spec_decode_acceptance_rate":null,"sample_count":20},
				"source":"shared-schema-corpus"
			}}}
		}}
	}`
	nestedNull := strings.Replace(
		nestedOmitted,
		`"recommended":{"kv_bits":8,"max_context_override":4096,"max_concurrency_override":1}`,
		`"status":null,"no_winner_reason":null,"candidate_source":null,"recommended":{"kv_bits":8,"max_context_override":4096,"max_concurrency_override":1,"draft_model":null,"draft_model_artifact_sha256":null,"num_draft_tokens":null}`,
		1,
	)
	nestedOmittedCatalog := mustCatalog(t, nestedOmitted)
	nestedNullCatalog := mustCatalog(t, nestedNull)
	if !nestedOmittedCatalog.PolicyEquivalent("fixture", nestedNullCatalog, "fixture") ||
		!nestedNullCatalog.PolicyEquivalent("fixture", nestedOmittedCatalog, "fixture") {
		t.Fatal("nested omitted and explicit-null optional policy fields must be equivalent")
	}
	changed := strings.Replace(nestedNull, `"num_draft_tokens":null`, `"num_draft_tokens":4`, 1)
	if nestedOmittedCatalog.PolicyEquivalent("fixture", mustCatalog(t, changed), "fixture") {
		t.Fatal("material nested policy change must not be equivalent")
	}
}

func TestResolveMaxAdmissionRejectsLegacyRowFromMixedStaleEvidence(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"release-2",
		"policy_version":"autotune-policy-v1",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"},
			"large":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","model_revision":"6e302ea604ad9ab206367e2c501d1571023e7b6d","model_sha256":"10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0","min_ram_gb":28,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3500},"runtime_status":"recommendable"}
		}
	}`)
	smallIdentity, ok := catalog.RowIdentity("small")
	if !ok {
		t.Fatal("missing small row identity")
	}
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: "previous-release-digest",
		Benchmarks: []autotune.VerifiedBenchmark{
			{
				ModelKey: "small", ModelID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
				SustainedTPS: 20, TTFTMS: 1000,
				ArtifactSHA256:         "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a",
				CandidateCatalogSHA256: "previous-release-digest", CandidateRowIdentity: smallIdentity,
			},
			{
				ModelKey: "large", ModelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
				SustainedTPS: 40, TTFTMS: 1000,
				ArtifactSHA256:         "10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0",
				CandidateCatalogSHA256: "previous-release-digest",
			},
		},
	}

	if _, err := autotune.ResolveMaxAdmission(catalog, evidence); err == nil {
		t.Fatal("stale catalog digest should be rejected even when row identity is present")
	}
}

func mustCatalog(t *testing.T, raw string) *autotune.Catalog {
	t.Helper()
	catalog, err := autotune.ParseCatalog([]byte(raw))
	if err != nil {
		t.Fatalf("ParseCatalog: %v", err)
	}
	return catalog
}

func mustRowIdentity(t *testing.T, catalog *autotune.Catalog, modelKey string) string {
	t.Helper()
	identity, ok := catalog.RowIdentity(modelKey)
	if !ok {
		t.Fatalf("missing row identity for %s", modelKey)
	}
	return identity
}
