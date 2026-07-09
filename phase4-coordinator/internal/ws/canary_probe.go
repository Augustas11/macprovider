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
	// LatencyGraced is set when the TTFT gate WOULD have failed but was waived
	// because the provider was inside its cold-start grace window. Surfaced in
	// logs so a genuinely-slow provider hiding behind grace stays visible.
	LatencyGraced bool
}

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

// evaluateCanaryProbe returns the probe outcome. When coldStartGrace is true the
// max_ttft_ms latency gate is waived (the provider may still be cold-loading a
// large model after connecting) — but the nonce-correctness and min_sustained_tps
// gates are ALWAYS enforced, so this never weakens the anti-cheat guarantee.
func evaluateCanaryProbe(challenge config.CanaryChallengeConfig, output string, expected string, metrics canaryProbeMetrics, coldStartGrace bool) canaryProbeOutcome {
	if !canaryAnswerMatches(output, expected) {
		return canaryProbeFail
	}
	if !challengeHasLatencyGates(challenge) {
		return canaryProbePass
	}
	if !coldStartGrace && challenge.MaxTTFTMS > 0 && metrics.TTFTMS > challenge.MaxTTFTMS {
		return canaryProbeFail
	}
	if challenge.MinSustainedTPS > 0 && (math.IsNaN(metrics.SustainedTPS) || math.IsInf(metrics.SustainedTPS, 0) || metrics.SustainedTPS < challenge.MinSustainedTPS) {
		return canaryProbeFail
	}
	return canaryProbePass
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
