package billing

import (
	"os"
	"testing"

	"gopkg.in/yaml.v3"
)

// Epic #2029 recommendable cut: the catalog key, its OpenRouter slug, the bare
// name and the served artifact id all bill on the shipped zai-org/glm-5.3-flash
// row at the operator-approved 2026-10-18 price, never on `default`.
func TestRateFor_GLM53FlashResolvesShippedRow(t *testing.T) {
	raw, err := os.ReadFile("../../dist/coordinator.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Rewards struct {
			RateCard map[string]RateCardEntry `yaml:"rate_card"`
		} `yaml:"rewards"`
	}
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	card := doc.Rewards.RateCard
	want, ok := card["zai-org/glm-5.3-flash"]
	if !ok {
		t.Fatal("dist/coordinator.yaml rewards.rate_card lacks zai-org/glm-5.3-flash")
	}
	if want.PromptCreditsPerMtok != 18500 || want.PromptCacheHitCreditsPerMtok != 5500 || want.CompletionCreditsPerMtok != 88000 {
		t.Fatalf("zai-org/glm-5.3-flash row = %+v, want 18500 prompt / 5500 cache-hit / 88000 completion credits per Mtok", want)
	}
	for _, model := range []string{
		"zai-org/glm-5.3-flash",
		"z-ai/glm-5.3-flash",
		"Z-AI/GLM-5.3-Flash",
		"glm-5.3-flash",
		"Jundot/GLM-5.3-Flash-oQ4e-mtp",
	} {
		if key := NormalizeModelKey(model); key != "zai-org/glm-5.3-flash" {
			t.Fatalf("NormalizeModelKey(%q) = %q, want zai-org/glm-5.3-flash", model, key)
		}
		if got := RateFor(card, model); got != want {
			t.Fatalf("RateFor(%q) = %+v, want %+v", model, got, want)
		}
	}
}

// #2189: the abliterated GLM-5.3-Flash build is retired from the catalog and
// its labelled row is gone. Its spellings still normalize to its own key, so a
// stray request bills on `default`, never on the base GLM-5.3-Flash row.
func TestRateFor_GLM53FlashAbliteratedRetiredBillsDefault(t *testing.T) {
	raw, err := os.ReadFile("../../dist/coordinator.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Rewards struct {
			RateCard map[string]RateCardEntry `yaml:"rate_card"`
		} `yaml:"rewards"`
	}
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	card := doc.Rewards.RateCard
	if _, ok := card["zai-org/glm-5.3-flash-abliterated"]; ok {
		t.Fatal("dist/coordinator.yaml rewards.rate_card still carries the retired zai-org/glm-5.3-flash-abliterated row")
	}
	want, ok := card["default"]
	if !ok {
		t.Fatal("dist/coordinator.yaml rewards.rate_card lacks default")
	}
	for _, model := range []string{
		"zai-org/glm-5.3-flash-abliterated",
		"z-ai/glm-5.3-flash-abliterated",
		"glm-5.3-flash-abliterated",
		"grant-ai/GLM-5.3-Flash-Abliterated-MLX-4bit",
	} {
		if key := NormalizeModelKey(model); key != "zai-org/glm-5.3-flash-abliterated" {
			t.Fatalf("NormalizeModelKey(%q) = %q, want zai-org/glm-5.3-flash-abliterated", model, key)
		}
		if got := RateFor(card, model); got != want {
			t.Fatalf("RateFor(%q) = %+v, want default %+v", model, got, want)
		}
	}
	for _, model := range []string{"zai-org/glm-5.3-flash", "Jundot/GLM-5.3-Flash-oQ4e-mtp"} {
		if key := NormalizeModelKey(model); key != "zai-org/glm-5.3-flash" {
			t.Fatalf("NormalizeModelKey(%q) = %q, want zai-org/glm-5.3-flash", model, key)
		}
	}
}
