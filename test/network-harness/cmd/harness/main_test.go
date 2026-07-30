package main

import (
	"path/filepath"
	"testing"
)

func TestOriginalScenarioPathPreservesWrapperRelativeReferences(t *testing.T) {
	snapshot := filepath.Join(t.TempDir(), "run-scenario-snapshot.yaml")
	original := filepath.Join(t.TempDir(), "scenarios", "buyer.yaml")
	t.Setenv("HARNESS_SCENARIO_ORIGINAL_PATH", original)

	if got := originalScenarioPath(snapshot); got != original {
		t.Fatalf("originalScenarioPath=%q, want %q", got, original)
	}
}

func TestResolvePricingPathUsesOriginalScenarioDirectory(t *testing.T) {
	original := filepath.Join(t.TempDir(), "scenarios", "buyer.yaml")
	got := resolvePricingPath("../pricing.json", original)
	want := filepath.Join(filepath.Dir(original), "../pricing.json")

	if got != want {
		t.Fatalf("resolvePricingPath=%q, want %q", got, want)
	}
}
