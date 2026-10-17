package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"gopkg.in/yaml.v3"
)

// TestVisionQualificationParityCorpus pins the coordinator side of the shared
// routing.vision_qualifications corpus. The ops validator in
// scripts/ops/lib/pearl-cli-config.py is checked against the same file by
// scripts/tests/test_pearl_cli_config.py, which also requires that every
// record ops accepts is one the coordinator accepts.
func TestVisionQualificationParityCorpus(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "scripts", "ops", "testdata", "vision-qualification-corpus.json"))
	if err != nil {
		t.Fatalf("read corpus: %v", err)
	}
	var corpus struct {
		Cases []struct {
			Name    string          `json:"name"`
			Record  json.RawMessage `json:"record"`
			GoValid bool            `json:"go_valid"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &corpus); err != nil {
		t.Fatalf("parse corpus: %v", err)
	}
	if len(corpus.Cases) == 0 {
		t.Fatal("corpus has no cases")
	}
	for _, tc := range corpus.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			// The overlay shape the ops task writes, decoded the way the
			// loader decodes an overlay over the base config.
			overlay := []byte(`{"routing":{"vision_qualifications":[` + string(tc.Record) + `]}}`)
			cfg := validTestConfig()
			err := yaml.Unmarshal(overlay, &cfg)
			if err == nil {
				err = cfg.Validate()
			}
			if got := err == nil; got != tc.GoValid {
				t.Fatalf("coordinator valid=%v want go_valid=%v (err=%v)", got, tc.GoValid, err)
			}
		})
	}
}
