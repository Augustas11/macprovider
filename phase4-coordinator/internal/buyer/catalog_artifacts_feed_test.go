package buyer_test

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// validCatalogArtifactsFeed is the SPEC-023 §3.7.3 feed whose single model
// binds the `test-model` row of validCandidateFeed: same model_id, revision,
// sha256, and min_ram_gb, primary verified, rate_class declared.
func validCatalogArtifactsFeed(version, generatedAt, policyVersion, candidateSHA256 string) []byte {
	return []byte(fmt.Sprintf(
		`{"candidate_catalog_sha256":%q,"generated_at":%q,"models":{"test-model":{"artifacts":{"mlx-4bit":{"allowed_runtime_sources":["mlx_cache"],"hash":%q,"hash_algorithm":"macprovider.snapshot-manifest.v1","min_ram_gb":4,"quantization":"4bit","runtime_format":"mlx_safetensors","size_bytes":123456,"source_ref":{"kind":"huggingface_revision","repo_id":"mlx-community/Test-Model-4bit","revision":%q},"verification_status":"verified","verified_at":"2026-09-01"}},"primary_artifact_id":"mlx-4bit","rate_class":"class-8b"}},"policy_version":%q,"release_id":%q,"source":"operator_curated_autotune_artifact_catalog","version":%q}`,
		candidateSHA256, generatedAt, strings.Repeat("2", 64), strings.Repeat("1", 40), policyVersion, version, version,
	))
}

type artifactBoundFixture struct {
	cfg            config.AutotuneFeedsConfig
	candidateJSON  []byte
	artifactsJSON  []byte
	artifactsSig   []byte
	candidateSHA   string
	artifactKeyID  string
	candidateKeyID string
}

// artifactBoundFeedSet writes a complete signed five-feed release. `artifacts`
// derives the artifact-feed bytes from the candidate digest so a test can
// drift exactly one binding; `artifactKey`/`artifactKeyID` select the key that
// signs the artifact feed, which may differ from the candidate signer to prove
// §3.7.2 signer equality is checked, not assumed.
func artifactBoundFeedSet(
	t *testing.T,
	artifacts func(candidateSHA256 string) []byte,
	artifactKey ed25519.PrivateKey,
	artifactKeyID string,
	keyring map[string]ed25519.PublicKey,
	candidateKey ed25519.PrivateKey,
) artifactBoundFixture {
	t.Helper()
	dir := t.TempDir()
	const version, generatedAt, policyVersion = "test-release", "2026-07-10T00:00:00Z", "autotune-policy-v1"
	candidate := validCandidateFeed(version)
	digest := sha256.Sum256(candidate)
	candidateSHA := hex.EncodeToString(digest[:])
	candidateJSONPath, candidateSigPath := writeSignedFeedPair(t, dir, "autotune-candidates", candidate, "test-key", candidateKey)
	demandJSONPath, demandSigPath := writeSignedFeedPair(t, dir, "demand-rank", validDemandFeedWith(version, generatedAt, policyVersion), "test-key", candidateKey)
	rateCardJSONPath, rateCardSigPath := writeSignedFeedPair(t, dir, "rate-card", validRateCardFeed(generatedAt, policyVersion), "test-key", candidateKey)
	artifactsJSON := artifacts(candidateSHA)
	artifactsJSONPath, artifactsSigPath := writeSignedFeedPair(t, dir, "autotune-artifacts", artifactsJSON, artifactKeyID, artifactKey)
	artifactsSig, err := os.ReadFile(artifactsSigPath)
	if err != nil {
		t.Fatal(err)
	}
	publicKeys := map[string]string{}
	for id, key := range keyring {
		publicKeys[id] = base64.StdEncoding.EncodeToString(key)
	}
	return artifactBoundFixture{
		cfg: config.AutotuneFeedsConfig{
			RateCardPath:              rateCardJSONPath,
			RateCardSigPath:           rateCardSigPath,
			DemandRankPath:            demandJSONPath,
			DemandRankSigPath:         demandSigPath,
			AutotuneCandidatesPath:    candidateJSONPath,
			AutotuneCandidatesSigPath: candidateSigPath,
			CatalogArtifactsPath:      artifactsJSONPath,
			CatalogArtifactsSigPath:   artifactsSigPath,
			PublicKeys:                publicKeys,
		},
		candidateJSON:  candidate,
		artifactsJSON:  artifactsJSON,
		artifactsSig:   artifactsSig,
		candidateSHA:   candidateSHA,
		artifactKeyID:  artifactKeyID,
		candidateKeyID: "test-key",
	}
}

func boundArtifacts(candidateSHA string) []byte {
	return validCatalogArtifactsFeed("test-release", "2026-07-10T00:00:00Z", "autotune-policy-v1", candidateSHA)
}

func TestLoadAutotuneFeedsServesBoundCatalogArtifacts(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	fixture := artifactBoundFeedSet(t, boundArtifacts, privateKey, "test-key", map[string]ed25519.PublicKey{"test-key": publicKey}, privateKey)

	feeds, err := buyer.LoadAutotuneFeeds(fixture.cfg)
	if err != nil {
		t.Fatalf("LoadAutotuneFeeds: %v", err)
	}
	verification := feeds.CatalogArtifactsVerification
	if verification.KeyID != "test-key" || verification.Version != "test-release" || verification.PolicyVersion != "autotune-policy-v1" {
		t.Fatalf("catalog_artifacts verification=%+v", verification)
	}
	artifactsDigest := sha256.Sum256(fixture.artifactsJSON)
	if verification.SHA256 != hex.EncodeToString(artifactsDigest[:]) {
		t.Fatalf("catalog_artifacts digest=%q", verification.SHA256)
	}
	if !verification.GeneratedAt.Equal(feeds.AutotuneCandidatesVerification.GeneratedAt) {
		t.Fatalf("catalog_artifacts generated_at=%v candidates=%v", verification.GeneratedAt, feeds.AutotuneCandidatesVerification.GeneratedAt)
	}

	server := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithAutotuneFeeds(feeds))
	handler := server.Handler()
	for _, tc := range []struct {
		path string
		want []byte
	}{
		{"/v1/catalog-artifacts", fixture.artifactsJSON},
		{"/v1/catalog-artifacts.sig", fixture.artifactsSig},
		{"/v1/autotune-candidates", fixture.candidateJSON},
	} {
		req := httptest.NewRequest(http.MethodGet, tc.path, nil)
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("%s status=%d body=%s", tc.path, rr.Code, rr.Body.String())
		}
		if got := rr.Body.Bytes(); string(got) != string(tc.want) {
			t.Fatalf("%s body mismatch: got %d bytes want %d bytes", tc.path, len(got), len(tc.want))
		}
		if cc := rr.Header().Get("Cache-Control"); cc != "public, max-age=300" {
			t.Fatalf("%s Cache-Control=%q", tc.path, cc)
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/autotune-release", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("autotune release status=%d body=%s", rr.Code, rr.Body.String())
	}
	var release struct {
		ReleaseID string `json:"release_id"`
		Feeds     map[string]struct {
			SHA256      string `json:"sha256"`
			SignerKeyID string `json:"signer_key_id"`
		} `json:"feeds"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &release); err != nil {
		t.Fatalf("decode autotune release: %v", err)
	}
	status, ok := release.Feeds["catalog_artifacts"]
	if !ok || status.SHA256 != verification.SHA256 || status.SignerKeyID != "test-key" {
		t.Fatalf("autotune release feeds=%+v, want catalog_artifacts bound", release.Feeds)
	}
}

func TestAutotuneReleaseOmitsCatalogArtifactsForFourFeedRelease(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	dir := t.TempDir()
	jsonPath, sigPath := writeSignedFeedPair(t, dir, "autotune-candidates", validCandidateFeed("test-release"), "test-key", privateKey)
	feeds, err := buyer.LoadAutotuneFeeds(completeCandidateFeedConfig(t, dir, jsonPath, sigPath, "test-key", publicKey, privateKey))
	if err != nil {
		t.Fatalf("LoadAutotuneFeeds: %v", err)
	}
	if len(feeds.CatalogArtifactsJSON) != 0 || len(feeds.CatalogArtifactsSig) != 0 {
		t.Fatalf("four-feed release must not carry artifact bytes")
	}
	server := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithAutotuneFeeds(feeds))
	handler := server.Handler()
	for _, path := range []string{"/v1/catalog-artifacts", "/v1/catalog-artifacts.sig"} {
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
		if rr.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d want 404 for a four-feed release", path, rr.Code)
		}
	}
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/v1/autotune-release", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("autotune release status=%d body=%s", rr.Code, rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), "catalog_artifacts") {
		t.Fatalf("four-feed release status must keep the v0.1 shape: %s", rr.Body.String())
	}
}

func TestLoadAutotuneFeedsRejectsUnboundCatalogArtifacts(t *testing.T) {
	t.Parallel()
	replace := func(old, replacement string) func(string) []byte {
		return func(candidateSHA string) []byte {
			raw := boundArtifacts(candidateSHA)
			if !strings.Contains(string(raw), old) {
				panic("fixture does not contain " + old)
			}
			return []byte(strings.Replace(string(raw), old, replacement, 1))
		}
	}
	tests := []struct {
		name      string
		artifacts func(string) []byte
		want      string
	}{
		{
			name: "release version drift",
			artifacts: func(candidateSHA string) []byte {
				return validCatalogArtifactsFeed("other-release", "2026-07-10T00:00:00Z", "autotune-policy-v1", candidateSHA)
			},
			want: `catalog_artifacts version "other-release" != autotune_candidates version "test-release"`,
		},
		{
			name: "generated_at drift",
			artifacts: func(candidateSHA string) []byte {
				return validCatalogArtifactsFeed("test-release", "2026-07-11T00:00:00Z", "autotune-policy-v1", candidateSHA)
			},
			want: "catalog_artifacts generated_at",
		},
		{
			name:      "candidate digest drift",
			artifacts: func(string) []byte { return boundArtifacts(strings.Repeat("0", 64)) },
			want:      "candidate_catalog_sha256",
		},
		{
			name:      "release_id differs from version",
			artifacts: replace(`"release_id":"test-release"`, `"release_id":"test-release-2"`),
			want:      "release_id must equal version",
		},
		{
			name:      "primary hash drift",
			artifacts: replace(`"hash":"`+strings.Repeat("2", 64)+`"`, `"hash":"`+strings.Repeat("3", 64)+`"`),
			want:      "primary artifact hash does not equal the candidate model_sha256",
		},
		{
			name:      "primary revision drift",
			artifacts: replace(`"revision":"`+strings.Repeat("1", 40)+`"`, `"revision":"`+strings.Repeat("a", 40)+`"`),
			want:      "primary artifact revision does not equal the candidate model_revision",
		},
		{
			name:      "primary min_ram_gb drift",
			artifacts: replace(`"min_ram_gb":4`, `"min_ram_gb":8`),
			want:      "primary artifact min_ram_gb does not equal the candidate min_ram_gb",
		},
		{
			name:      "unknown top-level field",
			artifacts: replace(`"version":"test-release"}`, `"version":"test-release","extra":true}`),
			want:      `unknown field "extra"`,
		},
		{
			name:      "identity tuple: gguf digest on an mlx artifact",
			artifacts: replace(`"hash_algorithm":"macprovider.snapshot-manifest.v1"`, `"hash_algorithm":"macprovider.gguf-file.v1"`),
			want:      `runtime_format "mlx_safetensors" requires hash_algorithm "macprovider.snapshot-manifest.v1"`,
		},
		{
			name:      "identity tuple: loopback source on an mlx artifact",
			artifacts: replace(`"allowed_runtime_sources":["mlx_cache"]`, `"allowed_runtime_sources":["mlx_cache","openai_compatible_loopback"]`),
			want:      `may not allow runtime source "openai_compatible_loopback"`,
		},
		{
			name:      "unmeasured size",
			artifacts: replace(`"size_bytes":123456`, `"size_bytes":null`),
			want:      "size_bytes must be a measured integer > 0",
		},
		{
			name:      "recommendable row without rate_class",
			artifacts: replace(`,"rate_class":"class-8b"`, ``),
			want:      `recommendable candidate row "test-model" must declare a rate_class`,
		},
		{
			name:      "unknown rate_class",
			artifacts: replace(`"rate_class":"class-8b"`, `"rate_class":"class-1t"`),
			want:      `rate_class "class-1t" is not a SPEC-023 §3.3.1 class`,
		},
		{
			name:      "declared primary on a recommendable row",
			artifacts: replace(`"verification_status":"verified","verified_at":"2026-09-01"`, `"verification_status":"declared","verified_at":null`),
			want:      `recommendable candidate row "test-model" requires a verified primary artifact`,
		},
		{
			name:      "primary_artifact_id names no artifact",
			artifacts: replace(`"primary_artifact_id":"mlx-4bit"`, `"primary_artifact_id":"gguf-q4"`),
			want:      `primary_artifact_id "gguf-q4" does not name an artifact`,
		},
		{
			name:      "model absent from the candidate catalog",
			artifacts: replace(`"models":{"test-model"`, `"models":{"other-model"`),
			want:      `model "other-model" is absent from the candidate catalog`,
		},
		{
			name:      "wrong feed source",
			artifacts: replace(`"source":"operator_curated_autotune_artifact_catalog"`, `"source":"operator_curated_autotune_candidate_catalog"`),
			want:      `source must be "operator_curated_autotune_artifact_catalog"`,
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			publicKey, privateKey := testSigningKey(t)
			fixture := artifactBoundFeedSet(t, tc.artifacts, privateKey, "test-key", map[string]ed25519.PublicKey{"test-key": publicKey}, privateKey)
			_, err := buyer.LoadAutotuneFeeds(fixture.cfg)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("LoadAutotuneFeeds error=%v, want %q", err, tc.want)
			}
		})
	}
}

func TestLoadAutotuneFeedsRejectsCatalogArtifactsSignedByADifferentTrustedKey(t *testing.T) {
	t.Parallel()
	candidatePublic, candidatePrivate := testSigningKey(t)
	otherPublic, otherPrivate := testSigningKey(t)
	keyring := map[string]ed25519.PublicKey{"test-key": candidatePublic, "other-key": otherPublic}
	// A cryptographically valid signature under a second concurrently trusted
	// key is exactly the case SPEC-023 §3.7.2 names: unknown-key rejection
	// cannot see it, only signer equality can.
	fixture := artifactBoundFeedSet(t, boundArtifacts, otherPrivate, "other-key", keyring, candidatePrivate)
	_, err := buyer.LoadAutotuneFeeds(fixture.cfg)
	if err == nil || !strings.Contains(err.Error(), `signer key_id "other-key" != autotune_candidates signer key_id "test-key"`) {
		t.Fatalf("LoadAutotuneFeeds error=%v, want signer identity equality failure", err)
	}
	// The same second key signing every feed of the release is fine: equality,
	// not a fixed key id, is the rule.
	uniform := artifactBoundFeedSet(t, boundArtifacts, candidatePrivate, "test-key", keyring, candidatePrivate)
	if _, err := buyer.LoadAutotuneFeeds(uniform.cfg); err != nil {
		t.Fatalf("LoadAutotuneFeeds uniform signer: %v", err)
	}
}

func TestLoadAutotuneFeedsRejectsTamperedCatalogArtifactsBytes(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	fixture := artifactBoundFeedSet(t, boundArtifacts, privateKey, "test-key", map[string]ed25519.PublicKey{"test-key": publicKey}, privateKey)
	tampered := bytesReplace(t, fixture.artifactsJSON, `"rate_class":"class-8b"`, `"rate_class":"class-3b"`)
	if err := os.WriteFile(fixture.cfg.CatalogArtifactsPath, tampered, 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := buyer.LoadAutotuneFeeds(fixture.cfg)
	if err == nil || !strings.Contains(err.Error(), "autotune.catalog_artifacts signature verification failed") {
		t.Fatalf("LoadAutotuneFeeds error=%v, want signature verification failure", err)
	}
}

func TestLoadAutotuneFeedsRejectsCatalogArtifactsWithoutBaseFeeds(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	dir := t.TempDir()
	jsonPath, sigPath := writeSignedFeedPair(t, dir, "autotune-artifacts", boundArtifacts(strings.Repeat("0", 64)), "test-key", privateKey)
	_, err := buyer.LoadAutotuneFeeds(config.AutotuneFeedsConfig{
		CatalogArtifactsPath:    jsonPath,
		CatalogArtifactsSigPath: sigPath,
		PublicKeys:              map[string]string{"test-key": base64.StdEncoding.EncodeToString(publicKey)},
	})
	if err == nil || !strings.Contains(err.Error(), "catalog_artifacts requires the rate_card, demand_rank, and autotune_candidates feeds") {
		t.Fatalf("LoadAutotuneFeeds error=%v, want base-feed requirement", err)
	}
	_, err = buyer.LoadAutotuneFeeds(config.AutotuneFeedsConfig{
		CatalogArtifactsPath: jsonPath,
		PublicKeys:           map[string]string{"test-key": base64.StdEncoding.EncodeToString(publicKey)},
	})
	if err == nil || !strings.Contains(err.Error(), "autotune.catalog_artifacts_path and autotune.catalog_artifacts_sig_path must both be set") {
		t.Fatalf("LoadAutotuneFeeds error=%v, want pair requirement", err)
	}
}
