package onboarding

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

type spec026JCSFixtures struct {
	Schema  string                `json:"schema"`
	Objects []spec026JCSObjectRow `json:"objects"`
}

type spec026JCSObjectRow struct {
	ID                string         `json:"id"`
	Body              map[string]any `json:"body"`
	ExpectedCanonical string         `json:"expected_canonical"`
}

func TestSpec026RegisterJCSFixtureParity(t *testing.T) {
	raw, err := os.ReadFile("../../test/jcs_fixtures/spec026_register.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fixtures spec026JCSFixtures
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.UseNumber()
	if err := dec.Decode(&fixtures); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if fixtures.Schema != "spec026_register_jcs_v1" {
		t.Fatalf("schema=%q", fixtures.Schema)
	}
	if len(fixtures.Objects) < 5 {
		t.Fatalf("fixture rows=%d want >=5", len(fixtures.Objects))
	}
	seen := map[string]bool{}
	for _, row := range fixtures.Objects {
		if row.ID == "" {
			t.Fatal("fixture row missing id")
		}
		if seen[row.ID] {
			t.Fatalf("duplicate fixture id %q", row.ID)
		}
		seen[row.ID] = true
		got, err := billing.CanonicalJSON(row.Body)
		if err != nil {
			t.Fatalf("%s canonicalize: %v", row.ID, err)
		}
		if string(got) != row.ExpectedCanonical {
			t.Fatalf("%s canonical mismatch\ngot:  %s\nwant: %s", row.ID, got, row.ExpectedCanonical)
		}
	}
	for _, id := range []string{
		"minimal_valid_http_body",
		"app_attest_present_valid_shape",
		"unicode_hardware_chip",
		"jcs_only_nested_object_variant",
		"signature_stripped_register_body_variant",
	} {
		if !seen[id] {
			t.Fatalf("missing required fixture row %q", id)
		}
	}
}
