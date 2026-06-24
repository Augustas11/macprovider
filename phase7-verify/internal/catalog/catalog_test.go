package catalog

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

const validHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func TestParseAndVerifyHappyPath(t *testing.T) {
	raw, pub := signFixture(t, "test-catalog", time.Now().Add(time.Hour), []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "model-a",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	c, err := Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if c.CatalogID != "test-catalog" {
		t.Fatalf("CatalogID = %q", c.CatalogID)
	}
	if got := c.Models[modelKey("model-a")].SHA256; got != validHash {
		t.Fatalf("sha = %q", got)
	}
	if err := Verify(c, pub, time.Now()); err != nil {
		t.Fatalf("Verify: %v", err)
	}
}

// SPEC-015 §M.3.2 step 6 — canonical Lookup uses lowercase + trim.
func TestLookupCaseFoldedAndTrimmed(t *testing.T) {
	raw, _ := signFixture(t, "tc", time.Now().Add(time.Hour), []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "MLX/Qwen2.5-7B-Instruct-4bit",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	c, err := Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	for _, query := range []string{
		"mlx/qwen2.5-7b-instruct-4bit",
		"MLX/Qwen2.5-7B-Instruct-4bit",
		"  mlx/qwen2.5-7b-instruct-4bit  ",
		"MLX/QWEN2.5-7B-INSTRUCT-4BIT",
	} {
		entry, ok := Lookup(c, query)
		if !ok {
			t.Fatalf("Lookup(%q) = miss", query)
		}
		if entry.SHA256 != validHash {
			t.Fatalf("Lookup(%q).SHA256 = %q", query, entry.SHA256)
		}
	}
	if _, ok := Lookup(c, "different-model"); ok {
		t.Fatalf("Lookup miss expected")
	}
}

// SPEC-015 §M.3.2 step 4 — verify alg "ed25519" (lowercase) rejected.
func TestVerifyRejectsLowercaseAlg(t *testing.T) {
	raw, pub := signFixture(t, "tc", time.Now().Add(time.Hour), []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "model-a",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	// Inject lowercase alg.
	mutated := bytes.Replace(raw, []byte(`"alg":"Ed25519"`), []byte(`"alg":"ed25519"`), 1)
	if bytes.Equal(mutated, raw) {
		t.Fatal("alg substitution did not change bytes")
	}
	c, err := Parse(mutated)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	err = Verify(c, pub, time.Now())
	var sigErr *ErrSignatureInvalid
	if !errors.As(err, &sigErr) {
		t.Fatalf("Verify err = %v, want ErrSignatureInvalid", err)
	}
	if !strings.Contains(sigErr.Reason, "signature.alg") {
		t.Fatalf("ErrSignatureInvalid.Reason = %q", sigErr.Reason)
	}
}

func TestVerifyRejectsTamperedSignature(t *testing.T) {
	raw, pub := signFixture(t, "tc", time.Now().Add(time.Hour), []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "model-a",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	c, err := Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	// Flip first byte of the signature (in the typed File, which Verify
	// reparses out of c.Raw). Construct a raw-mutated catalog and re-parse.
	mutated := mutateSignatureSig(t, raw)
	c2, err := Parse(mutated)
	if err != nil {
		t.Fatalf("Parse mutated: %v", err)
	}
	err = Verify(c2, pub, time.Now())
	var sigErr *ErrSignatureInvalid
	if !errors.As(err, &sigErr) {
		t.Fatalf("Verify err = %v, want ErrSignatureInvalid", err)
	}
	_ = c
}

func TestVerifyRejectsTamperedBody(t *testing.T) {
	raw, pub := signFixture(t, "tc", time.Now().Add(time.Hour), []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "model-a",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	// Tamper the catalog_id to break the signed canonical body.
	tampered := bytes.Replace(raw, []byte(`"catalog_id":"tc"`), []byte(`"catalog_id":"x!"`), 1)
	if bytes.Equal(tampered, raw) {
		t.Fatal("tamper substitution did not change bytes")
	}
	c, err := Parse(tampered)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	err = Verify(c, pub, time.Now())
	var sigErr *ErrSignatureInvalid
	if !errors.As(err, &sigErr) {
		t.Fatalf("Verify err = %v, want ErrSignatureInvalid", err)
	}
}

// SPEC-015 §M.3.2 step 5 — expired beyond 60s grace → ErrExpired.
func TestVerifyRejectsExpiredBeyondGrace(t *testing.T) {
	issued := time.Now().Add(-2 * time.Hour)
	expires := issued.Add(time.Hour) // expired 1h ago
	raw, pub := signFixtureAtTime(t, "tc", issued, expires, []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "model-a",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	c, err := Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	err = Verify(c, pub, time.Now())
	var expErr *ErrExpired
	if !errors.As(err, &expErr) {
		t.Fatalf("Verify err = %v, want ErrExpired", err)
	}
	if expErr.CatalogID != "tc" {
		t.Fatalf("ErrExpired.CatalogID = %q", expErr.CatalogID)
	}
}

// SPEC-015 §M.3.2 step 5 — within the 60-second grace window: OK.
func TestVerifyAcceptsWithin60sGrace(t *testing.T) {
	issued := time.Now().Add(-time.Hour)
	expires := time.Now().Add(-30 * time.Second) // 30s expired, within grace
	raw, pub := signFixtureAtTime(t, "tc", issued, expires, []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "model-a",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	c, err := Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if err := Verify(c, pub, time.Now()); err != nil {
		t.Fatalf("Verify within grace: %v", err)
	}
}

// SPEC-008 v0.3 / §M.3.2 step 3 — version pinned to 1; any other
// value MUST be rejected to keep the buyer-side and coordinator-side
// catalog accept/reject contracts equivalent.
func TestParseRejectsNonOneVersion(t *testing.T) {
	for _, version := range []int{0, 2, 3, -1, 99} {
		t.Run(fmtVersionName(version), func(t *testing.T) {
			raw, _ := signFixtureWithVersion(t, version, "tc", time.Now().Add(time.Hour), []ModelEntry{{
				ArtifactKind: "mlx_weight_file",
				HashScope:    "primary_weight_file",
				ModelID:      "model-a",
				SHA256:       validHash,
				Source:       "operator-curated",
			}})
			if _, err := Parse(raw); err == nil {
				t.Fatalf("Parse accepted version=%d", version)
			}
		})
	}
}

// Mirror phase4-coordinator/internal/tier2/catalog.go:473-475 — all
// model + signature required fields are non-empty at parse time, so
// a signature-valid but schema-malformed catalog cannot become buyer
// input.
func TestParseRejectsMissingRequiredFields(t *testing.T) {
	cases := map[string]ModelEntry{
		"empty-artifact_kind": {
			ArtifactKind: "",
			HashScope:    "primary_weight_file",
			ModelID:      "model-a",
			SHA256:       validHash,
			Source:       "operator-curated",
		},
		"empty-hash_scope": {
			ArtifactKind: "mlx_weight_file",
			HashScope:    "",
			ModelID:      "model-a",
			SHA256:       validHash,
			Source:       "operator-curated",
		},
		"empty-source": {
			ArtifactKind: "mlx_weight_file",
			HashScope:    "primary_weight_file",
			ModelID:      "model-a",
			SHA256:       validHash,
			Source:       "",
		},
		"empty-model_id": {
			ArtifactKind: "mlx_weight_file",
			HashScope:    "primary_weight_file",
			ModelID:      "",
			SHA256:       validHash,
			Source:       "operator-curated",
		},
	}
	for name, model := range cases {
		t.Run(name, func(t *testing.T) {
			raw, _ := signFixture(t, "tc", time.Now().Add(time.Hour), []ModelEntry{model})
			if _, err := Parse(raw); err == nil {
				t.Fatalf("Parse accepted bad model: %+v", model)
			}
		})
	}
}

func TestParseRejectsMissingSignatureKeyID(t *testing.T) {
	raw, _ := signFixture(t, "tc", time.Now().Add(time.Hour), []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "model-a",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	mutated := bytes.Replace(raw, []byte(`"key_id":"fixture-key"`), []byte(`"key_id":""`), 1)
	if bytes.Equal(mutated, raw) {
		t.Fatal("key_id substitution did not change bytes")
	}
	if _, err := Parse(mutated); err == nil {
		t.Fatal("Parse accepted catalog with empty signature.key_id")
	}
}

func TestParseRejectsTrailingJSON(t *testing.T) {
	raw, _ := signFixture(t, "tc", time.Now().Add(time.Hour), []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "model-a",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	mutated := append(append([]byte(nil), raw...), []byte(` {"extra":true}`)...)
	if _, err := Parse(mutated); err == nil {
		t.Fatal("Parse accepted trailing top-level JSON object")
	}
}

func TestParseRejectsUnsupportedModelEntryFields(t *testing.T) {
	cases := map[string]ModelEntry{
		"unsupported-artifact_kind": {
			ArtifactKind: "gguf_weight_file",
			HashScope:    "primary_weight_file",
			ModelID:      "model-a",
			SHA256:       validHash,
			Source:       "operator-curated",
		},
		"unsupported-hash_scope": {
			ArtifactKind: "mlx_weight_file",
			HashScope:    "secondary_weight_file",
			ModelID:      "model-a",
			SHA256:       validHash,
			Source:       "operator-curated",
		},
	}
	for name, model := range cases {
		t.Run(name, func(t *testing.T) {
			raw, _ := signFixture(t, "tc", time.Now().Add(time.Hour), []ModelEntry{model})
			if _, err := Parse(raw); err == nil {
				t.Fatalf("Parse accepted unsupported model entry: %+v", model)
			}
		})
	}
}

// SPEC-015 §M.3.2 step 5 — 60s skew grace boundaries: exactly at +60s
// MUST be accepted; +61s MUST be rejected as ErrExpired.
func TestVerifyExpiryBoundaryAt60s(t *testing.T) {
	now := time.Date(2026, 6, 24, 12, 0, 0, 0, time.UTC)
	issued := now.Add(-2 * time.Hour)

	// expires_at = now - 60s → boundary inclusive: still accepted.
	expiresAtBoundary := now.Add(-60 * time.Second)
	raw, pub := signFixtureAtTime(t, "tc", issued, expiresAtBoundary, []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "model-a",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	c, err := Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if err := Verify(c, pub, now); err != nil {
		t.Fatalf("Verify at exactly +60s grace boundary: %v", err)
	}

	// expires_at = now - 61s → just over boundary: ErrExpired.
	expiresJustOver := now.Add(-61 * time.Second)
	raw2, pub2 := signFixtureAtTime(t, "tc", issued, expiresJustOver, []ModelEntry{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      "model-a",
		SHA256:       validHash,
		Source:       "operator-curated",
	}})
	c2, err := Parse(raw2)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	err = Verify(c2, pub2, now)
	var expErr *ErrExpired
	if !errors.As(err, &expErr) {
		t.Fatalf("Verify at +61s: err = %v, want ErrExpired", err)
	}
}

func TestParseRejectsMalformedSha256(t *testing.T) {
	cases := map[string]string{
		"uppercase": "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789",
		"too short": "deadbeef",
		"too long":  validHash + "00",
		"prefixed":  "sha256:" + validHash,
		"non-hex":   "g000000000000000000000000000000000000000000000000000000000000000",
	}
	for name, bad := range cases {
		t.Run(name, func(t *testing.T) {
			raw, _ := signFixture(t, "tc", time.Now().Add(time.Hour), []ModelEntry{{
				ArtifactKind: "mlx_weight_file",
				HashScope:    "primary_weight_file",
				ModelID:      "model-a",
				SHA256:       bad,
				Source:       "operator-curated",
			}})
			if _, err := Parse(raw); err == nil {
				t.Fatalf("Parse accepted bad sha256 %q", bad)
			}
		})
	}
}

// SPEC-015 §M.3 — pure-Go verifier MUST accept what the existing
// scripts/sign-catalog.go signer produces. The test fixture below
// uses the same canonicalBody key order and Sign() shape; if
// Verify accepts the fixture but rejects a known-good catalog from
// sign-catalog.go, the cross-tool parity is broken.
func TestParityWithSignCatalogProduces(t *testing.T) {
	// Seed mirrors the coordinator test seed for reproducibility.
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)

	issued := time.Now().Add(-time.Hour).UTC().Round(time.Second)
	expires := issued.Add(2 * time.Hour)
	body := canonicalBody{
		CatalogID: "macprovider-tier2-2026-06-24",
		ExpiresAt: expires.Format(time.RFC3339),
		IssuedAt:  issued.Format(time.RFC3339),
		Models: []ModelEntry{{
			ArtifactKind: "mlx_weight_file",
			HashScope:    "primary_weight_file",
			ModelID:      "mlx-community/Qwen2.5-7B-Instruct-4bit",
			SHA256:       validHash,
			Source:       "operator-curated",
		}},
		Version: 1,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	sig := ed25519.Sign(priv, canonical)
	file := File{
		CatalogID: body.CatalogID,
		ExpiresAt: body.ExpiresAt,
		IssuedAt:  body.IssuedAt,
		Models:    body.Models,
		Signature: Signature{Alg: "Ed25519", KeyID: "parity-key", Sig: base64.RawURLEncoding.EncodeToString(sig)},
		Version:   body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	c, err := Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if err := Verify(c, pub, time.Now()); err != nil {
		t.Fatalf("Verify: %v", err)
	}
	// Lookup case-fold should accept the buyer's case variant.
	entry, ok := Lookup(c, "MLX-COMMUNITY/QWEN2.5-7B-INSTRUCT-4BIT")
	if !ok {
		t.Fatalf("case-fold lookup miss")
	}
	if entry.SHA256 != validHash {
		t.Fatalf("entry.SHA256 = %q", entry.SHA256)
	}
}

// helpers

func signFixture(t *testing.T, catalogID string, expires time.Time, models []ModelEntry) ([]byte, ed25519.PublicKey) {
	t.Helper()
	issued := expires.Add(-time.Hour)
	return signFixtureAtTime(t, catalogID, issued, expires, models)
}

func signFixtureWithVersion(t *testing.T, version int, catalogID string, expires time.Time, models []ModelEntry) ([]byte, ed25519.PublicKey) {
	t.Helper()
	issued := expires.Add(-time.Hour)
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	body := canonicalBody{
		CatalogID: catalogID,
		ExpiresAt: expires.UTC().Format(time.RFC3339),
		IssuedAt:  issued.UTC().Format(time.RFC3339),
		Models:    models,
		Version:   version,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal canonical: %v", err)
	}
	sig := ed25519.Sign(priv, canonical)
	file := File{
		CatalogID: body.CatalogID,
		ExpiresAt: body.ExpiresAt,
		IssuedAt:  body.IssuedAt,
		Models:    body.Models,
		Signature: Signature{Alg: "Ed25519", KeyID: "fixture-key", Sig: base64.RawURLEncoding.EncodeToString(sig)},
		Version:   body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return raw, pub
}

func fmtVersionName(v int) string {
	if v < 0 {
		return "negative"
	}
	return fmt.Sprintf("v%d", v)
}

func signFixtureAtTime(t *testing.T, catalogID string, issued, expires time.Time, models []ModelEntry) ([]byte, ed25519.PublicKey) {
	t.Helper()
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	body := canonicalBody{
		CatalogID: catalogID,
		ExpiresAt: expires.UTC().Format(time.RFC3339),
		IssuedAt:  issued.UTC().Format(time.RFC3339),
		Models:    models,
		Version:   1,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal canonical: %v", err)
	}
	sig := ed25519.Sign(priv, canonical)
	file := File{
		CatalogID: body.CatalogID,
		ExpiresAt: body.ExpiresAt,
		IssuedAt:  body.IssuedAt,
		Models:    body.Models,
		Signature: Signature{Alg: "Ed25519", KeyID: "fixture-key", Sig: base64.RawURLEncoding.EncodeToString(sig)},
		Version:   body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("marshal catalog: %v", err)
	}
	return raw, pub
}

func mutateSignatureSig(t *testing.T, raw []byte) []byte {
	t.Helper()
	var f File
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	sig, err := base64.RawURLEncoding.DecodeString(f.Signature.Sig)
	if err != nil {
		t.Fatalf("decode sig: %v", err)
	}
	sig[0] ^= 0xff
	f.Signature.Sig = base64.RawURLEncoding.EncodeToString(sig)
	out, err := json.Marshal(f)
	if err != nil {
		t.Fatalf("marshal mutated: %v", err)
	}
	return out
}
