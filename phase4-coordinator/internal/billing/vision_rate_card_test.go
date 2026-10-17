package billing

import (
	"os"
	"testing"

	"gopkg.in/yaml.v3"
)

// #2016: buyers send the exact HF id for native image input, and a
// catalog-bound provider advertises the lowercase catalog key; both must
// price on the shipped qwen2-vl-2b-instruct row, never on `default`.
func TestRateFor_Qwen2VLResolvesShippedRow(t *testing.T) {
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
	want, ok := card["qwen2-vl-2b-instruct"]
	if !ok {
		t.Fatal("dist/coordinator.yaml rewards.rate_card lacks qwen2-vl-2b-instruct")
	}
	if want == card["default"] {
		t.Fatal("qwen2-vl-2b-instruct row must not equal the default row")
	}
	for _, model := range []string{
		"mlx-community/Qwen2-VL-2B-Instruct-4bit",
		"mlx-community/qwen2-vl-2b-instruct-4bit",
		"qwen2-vl-2b-instruct",
	} {
		if got := RateFor(card, model); got != want {
			t.Fatalf("RateFor(%q) = %+v, want %+v", model, got, want)
		}
	}
}
