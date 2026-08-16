package cli

import (
	"testing"

	"github.com/augstar/macprovider/phase7-verify/internal/schemavalidator"
	"github.com/augstar/macprovider/phase7-verify/internal/verify"
)

// SPEC-015 v0.3 §M.3.2.1 — every v0.3-named reason + matching
// details shape MUST validate against the published schema. Round-2
// ARCHITECT-3 flagged that the existing schema tests only covered
// legacy reasons; this fixture corpus closes the gap.
func TestV03SchemaConformance(t *testing.T) {
	bptr := func(b bool) *bool { return &b }
	cases := []struct {
		name   string
		result verify.Result
	}{
		{
			name: "model_hash_mismatch",
			result: verify.Result{
				Result:            "invalid",
				Reason:            "model_hash_mismatch",
				ProviderID:        outputProviderID,
				ModelID:           outputModelID,
				SignedAt:          outputSignedAt,
				TrustSource:       "live",
				CoordinatorHost:   outputCoordinatorHost,
				ModelHashVerified: bptr(false),
				ReceiptVersion:    "3",
				Details: &verify.Details{
					Field:    "model_hash",
					Expected: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
					Actual:   "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
				},
			},
		},
		{
			name: "model_hash_required",
			result: verify.Result{
				Result:            "invalid",
				Reason:            "model_hash_required",
				ProviderID:        outputProviderID,
				ModelID:           outputModelID,
				SignedAt:          outputSignedAt,
				TrustSource:       "live",
				CoordinatorHost:   outputCoordinatorHost,
				ModelHashVerified: bptr(false),
				ReceiptVersion:    "3",
				Details:           &verify.Details{Field: "model_hash", PolicyFlag: "require-model-hash"},
			},
		},
		{
			name: "model_id_not_in_catalog",
			result: verify.Result{
				Result:          "inconclusive",
				Reason:          "model_id_not_in_catalog",
				ProviderID:      outputProviderID,
				ModelID:         "absent",
				SignedAt:        outputSignedAt,
				TrustSource:     "live",
				CoordinatorHost: outputCoordinatorHost,
				ReceiptVersion:  "3",
				Details:         &verify.Details{Field: "model_id", ModelID: "absent"},
			},
		},
		{
			name: "catalog_expired",
			result: verify.Result{
				Result:          "inconclusive",
				Reason:          "catalog_expired",
				ProviderID:      outputProviderID,
				ModelID:         outputModelID,
				SignedAt:        outputSignedAt,
				TrustSource:     "live",
				CoordinatorHost: outputCoordinatorHost,
				ReceiptVersion:  "3",
				Details: &verify.Details{
					Field:     "expires_at",
					CatalogID: "macprovider-tier2-2026-05-31",
					ExpiresAt: "2026-05-31T00:00:00Z",
				},
			},
		},
		{
			name: "catalog_signature_invalid",
			result: verify.Result{
				Result:          "invalid",
				Reason:          "catalog_signature_invalid",
				ProviderID:      outputProviderID,
				ModelID:         outputModelID,
				SignedAt:        outputSignedAt,
				TrustSource:     "live",
				CoordinatorHost: outputCoordinatorHost,
				ReceiptVersion:  "3",
				// SPEC-015 §M.3.2.1 requires details.alg with the
				// observed catalog signature.alg value.
				Details: &verify.Details{Field: "signature", Cause: "signature.alg=\"ed25519\", want \"Ed25519\"", Alg: "ed25519"},
			},
		},
		{
			name: "catalog_unreachable",
			result: verify.Result{
				Result:          "inconclusive",
				Reason:          "catalog_unreachable",
				ProviderID:      outputProviderID,
				ModelID:         outputModelID,
				SignedAt:        outputSignedAt,
				TrustSource:     "live",
				CoordinatorHost: outputCoordinatorHost,
				ReceiptVersion:  "3",
				Details: &verify.Details{
					Field: "catalog_url",
					URL:   "https://coordinator.malibu.tech/catalog/x",
					Cause: "connection refused",
				},
			},
		},
		{
			name: "unknown_receipt_version",
			result: verify.Result{
				Result:         "inconclusive",
				Reason:         "unknown_receipt_version",
				TrustSource:    "none",
				ReceiptVersion: "4",
				Details:        &verify.Details{Field: "receipt_version", ReceiptVersion: "4"},
			},
		},
		{
			name: "extra_field",
			result: verify.Result{
				Result:      "invalid",
				Reason:      "extra_field",
				TrustSource: "none",
				Details:     &verify.Details{Field: "x_unexpected"},
			},
		},
		{
			name: "missing_field",
			result: verify.Result{
				Result:      "invalid",
				Reason:      "missing_field",
				TrustSource: "none",
				Details:     &verify.Details{Field: "prompt_hash"},
			},
		},
		{
			name: "valid-with-catalog",
			result: verify.Result{
				Result:            "valid",
				Reason:            "signature_and_canonicalization_match",
				ProviderID:        outputProviderID,
				ModelID:           outputModelID,
				SignedAt:          outputSignedAt,
				TrustSource:       "live",
				CoordinatorHost:   outputCoordinatorHost,
				ModelHashVerified: bptr(true),
				ReceiptVersion:    "3",
			},
		},
		{
			name: "valid-legacy-skipped",
			result: verify.Result{
				Result:          "valid",
				Reason:          "signature_and_canonicalization_match",
				ProviderID:      outputProviderID,
				ModelID:         outputModelID,
				SignedAt:        outputSignedAt,
				TrustSource:     "live",
				CoordinatorHost: outputCoordinatorHost,
				ReceiptVersion:  "1",
				Warnings:        []verify.Warning{{Kind: "catalog_skipped_legacy_receipt"}},
			},
		},
	}

	schema := loadOutputSchema(t)

	// SPEC-015 §M.3.2.1 — assert the schema REJECTS catalog_signature_invalid
	// without details.alg. This locks the §M.3.2.1 contract at the schema
	// level so future renderer regressions can't silently emit a permissive
	// shape.
	t.Run("catalog_signature_invalid_without_alg_rejected", func(t *testing.T) {
		bad := verify.Result{
			Result:          "invalid",
			Reason:          "catalog_signature_invalid",
			ProviderID:      outputProviderID,
			ModelID:         outputModelID,
			SignedAt:        outputSignedAt,
			TrustSource:     "live",
			CoordinatorHost: outputCoordinatorHost,
			ReceiptVersion:  "3",
			Details:         &verify.Details{Field: "signature", Cause: "no alg"},
		}
		data, err := renderJSON(bad)
		if err != nil {
			t.Fatalf("renderJSON: %v", err)
		}
		if err := schemavalidator.Validate(schema, data); err == nil {
			t.Fatalf("schema accepted catalog_signature_invalid without details.alg: %s", data)
		}
	})

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			data, err := renderJSON(tc.result)
			if err != nil {
				t.Fatalf("renderJSON: %v", err)
			}
			if err := schemavalidator.Validate(schema, data); err != nil {
				t.Fatalf("schema rejected v0.3 conformance fixture %q: %v\nbody=%s", tc.name, err, data)
			}
		})
	}
}
