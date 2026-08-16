package ws_test

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

func nopLoggerForTest() zerolog.Logger { return zerolog.Nop() }

// SPEC-015 §M.4 / §M.5 AC-39 — /poolz emits catalog_id, catalog_url,
// catalog_pubkey_url when a tier-2 catalog is configured, loaded
// cleanly, and signature-verified.
func TestPoolzEmitsCatalogFieldsWhenCatalogActive(t *testing.T) {
	defer tier2.ResetForTest()
	raw, pubkey := wsCatalogFixture(t, "test-catalog-2026-06-24", time.Now().UTC().Add(time.Hour))
	path := writeWSCatalog(t, raw)
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.Tier2.CatalogPath = path
		cfg.Tier2.CatalogPublicKey = pubkey
		cfg.Tier2.PublicCatalogBaseURL = "https://coordinator.malibu.tech"
	})
	defer ts.Close()
	if err := tier2.Configure(config.Tier2Config{
		CatalogPath:      path,
		CatalogPublicKey: pubkey,
	}, nopLoggerForTest()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}

	raw2, _ := fetchPoolzCatalogFields(t, ts.URL)
	var parsed struct {
		CatalogID        *string `json:"catalog_id"`
		CatalogURL       *string `json:"catalog_url"`
		CatalogPubkeyURL *string `json:"catalog_pubkey_url"`
	}
	if err := json.Unmarshal(raw2, &parsed); err != nil {
		t.Fatalf("json: %v", err)
	}
	if parsed.CatalogID == nil || *parsed.CatalogID != "test-catalog-2026-06-24" {
		t.Fatalf("catalog_id = %v", parsed.CatalogID)
	}
	if parsed.CatalogURL == nil || *parsed.CatalogURL != "https://coordinator.malibu.tech/catalog/test-catalog-2026-06-24" {
		t.Fatalf("catalog_url = %v", parsed.CatalogURL)
	}
	if parsed.CatalogPubkeyURL == nil || *parsed.CatalogPubkeyURL != "https://coordinator.malibu.tech/catalog/pubkey" {
		t.Fatalf("catalog_pubkey_url = %v", parsed.CatalogPubkeyURL)
	}
}

// SPEC-015 §M.4 — /poolz OMITS the three catalog fields when no
// catalog is configured (§M.4 effectively-active condition fails on
// CatalogPath empty).
func TestPoolzOmitsCatalogFieldsWhenCatalogNotConfigured(t *testing.T) {
	defer tier2.ResetForTest()
	ts := newProviderServer(t)
	defer ts.Close()

	raw, _ := fetchPoolzCatalogFields(t, ts.URL)
	for _, key := range []string{"catalog_id", "catalog_url", "catalog_pubkey_url"} {
		if bytes.Contains(raw, []byte(`"`+key+`"`)) {
			t.Fatalf("/poolz includes %q with no catalog configured; raw=%s", key, raw)
		}
	}
}

// SPEC-015 §M.4 / AC-39 — when CatalogPath points at a missing
// file, malformed JSON, or a body whose signature does not verify,
// /poolz MUST OMIT the three catalog fields (they are absent from
// the response JSON, not present-with-null).
func TestPoolzOmitsCatalogFieldsWhenCatalogLoadFails(t *testing.T) {
	cases := []struct {
		name      string
		writeFile func(t *testing.T) (string, string) // returns (path, pubkey)
	}{
		{
			name: "missing-file",
			writeFile: func(t *testing.T) (string, string) {
				// Path under TempDir that we deliberately do NOT create.
				_, pubkey := wsCatalogFixture(t, "test-catalog", time.Now().UTC().Add(time.Hour))
				return filepath.Join(t.TempDir(), "missing-catalog.json"), pubkey
			},
		},
		{
			name: "malformed-json",
			writeFile: func(t *testing.T) (string, string) {
				_, pubkey := wsCatalogFixture(t, "test-catalog", time.Now().UTC().Add(time.Hour))
				return writeWSCatalog(t, []byte("this is not json")), pubkey
			},
		},
		{
			name: "signature-mismatch",
			writeFile: func(t *testing.T) (string, string) {
				raw, _ := wsCatalogFixture(t, "test-catalog", time.Now().UTC().Add(time.Hour))
				// Generate an UNRELATED pubkey so the catalog signature
				// will not verify against the configured CatalogPublicKey.
				seed := bytes.Repeat([]byte{99}, ed25519.SeedSize)
				other := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
				return writeWSCatalog(t, raw), base64.RawURLEncoding.EncodeToString(other)
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			defer tier2.ResetForTest()
			path, pubkey := tc.writeFile(t)
			ts := newProviderServer(t, func(cfg *config.Config) {
				cfg.Tier2.CatalogPath = path
				cfg.Tier2.CatalogPublicKey = pubkey
				cfg.Tier2.PublicCatalogBaseURL = "https://coordinator.malibu.tech"
			})
			defer ts.Close()
			// Configure with strict=false so a failed catalog leaves
			// tier2.Active() == false rather than refusing startup.
			_ = tier2.Configure(config.Tier2Config{
				CatalogPath:      path,
				CatalogPublicKey: pubkey,
			}, nopLoggerForTest())
			if tier2.Active() {
				t.Fatalf("tier2.Active() = true for failure case %q; test setup is wrong", tc.name)
			}

			raw, _ := fetchPoolzCatalogFields(t, ts.URL)
			for _, key := range []string{"catalog_id", "catalog_url", "catalog_pubkey_url"} {
				if bytes.Contains(raw, []byte(`"`+key+`"`)) {
					t.Fatalf("%s: /poolz includes %q for failed catalog; raw=%s", tc.name, key, raw)
				}
			}
		})
	}
}

// SPEC-015 §M.4 — URL construction edge cases. Trailing slash on
// PublicCatalogBaseURL is trimmed; empty config falls back to
// scheme+Host; missing host → URL fields omitted but catalog_id
// still emitted.
func TestPoolzCatalogURLConstructionEdgeCases(t *testing.T) {
	cases := []struct {
		name             string
		baseURL          string
		hostHeader       string
		wantCatalogURL   string
		wantPubkeyURL    string
		expectURLsAbsent bool
	}{
		{
			name:           "trailing-slash-base",
			baseURL:        "https://coordinator.malibu.tech/",
			hostHeader:     "coordinator.malibu.tech",
			wantCatalogURL: "https://coordinator.malibu.tech/catalog/test-catalog",
			wantPubkeyURL:  "https://coordinator.malibu.tech/catalog/pubkey",
		},
		{
			name:           "host-with-port-fallback",
			baseURL:        "",
			hostHeader:     "test.example:8443",
			wantCatalogURL: "http://test.example:8443/catalog/test-catalog",
			wantPubkeyURL:  "http://test.example:8443/catalog/pubkey",
		},
		{
			name:           "ipv6-host-fallback",
			baseURL:        "",
			hostHeader:     "[2001:db8::1]:8443",
			wantCatalogURL: "http://[2001:db8::1]:8443/catalog/test-catalog",
			wantPubkeyURL:  "http://[2001:db8::1]:8443/catalog/pubkey",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			defer tier2.ResetForTest()
			raw, pubkey := wsCatalogFixture(t, "test-catalog", time.Now().UTC().Add(time.Hour))
			path := writeWSCatalog(t, raw)
			ts := newProviderServer(t, func(cfg *config.Config) {
				cfg.Tier2.CatalogPath = path
				cfg.Tier2.CatalogPublicKey = pubkey
				cfg.Tier2.PublicCatalogBaseURL = tc.baseURL
			})
			defer ts.Close()
			if err := tier2.Configure(config.Tier2Config{
				CatalogPath:      path,
				CatalogPublicKey: pubkey,
			}, nopLoggerForTest()); err != nil {
				t.Fatalf("tier2.Configure: %v", err)
			}

			req, err := http.NewRequest(http.MethodGet, ts.URL+"/poolz", nil)
			if err != nil {
				t.Fatalf("request: %v", err)
			}
			req.Header.Set("Authorization", "Bearer test-operator-key")
			req.Host = tc.hostHeader
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("/poolz: %v", err)
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			var parsed struct {
				CatalogID        *string `json:"catalog_id"`
				CatalogURL       *string `json:"catalog_url"`
				CatalogPubkeyURL *string `json:"catalog_pubkey_url"`
			}
			if err := json.Unmarshal(body, &parsed); err != nil {
				t.Fatalf("json: %v body=%s", err, body)
			}
			if parsed.CatalogID == nil || *parsed.CatalogID != "test-catalog" {
				t.Fatalf("catalog_id = %v body=%s", parsed.CatalogID, body)
			}
			if parsed.CatalogURL == nil || *parsed.CatalogURL != tc.wantCatalogURL {
				t.Fatalf("catalog_url = %v want %q", parsed.CatalogURL, tc.wantCatalogURL)
			}
			if parsed.CatalogPubkeyURL == nil || *parsed.CatalogPubkeyURL != tc.wantPubkeyURL {
				t.Fatalf("catalog_pubkey_url = %v want %q", parsed.CatalogPubkeyURL, tc.wantPubkeyURL)
			}
		})
	}
}

// helpers (shadowed names to avoid conflict with server_test.go)

func fetchPoolzCatalogFields(t *testing.T, serverURL string) ([]byte, *http.Response) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, serverURL+"/poolz", nil)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("/poolz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("/poolz status = %d body=%s", resp.StatusCode, body)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return body, resp
}

func wsCatalogFixture(t *testing.T, catalogID string, expiresAt time.Time) ([]byte, string) {
	t.Helper()
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	privateKey := ed25519.NewKeyFromSeed(seed)
	publicKey := privateKey.Public().(ed25519.PublicKey)
	issuedAt := time.Now().UTC().Add(-time.Hour)
	if !issuedAt.Before(expiresAt) {
		issuedAt = expiresAt.Add(-time.Hour)
	}
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
		t.Fatalf("canonical: %v", err)
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
		Signature: signature{Alg: "Ed25519", KeyID: "ws-test-key", Sig: base64.RawURLEncoding.EncodeToString(sig)},
		Version:   body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return raw, base64.RawURLEncoding.EncodeToString(publicKey)
}

func writeWSCatalog(t *testing.T, raw []byte) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "catalog.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	return path
}
