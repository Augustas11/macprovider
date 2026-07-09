package spec014pairing

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
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

var (
	repoRoot       string
	coordinatorBin string
	buildErr       error
)

func TestMain(m *testing.M) {
	var err error
	repoRoot, err = findRepoRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "find repo root: %v\n", err)
		os.Exit(1)
	}
	tmpRoot, err := os.MkdirTemp("", "spec-014-v0-2-bins-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "tempdir: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmpRoot)
	coordinatorBin = filepath.Join(tmpRoot, "coordinator")
	buildErr = buildCoordinator(coordinatorBin)
	os.Exit(m.Run())
}

func requireCoordinator(t *testing.T) {
	t.Helper()
	if buildErr != nil {
		t.Fatalf("build coordinator: %v", buildErr)
	}
}

func buildCoordinator(outPath string) error {
	cmd := exec.Command("go", "build", "-o", outPath, "./cmd/coordinator")
	cmd.Dir = filepath.Join(repoRoot, "phase4-coordinator")
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v\n%s", err, string(out))
	}
	return nil
}

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

type coordinatorProcess struct {
	providerURL string
	dbPath      string
	logs        *safeBuffer
}

func startCoordinator(t *testing.T, githubEnabled bool, extraEnv map[string]string) *coordinatorProcess {
	t.Helper()
	requireCoordinator(t)
	dir := t.TempDir()
	providerPort := allocatePort(t)
	buyerPort := allocatePort(t)
	dbPath := filepath.Join(dir, "coordinator.db")
	cfgPath := filepath.Join(dir, "coordinator.yaml")
	writeCoordinatorConfig(t, cfgPath, dbPath, providerPort, buyerPort, githubEnabled)

	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, coordinatorBin, "-config", cfgPath)
	cmd.Env = withoutGitHubOAuthEnv(os.Environ())
	for k, v := range extraEnv {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	logs := &safeBuffer{}
	cmd.Stdout = logs
	cmd.Stderr = logs
	if err := cmd.Start(); err != nil {
		cancel()
		t.Fatalf("start coordinator: %v", err)
	}
	waitDone := make(chan error, 1)
	go func() { waitDone <- cmd.Wait() }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-waitDone:
		case <-time.After(5 * time.Second):
			_ = cmd.Process.Kill()
			<-waitDone
		}
	})

	proc := &coordinatorProcess{
		providerURL: fmt.Sprintf("http://127.0.0.1:%d", providerPort),
		dbPath:      dbPath,
		logs:        logs,
	}
	waitForHTTP(t, proc.providerURL+"/healthz")
	return proc
}

func runCoordinatorExpectFailure(t *testing.T, env map[string]string) string {
	t.Helper()
	requireCoordinator(t)
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "coordinator.yaml")
	writeCoordinatorConfigWithoutGitHubValues(t, cfgPath, filepath.Join(dir, "coordinator.db"), allocatePort(t), allocatePort(t))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, coordinatorBin, "-config", cfgPath)
	cmd.Env = withoutGitHubOAuthEnv(os.Environ())
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	out, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		t.Fatalf("coordinator did not fail closed within 5s; output=%s", string(out))
	}
	if err == nil {
		t.Fatalf("coordinator exited 0, want non-zero; output=%s", string(out))
	}
	return string(out)
}

func withoutGitHubOAuthEnv(env []string) []string {
	blocked := map[string]struct{}{
		"GITHUB_OAUTH_ENABLED":       {},
		"GITHUB_OAUTH_CLIENT_ID":     {},
		"GITHUB_OAUTH_CLIENT_SECRET": {},
		"GITHUB_OAUTH_REDIRECT_URI":  {},
		"PORTAL_BASE_URL":            {},
		"MP_SESSION_COOKIE_DOMAIN":   {},
	}
	out := env[:0]
	for _, entry := range env {
		key, _, ok := strings.Cut(entry, "=")
		if !ok {
			out = append(out, entry)
			continue
		}
		if _, drop := blocked[key]; drop {
			continue
		}
		out = append(out, entry)
	}
	return out
}

func writeCoordinatorConfig(t *testing.T, path, dbPath string, providerPort, buyerPort int, githubEnabled bool) {
	t.Helper()
	writeCoordinatorConfigWithOAuth(t, path, dbPath, providerPort, buyerPort, map[string]any{
		"enabled":         githubEnabled,
		"client_id":       "spec014-client",
		"client_secret":   "spec014-secret",
		"redirect_uri":    "https://coordinator.example/v1/auth/github/callback",
		"portal_base_url": "https://portal.example",
	})
}

func writeCoordinatorConfigWithoutGitHubValues(t *testing.T, path, dbPath string, providerPort, buyerPort int) {
	t.Helper()
	writeCoordinatorConfigWithOAuth(t, path, dbPath, providerPort, buyerPort, map[string]any{"enabled": false})
}

func writeCoordinatorConfigWithOAuth(t *testing.T, path, dbPath string, providerPort, buyerPort int, githubOAuth map[string]any) {
	t.Helper()
	cfg := map[string]any{
		"listen": map[string]any{
			"bind_address":  "127.0.0.1",
			"provider_port": providerPort,
			"buyer_port":    buyerPort,
		},
		"pool": map[string]any{
			"heartbeat_interval_s":       30,
			"disconnect_grace_period_s":  5,
			"heartbeat_miss_threshold_s": 90,
			"wake_gap_threshold_s":       300,
			"warmup_fallback_s":          2,
			"warmup_gate_enabled":        false,
			"warmup_gate_timeout_s":      1,
			"warmup_gate_max_tokens":     8,
			"degraded_backoff_s":         1,
			"degraded_max_retries":       1,
			"degraded_probe_after_502":   false,
			"breaker_failure_threshold":  3,
			"breaker_window_s":           60,
		},
		"routing": map[string]any{
			"preflight_threshold_tokens":        0,
			"preflight_timeout_s":               1,
			"request_timeout_s":                 5,
			"failover_enabled":                  true,
			"failover_timeout_s":                1,
			"tiebreak_randomize":                false,
			"tiebreak_epsilon":                  0.01,
			"max_retries":                       1,
			"retry_per_attempt_timeout_s":       5,
			"max_providers_faulted_per_request": 1,
			"sticky_enabled":                    false,
			"sticky_ttl_s":                      60,
			"sticky_max_entries":                100,
			"model_classes":                     map[string]any{},
		},
		"provider_http": map[string]any{"timeout_s": 5},
		"limits":        map[string]any{"max_chat_request_body_bytes": 1048576},
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
			"operator_key":            randHex(t, 32),
			"gateway_service_token":   randHex(t, 32),
			"require_provider_tokens": false,
			"github_oauth":            githubOAuth,
		},
		"storage": map[string]any{
			"db_path":                    dbPath,
			"snapshot_interval_s":        300,
			"request_log_retention_days": 90,
			"audit_log_retention_days":   90,
		},
		"logging": map[string]any{"level": "info", "format": "json"},
		"rewards": map[string]any{
			"global_multiplier": 1.0,
			"provider_share":    0.9,
			"rate_card": map[string]any{"default": map[string]any{
				"prompt_credits_per_mtok":     500000,
				"completion_credits_per_mtok": 1000000,
			}},
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
			"provider_earnings": map[string]any{"rate_limit_per_minute": 60},
		},
		"explorer":  map[string]any{"enabled": false},
		"providers": []any{},
	}
	b, err := yaml.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal coordinator config: %v", err)
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatalf("write coordinator config: %v", err)
	}
}

func providerHello(providerID string) map[string]any {
	return map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             providerID,
		"hostname":                "spec014-binary-stub",
		"model_id":                "llama-3.2-3b-instruct",
		"model_params_b":          3.0,
		"ram_gb":                  16,
		"max_context_tokens":      8192,
		"max_concurrency":         1,
		"throughput_tps_estimate": 10.0,
		"binary_version":          "spec014-v0.2-stub",
		"attestation":             nil,
	}
}

func dialProvider(t *testing.T, providerURL, providerID string) (net.Conn, map[string]any) {
	t.Helper()
	conn, _, _, err := gobwas.Dial(context.Background(), strings.Replace(providerURL, "http://", "ws://", 1)+"/ws/provider")
	if err != nil {
		t.Fatalf("dial provider ws: %v", err)
	}
	b, err := json.Marshal(providerHello(providerID))
	if err != nil {
		conn.Close()
		t.Fatalf("marshal hello: %v", err)
	}
	if err := wsutil.WriteClientText(conn, b); err != nil {
		conn.Close()
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		conn.Close()
		t.Fatalf("read hello_ack: %v", err)
	}
	var ack map[string]any
	if err := json.Unmarshal(payload, &ack); err != nil {
		conn.Close()
		t.Fatalf("decode hello_ack: %v payload=%s", err, string(payload))
	}
	return conn, ack
}

func readOwnershipEvent(t *testing.T, conn net.Conn, providerID string) map[string]any {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	if err := conn.SetReadDeadline(deadline); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	for time.Now().Before(deadline) {
		payload, _, err := wsutil.ReadServerData(conn)
		if err != nil {
			t.Fatalf("read ownership event: %v", err)
		}
		var event map[string]any
		if err := json.Unmarshal(payload, &event); err != nil {
			continue
		}
		if event["type"] == "ownership_event" && event["event"] == "bound" && event["provider_id"] == providerID {
			return event
		}
	}
	t.Fatalf("ownership_event bound for %s did not arrive within 5s", providerID)
	return nil
}

func openDB(t *testing.T, path string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func seedSession(t *testing.T, db *sql.DB, pendingPairOT string) string {
	t.Helper()
	now := time.Now().UTC()
	sessionID := randHex(t, 32)
	if _, err := db.Exec(`INSERT INTO github_identities (github_user_id, github_login, created_at, last_seen_at) VALUES (?, ?, ?, ?) ON CONFLICT(github_user_id) DO UPDATE SET github_login = excluded.github_login, last_seen_at = excluded.last_seen_at`,
		42, "octo", timeText(now), timeText(now)); err != nil {
		t.Fatalf("seed github identity: %v", err)
	}
	var pending any
	var pendingExpires any
	if pendingPairOT != "" {
		pending = pendingPairOT
		pendingExpires = timeText(now.Add(10 * time.Minute))
	}
	if _, err := db.Exec(`INSERT INTO mp_sessions (id, github_user_id, created_at, last_seen_at, last_setcookie_at, pending_pair_ot, pending_pair_ot_expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		sessionID, 42, timeText(now), timeText(now), timeText(now), pending, pendingExpires); err != nil {
		t.Fatalf("seed mp_session: %v", err)
	}
	return sessionID
}

func seedPairOT(t *testing.T, db *sql.DB, providerID string) string {
	t.Helper()
	pairOT := randHex(t, 16)
	now := time.Now().UTC()
	if _, err := db.Exec(`INSERT INTO pair_ots (id, provider_id, expires_at, created_at) VALUES (?, ?, ?, ?)`,
		pairOT, providerID, timeText(now.Add(10*time.Minute)), timeText(now)); err != nil {
		t.Fatalf("seed pair_ot: %v", err)
	}
	return pairOT
}

func authClient(t *testing.T, sessionID string) *http.Client {
	t.Helper()
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatalf("cookie jar: %v", err)
	}
	c := &http.Client{Jar: jar, Timeout: 5 * time.Second}
	u := mustURL(t, "http://127.0.0.1/")
	jar.SetCookies(u, []*http.Cookie{{Name: "mp_session", Value: sessionID, Path: "/"}})
	return c
}

func postBind(t *testing.T, c *http.Client, baseURL, body string) (int, []byte) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, baseURL+"/v1/auth/me/providers/bind", strings.NewReader(body))
	if err != nil {
		t.Fatalf("new bind req: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("post bind: %v", err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func waitForHTTP(t *testing.T, rawURL string) {
	t.Helper()
	// 30s: the cross-service integration job runs this package in parallel
	// with the root harness (each builds coordinator binaries). Under CI
	// load 10s was too tight for /healthz to come up reliably.
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(rawURL)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode < 500 {
				return
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("%s did not become ready", rawURL)
}

func allocatePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("allocate port: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func randHex(t *testing.T, n int) string {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return hex.EncodeToString(b)
}

func timeText(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05Z")
}

func mustURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse url: %v", err)
	}
	return u
}

type safeBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *safeBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}

func (b *safeBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String()
}
