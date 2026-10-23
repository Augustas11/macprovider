package config

import "fmt"

// ShardGroupsConfig is the SPEC-051 §4 coordinator `shard_groups` section.
// Its values are tuning bounds, not gates: none of them disables or withdraws
// a group on a schedule.
type ShardGroupsConfig struct {
	MaxMembers                  int                          `yaml:"max_members"`
	MaxLinkRTTP99US             int                          `yaml:"max_link_rtt_p99_us"`
	RequiredFrameProtection     ShardGroupFrameProtectionMin `yaml:"required_frame_protection"`
	GroupHeartbeatStaleMultiple int                          `yaml:"group_heartbeat_stale_multiple"`
	SupportedTransportVersions  []int                        `yaml:"supported_transport_versions"`
}

// ShardGroupFrameProtectionMin is the minimum frame protection per
// interconnect class (SPEC-051-R011).
type ShardGroupFrameProtectionMin struct {
	ThunderboltIP string `yaml:"thunderbolt-ip"`
	Ethernet      string `yaml:"ethernet"`
}

// DefaultShardGroupsConfig returns the SPEC-051 §4 defaults.
func DefaultShardGroupsConfig() ShardGroupsConfig {
	return ShardGroupsConfig{
		MaxMembers:      4,
		MaxLinkRTTP99US: 2000,
		RequiredFrameProtection: ShardGroupFrameProtectionMin{
			ThunderboltIP: "crc32c",
			Ethernet:      "hmac-sha256",
		},
		GroupHeartbeatStaleMultiple: 3,
		SupportedTransportVersions:  []int{1},
	}
}

// shardGroupFrameProtections is the closed SPEC-051-R011 enum.
var shardGroupFrameProtections = map[string]bool{"crc32c": true, "hmac-sha256": true, "aead-chacha20poly1305": true}

func (c ShardGroupsConfig) validate() error {
	bounds := []struct {
		name     string
		value    int
		min, max int
	}{
		{"max_members", c.MaxMembers, 2, 8},
		{"max_link_rtt_p99_us", c.MaxLinkRTTP99US, 200, 5000},
		{"group_heartbeat_stale_multiple", c.GroupHeartbeatStaleMultiple, 2, 10},
	}
	for _, b := range bounds {
		if b.value < b.min || b.value > b.max {
			return fmt.Errorf("shard_groups.%s must be in [%d, %d]", b.name, b.min, b.max)
		}
	}
	for name, value := range map[string]string{"thunderbolt-ip": c.RequiredFrameProtection.ThunderboltIP, "ethernet": c.RequiredFrameProtection.Ethernet} {
		if !shardGroupFrameProtections[value] {
			return fmt.Errorf("shard_groups.required_frame_protection.%s must be crc32c, hmac-sha256 or aead-chacha20poly1305", name)
		}
	}
	// SPEC-051-R011: a switched Ethernet segment is not point-to-point, so its
	// frames need authentication, never a check value alone.
	if c.RequiredFrameProtection.Ethernet == "crc32c" {
		return fmt.Errorf("shard_groups.required_frame_protection.ethernet must be hmac-sha256 or aead-chacha20poly1305")
	}
	if len(c.SupportedTransportVersions) == 0 {
		return fmt.Errorf("shard_groups.supported_transport_versions must not be empty")
	}
	for _, v := range c.SupportedTransportVersions {
		if v < 1 || v > 65535 {
			return fmt.Errorf("shard_groups.supported_transport_versions values must be in [1, 65535]")
		}
	}
	return nil
}
