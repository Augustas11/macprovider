// Tests for the coordinator.yaml pricing source (issue #223). The
// loader derives provider-net USD/1k rates from coord's rate_card ×
// global_multiplier × provider_share × stats.rollup.usd_per_million_credits.
package benchmark

import (
	"os"
	"path/filepath"
	"testing"
)

func writeYAML(t *testing.T, name, body string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCoordConfig_AllDefaults(t *testing.T) {
	// Empty yaml: every defaulted field should kick in.
	// Defaults: multiplier 1.0, share 0.90, usd_per_million_credits 1.0,
	// rate_card={default:{500k prompt / 1M completion}}.
	path := writeYAML(t, "coordinator.yaml", "")
	p, err := LoadPricing(path)
	if err != nil {
		t.Fatalf("LoadPricing: %v", err)
	}
	def, ok := p.ByModel["default"]
	if !ok {
		t.Fatalf("default entry missing: %+v", p.ByModel)
	}
	// 500k × 1.0 × 0.90 × 1.0 / 1e9 = 0.00045
	if def.PromptPricePer1k < 0.00044 || def.PromptPricePer1k > 0.00046 {
		t.Errorf("prompt: want ~0.00045, got %v", def.PromptPricePer1k)
	}
	// 1M × 1.0 × 0.90 × 1.0 / 1e9 = 0.0009
	if def.CompletionPricePer1k < 0.00089 || def.CompletionPricePer1k > 0.00091 {
		t.Errorf("completion: want ~0.0009, got %v", def.CompletionPricePer1k)
	}
	if len(p.Notes) < 4 {
		t.Errorf("expected ≥4 default-fallback notes, got %d: %v", len(p.Notes), p.Notes)
	}
}

func TestCoordConfig_ExplicitRateCard(t *testing.T) {
	// Per-model overrides + non-default multiplier + non-default usd factor.
	body := `
rewards:
  global_multiplier: 2.0
  provider_share: 0.80
  rate_card:
    "mlx-community/Qwen3-32B-4bit":
      prompt_credits_per_mtok: 2000000
      completion_credits_per_mtok: 5000000
    default:
      prompt_credits_per_mtok: 500000
      completion_credits_per_mtok: 1000000
stats:
  rollup:
    usd_per_million_credits: 1.5
`
	path := writeYAML(t, "coordinator.yaml", body)
	p, err := LoadPricing(path)
	if err != nil {
		t.Fatalf("LoadPricing: %v", err)
	}
	q, ok := p.ByModel["mlx-community/Qwen3-32B-4bit"]
	if !ok {
		t.Fatalf("Qwen3-32B-4bit missing: %+v", p.ByModel)
	}
	// 5_000_000 × 2.0 × 0.80 × 1.5 / 1e9 = 0.012
	if q.CompletionPricePer1k < 0.0119 || q.CompletionPricePer1k > 0.0121 {
		t.Errorf("Qwen3-32B completion: want ~0.012, got %v", q.CompletionPricePer1k)
	}
	// Default class also present, math: 1_000_000 × 2.0 × 0.80 × 1.5 / 1e9 = 0.0024
	def := p.ByModel["default"]
	if def.CompletionPricePer1k < 0.00239 || def.CompletionPricePer1k > 0.00241 {
		t.Errorf("default completion: want ~0.0024, got %v", def.CompletionPricePer1k)
	}
}

func TestCoordConfig_DefaultFallbackOnUnknownModel(t *testing.T) {
	// EarningsFor falls back to "default" entry when the model isn't
	// explicitly priced — matches coord's RateFor in billing/formula.go.
	body := `
rewards:
  rate_card:
    default:
      prompt_credits_per_mtok: 500000
      completion_credits_per_mtok: 1000000
`
	path := writeYAML(t, "coordinator.yaml", body)
	p, err := LoadPricing(path)
	if err != nil {
		t.Fatalf("LoadPricing: %v", err)
	}
	// Unknown model → falls back to default → $0.0009 / 1k completion
	earnings := p.EarningsFor("mlx-community/SomeNewModel", 0, 1000)
	if earnings < 0.00089 || earnings > 0.00091 {
		t.Errorf("default fallback: want ~0.0009 for 1k completion, got %v", earnings)
	}
	// And it should NOT be recorded as unknown (since the default rate applied)
	if c := p.UnknownModels["mlx-community/SomeNewModel"]; c != 0 {
		t.Errorf("unknown-model fallback to default should not record as unknown, got count %d", c)
	}
}

func TestCoordConfig_UnknownModelNoDefault(t *testing.T) {
	// Per-model rate card with NO default entry: unknown models earn 0
	// and get tracked in UnknownModels.
	body := `
rewards:
  rate_card:
    "modelA":
      prompt_credits_per_mtok: 500000
      completion_credits_per_mtok: 1000000
`
	path := writeYAML(t, "coordinator.yaml", body)
	p, err := LoadPricing(path)
	if err != nil {
		t.Fatalf("LoadPricing: %v", err)
	}
	earnings := p.EarningsFor("modelB", 0, 1000)
	if earnings != 0 {
		t.Errorf("no-default fallback: want $0 earnings, got %v", earnings)
	}
	if p.UnknownModels["modelB"] != 1 {
		t.Errorf("modelB should be recorded as unknown")
	}
}

func TestCoordConfig_ProductionPearlDefaults(t *testing.T) {
	// This matches Pearl's actual coordinator.yaml: NO rewards block at
	// all. Loader synthesizes defaults from coord defaults; B6 should
	// see ~$0.045/hr at 14 tok/s (per issue #222 calculation).
	body := `
listen:
  buyer_port: 8443
auth:
  operator_key: env:OPERATOR_KEY
storage:
  db_path: "/var/lib/macprovider/coordinator.db"
`
	path := writeYAML(t, "coordinator.yaml", body)
	p, err := LoadPricing(path)
	if err != nil {
		t.Fatalf("LoadPricing: %v", err)
	}
	// 14 tok/s × 3600 = 50,400 completion tokens/hr × $0.0009/1k = $0.0454
	earnings := p.EarningsFor("any-model", 0, 50400)
	if earnings < 0.044 || earnings > 0.046 {
		t.Errorf("Pearl-defaults earnings/hr math: want ~$0.045, got $%.4f", earnings)
	}
}

func TestCoordConfig_MalformedYAML(t *testing.T) {
	path := writeYAML(t, "coordinator.yaml", "this is: not: valid: yaml")
	_, err := LoadPricing(path)
	if err == nil {
		t.Error("expected error on malformed yaml")
	}
}

func TestCoordConfig_DotYmlExtension(t *testing.T) {
	// .yml extension should route to the yaml parser too.
	path := writeYAML(t, "coordinator.yml", `
rewards:
  rate_card:
    default:
      completion_credits_per_mtok: 1000000
`)
	p, err := LoadPricing(path)
	if err != nil {
		t.Fatalf("LoadPricing .yml: %v", err)
	}
	if _, ok := p.ByModel["default"]; !ok {
		t.Errorf("default entry missing from .yml parse")
	}
}

func TestStripSSHPath(t *testing.T) {
	cases := map[string]string{
		"pearl:/opt/macprovider/coordinator.yaml": "/opt/macprovider/coordinator.yaml",
		"/abs/local/file.json":                    "/abs/local/file.json",
		"specs/pricing.json":                      "specs/pricing.json",
		"user@host:/etc/foo.yml":                  "/etc/foo.yml",
	}
	for in, want := range cases {
		if got := stripSSHPath(in); got != want {
			t.Errorf("stripSSHPath(%q): got %q want %q", in, got, want)
		}
	}
}
