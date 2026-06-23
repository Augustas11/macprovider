package jcs

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
)

func TestJCSParityFixtures(t *testing.T) {
	raw, err := os.ReadFile("../../testdata/jcs_parity.json")
	if err != nil {
		t.Fatalf("read parity fixtures: %v", err)
	}

	var fixtures []struct {
		ID                   string          `json:"id"`
		Input                json.RawMessage `json:"input"`
		ExpectedCanonicalB64 string          `json:"expected_canonical_b64"`
	}
	if err := json.Unmarshal(raw, &fixtures); err != nil {
		t.Fatalf("parse parity fixtures: %v", err)
	}

	for _, fixture := range fixtures {
		t.Run(fixture.ID, func(t *testing.T) {
			canonical, err := CanonicalizeJSON(fixture.Input)
			if err != nil {
				t.Fatalf("CanonicalizeJSON() error = %v", err)
			}
			got := base64.StdEncoding.EncodeToString(canonical)
			if got != fixture.ExpectedCanonicalB64 {
				t.Fatalf("canonical base64 = %q, want %q\ncanonical = %s", got, fixture.ExpectedCanonicalB64, canonical)
			}
		})
	}
}
