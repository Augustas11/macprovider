package buyer

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// toolGrammarFixture is the shared cross-language family fixture (#2355):
// the Swift provider, this coordinator, the gateway and the buyer-UX suite
// assert the same cases, so their copies of the SPEC-018 §3.1 rule cannot
// drift apart.
type toolGrammarFixture struct {
	Schema string `json:"schema"`
	Cases  []struct {
		Model  string `json:"model"`
		Family string `json:"family"`
	} `json:"cases"`
}

func TestToolGrammarFamilyMatchesSharedFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "tool-grammar-families.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture toolGrammarFixture
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.Schema != "macprovider.tool-grammar-families.v1" || len(fixture.Cases) == 0 {
		t.Fatalf("unexpected fixture: schema %q, %d cases", fixture.Schema, len(fixture.Cases))
	}
	covered := map[string]bool{}
	for _, c := range fixture.Cases {
		if got := toolGrammarFamily(c.Model); got != c.Family {
			t.Errorf("toolGrammarFamily(%q) = %q, want %q", c.Model, got, c.Family)
		}
		covered[c.Family] = true
	}
	for _, family := range []string{toolGrammarQwen, toolGrammarGLM, toolGrammarLlama3, toolGrammarGemma4, toolGrammarHarmony, toolGrammarDSML, toolGrammarLFM2, toolGrammarMiniMax} {
		if !covered[family] {
			t.Errorf("no fixture case for family %q", family)
		}
	}
}
