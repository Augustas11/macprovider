package verify

import (
	"testing"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/receipt"
)

// SPEC-015 §M.1.1 — v0.3 verifier reading a legacy v0.1/v0.2 receipt
// MUST emit catalog_skipped_legacy_receipt warning when catalog
// flags were supplied, and MUST NOT short-circuit the result.
func TestCatalogCheckLegacyReceiptWithCatalogFlags(t *testing.T) {
	parsed := receipt.Parsed{
		Tuple: receipt.Tuple{
			ModelID: "mlx-fixture",
			// ReceiptVersion empty → legacy v0.1/v0.2.
		},
	}
	opts := VerifyOpts{
		Catalog: CatalogOpts{Enabled: true},
	}
	v := applyCatalogCheck(parsed, opts, time.Now())
	if v.Result != "" {
		t.Fatalf("legacy receipt should not short-circuit: got %q", v.Result)
	}
	if !hasWarning(v.Warnings, warningCatalogSkippedLegacyReceipt) {
		t.Fatalf("missing warning %q; got %+v", warningCatalogSkippedLegacyReceipt, v.Warnings)
	}
	if v.ModelHashVerified != nil {
		t.Fatalf("ModelHashVerified = %v, want nil", v.ModelHashVerified)
	}
}

// SPEC-015 §M.3.1.2 — --require-model-hash on a legacy receipt is
// invalid: model_hash_required.
func TestCatalogCheckLegacyReceiptRequireModelHash(t *testing.T) {
	parsed := receipt.Parsed{Tuple: receipt.Tuple{ModelID: "m"}}
	opts := VerifyOpts{RequireModelHash: true}
	v := applyCatalogCheck(parsed, opts, time.Now())
	if v.Result != resultInvalid || v.Reason != reasonModelHashRequired {
		t.Fatalf("got result=%q reason=%q, want invalid+model_hash_required", v.Result, v.Reason)
	}
	if v.ModelHashVerified == nil || *v.ModelHashVerified {
		t.Fatalf("ModelHashVerified = %v, want pointer-to-false", v.ModelHashVerified)
	}
}

// SPEC-015 §M.2.3 — v0.3 receipt with null model_hash + catalog
// flags → warning, valid path (model_hash_verified=nil).
func TestCatalogCheckNullHashWithCatalogFlags(t *testing.T) {
	parsed := receipt.Parsed{
		Tuple: receipt.Tuple{
			ModelID:          "m",
			ReceiptVersion:   "3",
			ModelHashPresent: true,
			ModelHashNull:    true,
		},
	}
	opts := VerifyOpts{Catalog: CatalogOpts{Enabled: true}}
	v := applyCatalogCheck(parsed, opts, time.Now())
	if v.Result != "" {
		t.Fatalf("null hash should not short-circuit (no policy flag): got %q", v.Result)
	}
	if !hasWarning(v.Warnings, warningCatalogSkippedNullHash) {
		t.Fatalf("missing warning %q", warningCatalogSkippedNullHash)
	}
	if v.ModelHashVerified != nil {
		t.Fatalf("ModelHashVerified = %v, want nil", v.ModelHashVerified)
	}
}

// SPEC-015 §M.3.1.2 — --require-model-hash + null hash → invalid:
// model_hash_required.
func TestCatalogCheckNullHashRequireModelHash(t *testing.T) {
	parsed := receipt.Parsed{
		Tuple: receipt.Tuple{
			ModelID:          "m",
			ReceiptVersion:   "3",
			ModelHashPresent: true,
			ModelHashNull:    true,
		},
	}
	opts := VerifyOpts{RequireModelHash: true}
	v := applyCatalogCheck(parsed, opts, time.Now())
	if v.Result != resultInvalid || v.Reason != reasonModelHashRequired {
		t.Fatalf("got result=%q reason=%q", v.Result, v.Reason)
	}
	if v.ModelHashVerified == nil || *v.ModelHashVerified {
		t.Fatalf("ModelHashVerified = %v, want false", v.ModelHashVerified)
	}
}

// SPEC-015 §M.3.2 step 6 — model_id not in catalog → inconclusive.
// Driven by writing a temp signed catalog that does NOT include
// the receipt's model_id.
func TestCatalogCheckModelIDNotInCatalog(t *testing.T) {
	path, pub := writeSignedCatalog(t, "tc", time.Now().Add(time.Hour), []catalogModel{{
		ModelID: "other-model",
		SHA256:  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	}})
	parsed := receipt.Parsed{
		Tuple: receipt.Tuple{
			ModelID:          "missing-model",
			ReceiptVersion:   "3",
			ModelHashPresent: true,
			ModelHash:        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		},
	}
	opts := VerifyOpts{
		Catalog: CatalogOpts{
			Enabled: true,
			Path:    path,
			Pubkey:  pub,
		},
	}
	v := applyCatalogCheck(parsed, opts, time.Now())
	if v.Result != resultInconclusive || v.Reason != reasonModelIDNotInCatalog {
		t.Fatalf("got result=%q reason=%q", v.Result, v.Reason)
	}
}

// SPEC-015 §M.3.2 step 7 — model_hash mismatch → invalid.
func TestCatalogCheckModelHashMismatch(t *testing.T) {
	want := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	path, pub := writeSignedCatalog(t, "tc", time.Now().Add(time.Hour), []catalogModel{{
		ModelID: "model-a",
		SHA256:  want,
	}})
	parsed := receipt.Parsed{
		Tuple: receipt.Tuple{
			ModelID:          "model-a",
			ReceiptVersion:   "3",
			ModelHashPresent: true,
			ModelHash:        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
		},
	}
	opts := VerifyOpts{
		Catalog: CatalogOpts{Enabled: true, Path: path, Pubkey: pub},
	}
	v := applyCatalogCheck(parsed, opts, time.Now())
	if v.Result != resultInvalid || v.Reason != reasonModelHashMismatch {
		t.Fatalf("got result=%q reason=%q", v.Result, v.Reason)
	}
	if v.ModelHashVerified == nil || *v.ModelHashVerified {
		t.Fatalf("ModelHashVerified = %v, want false", v.ModelHashVerified)
	}
}

// SPEC-015 §M.3.2 step 8 — hash match → no short-circuit; verifier
// continues to the valid path with model_hash_verified=true.
func TestCatalogCheckHashMatch(t *testing.T) {
	hash := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	path, pub := writeSignedCatalog(t, "tc", time.Now().Add(time.Hour), []catalogModel{{
		ModelID: "model-a",
		SHA256:  hash,
	}})
	parsed := receipt.Parsed{
		Tuple: receipt.Tuple{
			ModelID:          "model-a",
			ReceiptVersion:   "3",
			ModelHashPresent: true,
			ModelHash:        hash,
		},
	}
	opts := VerifyOpts{
		Catalog: CatalogOpts{Enabled: true, Path: path, Pubkey: pub},
	}
	v := applyCatalogCheck(parsed, opts, time.Now())
	if v.Result != "" {
		t.Fatalf("hash match should not short-circuit: got %q", v.Result)
	}
	if v.ModelHashVerified == nil || !*v.ModelHashVerified {
		t.Fatalf("ModelHashVerified = %v, want pointer-to-true", v.ModelHashVerified)
	}
}

// SPEC-015 §M.3.2.1 — the tampered-catalog end-to-end path through
// applyCatalogCheck must surface details.alg with the observed
// signature.alg so schema validation passes (the v0.3 schema
// requires details.alg when reason is catalog_signature_invalid).
func TestCatalogCheckTamperedCatalogPopulatesDetailsAlg(t *testing.T) {
	hash := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	path, pub := writeTamperedSignedCatalog(t, "tc", time.Now().Add(time.Hour), []catalogModel{{
		ModelID: "model-a",
		SHA256:  hash,
	}})
	parsed := receipt.Parsed{
		Tuple: receipt.Tuple{
			ModelID:          "model-a",
			ReceiptVersion:   "3",
			ModelHashPresent: true,
			ModelHash:        hash,
		},
	}
	opts := VerifyOpts{
		Catalog: CatalogOpts{Enabled: true, Path: path, Pubkey: pub},
	}
	v := applyCatalogCheck(parsed, opts, time.Now())
	if v.Result != resultInvalid || v.Reason != reasonCatalogSignatureInvalid {
		t.Fatalf("got result=%q reason=%q", v.Result, v.Reason)
	}
	if v.Details == nil {
		t.Fatal("Details nil")
	}
	if v.Details.Alg == "" {
		t.Fatalf("Details.Alg = %q, want non-empty (the observed catalog signature.alg)", v.Details.Alg)
	}
}

func hasWarning(ws []Warning, kind string) bool {
	for _, w := range ws {
		if w.Kind == kind {
			return true
		}
	}
	return false
}
