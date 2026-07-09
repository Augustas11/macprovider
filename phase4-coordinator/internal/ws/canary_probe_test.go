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
	// grace=false, enforce=true throughout this block (steady-state enforce mode).
	eval := func(out string, m canaryProbeMetrics, grace bool) (canaryProbeOutcome, canaryFailReason) {
		return evaluateCanaryProbe(challenge, out, "ABCD", m, grace, true)
	}
	if o, r := eval("ABCD", canaryProbeMetrics{TTFTMS: 700, SustainedTPS: 15}, false); o != canaryProbePass || r != canaryFailNone {
		t.Fatalf("enforce within gates = %q/%q", o, r)
	}
	if o, r := eval("ABCD", canaryProbeMetrics{TTFTMS: 900, SustainedTPS: 15}, false); o != canaryProbeFail || r != canaryFailTTFT {
		t.Fatalf("expected ttft_breach, got %q/%q", o, r)
	}
	if o, r := eval("ABCD", canaryProbeMetrics{TTFTMS: 700, SustainedTPS: 8}, false); o != canaryProbeFail || r != canaryFailTPS {
		t.Fatalf("expected tps_breach, got %q/%q", o, r)
	}
	if o, r := eval("wrong", canaryProbeMetrics{TTFTMS: 700, SustainedTPS: 15}, false); o != canaryProbeFail || r != canaryFailNonce {
		t.Fatalf("expected nonce_mismatch, got %q/%q", o, r)
	}
	// Cold-start grace waives BOTH wall-time latency gates (enforce mode).
	if o, r := eval("ABCD", canaryProbeMetrics{TTFTMS: 9000, SustainedTPS: 8}, true); o != canaryProbePass || r != canaryFailNone {
		t.Fatalf("expected grace to waive both latency gates, got %q/%q", o, r)
	}
	// Grace never waives the answer-correctness gate.
	if o, r := eval("wrong", canaryProbeMetrics{TTFTMS: 9000, SustainedTPS: 15}, true); o != canaryProbeFail || r != canaryFailNonce {
		t.Fatalf("grace must NOT waive nonce gate, got %q/%q", o, r)
	}

	// Observe mode (default): a nonce-correct probe NEVER fails on latency, even
	// with a hard breach and no grace. The nonce gate still enforces.
	if o, r := evaluateCanaryProbe(challenge, "ABCD", "ABCD", canaryProbeMetrics{TTFTMS: 9000, SustainedTPS: 1}, false, false); o != canaryProbePass || r != canaryFailNone {
		t.Fatalf("observe mode must not sanction latency, got %q/%q", o, r)
	}
	if o, r := evaluateCanaryProbe(challenge, "wrong", "ABCD", canaryProbeMetrics{TTFTMS: 700, SustainedTPS: 15}, false, false); o != canaryProbeFail || r != canaryFailNonce {
		t.Fatalf("observe mode must still enforce nonce, got %q/%q", o, r)
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

	// Fresh connect within the window → graced.
	if !s.canaryColdStartActive(p(base)) {
		t.Fatal("fresh connect within window should be graced")
	}
	// Past the window → not graced, even with a stale ConnectedAt.
	now = base.Add(400 * time.Second)
	if s.canaryColdStartActive(p(base)) {
		t.Fatal("past the cold-start window should not be graced")
	}
	now = base
	// Future / negative-age connect is never graced (clock-skew guard).
	if s.canaryColdStartActive(p(base.Add(time.Hour))) {
		t.Fatal("future ConnectedAt must not be graced")
	}
	// Alternation guard: once the previous probe was graced (enforceNextCanary
	// set), the next probe is enforced even with a fresh reconnect ConnectedAt —
	// so churn cannot arrange to only ever be probed under grace.
	s.enforceNextCanary.Store("p1", struct{}{})
	if s.canaryColdStartActive(p(now)) {
		t.Fatal("must enforce the probe following a graced one, despite fresh connect")
	}
	// After an enforced probe clears the flag, a genuine cold start is graced again.
	s.enforceNextCanary.Delete("p1")
	if !s.canaryColdStartActive(p(now)) {
		t.Fatal("grace should re-arm after an enforced probe clears the flag")
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
