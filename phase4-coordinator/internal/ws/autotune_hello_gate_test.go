package ws_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

type stubAutotuneEvidence struct {
	evidence autotune.VerifiedEvidence
	ok       bool
	err      error
}

func (s stubAutotuneEvidence) LatestVerified(context.Context, string, time.Duration) (autotune.VerifiedEvidence, bool, error) {
	return s.evidence, s.ok, s.err
}

func TestAutotuneHelloGateRejectsOverTierClaim(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
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
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{evidence: evidence, ok: true}),
	}, func(cfg *config.Config) {
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
	code, reason := sendHelloExpectClose(t, h.HTTP.URL, hello)
	if code != providerws.CloseInvalidHello || reason != "autotune_model_cap_exceeded" {
		t.Fatalf("code=%d reason=%q", code, reason)
	}
}

func TestAutotuneHelloGateAllowsUnderTierClaim(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
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
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{evidence: evidence, ok: true}),
	}, func(cfg *config.Config) {
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	hello := validHello("m4-anon")
	hello["model_id"] = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack["type"] != "hello_ack" {
		t.Fatalf("ack type = %v", ack["type"])
	}
	provider, ok := h.Registry.Resolve("m4-anon", ack["assigned_id"].(string))
	if !ok {
		t.Fatal("provider not registered")
	}
	if provider.MaxAdmittedModelKey != "small" {
		t.Fatalf("MaxAdmittedModelKey = %q, want small", provider.MaxAdmittedModelKey)
	}
	if provider.MaxAdmittedModelID != "mlx-community/Llama-3.2-3B-Instruct-4bit" {
		t.Fatalf("MaxAdmittedModelID = %q", provider.MaxAdmittedModelID)
	}
}

func TestAutotuneHelloGateRejectsMissingEvidence(t *testing.T) {
	catalog := mustAutotuneCatalog(t)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithAutotuneHelloGate(catalog, stubAutotuneEvidence{ok: false}),
	}, func(cfg *config.Config) {
		cfg.ProofOfWeights.RequireAutotuneHelloGate = true
		cfg.ProofOfWeights.AutotuneEvidenceTTLDays = 30
	})
	defer h.HTTP.Close()

	code, reason := sendHelloExpectClose(t, h.HTTP.URL, validHello("m4-anon"))
	if code != providerws.CloseInvalidHello || reason != "autotune_evidence_required" {
		t.Fatalf("code=%d reason=%q", code, reason)
	}
}

func mustAutotuneCatalog(t *testing.T) *autotune.Catalog {
	t.Helper()
	catalog, err := autotune.ParseCatalog([]byte(`{
		"version":"test",
		"generated_at":"2026-07-08T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"small":{"model_id":"mlx-community/Llama-3.2-3B-Instruct-4bit","model_revision":"7f0dc925e0d0afb0322d96f9255cfddf2ba5636e","model_sha256":"3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":2500},"runtime_status":"recommendable"},
			"large":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","model_revision":"6e302ea604ad9ab206367e2c501d1571023e7b6d","model_sha256":"10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0","min_ram_gb":28,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3000},"runtime_status":"recommendable"}
		}
	}`))
	if err != nil {
		t.Fatalf("ParseCatalog: %v", err)
	}
	return catalog
}
