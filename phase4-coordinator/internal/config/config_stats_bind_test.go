package config

import (
	"strings"
	"testing"
)

// TestStatsRequiresLoopbackBind — final adversarial audit
// (codex SECURITY MEDIUM 1): when stats.enabled=true, the
// coordinator mounts the Prometheus `/metrics` endpoint on
// the provider port. The `stats_partner_key_request_total`
// counter has a `partner_key_id` label which is a monotonic
// internal id — exposing it publicly is a key-enumeration
// oracle. Pearl deploys bind to 127.0.0.1 and front nginx, but
// a future operator who misconfigures `listen.bind_address` to
// 0.0.0.0 / :: must get a clear startup error rather than a
// silent public exposure.
func TestStatsRequiresLoopbackBind(t *testing.T) {
	mkCfg := func(bind string) Config {
		c := Config{}
		c.Listen.BindAddress = bind
		c.Listen.BuyerPort = 8443
		c.Listen.ProviderPort = 8444
		c.Stats.Enabled = true
		c.Stats.ReaderDSN = "postgres://r@/x"
		c.Stats.RollupDSN = "postgres://w@/x"
		return c
	}

	t.Run("loopback IPv4 accepted", func(t *testing.T) {
		if err := mkCfg("127.0.0.1").validateStats(); err != nil {
			t.Errorf("127.0.0.1 should be accepted; got %v", err)
		}
	})
	t.Run("loopback IPv6 accepted", func(t *testing.T) {
		if err := mkCfg("::1").validateStats(); err != nil {
			t.Errorf("::1 should be accepted; got %v", err)
		}
	})
	t.Run("localhost accepted", func(t *testing.T) {
		if err := mkCfg("localhost").validateStats(); err != nil {
			t.Errorf("localhost should be accepted; got %v", err)
		}
	})
	t.Run("0.0.0.0 rejected fail-closed", func(t *testing.T) {
		err := mkCfg("0.0.0.0").validateStats()
		if err == nil {
			t.Fatalf("0.0.0.0 must be rejected when stats.enabled=true")
		}
		if !strings.Contains(err.Error(), "loopback") {
			t.Errorf("error must mention loopback; got %q", err)
		}
		if !strings.Contains(err.Error(), "partner_key_id") &&
			!strings.Contains(err.Error(), "enumeration") {
			t.Errorf("error should explain the partner-key-id enumeration risk; got %q", err)
		}
	})
	t.Run("[::] rejected fail-closed", func(t *testing.T) {
		err := mkCfg("::").validateStats()
		if err == nil {
			t.Fatalf(":: must be rejected when stats.enabled=true")
		}
	})
	t.Run("public ip rejected fail-closed", func(t *testing.T) {
		err := mkCfg("10.0.0.5").validateStats()
		if err == nil {
			t.Fatalf("10.0.0.5 must be rejected when stats.enabled=true")
		}
	})
	t.Run("empty bind rejected", func(t *testing.T) {
		err := mkCfg("").validateStats()
		if err == nil {
			t.Fatalf("empty bind_address must be rejected")
		}
	})
	t.Run("stats disabled bypasses the guard", func(t *testing.T) {
		c := mkCfg("0.0.0.0")
		c.Stats.Enabled = false
		if err := c.validateStats(); err != nil {
			t.Errorf("stats disabled: bind guard should NOT fire; got %v", err)
		}
	})
}
