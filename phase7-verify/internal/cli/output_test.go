package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

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

func assertSchemaValidWithSchema(t *testing.T, schema any, result verify.Result) {
	t.Helper()
	data, err := renderJSON(result)
	if err != nil {
		t.Fatal(err)
	}
	if err := validateRawJSON(schema, data); err != nil {
		t.Fatalf("schema rejected %s: %v", data, err)
	}
}

func loadOutputSchema(t *testing.T) any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "schemas", "output.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	var schema any
	if err := json.Unmarshal(data, &schema); err != nil {
		t.Fatal(err)
	}
	return schema
}

func invalidReasonEnumContains(schema any, reason string) bool {
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

func validateRawJSON(schema any, raw []byte) error {
	var instance any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&instance); err != nil {
		return err
	}
	return validateSchema(schema, instance, "$")
}

func validateSchema(schema any, instance any, path string) error {
	switch typedSchema := schema.(type) {
	case bool:
		if typedSchema {
			return nil
		}
		return fmt.Errorf("%s rejected by false schema", path)
	case map[string]any:
		return validateSchemaObject(typedSchema, instance, path)
	default:
		return fmt.Errorf("%s invalid schema node %T", path, schema)
	}
}

func validateSchemaObject(schema map[string]any, instance any, path string) error {
	if variants, ok := schema["oneOf"].([]any); ok {
		matches := 0
		var lastErr error
		for _, variant := range variants {
			if err := validateSchema(variant, instance, path); err == nil {
				matches++
			} else {
				lastErr = err
			}
		}
		if matches != 1 {
			if lastErr == nil {
				lastErr = errors.New("no branch detail")
			}
			return fmt.Errorf("%s matched %d oneOf branches: %w", path, matches, lastErr)
		}
	}
	if allVariants, ok := schema["allOf"].([]any); ok {
		for _, variant := range allVariants {
			if err := validateSchema(variant, instance, path); err != nil {
				return err
			}
		}
	}
	if notSchema, ok := schema["not"]; ok {
		if err := validateSchema(notSchema, instance, path); err == nil {
			return fmt.Errorf("%s matched forbidden not schema", path)
		}
	}
	if typeSpec, ok := schema["type"]; ok && !schemaTypeMatches(typeSpec, instance) {
		return fmt.Errorf("%s has type %T, does not match %v", path, instance, typeSpec)
	}
	if constValue, ok := schema["const"]; ok && !jsonScalarEqual(instance, constValue) {
		return fmt.Errorf("%s=%v does not equal const %v", path, instance, constValue)
	}
	if enumValues, ok := schema["enum"].([]any); ok {
		matched := false
		for _, enumValue := range enumValues {
			if jsonScalarEqual(instance, enumValue) {
				matched = true
				break
			}
		}
		if !matched {
			return fmt.Errorf("%s=%v not in enum %v", path, instance, enumValues)
		}
	}
	object, isObject := instance.(map[string]any)
	if required, ok := schema["required"].([]any); ok {
		if !isObject {
			return fmt.Errorf("%s required applied to non-object", path)
		}
		for _, field := range required {
			name, _ := field.(string)
			if _, ok := object[name]; !ok {
				return fmt.Errorf("%s missing required field %q", path, name)
			}
		}
	}
	properties, hasProperties := schema["properties"].(map[string]any)
	if hasProperties && isObject {
		for key, value := range object {
			if propertySchema, ok := properties[key]; ok {
				if err := validateSchema(propertySchema, value, path+"."+key); err != nil {
					return err
				}
			}
		}
		if additional, ok := schema["additionalProperties"].(bool); ok && !additional {
			for key := range object {
				if _, ok := properties[key]; !ok {
					return fmt.Errorf("%s has additional property %q", path, key)
				}
			}
		}
	}
	if itemSchema, ok := schema["items"]; ok {
		items, ok := instance.([]any)
		if !ok {
			return fmt.Errorf("%s items applied to non-array", path)
		}
		for i, item := range items {
			if err := validateSchema(itemSchema, item, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
	}
	if ifSchema, ok := schema["if"]; ok {
		ifErr := validateSchema(ifSchema, instance, path)
		if ifErr == nil {
			if thenSchema, ok := schema["then"]; ok {
				if err := validateSchema(thenSchema, instance, path); err != nil {
					return err
				}
			}
		} else if elseSchema, ok := schema["else"]; ok {
			if err := validateSchema(elseSchema, instance, path); err != nil {
				return err
			}
		}
	}
	return nil
}

func schemaTypeMatches(typeSpec any, value any) bool {
	switch typed := typeSpec.(type) {
	case string:
		return singleSchemaTypeMatches(typed, value)
	case []any:
		for _, candidate := range typed {
			if name, ok := candidate.(string); ok && singleSchemaTypeMatches(name, value) {
				return true
			}
		}
		return false
	default:
		return false
	}
}

func singleSchemaTypeMatches(name string, value any) bool {
	switch name {
	case "null":
		return value == nil
	case "string":
		_, ok := value.(string)
		return ok
	case "integer":
		switch n := value.(type) {
		case json.Number:
			_, err := n.Int64()
			return err == nil
		case float64:
			return n == float64(int64(n))
		default:
			return false
		}
	case "object":
		_, ok := value.(map[string]any)
		return ok
	case "array":
		_, ok := value.([]any)
		return ok
	default:
		return false
	}
}

func jsonScalarEqual(a any, b any) bool {
	if reflect.DeepEqual(a, b) {
		return true
	}
	an, aok := a.(json.Number)
	bn, bok := b.(json.Number)
	if aok && bok {
		return an.String() == bn.String()
	}
	return false
}
