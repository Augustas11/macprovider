package spec015

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// SPEC-015 v0.3 §M.5 — AC-28 through AC-42 + AC-32a. The manifest
// mirrors the v0.2 acceptanceCriterion shape; SpecStep is in the
// §M.5 form because v0.3 §M is a new top-level section (not §14).
var spec015V03ACs = []acceptanceCriterion{
	{
		Number:   28,
		Summary:  "v0.3 provider emits an X-MacProvider-Receipt header whose tuple decodes to exactly 9 fields in JCS canonical (alphabetical) order with receipt_version=\"3\"",
		SpecStep: "SPEC-015 §M.5 AC-28",
		Commands: []string{"cd phase3-binary && swift test --filter ReceiptBuilderTests"},
		CIJobs:   []string{"phase3-binary (swift test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift", "v03TupleKeys"},
			{"phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift", "testCanonicalTupleIsAlphabeticalUtf16Order"},
			{"phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift", "receiptVersionV03"},
		},
	},
	{
		Number:   29,
		Summary:  "warm-swap-on provider's receipt model_hash matches the runtime-served snapshot hash",
		SpecStep: "SPEC-015 §M.5 AC-29",
		Commands: []string{"cd phase3-binary && swift test --filter HTTPServerReceiptTests"},
		CIJobs:   []string{"phase3-binary (swift test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "testHTTPSuccessReceiptCarriesWarmSwapHash"},
			{"phase3-binary/Sources/macprovider-cli/ModelRuntime.swift", "completeWithServedSnapshot"},
		},
	},
	{
		Number:   30,
		Summary:  "warm-swap-disabled provider emits model_hash as the JSON null literal (not empty string, not absent)",
		SpecStep: "SPEC-015 §M.5 AC-30",
		Commands: []string{"cd phase3-binary && swift test --filter ReceiptBuilderTests"},
		CIJobs:   []string{"phase3-binary (swift test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift", "testBuildEmitsJSONNullForAbsentModelHash"},
			{"phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift", "modelHashValue = .null"},
		},
	},
	{
		Number:   31,
		Summary:  "error / null-usage receipt inherits the request-start model_hash (warm-swap-on path)",
		SpecStep: "SPEC-015 §M.5 AC-31",
		Commands: []string{"cd phase3-binary && swift test --filter HTTPServerReceiptTests"},
		CIJobs:   []string{"phase3-binary (swift test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "testHTTPErrorReceiptInheritsWarmSwapHash"},
			{"phase3-binary/Sources/macprovider-cli/HTTPServer.swift", "modelHashSource: fallbackHashSource"},
		},
	},
	{
		Number:   32,
		Summary:  "v0.3 verifier reports valid + catalog_skipped_null_hash warning when receipt has model_hash:null and catalog flags supplied",
		SpecStep: "SPEC-015 §M.5 AC-32",
		Commands: []string{"cd phase7-verify && go test ./internal/verify/ -run TestCatalogCheckNullHashWithCatalogFlags -count=1"},
		CIJobs:   []string{"phase7-verify (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase7-verify/internal/verify/catalog_check_test.go", "TestCatalogCheckNullHashWithCatalogFlags"},
			{"phase7-verify/internal/verify/verify.go", "warningCatalogSkippedNullHash"},
		},
	},
	{
		Number:   33,
		Summary:  "v0.3 verifier reports invalid with reason model_hash_mismatch when receipt hash diverges from catalog sha256",
		SpecStep: "SPEC-015 §M.5 AC-33",
		Commands: []string{"cd phase7-verify && go test ./internal/verify/ -run TestCatalogCheckModelHashMismatch -count=1"},
		CIJobs:   []string{"phase7-verify (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase7-verify/internal/verify/catalog_check_test.go", "TestCatalogCheckModelHashMismatch"},
			{"phase7-verify/internal/verify/verify.go", "reasonModelHashMismatch"},
		},
	},
	{
		Number:   34,
		Summary:  "v0.3 verifier reports inconclusive with reason model_id_not_in_catalog when receipt model_id is not present in catalog",
		SpecStep: "SPEC-015 §M.5 AC-34",
		Commands: []string{"cd phase7-verify && go test ./internal/verify/ -run TestCatalogCheckModelIDNotInCatalog -count=1"},
		CIJobs:   []string{"phase7-verify (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase7-verify/internal/verify/catalog_check_test.go", "TestCatalogCheckModelIDNotInCatalog"},
			{"phase7-verify/internal/verify/verify.go", "reasonModelIDNotInCatalog"},
		},
	},
	{
		Number:   35,
		Summary:  "v0.3 verifier reports invalid with reason catalog_signature_invalid when catalog signature does not verify or alg is lowercase",
		SpecStep: "SPEC-015 §M.5 AC-35",
		Commands: []string{"cd phase7-verify && go test ./internal/catalog/ -run 'TestVerifyRejectsLowercaseAlg|TestVerifyRejectsTamperedSignature|TestVerifyTamperedSignatureCarriesObservedAlg' -count=1"},
		CIJobs:   []string{"phase7-verify (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase7-verify/internal/catalog/catalog_test.go", "TestVerifyRejectsLowercaseAlg"},
			{"phase7-verify/internal/catalog/catalog_test.go", "TestVerifyRejectsTamperedSignature"},
			{"phase7-verify/internal/catalog/catalog_test.go", "TestVerifyTamperedSignatureCarriesObservedAlg"},
		},
	},
	{
		Number:   36,
		Summary:  "v0.3 verifier reports inconclusive with reason catalog_expired when catalog expires_at > now + 60s grace",
		SpecStep: "SPEC-015 §M.5 AC-36",
		Commands: []string{"cd phase7-verify && go test ./internal/catalog/ -run 'TestVerifyRejectsExpiredBeyondGrace|TestVerifyAcceptsWithin60sGrace|TestVerifyExpiryBoundaryAt60s' -count=1"},
		CIJobs:   []string{"phase7-verify (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase7-verify/internal/catalog/catalog_test.go", "TestVerifyExpiryBoundaryAt60s"},
			{"phase7-verify/internal/catalog/catalog_test.go", "TestVerifyAcceptsWithin60sGrace"},
		},
	},
	{
		Number:   37,
		Summary:  "v0.3 verifier reading a legacy v0.1/v0.2 receipt reports valid without catalog check; catalog_skipped_legacy_receipt warning emitted when catalog flags supplied",
		SpecStep: "SPEC-015 §M.5 AC-37",
		Commands: []string{"cd phase7-verify && go test ./internal/verify/ -run TestCatalogCheckLegacyReceiptWithCatalogFlags -count=1"},
		CIJobs:   []string{"phase7-verify (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase7-verify/internal/verify/catalog_check_test.go", "TestCatalogCheckLegacyReceiptWithCatalogFlags"},
			{"phase7-verify/internal/verify/verify.go", "warningCatalogSkippedLegacyReceipt"},
		},
	},
	{
		Number:   38,
		Summary:  "v0.1.3 / v0.2.4 locked verifier reading a v0.3 receipt (9 keys including receipt_version) reports invalid per §3.1 seven-keys-only rule — cross-binary parity",
		SpecStep: "SPEC-015 §M.5 AC-38",
		Commands: []string{"cd phase7-verify && go test ./internal/receipt/ -run TestV02LockedParserRejectsV03Receipts -count=1"},
		CIJobs:   []string{"phase7-verify (go vet + test)"},
		Evidence: []evidenceAnchor{
			// §M.1.2 forward-incompat: the v0.2.4-LOCKED parser logic
			// is re-implemented inline as parseTupleV02Locked. The test
			// drives v0.3 receipts (with and without null model_hash)
			// through the locked-floor parser and asserts ErrTupleExtraKey
			// — the §3.1 "EXACTLY these seven keys" rejection. Same
			// test confirms genuine v0.1/v0.2 7-field tuples are
			// accepted, proving the locked floor is preserved.
			{"phase7-verify/internal/receipt/v02_parity_test.go", "TestV02LockedParserRejectsV03Receipts"},
			{"phase7-verify/internal/receipt/v02_parity_test.go", "parseTupleV02Locked"},
			{"phase7-verify/internal/receipt/v02_parity_test.go", "v0.2.4 parser MUST reject v0.3"},
		},
	},
	{
		Number:   39,
		Summary:  "coordinator /poolz emits catalog_id, catalog_url, catalog_pubkey_url when tier-2 catalog is effectively active; omits them when not",
		SpecStep: "SPEC-015 §M.5 AC-39",
		Commands: []string{"cd phase4-coordinator && go test ./internal/ws/ -run 'TestPoolzEmitsCatalogFieldsWhenCatalogActive|TestPoolzOmitsCatalogFieldsWhenCatalogNotConfigured|TestPoolzOmitsCatalogFieldsWhenCatalogLoadFails' -count=1"},
		CIJobs:   []string{"phase4-coordinator (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase4-coordinator/internal/ws/poolz_catalog_test.go", "TestPoolzEmitsCatalogFieldsWhenCatalogActive"},
			{"phase4-coordinator/internal/ws/poolz_catalog_test.go", "TestPoolzOmitsCatalogFieldsWhenCatalogNotConfigured"},
			{"phase4-coordinator/internal/ws/poolz_catalog_test.go", "TestPoolzOmitsCatalogFieldsWhenCatalogLoadFails"},
		},
	},
	{
		Number:   40,
		Summary:  "RequireHashVerified=false continues to route to uncatalogued / catalog_unavailable providers (Entry 80 preservation); v0.3 receipts on those providers carry non-null model_hash regardless",
		SpecStep: "SPEC-015 §M.5 AC-40",
		Commands: []string{"cd phase4-coordinator && go test ./internal/tier2/ -count=1"},
		CIJobs:   []string{"phase4-coordinator (go vet + test)"},
		Evidence: []evidenceAnchor{
			// Entry 80 orthogonality is a compile-time invariant: the
			// default in config.go is false, the routing predicate in
			// catalog.go fails closed only on mismatch/invalid.
			{"phase4-coordinator/internal/config/config.go", "RequireHashVerified"},
			{"phase4-coordinator/internal/tier2/catalog.go", "IsHashPredicateFailure"},
			{"beta/DECISION_CRITERIA.md", "Entry 80"},
		},
	},
	{
		Number:   41,
		Summary:  "catalog URL cache obeys §M.3.4 three-band TTL: R>6h caches 6h; [60s,6h] caches R-60s; R<60s does not cache",
		SpecStep: "SPEC-015 §M.5 AC-41",
		Commands: []string{"cd phase7-verify && go test ./internal/cache/catalog/ -run 'TestComputeTTLBands|TestPutSkipsBelowMinTTL|TestGetMissOnPubkeyRotation|TestGetMissOnStaleEntry' -count=1"},
		CIJobs:   []string{"phase7-verify (go vet + test)"},
		Evidence: []evidenceAnchor{
			{"phase7-verify/internal/cache/catalog/catalog_cache_test.go", "TestComputeTTLBands"},
			{"phase7-verify/internal/cache/catalog/catalog_cache_test.go", "TestGetMissOnPubkeyRotation"},
			{"phase7-verify/internal/cache/catalog/catalog_cache_test.go", "TestGetMissOnStaleEntry"},
		},
	},
	{
		Number:   42,
		Summary:  "§M.2.2 defence-in-depth: ambiguous request-start provenance (warm-swap on AND no hash on snapshot) → no X-MacProvider-Receipt header AND receipt_omitted: model_swap_violation audit row",
		SpecStep: "SPEC-015 §M.5 AC-42",
		Commands: []string{"cd phase3-binary && swift test --filter 'HTTPServerReceiptTests/testHTTPReceiptRefusedOnAmbiguousProvenance|HTTPServerReceiptTests/testHTTPAmbiguousProvenanceEmitsReceiptOmittedAudit|HTTPServerReceiptTests/testHTTPReceiptEmittedForNormalInFlightSwap'"},
		CIJobs:   []string{"phase3-binary (swift test)"},
		Evidence: []evidenceAnchor{
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "testHTTPReceiptRefusedOnAmbiguousProvenance"},
			{"phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift", "testHTTPAmbiguousProvenanceEmitsReceiptOmittedAudit"},
			{"phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift", "ReceiptModelHashSource"},
		},
	},
}

// SPEC-015 §M.3.1.2 AC-32a — opt-in --require-model-hash policy gate.
var spec015AC32a = acceptanceCriterion{
	Number:   320, // sentinel — 32 * 10 to fit the int field without colliding with AC-32
	Summary:  "--require-model-hash flag fails closed (exit 1, reason model_hash_required) on null-hash v0.3 receipt AND on legacy v0.1/v0.2 receipt",
	SpecStep: "SPEC-015 §M.5 AC-32a",
	Commands: []string{"cd phase7-verify && go test ./internal/verify/ -run 'TestCatalogCheckNullHashRequireModelHash|TestCatalogCheckLegacyReceiptRequireModelHash' -count=1"},
	CIJobs:   []string{"phase7-verify (go vet + test)"},
	Evidence: []evidenceAnchor{
		{"phase7-verify/internal/verify/catalog_check_test.go", "TestCatalogCheckNullHashRequireModelHash"},
		{"phase7-verify/internal/verify/catalog_check_test.go", "TestCatalogCheckLegacyReceiptRequireModelHash"},
		{"phase7-verify/internal/verify/verify.go", "reasonModelHashRequired"},
	},
}

func TestSpec015V03AcceptanceCriteria(t *testing.T) {
	root := repoRoot(t)
	check := func(t *testing.T, ac acceptanceCriterion) {
		t.Helper()
		if !strings.HasPrefix(ac.SpecStep, "SPEC-015 §M.5 AC-") {
			t.Fatalf("spec step = %q", ac.SpecStep)
		}
		if len(ac.Commands) == 0 || len(ac.CIJobs) == 0 {
			t.Fatalf("missing automated command or CI job: %+v", ac)
		}
		// Step 6 audit prompt requires ≥2 evidence anchors per AC so
		// a single test rename can't silently sink the coverage claim.
		if len(ac.Evidence) < 2 {
			t.Fatalf("AC-%d has %d evidence anchors, want ≥2: %+v", ac.Number, len(ac.Evidence), ac)
		}
		for _, anchor := range ac.Evidence {
			content, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(anchor.File)))
			if err != nil {
				t.Fatalf("read evidence %s: %v", anchor.File, err)
			}
			if !strings.Contains(string(content), anchor.Pattern) {
				t.Fatalf("evidence %s missing pattern %q", anchor.File, anchor.Pattern)
			}
		}
		t.Logf("%s PASS via %s", ac.SpecStep, strings.Join(ac.CIJobs, ", "))
	}
	for _, ac := range spec015V03ACs {
		ac := ac
		t.Run(fmt.Sprintf("AC-%02d", ac.Number), func(t *testing.T) {
			check(t, ac)
		})
	}
	t.Run("AC-32a", func(t *testing.T) {
		check(t, spec015AC32a)
	})
}

func TestSpec015V03AcceptanceManifestCoversAC28ThroughAC42(t *testing.T) {
	if len(spec015V03ACs) != 15 {
		t.Fatalf("v0.3 manifest has %d ACs, want 15 (AC-28..AC-42)", len(spec015V03ACs))
	}
	seen := make(map[int]bool, len(spec015V03ACs))
	for _, ac := range spec015V03ACs {
		if ac.Number < 28 || ac.Number > 42 {
			t.Fatalf("v0.3 AC-%d outside expected range", ac.Number)
		}
		if seen[ac.Number] {
			t.Fatalf("duplicate v0.3 AC-%d", ac.Number)
		}
		seen[ac.Number] = true
	}
	// AC-32a is a §M.3.1.2 named addition, not a numbered AC in the
	// 28..42 range, but it MUST be covered.
	if spec015AC32a.Number == 0 || len(spec015AC32a.Evidence) == 0 {
		t.Fatal("AC-32a entry missing or empty")
	}
}
