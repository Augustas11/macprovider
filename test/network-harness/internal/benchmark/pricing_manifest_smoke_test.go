// Smoke test for the new pricing manifest + path resolver.
package benchmark

import (
	"path/filepath"
	"testing"
)

func TestSmokeBenchmarkPricingV01(t *testing.T) {
	// scenario 10 lives at test/network-harness/scenarios/, pricing at repo-root specs/.
	// Mirror the production layout via test fixtures relative to this file.
	// This file is at internal/benchmark/, so repo root = ../../../..
	scenarioDir := filepath.Join("..", "..", "scenarios")
	scenarioPath := filepath.Join(scenarioDir, "10_provider_session_economics.yaml")
	// resolver lives in main.go; replicate the resolver inline here.
	source := "../../../specs/BENCHMARK_PRICING_v0.1.json"
	resolved := filepath.Join(filepath.Dir(scenarioPath), source)
	p, err := LoadPricing(resolved)
	if err != nil {
		t.Fatalf("LoadPricing(%q): %v", resolved, err)
	}
	if len(p.ByModel) < 3 {
		t.Fatalf("want at least 3 models, got %d (%v)", len(p.ByModel), p.ByModel)
	}
	must := []string{
		"mlx-community/Qwen2.5-7B-Instruct-4bit",
		"mlx-community/Qwen3-32B-4bit",
		"mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
	}
	for _, m := range must {
		if _, ok := p.ByModel[m]; !ok {
			t.Errorf("model missing from BENCHMARK_PRICING_v0.1.json: %s", m)
		}
	}
	// Math sanity: Qwen3-32B at 14 tok/s × 3600s = 50,400 completion tokens/hr
	// × $0.04/1k = $2.02/hr → well over $1.00 target.
	earnings := p.EarningsFor("mlx-community/Qwen3-32B-4bit", 0, 50400)
	if earnings < 1.50 || earnings > 2.50 {
		t.Errorf("expected ~$2.02 earnings for 50400 completion tokens, got $%.4f", earnings)
	}
}
