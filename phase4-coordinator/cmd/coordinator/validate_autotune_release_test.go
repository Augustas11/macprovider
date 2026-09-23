package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

const validatorGeneratedAt = "2026-07-10T00:00:00Z"

func validatorKey() ed25519.PrivateKey {
	return ed25519.NewKeyFromSeed(bytes.Repeat([]byte{11}, ed25519.SeedSize))
}

func validatorCandidateFeed(version, modelSHA string) []byte {
	return []byte(fmt.Sprintf(
		`{"version":%q,"policy_version":"autotune-policy-v1","generated_at":%q,"source":"operator_curated_autotune_candidate_catalog","rows":{"test-model":{"model_id":"org/model-a","model_revision":"%s","model_sha256":%q,"min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000,"provenance":{"source":"legacy_unverified","notes":"test fixture"}},"runtime_status":"recommendable","notes":"fixture"}}}`,
		version, validatorGeneratedAt, strings.Repeat("1", 40), modelSHA,
	))
}

func validatorDemandFeed(version string) []byte {
	return []byte(fmt.Sprintf(
		`{"version":%q,"policy_version":"autotune-policy-v1","generated_at":%q,"source":"openrouter_completion_token_rank_operator_curated","cold_start_floor":0.15,"diversification_band":0.85,"rows":{"test-model":{"demand_weight":0.5,"rank":1,"recommendable":true,"min_provider_target":1}}}`,
		version, validatorGeneratedAt,
	))
}

func validatorRewards() config.RewardsConfig {
	return coordinatorParityRewards(map[string]config.RateCardEntry{"default": coordinatorParityEntry(100, 100, 200)})
}

func writeValidatorSigned(t *testing.T, path string, raw []byte) {
	t.Helper()
	sidecar, err := json.Marshal(map[string]string{
		"key_id":    "test-key",
		"alg":       "ed25519",
		"signature": base64.StdEncoding.EncodeToString(ed25519.Sign(validatorKey(), raw)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", sidecar, 0o600); err != nil {
		t.Fatal(err)
	}
}

// writeValidatorRelease writes a complete signed release (three feeds +
// Tier-2 catalog) into dir and returns the candidate and Tier-2 bytes.
func writeValidatorRelease(t *testing.T, dir, version, tier2SHA string) (candidates, tier2Raw []byte, tier2Pub string) {
	t.Helper()
	candidates = validatorCandidateFeed(version, reloadTestHash)
	writeValidatorSigned(t, filepath.Join(dir, "autotune-candidates.json"), candidates)
	writeValidatorSigned(t, filepath.Join(dir, "demand-rank.json"), validatorDemandFeed(version))
	writeValidatorSigned(t, filepath.Join(dir, "rate-card.json"), coordinatorParityFeeds(t, validatorRewards(), 1.0).RateCardJSON)
	tier2Raw, tier2Pub = signedReloadCatalogFixtureFor(t, time.Now().UTC().Add(time.Hour), "org/model-a", tier2SHA)
	if err := os.WriteFile(filepath.Join(dir, "tier2-catalog.json"), tier2Raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return candidates, tier2Raw, tier2Pub
}

// validatorConfig mirrors the deployed layout: every feed and the Tier-2
// catalog live under <liveRoot>/current.
func validatorConfig(liveRoot, tier2Pub string) config.Config {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "0123456789abcdefABCDEFghijklmnop"
	cfg.Auth.GatewayServiceToken = "fedcba9876543210FEDCBAzyxwvutsrq"
	cfg.Pool.WarmupGateEnabled = false
	cfg.Rewards = validatorRewards()
	cfg.Stats.Rollup.UsdPerMillionCredits = 1.0
	current := filepath.Join(liveRoot, "current")
	cfg.AutotuneFeeds.RateCardPath = filepath.Join(current, "rate-card.json")
	cfg.AutotuneFeeds.RateCardSigPath = filepath.Join(current, "rate-card.json.sig")
	cfg.AutotuneFeeds.DemandRankPath = filepath.Join(current, "demand-rank.json")
	cfg.AutotuneFeeds.DemandRankSigPath = filepath.Join(current, "demand-rank.json.sig")
	cfg.AutotuneFeeds.AutotuneCandidatesPath = filepath.Join(current, "autotune-candidates.json")
	cfg.AutotuneFeeds.AutotuneCandidatesSigPath = filepath.Join(current, "autotune-candidates.json.sig")
	cfg.AutotuneFeeds.EnforceProviderAdmission = true
	cfg.AutotuneFeeds.PublicKeys = map[string]string{
		"test-key": base64.StdEncoding.EncodeToString(validatorKey().Public().(ed25519.PublicKey)),
	}
	cfg.Tier2.CatalogPath = filepath.Join(current, "tier2-catalog.json")
	cfg.Tier2.CatalogPublicKey = tier2Pub
	cfg.Tier2.RequireHashVerified = true
	return cfg
}

func sha256Hex(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

// treeSnapshot records every path, size and mtime under root.
func treeSnapshot(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		out = append(out, fmt.Sprintf("%s|%d|%d", path, info.Size(), info.ModTime().UnixNano()))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(out)
	return out
}

func assertValidatorError(t *testing.T, got autotuneReleaseValidation, want string) {
	t.Helper()
	if got.OK {
		t.Fatalf("validator ok=true, want failure containing %q: %+v", want, got)
	}
	for _, e := range got.Errors {
		if strings.Contains(e, want) {
			return
		}
	}
	t.Fatalf("validator errors %q do not contain %q", got.Errors, want)
}

func TestValidateAutotuneReleaseAcceptsValidReleaseWithRetainedWindow(t *testing.T) {
	defer tier2.ResetForTest()
	base := t.TempDir()
	dir := filepath.Join(base, "candidate")
	candidates, tier2Raw, tier2Pub := writeValidatorRelease(t, dir, "release-next", reloadTestHash)
	previousRoot := filepath.Join(base, "retained")
	previousRaw := validatorCandidateFeed("release-prev", reloadTestHash)
	writeValidatorSigned(t, filepath.Join(previousRoot, "releases", "release-prev", "autotune-candidates.json"), previousRaw)
	previousTarget := filepath.Join(previousRoot, ".previous-target")
	if err := os.WriteFile(previousTarget, []byte("releases/release-prev\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	configPath := writeReloadConfig(t, validatorConfig(filepath.Join(base, "live"), tier2Pub))

	var out bytes.Buffer
	if code := runValidateAutotuneRelease(&out, configPath, "", dir, previousTarget); code != 0 {
		t.Fatalf("exit=%d want 0 output=%s", code, out.String())
	}
	if strings.Count(out.String(), "\n") != 1 {
		t.Fatalf("want exactly one JSON line, got %q", out.String())
	}
	var got autotuneReleaseValidation
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("decode %q: %v", out.String(), err)
	}
	if !got.OK || len(got.Errors) != 0 {
		t.Fatalf("validator result=%+v", got)
	}
	if got.ReleaseID != "release-next" || !strings.EqualFold(got.CandidatesSHA256, sha256Hex(candidates)) {
		t.Fatalf("release identity=%s/%s want release-next/%s", got.ReleaseID, got.CandidatesSHA256, sha256Hex(candidates))
	}
	if got.Tier2CatalogID != "test-catalog" || got.Tier2SHA256 != sha256Hex(tier2Raw) {
		t.Fatalf("tier2 identity=%s/%s want test-catalog/%s", got.Tier2CatalogID, got.Tier2SHA256, sha256Hex(tier2Raw))
	}
	if len(got.PreviousLoaded) != 1 || got.PreviousLoaded[0].ReleaseID != "release-prev" ||
		!strings.EqualFold(got.PreviousLoaded[0].CandidatesSHA256, sha256Hex(previousRaw)) {
		t.Fatalf("previous_loaded=%+v", got.PreviousLoaded)
	}
	if tier2.CatalogID() != "" {
		t.Fatalf("validator published into the tier2 singleton: %q", tier2.CatalogID())
	}
}

func TestValidateAutotuneReleaseRejectsRateCardParityMismatch(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "candidate")
	_, _, tier2Pub := writeValidatorRelease(t, dir, "release-next", reloadTestHash)
	cfg := validatorConfig(filepath.Join(base, "live"), tier2Pub)
	cfg.Rewards.RateCard["default"] = coordinatorParityEntry(101, 100, 200)

	got := validateAutotuneRelease(writeReloadConfig(t, cfg), "", dir, "", zerolog.Nop())
	assertValidatorError(t, got, "autotune runtime economics")
}

func TestValidateAutotuneReleaseRejectsTier2NotBoundToRelease(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "candidate")
	_, _, tier2Pub := writeValidatorRelease(t, dir, "release-next", reloadOtherHash)

	got := validateAutotuneRelease(writeReloadConfig(t, validatorConfig(filepath.Join(base, "live"), tier2Pub)), "", dir, "", zerolog.Nop())
	assertValidatorError(t, got, "autotune/tier2 identity conflict")
	if got.Tier2CatalogID != "" {
		t.Fatalf("rejected tier2 must not be reported as loaded: %q", got.Tier2CatalogID)
	}
}

func TestValidateAutotuneReleaseRejectsUnloadableRetainedEntry(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "candidate")
	_, _, tier2Pub := writeValidatorRelease(t, dir, "release-next", reloadTestHash)
	previousRoot := filepath.Join(base, "retained")
	if err := os.MkdirAll(filepath.Join(previousRoot, "releases", "release-gone"), 0o700); err != nil {
		t.Fatal(err)
	}
	previousTarget := filepath.Join(previousRoot, ".previous-target")
	if err := os.WriteFile(previousTarget, []byte("releases/release-gone\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	code := runValidateAutotuneRelease(&out, writeReloadConfig(t, validatorConfig(filepath.Join(base, "live"), tier2Pub)), "", dir, previousTarget)
	if code == 0 {
		t.Fatalf("exit=0 for unloadable retained entry: %s", out.String())
	}
	var got autotuneReleaseValidation
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("decode %q: %v", out.String(), err)
	}
	assertValidatorError(t, got, "autotune previous catalog")
}

// The live tree holds a different release and a .previous-target that would
// fail if read. The validator must neither read it nor write anywhere.
func TestValidateAutotuneReleaseDoesNotTouchLivePath(t *testing.T) {
	defer tier2.ResetForTest()
	base := t.TempDir()
	liveRoot := filepath.Join(base, "live")
	writeValidatorRelease(t, filepath.Join(liveRoot, "current"), "release-live", reloadTestHash)
	if err := os.WriteFile(filepath.Join(liveRoot, ".previous-target"), []byte("releases/release-broken\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(base, "candidate")
	_, _, tier2Pub := writeValidatorRelease(t, dir, "release-next", reloadTestHash)
	configPath := writeReloadConfig(t, validatorConfig(liveRoot, tier2Pub))
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	beforeBase, beforeCwd := treeSnapshot(t, base), treeSnapshot(t, cwd)

	got := validateAutotuneRelease(configPath, "", dir, "", zerolog.Nop())
	if !got.OK || got.ReleaseID != "release-next" || len(got.PreviousLoaded) != 0 {
		t.Fatalf("validator result=%+v, want ok on the candidate with no retained releases", got)
	}
	if after := treeSnapshot(t, base); strings.Join(after, "\n") != strings.Join(beforeBase, "\n") {
		t.Fatalf("validator changed the temp tree:\nbefore=%v\nafter=%v", beforeBase, after)
	}
	if after := treeSnapshot(t, cwd); strings.Join(after, "\n") != strings.Join(beforeCwd, "\n") {
		t.Fatal("validator created or modified files in the working directory")
	}
	if tier2.CatalogID() != "" {
		t.Fatalf("validator published into the tier2 singleton: %q", tier2.CatalogID())
	}
}

func TestReloadAutotuneFeedSIGHUPLogsTier2Identity(t *testing.T) {
	defer tier2.ResetForTest()
	liveRoot := t.TempDir()
	_, tier2Raw, tier2Pub := writeValidatorRelease(t, filepath.Join(liveRoot, "current"), "release-live", reloadTestHash)
	startup, _, wsServer, buyerServer := reloadTestServers(validatorConfig(liveRoot, tier2Pub))
	if err := tier2.Configure(startup.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("startup Configure: %v", err)
	}

	var logs bytes.Buffer
	reloadCoordinatorConfig(writeReloadConfig(t, startup), "", startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil, nil, nil)

	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		var event map[string]any
		if json.Unmarshal([]byte(line), &event) != nil || event["message"] != "autotune signed feed reloaded without restart" {
			continue
		}
		if event["event"] != "autotune_feed_sighup_reload" || event["autotune_catalog_version"] != "release-live" {
			t.Fatalf("reload event shape changed: %v", event)
		}
		if event["tier2_catalog_id"] != "test-catalog" || event["tier2_sha256"] != sha256Hex(tier2Raw) {
			t.Fatalf("reload event tier2 identity=%v/%v want test-catalog/%s", event["tier2_catalog_id"], event["tier2_sha256"], sha256Hex(tier2Raw))
		}
		return
	}
	t.Fatalf("no autotune_feed_sighup_reload success event; logs=%s", logs.String())
}
