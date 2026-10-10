package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestSettlementEvidenceArchiveRequiresArchiveAndKnownAction(t *testing.T) {
	var out bytes.Buffer
	if err := settlementEvidenceArchive(nil, &out); err == nil {
		t.Fatal("no action accepted")
	}
	if err := settlementEvidenceArchive([]string{"verify"}, &out); err == nil || !strings.Contains(err.Error(), "--archive") {
		t.Fatalf("missing archive err=%v", err)
	}
	if err := settlementEvidenceArchive([]string{"rederive", "--archive", "/nonexistent.jsonl.gz"}, &out); err == nil || !strings.Contains(err.Error(), "--credit-id") {
		t.Fatalf("missing credit id err=%v", err)
	}
	if err := settlementEvidenceArchive([]string{"delete", "--archive", "/nonexistent.jsonl.gz"}, &out); err == nil || !strings.Contains(err.Error(), "unknown") {
		t.Fatalf("unknown action err=%v", err)
	}
	if err := settlementEvidenceArchive([]string{"verify", "--archive", "/nonexistent.jsonl.gz"}, &out); err == nil {
		t.Fatal("missing archive verified")
	}
}
