package buyer

import (
	"encoding/json"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// TestModelFactsCapabilitiesMatchServingPredicates pins the capability badges
// Malibu shows (SPEC-044-R015, phase3-binary/catalog/autotune/model-facts.json)
// to the predicates this coordinator enforces for the same served model:
//
//   - tools: the model family has a tool grammar (toolGrammarFamily);
//   - reasoning: the template always reasons (reasoningFamily) or reasons on
//     request (onRequestReasoningFamily);
//   - vision: the model is the natively qualified vision model.
//
// A buyer-UX conformance record narrows tools and reasoning: a capability its
// checks did not pass is never advertised, so it is never a badge either. An
// owed record is a promotion step, not a verdict, and does not narrow.
func TestModelFactsCapabilitiesMatchServingPredicates(t *testing.T) {
	raw, err := os.ReadFile("../../../phase3-binary/catalog/autotune/model-facts.json")
	if err != nil {
		t.Fatal(err)
	}
	var facts struct {
		Rows map[string]struct {
			ModelID      string   `json:"model_id"`
			Capabilities []string `json:"capabilities"`
		} `json:"rows"`
	}
	if err := json.Unmarshal(raw, &facts); err != nil {
		t.Fatal(err)
	}
	if len(facts.Rows) == 0 {
		t.Fatal("model-facts.json has no rows")
	}
	recordsRaw, err := os.ReadFile("../../../phase3-binary/catalog/autotune/buyer-ux-conformance.json")
	if err != nil {
		t.Fatal(err)
	}
	var conformance struct {
		Records map[string]struct {
			Model        string              `json:"model"`
			Capabilities buyerUXCapabilities `json:"capabilities"`
		} `json:"records"`
	}
	if err := json.Unmarshal(recordsRaw, &conformance); err != nil {
		t.Fatal(err)
	}
	records := map[string]buyerUXCapabilities{}
	for _, record := range conformance.Records {
		records[strings.ToLower(record.Model)] = record.Capabilities
	}

	for key, row := range facts.Rows {
		record, hasRecord := records[strings.ToLower(row.ModelID)]
		want := []string{}
		if (reasoningFamily(row.ModelID) || onRequestReasoningFamily(row.ModelID)) && (!hasRecord || record.Reasoning) {
			want = append(want, "reasoning")
		}
		if toolGrammarFamily(row.ModelID) != "" && (!hasRecord || record.Tools) {
			want = append(want, "tools")
		}
		if row.ModelID == visionModelID {
			want = append(want, "vision")
		}
		sort.Strings(want)
		got := append([]string{}, row.Capabilities...)
		if got == nil {
			got = []string{}
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s (%s): capabilities %v, serving predicates give %v", key, row.ModelID, got, want)
		}
	}
}
