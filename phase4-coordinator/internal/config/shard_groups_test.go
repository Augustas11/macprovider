package config

import (
	"strings"
	"testing"
)

// SPEC-051 §4: shard_groups defaults are valid and out-of-bound values fail
// configuration load.
func TestShardGroupsConfigBounds(t *testing.T) {
	if err := DefaultShardGroupsConfig().validate(); err != nil {
		t.Fatalf("defaults invalid: %v", err)
	}
	if err := Default().Validate(); err != nil && strings.Contains(err.Error(), "shard_groups") {
		t.Fatalf("default config shard_groups invalid: %v", err)
	}
	for name, mutate := range map[string]func(*ShardGroupsConfig){
		"max_members low":     func(c *ShardGroupsConfig) { c.MaxMembers = 1 },
		"max_members high":    func(c *ShardGroupsConfig) { c.MaxMembers = 9 },
		"rtt low":             func(c *ShardGroupsConfig) { c.MaxLinkRTTP99US = 100 },
		"rtt high":            func(c *ShardGroupsConfig) { c.MaxLinkRTTP99US = 6000 },
		"stale multiple":      func(c *ShardGroupsConfig) { c.GroupHeartbeatStaleMultiple = 1 },
		"protection unknown":  func(c *ShardGroupsConfig) { c.RequiredFrameProtection.Ethernet = "none" },
		"no transports":       func(c *ShardGroupsConfig) { c.SupportedTransportVersions = nil },
		"transport out range": func(c *ShardGroupsConfig) { c.SupportedTransportVersions = []int{0} },
	} {
		c := DefaultShardGroupsConfig()
		mutate(&c)
		if err := c.validate(); err == nil || !strings.HasPrefix(err.Error(), "shard_groups.") {
			t.Errorf("%s: err = %v", name, err)
		}
	}
}
