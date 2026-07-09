package ws

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
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
	// Cold-start grace waives the TTFT gate: a slow-but-correct answer passes.
	// DecodeWindowReliable=true models a streaming WS probe.
	if evaluateCanaryProbe(challenge, "ABCD", "ABCD", canaryProbeMetrics{TTFTMS: 9000, SustainedTPS: 15, DecodeWindowReliable: true}, true) != canaryProbePass {
		t.Fatal("expected cold-start grace to waive the ttft gate")
	}
	// Grace never waives the answer-correctness gate.
	if evaluateCanaryProbe(challenge, "wrong", "ABCD", canaryProbeMetrics{TTFTMS: 9000, SustainedTPS: 15, DecodeWindowReliable: true}, true) != canaryProbeFail {
		t.Fatal("cold-start grace must NOT waive the answer-correctness gate")
	}
	// For a WS probe with a real decode window, sustained-TPS is STILL enforced
	// under grace (cold load does not depress decode rate).
	if evaluateCanaryProbe(challenge, "ABCD", "ABCD", canaryProbeMetrics{TTFTMS: 9000, SustainedTPS: 8, DecodeWindowReliable: true}, true) != canaryProbeFail {
		t.Fatal("cold-start grace must NOT waive sustained-tps for a WS decode-window probe")
	}
	// For an HTTP probe with NO decode window, SustainedTPS is over full wall
	// time and is cold-contaminated, so it is waived under grace.
	if evaluateCanaryProbe(challenge, "ABCD", "ABCD", canaryProbeMetrics{TTFTMS: 9000, SustainedTPS: 8, DecodeWindowReliable: false}, true) != canaryProbePass {
		t.Fatal("cold-start grace should waive sustained-tps for an HTTP no-decode-window probe")
	}
	// Without grace, TPS is enforced regardless of decode window.
	if evaluateCanaryProbe(challenge, "ABCD", "ABCD", canaryProbeMetrics{TTFTMS: 700, SustainedTPS: 8, DecodeWindowReliable: false}, false) != canaryProbeFail {
		t.Fatal("without grace the sustained-tps gate must still fail")
	}
}

func TestCanaryColdStartActiveIsChurnSafe(t *testing.T) {
	base := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)
	now := base
	s := &Server{now: func() time.Time { return now }}
	s.cfg.Pool.CanaryColdStartGraceS = 300 // 300s window
	p := func(connectedAt time.Time) pool.Provider {
		return pool.Provider{ProviderID: "p1", ConnectedAt: connectedAt}
	}

	// Fresh connect → grace armed and active.
	if !s.canaryColdStartActive(p(base)) {
		t.Fatal("fresh connect should be graced")
	}
	// Still within the original window → active.
	now = base.Add(200 * time.Second)
	if !s.canaryColdStartActive(p(base)) {
		t.Fatal("within window should stay graced")
	}
	// Reconnect-churn AFTER the original expiry with a fresh ConnectedAt must NOT
	// re-arm grace while inside the cooldown — the TTFT gate is enforced again.
	now = base.Add(310 * time.Second)
	if s.canaryColdStartActive(p(now)) {
		t.Fatal("reconnect-churn within cooldown must NOT re-arm grace")
	}
	// Future / negative-age connect is never graced (clock skew guard).
	if s.canaryColdStartActive(p(now.Add(time.Hour))) {
		t.Fatal("future ConnectedAt must not be graced")
	}
	// A genuinely new cold start past the cooldown re-arms grace.
	now = base.Add(601 * time.Second)
	if !s.canaryColdStartActive(p(now)) {
		t.Fatal("a new cold start past cooldown should re-arm grace")
	}
	// Disabled when grace <= 0.
	s.cfg.Pool.CanaryColdStartGraceS = 0
	if s.canaryColdStartActive(p(now)) {
		t.Fatal("grace disabled (0) must be inactive")
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
