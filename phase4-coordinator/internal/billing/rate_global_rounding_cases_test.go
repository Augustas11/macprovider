package billing

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestRateGlobalRoundingSharedCaseTable pins ParseShareBps / ParseMultiplierPPM
// against the SAME vectors the catalog release gate is pinned against
// (scripts/tests/test_catalog_artifact_feed.py, via
// catalog_release.scaled_nonnegative_integer).
//
// SPEC-023 §3.3.1 rule 9 makes the published rate card's release globals an
// EXACT equality with what this package derives from the coordinator config. The
// generator has to reproduce these two functions to enforce that equality, and a
// port written in decimal semantics answers a different integer whenever a
// value's binary64 product sits just off a half unit its decimal text lands on.
// Expectation literals duplicated on each side would not catch that; one shared
// table does, and it fails whichever side drifts.
func TestRateGlobalRoundingSharedCaseTable(t *testing.T) {
	path := filepath.Join("..", "..", "..", "scripts", "tests", "fixtures", "rate_global_rounding_cases.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared case table: %v", err)
	}
	var table struct {
		SchemaVersion   string `json:"schema_version"`
		ShareScale      int64  `json:"share_scale"`
		MultiplierScale int64  `json:"multiplier_scale"`
		Shares          []struct {
			Value    float64 `json:"value"`
			Expected int64   `json:"expected_bps"`
			Note     string  `json:"note"`
		} `json:"shares"`
		Multipliers []struct {
			Value    float64 `json:"value"`
			Expected int64   `json:"expected_ppm"`
			Note     string  `json:"note"`
		} `json:"multipliers"`
	}
	if err := json.Unmarshal(data, &table); err != nil {
		t.Fatalf("parse shared case table: %v", err)
	}
	if table.SchemaVersion != "macprovider.rate-global-rounding-cases.v1" {
		t.Fatalf("unexpected shared case table schema_version %q", table.SchemaVersion)
	}
	if len(table.Shares) == 0 || len(table.Multipliers) == 0 {
		t.Fatal("shared case table is empty")
	}
	// The scales the table was computed against must still be the ones these
	// functions apply, or every expectation below is pinned to the wrong product.
	if table.ShareScale != providerShareDenom {
		t.Fatalf("shared case table share_scale %d != providerShareDenom %d", table.ShareScale, providerShareDenom)
	}
	if table.MultiplierScale != globalMultiplierDenom {
		t.Fatalf("shared case table multiplier_scale %d != globalMultiplierDenom %d", table.MultiplierScale, globalMultiplierDenom)
	}
	for _, testCase := range table.Shares {
		if got := ParseShareBps(testCase.Value); got != testCase.Expected {
			t.Errorf("ParseShareBps(%v) = %d, want %d (%s)", testCase.Value, got, testCase.Expected, testCase.Note)
		}
	}
	for _, testCase := range table.Multipliers {
		if got := ParseMultiplierPPM(testCase.Value); got != testCase.Expected {
			t.Errorf("ParseMultiplierPPM(%v) = %d, want %d (%s)", testCase.Value, got, testCase.Expected, testCase.Note)
		}
	}
}
