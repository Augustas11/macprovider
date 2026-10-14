package buyer

import (
	"encoding/json"
	"strings"
	"testing"
)

func chatBodyWithContent(content string) json.RawMessage {
	encoded, _ := json.Marshal(content)
	return json.RawMessage(`{"model":"m","messages":[{"role":"user","content":` + string(encoded) + `}]}`)
}

// #1570 / SPEC-006 §7.2.1: the provider prompt-token bound covers
// token-dense prompts that bytes/4 under-counted.
func TestPromptTokenUpperBoundCoversTokenDensePrompts(t *testing.T) {
	// Qwen tokenizes digits one per token: 4000 digits are about 4000 tokens,
	// while bytes/4 is about 1000.
	digits := chatBodyWithContent(strings.Repeat("7", 4000))
	if bound := promptTokenUpperBound(digits); bound < 4000 {
		t.Fatalf("digit bound=%d, want >= 4000", bound)
	}
	// The bound never drops below the pre-#1570 bytes/4 + 64.
	cjk := chatBodyWithContent(strings.Repeat("机器学习", 1000))
	if bound, floor := promptTokenUpperBound(cjk), int64(estimateTokens(cjk))+promptHeadroomTokens; bound < floor {
		t.Fatalf("cjk bound=%d below bytes/4 floor %d", bound, floor)
	}
}

// The routing estimate does not over-count text that packs several bytes per
// token, which bytes/4 rejected against a provider's context.
func TestRoutingPromptTokenEstimateDoesNotOverCountDenseScripts(t *testing.T) {
	// Russian prose: about 0.22 Qwen3.6 tokens per character, 2 bytes per
	// letter, so bytes/4 is about 2x the tokenizer count.
	russian := chatBodyWithContent(strings.Repeat("Машинное обучение — это область искусственного интеллекта. ", 400))
	chars := int64(len([]rune(strings.Repeat("Машинное обучение — это область искусственного интеллекта. ", 400))))
	approxTokens := chars * 22 / 100
	if got := int64(routingPromptTokenEstimate(russian)); got > approxTokens*11/10 {
		t.Fatalf("russian routing estimate=%d, want <= 1.1x tokenizer count %d", got, approxTokens)
	}
	if old := int64(estimateTokens(russian)); old < approxTokens*17/10 {
		t.Fatalf("fixture: bytes/4=%d should over-count %d", old, approxTokens)
	}
	// JSON escapes are decoded before counting.
	escaped := json.RawMessage(`{"messages":[{"role":"user","content":"` + strings.Repeat(`\`+"u4e2d", 3000) + `"}]}`)
	if got := routingPromptTokenEstimate(escaped); got > 1500 {
		t.Fatalf("escaped CJK routing estimate=%d, want about 0.45/char", got)
	}
	if got := routingPromptTokenEstimate(json.RawMessage(`{}`)); got != 1 {
		t.Fatalf("empty routing estimate=%d, want 1", got)
	}
	bad := json.RawMessage(`{"messages":[` + strings.Repeat("x", 400))
	if got, want := routingPromptTokenEstimate(bad), estimateTokens(bad); got != want {
		t.Fatalf("malformed routing estimate=%d want bytes/4 fallback %d", got, want)
	}
}

// Golden vectors shared with phase5-gateway/internal/router: both services
// MUST compute identical class estimates.
func TestPromptTokenClassEstimateGolden(t *testing.T) {
	for _, tc := range promptTokenClassGoldenCases {
		upper, ok := promptTokenClassEstimate([]byte(tc.body), promptTokenUpperWeights)
		if !ok || upper != tc.upper {
			t.Errorf("%s upper=%d ok=%v want %d", tc.name, upper, ok, tc.upper)
		}
		central, ok := promptTokenClassEstimate([]byte(tc.body), promptTokenCentralWeights)
		if !ok || central != tc.central {
			t.Errorf("%s central=%d ok=%v want %d", tc.name, central, ok, tc.central)
		}
	}
}
