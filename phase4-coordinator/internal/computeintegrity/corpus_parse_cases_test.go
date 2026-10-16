package computeintegrity

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
)

// TestParseCorpusSharedCases pins ParseCorpus to the cases the ops tooling's
// corpus check (scripts/ops/lib/pearl-cli-config.py) also runs: what the ops
// check accepts, the coordinator accepts.
func TestParseCorpusSharedCases(t *testing.T) {
	raw, err := os.ReadFile("testdata/corpus_parse_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Cases []struct {
			Name   string `json:"name"`
			DocB64 string `json:"doc_b64"`
			Go     bool   `json:"go"`
			Python bool   `json:"python"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range doc.Cases {
		body, err := base64.StdEncoding.DecodeString(c.DocB64)
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		if c.Python && !c.Go {
			t.Errorf("%s: the ops check may not accept what the coordinator rejects", c.Name)
		}
		_, err = ParseCorpus(body)
		if got := err == nil; got != c.Go {
			t.Errorf("%s: ParseCorpus accepted=%v, want %v (err=%v)", c.Name, got, c.Go, err)
		}
	}
}
