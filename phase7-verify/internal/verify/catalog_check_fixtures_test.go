package verify

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type catalogModel struct {
	ArtifactKind string `json:"artifact_kind"`
	HashScope    string `json:"hash_scope"`
	ModelID      string `json:"model_id"`
	SHA256       string `json:"sha256"`
	Source       string `json:"source"`
}

// writeSignedCatalog produces a signed catalog file at a temp path
// containing the supplied models (with defaults filled in for the
// per-entry required fields). Returns (path, pubkey-bytes).
// writeTamperedSignedCatalog produces a signed catalog whose
// signature.sig has been flipped after signing, so verification will
// fail at the ed25519.Verify-returned-false branch.
func writeTamperedSignedCatalog(t *testing.T, catalogID string, expires time.Time, models []catalogModel) (string, ed25519.PublicKey) {
	t.Helper()
	path, pub := writeSignedCatalog(t, catalogID, expires, models)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read for tamper: %v", err)
	}
	// Flip the first base64 character of the signature.sig field.
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	sig := doc["signature"].(map[string]any)
	raw := sig["sig"].(string)
	if len(raw) == 0 {
		t.Fatal("sig empty")
	}
	flipped := []byte(raw)
	if flipped[0] == 'A' {
		flipped[0] = 'B'
	} else {
		flipped[0] = 'A'
	}
	sig["sig"] = string(flipped)
	out, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(path, out, 0o600); err != nil {
		t.Fatalf("rewrite: %v", err)
	}
	return path, pub
}

func writeSignedCatalog(t *testing.T, catalogID string, expires time.Time, models []catalogModel) (string, ed25519.PublicKey) {
	t.Helper()
	for i := range models {
		if models[i].ArtifactKind == "" {
			models[i].ArtifactKind = "mlx_weight_file"
		}
		if models[i].HashScope == "" {
			models[i].HashScope = "primary_weight_file"
		}
		if models[i].Source == "" {
			models[i].Source = "operator-curated"
		}
	}
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	issued := time.Now().Add(-time.Hour).UTC().Round(time.Second)
	type body struct {
		CatalogID string         `json:"catalog_id"`
		ExpiresAt string         `json:"expires_at"`
		IssuedAt  string         `json:"issued_at"`
		Models    []catalogModel `json:"models"`
		Version   int            `json:"version"`
	}
	type sig struct {
		Alg   string `json:"alg"`
		KeyID string `json:"key_id"`
		Sig   string `json:"sig"`
	}
	type file struct {
		CatalogID string         `json:"catalog_id"`
		ExpiresAt string         `json:"expires_at"`
		IssuedAt  string         `json:"issued_at"`
		Models    []catalogModel `json:"models"`
		Signature sig            `json:"signature"`
		Version   int            `json:"version"`
	}
	b := body{
		CatalogID: catalogID,
		ExpiresAt: expires.UTC().Format(time.RFC3339),
		IssuedAt:  issued.Format(time.RFC3339),
		Models:    models,
		Version:   1,
	}
	canonical, err := json.Marshal(b)
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	signature := ed25519.Sign(priv, canonical)
	f := file{
		CatalogID: b.CatalogID,
		ExpiresAt: b.ExpiresAt,
		IssuedAt:  b.IssuedAt,
		Models:    b.Models,
		Signature: sig{Alg: "Ed25519", KeyID: "verify-test-key", Sig: base64.RawURLEncoding.EncodeToString(signature)},
		Version:   b.Version,
	}
	raw, err := json.Marshal(f)
	if err != nil {
		t.Fatalf("marshal file: %v", err)
	}
	path := filepath.Join(t.TempDir(), "catalog.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	return path, pub
}
