package config

import (
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

func TestRejectionTimingFloorClampsToFiftyMS(t *testing.T) {
	cases := map[int]time.Duration{
		-5: 50 * time.Millisecond,
		0:  50 * time.Millisecond,
		10: 50 * time.Millisecond,
		49: 50 * time.Millisecond,
		50: 50 * time.Millisecond,
		75: 75 * time.Millisecond,
	}
	for ms, want := range cases {
		got := TrustedPoolsConfig{RejectionTimingFloorMS: ms}.RejectionTimingFloor()
		if got != want {
			t.Errorf("floor(%d)=%v want %v", ms, got, want)
		}
	}
}

func TestLoadErrorPaths(t *testing.T) {
	if _, err := Load(t.TempDir() + "/missing.yaml"); err == nil {
		t.Fatal("missing file must error")
	}
	if _, err := Load(writeTempConfig(t, "listen: [unterminated")); err == nil {
		t.Fatal("malformed yaml must error")
	}
	// Valid yaml that fails Validate (default config has no secrets).
	if _, err := Load(writeTempConfig(t, "listen:\n  port: 8080\n")); err == nil {
		t.Fatal("config failing validation must error from Load")
	}
}

func TestLoadResolvesEnvSentinelsAndFailsClosed(t *testing.T) {
	cfg := validTestConfig()
	cfg.Coordinator.OperatorKey = "env:COVER_TEST_OPERATOR_KEY"
	b, err := yaml.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	path := writeTempConfig(t, string(b))

	t.Setenv("COVER_TEST_OPERATOR_KEY", "")
	_, err = Load(path)
	if err == nil || !strings.Contains(err.Error(), "coordinator.operator_key") {
		t.Fatalf("empty env must fail closed naming the field, got %v", err)
	}

	t.Setenv("COVER_TEST_OPERATOR_KEY", "resolved-operator")
	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.Coordinator.OperatorKey != "resolved-operator" {
		t.Fatalf("operator key = %q", got.Coordinator.OperatorKey)
	}
}

func TestResolveEnvErrorsPerField(t *testing.T) {
	for name, mutate := range map[string]func(*Config){
		"coordinator.service_token":       func(c *Config) { c.Coordinator.ServiceToken = "env:COVER_UNSET_X" },
		"auth.key_hash_secret":            func(c *Config) { c.Auth.KeyHashSecret = "env:COVER_UNSET_X" },
		"auth.demo.signing_secret":        func(c *Config) { c.Auth.Demo.SigningSecret = "env:COVER_UNSET_X" },
		"auth.oauth.github.client_id":     func(c *Config) { c.Auth.OAuth.GitHub.ClientID = "env:COVER_UNSET_X" },
		"auth.oauth.github.client_secret": func(c *Config) { c.Auth.OAuth.GitHub.ClientSecret = "env:COVER_UNSET_X" },
	} {
		cfg := validTestConfig()
		mutate(&cfg)
		err := cfg.resolveEnv()
		if err == nil || !strings.Contains(err.Error(), name) {
			t.Errorf("%s: err=%v", name, err)
		}
	}
	cfg := validTestConfig()
	cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": "env:COVER_UNSET_X"}
	if err := cfg.resolveEnv(); err == nil || !strings.Contains(err.Error(), "bearer_hash_keys.k1") {
		t.Errorf("bearer hash key env err=%v", err)
	}
}

func TestValidateRejectsStructuralMisconfig(t *testing.T) {
	cases := map[string]func(*Config){
		"listen.bind_address": func(c *Config) { c.Listen.BindAddress = "" },
		"listen.port":         func(c *Config) { c.Listen.Port = 70000 },
		"trusted_cidrs":       func(c *Config) { c.Proxy.TrustedCIDRs = nil },
		"public.base_url":     func(c *Config) { c.Public.BaseURL = "not-a-url" },
		"public.account_path": func(c *Config) { c.Public.AccountPath = "account" },
		"storage.driver":      func(c *Config) { c.Storage.Driver = "postgres" },
		"storage.db_path":     func(c *Config) { c.Storage.DBPath = "" },
		"coordinator.buyer_url": func(c *Config) {
			c.Coordinator.BuyerURL = ""
		},
		"coordinator.operator_url": func(c *Config) { c.Coordinator.OperatorURL = "" },
		"coordinator.operator_key": func(c *Config) { c.Coordinator.OperatorKey = "" },
		"service_token":            func(c *Config) { c.Coordinator.ServiceToken = "  " },
		"poolz_poll_interval_s":    func(c *Config) { c.Coordinator.PoolzPollInterval = 0 },
		"auth.key_prefix":          func(c *Config) { c.Auth.KeyPrefix = "xx_" },
		"auth.key_hash":            func(c *Config) { c.Auth.KeyHash = "md5" },
		"auth.key_hash_secret":     func(c *Config) { c.Auth.KeyHashSecret = "" },
		"auth.demo.signing_secret": func(c *Config) { c.Auth.Demo.SigningSecret = "" },
	}
	if err := validTestConfig().Validate(); err != nil {
		t.Fatalf("baseline must validate: %v", err)
	}
	for want, mutate := range cases {
		cfg := validTestConfig()
		mutate(&cfg)
		err := cfg.Validate()
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: err=%v", want, err)
		}
	}
}

func TestValidateRejectsBadCoordinatorURL(t *testing.T) {
	cfg := validTestConfig()
	cfg.Coordinator.BuyerURL = "/relative/only"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "coordinator.buyer_url must be an absolute URL") {
		t.Fatalf("err=%v", err)
	}
	cfg = validTestConfig()
	cfg.Coordinator.OperatorURL = "//nohost"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "coordinator.operator_url must be an absolute URL") {
		t.Fatalf("err=%v", err)
	}
}

func TestTrustedProxyNets(t *testing.T) {
	cfg := validTestConfig()
	cfg.Proxy.TrustedCIDRs = []string{"10.0.0.0/8", " 192.0.2.7 ", "2001:db8::1"}
	nets, err := cfg.TrustedProxyNets()
	if err != nil {
		t.Fatal(err)
	}
	if len(nets) != 3 {
		t.Fatalf("len=%d", len(nets))
	}
	if ones, bits := nets[1].Mask.Size(); ones != 32 || bits != 32 {
		t.Errorf("bare IPv4 mask = /%d of %d", ones, bits)
	}
	if ones, bits := nets[2].Mask.Size(); ones != 128 || bits != 128 {
		t.Errorf("bare IPv6 mask = /%d of %d", ones, bits)
	}
	if nets[0].Contains(nets[1].IP) {
		t.Error("10.0.0.0/8 must not contain 192.0.2.7")
	}

	cfg.Proxy.TrustedCIDRs = []string{"10.0.0.0/8", "bogus"}
	if _, err := cfg.TrustedProxyNets(); err == nil {
		t.Fatal("invalid entry must error")
	}
}

func TestParseCIDROrIPRejectsBadInput(t *testing.T) {
	for _, raw := range []string{"", "   ", "300.1.1.1", "10.0.0.0/99", "not-an-ip"} {
		if _, _, err := parseCIDROrIP(raw); err == nil {
			t.Errorf("%q must be rejected", raw)
		}
	}
}

func TestAddressAndCoordinatorTimeouts(t *testing.T) {
	cfg := Default()
	cfg.Listen.BindAddress = "127.0.0.1"
	cfg.Listen.Port = 9123
	if got := cfg.Address(); got != "127.0.0.1:9123" {
		t.Errorf("Address=%q", got)
	}
	cfg.Timeouts.CoordinatorConnectSeconds = 7
	cfg.Timeouts.CoordinatorAdmissionSeconds = 31
	if got := cfg.CoordinatorConnectTimeout(); got != 7*time.Second {
		t.Errorf("connect=%v", got)
	}
	if got := cfg.CoordinatorAdmissionTimeout(); got != 31*time.Second {
		t.Errorf("admission=%v", got)
	}
}

func TestNormalizeModelKeyServedAliases(t *testing.T) {
	cases := map[string]string{
		"Llama-3.1-8B-Instruct":                  "meta-llama/llama-3.1-8b-instruct",
		"mlx-community/Meta-Llama-3-8B-Instruct": "meta-llama/llama-3-8b-instruct",
		"nvidia/nvidia-nemotron-nano-9b":         "nemotron-nano-9b",
		"gpt-oss-120b":                           "openai/gpt-oss-120b",
		"openai/gpt-oss-20b-4bit":                "openai/gpt-oss-20b",
		"glm-4.6":                                "z-ai/glm-4.6",
		"unknown/model-4bit":                     "unknown/model",
		"some-plain-model":                       "some-plain-model",
		"somevendor/llama-3":                     "somevendor/llama-3",
	}
	for in, want := range cases {
		if got := NormalizeModelKey(in); got != want {
			t.Errorf("NormalizeModelKey(%q)=%q want %q", in, got, want)
		}
	}
}
