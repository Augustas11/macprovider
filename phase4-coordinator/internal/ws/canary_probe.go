package ws

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

var (
	errCanaryChallengeBankEmpty   = errors.New("canary challenge bank is empty")
	errCanaryRandomSeedTooShort   = errors.New("canary random seed too short")
	errCanaryChallengePromptEmpty = errors.New("canary challenge prompt and expected must not be empty")
	errCanaryChallengeMissingNonce = errors.New("canary challenge prompt and expected must contain {nonce}")
)

type canaryBuiltProbe struct {
	Body           []byte
	Expected       string
	Challenge      config.CanaryChallengeConfig
	ModelClassBank bool
}

type canaryProbeMetrics struct {
	TTFTMS       int
	SustainedTPS float64
	LatencyGated bool
	// LatencyGraced is set when a latency gate (max_ttft_ms or min_sustained_tps)
	// WOULD have failed but was waived because the provider was inside its
	// cold-start grace window. Surfaced in logs so a genuinely-slow provider
	// hiding behind grace stays visible.
	LatencyGraced bool
	// FailReason records WHY a probe failed (nonce_mismatch, ttft_breach,
	// tps_breach, incomplete, relay_error) so prod canary-failure logs are
	// diagnosable. Empty on a pass.
	FailReason canaryFailReason
}

// canaryFailReason identifies why a canary probe failed. Empty on pass.
type canaryFailReason string

const (
	canaryFailNone       canaryFailReason = ""
	canaryFailNonce      canaryFailReason = "nonce_mismatch"
	canaryFailTTFT       canaryFailReason = "ttft_breach"
	canaryFailTPS        canaryFailReason = "tps_breach"
	canaryFailIncomplete canaryFailReason = "incomplete"
	canaryFailRelay      canaryFailReason = "relay_error"
)

type canaryAttemptResult struct {
	outcome        canaryProbeOutcome
	metrics        canaryProbeMetrics
	modelClassBank bool
	challenge      config.CanaryChallengeConfig
}

func buildCanaryProbe(modelID string, maxTokens int, challenges []config.CanaryChallengeConfig, modelClassBank bool) (canaryBuiltProbe, error) {
	body, expected, challenge, err := buildCanaryBodyFromBank(modelID, maxTokens, challenges)
	if err != nil {
		return canaryBuiltProbe{}, err
	}
	return canaryBuiltProbe{
		Body:           body,
		Expected:       expected,
		Challenge:      challenge,
		ModelClassBank: modelClassBank,
	}, nil
}

func buildCanaryBodyFromBank(modelID string, maxTokens int, challenges []config.CanaryChallengeConfig) ([]byte, string, config.CanaryChallengeConfig, error) {
	random, err := randomBytes(5)
	if err != nil {
		return nil, "", config.CanaryChallengeConfig{}, err
	}
	return buildCanaryBodyFromRandomWithChallenge(modelID, maxTokens, challenges, random)
}

func buildCanaryBodyFromRandomWithChallenge(modelID string, maxTokens int, challenges []config.CanaryChallengeConfig, random []byte) ([]byte, string, config.CanaryChallengeConfig, error) {
	if len(challenges) == 0 {
		return nil, "", config.CanaryChallengeConfig{}, errCanaryChallengeBankEmpty
	}
	if len(random) < 5 {
		return nil, "", config.CanaryChallengeConfig{}, errCanaryRandomSeedTooShort
	}
	challenge := challenges[int(random[4])%len(challenges)]
	promptTemplate := strings.TrimSpace(challenge.Prompt)
	expectedTemplate := strings.TrimSpace(challenge.Expected)
	if promptTemplate == "" || expectedTemplate == "" {
		return nil, "", config.CanaryChallengeConfig{}, errCanaryChallengePromptEmpty
	}
	if !strings.Contains(promptTemplate, "{nonce}") || !strings.Contains(expectedTemplate, "{nonce}") {
		return nil, "", config.CanaryChallengeConfig{}, errCanaryChallengeMissingNonce
	}
	nonce := strings.ToUpper(hex.EncodeToString(random[:4]))
	content := strings.ReplaceAll(promptTemplate, "{nonce}", nonce)
	expected := strings.ReplaceAll(expectedTemplate, "{nonce}", nonce)
	body, err := json.Marshal(map[string]any{
		"model": modelID,
		"messages": []map[string]string{{
			"role":    "user",
			"content": content,
		}},
		"max_tokens": maxTokens,
		"stream":     false,
	})
	if err != nil {
		return nil, "", config.CanaryChallengeConfig{}, err
	}
	return body, expected, challenge, nil
}

func challengeHasLatencyGates(challenge config.CanaryChallengeConfig) bool {
	return challenge.MaxTTFTMS > 0 || challenge.MinSustainedTPS > 0
}

// latencyBreachReason returns the specific latency gate the metrics violate
// (ttft_breach checked before tps_breach), or canaryFailNone if neither.
func latencyBreachReason(challenge config.CanaryChallengeConfig, metrics canaryProbeMetrics) canaryFailReason {
	if challenge.MaxTTFTMS > 0 && metrics.TTFTMS > challenge.MaxTTFTMS {
		return canaryFailTTFT
	}
	if challenge.MinSustainedTPS > 0 && (math.IsNaN(metrics.SustainedTPS) || math.IsInf(metrics.SustainedTPS, 0) || metrics.SustainedTPS < challenge.MinSustainedTPS) {
		return canaryFailTPS
	}
	return canaryFailNone
}

// challengeLatencyBreach reports whether the probe metrics violate a configured
// latency gate (max_ttft_ms or min_sustained_tps).
func challengeLatencyBreach(challenge config.CanaryChallengeConfig, metrics canaryProbeMetrics) bool {
	return latencyBreachReason(challenge, metrics) != canaryFailNone
}

// evaluateCanaryProbe returns the probe outcome and, on failure, the reason.
// The nonce-correctness gate (model identity / anti-downgrade) is ALWAYS
// enforced. The wall-time latency gates (max_ttft_ms / min_sustained_tps)
// SANCTION only when enforceLatency is true — canary probes are non-streaming
// (stream:false), so those metrics are structurally unreliable, and observe
// mode (the default) never fails a nonce-correct probe on latency. When
// enforceLatency is true, coldStartGrace additionally waives BOTH latency gates
// for the cold-start window; a graced probe is NEUTRAL for the sanction counter
// (see runCanaryProbe), so waiving cannot be abused to clear enforced-window
// failures.
func evaluateCanaryProbe(challenge config.CanaryChallengeConfig, output string, expected string, metrics canaryProbeMetrics, coldStartGrace bool, enforceLatency bool) (canaryProbeOutcome, canaryFailReason) {
	if !canaryAnswerMatches(output, expected) {
		return canaryProbeFail, canaryFailNonce
	}
	// Nonce correct. Latency gates sanction only in enforce mode, and are waived
	// during the cold-start grace window even then.
	if !enforceLatency || coldStartGrace {
		return canaryProbePass, canaryFailNone
	}
	if reason := latencyBreachReason(challenge, metrics); reason != canaryFailNone {
		return canaryProbeFail, reason
	}
	return canaryProbePass, canaryFailNone
}

func canaryMetricsFromTiming(start time.Time, firstTokenAt time.Time, completedAt time.Time, completionTokens int) canaryProbeMetrics {
	if completionTokens <= 0 {
		completionTokens = 1
	}
	ttft := completedAt.Sub(start)
	if !firstTokenAt.IsZero() {
		ttft = firstTokenAt.Sub(start)
	}
	decode := completedAt.Sub(start)
	if !firstTokenAt.IsZero() {
		decode = completedAt.Sub(firstTokenAt)
	}
	if decode <= 0 {
		decode = time.Millisecond
	}
	tps := float64(completionTokens) / decode.Seconds()
	return canaryProbeMetrics{
		TTFTMS:       int(ttft.Round(time.Millisecond) / time.Millisecond),
		SustainedTPS: tps,
		LatencyGated: true,
	}
}

func canaryCompletionTokens(raw []byte) int {
	var resp struct {
		Usage struct {
			CompletionTokens int `json:"completion_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return 0
	}
	return resp.Usage.CompletionTokens
}
