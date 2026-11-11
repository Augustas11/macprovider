package config

import (
	"reflect"
	"testing"
)

// Live coordinator.yaml files may still carry keys whose struct fields were
// removed because nothing read them. Load must keep accepting those files and
// produce the same config as without them.
func TestLoadIgnoresRetiredKeys(t *testing.T) {
	const base = `
auth:
  operator_key: 0123456789abcdefABCDEFghijklmnop
  gateway_service_token: fedcba9876543210FEDCBAzyxwvutsrq
providers:
  - provider_id: mac
    endpoint_url: ""
`
	baseline := writeMinimalConfig(t, base)
	got := writeMinimalConfig(t, base+`    display_name: "Pearl Mac provider"
storage:
  snapshot_interval_s: 300
explorer:
  poll_min_interval_seconds: 5
  buyers_max_window_days: 31
  buyers_default_window_hours: 168
`)
	if !reflect.DeepEqual(got, baseline) {
		t.Fatal("retired keys changed the loaded config")
	}
}
