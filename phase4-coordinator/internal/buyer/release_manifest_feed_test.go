package buyer_test

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// releaseManifestFixture is a three-feed release directory signed with a
// throwaway test key, plus its config.
type releaseManifestFixture struct {
	dir        string
	cfg        config.AutotuneFeedsConfig
	privateKey ed25519.PrivateKey
}

func newReleaseManifestFixture(t *testing.T) releaseManifestFixture {
	t.Helper()
	publicKey, privateKey := testSigningKey(t)
	dir := t.TempDir()
	candidatePath, candidateSigPath := writeSignedFeedPair(t, dir, "autotune-candidates", validCandidateFeed("release-a"), "test-key", privateKey)
	cfg := completeCandidateFeedConfig(t, dir, candidatePath, candidateSigPath, "test-key", publicKey, privateKey)
	return releaseManifestFixture{dir: dir, cfg: cfg, privateKey: privateKey}
}

func (f releaseManifestFixture) manifest(t *testing.T) map[string]any {
	t.Helper()
	feeds := map[string]any{}
	for name, path := range map[string]string{
		"autotune-candidates.json": f.cfg.AutotuneCandidatesPath,
		"demand-rank.json":         f.cfg.DemandRankPath,
		"rate-card.json":           f.cfg.RateCardPath,
	} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(raw)
		feeds[name] = map[string]any{
			"bytes": len(raw), "sha256": hex.EncodeToString(sum[:]), "signer_key_id": "test-key", "version": "v",
		}
	}
	feeds["tier2-catalog.json"] = map[string]any{
		"bytes": 10, "sha256": strings.Repeat("a", 64), "signer_key_id": "tier2-coordinator-key:test", "version": "tier2",
	}
	return map[string]any{
		"feeds":          feeds,
		"generated_at":   "2026-07-10T00:00:00Z",
		"policy_version": "autotune-policy-v1",
		"release_id":     "release-a",
		"schema_version": "macprovider.autotune-release.v1",
	}
}

func (f releaseManifestFixture) write(t *testing.T, manifest map[string]any, keyID string, key ed25519.PrivateKey) []byte {
	t.Helper()
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	sidecar, err := json.Marshal(map[string]string{
		"key_id": keyID, "alg": "ed25519", "signature": base64.StdEncoding.EncodeToString(ed25519.Sign(key, raw)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.dir, "release.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.dir, "release.json.sig"), sidecar, 0o600); err != nil {
		t.Fatal(err)
	}
	return raw
}

func serveFeed(t *testing.T, feeds buyer.AutotuneFeeds, path string) *httptest.ResponseRecorder {
	t.Helper()
	server := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithAutotuneFeeds(feeds))
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
	return rr
}

func TestReleaseManifestServedWhenSignedAndBindingServedFeeds(t *testing.T) {
	t.Parallel()
	f := newReleaseManifestFixture(t)
	raw := f.write(t, f.manifest(t), "test-key", f.privateKey)
	sig, err := os.ReadFile(filepath.Join(f.dir, "release.json.sig"))
	if err != nil {
		t.Fatal(err)
	}
	feeds, err := buyer.LoadAutotuneFeeds(f.cfg)
	if err != nil {
		t.Fatalf("LoadAutotuneFeeds: %v", err)
	}
	if rr := serveFeed(t, feeds, "/v1/catalog-release"); rr.Code != http.StatusOK || rr.Body.String() != string(raw) {
		t.Fatalf("/v1/catalog-release status=%d body mismatch", rr.Code)
	}
	if rr := serveFeed(t, feeds, "/v1/catalog-release.sig"); rr.Code != http.StatusOK || rr.Body.String() != string(sig) {
		t.Fatalf("/v1/catalog-release.sig status=%d body mismatch", rr.Code)
	}
	// Per-feed sidecars keep being served beside the manifest.
	if rr := serveFeed(t, feeds, "/v1/autotune-candidates.sig"); rr.Code != http.StatusOK {
		t.Fatalf("/v1/autotune-candidates.sig status=%d", rr.Code)
	}
}

func TestReleaseManifestAbsentServesFeedsAnd404(t *testing.T) {
	t.Parallel()
	f := newReleaseManifestFixture(t)
	// An unsigned release.json (a release cut before SPEC-023 §3.8) is ignored.
	raw, _ := json.Marshal(f.manifest(t))
	if err := os.WriteFile(filepath.Join(f.dir, "release.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	feeds, err := buyer.LoadAutotuneFeeds(f.cfg)
	if err != nil {
		t.Fatalf("LoadAutotuneFeeds: %v", err)
	}
	for _, path := range []string{"/v1/catalog-release", "/v1/catalog-release.sig"} {
		if rr := serveFeed(t, feeds, path); rr.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d want 404", path, rr.Code)
		}
	}
	if rr := serveFeed(t, feeds, "/v1/autotune-candidates"); rr.Code != http.StatusOK {
		t.Fatalf("/v1/autotune-candidates status=%d", rr.Code)
	}
}

func TestReleaseManifestRoutesDisabledWhenFeedsUnset(t *testing.T) {
	t.Parallel()
	for _, path := range []string{"/v1/catalog-release", "/v1/catalog-release.sig"} {
		if rr := serveFeed(t, buyer.AutotuneFeeds{}, path); rr.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d want 404", path, rr.Code)
		}
	}
}

func TestReleaseManifestFailsClosed(t *testing.T) {
	t.Parallel()
	cases := map[string]struct {
		mutate func(t *testing.T, f releaseManifestFixture)
		want   string
	}{
		"signature over other bytes": {
			mutate: func(t *testing.T, f releaseManifestFixture) {
				f.write(t, f.manifest(t), "test-key", f.privateKey)
				path := filepath.Join(f.dir, "release.json")
				raw, _ := os.ReadFile(path)
				_ = os.WriteFile(path, append(raw, ' '), 0o600)
			},
			want: "signature verification failed",
		},
		"unknown signing key": {
			mutate: func(t *testing.T, f releaseManifestFixture) {
				_, other := testSigningKey(t)
				f.write(t, f.manifest(t), "other-key", other)
			},
			want: "unknown key_id",
		},
		"served feed digest differs": {
			mutate: func(t *testing.T, f releaseManifestFixture) {
				m := f.manifest(t)
				m["feeds"].(map[string]any)["demand-rank.json"].(map[string]any)["sha256"] = strings.Repeat("b", 64)
				f.write(t, m, "test-key", f.privateKey)
			},
			want: "does not match the served bytes",
		},
		"served feed not bound": {
			mutate: func(t *testing.T, f releaseManifestFixture) {
				m := f.manifest(t)
				delete(m["feeds"].(map[string]any), "rate-card.json")
				f.write(t, m, "test-key", f.privateKey)
			},
			want: "does not bind served feed rate-card.json",
		},
		"static feed bound to another signer": {
			mutate: func(t *testing.T, f releaseManifestFixture) {
				m := f.manifest(t)
				m["feeds"].(map[string]any)["demand-rank.json"].(map[string]any)["signer_key_id"] = "other-key"
				f.write(t, m, "test-key", f.privateKey)
			},
			want: "not the manifest signer",
		},
		"other release": {
			mutate: func(t *testing.T, f releaseManifestFixture) {
				m := f.manifest(t)
				m["release_id"] = "release-b"
				f.write(t, m, "test-key", f.privateKey)
			},
			want: "release_id",
		},
		"unknown field": {
			mutate: func(t *testing.T, f releaseManifestFixture) {
				m := f.manifest(t)
				m["extra"] = true
				f.write(t, m, "test-key", f.privateKey)
			},
			want: "schema",
		},
		"signature without manifest": {
			mutate: func(t *testing.T, f releaseManifestFixture) {
				f.write(t, f.manifest(t), "test-key", f.privateKey)
				_ = os.Remove(filepath.Join(f.dir, "release.json"))
			},
			want: "unreadable",
		},
	}
	for name, tc := range cases {
		name, tc := name, tc
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newReleaseManifestFixture(t)
			tc.mutate(t, f)
			_, err := buyer.LoadAutotuneFeeds(f.cfg)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("LoadAutotuneFeeds error=%v, want %q", err, tc.want)
			}
		})
	}
}

func TestReleaseManifestSignedByTrustedNonCandidateKeyFailsClosed(t *testing.T) {
	t.Parallel()
	f := newReleaseManifestFixture(t)
	otherPublic, otherPrivate := testSigningKey(t)
	f.cfg.PublicKeys["other-key"] = base64.StdEncoding.EncodeToString(otherPublic)
	m := f.manifest(t)
	for name, entry := range m["feeds"].(map[string]any) {
		if name != "tier2-catalog.json" {
			entry.(map[string]any)["signer_key_id"] = "other-key"
		}
	}
	f.write(t, m, "other-key", otherPrivate)
	_, err := buyer.LoadAutotuneFeeds(f.cfg)
	if err == nil || !strings.Contains(err.Error(), "!= autotune_candidates signer key_id") {
		t.Fatalf("LoadAutotuneFeeds error=%v, want signer mismatch", err)
	}
}
