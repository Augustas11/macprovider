// Package integration is the cross-service integration harness for the
// gateway <-> coordinator boundary. It closes TEST-6 from the 2026-06-10
// repo audit by spinning up REAL coordinator and gateway binaries,
// generating temp config + SQLite DBs + service tokens, and exercising
// the boundary contracts that
// phase5-gateway/internal/router/integration_test.go currently mocks
// (Coordinator.BuyerURL = "http://coordinator.test" + httptest stubs).
//
// Design choices:
//
//   - Top-level test/integration/ module with NO source dependencies on
//     the coordinator or gateway modules. Both services are treated as
//     opaque binaries built via `go build` from TestMain. This is the
//     audit-cited shape (M2-9 / M3-11) and matches the "test the
//     boundary, not the contents" principle: billing math, sticky
//     selection, retry semantics are well covered by their own unit
//     tests inside each module.
//
//   - Fake provider runs IN-PROCESS as a Go goroutine. It WS-connects
//     to the coordinator's /ws/provider endpoint using gobwas/ws (the
//     same library the coordinator uses server-side, eliminating
//     protocol-library drift), sends a v1 hello frame announcing
//     `endpoint_url: http://127.0.0.1:<port>` (legacy mode, see
//     CoordinatorClient.swift:340 "endpoint_url legacy mode — no relay
//     needed"), heartbeats on the cadence the HelloAck specifies, and
//     serves a canned OpenAI-shaped chat completion via plain HTTP on
//     the endpoint_url port. This matches what the Swift binary does in
//     endpoint_url mode and exercises the full
//     gateway -> coordinator -> provider HTTP forwarding path.
//
//   - Pre-seeding the gateway DB happens via direct sqlite writes. The
//     gateway's API-key hashing is HMAC-SHA256(key_hash_secret, fullKey)
//     per phase5-gateway/internal/auth/keys.go:63-71; we re-implement
//     it here (~10 lines) rather than importing the gateway module.
//
//   - Each scenario gets its own temp dir + fresh ports + fresh
//     processes via t.Run subtests. There is no shared global state
//     between scenarios, so test order and -count=N reruns are
//     deterministic.
//
//   - All processes are torn down via context cancellation + Wait,
//     with a hard kill fallback after a per-test timeout. Stdout +
//     stderr stream to the test logger so a failure produces the full
//     coordinator/gateway log line that caused it.
package integration

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf16"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"golang.org/x/text/unicode/norm"
	"gopkg.in/yaml.v3"
	_ "modernc.org/sqlite"
)

// Built binary paths populated by TestMain. Each scenario shells out to
// these via os/exec. Treating them as opaque is what makes this a
// REAL cross-service test rather than within-process.
var (
	coordinatorBin    string
	coordinatorCLIBin string
	gatewayBin        string
	binBuildErr       error
)

const (
	snapshotManifestV1            = "macprovider.snapshot-manifest.v1"
	defaultFakeModelID            = "llama-3.2-3b-instruct"
	settlementFixtureModelID      = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	staticLlama32CandidateKey     = "meta-llama/llama-3.2-3b-instruct"
	staticLlama32CandidateRowID   = "c17e31e3bb1e1b64809e0157b32f91d03c1f6db716f03a2eee3fe589e8fbe9e2"
	staticAutotuneSignerKeyID     = "streamvc-autotune-static-v4"
	staticAutotunePublicKeyBase64 = "zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU="
)

func TestMain(m *testing.M) {
	tmpRoot, err := os.MkdirTemp("", "macprovider-integration-bins-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "tempdir: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmpRoot)

	repoRoot, err := findRepoRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "find repo root: %v\n", err)
		os.Exit(1)
	}

	coordinatorBin = filepath.Join(tmpRoot, "coordinator")
	coordinatorCLIBin = filepath.Join(tmpRoot, "coordinator-cli")
	gatewayBin = filepath.Join(tmpRoot, "gateway")

	binBuildErr = buildBinary(filepath.Join(repoRoot, "phase4-coordinator"), "./cmd/coordinator", coordinatorBin)
	if binBuildErr == nil {
		binBuildErr = buildBinary(filepath.Join(repoRoot, "phase4-coordinator"), "./cmd/coordinator-cli", coordinatorCLIBin)
	}
	if binBuildErr == nil {
		binBuildErr = buildBinary(filepath.Join(repoRoot, "phase5-gateway"), "./cmd/gateway", gatewayBin)
	}

	os.Exit(m.Run())
}

func buildBinary(modDir, pkg, outPath string) error {
	cmd := exec.Command("go", "build", "-o", outPath, pkg)
	cmd.Dir = modDir
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("build %s in %s failed: %v\n%s", pkg, modDir, err, string(out))
	}
	return nil
}

// findRepoRoot walks up from CWD looking for a marker file (go.work or
// a top-level Makefile + .github/workflows pair).
func findRepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "Makefile")); err == nil {
			if _, err := os.Stat(filepath.Join(dir, "phase4-coordinator")); err == nil {
				return dir, nil
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("could not locate repo root from %s", dir)
		}
		dir = parent
	}
}

// requireBins fails the test fast if TestMain couldn't build the
// binaries. We surface the error per-test rather than via TestMain
// so it shows up in -v output attached to the failing test.
func requireBins(t *testing.T) {
	t.Helper()
	if binBuildErr != nil {
		t.Fatalf("binary build failed in TestMain: %v", binBuildErr)
	}
}

// allocatePort returns an OS-allocated free port. Inevitably racy
// between Close + the child process reopening it, but in practice the
// window is microseconds and the coordinator/gateway listen() retries
// don't matter at our concurrency. If flakes appear, switch to
// fd-handoff via net.FileListener.
func allocatePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("allocate port: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// scenario wires up one coordinator + one gateway + one fake provider
// for a single subtest. All temp files live in t.TempDir() and are
// auto-cleaned. Returns the gateway base URL + API key + coordinator DB
// path so each scenario can drive HTTP requests and inspect billing
// rows.
type scenario struct {
	t                   *testing.T
	tempDir             string
	coordinatorDB       string
	gatewayDB           string
	coordYAML           string
	gatewayYAML         string
	operatorKey         string
	serviceToken        string
	keyHashSecret       string
	demoSecret          string
	apiKey              string // mp_... full API key (only seeded for chat scenarios)
	accountID           string
	gatewayBaseURL      string
	coordBuyerURL       string // http://127.0.0.1:<port>
	coordProvURL        string // http://127.0.0.1:<port> (provider/admin/ws port)
	providerID          string
	providerEndpointURL string // http://127.0.0.1:<port> — first fake provider HTTP
	providerToken       string // pre-issued via coordinator-cli for first provider
	providerSlots       []struct {
		ID  string
		URL string
	}
	fakeProvs              []*fakeProvider
	coordLogBuf            *logBuffer // populated when captureCoordLogs=true
	cancelAll              context.CancelFunc
	rootCtx                context.Context
	coordCancel            context.CancelFunc
	coordCmd               *exec.Cmd
	fakeProv               *fakeProvider
	procWG                 sync.WaitGroup
	modelHash              string
	rateCardPath           string
	rateCardSHA256         string
	rateCardVersion        string
	autotuneCatalogVersion string
	autotuneCatalogSHA256  string
	settlementCatalogID    string
	settlementCatalogKeyID string
}

type scenarioOpts struct {
	// gatewayServiceToken, when non-nil, overrides the gateway's
	// coordinator.service_token config field. nil = use
	// scenario.serviceToken. A pointer to the empty string is the only
	// way to express "configure the gateway with NO service token" so
	// upstream calls fall back to operator_key — required by the
	// security audit's gateway-fallback-end-to-end gap.
	gatewayServiceToken *string
	// coordinatorGatewayServiceToken, when non-nil, overrides the
	// coordinator's auth.gateway_service_token config field. nil = use
	// scenario.serviceToken. Pointer-to-empty-string supported for
	// future "coordinator without bridge configured" scenarios.
	coordinatorGatewayServiceToken *string
	// stickyEnabled toggles sticky on both sides. Required for the
	// sticky-header forwarding scenario.
	stickyEnabled bool
	// seedAccount, when true, pre-seeds the gateway DB with an account +
	// API key so the chat path can be exercised. Off for the WS-only
	// auth-rejection scenario where we hit /internal/routing directly.
	seedAccount bool
	// skipProvider, when true, skips spinning up the fake provider WS
	// connection (and the coordinator wait-for-ready) — used by the
	// auth-rejection scenario where no provider is needed.
	skipProvider bool
	// providerCount, when > 1, spawns N fake providers with the same
	// model so sticky routing has a candidate set bigger than 1. The
	// coordinator's applySticky returns the input unchanged when
	// len(candidates) < 2 (buyer/server.go:2530), so a single-provider
	// sticky test cannot prove the sticky-header contract holds — it
	// passes trivially. Defaults to 1.
	providerCount int
	// captureCoordLogs, when true, retains coordinator stdout for the
	// scenario to inspect. Used by log-class assertion scenarios that
	// pin `internal_bearer_accepted key=<service_token|operator_key>`.
	captureCoordLogs bool
	// receiptEnabledProvider, when true, makes the fake provider emit a
	// SPEC-015-shaped non-streaming receipt header so the gateway and
	// coordinator boundary can be tested without mocking either service.
	receiptEnabledProvider bool
	// settlementReceiptProvider, when true, makes the fake provider
	// advertise a catalog-verified model hash and emit signed SPEC-015
	// v0.4 settlement receipts on both non-streaming and streaming
	// requests.
	settlementReceiptProvider bool
	// settlementEnforceMode, when true, runs the coordinator with
	// settlement.verified_model_settlement_mode=enforce so gateway
	// money movement must be driven by coordinator finality rather than
	// legacy/provider-reported accounting.
	settlementEnforceMode bool
	// settlementReconcileIntervalSeconds overrides the gateway SPEC-022
	// background reconciler cadence. Zero keeps the gateway default.
	settlementReconcileIntervalSeconds int
}

type settlementCatalogFixture struct {
	path                   string
	publicKey              string
	modelHash              string
	rateCardPath           string
	rateCardSHA256         string
	rateCardVersion        string
	rateCardSigPath        string
	demandRankPath         string
	demandRankSigPath      string
	autotuneCatalogPath    string
	autotuneCatalogSigPath string
	autotuneCatalogSHA256  string
	autotuneCatalogVersion string
	autotunePolicyVersion  string
	catalogID              string
	catalogKeyID           string
}

func newScenario(t *testing.T, opts scenarioOpts) *scenario {
	t.Helper()
	requireBins(t)

	tempDir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	s := &scenario{
		t:             t,
		tempDir:       tempDir,
		coordinatorDB: filepath.Join(tempDir, "coordinator.db"),
		gatewayDB:     filepath.Join(tempDir, "gateway.db"),
		coordYAML:     filepath.Join(tempDir, "coordinator.yaml"),
		gatewayYAML:   filepath.Join(tempDir, "gateway.yaml"),
		operatorKey:   randHex(t, 32),
		serviceToken:  randHex(t, 32),
		keyHashSecret: randHex(t, 32),
		demoSecret:    randHex(t, 32),
		accountID:     "acct_" + randHex(t, 8),
		providerID:    "prov-" + randHex(t, 4),
		rootCtx:       ctx,
		cancelAll:     cancel,
	}
	t.Cleanup(s.shutdown)

	if opts.providerCount == 0 {
		opts.providerCount = 1
	}

	buyerPort := allocatePort(t)
	provPort := allocatePort(t)
	gwPort := allocatePort(t)

	// Allocate an endpoint port per fake provider, with a stable
	// providerID-per-index. The first provider keeps the scenario's
	// original ID for backward compatibility with single-provider
	// scenarios.
	type providerSlot struct {
		ID    string
		Port  int
		URL   string
		Token string
	}
	providerSlots := make([]providerSlot, opts.providerCount)
	for i := range providerSlots {
		port := allocatePort(t)
		id := s.providerID
		if i > 0 {
			id = fmt.Sprintf("%s-%d", s.providerID, i)
		}
		providerSlots[i] = providerSlot{
			ID:   id,
			Port: port,
			URL:  fmt.Sprintf("http://127.0.0.1:%d", port),
		}
	}
	s.providerEndpointURL = providerSlots[0].URL
	s.providerSlots = make([]struct {
		ID  string
		URL string
	}, len(providerSlots))
	for i, slot := range providerSlots {
		s.providerSlots[i].ID = slot.ID
		s.providerSlots[i].URL = slot.URL
	}

	s.coordBuyerURL = fmt.Sprintf("http://127.0.0.1:%d", buyerPort)
	s.coordProvURL = fmt.Sprintf("http://127.0.0.1:%d", provPort)
	s.gatewayBaseURL = fmt.Sprintf("http://127.0.0.1:%d", gwPort)

	coordServiceTok := s.serviceToken
	if opts.coordinatorGatewayServiceToken != nil {
		coordServiceTok = *opts.coordinatorGatewayServiceToken
	}
	providerCfgs := make([]map[string]any, len(providerSlots))
	for i, slot := range providerSlots {
		providerCfgs[i] = map[string]any{
			"provider_id":  slot.ID,
			"endpoint_url": slot.URL,
			"display_name": fmt.Sprintf("fake-integration-%d", i),
		}
	}
	var settlementCatalog settlementCatalogFixture
	if opts.settlementReceiptProvider {
		settlementCatalog = s.writeSettlementCatalogFixture()
		s.modelHash = settlementCatalog.modelHash
		s.rateCardSHA256 = settlementCatalog.rateCardSHA256
		s.rateCardVersion = settlementCatalog.rateCardVersion
		s.autotuneCatalogVersion = settlementCatalog.autotuneCatalogVersion
		s.autotuneCatalogSHA256 = settlementCatalog.autotuneCatalogSHA256
		s.settlementCatalogID = settlementCatalog.catalogID
		s.settlementCatalogKeyID = settlementCatalog.catalogKeyID
	}
	s.writeCoordinatorYAML(buyerPort, provPort, opts.stickyEnabled, coordServiceTok, providerCfgs, settlementCatalog, opts.settlementEnforceMode)

	gwServiceTok := s.serviceToken
	if opts.gatewayServiceToken != nil {
		gwServiceTok = *opts.gatewayServiceToken
	}
	s.writeGatewayYAML(gwPort, opts.stickyEnabled, gwServiceTok, opts.settlementReconcileIntervalSeconds)

	if opts.seedAccount {
		s.apiKey = s.seedGatewayAccountAndKey()
	}

	// Issue a token per pinned provider BEFORE coordinator starts.
	// coordinator-cli creates the DB + migrates the schema; the
	// coordinator binary then attaches to the same WAL DB. This is
	// necessary because pinned providers are admitted only when
	// auth.validated=true (ws/server.go:949), and validated=true comes
	// from ValidateAndMarkTokenUsed returning a non-empty providerID,
	// which requires an existing row. Provisional admission (no
	// providers: list) would bypass this but force ws-tunneled mode
	// — incompatible with our fake provider's HTTP-endpoint stub.
	providerTokens := make([]string, len(providerSlots))
	if !opts.skipProvider {
		for i, slot := range providerSlots {
			providerTokens[i] = s.issueProviderToken(slot.ID, fmt.Sprintf("fake-integration-%d", i))
		}
		s.providerToken = providerTokens[0]
	}

	// Coordinator first — gateway healthz exercises a route that
	// proxies to it on first hit, so order matters for fast startup.
	if opts.captureCoordLogs {
		s.coordLogBuf = newLogBuffer()
	}
	s.startCoordinator(ctx)
	s.waitForHealth(s.coordBuyerURL + "/healthz")
	s.waitForHealth(s.coordProvURL + "/healthz")

	if !opts.skipProvider {
		for i, slot := range providerSlots {
			fp := newFakeProvider(t, slot.ID, slot.Port, s.coordProvURL, providerTokens[i])
			if opts.receiptEnabledProvider {
				fp.enableReceipts()
			}
			if opts.settlementReceiptProvider {
				fp.enableSettlementReceipts(settlementCatalog)
			}
			fp.start(ctx)
			s.fakeProvs = append(s.fakeProvs, fp)
			s.waitForProviderReady(slot.ID)
		}
		// Back-compat: scenarios that look at s.fakeProv get the first.
		if len(s.fakeProvs) > 0 {
			s.fakeProv = s.fakeProvs[0]
		}
	}

	s.startGateway(ctx)
	s.waitForHealth(s.gatewayBaseURL + "/healthz")

	return s
}

func (s *scenario) shutdown() {
	if s.cancelAll != nil {
		s.cancelAll()
	}
	s.procWG.Wait()
}

// randHex returns a random hex string of length 2n (n random bytes).
func randHex(t *testing.T, n int) string {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return hex.EncodeToString(b)
}

// writeCoordinatorYAML drops the minimal config the coordinator needs
// to boot in test mode. require_provider_tokens=false so a fake
// provider can connect without operator-issued bearer (this matches
// the audit fixture: we want a clean room for testing the GATEWAY ↔
// COORDINATOR boundary, not the provider auth gate which has its own
// dedicated tests in phase4-coordinator/internal/ws).
func (s *scenario) writeCoordinatorYAML(buyerPort, provPort int, stickyEnabled bool, gatewayServiceToken string, providers []map[string]any, settlementCatalog settlementCatalogFixture, settlementEnforceMode bool) {
	s.t.Helper()
	tier2Cfg := map[string]any{
		"observe_enabled":                    false,
		"require_hash_verified":              false,
		"require_encrypted_leg":              false,
		"encrypted_leg_aead":                 "A256GCM",
		"encrypted_leg_rekey_after_requests": 10000,
		"encrypted_leg_rekey_after_seconds":  3600,
		"require_attestation":                false,
		"attestation_max_age_s":              600,
		"behavioral_safety_enabled":          false,
		"output_size_cap_bytes":              0,
		"output_bytes_per_token_ceiling":     16,
		"default_output_size_cap_bytes":      1048576,
		"encoding_validation_enabled":        false,
		"response_time_anomaly_enabled":      false,
		"response_time_anomaly_factor":       5.0,
		"response_time_anomaly_min_ms":       10000,
	}
	if settlementCatalog.path != "" {
		tier2Cfg["observe_enabled"] = true
		tier2Cfg["require_hash_verified"] = true
		tier2Cfg["catalog_path"] = settlementCatalog.path
		tier2Cfg["catalog_public_key"] = settlementCatalog.publicKey
	}
	cfg := map[string]any{
		"listen": map[string]any{
			"buyer_port":    buyerPort,
			"provider_port": provPort,
			"bind_address":  "127.0.0.1",
		},
		"pool": map[string]any{
			"heartbeat_interval_s":       1,
			"disconnect_grace_period_s":  30,
			"heartbeat_miss_threshold_s": 90,
			"wake_gap_threshold_s":       120,
			"warmup_fallback_s":          60,
			"warmup_gate_enabled":        false,
			"degraded_backoff_s":         30,
			"degraded_max_retries":       3,
			"degraded_probe_after_502":   true,
			"breaker_failure_threshold":  2,
			"breaker_window_s":           120,
		},
		"routing": map[string]any{
			"preflight_threshold_tokens":        4096,
			"preflight_timeout_s":               5,
			"request_timeout_s":                 60,
			"failover_enabled":                  true,
			"failover_timeout_s":                5,
			"retry_per_attempt_timeout_s":       60,
			"max_providers_faulted_per_request": 0,
			"sticky_enabled":                    stickyEnabled,
			"sticky_ttl_s":                      1800,
			"sticky_max_entries":                10000,
		},
		"provider_http": map[string]any{
			"timeout_s": 30,
		},
		"limits": map[string]any{
			"max_chat_request_body_bytes": 1048576,
		},
		"ws": map[string]any{
			"write_buffer_size":               64,
			"handshake_timeout_s":             10,
			"write_timeout_s":                 10,
			"max_frame_bytes":                 4 << 20,
			"max_unauthenticated_conn":        64,
			"max_unauthenticated_conn_per_ip": 16,
		},
		"admission": map[string]any{
			"pinned_only":                         false,
			"provisional_admission_rate_per_hour": 1000,
			"provisional_pool_max":                100,
			"provisional_quota_per_hour":          1000,
			"provisional_tier_weight":             0.3,
			"provisional_retention_days":          30,
		},
		"tier2": tier2Cfg,
		"auth": map[string]any{
			"operator_key":            s.operatorKey,
			"gateway_service_token":   gatewayServiceToken,
			"require_provider_tokens": false,
		},
		"storage": map[string]any{
			"db_path":                    s.coordinatorDB,
			"snapshot_interval_s":        300,
			"request_log_retention_days": 90,
			"audit_log_retention_days":   90,
		},
		"logging": map[string]any{
			"level":  "info",
			"format": "json",
		},
		"rewards": map[string]any{
			"global_multiplier": 1.0,
			"provider_share":    0.9,
			"rate_card": map[string]any{
				"default": map[string]any{
					"prompt_credits_per_mtok":     500000,
					"completion_credits_per_mtok": 1000000,
				},
			},
		},
		"settlement": map[string]any{
			"cadence_days":                   7,
			"min_payout_credits":             0,
			"startup_reconcile_window_hours": 24,
			"nightly_reconcile_window_days":  7,
			"recovery_grace_seconds":         30,
			"verified_model_settlement_mode": verifiedModelSettlementMode(settlementEnforceMode),
			"job_enabled":                    false,
		},
		"endpoints": map[string]any{
			"provider_earnings": map[string]any{
				"rate_limit_per_minute": 60,
			},
		},
		"explorer": map[string]any{
			"enabled": false,
		},
		// Pin each fake provider in coordinator config so they admit in
		// HTTP-forwarding (endpoint_url) mode rather than ws-tunneled
		// mode. Provisional providers always force ws-tunneled
		// (ws/server.go:986-988) — and our fake doesn't implement the
		// wsForward inference protocol, only the legacy HTTP path.
		// Pinning is correct anyway: any operator using endpoint_url in
		// production has the provider in their providers: list.
		"providers": providers,
	}
	if settlementCatalog.autotuneCatalogPath != "" {
		cfg["autotune"] = map[string]any{
			"rate_card_path":               settlementCatalog.rateCardPath,
			"rate_card_sig_path":           settlementCatalog.rateCardSigPath,
			"demand_rank_path":             settlementCatalog.demandRankPath,
			"demand_rank_sig_path":         settlementCatalog.demandRankSigPath,
			"autotune_candidates_path":     settlementCatalog.autotuneCatalogPath,
			"autotune_candidates_sig_path": settlementCatalog.autotuneCatalogSigPath,
			"enforce_provider_admission":   true,
			"public_keys": map[string]string{
				staticAutotuneSignerKeyID: staticAutotunePublicKeyBase64,
			},
		}
	}
	b, err := yaml.Marshal(cfg)
	if err != nil {
		s.t.Fatalf("marshal coordinator yaml: %v", err)
	}
	if err := os.WriteFile(s.coordYAML, b, 0o600); err != nil {
		s.t.Fatalf("write coordinator yaml: %v", err)
	}
}

func verifiedModelSettlementMode(enforce bool) string {
	if enforce {
		return "enforce"
	}
	return "observe"
}

func (s *scenario) writeSettlementCatalogFixture() settlementCatalogFixture {
	s.t.Helper()
	repoRoot, err := findRepoRoot()
	if err != nil {
		s.t.Fatalf("find repo root for autotune fixture: %v", err)
	}
	autotuneCatalogPath := filepath.Join(repoRoot, "phase3-binary", "dist", "static", "autotune-candidates.json")
	autotuneCatalogSigPath := autotuneCatalogPath + ".sig"
	rateCardPath := filepath.Join(repoRoot, "phase3-binary", "dist", "static", "rate-card.json")
	rateCardSigPath := rateCardPath + ".sig"
	rateCardJSON, err := os.ReadFile(rateCardPath)
	if err != nil {
		s.t.Fatalf("read rate-card fixture: %v", err)
	}
	var rateCardMeta struct {
		Version string `json:"version"`
	}
	if err := json.Unmarshal(rateCardJSON, &rateCardMeta); err != nil {
		s.t.Fatalf("parse rate-card fixture: %v", err)
	}
	if rateCardMeta.Version == "" {
		s.t.Fatal("rate-card fixture missing version")
	}
	rateCardDigest := sha256.Sum256(rateCardJSON)
	demandRankPath := filepath.Join(repoRoot, "phase3-binary", "dist", "static", "demand-rank.json")
	demandRankSigPath := demandRankPath + ".sig"
	autotuneCatalogJSON, err := os.ReadFile(autotuneCatalogPath)
	if err != nil {
		s.t.Fatalf("read signed autotune fixture: %v", err)
	}
	for label, path := range map[string]string{
		"rate-card fixture":     rateCardPath,
		"rate-card signature":   rateCardSigPath,
		"demand-rank fixture":   demandRankPath,
		"demand-rank signature": demandRankSigPath,
		"autotune signature":    autotuneCatalogSigPath,
	} {
		if _, err := os.Stat(path); err != nil {
			s.t.Fatalf("read %s: %v", label, err)
		}
	}
	var autotuneCatalog struct {
		Version       string `json:"version"`
		PolicyVersion string `json:"policy_version"`
		Rows          map[string]struct {
			ModelSHA256 string `json:"model_sha256"`
		} `json:"rows"`
	}
	if err := json.Unmarshal(autotuneCatalogJSON, &autotuneCatalog); err != nil {
		s.t.Fatalf("parse signed autotune fixture: %v", err)
	}
	modelHash := autotuneCatalog.Rows[staticLlama32CandidateKey].ModelSHA256
	if len(modelHash) != sha256.Size*2 {
		s.t.Fatalf("signed autotune fixture model hash is invalid: %q", modelHash)
	}
	autotuneCatalogDigest := sha256.Sum256(autotuneCatalogJSON)

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		s.t.Fatalf("generate catalog key: %v", err)
	}

	minRAM := 16
	models := []settlementCatalogModel{{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "primary_weight_file",
		ModelID:      settlementFixtureModelID,
		MinRAMGB:     &minRAM,
		SHA256:       modelHash,
		Source:       "integration-test",
	}}
	issuedAt := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
	expiresAt := time.Now().UTC().Add(24 * time.Hour).Truncate(time.Second)
	body := settlementCatalogBody{
		CatalogID: "integration-catalog",
		ExpiresAt: expiresAt.Format(time.RFC3339),
		IssuedAt:  issuedAt.Format(time.RFC3339),
		Models:    models,
		Version:   1,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		s.t.Fatalf("marshal catalog body: %v", err)
	}
	sig := ed25519.Sign(priv, canonical)
	file := settlementCatalogFile{
		CatalogID: body.CatalogID,
		ExpiresAt: body.ExpiresAt,
		IssuedAt:  body.IssuedAt,
		Models:    body.Models,
		Signature: settlementCatalogSignature{
			Alg:   "Ed25519",
			KeyID: "integration-catalog-key",
			Sig:   base64.RawURLEncoding.EncodeToString(sig),
		},
		Version: body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		s.t.Fatalf("marshal catalog file: %v", err)
	}
	path := filepath.Join(s.tempDir, "settlement-catalog.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		s.t.Fatalf("write settlement catalog: %v", err)
	}
	return settlementCatalogFixture{
		path:                   path,
		publicKey:              base64.RawURLEncoding.EncodeToString(pub),
		modelHash:              modelHash,
		rateCardPath:           rateCardPath,
		rateCardSHA256:         hex.EncodeToString(rateCardDigest[:]),
		rateCardVersion:        rateCardMeta.Version,
		rateCardSigPath:        rateCardSigPath,
		demandRankPath:         demandRankPath,
		demandRankSigPath:      demandRankSigPath,
		autotuneCatalogPath:    autotuneCatalogPath,
		autotuneCatalogSigPath: autotuneCatalogSigPath,
		autotuneCatalogSHA256:  hex.EncodeToString(autotuneCatalogDigest[:]),
		autotuneCatalogVersion: autotuneCatalog.Version,
		autotunePolicyVersion:  autotuneCatalog.PolicyVersion,
		catalogID:              body.CatalogID,
		catalogKeyID:           file.Signature.KeyID,
	}
}

type settlementCatalogModel struct {
	ArtifactKind string `json:"artifact_kind"`
	HashScope    string `json:"hash_scope"`
	ModelID      string `json:"model_id"`
	MinRAMGB     *int   `json:"min_ram_gb,omitempty"`
	Notes        string `json:"notes,omitempty"`
	SHA256       string `json:"sha256"`
	Source       string `json:"source"`
}

type settlementCatalogSignature struct {
	Alg   string `json:"alg"`
	KeyID string `json:"key_id"`
	Sig   string `json:"sig"`
}

type settlementCatalogBody struct {
	CatalogID string                   `json:"catalog_id"`
	ExpiresAt string                   `json:"expires_at"`
	IssuedAt  string                   `json:"issued_at"`
	Models    []settlementCatalogModel `json:"models"`
	Version   int                      `json:"version"`
}

type settlementCatalogFile struct {
	CatalogID string                     `json:"catalog_id"`
	ExpiresAt string                     `json:"expires_at"`
	IssuedAt  string                     `json:"issued_at"`
	Models    []settlementCatalogModel   `json:"models"`
	Signature settlementCatalogSignature `json:"signature"`
	Version   int                        `json:"version"`
}

func (s *scenario) writeGatewayYAML(gwPort int, stickyEnabled bool, serviceToken string, settlementReconcileIntervalSeconds int) {
	s.t.Helper()
	cfg := map[string]any{
		"listen": map[string]any{
			"bind_address": "127.0.0.1",
			"port":         gwPort,
		},
		"proxy": map[string]any{
			"trusted_cidrs": []string{"127.0.0.0/8", "::1/128"},
		},
		"public": map[string]any{
			"base_url":     fmt.Sprintf("http://127.0.0.1:%d", gwPort),
			"account_path": "/account",
		},
		"coordinator": map[string]any{
			"buyer_url":             s.coordBuyerURL,
			"operator_url":          s.coordProvURL,
			"operator_key":          s.operatorKey,
			"service_token":         serviceToken,
			"poolz_poll_interval_s": 60,
		},
		"storage": map[string]any{
			"driver":  "sqlite",
			"db_path": s.gatewayDB,
		},
		"auth": map[string]any{
			"key_prefix":               "mp_",
			"key_hash":                 "hmac_sha256",
			"key_hash_secret":          s.keyHashSecret,
			"github_oauth_enabled":     false,
			"email_magic_link_enabled": false,
			"oauth": map[string]any{
				"state_max_per_ip": 20,
				"callback_allowlist": []string{
					fmt.Sprintf("http://127.0.0.1:%d/auth/github/callback", gwPort),
				},
			},
			"demo": map[string]any{
				"signing_secret": s.demoSecret,
			},
		},
		"quotas": map[string]any{
			"account_daily_tokens":           1000000,
			"demo_daily_tokens_per_ip":       10000,
			"demo_sessions_per_ip_per_hour":  10,
			"account_concurrency":            4,
			"demo_concurrency":               4,
			"signup_accounts_per_ip_per_day": 3,
			"reaper_interval_hours":          24,
			"reservation_max_age_hours":      24,
		},
		"limits": map[string]any{
			"max_tokens_per_request":            4096,
			"demo_max_tokens_per_request":       512,
			"max_feedback_comment_bytes":        2000,
			"max_feedback_body_bytes":           16384,
			"feedback_requests_per_ip_per_hour": 10,
			"request_body_bytes":                1048576,
		},
		"capacity": map[string]any{
			"monthly_budget_usd":                500,
			"ready_provider_degraded_threshold": 1,
			"projected_cost_tier1_percent":      80,
			"tier_cooldown_seconds":             3600,
		},
		"timeouts": map[string]any{
			// Post-#760/#784 C2b: response-header transport must cover
			// max(coordinator_admission_seconds, effective non_stream_request_seconds).
			// The fixture keeps a short request wall but uses the runtime
			// admission default (120s), so the header budget must be at least 120s.
			"coordinator_request_seconds":        60,
			"coordinator_header_timeout_seconds": 120,
			"streaming_cancel_ms":                500,
		},
		"cors": map[string]any{
			"allowed_origins": []string{fmt.Sprintf("http://127.0.0.1:%d", gwPort)},
		},
		"routing": map[string]any{
			"sticky_enabled": stickyEnabled,
			"sticky_ttl_s":   1800,
		},
		"explorer": map[string]any{
			"enabled": false,
		},
	}
	if settlementReconcileIntervalSeconds > 0 {
		cfg["settlement"] = map[string]any{
			"reconcile_enabled":           true,
			"reconcile_interval_s":        settlementReconcileIntervalSeconds,
			"reconcile_batch_limit":       100,
			"reconcile_request_timeout_s": 5,
		}
	}
	b, err := yaml.Marshal(cfg)
	if err != nil {
		s.t.Fatalf("marshal gateway yaml: %v", err)
	}
	if err := os.WriteFile(s.gatewayYAML, b, 0o600); err != nil {
		s.t.Fatalf("write gateway yaml: %v", err)
	}
}

// seedGatewayAccountAndKey writes an active account and one API key
// directly into the gateway SQLite DB. The key hash uses
// HMAC-SHA256(key_hash_secret, fullKey) as in
// phase5-gateway/internal/auth/keys.go:64-67. Returns the full key
// the buyer should send as Authorization: Bearer.
//
// We pre-boot the gateway briefly so it runs its own schema migrations,
// then close the connection and let the real gateway take over. This is
// simpler than re-implementing the schema in this test file (which
// would drift the first time someone adds a column).
func (s *scenario) seedGatewayAccountAndKey() string {
	s.t.Helper()
	// Boot the gateway once to run migrations, then stop it. This
	// uses the same binary path; we run it for ~1s, kill, then proceed.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, gatewayBin, "-config", s.gatewayYAML)
	var seedLogs bytes.Buffer
	cmd.Stderr = &seedLogs
	cmd.Stdout = io.Discard
	if err := cmd.Start(); err != nil {
		s.t.Fatalf("seed gateway start: %v", err)
	}
	// Poll until the schema is present, then kill.
	deadline := time.Now().Add(4 * time.Second)
	schemaReady := false
	for time.Now().Before(deadline) {
		db, err := sql.Open("sqlite", s.gatewayDB)
		if err == nil {
			var ok int
			err = db.QueryRow(`SELECT 1 FROM sqlite_master WHERE type='table' AND name='accounts'`).Scan(&ok)
			db.Close()
			if err == nil {
				schemaReady = true
				break
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = cmd.Process.Kill()
	_ = cmd.Wait()
	if !schemaReady {
		s.t.Fatalf("seed gateway did not create accounts schema: %s", seedLogs.String())
	}

	db, err := sql.Open("sqlite", s.gatewayDB)
	if err != nil {
		s.t.Fatalf("open gateway db for seed: %v", err)
	}
	defer db.Close()
	now := time.Now().UTC().Format(time.RFC3339Nano)

	if _, err := db.Exec(
		`INSERT INTO accounts(account_id, status, quota_class, concurrency_class, created_at) VALUES(?, 'active', 'default', 'default', ?)`,
		s.accountID, now,
	); err != nil {
		s.t.Fatalf("seed account: %v", err)
	}

	rawKey := make([]byte, 32)
	if _, err := rand.Read(rawKey); err != nil {
		s.t.Fatalf("rand: %v", err)
	}
	fullKey := "mp_" + base64.RawURLEncoding.EncodeToString(rawKey)
	mac := hmac.New(sha256.New, []byte(s.keyHashSecret))
	_, _ = mac.Write([]byte(fullKey))
	hash := mac.Sum(nil)
	prefix := fullKey
	if len(fullKey) > 12 {
		prefix = fullKey[:12]
	}
	keyID := "key_" + randHex(s.t, 16)
	if _, err := db.Exec(
		`INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at) VALUES(?, ?, ?, ?, 'active', ?)`,
		keyID, s.accountID, hash, prefix, now,
	); err != nil {
		s.t.Fatalf("seed api_key: %v", err)
	}
	return fullKey
}

// issueProviderToken shells out to coordinator-cli to mint a token row
// for `providerID` in the coordinator DB. The CLI uses OpenStore which
// auto-creates and migrates the DB, so this runs cleanly before the
// coordinator binary starts. The token is printed on stdout as
// "token=<hex>"; we parse that line.
func (s *scenario) issueProviderToken(providerID, providerName string) string {
	s.t.Helper()
	cmd := exec.Command(coordinatorCLIBin, "issue-token",
		"-db", s.coordinatorDB,
		"-provider-id", providerID,
		"-provider-name", providerName,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		s.t.Fatalf("issue-token: %v\n%s", err, string(out))
	}
	for _, line := range strings.Split(string(out), "\n") {
		if rest, ok := strings.CutPrefix(line, "token="); ok {
			return strings.TrimSpace(rest)
		}
	}
	s.t.Fatalf("issue-token: no token= line in output: %s", string(out))
	return ""
}

func (s *scenario) startCoordinator(ctx context.Context) {
	s.t.Helper()
	if s.coordCancel != nil {
		s.coordCancel()
	}
	coordCtx, cancel := context.WithCancel(ctx)
	s.coordCancel = cancel
	cmd := exec.CommandContext(coordCtx, coordinatorBin, "-config", s.coordYAML)
	cmd.Env = os.Environ()
	s.streamLogs(cmd, "coord")
	if err := cmd.Start(); err != nil {
		s.t.Fatalf("start coordinator: %v", err)
	}
	s.coordCmd = cmd
	s.procWG.Add(1)
	go func() {
		defer s.procWG.Done()
		_ = cmd.Wait()
	}()
}

func (s *scenario) stopCoordinator() {
	s.t.Helper()
	if s.coordCancel != nil {
		s.coordCancel()
	}
	if s.coordCmd != nil && s.coordCmd.Process != nil {
		_ = s.coordCmd.Process.Kill()
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(s.coordBuyerURL + "/healthz")
		if err != nil {
			s.coordCmd = nil
			return
		}
		resp.Body.Close()
		time.Sleep(50 * time.Millisecond)
	}
	s.t.Fatal("coordinator healthz still reachable after stop")
}

func (s *scenario) restartCoordinator() {
	s.t.Helper()
	s.stopCoordinator()
	time.Sleep(200 * time.Millisecond)
	s.startCoordinator(s.rootCtx)
	s.waitForHealth(s.coordBuyerURL + "/healthz")
	s.waitForHealth(s.coordProvURL + "/healthz")
}

func (s *scenario) startGateway(ctx context.Context) {
	s.t.Helper()
	cmd := exec.CommandContext(ctx, gatewayBin, "-config", s.gatewayYAML)
	cmd.Env = os.Environ()
	s.streamLogs(cmd, "gateway")
	if err := cmd.Start(); err != nil {
		s.t.Fatalf("start gateway: %v", err)
	}
	s.procWG.Add(1)
	go func() {
		defer s.procWG.Done()
		_ = cmd.Wait()
	}()
}

func (s *scenario) streamLogs(cmd *exec.Cmd, tag string) {
	s.t.Helper()
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		s.t.Fatalf("stdout pipe: %v", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		s.t.Fatalf("stderr pipe: %v", err)
	}
	var captureOut *logBuffer
	if tag == "coord" {
		captureOut = s.coordLogBuf // nil when captureCoordLogs=false
	}
	go pumpLogs(s.t, tag+".out", stdout, captureOut)
	go pumpLogs(s.t, tag+".err", stderr, nil)
}

func pumpLogs(t *testing.T, tag string, r io.ReadCloser, capture *logBuffer) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		t.Logf("[%s] %s", tag, line)
		if capture != nil {
			capture.append(line)
		}
	}
}

// logBuffer is a goroutine-safe append-only line buffer used by
// scenarios that need to assert against subprocess log output (e.g.,
// `internal_bearer_accepted key=<service_token|operator_key>` for the
// M3-2 cutover audit-trail contract).
type logBuffer struct {
	mu    sync.Mutex
	lines []string
}

func newLogBuffer() *logBuffer { return &logBuffer{} }

func (b *logBuffer) append(line string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.lines = append(b.lines, line)
}

// snapshot returns a copy of all captured lines so far. Callers can
// scan this for substring matches without holding the buffer mutex.
func (b *logBuffer) snapshot() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]string, len(b.lines))
	copy(out, b.lines)
	return out
}

// awaitContains polls the buffer until ANY line contains all the
// given substrings, or the deadline expires. Returns the matching
// line on success, "" on timeout. Used to pin
// `event=internal_bearer_accepted key=<kind>` audit log lines that the
// coordinator writes asynchronously relative to the test's HTTP
// response.
func (b *logBuffer) awaitContains(deadline time.Time, substrs ...string) string {
	for time.Now().Before(deadline) {
		for _, line := range b.snapshot() {
			matched := true
			for _, s := range substrs {
				if !strings.Contains(line, s) {
					matched = false
					break
				}
			}
			if matched {
				return line
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	return ""
}

// waitForHealth polls until the /healthz endpoint returns 200, or
// times out after 10s. Determinism contract: the test reads the SAME
// healthz both services already expose for nginx/load-balancer probes,
// so this exercises real wire shape.
func (s *scenario) waitForHealth(url string) {
	s.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return
			}
			lastErr = fmt.Errorf("status %d", resp.StatusCode)
		} else {
			lastErr = err
		}
		time.Sleep(50 * time.Millisecond)
	}
	s.t.Fatalf("healthz %s never ready: %v", url, lastErr)
}

// waitForProviderReady polls the coordinator's /poolz endpoint until
// the named provider appears in a routable state. /poolz needs operator
// auth; we send the operator key.
func (s *scenario) waitForProviderReady(providerID string) {
	s.t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest(http.MethodGet, s.coordProvURL+"/poolz", nil)
		req.Header.Set("Authorization", "Bearer "+s.operatorKey)
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK && strings.Contains(string(body), providerID) {
				// Also need provider in ready state — the response
				// includes `"state":"ready"` once heartbeat lands.
				if strings.Contains(string(body), `"state":"ready"`) {
					return
				}
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	s.t.Fatalf("provider %s never reached ready state in /poolz", providerID)
}

// chatRequest sends a chat completion to the gateway with the given
// Bearer + extra headers. Returns status, headers, body.
func (s *scenario) chatRequest(headers map[string]string, body string) (int, http.Header, []byte) {
	s.t.Helper()
	req, err := http.NewRequest(http.MethodPost, s.gatewayBaseURL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		s.t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+s.apiKey)
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		s.t.Fatalf("chat: %v", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, respBody
}

// fakeProvider runs an in-process Go WS client that connects to the
// coordinator's /ws/provider endpoint, sends a v1 hello announcing
// endpoint_url=http://127.0.0.1:<port>, heartbeats every second, and
// serves OpenAI-shaped chat completions on the endpoint port.
// Cancellation tears both halves down.
type fakeProvider struct {
	t                 *testing.T
	providerID        string
	providerToken     string
	httpPort          int
	wsURL             string
	hServer           *http.Server
	receiptEnabled    bool
	settlementEnabled bool
	modelID           string
	modelHash         string
	catalogReleaseID  string
	catalogPolicy     string
	catalogSHA256     string
	receiptPubkey     ed25519.PublicKey
	receiptPrivkey    ed25519.PrivateKey
	lastRequestBody   []byte
	lastResponseBody  []byte
	hReady            chan struct{}
	stopOnce          sync.Once
	stopped           chan struct{}
	hitMu             sync.Mutex
	hits              int // /v1/chat/completions hit count, for sticky verification
}

// Hits returns the number of /v1/chat/completions requests this fake
// provider has served. Sticky-routing scenarios assert that after a
// first request, follow-up requests land on the same provider.
func (p *fakeProvider) Hits() int {
	p.hitMu.Lock()
	defer p.hitMu.Unlock()
	return p.hits
}

func (p *fakeProvider) LastReceiptBodies() ([]byte, []byte) {
	p.hitMu.Lock()
	defer p.hitMu.Unlock()
	return append([]byte(nil), p.lastRequestBody...), append([]byte(nil), p.lastResponseBody...)
}

func newFakeProvider(t *testing.T, providerID string, httpPort int, coordProvURL, providerToken string) *fakeProvider {
	t.Helper()
	u, err := url.Parse(coordProvURL)
	if err != nil {
		t.Fatalf("parse coord url: %v", err)
	}
	wsScheme := "ws"
	if u.Scheme == "https" {
		wsScheme = "wss"
	}
	return &fakeProvider{
		t:             t,
		providerID:    providerID,
		providerToken: providerToken,
		httpPort:      httpPort,
		wsURL:         fmt.Sprintf("%s://%s/ws/provider", wsScheme, u.Host),
		modelID:       defaultFakeModelID,
		hReady:        make(chan struct{}),
		stopped:       make(chan struct{}),
	}
}

func (p *fakeProvider) enableReceipts() {
	p.t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		p.t.Fatalf("generate fake receipt key: %v", err)
	}
	p.receiptEnabled = true
	p.receiptPubkey = pub
	p.receiptPrivkey = priv
}

func (p *fakeProvider) enableSettlementReceipts(catalog settlementCatalogFixture) {
	p.t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		p.t.Fatalf("generate fake settlement receipt key: %v", err)
	}
	p.settlementEnabled = true
	p.modelID = settlementFixtureModelID
	p.modelHash = catalog.modelHash
	p.catalogReleaseID = catalog.autotuneCatalogVersion
	p.catalogPolicy = catalog.autotunePolicyVersion
	p.catalogSHA256 = catalog.autotuneCatalogSHA256
	p.receiptPubkey = pub
	p.receiptPrivkey = priv
}

const fakeCompletionBody = `{
  "id":"chatcmpl-fake-integration",
  "object":"chat.completion",
  "created":1780000000,
  "model":"llama-3.2-3b-instruct",
  "usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20},
  "choices":[{"index":0,"message":{"role":"assistant","content":"hello from fake provider"},"finish_reason":"stop"}]
}`

func (p *fakeProvider) buildReceiptHeader(requestBody, responseBody []byte) (string, error) {
	promptHash, err := spec015CanonicalPromptHash(requestBody)
	if err != nil {
		return "", fmt.Errorf("canonical prompt hash: %w", err)
	}
	outputHash, err := spec015CanonicalOutputHash(responseBody)
	if err != nil {
		return "", fmt.Errorf("canonical output hash: %w", err)
	}
	tuple := fmt.Sprintf(
		`{"model_id":"llama-3.2-3b-instruct","output_hash":"%s","prompt_hash":"%s","provider_pubkey":"%s","tokens_out":12,"ttft_ms":0,"unix_ts":%d}`,
		outputHash,
		promptHash,
		base64.StdEncoding.EncodeToString(p.receiptPubkey),
		time.Now().Unix(),
	)
	signature := ed25519.Sign(p.receiptPrivkey, []byte(tuple))
	return base64.StdEncoding.EncodeToString([]byte(tuple)) + "." + base64.StdEncoding.EncodeToString(signature), nil
}

type settlementMetadata struct {
	AccountScope               string `json:"account_scope"`
	RequestID                  string `json:"request_id"`
	AttemptN                   int64  `json:"attempt_n"`
	ProviderID                 string `json:"provider_id"`
	ProviderReceiptKeyID       string `json:"provider_receipt_key_id"`
	ModelID                    string `json:"model_id"`
	ExpectedCatalogModelHash   string `json:"expected_catalog_model_hash"`
	CatalogID                  string `json:"catalog_id"`
	CatalogBodyDigest          string `json:"catalog_body_digest"`
	RouteSnapshotDigest        string `json:"route_snapshot_digest"`
	RouteSnapshotPolicyVersion string `json:"route_snapshot_policy_version"`
	RouteSnapshotMode          string `json:"route_snapshot_mode"`
	PromptHash                 string `json:"prompt_hash"`
	OutputPrefixStartByte      int64  `json:"output_prefix_start_byte"`
	PendingDeadlineSeconds     int64  `json:"pending_deadline_seconds"`
}

func decodeSettlementMetadataHeader(header string) (settlementMetadata, bool, error) {
	header = strings.TrimSpace(header)
	if header == "" {
		return settlementMetadata{}, false, nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(header)
	if err != nil {
		return settlementMetadata{}, false, fmt.Errorf("decode settlement metadata: %w", err)
	}
	var metadata settlementMetadata
	if err := json.Unmarshal(raw, &metadata); err != nil {
		return settlementMetadata{}, false, fmt.Errorf("decode settlement metadata json: %w", err)
	}
	return metadata, true, nil
}

func (p *fakeProvider) buildSettlementReceiptHeader(metadata settlementMetadata, content, finishReason string, promptTokens, completionTokens, terminalTSUnixMS int64) (string, error) {
	normalizedContent := norm.NFC.String(normalizeSpec015LineEndings(content))
	deliveredBytes := int64(len([]byte(normalizedContent)))
	outputPrefixEnd := metadata.OutputPrefixStartByte + deliveredBytes
	output := map[string]any{
		"content":                  normalizedContent,
		"finish_reason":            finishReason,
		"output_prefix_end_byte":   outputPrefixEnd,
		"output_prefix_start_byte": metadata.OutputPrefixStartByte,
		"terminal_state":           "normal_done",
		"tool_calls":               nil,
	}
	outputHash, _, err := spec015CanonicalSHA256Hex(output)
	if err != nil {
		return "", fmt.Errorf("canonical output hash: %w", err)
	}
	usage := map[string]any{
		"billable_input_tokens":  promptTokens,
		"billable_output_tokens": completionTokens,
		"delivered_output_bytes": deliveredBytes,
		"observed_input_tokens":  promptTokens,
		"observed_output_tokens": completionTokens,
	}
	tuple := map[string]any{
		"account_scope":                 metadata.AccountScope,
		"attempt_n":                     metadata.AttemptN,
		"catalog_body_digest":           metadata.CatalogBodyDigest,
		"catalog_id":                    metadata.CatalogID,
		"expected_catalog_model_hash":   metadata.ExpectedCatalogModelHash,
		"issued_at_unix_ms":             terminalTSUnixMS,
		"model_hash":                    p.modelHash,
		"model_id":                      metadata.ModelID,
		"output_hash":                   outputHash,
		"output_prefix_end_byte":        outputPrefixEnd,
		"output_prefix_start_byte":      metadata.OutputPrefixStartByte,
		"prompt_hash":                   metadata.PromptHash,
		"provider_id":                   metadata.ProviderID,
		"provider_receipt_key_id":       metadata.ProviderReceiptKeyID,
		"receipt_version":               "4",
		"request_id":                    metadata.RequestID,
		"route_snapshot_digest":         metadata.RouteSnapshotDigest,
		"route_snapshot_mode":           metadata.RouteSnapshotMode,
		"route_snapshot_policy_version": metadata.RouteSnapshotPolicyVersion,
		"signature_key_alg":             "Ed25519",
		"terminal_state":                "normal_done",
		"terminal_state_ts_unix_ms":     terminalTSUnixMS,
		"usage":                         usage,
	}
	canonical, err := spec015CanonicalJSON(tuple)
	if err != nil {
		return "", fmt.Errorf("canonical settlement tuple: %w", err)
	}
	signature := ed25519.Sign(p.receiptPrivkey, canonical)
	return base64.StdEncoding.EncodeToString(canonical) + "." + base64.StdEncoding.EncodeToString(signature), nil
}

func spec015CanonicalPromptHash(requestBody []byte) (string, error) {
	var raw map[string]any
	if err := json.Unmarshal(requestBody, &raw); err != nil {
		return "", err
	}
	messages, err := canonicalPromptMessages(raw["messages"])
	if err != nil {
		return "", err
	}
	object := map[string]any{
		"model":             raw["model"],
		"messages":          messages,
		"tools":             canonicalPromptTools(raw["tools"]),
		"temperature":       valueOrNil(raw, "temperature"),
		"top_p":             valueOrNil(raw, "top_p"),
		"max_tokens":        valueOrNil(raw, "max_tokens"),
		"stop":              valueOrNil(raw, "stop"),
		"seed":              valueOrNil(raw, "seed"),
		"response_format":   valueOrNil(raw, "response_format"),
		"tool_choice":       valueOrNil(raw, "tool_choice"),
		"presence_penalty":  valueOrNil(raw, "presence_penalty"),
		"frequency_penalty": valueOrNil(raw, "frequency_penalty"),
		"logit_bias":        valueOrNil(raw, "logit_bias"),
		"logprobs":          valueOrNil(raw, "logprobs"),
		"top_logprobs":      valueOrNil(raw, "top_logprobs"),
		"n":                 valueOrNil(raw, "n"),
	}
	return spec015JCSHash(object)
}

func canonicalPromptMessages(value any) ([]any, error) {
	rawMessages, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("messages has type %T, want array", value)
	}
	messages := make([]any, 0, len(rawMessages))
	for _, item := range rawMessages {
		message, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("message has type %T, want object", item)
		}
		content, err := canonicalPromptContent(message["content"])
		if err != nil {
			return nil, err
		}
		messages = append(messages, map[string]any{
			"role":         valueOrNil(message, "role"),
			"content":      content,
			"name":         valueOrNil(message, "name"),
			"tool_call_id": valueOrNil(message, "tool_call_id"),
			"tool_calls":   canonicalPromptToolCalls(message["tool_calls"]),
		})
	}
	return messages, nil
}

func canonicalPromptContent(value any) (any, error) {
	switch typed := value.(type) {
	case nil:
		return nil, nil
	case string:
		return normalizeSpec015LineEndings(typed), nil
	case []any:
		parts := make([]any, 0, len(typed))
		for _, item := range typed {
			object, ok := item.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("content part has type %T, want object", item)
			}
			kind, _ := object["type"].(string)
			switch kind {
			case "text":
				text, _ := object["text"].(string)
				parts = append(parts, map[string]any{"type": "text", "text": normalizeSpec015LineEndings(text)})
			case "image_url":
				parts = append(parts, map[string]any{"type": "image_url", "image_url": object["image_url"]})
			case "input_audio":
				parts = append(parts, map[string]any{"type": "input_audio", "input_audio": object["input_audio"]})
			default:
				return nil, fmt.Errorf("unsupported content part type %q", kind)
			}
		}
		return parts, nil
	default:
		return nil, fmt.Errorf("content has type %T, want string, array, or null", value)
	}
}

func canonicalPromptTools(value any) any {
	if value == nil {
		return nil
	}
	return value
}

func canonicalPromptToolCalls(value any) any {
	if value == nil {
		return nil
	}
	return value
}

func spec015CanonicalOutputHash(responseBody []byte) (string, error) {
	var response struct {
		Choices []struct {
			Message struct {
				Content   string `json:"content"`
				ToolCalls any    `json:"tool_calls"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(responseBody, &response); err != nil {
		return "", err
	}
	if len(response.Choices) == 0 {
		return "", errors.New("response has no choices")
	}
	choice := response.Choices[0]
	object := map[string]any{
		"content":       normalizeSpec015LineEndings(choice.Message.Content),
		"tool_calls":    choice.Message.ToolCalls,
		"finish_reason": choice.FinishReason,
	}
	return spec015JCSHash(object)
}

func valueOrNil(values map[string]any, key string) any {
	if value, ok := values[key]; ok {
		return value
	}
	return nil
}

func normalizeSpec015LineEndings(value string) string {
	return strings.ReplaceAll(strings.ReplaceAll(value, "\r\n", "\n"), "\r", "\n")
}

func spec015JCSHash(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

func spec015CanonicalSHA256Hex(value any) (string, []byte, error) {
	canonical, err := spec015CanonicalJSON(value)
	if err != nil {
		return "", nil, err
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), canonical, nil
}

func spec015CanonicalJSON(v any) ([]byte, error) {
	var b bytes.Buffer
	if err := writeSpec015JCS(&b, v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func writeSpec015JCS(b *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case string:
		b.WriteString(escapeSpec015JCSString(norm.NFC.String(x)))
	case bool:
		if x {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case int:
		b.WriteString(strconv.Itoa(x))
	case int64:
		b.WriteString(strconv.FormatInt(x, 10))
	case json.Number:
		formatted, err := canonicalSpec015JSONNumber(x.String())
		if err != nil {
			return err
		}
		b.WriteString(formatted)
	case float64:
		formatted, err := canonicalSpec015Double(x)
		if err != nil {
			return err
		}
		b.WriteString(formatted)
	case []any:
		b.WriteByte('[')
		for i, item := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeSpec015JCS(b, item); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(x))
		for key := range x {
			keys = append(keys, key)
		}
		sort.Slice(keys, func(i, j int) bool {
			return spec015UTF16Less(keys[i], keys[j])
		})
		b.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(escapeSpec015JCSString(key))
			b.WriteByte(':')
			if err := writeSpec015JCS(b, x[key]); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	default:
		return fmt.Errorf("unsupported JCS value %T", v)
	}
	return nil
}

var integerNumberPattern = regexp.MustCompile(`^-?(0|[1-9][0-9]*)$`)

func canonicalSpec015JSONNumber(raw string) (string, error) {
	if integerNumberPattern.MatchString(raw) {
		n, err := strconv.ParseInt(raw, 10, 64)
		if err == nil {
			return strconv.FormatInt(n, 10), nil
		}
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
		return "", fmt.Errorf("invalid JSON number %q", raw)
	}
	if f == math.Trunc(f) && f >= math.MinInt64 && f <= math.MaxInt64 {
		return strconv.FormatInt(int64(f), 10), nil
	}
	return canonicalSpec015Double(f)
}

func canonicalSpec015Double(f float64) (string, error) {
	if math.IsInf(f, 0) || math.IsNaN(f) {
		return "", fmt.Errorf("non-finite number")
	}
	if f == 0 {
		return "0", nil
	}
	sign := ""
	if f < 0 {
		sign = "-"
		f = -f
	}
	digits, e, err := decimalDigitsAndExponent(strconv.FormatFloat(f, 'g', -1, 64))
	if err != nil {
		return "", err
	}
	return sign + renderSpec015ECMAScriptNumber(digits, e), nil
}

func decimalDigitsAndExponent(s string) (string, int, error) {
	if split := strings.IndexAny(s, "eE"); split >= 0 {
		mantissa := s[:split]
		exp, err := strconv.Atoi(s[split+1:])
		if err != nil {
			return "", 0, fmt.Errorf("parse float exponent %q: %w", s, err)
		}
		point := strings.IndexByte(mantissa, '.')
		integerDigits := len(mantissa)
		if point >= 0 {
			integerDigits = point
			mantissa = mantissa[:point] + mantissa[point+1:]
		}
		digits := strings.TrimLeft(mantissa, "0")
		if digits == "" {
			return "0", 1, nil
		}
		return digits, exp + integerDigits, nil
	}
	point := strings.IndexByte(s, '.')
	if point < 0 {
		point = len(s)
	} else {
		s = s[:point] + s[point+1:]
	}
	leadingZeroes := len(s) - len(strings.TrimLeft(s, "0"))
	digits := strings.TrimLeft(s, "0")
	if digits == "" {
		return "0", 1, nil
	}
	return digits, point - leadingZeroes, nil
}

func renderSpec015ECMAScriptNumber(digits string, e int) string {
	k := len(digits)
	switch {
	case k <= e && e <= 21:
		return digits + strings.Repeat("0", e-k)
	case 0 < e && e <= 21:
		return digits[:e] + "." + digits[e:]
	case -6 < e && e <= 0:
		return "0." + strings.Repeat("0", -e) + digits
	default:
		exponent := e - 1
		mantissa := digits[:1]
		if k > 1 {
			mantissa += "." + digits[1:]
		}
		if exponent >= 0 {
			return mantissa + "e+" + strconv.Itoa(exponent)
		}
		return mantissa + "e-" + strconv.Itoa(-exponent)
	}
}

func spec015UTF16Less(a, b string) bool {
	aa := utf16.Encode([]rune(a))
	bb := utf16.Encode([]rune(b))
	for i := 0; i < len(aa) && i < len(bb); i++ {
		if aa[i] != bb[i] {
			return aa[i] < bb[i]
		}
	}
	return len(aa) < len(bb)
}

func escapeSpec015JCSString(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\t':
			b.WriteString(`\t`)
		case '\n':
			b.WriteString(`\n`)
		case '\f':
			b.WriteString(`\f`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if r >= 0 && r <= 0x1f {
				b.WriteString(`\u00`)
				b.WriteString(hex.EncodeToString([]byte{byte(r)}))
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func readyStateUpdate(modelID, modelHash string) map[string]any {
	msg := map[string]any{
		"type":  "state_update",
		"state": "ready",
		"metrics_snapshot": map[string]any{
			"model_id":                   modelID,
			"model_params_b":             3.0,
			"ram_gb":                     16,
			"max_context_tokens":         8192,
			"max_concurrency":            2,
			"slots_free":                 2,
			"slots_total":                2,
			"throughput_tps_estimate":    20.0,
			"requests_served_since_last": 0,
			"avg_latency_ms_since_last":  0.0,
			"throughput_tps_since_last":  0.0,
		},
	}
	addCanonicalModelIdentity(msg["metrics_snapshot"].(map[string]any), modelHash)
	return msg
}

func addCanonicalModelIdentity(msg map[string]any, modelHash string) {
	if modelHash == "" {
		return
	}
	msg["model_hash"] = modelHash
	msg["model_hash_algorithm"] = snapshotManifestV1
}

func TestAddCanonicalModelIdentity(t *testing.T) {
	const hash = "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a"
	msg := map[string]any{}
	addCanonicalModelIdentity(msg, hash)
	if msg["model_hash"] != hash || msg["model_hash_algorithm"] != snapshotManifestV1 {
		t.Fatalf("canonical identity frame = %#v", msg)
	}
}

func chatBodyRequestsStream(body []byte) bool {
	var envelope struct {
		Stream bool `json:"stream"`
	}
	return json.Unmarshal(body, &envelope) == nil && envelope.Stream
}

func (p *fakeProvider) start(ctx context.Context) {
	p.t.Helper()
	// Inference HTTP endpoint — the coordinator hits this in legacy
	// (endpoint_url) mode. We accept any /v1/chat/completions POST and
	// return the canned completion.
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		requestBody, _ := io.ReadAll(r.Body)
		settlementMetadata, hasSettlementMetadata, err := decodeSettlementMetadataHeader(r.Header.Get("X-MacProvider-Settlement-Metadata"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		p.hitMu.Lock()
		p.hits++
		p.lastRequestBody = append([]byte(nil), requestBody...)
		p.lastResponseBody = []byte(fakeCompletionBody)
		p.hitMu.Unlock()
		if chatBodyRequestsStream(requestBody) {
			w.Header().Set("Content-Type", "text/event-stream")
			terminalTS := time.Now().UTC().UnixMilli()
			var receipt string
			if p.settlementEnabled && hasSettlementMetadata {
				var err error
				receipt, err = p.buildSettlementReceiptHeader(settlementMetadata, "hello from fake provider", "stop", 8, 12, terminalTS)
				if err != nil {
					http.Error(w, err.Error(), http.StatusInternalServerError)
					return
				}
				w.Header().Add("Trailer", "X-MacProvider-Receipt")
				w.Header().Add("Trailer", "X-MacProvider-Receipt-Terminal-State-TS-Unix-MS")
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("data: {\"id\":\"chatcmpl-fake-integration\",\"object\":\"chat.completion.chunk\",\"created\":1780000000,\"model\":\"llama-3.2-3b-instruct\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello \"},\"finish_reason\":null}]}\n\n"))
			_, _ = w.Write([]byte("data: {\"id\":\"chatcmpl-fake-integration\",\"object\":\"chat.completion.chunk\",\"created\":1780000000,\"model\":\"llama-3.2-3b-instruct\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"from fake provider\"},\"finish_reason\":null}]}\n\n"))
			_, _ = w.Write([]byte("data: {\"id\":\"chatcmpl-fake-integration\",\"object\":\"chat.completion.chunk\",\"created\":1780000000,\"model\":\"llama-3.2-3b-instruct\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"))
			_, _ = w.Write([]byte("data: {\"id\":\"chatcmpl-fake-integration\",\"object\":\"chat.completion.chunk\",\"created\":1780000000,\"model\":\"llama-3.2-3b-instruct\",\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":12,\"total_tokens\":20},\"choices\":[]}\n\n"))
			_, _ = w.Write([]byte("data: [DONE]\n\n"))
			if receipt != "" {
				w.Header().Set("X-MacProvider-Receipt", receipt)
				w.Header().Set("X-MacProvider-Receipt-Terminal-State-TS-Unix-MS", strconv.FormatInt(terminalTS, 10))
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-MacProvider-Completion-Tokens", "12")
		if p.receiptEnabled {
			receipt, err := p.buildReceiptHeader(requestBody, []byte(fakeCompletionBody))
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			w.Header().Set("X-MacProvider-Receipt", receipt)
		}
		if p.settlementEnabled && hasSettlementMetadata {
			terminalTS := time.Now().UTC().UnixMilli()
			receipt, err := p.buildSettlementReceiptHeader(settlementMetadata, "hello from fake provider", "stop", 8, 12, terminalTS)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			w.Header().Set("X-MacProvider-Receipt", receipt)
			w.Header().Set("X-MacProvider-Receipt-Terminal-State-TS-Unix-MS", strconv.FormatInt(terminalTS, 10))
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(fakeCompletionBody))
	})
	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"object":"list","data":[{"id":"llama-3.2-3b-instruct","object":"model"}]}`))
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	p.hServer = &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%d", p.httpPort),
		Handler: mux,
	}
	httpReady := make(chan struct{})
	go func() {
		ln, err := net.Listen("tcp", p.hServer.Addr)
		if err != nil {
			p.t.Errorf("fake provider listen: %v", err)
			close(httpReady)
			return
		}
		close(httpReady)
		_ = p.hServer.Serve(ln)
	}()
	<-httpReady

	// WS half — runs until ctx is cancelled or shutdown is called.
	go p.runWS(ctx)
}

func (p *fakeProvider) stop() {
	p.stopOnce.Do(func() {
		if p.hServer != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_ = p.hServer.Shutdown(ctx)
		}
		close(p.stopped)
	})
}

func (p *fakeProvider) runWS(ctx context.Context) {
	defer p.stop()
	// gobwas/ws client dial. The pinned provider needs to send its
	// Bearer token on the HTTP upgrade request so the coordinator's
	// validateProviderToken returns auth.validated=true (a pinned
	// provider with auth.validated=false is closed with invalid_token
	// at prepareProviderAdmission, ws/server.go:949).
	header := http.Header{}
	if p.providerToken != "" {
		header.Set("Authorization", "Bearer "+p.providerToken)
	}
	dialer := gobwas.Dialer{
		Timeout: 5 * time.Second,
		Header:  gobwas.HandshakeHeaderHTTP(header),
	}
	deadline := time.Now().Add(10 * time.Second)
	var conn net.Conn
	for time.Now().Before(deadline) {
		c, _, _, err := dialer.Dial(ctx, p.wsURL)
		if err == nil {
			conn = c
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if conn == nil {
		p.t.Errorf("fake provider WS dial failed within deadline")
		return
	}
	defer conn.Close()

	endpointURL := fmt.Sprintf("http://127.0.0.1:%d", p.httpPort)
	if p.receiptEnabled || p.settlementEnabled {
		providerECDH := make([]byte, 32)
		if _, err := rand.Read(providerECDH); err != nil {
			p.t.Errorf("provider ecdh key: %v", err)
			return
		}
		initial := map[string]any{
			"type":                        "auth_request",
			"version":                     2,
			"stage":                       "initial",
			"provider_id":                 p.providerID,
			"hostname":                    "fake-provider",
			"model_id":                    p.modelID,
			"model_params_b":              3.0,
			"ram_gb":                      16,
			"max_context_tokens":          8192,
			"max_concurrency":             2,
			"throughput_tps_estimate":     20.0,
			"binary_version":              "1.6.0-fake",
			"endpoint_url":                endpointURL,
			"provider_ecdh_public_key":    base64.RawURLEncoding.EncodeToString(providerECDH),
			"provider_receipt_public_key": base64.StdEncoding.EncodeToString(p.receiptPubkey),
			"supported_models":            []string{p.modelID},
			"publishes_supported_models":  true,
			"tier2_capabilities":          map[string]any{"encrypted_leg": true, "attestation": false, "aead_suites": []string{"A256GCM"}},
		}
		addCanonicalModelIdentity(initial, p.modelHash)
		if p.catalogReleaseID != "" {
			initial["catalog_release_id"] = p.catalogReleaseID
			initial["catalog_policy_version"] = p.catalogPolicy
			initial["catalog_candidate_sha256"] = p.catalogSHA256
			initial["catalog_signer_key_id"] = staticAutotuneSignerKeyID
			initial["catalog_row_identity"] = staticLlama32CandidateRowID
		}
		if err := writeJSONFrame(conn, initial); err != nil {
			p.t.Errorf("auth initial write: %v", err)
			return
		}
		challengePayload, _, err := wsutil.ReadServerData(conn)
		if err != nil {
			p.t.Errorf("read auth_challenge: %v", err)
			return
		}
		var challenge struct {
			AuthAttemptID string `json:"auth_attempt_id"`
		}
		if err := json.Unmarshal(challengePayload, &challenge); err != nil {
			p.t.Errorf("decode auth_challenge: %v", err)
			return
		}
		proof := map[string]any{
			"type":                       "auth_request",
			"version":                    2,
			"stage":                      "proof",
			"auth_attempt_id":            challenge.AuthAttemptID,
			"provider_id":                p.providerID,
			"attestation_token":          nil,
			"supported_models":           []string{p.modelID},
			"publishes_supported_models": true,
		}
		if err := writeJSONFrame(conn, proof); err != nil {
			p.t.Errorf("auth proof write: %v", err)
			return
		}
		responsePayload, _, err := wsutil.ReadServerData(conn)
		if err != nil {
			p.t.Errorf("read auth_response: %v", err)
			return
		}
		var response struct {
			Status string `json:"status"`
		}
		if err := json.Unmarshal(responsePayload, &response); err != nil || response.Status != "accepted" {
			p.t.Errorf("auth_response = %s err=%v", string(responsePayload), err)
			return
		}
		if err := writeJSONFrame(conn, readyStateUpdate(p.modelID, p.modelHash)); err != nil {
			p.t.Errorf("state_update write: %v", err)
			return
		}
	} else {
		hello := map[string]any{
			"type":                    "hello",
			"version":                 1,
			"tier":                    1,
			"provider_id":             p.providerID,
			"hostname":                "fake-provider",
			"model_id":                p.modelID,
			"model_params_b":          3.0,
			"ram_gb":                  16,
			"max_context_tokens":      8192,
			"max_concurrency":         2,
			"throughput_tps_estimate": 20.0,
			"binary_version":          "1.0.0-fake",
			"attestation":             nil,
			"endpoint_url":            endpointURL,
		}
		if err := writeJSONFrame(conn, hello); err != nil {
			p.t.Errorf("hello write: %v", err)
			return
		}

		// Read hello_ack — once we get it the coordinator considers the
		// provider admitted. We don't need to validate the ack contents;
		// the /poolz wait loop on the test side is the source of truth.
		if _, _, err := wsutil.ReadServerData(conn); err != nil {
			p.t.Errorf("read hello_ack: %v", err)
			return
		}
	}

	// Start heartbeat loop + inbound message reader. The reader has
	// to drain inbound frames or the WS buffer eventually backpressures
	// the coordinator's writer. We don't expect the coordinator to send
	// inference frames in legacy endpoint_url mode (those go via HTTP),
	// but state_update / drain_status / cancel_request can still arrive.
	hbTick := time.NewTicker(1 * time.Second)
	defer hbTick.Stop()

	// Reader goroutine
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		for {
			_, _, err := wsutil.ReadServerData(conn)
			if err != nil {
				return
			}
			// Silently drop frames; the coordinator doesn't actually
			// send inference forwards in endpoint_url mode.
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return
		case <-readDone:
			return
		case <-hbTick.C:
			hb := map[string]any{
				"type":                       "heartbeat",
				"status":                     "ready",
				"model_id":                   p.modelID,
				"model_params_b":             3.0,
				"ram_gb":                     16,
				"max_context_tokens":         8192,
				"max_concurrency":            2,
				"slots_free":                 2,
				"slots_total":                2,
				"throughput_tps_estimate":    20.0,
				"requests_served_since_last": 0,
				"avg_latency_ms_since_last":  0.0,
				"throughput_tps_since_last":  0.0,
			}
			addCanonicalModelIdentity(hb, p.modelHash)
			if err := writeJSONFrame(conn, hb); err != nil {
				return
			}
		}
	}
}

func writeJSONFrame(conn net.Conn, payload map[string]any) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	// As a WS client (i.e., this side initiated the handshake), we
	// MUST mask outbound frames. gobwas/ws's wsutil.WriteClientText
	// applies the right masking.
	return wsutil.WriteClientText(conn, b)
}

// requestLogRow is the subset of the coordinator's request_log row we
// pin in the money-path scenario. The columns match
// phase4-coordinator/internal/requestlog/store.go:93-113 verbatim.
type requestLogRow struct {
	ProviderAssignedID string
	Model              string
	Status             int
	TotalTokens        sql.NullInt64
	Stream             int
}

// usageEventRow is the subset of the gateway's usage_events row we pin
// in the money-path scenario. Columns match
// phase5-gateway/internal/storage/sqlite/migrate.go:68-79.
type usageEventRow struct {
	AccountID        string
	PromptTokens     int64
	CompletionTokens int64
	TotalTokens      int64
	Outcome          string
	TokenSource      string
	RequestID        string
}

type settlementReceiptVerdictRow struct {
	RequestID                 string
	AttemptN                  int64
	ProviderID                string
	ReceiptPresent            int
	ReceiptVersion            sql.NullString
	ReceiptResult             string
	SettlementOutcome         string
	Reason                    string
	Closed                    int
	ModelHash                 sql.NullString
	BuyerDebitOutcome         string
	ProviderSettlementOutcome string
	PayoutExclusionOutcome    string
}

type quotaReservationRow struct {
	AccountID      string
	RequestID      string
	ReservedTokens int64
	SettledTokens  int64
	Status         string
	SettlementHold int
}

// readLatestUsageEvent opens the gateway SQLite DB and returns the
// most recent usage_events row for the seeded account, or (zero, false)
// if none exists. This is the gateway-side store; together with
// readLatestRequestLog (coordinator-side) it satisfies the audit's
// "both stores' rows" coverage requirement (REPO_AUDIT.md:253).
func (s *scenario) readLatestUsageEvent() (usageEventRow, bool) {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.gatewayDB)
	if err != nil {
		s.t.Fatalf("open gateway db: %v", err)
	}
	defer db.Close()
	var row usageEventRow
	err = db.QueryRow(
		`SELECT account_id, request_id, prompt_tokens, completion_tokens, total_tokens, outcome, token_source
		   FROM usage_events WHERE account_id = ?
		  ORDER BY created_at DESC LIMIT 1`,
		s.accountID,
	).Scan(&row.AccountID, &row.RequestID, &row.PromptTokens, &row.CompletionTokens, &row.TotalTokens, &row.Outcome, &row.TokenSource)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return usageEventRow{}, false
		}
		s.t.Fatalf("query usage_events: %v", err)
	}
	return row, true
}

func (s *scenario) readUsageEvent(requestID string) (usageEventRow, bool) {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.gatewayDB)
	if err != nil {
		s.t.Fatalf("open gateway db: %v", err)
	}
	defer db.Close()
	var row usageEventRow
	err = db.QueryRow(
		`SELECT account_id, request_id, prompt_tokens, completion_tokens, total_tokens, outcome, token_source
		   FROM usage_events WHERE account_id = ? AND request_id = ?`,
		s.accountID, requestID,
	).Scan(&row.AccountID, &row.RequestID, &row.PromptTokens, &row.CompletionTokens, &row.TotalTokens, &row.Outcome, &row.TokenSource)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return usageEventRow{}, false
		}
		s.t.Fatalf("query usage_events for request %s: %v", requestID, err)
	}
	return row, true
}

func (s *scenario) readQuotaReservation(requestID string) (quotaReservationRow, bool) {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.gatewayDB)
	if err != nil {
		s.t.Fatalf("open gateway db: %v", err)
	}
	defer db.Close()
	var row quotaReservationRow
	err = db.QueryRow(
		`SELECT account_id, request_id, reserved_tokens, settled_tokens, status, settlement_hold
		   FROM quota_reservations WHERE account_id = ? AND request_id = ?`,
		s.accountID, requestID,
	).Scan(&row.AccountID, &row.RequestID, &row.ReservedTokens, &row.SettledTokens, &row.Status, &row.SettlementHold)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return quotaReservationRow{}, false
		}
		s.t.Fatalf("query quota_reservations for request %s: %v", requestID, err)
	}
	return row, true
}

// readLatestRequestLog opens the coordinator SQLite DB and returns the
// most recent request_log row, or (zero, false) if the table is empty.
// We can't filter by provider_id at the column level because the schema
// stores provider_assigned_id (the per-session ID), not the stable
// provider_id from the hello frame; the test asserts on the value
// returned in the X-MacProvider-Provider response header instead and
// pins the model + status from the row.
func (s *scenario) readLatestRequestLog() (requestLogRow, bool) {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		s.t.Fatalf("open coord db: %v", err)
	}
	defer db.Close()
	var row requestLogRow
	err = db.QueryRow(`SELECT provider_assigned_id, model, status, total_tokens, stream
		FROM request_log ORDER BY id DESC LIMIT 1`).
		Scan(&row.ProviderAssignedID, &row.Model, &row.Status, &row.TotalTokens, &row.Stream)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return requestLogRow{}, false
		}
		s.t.Fatalf("query request_log: %v", err)
	}
	return row, true
}

func (s *scenario) readSettlementReceiptVerdicts() []settlementReceiptVerdictRow {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		s.t.Fatalf("open coord db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT request_id, attempt_n, provider_id, receipt_present, receipt_version,
       receipt_result, settlement_outcome, reason, closed, model_hash,
       buyer_debit_outcome, provider_settlement_outcome, payout_exclusion_outcome
  FROM settlement_receipt_verdicts
 ORDER BY id ASC`)
	if err != nil {
		s.t.Fatalf("query settlement_receipt_verdicts: %v", err)
	}
	defer rows.Close()
	var verdicts []settlementReceiptVerdictRow
	for rows.Next() {
		var row settlementReceiptVerdictRow
		if err := rows.Scan(
			&row.RequestID,
			&row.AttemptN,
			&row.ProviderID,
			&row.ReceiptPresent,
			&row.ReceiptVersion,
			&row.ReceiptResult,
			&row.SettlementOutcome,
			&row.Reason,
			&row.Closed,
			&row.ModelHash,
			&row.BuyerDebitOutcome,
			&row.ProviderSettlementOutcome,
			&row.PayoutExclusionOutcome,
		); err != nil {
			s.t.Fatalf("scan settlement_receipt_verdicts: %v", err)
		}
		verdicts = append(verdicts, row)
	}
	if err := rows.Err(); err != nil {
		s.t.Fatalf("settlement_receipt_verdict rows: %v", err)
	}
	return verdicts
}

type ledgerCreditRow struct {
	ID                    int64
	RequestID             string
	AttemptN              int
	ProviderID            string
	Status                int
	Stream                int
	PromptTokens          sql.NullInt64
	ChargedPromptTokens   sql.NullInt64
	CachedPromptTokens    sql.NullInt64
	CompletionTokens      sql.NullInt64
	PromptRatePerMtok     int64
	CompletionRatePerMtok int64
	GlobalMultiplierPPM   int64
	ProviderShareBps      int64
	GrossCredits          int64
	ProviderCredits       int64
	Settled               int
	SettlementPolicyMode  string
}

func (s *scenario) readLedgerCredits() []ledgerCreditRow {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		s.t.Fatalf("open coord db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT id, request_id, attempt_n, provider_id, status, stream,
       prompt_tokens, charged_prompt_tokens, cached_prompt_tokens, completion_tokens,
       prompt_rate_per_mtok, completion_rate_per_mtok,
       global_multiplier_ppm, provider_share_bps, gross_credits, provider_credits,
       settled, settlement_policy_mode
  FROM ledger_request_credits
 ORDER BY id ASC`)
	if err != nil {
		s.t.Fatalf("query ledger_request_credits: %v", err)
	}
	defer rows.Close()
	var credits []ledgerCreditRow
	for rows.Next() {
		var row ledgerCreditRow
		if err := rows.Scan(
			&row.ID,
			&row.RequestID,
			&row.AttemptN,
			&row.ProviderID,
			&row.Status,
			&row.Stream,
			&row.PromptTokens,
			&row.ChargedPromptTokens,
			&row.CachedPromptTokens,
			&row.CompletionTokens,
			&row.PromptRatePerMtok,
			&row.CompletionRatePerMtok,
			&row.GlobalMultiplierPPM,
			&row.ProviderShareBps,
			&row.GrossCredits,
			&row.ProviderCredits,
			&row.Settled,
			&row.SettlementPolicyMode,
		); err != nil {
			s.t.Fatalf("scan ledger_request_credits: %v", err)
		}
		credits = append(credits, row)
	}
	if err := rows.Err(); err != nil {
		s.t.Fatalf("ledger_request_credits rows: %v", err)
	}
	return credits
}

func (s *scenario) payoutReadyCount() int {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		s.t.Fatalf("open coord db: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_payout_ready`).Scan(&count); err != nil {
		s.t.Fatalf("query ledger_payout_ready: %v", err)
	}
	return count
}

func (s *scenario) settledQuotaTokens() int64 {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.gatewayDB)
	if err != nil {
		s.t.Fatalf("open gateway db: %v", err)
	}
	defer db.Close()
	var total int64
	if err := db.QueryRow(
		`SELECT COALESCE(SUM(settled_tokens), 0) FROM quota_reservations WHERE account_id = ? AND status = 'settled'`,
		s.accountID,
	).Scan(&total); err != nil {
		s.t.Fatalf("query settled quota: %v", err)
	}
	return total
}

func (s *scenario) gatewayRequest(method, path string, extraHeaders map[string]string) (int, http.Header, []byte) {
	s.t.Helper()
	req, err := http.NewRequest(method, s.gatewayBaseURL+path, nil)
	if err != nil {
		s.t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+s.apiKey)
	for k, v := range extraHeaders {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		s.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, body
}
