package pow

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type erroringEvidence struct{}

func (erroringEvidence) LatestVerified(context.Context, string, time.Duration) (autotune.VerifiedEvidence, bool, error) {
	return autotune.VerifiedEvidence{}, false, errors.New("evidence store down")
}

func missingBenchmarkCatalog(t *testing.T) *autotune.Catalog {
	t.Helper()
	return mustCatalog(t, `{
		"version":"test","source":"operator_curated_autotune_candidate_catalog",
		"rows":{"qwen3-coder-30b-a3b-instruct":{"model_id":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit","min_ram_gb":28,"bench_gate":{"min_sustained_tps":20,"max_4k_ttft_ms":3500}}}
	}`)
}

func missingBenchmarkProvider() pool.Provider {
	return pool.Provider{
		ProviderID: "mac",
		AssignedID: "sess-1",
		ModelID:    "qwen3-coder-30b-a3b-instruct",
		HashStatus: pool.HashStatusVerified,
	}
}

func verifiedBenchmarkEvidence() autotune.VerifiedEvidence {
	return autotune.VerifiedEvidence{
		Benchmarks: []autotune.VerifiedBenchmark{{
			ModelKey:       "qwen3-coder-30b-a3b-instruct",
			ModelID:        "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
			SustainedTPS:   20,
			ArtifactSHA256: "abc123",
		}},
	}
}

func newMissingBenchmarkEvaluator(t *testing.T, quarantine bool, evidence autotune.EvidenceStore) *Evaluator {
	t.Helper()
	e := NewEvaluator(TelemetryDriftConfig{
		Enabled:                    true,
		TPSRatioThreshold:          0.70,
		AlertCooldown:              time.Second,
		QuarantineMissingBenchmark: quarantine,
	}, missingBenchmarkCatalog(t), evidence, 30*24*time.Hour)
	e.now = func() time.Time { return time.Unix(0, 0) }
	return e
}

// Issue #765 acceptance: with the gate ENABLED, a provider with no verified
// benchmark yields the Missing verdict the caller turns into a quarantine.
func TestEvaluateHeartbeatMissingBenchmarkQuarantinesWhenEnabled(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name     string
		evidence autotune.EvidenceStore
	}{
		{name: "no verified evidence at all", evidence: stubEvidence{ok: false}},
		{
			name: "evidence without a benchmark for the served model",
			evidence: stubEvidence{ok: true, evidence: autotune.VerifiedEvidence{
				Benchmarks: []autotune.VerifiedBenchmark{{
					ModelKey:     "some-other-model",
					ModelID:      "mlx-community/Some-Other-Model",
					SustainedTPS: 20,
				}},
			}},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			evaluator := newMissingBenchmarkEvaluator(t, true, tc.evidence)
			alerts, verdict := evaluator.EvaluateHeartbeatWithVerdict(context.Background(), missingBenchmarkProvider())
			if verdict != BenchmarkVerdictMissing {
				t.Fatalf("verdict = %v, want BenchmarkVerdictMissing", verdict)
			}
			if len(alerts) == 0 || alerts[0].Signal != SignalMissingBenchmark {
				t.Fatalf("alerts = %#v, want a %s alert", alerts, SignalMissingBenchmark)
			}
		})
	}
}

// Pins the CURRENT default posture: with the quarantine gate off, an
// un-benchmarked provider produces no verdict, so routing is unchanged.
func TestEvaluateHeartbeatMissingBenchmarkIsObserveOnlyByDefault(t *testing.T) {
	t.Parallel()
	evaluator := newMissingBenchmarkEvaluator(t, false, stubEvidence{ok: false})
	alerts, verdict := evaluator.EvaluateHeartbeatWithVerdict(context.Background(), missingBenchmarkProvider())
	if verdict != BenchmarkVerdictUnknown {
		t.Fatalf("verdict = %v, want BenchmarkVerdictUnknown with the gate off", verdict)
	}
	if len(alerts) != 1 || alerts[0].Signal != SignalMissingBenchmark {
		t.Fatalf("alerts = %#v, want the observe-only %s alert", alerts, SignalMissingBenchmark)
	}
}

// A disabled evaluator must be completely inert — the pre-#765 contract.
func TestEvaluateHeartbeatDisabledEvaluatorIsInert(t *testing.T) {
	t.Parallel()
	var evaluator *Evaluator
	alerts, verdict := evaluator.EvaluateHeartbeatWithVerdict(context.Background(), missingBenchmarkProvider())
	if len(alerts) != 0 || verdict != BenchmarkVerdictUnknown {
		t.Fatalf("nil evaluator = (%#v, %v), want (nil, Unknown)", alerts, verdict)
	}
	disabled := NewEvaluator(TelemetryDriftConfig{QuarantineMissingBenchmark: true}, missingBenchmarkCatalog(t), stubEvidence{ok: false}, time.Hour)
	alerts, verdict = disabled.EvaluateHeartbeatWithVerdict(context.Background(), missingBenchmarkProvider())
	if len(alerts) != 0 || verdict != BenchmarkVerdictUnknown {
		t.Fatalf("disabled evaluator = (%#v, %v), want (nil, Unknown)", alerts, verdict)
	}
}

// A verified benchmark releases the quarantine ("until it produces one").
func TestEvaluateHeartbeatVerifiedBenchmarkReleasesQuarantine(t *testing.T) {
	t.Parallel()
	evaluator := newMissingBenchmarkEvaluator(t, true, stubEvidence{ok: true, evidence: verifiedBenchmarkEvidence()})
	alerts, verdict := evaluator.EvaluateHeartbeatWithVerdict(context.Background(), missingBenchmarkProvider())
	if verdict != BenchmarkVerdictVerified {
		t.Fatalf("verdict = %v, want BenchmarkVerdictVerified", verdict)
	}
	for _, alert := range alerts {
		if alert.Signal == SignalMissingBenchmark {
			t.Fatalf("unexpected %s alert for a benchmarked provider: %#v", SignalMissingBenchmark, alert)
		}
	}
}

// An evidence-store failure is infrastructure, not a provider claim. It must
// stay Unknown or a database blip would quarantine the whole fleet.
func TestEvaluateHeartbeatEvidenceErrorDoesNotQuarantine(t *testing.T) {
	t.Parallel()
	evaluator := newMissingBenchmarkEvaluator(t, true, erroringEvidence{})
	alerts, verdict := evaluator.EvaluateHeartbeatWithVerdict(context.Background(), missingBenchmarkProvider())
	if verdict != BenchmarkVerdictUnknown {
		t.Fatalf("verdict = %v, want BenchmarkVerdictUnknown on an evidence-store error", verdict)
	}
	if len(alerts) != 0 {
		t.Fatalf("alerts = %#v, want none on an evidence-store error", alerts)
	}
}
