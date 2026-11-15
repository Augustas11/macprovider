package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The gateway's NormalizeModelKey mirrors the coordinator's billing one, so it
// is pinned to the same shared case table as billing and the Python port
// (scripts/tests/fixtures/normalize_model_key_cases.json).
func TestNormalizeModelKeySharedCaseTable(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "scripts", "tests", "fixtures", "normalize_model_key_cases.json"))
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
	if table.SchemaVersion != "macprovider.normalize-model-key-cases.v1" || len(table.Cases) == 0 {
		t.Fatalf("unexpected shared case table: schema %q, %d cases", table.SchemaVersion, len(table.Cases))
	}
	for _, testCase := range table.Cases {
		if got := NormalizeModelKey(testCase.Input); got != testCase.Expected {
			t.Errorf("NormalizeModelKey(%q) = %q, want %q", testCase.Input, got, testCase.Expected)
		}
	}
}
