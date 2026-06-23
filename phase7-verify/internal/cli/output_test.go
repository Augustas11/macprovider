package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/schemavalidator"
	"github.com/augstar/macprovider/phase7-verify/internal/verify"
)

const (
	outputProviderID      = "m1-anon"
	outputModelID         = "qwen2.5-7b-instruct-q4"
	outputSignedAt        = int64(1719144000)
	outputCoordinatorHost = "coordinator.streamvc.live"
)

func TestRenderJSONExamples(t *testing.T) {
	tests := []struct {
		name   string
		result verify.Result
		want   string
	}{
		{
			name:   "valid",
			result: validOutputFixture(nil),
			want:   `{"result":"valid","reason":"signature_and_canonicalization_match","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"live","coordinator_host":"coordinator.streamvc.live"}` + "\n",
		},
		{
			name: "invalid",
			result: verify.Result{
				Result:          "invalid",
				Reason:          "output_hash_mismatch",
				ProviderID:      outputProviderID,
				ModelID:         outputModelID,
				SignedAt:        outputSignedAt,
				TrustSource:     "live",
				CoordinatorHost: outputCoordinatorHost,
				Details: &verify.Details{
					Field:    "output_hash",
					Computed: "ab12...",
					Receipt:  "cd34...",
				},
			},
			want: `{"result":"invalid","reason":"output_hash_mismatch","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"live","coordinator_host":"coordinator.streamvc.live","details":{"field":"output_hash","computed":"ab12...","receipt":"cd34..."}}` + "\n",
		},
		{
			name: "inconclusive",
			result: verify.Result{
				Result:          "inconclusive",
				Reason:          "cache_stale_and_live_unreachable",
				ProviderID:      outputProviderID,
				ModelID:         outputModelID,
				SignedAt:        outputSignedAt,
				TrustSource:     "none",
				CoordinatorHost: "",
				Warnings: []verify.Warning{{
					Kind:   "live_check_skipped",
					Fields: map[string]any{"reason": "network_unreachable"},
				}},
			},
			want: `{"result":"inconclusive","reason":"cache_stale_and_live_unreachable","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"none","coordinator_host":null,"warnings":[{"kind":"live_check_skipped","reason":"network_unreachable"}]}` + "\n",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := renderJSON(tt.result)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != tt.want {
				t.Fatalf("renderJSON()=%q want %q", string(got), tt.want)
			}
		})
	}
}

func TestRenderHumanExamples(t *testing.T) {
	tests := []struct {
		name   string
		result verify.Result
		want   string
	}{
		{
			name:   "valid",
			result: validOutputFixture(nil),
			want: fmt.Sprintf("valid (m1-anon · qwen2.5-7b-instruct-q4 · signed %s · trust=live@coordinator.streamvc.live)\n",
				time.Unix(outputSignedAt, 0).UTC().Format(time.RFC3339),
			),
		},
		{
			name: "invalid",
			result: verify.Result{
				Result: "invalid",
				Reason: "output_hash_mismatch",
				Details: &verify.Details{
					Field:    "output_hash",
					Computed: "ab12...",
					Receipt:  "cd34...",
				},
			},
			want: "invalid: output_hash mismatch (computed=ab12... receipt=cd34...)\n",
		},
		{
			name: "inconclusive",
			result: verify.Result{
				Result:          "inconclusive",
				Reason:          "cache_stale_and_live_unreachable",
				CoordinatorHost: outputCoordinatorHost,
			},
			want: "inconclusive: cache stale and /v1/receipt-keys unreachable on coordinator.streamvc.live\n",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := renderHuman(tt.result); got != tt.want {
				t.Fatalf("renderHuman()=%q want %q", got, tt.want)
			}
		})
	}
}

func TestRenderHumanValidNoExplicitTrust(t *testing.T) {
	result := validOutputFixture(nil)
	result.TrustSource = "explicit_pubkey"
	result.CoordinatorHost = ""

	got := renderHuman(result)
	if strings.Contains(got, "@") {
		t.Fatalf("renderHuman()=%q, explicit_pubkey trust must not include @host", got)
	}
	if !strings.Contains(got, "trust=explicit_pubkey") {
		t.Fatalf("renderHuman()=%q missing explicit_pubkey trust", got)
	}
}

func TestRenderHumanInvalidGraceWindow(t *testing.T) {
	got := renderHuman(verify.Result{
		Result: "invalid",
		Reason: "previous_key_outside_grace_window",
		Details: &verify.Details{
			Field:   "grace_window",
			Receipt: "receipt-pubkey",
			Extra: map[string]any{
				"unix_ts":    int64(1719144000),
				"rotated_at": int64(1719000000),
				"expires_at": int64(1719100000),
			},
		},
	})
	want := "invalid: previous_key_outside_grace_window (unix_ts=1719144000 rotated_at=1719000000 expires_at=1719100000)\n"
	if got != want {
		t.Fatalf("renderHuman()=%q want %q", got, want)
	}
}

func TestRenderHumanInconclusiveCacheStale(t *testing.T) {
	got := renderHuman(verify.Result{
		Result:          "inconclusive",
		Reason:          "cache_stale_and_live_unreachable",
		CoordinatorHost: "other.example",
	})
	want := "inconclusive: cache stale and /v1/receipt-keys unreachable on other.example\n"
	if got != want {
		t.Fatalf("renderHuman()=%q want %q", got, want)
	}
}

func TestRenderJSONOmitsDetailsForNonInvalid(t *testing.T) {
	result := validOutputFixture(nil)
	result.Details = &verify.Details{Field: "output_hash", Computed: "x", Receipt: "y"}
	got := mustRenderJSONMap(t, result)
	if _, ok := got["details"]; ok {
		t.Fatalf("renderJSON emitted details for valid result: %#v", got)
	}
}

func TestRenderJSONOmitsComputedForSignatureField(t *testing.T) {
	got := mustRenderJSONMap(t, verify.Result{
		Result:          "invalid",
		Reason:          "signature_verify_failed",
		ProviderID:      outputProviderID,
		ModelID:         outputModelID,
		SignedAt:        outputSignedAt,
		TrustSource:     "live",
		CoordinatorHost: outputCoordinatorHost,
		Details:         &verify.Details{Field: "signature", Computed: "opaque", Receipt: "sig"},
	})
	details, ok := got["details"].(map[string]any)
	if !ok {
		t.Fatalf("details missing or wrong type: %#v", got["details"])
	}
	if _, ok := details["computed"]; ok {
		t.Fatalf("renderJSON emitted computed for signature details: %#v", details)
	}
}

func TestRenderJSONWarningsArrayOmittedWhenEmpty(t *testing.T) {
	got := mustRenderJSONMap(t, validOutputFixture(nil))
	if _, ok := got["warnings"]; ok {
		t.Fatalf("renderJSON emitted empty warnings: %#v", got)
	}
}

func TestRenderJSONFlattensWarningFields(t *testing.T) {
	result := validOutputFixture([]verify.Warning{{
		Kind: "clock_skew",
		Fields: map[string]any{
			"unix_ts":       int64(1719144000),
			"system_time":   int64(1719320400),
			"delta_seconds": int64(176400),
		},
	}})
	got, err := renderJSON(result)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(got, []byte(`"warnings":[{"kind":"clock_skew","delta_seconds":176400,"system_time":1719320400,"unix_ts":1719144000}]`)) {
		t.Fatalf("warning was not flattened with kind-specific fields: %s", got)
	}
	if bytes.Contains(got, []byte(`"fields"`)) {
		t.Fatalf("warning leaked nested fields object: %s", got)
	}
}

func TestRenderWarningsToStderr(t *testing.T) {
	warnings := []verify.Warning{
		{Kind: "non_default_coordinator", Fields: map[string]any{"coordinator_host": "other.example"}},
		{Kind: "explicit_vs_live_divergence", Fields: map[string]any{"live_pubkey": "live-key", "coordinator_host": "other.example"}},
		{Kind: "live_check_skipped", Fields: map[string]any{"reason": "offline_flag"}},
		{Kind: "clock_skew", Fields: map[string]any{"unix_ts": int64(1719144000), "system_time": int64(1719320400), "delta_seconds": int64(176400)}},
	}
	var stderr bytes.Buffer
	renderWarningsToStderr(&stderr, warnings)
	want := strings.Join([]string{
		"warning: non-default coordinator other.example",
		"warning: explicit --pubkey differs from coordinator-published pubkey live-key at other.example",
		"warning: live divergence check skipped (offline_flag)",
		"warning: clock skew (receipt unix_ts=1719144000, system_time=1719320400, delta=176400s)",
		"",
	}, "\n")
	if stderr.String() != want {
		t.Fatalf("stderr=%q want %q", stderr.String(), want)
	}
}

func TestSchemaValidationValid(t *testing.T) {
	assertSchemaValid(t, validOutputFixture(nil))
}

func TestSchemaValidationInvalid(t *testing.T) {
	assertSchemaValid(t, verify.Result{
		Result:          "invalid",
		Reason:          "output_hash_mismatch",
		ProviderID:      outputProviderID,
		ModelID:         outputModelID,
		SignedAt:        outputSignedAt,
		TrustSource:     "live",
		CoordinatorHost: outputCoordinatorHost,
		Details:         &verify.Details{Field: "output_hash", Computed: "ab12...", Receipt: "cd34..."},
	})
}

func TestSchemaValidationReservedBundlePubkeyProviderMismatch(t *testing.T) {
	schema := loadOutputSchema(t)
	if !invalidReasonEnumContains(schema, "bundle_pubkey_provider_mismatch") {
		t.Fatal("invalid reason enum missing bundle_pubkey_provider_mismatch")
	}
	assertSchemaValidWithSchema(t, schema, verify.Result{
		Result:          "invalid",
		Reason:          "bundle_pubkey_provider_mismatch",
		ProviderID:      outputProviderID,
		ModelID:         outputModelID,
		SignedAt:        outputSignedAt,
		TrustSource:     "live",
		CoordinatorHost: outputCoordinatorHost,
		Details:         &verify.Details{Field: "pubkey", Computed: "provider-a", Receipt: "provider-b"},
	})
}

func TestSchemaValidationInconclusive(t *testing.T) {
	assertSchemaValid(t, verify.Result{
		Result:          "inconclusive",
		Reason:          "cache_stale_and_live_unreachable",
		ProviderID:      outputProviderID,
		ModelID:         outputModelID,
		SignedAt:        outputSignedAt,
		TrustSource:     "none",
		CoordinatorHost: "",
		Warnings: []verify.Warning{{
			Kind:   "live_check_skipped",
			Fields: map[string]any{"reason": "network_unreachable"},
		}},
	})
}

func TestSchemaRejectsExtraProperty(t *testing.T) {
	schema := loadOutputSchema(t)
	raw := []byte(`{"result":"valid","reason":"signature_and_canonicalization_match","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"live","coordinator_host":"coordinator.streamvc.live","foo":"bar"}`)
	if err := validateRawJSON(schema, raw); err == nil {
		t.Fatal("schema accepted extra top-level property")
	}
}

func TestSchemaRejectsTrustSourceCoordinatorHostMismatches(t *testing.T) {
	schema := loadOutputSchema(t)
	tests := []struct {
		name string
		raw  []byte
	}{
		{
			name: "valid none trust source",
			raw:  []byte(`{"result":"valid","reason":"signature_and_canonicalization_match","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"none","coordinator_host":null}`),
		},
		{
			name: "valid live null coordinator",
			raw:  []byte(`{"result":"valid","reason":"signature_and_canonicalization_match","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"live","coordinator_host":null}`),
		},
		{
			name: "valid explicit pubkey coordinator",
			raw:  []byte(`{"result":"valid","reason":"signature_and_canonicalization_match","provider_id":"m1-anon","model_id":"qwen2.5-7b-instruct-q4","signed_at":1719144000,"trust_source":"explicit_pubkey","coordinator_host":"coordinator.streamvc.live"}`),
		},
		{
			name: "inconclusive live null coordinator",
			raw:  []byte(`{"result":"inconclusive","reason":"cache_stale_and_live_unreachable","trust_source":"live","coordinator_host":null}`),
		},
		{
			name: "inconclusive none coordinator",
			raw:  []byte(`{"result":"inconclusive","reason":"cache_stale_and_live_unreachable","trust_source":"none","coordinator_host":"coordinator.streamvc.live"}`),
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := validateRawJSON(schema, tt.raw); err == nil {
				t.Fatalf("schema accepted malformed trust_source/coordinator_host combination: %s", tt.raw)
			}
		})
	}
}

func validOutputFixture(warnings []verify.Warning) verify.Result {
	return verify.Result{
		Result:          "valid",
		Reason:          "signature_and_canonicalization_match",
		ProviderID:      outputProviderID,
		ModelID:         outputModelID,
		SignedAt:        outputSignedAt,
		TrustSource:     "live",
		CoordinatorHost: outputCoordinatorHost,
		Warnings:        warnings,
	}
}

func mustRenderJSONMap(t *testing.T, result verify.Result) map[string]any {
	t.Helper()
	data, err := renderJSON(result)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		t.Fatalf("renderJSON emitted invalid JSON: %v in %s", err, data)
	}
	return decoded
}

func assertSchemaValid(t *testing.T, result verify.Result) {
	t.Helper()
	schema := loadOutputSchema(t)
	assertSchemaValidWithSchema(t, schema, result)
}

func assertSchemaValidWithSchema(t *testing.T, schema []byte, result verify.Result) {
	t.Helper()
	data, err := renderJSON(result)
	if err != nil {
		t.Fatal(err)
	}
	if err := schemavalidator.Validate(schema, data); err != nil {
		t.Fatalf("schema rejected %s: %v", data, err)
	}
}

func loadOutputSchema(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "schemas", "output.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func invalidReasonEnumContains(schemaData []byte, reason string) bool {
	var schema any
	if err := json.Unmarshal(schemaData, &schema); err != nil {
		return false
	}
	root, ok := schema.(map[string]any)
	if !ok {
		return false
	}
	variants, ok := root["oneOf"].([]any)
	if !ok || len(variants) < 2 {
		return false
	}
	invalidBranch, ok := variants[1].(map[string]any)
	if !ok {
		return false
	}
	properties, ok := invalidBranch["properties"].(map[string]any)
	if !ok {
		return false
	}
	reasonSchema, ok := properties["reason"].(map[string]any)
	if !ok {
		return false
	}
	enumValues, ok := reasonSchema["enum"].([]any)
	if !ok {
		return false
	}
	for _, enumValue := range enumValues {
		if enumValue == reason {
			return true
		}
	}
	return false
}

func validateRawJSON(schema []byte, raw []byte) error {
	return schemavalidator.Validate(schema, raw)
}
