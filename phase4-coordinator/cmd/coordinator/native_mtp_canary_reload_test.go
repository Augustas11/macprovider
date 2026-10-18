package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
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
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// writeValidatorNativeMTPSet writes a native-MTP admission set for releaseID
// into dir, signed like the release feeds (key "test-key").
func writeValidatorNativeMTPSet(t *testing.T, dir, releaseID string) {
	t.Helper()
	tokens := "[42,43]"
	bank := []byte(fmt.Sprintf(
		`{"schema_version":"macprovider.native-mtp-challenge-bank.v1","release_id":%q,"issued_at":"2026-10-01T00:00:00Z","expires_at":"2026-12-25T00:00:00Z","signer_key_id":"test-key","entries":[{"challenge_id":"challenge-a","model_id":"test-model","model_hash":%q,"tokenizer_sha256":%q,"artifact_sha256":%q,"mtp_manifest_sha256":%q,"prompt_token_ids":[10,11,12],"max_completion_tokens":16,"fixed_proposal_depth":2,"expected_token_ids":%s,"expected_token_id_sha256":%q,"expected_terminal_reason":"stop","expected_counters":{"accepted":2,"rejected":0,"bonus":0,"committed":2},"expected_committed_state_sha256":%q}]}`,
		releaseID, reloadTestHash, strings.Repeat("2", 64), strings.Repeat("3", 64), strings.Repeat("4", 64),
		tokens, sha256Hex([]byte(tokens)), strings.Repeat("6", 64),
	))
	manifest := []byte(`{"schema_version":"macprovider.native-mtp-artifact-manifest.v1"}`)
	admission := []byte(fmt.Sprintf(
		`{"schema_version":"macprovider.native-mtp-admission.v1","release_id":%q,"issued_at":"2026-10-01T00:00:00Z","expires_at":"2026-12-25T00:00:00Z","signer_key_id":"test-key","challenge_bank_signer_key_id":"test-key","revocation_signer_key_id":"test-key","entries":[{"artifact_manifest_sha256":%q,"challenge_bank_sha256":%q,"model_key":"test-model"}]}`,
		releaseID, sha256Hex(manifest), sha256Hex(bank),
	))
	writeValidatorSigned(t, filepath.Join(dir, "native-mtp-admission.json"), admission)
	writeValidatorSigned(t, filepath.Join(dir, "native-mtp-selftest-bank.json"), bank)
	if err := os.WriteFile(filepath.Join(dir, "native-mtp-artifact-manifest.json"), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "revocations"), 0o700); err != nil {
		t.Fatal(err)
	}
}

func nativeMTPCanaryReloadConfig(t *testing.T, liveRoot, releaseID string) config.Config {
	t.Helper()
	current := filepath.Join(liveRoot, "current")
	_, _, tier2Pub := writeValidatorRelease(t, current, releaseID, reloadTestHash)
	writeValidatorNativeMTPSet(t, current, releaseID)
	cfg := validatorConfig(liveRoot, tier2Pub)
	cfg.AutotuneFeeds.NativeMTPAdmissionPath = filepath.Join(current, "native-mtp-admission.json")
	cfg.AutotuneFeeds.NativeMTPAdmissionSigPath = filepath.Join(current, "native-mtp-admission.json.sig")
	cfg.AutotuneFeeds.NativeMTPArtifactManifestPath = filepath.Join(current, "native-mtp-artifact-manifest.json")
	cfg.AutotuneFeeds.NativeMTPSelftestBankPath = filepath.Join(current, "native-mtp-selftest-bank.json")
	cfg.AutotuneFeeds.NativeMTPSelftestBankSigPath = filepath.Join(current, "native-mtp-selftest-bank.json.sig")
	cfg.AutotuneFeeds.NativeMTPRevocationsDir = filepath.Join(current, "revocations")
	cfg.Pool.NativeMTPCanary = config.NativeMTPCanaryConfig{
		Enabled:           true,
		ChallengeBankPath: cfg.AutotuneFeeds.NativeMTPSelftestBankPath,
		SignaturePath:     cfg.AutotuneFeeds.NativeMTPSelftestBankSigPath,
		SignerKeyID:       "test-key",
		PublicKeys:        map[string]string{"test-key": base64.StdEncoding.EncodeToString(validatorKey().Public().(ed25519.PublicKey))},
		IntervalS:         900,
	}
	return cfg
}

func logEvents(t *testing.T, logs *bytes.Buffer, event string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		var entry map[string]any
		if json.Unmarshal([]byte(line), &entry) == nil && entry["event"] == event {
			out = append(out, entry)
		}
	}
	return out
}

// nativeMTPCanaryBootServers boots the WS/buyer pair the way main() does for
// the canary: the admission catalog and the canary banks come from the same
// verified feed snapshot (nativeMTPCanaryBootOption).
func nativeMTPCanaryBootServers(t *testing.T, cfg config.Config, logger zerolog.Logger) (config.Config, *providerws.Server, *buyer.Server) {
	t.Helper()
	feeds, catalog, compatible, err := loadAutotuneCatalogForReload(cfg.AutotuneFeeds)
	if err != nil {
		t.Fatalf("boot feeds: %v", err)
	}
	cfg.Auth.OperatorKey = "0123456789abcdefABCDEFghijklmnop"
	cfg.Auth.GatewayServiceToken = "fedcba9876543210FEDCBAzyxwvutsrq"
	cfg.Pool.WarmupGateEnabled = false
	registry := pool.NewRegistry(nil)
	wsServer := providerws.NewServer(cfg, registry, logger,
		providerws.WithAutotuneCatalog(catalog, compatible...),
		nativeMTPCanaryBootOption(cfg.AutotuneFeeds, feeds, zerolog.Nop()),
	)
	buyerServer := buyer.NewServer(registry, logger, time.Unix(1716768000, 0),
		buyer.WithTier2Config(cfg.Tier2),
		buyer.WithGatewayServiceToken(cfg.Auth.GatewayServiceToken),
	)
	buyerServer.SetAutotuneFeeds(feeds)
	if err := tier2.Configure(cfg.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("startup Configure: %v", err)
	}
	return cfg, wsServer, buyerServer
}

// retainRelease copies the live release directory to releases/<id> and lists
// it in .previous-target, the deployer's compatible-previous layout.
func retainRelease(t *testing.T, liveRoot, releaseID string) {
	t.Helper()
	dst := filepath.Join(liveRoot, "releases", releaseID)
	if err := os.CopyFS(dst, os.DirFS(filepath.Join(liveRoot, "current"))); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(liveRoot, ".previous-target"), []byte("releases/"+releaseID+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func healthzCanaryBank(t *testing.T, wsServer *providerws.Server) (string, string) {
	t.Helper()
	srv := httptest.NewServer(wsServer.Handler())
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body struct {
		ReleaseID string `json:"native_mtp_canary_bank_release_id"`
		SHA256    string `json:"native_mtp_canary_bank_sha256"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return body.ReleaseID, body.SHA256
}

// SPEC-031-R033: a SIGHUP release reload moves the native-MTP canary bank
// with the catalog; no coordinator restart is needed for the new bank. The
// replaced bank stays as the previous bank while its release is retained.
func TestSIGHUPReleaseReloadMovesTheNativeMTPCanaryBank(t *testing.T) {
	defer tier2.ResetForTest()
	liveRoot := t.TempDir()
	cfg := nativeMTPCanaryReloadConfig(t, liveRoot, "release-live")
	var wsLogs bytes.Buffer
	startup, wsServer, buyerServer := nativeMTPCanaryBootServers(t, cfg, zerolog.New(&wsLogs))
	if got, _ := healthzCanaryBank(t, wsServer); got != "release-live" {
		t.Fatalf("boot canary bank release=%q", got)
	}

	retainRelease(t, liveRoot, "release-live")
	current := filepath.Join(liveRoot, "current")
	writeValidatorRelease(t, current, "release-next", reloadTestHash)
	writeValidatorNativeMTPSet(t, current, "release-next")
	var logs bytes.Buffer
	reloadCoordinatorConfig(writeReloadConfig(t, startup), "", startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil, nil, nil)

	if got := wsServer.CurrentAutotuneCatalog(); got == nil || got.Version != "release-next" {
		t.Fatalf("live catalog=%v; reload logs=%s", got, logs.String())
	}
	events := logEvents(t, &wsLogs, "native_mtp_canary_bank_reloaded")
	if len(events) != 1 {
		t.Fatalf("canary bank reload events=%v", events)
	}
	if events[0]["challenge_bank_release_id"] != "release-next" || events[0]["previous_challenge_bank_release_id"] != "release-live" {
		t.Fatalf("canary bank reload event=%v", events[0])
	}
	bank, err := os.ReadFile(filepath.Join(current, "native-mtp-selftest-bank.json"))
	if err != nil {
		t.Fatal(err)
	}
	if release, sha := healthzCanaryBank(t, wsServer); release != "release-next" || sha != sha256Hex(bank) {
		t.Fatalf("healthz canary bank=%q/%q want release-next/%s", release, sha, sha256Hex(bank))
	}
}

// A release without native-MTP feeds retires the old current bank: with the
// old release not retained it is dropped, so it admits nothing.
func TestSIGHUPReleaseWithoutNativeMTPFeedsRetiresTheCanaryBank(t *testing.T) {
	defer tier2.ResetForTest()
	liveRoot := t.TempDir()
	cfg := nativeMTPCanaryReloadConfig(t, liveRoot, "release-live")
	var wsLogs bytes.Buffer
	startup, wsServer, buyerServer := nativeMTPCanaryBootServers(t, cfg, zerolog.New(&wsLogs))

	next := startup
	next.AutotuneFeeds.NativeMTPAdmissionPath = ""
	next.AutotuneFeeds.NativeMTPAdmissionSigPath = ""
	next.AutotuneFeeds.NativeMTPArtifactManifestPath = ""
	next.AutotuneFeeds.NativeMTPSelftestBankPath = ""
	next.AutotuneFeeds.NativeMTPSelftestBankSigPath = ""
	next.AutotuneFeeds.NativeMTPRevocationsDir = ""
	writeValidatorRelease(t, filepath.Join(liveRoot, "current"), "release-plain", reloadTestHash)
	var logs bytes.Buffer
	reloadCoordinatorConfig(writeReloadConfig(t, next), "", startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil, nil, nil)

	if got := wsServer.CurrentAutotuneCatalog(); got == nil || got.Version != "release-plain" {
		t.Fatalf("live catalog=%v; reload logs=%s", got, logs.String())
	}
	if release, sha := healthzCanaryBank(t, wsServer); release != "" || sha != "" {
		t.Fatalf("a release without native-MTP feeds left the old bank current: %q/%q", release, sha)
	}
	events := logEvents(t, &wsLogs, "native_mtp_canary_bank_reloaded")
	if len(events) != 1 || events[0]["retired_challenge_bank_release_id"] != "release-live" || events[0]["previous_challenge_bank_release_id"] != "" {
		t.Fatalf("canary bank retirement event=%v", events)
	}
}

// After a coordinator restart the canary rebuilds the retained
// compatible-previous release's bank from that release's verified feed set.
func TestCoordinatorRestartRebuildsTheRetainedPreviousCanaryBank(t *testing.T) {
	defer tier2.ResetForTest()
	liveRoot := t.TempDir()
	cfg := nativeMTPCanaryReloadConfig(t, liveRoot, "release-live")
	retainRelease(t, liveRoot, "release-live")
	current := filepath.Join(liveRoot, "current")
	writeValidatorRelease(t, current, "release-next", reloadTestHash)
	writeValidatorNativeMTPSet(t, current, "release-next")

	var wsLogs bytes.Buffer
	_, wsServer, _ := nativeMTPCanaryBootServers(t, cfg, zerolog.New(&wsLogs))
	if release, _ := healthzCanaryBank(t, wsServer); release != "release-next" {
		t.Fatalf("restart canary bank release=%q", release)
	}
	previous, err := os.ReadFile(filepath.Join(liveRoot, "releases", "release-live", "native-mtp-selftest-bank.json"))
	if err != nil {
		t.Fatal(err)
	}
	events := logEvents(t, &wsLogs, "native_mtp_canary_bank_loaded")
	if len(events) != 1 || events[0]["previous_challenge_bank_release_id"] != "release-live" ||
		events[0]["previous_challenge_bank_sha256"] != sha256Hex(previous) {
		t.Fatalf("restart did not rebuild the retained previous release's canary bank: %v", events)
	}
}

// A release whose bank the canary cannot verify never goes live: the reload
// keeps the prior catalog, served feeds and canary bank together.
func TestSIGHUPReleaseReloadRefusesABankTheCanaryCannotVerify(t *testing.T) {
	defer tier2.ResetForTest()
	liveRoot := t.TempDir()
	cfg := nativeMTPCanaryReloadConfig(t, liveRoot, "release-live")
	// The canary trusts a different key under the bank's key id.
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{12}, ed25519.SeedSize))
	cfg.Pool.NativeMTPCanary.PublicKeys = map[string]string{"test-key": base64.StdEncoding.EncodeToString(other.Public().(ed25519.PublicKey))}
	var wsLogs bytes.Buffer
	startup, _, wsServer, buyerServer := reloadTestServersWithLogger(cfg, zerolog.New(&wsLogs))
	if err := tier2.Configure(startup.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("startup Configure: %v", err)
	}
	before := wsServer.CurrentAutotuneCatalog()

	current := filepath.Join(liveRoot, "current")
	writeValidatorRelease(t, current, "release-next", reloadTestHash)
	writeValidatorNativeMTPSet(t, current, "release-next")
	var logs bytes.Buffer
	reloadCoordinatorConfig(writeReloadConfig(t, startup), "", startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil, nil, nil)

	if got := wsServer.CurrentAutotuneCatalog(); got != before {
		t.Fatalf("a release the canary refused went live: %v", got)
	}
	if !strings.Contains(logs.String(), "keeping prior catalog, served feeds and native MTP canary bank") {
		t.Fatalf("missing refusal log; logs=%s", logs.String())
	}
	if events := logEvents(t, &wsLogs, "native_mtp_canary_bank_reloaded"); len(events) != 0 {
		t.Fatalf("canary bank moved on a refused reload: %v", events)
	}
}

func TestValidateAutotuneReleaseRefusesABankTheCanaryCannotVerify(t *testing.T) {
	defer tier2.ResetForTest()
	liveRoot := t.TempDir()
	cfg := nativeMTPCanaryReloadConfig(t, liveRoot, "release-live")
	cfgPath := writeReloadConfig(t, cfg)
	if got := validateAutotuneRelease(cfgPath, "", filepath.Join(liveRoot, "current"), "", zerolog.Nop()); !got.OK {
		t.Fatalf("valid native-bound release refused: %v", got.Errors)
	}
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{12}, ed25519.SeedSize))
	cfg.Pool.NativeMTPCanary.PublicKeys = map[string]string{"test-key": base64.StdEncoding.EncodeToString(other.Public().(ed25519.PublicKey))}
	got := validateAutotuneRelease(writeReloadConfig(t, cfg), "", filepath.Join(liveRoot, "current"), "", zerolog.Nop())
	assertValidatorError(t, got, "native MTP canary bank")
}
