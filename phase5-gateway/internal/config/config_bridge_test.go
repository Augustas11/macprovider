package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestUpstreamCoordinatorBearerReturnsServiceToken locks the post-PR-#87-item-3
// contract: UpstreamCoordinatorBearer returns the ServiceToken directly,
// no longer falls back to OperatorKey. Validate() guarantees ServiceToken
// is non-empty so the empty-return case can only happen if a caller bypasses
// Load — which this test pins to "" so a regression to the old fallback
// would surface as a test failure rather than a silent re-introduction of
// the legacy operator_key on /internal/* paths.
func TestUpstreamCoordinatorBearerReturnsServiceToken(t *testing.T) {
	c := CoordinatorConfig{OperatorKey: "operator", ServiceToken: "service"}
	if got := c.UpstreamCoordinatorBearer(); got != "service" {
		t.Fatalf("UpstreamCoordinatorBearer=%q want %q", got, "service")
	}
}

// TestUpstreamCoordinatorBearerNoFallbackToOperatorKey verifies that the
// removed legacy fallback stays removed: empty ServiceToken returns ""
// (NOT OperatorKey). A regression to the old behavior would re-introduce
// the cutover-defeating dual-credential path on the wire.
func TestUpstreamCoordinatorBearerNoFallbackToOperatorKey(t *testing.T) {
	c := CoordinatorConfig{OperatorKey: "operator", ServiceToken: ""}
	if got := c.UpstreamCoordinatorBearer(); got != "" {
		t.Fatalf("UpstreamCoordinatorBearer=%q want empty (post-#87 fallback removal)", got)
	}
}

// TestResolveEnvValueFailsClosedOnUnsetEnv pins the codex PR #73 MED
// fix at the helper level: when the YAML uses `env:NAME` and the
// environment variable is unset or empty, resolveEnvValue returns an
// error. Pre-fix the silent fall-through to "" let the gateway boot
// with an empty coordinator.service_token, at which point
// UpstreamCoordinatorBearer() silently fell back to OperatorKey,
// defeating the M3-2 cutover the operator had configured.
func TestResolveEnvValueFailsClosedOnUnsetEnv(t *testing.T) {
	// Guarantee the var is unset for this run.
	if err := os.Unsetenv("M3_2_TEST_UNSET_GATEWAY_TOKEN"); err != nil {
		t.Fatalf("unsetenv: %v", err)
	}
	_, err := resolveEnvValue("coordinator.service_token", "env:M3_2_TEST_UNSET_GATEWAY_TOKEN")
	if err == nil {
		t.Fatal("expected error for unset env var, got nil")
	}
	if !strings.Contains(err.Error(), "coordinator.service_token") || !strings.Contains(err.Error(), "M3_2_TEST_UNSET_GATEWAY_TOKEN") {
		t.Fatalf("error should name the field and env var: %v", err)
	}
}

// TestResolveEnvValueFailsClosedOnEmptyEnv covers the second leg: env
// var is SET but empty must still fail closed (matches the coordinator
// resolver's contract).
func TestResolveEnvValueFailsClosedOnEmptyEnv(t *testing.T) {
	t.Setenv("M3_2_TEST_EMPTY_GATEWAY_TOKEN", "")
	_, err := resolveEnvValue("coordinator.service_token", "env:M3_2_TEST_EMPTY_GATEWAY_TOKEN")
	if err == nil {
		t.Fatal("expected error for empty env var, got nil")
	}
}

// TestResolveEnvValuePassThroughNonEnvLiteral confirms that values
// WITHOUT the env: prefix are returned verbatim — the resolver only
// fires for the sentinel form.
func TestResolveEnvValuePassThroughNonEnvLiteral(t *testing.T) {
	got, err := resolveEnvValue("coordinator.operator_key", "literal-secret")
	if err != nil {
		t.Fatalf("literal value rejected: %v", err)
	}
	if got != "literal-secret" {
		t.Fatalf("got=%q want=literal-secret", got)
	}
}

// TestResolveEnvValueResolvesSetEnv covers the happy path: env var is
// set to a non-empty string, the resolver returns it.
func TestResolveEnvValueResolvesSetEnv(t *testing.T) {
	t.Setenv("M3_2_TEST_OK_GATEWAY_TOKEN", "resolved-secret")
	got, err := resolveEnvValue("coordinator.service_token", "env:M3_2_TEST_OK_GATEWAY_TOKEN")
	if err != nil {
		t.Fatalf("resolveEnvValue: %v", err)
	}
	if got != "resolved-secret" {
		t.Fatalf("got=%q want=resolved-secret", got)
	}
}

// TestLoadFailsClosedOnUnsetCoordinatorServiceTokenEnv is the
// integration-level assertion: Load() (the real boot path) returns a
// non-nil error when the YAML uses env:NAME for
// coordinator.service_token and the variable is unset. Without this,
// the codex MED finding would let the operator misconfigure the
// cutover silently.
func TestLoadFailsClosedOnUnsetCoordinatorServiceTokenEnv(t *testing.T) {
	if err := os.Unsetenv("M3_2_TEST_LOAD_UNSET_TOKEN"); err != nil {
		t.Fatalf("unsetenv: %v", err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "gateway.yaml")
	// Minimum Validate-passing config that pulls service_token from env.
	yaml := `
listen:
  bind_address: 127.0.0.1
  port: 9443
proxy:
  trusted_cidrs:
    - 127.0.0.1/32
public:
  base_url: https://example.com
  account_path: /account
storage:
  driver: sqlite
  db_path: /tmp/test.db
coordinator:
  buyer_url: https://buyer.example
  operator_url: https://op.example
  operator_key: operator-secret
  service_token: env:M3_2_TEST_LOAD_UNSET_TOKEN
  poolz_poll_interval_s: 5
auth:
  key_prefix: mp_
  key_hash: hmac_sha256
`
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected Load to fail closed on unset env, got nil")
	}
	if !strings.Contains(err.Error(), "coordinator.service_token") {
		t.Fatalf("error should reference field: %v", err)
	}
}

func TestValidateRejectsWhitespaceOnlyCoordinatorServiceToken(t *testing.T) {
	cfg := validTestConfig()
	cfg.Coordinator.ServiceToken = " \t\n "
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "coordinator.service_token must be set") {
		t.Fatalf("Validate err=%v want whitespace-only token rejection", err)
	}
}
