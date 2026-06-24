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
// the verified signed catalog bytes verbatim with the right Content-Type
// and Cache-Control.
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

func TestCatalogEndpointServesVerifiedBytesAfterFileReplacement(t *testing.T) {
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
	tampered := bytes.Replace(raw, []byte(`"catalog_id":"test-catalog-2026-06-24"`), []byte(`"catalog_id":"tampered-catalog-2026-06"`), 1)
	if bytes.Equal(tampered, raw) {
		t.Fatal("tamper replacement did not change catalog bytes")
	}
	if err := os.WriteFile(path, tampered, 0o600); err != nil {
		t.Fatalf("replace catalog file: %v", err)
	}
	server := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0))
	server.SetTier2Config(cfg)

	for name, rr := range map[string]*httptest.ResponseRecorder{
		"current": serveCatalogCurrent(server, "198.51.100.1:12345"),
		"id":      serveCatalogFile(server, "test-catalog-2026-06-24", "198.51.100.1:12346"),
	} {
		if rr.Code != http.StatusOK {
			t.Fatalf("%s status = %d body=%s", name, rr.Code, rr.Body.String())
		}
		if !bytes.Equal(rr.Body.Bytes(), raw) {
			t.Fatalf("%s served bytes from replaced file; got %s want verified raw catalog", name, rr.Body.String())
		}
	}
}

// GET /catalog/current serves the same signed catalog bytes without requiring
// installers to discover catalog_id from operator-only /poolz.
func TestCatalogCurrentServesActiveCatalogBytes(t *testing.T) {
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

	rr := serveCatalogCurrent(server, "198.51.100.1:12345")
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

	for _, target := range []string{"/catalog/current", "/catalog/test-catalog", "/catalog/pubkey"} {
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

// SPEC-015 v0.3 bundle audit round 1 SECURITY HIGH-1 fix:
// catalog endpoints sit behind nginx on loopback (see
// phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf), so
// every public buyer's r.RemoteAddr is 127.0.0.1. Keying the bucket
// solely off RemoteAddr collapses every public buyer into one shared
// pool and lets a single caller starve everyone else. The fix to
// poolCheckClientKey honors X-Real-IP only when r.RemoteAddr is a
// loopback address (so an open-internet attacker can't spoof). This
// test asserts two different X-Real-IP values behind 127.0.0.1 get
// independent buckets, while a direct caller cannot use X-Real-IP to
// escape its own bucket.
func TestCatalogEndpointRateLimitedPerXRealIPBehindLoopback(t *testing.T) {
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

	// Buyer A (X-Real-IP=198.51.100.1) burns the burst.
	for i := 1; i <= 10; i++ {
		rr := serveCatalogPubkeyWithRealIP(server, "127.0.0.1:65431", "198.51.100.1")
		if rr.Code != http.StatusOK {
			t.Fatalf("A request %d status = %d want 200 body=%s", i, rr.Code, rr.Body.String())
		}
	}
	// Buyer A's 11th request returns 429 — its own bucket is empty.
	if rr := serveCatalogPubkeyWithRealIP(server, "127.0.0.1:65431", "198.51.100.1"); rr.Code != http.StatusTooManyRequests {
		t.Fatalf("A request 11 status = %d want 429", rr.Code)
	}
	// Buyer B (X-Real-IP=198.51.100.2) behind the SAME loopback gets a
	// fresh bucket — this is what the fix protects.
	if rr := serveCatalogPubkeyWithRealIP(server, "127.0.0.1:65432", "198.51.100.2"); rr.Code != http.StatusOK {
		t.Fatalf("B request 1 status = %d want 200 — bucket leaked across X-Real-IP", rr.Code)
	}
	// Direct non-loopback caller MUST NOT escape its bucket by
	// spoofing X-Real-IP — header is only honored when RemoteAddr is
	// loopback. Different X-Real-IP values from the same direct
	// remote share the same bucket.
	for i := 1; i <= 10; i++ {
		rr := serveCatalogPubkeyWithRealIP(server, "203.0.113.5:50000", "decoy-1")
		if rr.Code != http.StatusOK {
			t.Fatalf("direct burst %d status = %d want 200", i, rr.Code)
		}
	}
	if rr := serveCatalogPubkeyWithRealIP(server, "203.0.113.5:50001", "decoy-2"); rr.Code != http.StatusTooManyRequests {
		t.Fatalf("direct spoof status = %d want 429 — X-Real-IP was honored for non-loopback caller", rr.Code)
	}
}

// helpers

func serveCatalogPubkeyWithRealIP(server *Server, remoteAddr, realIP string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/catalog/pubkey", nil)
	req.RemoteAddr = remoteAddr
	if realIP != "" {
		req.Header.Set("X-Real-IP", realIP)
	}
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}

func serveCatalogFile(server *Server, catalogID, remoteAddr string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/catalog/"+catalogID, nil)
	req.RemoteAddr = remoteAddr
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}

func serveCatalogCurrent(server *Server, remoteAddr string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/catalog/current", nil)
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
