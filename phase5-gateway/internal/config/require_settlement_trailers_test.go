package config

import (
	"os"
	"strings"
	"testing"
)

// coordinator.require_settlement_trailers (SPEC-022 R-12.8) defaults off, so
// an existing config keeps its behaviour, and loads when set.
func TestRequireSettlementTrailersConfig(t *testing.T) {
	base := `
listen:
  bind_address: 127.0.0.1
  port: 9443
public:
  base_url: https://api.malibu.tech
  account_path: /account
coordinator:
  buyer_url: http://127.0.0.1:8443
  operator_url: http://127.0.0.1:8444
  operator_key: operator-key
  service_token: service-token
  poolz_poll_interval_s: 10
PIN
storage:
  driver: sqlite
  db_path: /var/lib/macprovider/gateway.db
auth:
  key_hash_secret: secret
  github_oauth_enabled: false
  demo:
    signing_secret: demo-secret
`
	for _, tc := range []struct {
		pin  string
		want bool
	}{
		{pin: "", want: false},
		{pin: "  require_settlement_trailers: false", want: false},
		{pin: "  require_settlement_trailers: true", want: true},
	} {
		path := t.TempDir() + "/gateway.yaml"
		if err := os.WriteFile(path, []byte(strings.Replace(base, "PIN", tc.pin, 1)), 0o600); err != nil {
			t.Fatalf("write config: %v", err)
		}
		cfg, err := Load(path)
		if err != nil {
			t.Fatalf("pin %q: Load: %v", tc.pin, err)
		}
		if cfg.Coordinator.RequireSettlementTrailers != tc.want {
			t.Fatalf("pin %q: RequireSettlementTrailers=%v want %v", tc.pin, cfg.Coordinator.RequireSettlementTrailers, tc.want)
		}
	}
	if Default().Coordinator.RequireSettlementTrailers {
		t.Fatal("the pin must default off")
	}
}
