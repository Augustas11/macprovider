package autotune_test

import (
	"os"
	"path/filepath"
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

func mustCatalog(t *testing.T, raw string) *autotune.Catalog {
	t.Helper()
	catalog, err := autotune.ParseCatalog([]byte(raw))
	if err != nil {
		t.Fatalf("ParseCatalog: %v", err)
	}
	return catalog
}
