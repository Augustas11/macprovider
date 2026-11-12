package config

import (
	"errors"
	"io/fs"
	"strings"
	"testing"
	"time"
)

func TestLoadErrorPaths(t *testing.T) {
	if _, err := Load(t.TempDir() + "/missing.yaml"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing file must surface the read error, got %v", err)
	}
	// Default config fails Validate; a swallowed yaml error would surface that
	// validation message instead of a parse error.
	defErr := Default().Validate()
	if defErr == nil {
		t.Fatal("default config unexpectedly valid")
	}
	if _, err := Load(writeTempConfig(t, "listen: [unterminated")); err == nil || err.Error() == defErr.Error() {
		t.Fatalf("malformed yaml must surface the parse error, got %v", err)
	}
	// Valid yaml that fails Validate (default config has no secrets).
	if _, err := Load(writeTempConfig(t, "listen:\n  port: 8080\n")); err == nil {
		t.Fatal("config failing validation must error from Load")
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
	for _, raw := range []string{"300.1.1.1", "10.0.0.0/99", "not-an-ip"} {
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
