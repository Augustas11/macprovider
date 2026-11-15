package router

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The gateway's OpenRouter tool-family predicate against the shared
// cross-language fixture (#2355): a model has tools exactly when the fixture
// gives it a family, as the coordinator's toolGrammarFamily does.
func TestOpenRouterToolFamilyMatchesSharedFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "tool-grammar-families.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Schema string `json:"schema"`
		Cases  []struct {
			Model  string `json:"model"`
			Family string `json:"family"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.Schema != "macprovider.tool-grammar-families.v1" || len(fixture.Cases) == 0 {
		t.Fatalf("unexpected fixture: schema %q, %d cases", fixture.Schema, len(fixture.Cases))
	}
	for _, c := range fixture.Cases {
		if got, want := openRouterToolFamilyModel(c.Model), c.Family != ""; got != want {
			t.Errorf("openRouterToolFamilyModel(%q) = %v, want %v (family %q)", c.Model, got, want, c.Family)
		}
	}
}
