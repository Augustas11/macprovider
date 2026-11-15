package billing

import (
	"os"
	"testing"

	"gopkg.in/yaml.v3"
)

// #2236: Nemotron 3.5 Lightning 30B-A3B bills on its own row at the
// Nemotron 3 Nano price; none of its spellings falls through to the Nano row
// or to `default`, and no Nano spelling reaches it.
func TestRateFor_Nemotron35LightningResolvesOwnRow(t *testing.T) {
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
	want, ok := card["nemotron-3.5-lightning-30b-a3b"]
	if !ok {
		t.Fatal("dist/coordinator.yaml rewards.rate_card lacks nemotron-3.5-lightning-30b-a3b")
	}
	if nano := card["nemotron-3-nano-30b-a3b"]; want != nano {
		t.Fatalf("Lightning row = %+v, want the nemotron-3-nano-30b-a3b price %+v", want, nano)
	}
	for _, model := range []string{
		"nemotron-3.5-lightning-30b-a3b",
		"nvidia/nemotron-3.5-lightning-30b-a3b",
		"mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit",
	} {
		if key := NormalizeModelKey(model); key != "nemotron-3.5-lightning-30b-a3b" {
			t.Fatalf("NormalizeModelKey(%q) = %q, want nemotron-3.5-lightning-30b-a3b", model, key)
		}
		if got := RateFor(card, model); got != want {
			t.Fatalf("RateFor(%q) = %+v, want %+v", model, got, want)
		}
	}
	for _, model := range []string{"nvidia/nemotron-3-nano-30b-a3b", "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit"} {
		if key := NormalizeModelKey(model); key != "nemotron-3-nano-30b-a3b" {
			t.Fatalf("NormalizeModelKey(%q) = %q, want nemotron-3-nano-30b-a3b", model, key)
		}
	}
}

// #2329: Nemotron 3.5 Bolt 74B-A9B bills on its own row at the
// class-120b-moe class rate; its catalog key, upstream name and served
// rapid-mlx artifact resolve to it, never to the Lightning or Nano rows.
func TestRateFor_Nemotron35BoltResolvesOwnRow(t *testing.T) {
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
	want, ok := card["nemotron-3.5-bolt-74b-a9b"]
	if !ok {
		t.Fatal("dist/coordinator.yaml rewards.rate_card lacks nemotron-3.5-bolt-74b-a9b")
	}
	if want.PromptCreditsPerMtok != 68000 || want.PromptCacheHitCreditsPerMtok != 17000 || want.CompletionCreditsPerMtok != 136000 {
		t.Fatalf("Bolt row = %+v, want the class-120b-moe rates 68000/17000/136000", want)
	}
	for _, model := range []string{
		"nemotron-3.5-bolt-74b-a9b",
		"nvidia/nemotron-3.5-bolt-74b-a9b",
		"nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B",
		"rapid-mlx/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-MLX-4bit",
	} {
		if key := NormalizeModelKey(model); key != "nemotron-3.5-bolt-74b-a9b" {
			t.Fatalf("NormalizeModelKey(%q) = %q, want nemotron-3.5-bolt-74b-a9b", model, key)
		}
		if got := RateFor(card, model); got != want {
			t.Fatalf("RateFor(%q) = %+v, want %+v", model, got, want)
		}
	}
}
