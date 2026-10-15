package router

import (
	"encoding/json"
	"strings"
	"testing"
)

// Golden vectors shared with phase4-coordinator/internal/buyer: both services
// MUST compute identical SPEC-006 §7.2.1 class estimates.
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

// #1570: the prompt reservation covers token-dense prompts and never drops
// below the pre-#1570 ceil(bytes/4) + 64.
func TestPromptCapTokensCoversTokenDensePrompts(t *testing.T) {
	encoded, _ := json.Marshal(strings.Repeat("7", 4000))
	digits := []byte(`{"model":"m","messages":[{"role":"user","content":` + string(encoded) + `}]}`)
	if got := promptCapTokens(digits); got < 4000 {
		t.Fatalf("digit reservation=%d, want >= 4000 (one Qwen token per digit)", got)
	}
	for _, body := range [][]byte{
		digits,
		[]byte(`{"model":"m","messages":[{"role":"user","content":"` + strings.Repeat("机器学习", 500) + `"}]}`),
		[]byte(`not json`),
	} {
		if got, floor := promptCapTokens(body), estimatePromptTokens(body)+promptHeadroomTokens; got < floor {
			t.Fatalf("reservation=%d below bytes/4 floor %d", got, floor)
		}
	}
}
