package buyer_test

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
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

const autotuneV4PublicKeyBase64 = "zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU="

func TestAutotuneFeedsServeLiteralSignedBytes(t *testing.T) {
	t.Parallel()
	staticDir := filepath.Join("..", "..", "..", "phase3-binary", "dist", "static")
	demandJSON, err := os.ReadFile(filepath.Join(staticDir, "demand-rank.json"))
	if err != nil {
		t.Fatalf("read demand-rank.json: %v", err)
	}
	demandSig, err := os.ReadFile(filepath.Join(staticDir, "demand-rank.json.sig"))
	if err != nil {
		t.Fatalf("read demand-rank.json.sig: %v", err)
	}
	candidatesJSON, err := os.ReadFile(filepath.Join(staticDir, "autotune-candidates.json"))
	if err != nil {
		t.Fatalf("read autotune-candidates.json: %v", err)
	}
	candidatesSig, err := os.ReadFile(filepath.Join(staticDir, "autotune-candidates.json.sig"))
	if err != nil {
		t.Fatalf("read autotune-candidates.json.sig: %v", err)
	}

	feeds, err := buyer.LoadAutotuneFeeds(config.AutotuneFeedsConfig{
		DemandRankPath:            filepath.Join(staticDir, "demand-rank.json"),
		DemandRankSigPath:         filepath.Join(staticDir, "demand-rank.json.sig"),
		AutotuneCandidatesPath:    filepath.Join(staticDir, "autotune-candidates.json"),
		AutotuneCandidatesSigPath: filepath.Join(staticDir, "autotune-candidates.json.sig"),
		PublicKeys: map[string]string{
			"streamvc-autotune-static-v4": autotuneV4PublicKeyBase64,
		},
	})
	if err != nil {
		t.Fatalf("LoadAutotuneFeeds: %v", err)
	}
	for name, verification := range map[string]buyer.AutotuneFeedVerification{
		"demand_rank":         feeds.DemandRankVerification,
		"autotune_candidates": feeds.AutotuneCandidatesVerification,
	} {
		if verification.KeyID != "streamvc-autotune-static-v4" {
			t.Fatalf("%s key ID=%q", name, verification.KeyID)
		}
		if verification.Version != "published-2026-07-10-catalog-recovery-v1" {
			t.Fatalf("%s version=%q", name, verification.Version)
		}
		if verification.PolicyVersion != "autotune-policy-v1" {
			t.Fatalf("%s policy version=%q", name, verification.PolicyVersion)
		}
		if verification.VerifiedAt.IsZero() {
			t.Fatalf("%s verification time is zero", name)
		}
	}
	demandDigest := sha256.Sum256(demandJSON)
	if feeds.DemandRankVerification.SHA256 != hex.EncodeToString(demandDigest[:]) {
		t.Fatalf("demand digest=%q", feeds.DemandRankVerification.SHA256)
	}
	candidatesDigest := sha256.Sum256(candidatesJSON)
	if feeds.AutotuneCandidatesVerification.SHA256 != hex.EncodeToString(candidatesDigest[:]) {
		t.Fatalf("candidate digest=%q", feeds.AutotuneCandidatesVerification.SHA256)
	}

	server := buyer.NewServer(
		pool.NewRegistry(nil),
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithAutotuneFeeds(feeds),
	)
	handler := server.Handler()

	cases := []struct {
		path string
		want []byte
	}{
		{"/v1/demand-rank", demandJSON},
		{"/v1/demand-rank.sig", demandSig},
		{"/v1/autotune-candidates", candidatesJSON},
		{"/v1/autotune-candidates.sig", candidatesSig},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.path, func(t *testing.T) {
			t.Parallel()
			req := httptest.NewRequest(http.MethodGet, tc.path, nil)
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			if got := rr.Body.Bytes(); string(got) != string(tc.want) {
				t.Fatalf("body mismatch: got %d bytes want %d bytes", len(got), len(tc.want))
			}
			if cc := rr.Header().Get("Cache-Control"); cc != "public, max-age=300" {
				t.Fatalf("Cache-Control=%q", cc)
			}
		})
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/autotune-release", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("autotune release status=%d body=%s", rr.Code, rr.Body.String())
	}
	var release struct {
		Status        string `json:"status"`
		ReleaseID     string `json:"release_id"`
		PolicyVersion string `json:"policy_version"`
		Feeds         map[string]struct {
			SHA256      string `json:"sha256"`
			SignerKeyID string `json:"signer_key_id"`
		} `json:"feeds"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &release); err != nil {
		t.Fatalf("decode autotune release: %v", err)
	}
	if release.Status != "live_verified" || release.ReleaseID != "published-2026-07-10-catalog-recovery-v1" || release.PolicyVersion != "autotune-policy-v1" {
		t.Fatalf("autotune release metadata=%+v", release)
	}
	if release.Feeds["autotune_candidates"].SHA256 != feeds.AutotuneCandidatesVerification.SHA256 || release.Feeds["demand_rank"].SignerKeyID != "streamvc-autotune-static-v4" {
		t.Fatalf("autotune release feeds=%+v", release.Feeds)
	}
}

func TestLoadAutotuneFeedsRejectsTamperedLiteralBytes(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	dir := t.TempDir()
	original := validCandidateFeed("test-release")
	jsonPath, sigPath := writeSignedFeedPair(t, dir, "autotune-candidates", original, "test-key", privateKey)
	tampered := bytesReplace(t, original, `"runtime_status":"recommendable"`, `"runtime_status":"listed"`)
	if err := os.WriteFile(jsonPath, tampered, 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := buyer.LoadAutotuneFeeds(candidateFeedConfig(jsonPath, sigPath, "test-key", publicKey))
	if err == nil || !strings.Contains(err.Error(), "signature verification failed") {
		t.Fatalf("LoadAutotuneFeeds error=%v, want signature verification failure", err)
	}
}

func TestLoadAutotuneFeedsRejectsUnknownSidecarKey(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	dir := t.TempDir()
	jsonPath, sigPath := writeSignedFeedPair(t, dir, "autotune-candidates", validCandidateFeed("test-release"), "unknown-key", privateKey)

	_, err := buyer.LoadAutotuneFeeds(candidateFeedConfig(jsonPath, sigPath, "trusted-key", publicKey))
	if err == nil || !strings.Contains(err.Error(), `unknown key_id "unknown-key"`) {
		t.Fatalf("LoadAutotuneFeeds error=%v, want unknown key rejection", err)
	}
}

func TestLoadAutotuneFeedsRejectsMalformedSidecars(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		make func(signature string) []byte
		want string
	}{
		{
			name: "malformed JSON",
			make: func(string) []byte { return []byte(`{"key_id":`) },
			want: "EOF",
		},
		{
			name: "extra field",
			make: func(signature string) []byte {
				return []byte(fmt.Sprintf(`{"key_id":"test-key","alg":"ed25519","signature":%q,"extra":true}`, signature))
			},
			want: `unknown field "extra"`,
		},
		{
			name: "duplicate field",
			make: func(signature string) []byte {
				return []byte(fmt.Sprintf(`{"key_id":"test-key","key_id":"test-key","alg":"ed25519","signature":%q}`, signature))
			},
			want: `duplicate JSON field "key_id"`,
		},
		{
			name: "invalid signature base64",
			make: func(string) []byte {
				return []byte(`{"key_id":"test-key","alg":"ed25519","signature":"not-base64"}`)
			},
			want: "signature must be canonical padded base64",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			publicKey, privateKey := testSigningKey(t)
			dir := t.TempDir()
			raw := validCandidateFeed("test-release")
			jsonPath, sigPath := writeSignedFeedPair(t, dir, "autotune-candidates", raw, "test-key", privateKey)
			signature := base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, raw))
			if err := os.WriteFile(sigPath, tc.make(signature), 0o600); err != nil {
				t.Fatal(err)
			}
			_, err := buyer.LoadAutotuneFeeds(candidateFeedConfig(jsonPath, sigPath, "test-key", publicKey))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("LoadAutotuneFeeds error=%v, want %q", err, tc.want)
			}
		})
	}
}

func TestLoadAutotuneFeedsRejectsTrailingJSON(t *testing.T) {
	t.Parallel()
	t.Run("feed", func(t *testing.T) {
		publicKey, privateKey := testSigningKey(t)
		dir := t.TempDir()
		raw := append(validCandidateFeed("test-release"), []byte(`{}`)...)
		jsonPath, sigPath := writeSignedFeedPair(t, dir, "autotune-candidates", raw, "test-key", privateKey)
		_, err := buyer.LoadAutotuneFeeds(candidateFeedConfig(jsonPath, sigPath, "test-key", publicKey))
		if err == nil || !strings.Contains(err.Error(), "trailing JSON data") {
			t.Fatalf("LoadAutotuneFeeds error=%v, want trailing JSON rejection", err)
		}
	})
	t.Run("sidecar", func(t *testing.T) {
		publicKey, privateKey := testSigningKey(t)
		dir := t.TempDir()
		jsonPath, sigPath := writeSignedFeedPair(t, dir, "autotune-candidates", validCandidateFeed("test-release"), "test-key", privateKey)
		sidecar, err := os.ReadFile(sigPath)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(sigPath, append(sidecar, []byte(`{}`)...), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err = buyer.LoadAutotuneFeeds(candidateFeedConfig(jsonPath, sigPath, "test-key", publicKey))
		if err == nil || !strings.Contains(err.Error(), "trailing JSON data") {
			t.Fatalf("LoadAutotuneFeeds error=%v, want trailing JSON rejection", err)
		}
	})
}

func TestLoadAutotuneFeedsRejectsInvalidFeedSchema(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		raw  []byte
		want string
	}{
		{
			name: "unsafe mutable candidate revision",
			raw:  bytesReplace(t, validCandidateFeed("test-release"), strings.Repeat("1", 40), "main"),
			want: "model_revision must be lowercase 40-hex",
		},
		{
			name: "invalid artifact digest",
			raw:  bytesReplace(t, validCandidateFeed("test-release"), strings.Repeat("2", 64), strings.Repeat("A", 64)),
			want: "model_sha256 must be lowercase 64-hex",
		},
		{
			name: "unknown candidate field",
			raw:  bytesReplace(t, validCandidateFeed("test-release"), `"notes":"fixture"`, `"notes":"fixture","unsafe_override":true`),
			want: `unknown field "unsafe_override"`,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			publicKey, privateKey := testSigningKey(t)
			dir := t.TempDir()
			jsonPath, sigPath := writeSignedFeedPair(t, dir, "autotune-candidates", tc.raw, "test-key", privateKey)
			_, err := buyer.LoadAutotuneFeeds(candidateFeedConfig(jsonPath, sigPath, "test-key", publicKey))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("LoadAutotuneFeeds error=%v, want %q", err, tc.want)
			}
		})
	}
}

func TestLoadAutotuneFeedsRejectsInvalidDemandSchema(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		raw  []byte
		want string
	}{
		{
			name: "out of range demand weight",
			raw:  bytesReplace(t, validDemandFeed("test-release"), `"demand_weight":0.5`, `"demand_weight":1.5`),
			want: "demand_weight must be finite and in [0,1]",
		},
		{
			name: "missing deployability switch",
			raw:  bytesReplace(t, validDemandFeed("test-release"), `,"recommendable":true`, ""),
			want: "recommendable is required",
		},
		{
			name: "unknown demand field",
			raw:  bytesReplace(t, validDemandFeed("test-release"), `"min_provider_target":1`, `"min_provider_target":1,"supply_override":999`),
			want: `unknown field "supply_override"`,
		},
		{
			name: "negative ready provider count",
			raw:  bytesReplace(t, validDemandFeed("test-release"), `"min_provider_target":1`, `"min_provider_target":1,"ready_provider_count":-1`),
			want: "ready_provider_count must be >= 0",
		},
		{
			name: "unbounded supply multiplier",
			raw:  bytesReplace(t, validDemandFeed("test-release"), `"min_provider_target":1`, `"min_provider_target":1,"supply_deficit_multiplier":2.1`),
			want: "supply_deficit_multiplier must be finite and in [0.5,2.0]",
		},
		{
			name: "excessive dwell",
			raw:  bytesReplace(t, validDemandFeed("test-release"), `"min_provider_target":1`, `"min_provider_target":1,"min_dwell_hours":721`),
			want: "min_dwell_hours must be in [0,720]",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			publicKey, privateKey := testSigningKey(t)
			dir := t.TempDir()
			jsonPath, sigPath := writeSignedFeedPair(t, dir, "demand-rank", tc.raw, "test-key", privateKey)
			_, err := buyer.LoadAutotuneFeeds(config.AutotuneFeedsConfig{
				DemandRankPath:    jsonPath,
				DemandRankSigPath: sigPath,
				PublicKeys: map[string]string{
					"test-key": base64.StdEncoding.EncodeToString(publicKey),
				},
			})
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("LoadAutotuneFeeds error=%v, want %q", err, tc.want)
			}
		})
	}
}

func TestLoadAutotuneFeedsAcceptsBoundedSupplyTelemetry(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	dir := t.TempDir()
	raw := bytesReplace(
		t,
		validDemandFeed("test-release"),
		`"min_provider_target":1`,
		`"min_provider_target":1,"ready_provider_count":0,"supply_deficit_multiplier":2.0,"min_dwell_hours":720`,
	)
	raw = bytesReplace(t, raw, "openrouter_completion_token_rank_operator_curated", "macprovider_buyer_supply_deficit_v1")
	jsonPath, sigPath := writeSignedFeedPair(t, dir, "demand-rank", raw, "test-key", privateKey)
	feeds, err := buyer.LoadAutotuneFeeds(config.AutotuneFeedsConfig{
		DemandRankPath:    jsonPath,
		DemandRankSigPath: sigPath,
		PublicKeys: map[string]string{
			"test-key": base64.StdEncoding.EncodeToString(publicKey),
		},
	})
	if err != nil {
		t.Fatalf("LoadAutotuneFeeds: %v", err)
	}
	if feeds.DemandRankVerification.PolicyVersion != "autotune-policy-v1" {
		t.Fatalf("policy version=%q", feeds.DemandRankVerification.PolicyVersion)
	}
}

func TestLoadAutotuneFeedsRejectsMixedReleasePairs(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	dir := t.TempDir()
	demandJSONPath, demandSigPath := writeSignedFeedPair(t, dir, "demand-rank", validDemandFeed("release-a"), "test-key", privateKey)
	candidateJSONPath, candidateSigPath := writeSignedFeedPair(t, dir, "autotune-candidates", validCandidateFeed("release-b"), "test-key", privateKey)

	_, err := buyer.LoadAutotuneFeeds(config.AutotuneFeedsConfig{
		DemandRankPath:            demandJSONPath,
		DemandRankSigPath:         demandSigPath,
		AutotuneCandidatesPath:    candidateJSONPath,
		AutotuneCandidatesSigPath: candidateSigPath,
		PublicKeys: map[string]string{
			"test-key": base64.StdEncoding.EncodeToString(publicKey),
		},
	})
	if err == nil || !strings.Contains(err.Error(), "autotune feed release mismatch") {
		t.Fatalf("LoadAutotuneFeeds error=%v, want release mismatch", err)
	}
}

func TestAutotuneFeedsDisabledWhenUnset(t *testing.T) {
	t.Parallel()
	server := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0))
	handler := server.Handler()

	for _, path := range []string{
		"/v1/demand-rank",
		"/v1/demand-rank.sig",
		"/v1/autotune-candidates",
		"/v1/autotune-candidates.sig",
	} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, req)
		if rr.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d want 404", path, rr.Code)
		}
	}
}

func testSigningKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate Ed25519 key: %v", err)
	}
	return publicKey, privateKey
}

func validCandidateFeed(version string) []byte {
	return []byte(fmt.Sprintf(
		`{"version":%q,"policy_version":"autotune-policy-v1","generated_at":"2026-07-10T00:00:00Z","source":"operator_curated_autotune_candidate_catalog","rows":{"test-model":{"model_id":"mlx-community/Test-Model-4bit","model_revision":"%s","model_sha256":"%s","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommendable","notes":"fixture"}}}`,
		version,
		strings.Repeat("1", 40),
		strings.Repeat("2", 64),
	))
}

func TestCandidateCatalogSharedNestedSchemaCorpus(t *testing.T) {
	t.Parallel()
	corpus := filepath.Join("..", "..", "..", "phase3-binary", "catalog", "autotune", "testdata")
	publicKey, privateKey := testSigningKey(t)
	tests := map[string]bool{
		"valid-workload-profile.json":             true,
		"invalid-workload-profiles-type.json":     false,
		"invalid-draft-candidates-type.json":      false,
		"invalid-workload-no-winner-samples.json": false,
	}
	for fixture, valid := range tests {
		fixture, valid := fixture, valid
		t.Run(fixture, func(t *testing.T) {
			raw, err := os.ReadFile(filepath.Join(corpus, fixture))
			if err != nil {
				t.Fatal(err)
			}
			jsonPath, sigPath := writeSignedFeedPair(t, t.TempDir(), "candidate", raw, "test-key", privateKey)
			_, err = buyer.LoadAutotuneFeeds(candidateFeedConfig(jsonPath, sigPath, "test-key", publicKey))
			if valid && err != nil {
				t.Fatalf("valid corpus rejected: %v", err)
			}
			if !valid && err == nil {
				t.Fatal("invalid corpus accepted")
			}
		})
	}
}

func validDemandFeed(version string) []byte {
	return []byte(fmt.Sprintf(
		`{"version":%q,"policy_version":"autotune-policy-v1","generated_at":"2026-07-10T00:00:00Z","source":"openrouter_completion_token_rank_operator_curated","cold_start_floor":0.15,"diversification_band":0.85,"rows":{"test-model":{"demand_weight":0.5,"rank":1,"recommendable":true,"min_provider_target":1}}}`,
		version,
	))
}

func writeSignedFeedPair(
	t *testing.T,
	dir, name string,
	raw []byte,
	keyID string,
	privateKey ed25519.PrivateKey,
) (string, string) {
	t.Helper()
	jsonPath := filepath.Join(dir, name+".json")
	sigPath := jsonPath + ".sig"
	sidecar, err := json.Marshal(map[string]string{
		"key_id":    keyID,
		"alg":       "ed25519",
		"signature": base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, raw)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(jsonPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sigPath, sidecar, 0o600); err != nil {
		t.Fatal(err)
	}
	return jsonPath, sigPath
}

func candidateFeedConfig(jsonPath, sigPath, keyID string, publicKey ed25519.PublicKey) config.AutotuneFeedsConfig {
	return config.AutotuneFeedsConfig{
		AutotuneCandidatesPath:    jsonPath,
		AutotuneCandidatesSigPath: sigPath,
		PublicKeys: map[string]string{
			keyID: base64.StdEncoding.EncodeToString(publicKey),
		},
	}
}

func bytesReplace(t *testing.T, raw []byte, old, replacement string) []byte {
	t.Helper()
	updated := strings.Replace(string(raw), old, replacement, 1)
	if updated == string(raw) {
		t.Fatalf("fixture does not contain %q", old)
	}
	return []byte(updated)
}

func TestNginxAutotuneFeedsAllowThroughBeforeV1CatchAll(t *testing.T) {
	t.Parallel()
	b, err := os.ReadFile(filepath.Join("..", "..", "dist", "nginx-coordinator.streamvc.live.conf"))
	if err != nil {
		t.Fatalf("read nginx config: %v", err)
	}
	cfg := string(b)
	catchAll := strings.Index(cfg, "location /v1/ {\n        return 404;")
	if catchAll < 0 {
		t.Fatalf("/v1/ 404 catch-all missing")
	}
	beforeCatchAll := cfg[:catchAll]
	for _, location := range []string{
		"location = /v1/rate-card",
		"location = /v1/demand-rank",
		"location = /v1/demand-rank.sig",
		"location = /v1/autotune-candidates",
		"location = /v1/autotune-candidates.sig",
	} {
		if !strings.Contains(beforeCatchAll, location) {
			t.Fatalf("%s missing before /v1/ catch-all", location)
		}
	}
	if strings.Contains(beforeCatchAll, "location /static/") {
		t.Fatalf("legacy /static/ nginx alias should be removed")
	}
}
