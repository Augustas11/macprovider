package pool

import (
	"testing"
	"time"
)

func TestToolSelectionCapabilityHeartbeatWithdrawal(t *testing.T) {
	r := NewRegistry(nil)
	caps := []ToolSelectionCapability{{ModelID: "model-a", Runtime: "mlx_cache", Modes: []string{"none"}, Validation: "schema-holdback-v1"}}
	p := &Provider{ProviderID: "p", AssignedID: "s", ModelID: "model-a", State: StateReady, ToolSelectionCapabilities: caps, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1}
	r.Register(p, nil)
	hb := HeartbeatUpdate{Status: StateReady, ModelID: "model-a", MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, At: time.Now(), ToolSelectionCapabilities: caps}
	if result := r.ApplyHeartbeatDetailed("p", "s", hb); !result.OK || len(result.Provider.ToolSelectionCapabilities) != 1 {
		t.Fatalf("capabilities not published: %+v", result)
	}
	hb.ToolSelectionCapabilities = nil
	hb.ModelID = "model-b"
	result := r.ApplyHeartbeatDetailed("p", "s", hb)
	if !result.OK || len(result.Provider.ToolSelectionCapabilities) != 0 {
		t.Fatalf("stale capability survived absent/model-change heartbeat: %+v", result)
	}
	// Stale old-session reports cannot authorize a replacement session.
	r.Register(&Provider{ProviderID: "p", AssignedID: "replacement", ModelID: "model-b", State: StateReady}, nil)
	hb.ToolSelectionCapabilities = caps
	if result := r.ApplyHeartbeatDetailed("p", "s", hb); result.OK {
		t.Fatal("old-session heartbeat accepted")
	}
	current, _ := r.Resolve("p", "replacement")
	if len(current.ToolSelectionCapabilities) != 0 {
		t.Fatal("replacement inherited old guarantee")
	}
}
