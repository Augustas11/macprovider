package verify

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestReasonEnumBijection(t *testing.T) {
	expectedReasons := []string{
		"signature_and_canonicalization_match",
		"signature_verify_failed",
		"prompt_hash_mismatch",
		"output_hash_mismatch",
		"pubkey_not_endorsed",
		"previous_key_outside_grace_window",
		"bundle_pubkey_provider_mismatch",
		"pubkey_unresolvable",
		"provider_id_not_in_pool",
		"cache_stale_and_live_unreachable",
		// SPEC-015 v0.3 §M.3.2.1 — new reason enum.
		"model_hash_mismatch",
		"model_hash_required",
		"model_id_not_in_catalog",
		"catalog_signature_invalid",
		"catalog_unreachable",
		"catalog_expired",
		"catalog_format_invalid",
		"unknown_receipt_version",
		"extra_field",
		"missing_field",
	}
	expected := make(map[string]bool, len(expectedReasons))
	for _, reason := range expectedReasons {
		expected[reason] = true
	}

	data, err := os.ReadFile(filepath.Join("..", "..", "schemas", "output.schema.json"))
	if err != nil {
		t.Fatalf("read output schema: %v", err)
	}
	var schema struct {
		OneOf []struct {
			Properties map[string]struct {
				Const string   `json:"const"`
				Enum  []string `json:"enum"`
			} `json:"properties"`
		} `json:"oneOf"`
	}
	if err := json.Unmarshal(data, &schema); err != nil {
		t.Fatalf("decode output schema: %v", err)
	}
	if len(schema.OneOf) != 3 {
		t.Fatalf("schema oneOf branch count = %d, want 3", len(schema.OneOf))
	}

	branchByReason := map[string][]int{}
	for branchIndex, branch := range schema.OneOf {
		reasonProperty, ok := branch.Properties["reason"]
		if !ok {
			t.Fatalf("schema branch %d missing reason property", branchIndex)
		}
		reasons := reasonProperty.Enum
		if reasonProperty.Const != "" {
			reasons = append(reasons, reasonProperty.Const)
		}
		if len(reasons) == 0 {
			t.Fatalf("schema branch %d has no reason const/enum", branchIndex)
		}
		for _, reason := range reasons {
			if !expected[reason] {
				t.Fatalf("schema reason %q is not in expectedReasons", reason)
			}
			branchByReason[reason] = append(branchByReason[reason], branchIndex)
		}
	}

	for _, reason := range expectedReasons {
		branches := branchByReason[reason]
		if len(branches) != 1 {
			t.Fatalf("expected reason %q appears in schema branches %v, want exactly one branch", reason, branches)
		}
	}

	verifyReasonConstants := []string{
		reasonValid,
		reasonSignatureFailed,
		reasonPromptHashMismatch,
		reasonOutputHashMismatch,
		reasonPubkeyNotEndorsed,
		reasonPreviousKeyOutsideGraceWindow,
		reasonBundlePubkeyProviderMismatch,
		reasonPubkeyUnresolvable,
		reasonProviderIDNotInPool,
		reasonCacheStaleAndLiveUnreachable,
		reasonModelHashMismatch,
		reasonModelHashRequired,
		reasonModelIDNotInCatalog,
		reasonCatalogSignatureInvalid,
		reasonCatalogUnreachable,
		reasonCatalogExpired,
		reasonCatalogFormatInvalid,
		reasonUnknownReceiptVersion,
		reasonExtraField,
		reasonMissingField,
	}
	for _, reason := range verifyReasonConstants {
		if !expected[reason] {
			t.Fatalf("verify reason constant %q is not in expectedReasons", reason)
		}
	}
	if len(verifyReasonConstants) != len(expectedReasons) {
		t.Fatalf("verify reason constant count = %d, want %d", len(verifyReasonConstants), len(expectedReasons))
	}
}
