package ws

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func TestEvaluateCanaryProbeLatencyGates(t *testing.T) {
	t.Parallel()
	challenge := config.CanaryChallengeConfig{
		Prompt:          "Reply {nonce}",
		Expected:        "{nonce}",
		MaxTTFTMS:       800,
		MinSustainedTPS: 12,
	}
	pass := evaluateCanaryProbe(challenge, "ABCD", "ABCD", canaryProbeMetrics{TTFTMS: 700, SustainedTPS: 15}, false)
	if pass != canaryProbePass {
		t.Fatalf("latency pass = %q", pass)
	}
	if evaluateCanaryProbe(challenge, "ABCD", "ABCD", canaryProbeMetrics{TTFTMS: 900, SustainedTPS: 15}, false) != canaryProbeFail {
		t.Fatal("expected ttft fail")
	}
	if evaluateCanaryProbe(challenge, "ABCD", "ABCD", canaryProbeMetrics{TTFTMS: 700, SustainedTPS: 8}, false) != canaryProbeFail {
		t.Fatal("expected tps fail")
	}
	if evaluateCanaryProbe(challenge, "wrong", "ABCD", canaryProbeMetrics{TTFTMS: 700, SustainedTPS: 15}, false) != canaryProbeFail {
		t.Fatal("expected answer fail")
	}
	// Cold-start grace waives ONLY the TTFT gate: a slow-but-correct answer
	// passes, while a wrong answer or low sustained TPS still fails.
	if evaluateCanaryProbe(challenge, "ABCD", "ABCD", canaryProbeMetrics{TTFTMS: 9000, SustainedTPS: 15}, true) != canaryProbePass {
		t.Fatal("expected cold-start grace to waive the ttft gate")
	}
	if evaluateCanaryProbe(challenge, "wrong", "ABCD", canaryProbeMetrics{TTFTMS: 9000, SustainedTPS: 15}, true) != canaryProbeFail {
		t.Fatal("cold-start grace must NOT waive the answer-correctness gate")
	}
	if evaluateCanaryProbe(challenge, "ABCD", "ABCD", canaryProbeMetrics{TTFTMS: 9000, SustainedTPS: 8}, true) != canaryProbeFail {
		t.Fatal("cold-start grace must NOT waive the sustained-tps gate")
	}
}

func TestPoolConfigCanaryChallengesForModel(t *testing.T) {
	t.Parallel()
	pool := config.PoolConfig{
		CanaryChallenges: []config.CanaryChallengeConfig{{Prompt: "global {nonce}", Expected: "{nonce}"}},
		ModelClassChallenges: map[string][]config.CanaryChallengeConfig{
			"qwen3-coder-30b-a3b-instruct": {{Prompt: "tier {nonce}", Expected: "tier-{nonce}"}},
		},
	}
	if bank, ok := pool.CanaryChallengesForModel("qwen3-coder-30b-a3b-instruct"); !ok || bank[0].Prompt != "tier {nonce}" {
		t.Fatalf("model class bank = %+v ok=%v", bank, ok)
	}
	if bank, ok := pool.CanaryChallengesForModel("unknown-model"); ok || bank[0].Prompt != "global {nonce}" {
		t.Fatalf("fallback bank = %+v ok=%v", bank, ok)
	}
}
