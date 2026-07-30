package ws

import (
	"encoding/json"
	"testing"
)

// TestParseHelloRejectsInvalidProviderID_Iss274 pins that WS Hello
// registration rejects ProviderIDs that don't match config.providerIDPattern.
// Pre-#274 the parser only checked non-empty + non-control-char, so
// `"a/b"` passed and would have produced an ambiguous pool.Provider.SortKey.
func TestParseHelloRejectsInvalidProviderID_Iss274(t *testing.T) {
	base := map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"hostname":                "h-ok",
		"model_id":                "m-ok",
		"model_params_b":          7.0,
		"ram_gb":                  16,
		"max_context_tokens":      50000,
		"max_concurrency":         1,
		"throughput_tps_estimate": 19.8,
		"binary_version":          "0.1.0",
		"attestation":             nil,
	}
	for name, bad := range map[string]string{
		"slash_delimiter_collision_seed": "a/b",
		"space":                          "m4 anon",
		"colon":                          "m4:anon",
		"unicode":                        "café",
	} {
		t.Run(name, func(t *testing.T) {
			payload := make(map[string]any, len(base)+1)
			for k, v := range base {
				payload[k] = v
			}
			payload["provider_id"] = bad
			raw, err := json.Marshal(payload)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			_, badField, err := ParseHello(raw)
			if err == nil {
				t.Fatalf("ParseHello accepted provider_id=%q", bad)
			}
			if badField != "provider_id" {
				t.Fatalf("badField = %q, want provider_id", badField)
			}
		})
	}
}

// TestParseAuthRequestInitialRejectsInvalidProviderID_Iss274 pins the same
// gate for the WS auth_request initial-stage frame.
func TestParseAuthRequestInitialRejectsInvalidProviderID_Iss274(t *testing.T) {
	for name, bad := range map[string]string{
		"slash_delimiter_collision_seed": "a/b",
		"space":                          "m4 anon",
	} {
		t.Run(name, func(t *testing.T) {
			payload := validAuthRequestInitial()
			payload["provider_id"] = bad
			_, _, badField, err := ParseAuthRequest(mustAuthJSON(t, payload))
			if err == nil {
				t.Fatalf("ParseAuthRequest(initial) accepted provider_id=%q", bad)
			}
			if badField != "provider_id" {
				t.Fatalf("badField = %q, want provider_id", badField)
			}
		})
	}
}

// TestParseAuthRequestProofRejectsInvalidProviderID_Iss274 pins the same
// gate for the WS auth_request proof-stage frame.
func TestParseAuthRequestProofRejectsInvalidProviderID_Iss274(t *testing.T) {
	for name, bad := range map[string]string{
		"slash_delimiter_collision_seed": "a/b",
		"colon":                          "m4:anon",
	} {
		t.Run(name, func(t *testing.T) {
			payload := validAuthRequestProof()
			payload["provider_id"] = bad
			_, _, badField, err := ParseAuthRequest(mustAuthJSON(t, payload))
			if err == nil {
				t.Fatalf("ParseAuthRequest(proof) accepted provider_id=%q", bad)
			}
			if badField != "provider_id" {
				t.Fatalf("badField = %q, want provider_id", badField)
			}
		})
	}
}
