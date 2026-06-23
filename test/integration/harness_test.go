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
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
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
	fakeProvs   []*fakeProvider
	coordLogBuf *logBuffer // populated when captureCoordLogs=true
	cancelAll   context.CancelFunc
	fakeProv    *fakeProvider
	procWG      sync.WaitGroup
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
	s.writeCoordinatorYAML(buyerPort, provPort, opts.stickyEnabled, coordServiceTok, providerCfgs)

	gwServiceTok := s.serviceToken
	if opts.gatewayServiceToken != nil {
		gwServiceTok = *opts.gatewayServiceToken
	}
	s.writeGatewayYAML(gwPort, opts.stickyEnabled, gwServiceTok)

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
func (s *scenario) writeCoordinatorYAML(buyerPort, provPort int, stickyEnabled bool, gatewayServiceToken string, providers []map[string]any) {
	s.t.Helper()
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
		"tier2": map[string]any{
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
		},
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
	b, err := yaml.Marshal(cfg)
	if err != nil {
		s.t.Fatalf("marshal coordinator yaml: %v", err)
	}
	if err := os.WriteFile(s.coordYAML, b, 0o600); err != nil {
		s.t.Fatalf("write coordinator yaml: %v", err)
	}
}

func (s *scenario) writeGatewayYAML(gwPort int, stickyEnabled bool, serviceToken string) {
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
			"max_tokens_per_request":      4096,
			"demo_max_tokens_per_request": 512,
			"max_feedback_comment_bytes":  2000,
			"request_body_bytes":          1048576,
		},
		"capacity": map[string]any{
			"monthly_budget_usd":                500,
			"ready_provider_degraded_threshold": 1,
			"projected_cost_tier1_percent":      80,
			"tier_cooldown_seconds":             3600,
		},
		"timeouts": map[string]any{
			"coordinator_request_seconds":        60,
			"coordinator_header_timeout_seconds": 10,
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
	cmd.Stderr = io.Discard
	cmd.Stdout = io.Discard
	if err := cmd.Start(); err != nil {
		s.t.Fatalf("seed gateway start: %v", err)
	}
	// Poll until the schema is present, then kill.
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		db, err := sql.Open("sqlite", s.gatewayDB)
		if err == nil {
			var ok int
			err = db.QueryRow(`SELECT 1 FROM sqlite_master WHERE type='table' AND name='accounts'`).Scan(&ok)
			db.Close()
			if err == nil {
				break
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = cmd.Process.Kill()
	_ = cmd.Wait()

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
	cmd := exec.CommandContext(ctx, coordinatorBin, "-config", s.coordYAML)
	cmd.Env = os.Environ()
	s.streamLogs(cmd, "coord")
	if err := cmd.Start(); err != nil {
		s.t.Fatalf("start coordinator: %v", err)
	}
	s.procWG.Add(1)
	go func() {
		defer s.procWG.Done()
		_ = cmd.Wait()
	}()
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
	t                *testing.T
	providerID       string
	providerToken    string
	httpPort         int
	wsURL            string
	hServer          *http.Server
	receiptEnabled   bool
	receiptPubkey    ed25519.PublicKey
	receiptPrivkey   ed25519.PrivateKey
	lastRequestBody  []byte
	lastResponseBody []byte
	hReady           chan struct{}
	stopOnce         sync.Once
	stopped          chan struct{}
	hitMu            sync.Mutex
	hits             int // /v1/chat/completions hit count, for sticky verification
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

func readyStateUpdate() map[string]any {
	return map[string]any{
		"type":  "state_update",
		"state": "ready",
		"metrics_snapshot": map[string]any{
			"model_id":                   "llama-3.2-3b-instruct",
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
		p.hitMu.Lock()
		p.hits++
		p.lastRequestBody = append([]byte(nil), requestBody...)
		p.lastResponseBody = []byte(fakeCompletionBody)
		p.hitMu.Unlock()
		if chatBodyRequestsStream(requestBody) {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("data: {\"id\":\"chatcmpl-fake-integration\",\"object\":\"chat.completion.chunk\",\"created\":1780000000,\"model\":\"llama-3.2-3b-instruct\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\n"))
			_, _ = w.Write([]byte("data: {\"id\":\"chatcmpl-fake-integration\",\"object\":\"chat.completion.chunk\",\"created\":1780000000,\"model\":\"llama-3.2-3b-instruct\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"))
			_, _ = w.Write([]byte("data: [DONE]\n\n"))
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
	if p.receiptEnabled {
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
			"model_id":                    "llama-3.2-3b-instruct",
			"model_params_b":              3.0,
			"ram_gb":                      16,
			"max_context_tokens":          8192,
			"max_concurrency":             2,
			"throughput_tps_estimate":     20.0,
			"binary_version":              "1.6.0-fake",
			"endpoint_url":                endpointURL,
			"provider_ecdh_public_key":    base64.RawURLEncoding.EncodeToString(providerECDH),
			"provider_receipt_public_key": base64.StdEncoding.EncodeToString(p.receiptPubkey),
			"supported_models":            []string{"llama-3.2-3b-instruct"},
			"publishes_supported_models":  true,
			"tier2_capabilities":          map[string]any{"encrypted_leg": true, "attestation": false, "aead_suites": []string{"A256GCM"}},
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
			"supported_models":           []string{"llama-3.2-3b-instruct"},
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
		if err := writeJSONFrame(conn, readyStateUpdate()); err != nil {
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
			"model_id":                "llama-3.2-3b-instruct",
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
				"model_id":                   "llama-3.2-3b-instruct",
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
	AccountID   string
	TotalTokens int64
	Outcome     string
	TokenSource string
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
		`SELECT account_id, total_tokens, outcome, token_source
		   FROM usage_events WHERE account_id = ?
		  ORDER BY created_at DESC LIMIT 1`,
		s.accountID,
	).Scan(&row.AccountID, &row.TotalTokens, &row.Outcome, &row.TokenSource)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return usageEventRow{}, false
		}
		s.t.Fatalf("query usage_events: %v", err)
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
