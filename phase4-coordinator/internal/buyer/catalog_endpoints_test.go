package buyer

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

// SPEC-015 §M.4 / §M.5 AC-39 — GET /catalog/<catalog_id> returns
// the on-disk signed catalog bytes verbatim with the right
// Content-Type and Cache-Control.
func TestCatalogFileServesActiveCatalogBytes(t *testing.T) {
	defer tier2.ResetForTest()
	raw, pubkey := buyerCatalogFixture(t, "test-catalog-2026-06-24", time.Now().UTC().Add(time.Hour))
	path := writeBuyerCatalog(t, raw)
	cfg := config.Tier2Config{
		CatalogPath:      path,
		CatalogPublicKey: pubkey,
		ObserveEnabled:   true,
	}
	if err := tier2.Configure(cfg, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0))
	server.SetTier2Config(cfg)

	rr := serveCatalogFile(server, "test-catalog-2026-06-24", "198.51.100.1:12345")
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("Content-Type = %q", got)
	}
	if got := rr.Header().Get("Cache-Control"); got != "public, max-age=300" {
		t.Fatalf("Cache-Control = %q", got)
	}
	if !bytes.Equal(rr.Body.Bytes(), raw) {
		t.Fatalf("body bytes mismatch: got %d bytes, want %d", len(rr.Body.Bytes()), len(raw))
	}
}

// SPEC-015 §M.4 — wrong catalog_id → 404 catalog_not_found.
func TestCatalogFile404OnUnknownCatalogID(t *testing.T) {
	defer tier2.ResetForTest()
	raw, pubkey := buyerCatalogFixture(t, "test-catalog", time.Now().UTC().Add(time.Hour))
	path := writeBuyerCatalog(t, raw)
	cfg := config.Tier2Config{CatalogPath: path, CatalogPublicKey: pubkey}
	if err := tier2.Configure(cfg, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0))
	server.SetTier2Config(cfg)

	rr := serveCatalogFile(server, "nonexistent-catalog", "198.51.100.1:12345")
	if rr.Code != http.StatusNotFound {
		t.Fatalf("status = %d body=%s", rr.Code, rr.Body.String())
	}
	var got struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Error.Code != "catalog_not_found" {
		t.Fatalf("error.code = %q", got.Error.Code)
	}
}

// SPEC-015 §M.4 — no catalog configured → 404 on both endpoints.
func TestCatalogEndpoints404WhenNoCatalogConfigured(t *testing.T) {
	defer tier2.ResetForTest()
	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0))
	server.SetTier2Config(config.Tier2Config{})

	for _, target := range []string{"/catalog/test-catalog", "/catalog/pubkey"} {
		rr := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, target, nil)
		req.RemoteAddr = "198.51.100.1:12345"
		server.Handler().ServeHTTP(rr, req)
		if rr.Code != http.StatusNotFound {
			t.Fatalf("%s status = %d", target, rr.Code)
		}
	}
}

// SPEC-015 §M.4 — GET /catalog/pubkey returns base64url-unpadded
// pubkey + alg = "Ed25519".
func TestCatalogPubkeyReturnsBase64URLPubkeyAndCapitalEd25519(t *testing.T) {
	defer tier2.ResetForTest()
	raw, pubkey := buyerCatalogFixture(t, "test-catalog", time.Now().UTC().Add(time.Hour))
	path := writeBuyerCatalog(t, raw)
	cfg := config.Tier2Config{CatalogPath: path, CatalogPublicKey: pubkey}
	if err := tier2.Configure(cfg, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0))
	server.SetTier2Config(cfg)

	rr := serveCatalogPubkey(server, "198.51.100.1:12345")
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("Cache-Control"); got != "public, max-age=300" {
		t.Fatalf("Cache-Control = %q", got)
	}
	var got map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got["pubkey"] != pubkey {
		t.Fatalf("pubkey = %v want %q", got["pubkey"], pubkey)
	}
	if got["alg"] != "Ed25519" {
		t.Fatalf("alg = %v want \"Ed25519\" (capital E)", got["alg"])
	}
	// Decode pubkey as base64.RawURLEncoding and verify 32-byte length.
	decoded, err := base64.RawURLEncoding.DecodeString(pubkey)
	if err != nil {
		t.Fatalf("pubkey decode: %v", err)
	}
	if len(decoded) != ed25519.PublicKeySize {
		t.Fatalf("decoded pubkey len = %d want %d", len(decoded), ed25519.PublicKeySize)
	}
}

// SPEC-015 §M.4 — catalog endpoints share the receipt-keys rate
// limit bucket, so the 11th request in a second returns 429.
func TestCatalogEndpointRateLimited(t *testing.T) {
	defer tier2.ResetForTest()
	raw, pubkey := buyerCatalogFixture(t, "test-catalog", time.Now().UTC().Add(time.Hour))
	path := writeBuyerCatalog(t, raw)
	cfg := config.Tier2Config{CatalogPath: path, CatalogPublicKey: pubkey}
	if err := tier2.Configure(cfg, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0))
	server.SetTier2Config(cfg)
	now := time.Date(2026, 6, 24, 12, 0, 0, 0, time.UTC)
	server.now = func() time.Time { return now }

	for i := 1; i <= 11; i++ {
		rr := serveCatalogPubkey(server, "198.51.100.99:12345")
		want := http.StatusOK
		if i == 11 {
			want = http.StatusTooManyRequests
		}
		if rr.Code != want {
			t.Fatalf("request %d status = %d want %d body=%s", i, rr.Code, want, rr.Body.String())
		}
	}
}

// helpers

func serveCatalogFile(server *Server, catalogID, remoteAddr string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/catalog/"+catalogID, nil)
	req.RemoteAddr = remoteAddr
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}

func serveCatalogPubkey(server *Server, remoteAddr string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/catalog/pubkey", nil)
	req.RemoteAddr = remoteAddr
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}

// buyerCatalogFixture mirrors tier2's signedCatalogFixture but lives
// in the buyer test package so we don't import tier2 test-only
// helpers. Returns the raw signed catalog bytes and the
// base64.RawURLEncoding pubkey.
func buyerCatalogFixture(t *testing.T, catalogID string, expiresAt time.Time) ([]byte, string) {
	t.Helper()
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	privateKey := ed25519.NewKeyFromSeed(seed)
	publicKey := privateKey.Public().(ed25519.PublicKey)
	issuedAt := time.Now().UTC().Add(-time.Hour)
	if !issuedAt.Before(expiresAt) {
		issuedAt = expiresAt.Add(-time.Hour)
	}
	// Canonical body — keys ordered alphabetically as the existing
	// scripts/sign-catalog.go writes (catalog_id, expires_at,
	// issued_at, models, version).
	type catalogModel struct {
		ArtifactKind string `json:"artifact_kind"`
		HashScope    string `json:"hash_scope"`
		ModelID      string `json:"model_id"`
		SHA256       string `json:"sha256"`
		Source       string `json:"source"`
	}
	type canonicalBody struct {
		CatalogID string         `json:"catalog_id"`
		ExpiresAt string         `json:"expires_at"`
		IssuedAt  string         `json:"issued_at"`
		Models    []catalogModel `json:"models"`
		Version   int            `json:"version"`
	}
	body := canonicalBody{
		CatalogID: catalogID,
		ExpiresAt: expiresAt.UTC().Format(time.RFC3339),
		IssuedAt:  issuedAt.Format(time.RFC3339),
		Models: []catalogModel{{
			ArtifactKind: "mlx_weight_file",
			HashScope:    "primary_weight_file",
			ModelID:      "model-a",
			SHA256:       "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			Source:       "operator-curated",
		}},
		Version: 1,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("canonical marshal: %v", err)
	}
	sig := ed25519.Sign(privateKey, canonical)
	type signature struct {
		Alg   string `json:"alg"`
		KeyID string `json:"key_id"`
		Sig   string `json:"sig"`
	}
	type catalogFile struct {
		CatalogID string         `json:"catalog_id"`
		ExpiresAt string         `json:"expires_at"`
		IssuedAt  string         `json:"issued_at"`
		Models    []catalogModel `json:"models"`
		Signature signature      `json:"signature"`
		Version   int            `json:"version"`
	}
	file := catalogFile{
		CatalogID: body.CatalogID,
		ExpiresAt: body.ExpiresAt,
		IssuedAt:  body.IssuedAt,
		Models:    body.Models,
		Signature: signature{Alg: "Ed25519", KeyID: "buyer-test-key", Sig: base64.RawURLEncoding.EncodeToString(sig)},
		Version:   body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("catalog marshal: %v", err)
	}
	return raw, base64.RawURLEncoding.EncodeToString(publicKey)
}

func writeBuyerCatalog(t *testing.T, raw []byte) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "catalog.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	return path
}
