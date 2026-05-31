package tier2

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

const testHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const otherHash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

func TestLoadCatalogVerifiesKnownGoodFixture(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	path := writeTempCatalog(t, raw)

	catalog, err := LoadCatalog(path, publicKey, zerolog.Nop())
	if err != nil {
		t.Fatalf("LoadCatalog: %v", err)
	}
	if catalog.CatalogID != "test-catalog" {
		t.Fatalf("catalog_id=%q", catalog.CatalogID)
	}
	if got := catalog.Models["model-a"].SHA256; got != testHash {
		t.Fatalf("sha=%q", got)
	}
}

func TestLoadCatalogRejectsCorruptedBodyAndLogsSignatureInvalid(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	corrupted := bytes.Replace(raw, []byte("model-a"), []byte("model-b"), 1)
	path := writeTempCatalog(t, corrupted)
	var logs bytes.Buffer
	logger := zerolog.New(&logs)

	_, err := LoadCatalog(path, publicKey, logger)
	if err == nil {
		t.Fatal("LoadCatalog succeeded, want signature failure")
	}
	if !strings.Contains(logs.String(), `"event":"catalog_signature_invalid"`) {
		t.Fatalf("logs did not include catalog_signature_invalid: %s", logs.String())
	}
}

func TestLoadCatalogRejectsExpiredCatalog(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(-time.Hour), testHash)
	path := writeTempCatalog(t, raw)

	_, err := LoadCatalog(path, publicKey, zerolog.Nop())
	if err == nil || !strings.Contains(err.Error(), "catalog expired") {
		t.Fatalf("LoadCatalog err=%v, want expired", err)
	}
}

func TestVerifyProviderHashStatuses(t *testing.T) {
	defer ResetForTest()
	raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	path := writeTempCatalog(t, raw)
	cfg := config.Default()
	cfg.Tier2.CatalogPath = path
	cfg.Tier2.CatalogPublicKey = publicKey
	if err := Configure(cfg.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("Configure: %v", err)
	}

	tests := []struct {
		name         string
		modelID      string
		reportedHash string
		want         pool.HashStatus
	}{
		{name: "match", modelID: "model-a", reportedHash: testHash, want: pool.HashStatusVerified},
		{name: "mismatch", modelID: "model-a", reportedHash: otherHash, want: pool.HashStatusMismatch},
		{name: "empty", modelID: "model-a", reportedHash: "", want: pool.HashStatusUncatalogued},
		{name: "invalid", modelID: "model-a", reportedHash: "not-a-sha", want: pool.HashStatusInvalid},
		{name: "unknown", modelID: "unknown-model", reportedHash: testHash, want: pool.HashStatusUncatalogued},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := VerifyProviderHash(tc.modelID, tc.reportedHash); got != tc.want {
				t.Fatalf("VerifyProviderHash=%q want %q", got, tc.want)
			}
		})
	}
}

func signedCatalogFixture(t *testing.T, expiresAt time.Time, sha string) ([]byte, string) {
	t.Helper()
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	privateKey := ed25519.NewKeyFromSeed(seed)
	publicKey := privateKey.Public().(ed25519.PublicKey)
	body := canonicalBody{
		CatalogID: "test-catalog",
		ExpiresAt: expiresAt.UTC().Format(time.RFC3339),
		IssuedAt:  time.Now().UTC().Add(-time.Hour).Format(time.RFC3339),
		Models: []ModelEntry{{
			ArtifactKind: "mlx_weight_file",
			HashScope:    "primary_weight_file",
			ModelID:      "model-a",
			SHA256:       sha,
			Source:       "operator-curated",
		}},
		Version: 1,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("canonical marshal: %v", err)
	}
	sig := ed25519.Sign(privateKey, canonical)
	file := catalogFile{
		CatalogID: body.CatalogID,
		ExpiresAt: body.ExpiresAt,
		IssuedAt:  body.IssuedAt,
		Models:    body.Models,
		Signature: Signature{Alg: "Ed25519", KeyID: "test-key", Sig: base64.RawURLEncoding.EncodeToString(sig)},
		Version:   body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("catalog marshal: %v", err)
	}
	return raw, base64.RawURLEncoding.EncodeToString(publicKey)
}

func writeTempCatalog(t *testing.T, raw []byte) string {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "catalog-*.json")
	if err != nil {
		t.Fatalf("CreateTemp: %v", err)
	}
	if _, err := f.Write(raw); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close catalog: %v", err)
	}
	return f.Name()
}
