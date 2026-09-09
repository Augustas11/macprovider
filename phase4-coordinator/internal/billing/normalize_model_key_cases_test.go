package billing

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestNormalizeModelKeySharedCaseTable pins NormalizeModelKey against the SAME
// case table the Python port in scripts/catalog-release.py is pinned against
// (scripts/tests/test_catalog_artifact_feed.py). The catalog release generator
// resolves SPEC-023 §3.3.1 rule 7 — "every recommendable candidate row MUST
// resolve to a published rate row" — through that port, so a change to this
// function that the port does not follow would let a release be cut whose
// authoring-time rate resolution disagrees with the resolution billing actually
// performs. Duplicated expectation literals on each side would not catch that;
// one shared table does.
func TestNormalizeModelKeySharedCaseTable(t *testing.T) {
	path := filepath.Join("..", "..", "..", "scripts", "tests", "fixtures", "normalize_model_key_cases.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared case table: %v", err)
	}
	var table struct {
		SchemaVersion string `json:"schema_version"`
		Cases         []struct {
			Input    string `json:"input"`
			Expected string `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &table); err != nil {
		t.Fatalf("parse shared case table: %v", err)
	}
	if table.SchemaVersion != "macprovider.normalize-model-key-cases.v1" {
		t.Fatalf("unexpected shared case table schema_version %q", table.SchemaVersion)
	}
	if len(table.Cases) == 0 {
		t.Fatal("shared case table is empty")
	}
	for _, testCase := range table.Cases {
		if got := NormalizeModelKey(testCase.Input); got != testCase.Expected {
			t.Errorf("NormalizeModelKey(%q) = %q, want %q", testCase.Input, got, testCase.Expected)
		}
	}
}
