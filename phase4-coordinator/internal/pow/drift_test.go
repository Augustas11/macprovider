package pow

import (
	"context"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type stubEvidence struct {
	evidence autotune.VerifiedEvidence
	ok       bool
}

func (s stubEvidence) LatestVerified(context.Context, string, time.Duration) (autotune.VerifiedEvidence, bool, error) {
	return s.evidence, s.ok, nil
}

func mustCatalog(t *testing.T, raw string) *autotune.Catalog {
	t.Helper()
	catalog, err := autotune.ParseCatalog([]byte(raw))
	if err != nil {
		t.Fatalf("ParseCatalog: %v", err)
	}
	return catalog
}

func TestEvaluateHeartbeatTPSDrift(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"test","source":"operator_curated_autotune_candidate_catalog",
		"rows":{"qwen3-coder-30b-a3b-instruct":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","min_ram_gb":28,"bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3500}}}
	}`)
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{{
			ModelKey:       "qwen3-coder-30b-a3b-instruct",
			ModelID:        "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
			SustainedTPS:   20,
			ArtifactSHA256: "abc123",
		}},
	}
	evaluator := NewEvaluator(TelemetryDriftConfig{
		Enabled:           true,
		TPSRatioThreshold: 0.70,
		TPSMinAbsolute:    5,
		AlertCooldown:     time.Second,
	}, catalog, stubEvidence{evidence: evidence, ok: true}, 30*24*time.Hour)
	evaluator.now = func() time.Time { return time.Unix(0, 0) }

	alerts := evaluator.EvaluateHeartbeat(context.Background(), pool.Provider{
		ProviderID:            "mac",
		AssignedID:            "sess-1",
		ModelID:               "qwen3-coder-30b-a3b-instruct",
		ThroughputTPSEstimate: 10,
		HashStatus:            pool.HashStatusVerified,
		ModelHash:             "abc123",
	})
	if len(alerts) != 1 || alerts[0].Signal != "tps" {
		t.Fatalf("alerts = %#v, want single tps alert", alerts)
	}

	alerts = evaluator.EvaluateHeartbeat(context.Background(), pool.Provider{
		ProviderID:            "mac",
		AssignedID:            "sess-1",
		ModelID:               "qwen3-coder-30b-a3b-instruct",
		ThroughputTPSEstimate: 15,
		HashStatus:            pool.HashStatusVerified,
		ModelHash:             "abc123",
	})
	if len(alerts) != 0 {
		t.Fatalf("expected no alert above threshold, got %#v", alerts)
	}
}

func TestEvaluateHeartbeatHashArtifactDrift(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"test","source":"operator_curated_autotune_candidate_catalog",
		"rows":{"qwen3-coder-30b-a3b-instruct":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","min_ram_gb":28,"bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3500}}}
	}`)
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{{
			ModelKey:       "qwen3-coder-30b-a3b-instruct",
			SustainedTPS:   20,
			ArtifactSHA256: "deadbeef",
		}},
	}
	evaluator := NewEvaluator(TelemetryDriftConfig{
		Enabled:                  true,
		HashAlertOnArtifactDrift: true,
		AlertCooldown:            time.Second,
	}, catalog, stubEvidence{evidence: evidence, ok: true}, 30*24*time.Hour)
	evaluator.now = func() time.Time { return time.Unix(0, 0) }

	alerts := evaluator.EvaluateHeartbeat(context.Background(), pool.Provider{
		ProviderID:            "mac",
		AssignedID:            "sess-1",
		ModelID:               "qwen3-coder-30b-a3b-instruct",
		ThroughputTPSEstimate: 20,
		HashStatus:            pool.HashStatusVerified,
		ModelHash:             "cafebabe",
	})
	if len(alerts) != 1 || alerts[0].Signal != "hash_artifact" {
		t.Fatalf("alerts = %#v, want hash_artifact", alerts)
	}
}

func TestRecordModelClassCanaryPassRateDrop(t *testing.T) {
	t.Parallel()
	evaluator := NewEvaluator(TelemetryDriftConfig{
		Enabled:               true,
		OPoIPassRateWindow:    5,
		OPoIPassRateThreshold: 0.80,
		AlertCooldown:         time.Second,
	}, nil, stubEvidence{}, time.Hour)
	evaluator.now = func() time.Time { return time.Unix(0, 0) }
	provider := pool.Provider{ProviderID: "mac", AssignedID: "sess-1", ModelID: "qwen3-coder-30b-a3b-instruct"}

	for i := 0; i < 4; i++ {
		if alerts := evaluator.RecordModelClassCanary(provider, false); alerts != nil {
			t.Fatalf("unexpected early alert at %d: %#v", i, alerts)
		}
	}
	alerts := evaluator.RecordModelClassCanary(provider, false)
	if len(alerts) != 1 || alerts[0].Signal != "opoi_pass_rate" {
		t.Fatalf("alerts = %#v, want opoi_pass_rate", alerts)
	}
}

func TestTelemetryDriftCooldownSuppressesRepeat(t *testing.T) {
	t.Parallel()
	catalog := mustCatalog(t, `{
		"version":"test","source":"operator_curated_autotune_candidate_catalog",
		"rows":{"qwen3-coder-30b-a3b-instruct":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","min_ram_gb":28,"bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3500}}}
	}`)
	evidence := autotune.VerifiedEvidence{
		CandidateCatalogSHA256: catalog.SHA256,
		Benchmarks: []autotune.VerifiedBenchmark{{
			ModelKey:     "qwen3-coder-30b-a3b-instruct",
			SustainedTPS: 20,
		}},
	}
	now := time.Unix(1000, 0)
	evaluator := NewEvaluator(TelemetryDriftConfig{
		Enabled:           true,
		TPSRatioThreshold: 0.70,
		TPSMinAbsolute:    5,
		AlertCooldown:     15 * time.Minute,
	}, catalog, stubEvidence{evidence: evidence, ok: true}, time.Hour)
	evaluator.now = func() time.Time { return now }

	provider := pool.Provider{
		ProviderID:            "mac",
		AssignedID:            "sess-1",
		ModelID:               "qwen3-coder-30b-a3b-instruct",
		ThroughputTPSEstimate: 1,
	}
	if alerts := evaluator.EvaluateHeartbeat(context.Background(), provider); len(alerts) != 1 {
		t.Fatalf("first alert = %#v", alerts)
	}
	if alerts := evaluator.EvaluateHeartbeat(context.Background(), provider); len(alerts) != 0 {
		t.Fatalf("expected cooldown suppression, got %#v", alerts)
	}
}
