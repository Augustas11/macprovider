package ws

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const engineProfileHeartbeatBase = `{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":4096,"max_concurrency":5,"slots_free":5,"slots_total":5,"throughput_tps_estimate":10.0,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0`

const validEngineProfile = `{"version":"engine-profile-v1","engine_family":"continuous_batching","cb_granted_slots":4,"native_mtp_active":false,"chip_class":"m2_max","ram_class_gb":96,"max_stable_context_tokens":32768}`

// SPEC-001-R006: a valid closed profile is recorded.
func TestParseHeartbeatAcceptsEngineProfile(t *testing.T) {
	hb, _, _, err := ParseHeartbeat([]byte(engineProfileHeartbeatBase + `,"engine_profile":` + validEngineProfile + `}`))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	want := pool.EngineProfile{Version: "engine-profile-v1", EngineFamily: "continuous_batching", CBGrantedSlots: 4, ChipClass: "m2_max", RAMClassGB: 96, MaxStableContextTokens: 32768}
	if hb.EngineProfile == nil || *hb.EngineProfile != want {
		t.Fatalf("engine_profile = %+v", hb.EngineProfile)
	}
	if hb, _, _, err := ParseHeartbeat([]byte(engineProfileHeartbeatBase + `}`)); err != nil || hb.EngineProfile != nil {
		t.Fatalf("absent profile: %+v err=%v", hb.EngineProfile, err)
	}
}

// SPEC-001-R006: any violation drops the profile and never rejects the
// heartbeat.
func TestParseHeartbeatDropsInvalidEngineProfileWithoutRejecting(t *testing.T) {
	for name, bad := range map[string]string{
		"unknown member":   strings.Replace(validEngineProfile, `"version"`, `"extra":1,"version"`, 1),
		"missing member":   strings.Replace(validEngineProfile, `"native_mtp_active":false,`, ``, 1),
		"unknown version":  strings.Replace(validEngineProfile, `engine-profile-v1`, `engine-profile-v2`, 1),
		"unknown family":   strings.Replace(validEngineProfile, `continuous_batching`, `lily`, 1),
		"slots range":      strings.Replace(validEngineProfile, `"cb_granted_slots":4`, `"cb_granted_slots":257`, 1),
		"negative ctx":     strings.Replace(validEngineProfile, `32768`, `-1`, 1),
		"chip class":       strings.Replace(validEngineProfile, `m2_max`, `m2_maxi`, 1),
		"chip gen":         strings.Replace(validEngineProfile, `m2_max`, `m0`, 1),
		"ram class":        strings.Replace(validEngineProfile, `"ram_class_gb":96`, `"ram_class_gb":97`, 1),
		"fractional":       strings.Replace(validEngineProfile, `"cb_granted_slots":4`, `"cb_granted_slots":4.5`, 1),
		"wrong type":       `"engine-profile-v1"`,
		"null":             `null`,
		"mtp mismatch":     strings.Replace(validEngineProfile, `"native_mtp_active":false`, `"native_mtp_active":true`, 1),
		"mtp family off":   strings.Replace(validEngineProfile, `continuous_batching`, `native_mtp`, 1),
		"plain with slots": strings.Replace(validEngineProfile, `continuous_batching`, `general_mlx`, 1),
		"oversized":        strings.Replace(validEngineProfile, `"version"`, `"pad":"`+strings.Repeat("x", 600)+`","version"`, 1),
	} {
		hb, _, field, err := ParseHeartbeat([]byte(engineProfileHeartbeatBase + `,"engine_profile":` + bad + `}`))
		if err != nil {
			t.Fatalf("%s: heartbeat rejected (field=%q err=%v)", name, field, err)
		}
		if hb.EngineProfile != nil {
			t.Fatalf("%s: profile kept: %+v", name, hb.EngineProfile)
		}
	}
	for _, chip := range []string{"unknown", "m1", "m9_pro", "m4_ultra"} {
		hb, _, _, err := ParseHeartbeat([]byte(engineProfileHeartbeatBase + `,"engine_profile":` + strings.Replace(validEngineProfile, `m2_max`, chip, 1) + `}`))
		if err != nil || hb.EngineProfile == nil {
			t.Fatalf("chip %q dropped: err=%v", chip, err)
		}
	}
}

// The registry records the profile per session and Snapshot copies it.
func TestRegistrySetEngineProfile(t *testing.T) {
	registry := pool.NewRegistry(nil)
	p := pool.Provider{ProviderID: "p1", AssignedID: "s-p1", ModelID: "model-a", State: pool.StateReady}
	registry.Register(&p, nil)
	profile := &pool.EngineProfile{Version: "engine-profile-v1", EngineFamily: "native_mtp", NativeMTPActive: true, ChipClass: "m3_max", RAMClassGB: 128}
	registry.SetEngineProfile("p1", profile)
	profile.EngineFamily = "mutated"
	snap := registry.Snapshot()
	if len(snap) != 1 || snap[0].EngineProfile == nil || snap[0].EngineProfile.EngineFamily != "native_mtp" {
		t.Fatalf("snapshot profile = %+v", snap)
	}
	registry.SetEngineProfile("p1", nil)
	if registry.Snapshot()[0].EngineProfile != nil {
		t.Fatal("nil must clear the profile")
	}
}
