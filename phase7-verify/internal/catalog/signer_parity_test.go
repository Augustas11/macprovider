package catalog

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestParityWithSignCatalogToolReal exercises the existing
// scripts/sign-catalog.go signer against this package's Parse +
// Verify. Pure parity check at the contract boundary — the
// verifier MUST accept any catalog the signer produces (and the
// signer's pubkey).
//
// Skips when:
//   - `go` is not on PATH (CI / containers without a Go toolchain),
//   - scripts/sign-catalog.go cannot be located from this test
//     file's relative path (out-of-tree go test invocations).
//
// The test is fast (~100ms; one keygen + one sign invocation).
func TestParityWithSignCatalogToolReal(t *testing.T) {
	if _, err := exec.LookPath("go"); err != nil {
		t.Skipf("go binary not on PATH: %v", err)
	}
	repoRoot := findRepoRoot(t)
	signCatalog := filepath.Join(repoRoot, "scripts", "sign-catalog.go")
	if _, err := os.Stat(signCatalog); err != nil {
		t.Skipf("scripts/sign-catalog.go not found: %v", err)
	}

	dir := t.TempDir()
	pubKeyPath := filepath.Join(dir, "catalog-signing-key.pub")
	privKeyPath := filepath.Join(dir, "catalog-signing-key.priv")
	bodyPath := filepath.Join(dir, "catalog-body.json")
	outPath := filepath.Join(dir, "catalog.signed.json")

	// 1. keygen.
	mustRun(t, repoRoot,
		"go", "run", signCatalog, "keygen",
		"-public-out", pubKeyPath,
		"-private-out", privKeyPath,
	)

	// 2. write an unsigned canonical body (the signer's input).
	body := `{
  "catalog_id": "parity-test-catalog",
  "expires_at": "` + time.Now().Add(2*time.Hour).UTC().Format(time.RFC3339) + `",
  "issued_at": "` + time.Now().Add(-time.Minute).UTC().Format(time.RFC3339) + `",
  "models": [
    {
      "artifact_kind": "mlx_weight_file",
      "hash_scope": "primary_weight_file",
      "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "source": "operator-curated"
    }
  ],
  "version": 1
}`
	if err := os.WriteFile(bodyPath, []byte(body), 0o600); err != nil {
		t.Fatalf("write body: %v", err)
	}

	// 3. sign. sign-catalog.go takes the unsigned body as a
	// positional argument (NOT -in).
	mustRun(t, repoRoot,
		"go", "run", signCatalog, "sign",
		"-out", outPath,
		"-key", privKeyPath,
		bodyPath,
	)

	// 4. read the produced signed catalog + the produced pubkey.
	signed, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read signed catalog: %v", err)
	}
	pubKeyRaw, err := os.ReadFile(pubKeyPath)
	if err != nil {
		t.Fatalf("read pubkey: %v", err)
	}
	pubKeyB64 := strings.TrimSpace(string(pubKeyRaw))
	pubKeyBytes, err := base64.RawURLEncoding.DecodeString(pubKeyB64)
	if err != nil {
		t.Fatalf("decode pubkey base64url: %v (key=%q)", err, pubKeyB64)
	}
	if len(pubKeyBytes) != ed25519.PublicKeySize {
		t.Fatalf("pubkey size=%d, want %d", len(pubKeyBytes), ed25519.PublicKeySize)
	}

	// 5. Parse + Verify the signer's output.
	c, err := Parse(signed)
	if err != nil {
		t.Fatalf("Parse signer output: %v (raw=%s)", err, string(signed))
	}
	if c.CatalogID != "parity-test-catalog" {
		t.Fatalf("CatalogID=%q", c.CatalogID)
	}
	if err := Verify(c, ed25519.PublicKey(pubKeyBytes), time.Now()); err != nil {
		t.Fatalf("Verify signer output: %v", err)
	}

	// 6. Tamper the signed file and verify rejection.
	tampered := bytes.Replace(signed, []byte("parity-test-catalog"), []byte("tampered-catalog!!"), 1)
	if bytes.Equal(tampered, signed) {
		t.Fatal("tamper substitution did not change bytes")
	}
	c2, err := Parse(tampered)
	if err != nil {
		// Expected — schema validation on catalog_id length may catch it.
		return
	}
	err = Verify(c2, ed25519.PublicKey(pubKeyBytes), time.Now())
	var sigErr *ErrSignatureInvalid
	if !errors.As(err, &sigErr) {
		t.Fatalf("Verify tampered: err=%v, want ErrSignatureInvalid", err)
	}
}

func findRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "scripts", "sign-catalog.go")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Skip("could not locate repo root (no scripts/sign-catalog.go ancestor)")
			return ""
		}
		dir = parent
	}
}

func mustRun(t *testing.T, cwd string, args ...string) {
	t.Helper()
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = cwd
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("%s failed: %v\nstderr: %s", strings.Join(args, " "), err, stderr.String())
	}
}
