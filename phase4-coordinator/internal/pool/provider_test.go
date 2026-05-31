package pool

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"
)

func TestRoutingEligibleExcludesHashMismatchAndInvalid(t *testing.T) {
	base := Provider{State: StateReady, SlotsFree: 1}
	if !base.RoutingEligible() {
		t.Fatal("zero hash status should preserve default routing eligibility")
	}
	if base.AttestationStatus != "" {
		t.Fatalf("zero provider attestation status = %q, want empty legacy default", base.AttestationStatus)
	}
	mismatch := base
	mismatch.HashStatus = HashStatusMismatch
	if mismatch.RoutingEligible() {
		t.Fatal("hash_mismatch provider should not be routing eligible")
	}
	invalid := base
	invalid.HashStatus = HashStatusInvalid
	if invalid.RoutingEligible() {
		t.Fatal("hash_invalid provider should not be routing eligible")
	}
}

func TestProviderTier2SessionIsNotSerialized(t *testing.T) {
	provider := Provider{
		ProviderID:            "provider-a",
		AssignedID:            "session-a",
		ModelID:               "model-a",
		State:                 StateReady,
		SlotsFree:             1,
		EncryptedLeg:          true,
		AttestationStatus:     AttestationStatusAttested,
		MaxConcurrency:        1,
		MaxContextTokens:      20000,
		ThroughputTPSEstimate: 20,
		Tier2Session: &Tier2Session{
			AEADSuite: "A256GCM",
			C2PKey:    []byte("secret-c2p-key-material"),
			P2CKey:    []byte("secret-p2c-key-material"),
			KeyID:     "kid-1",
			StartedAt: time.Unix(1716768000, 0).UTC(),
		},
	}

	raw, err := json.Marshal(provider)
	if err != nil {
		t.Fatalf("marshal provider: %v", err)
	}
	if !bytes.Contains(raw, []byte(`"encrypted_leg":true`)) || !bytes.Contains(raw, []byte(`"attestation_status":"attested"`)) {
		t.Fatalf("tier2 public metadata missing from provider JSON: %s", string(raw))
	}
	if bytes.Contains(raw, []byte("secret-")) || bytes.Contains(raw, []byte("Tier2Session")) || bytes.Contains(raw, []byte("kid-1")) {
		t.Fatalf("tier2 session material leaked in provider JSON: %s", string(raw))
	}
}

func TestHeartbeatModelChangeClearsHashEvidence(t *testing.T) {
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()
	registry.Register(&Provider{
		ProviderID:       "p1",
		AssignedID:       "current",
		ModelID:          "model-a",
		ModelHash:        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		HashStatus:       HashStatusVerified,
		State:            StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		LastHeartbeatAt:  start,
		LastActivityAt:   start,
		MaxConcurrency:   1,
		MaxContextTokens: 20000,
	}, nil)

	provider, _, ok := registry.ApplyHeartbeat("p1", "current", HeartbeatUpdate{
		Status:           StateReady,
		ModelID:          "model-b",
		SlotsFree:        1,
		SlotsTotal:       1,
		At:               start.Add(time.Minute),
		MaxContextTokens: 20000,
	})
	if !ok {
		t.Fatal("heartbeat not applied")
	}
	if provider.ModelHash != "" || provider.HashStatus != HashStatusUncatalogued {
		t.Fatalf("hash evidence = (%q, %q), want cleared uncatalogued", provider.ModelHash, provider.HashStatus)
	}
}

func TestRegistryRejectsStaleAssignedIDUpdates(t *testing.T) {
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()
	registry.Register(&Provider{
		ProviderID:       "p1",
		AssignedID:       "current",
		ModelID:          "model-a",
		State:            StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		LastHeartbeatAt:  start,
		LastActivityAt:   start,
		MaxConcurrency:   1,
		MaxContextTokens: 20000,
	}, nil)

	if _, _, ok := registry.ApplyHeartbeat("p1", "stale", HeartbeatUpdate{
		Status:     StateUnavailable,
		ModelID:    "model-a",
		SlotsFree:  0,
		SlotsTotal: 1,
		At:         start.Add(time.Minute),
	}); ok {
		t.Fatal("stale heartbeat applied")
	}
	assertProviderReady(t, registry, start)

	if _, ok := registry.ApplyStateUpdate("p1", "stale", StateUpdate{State: StateUnavailable}); ok {
		t.Fatal("stale state update applied")
	}
	assertProviderReady(t, registry, start)

	registry.Touch("p1", "stale", start.Add(2*time.Minute))
	assertProviderReady(t, registry, start)

	registry.Touch("p1", "current", start.Add(3*time.Minute))
	provider, ok := registry.Resolve("p1", "current")
	if !ok {
		t.Fatal("provider not found")
	}
	if _, ok := registry.Resolve("p1", "stale"); ok {
		t.Fatal("stale assigned_id resolved active provider")
	}
	if !provider.LastActivityAt.Equal(start.Add(3 * time.Minute)) {
		t.Fatalf("last_activity_at = %s, want current-session touch", provider.LastActivityAt)
	}
}

func TestProviderCannotEscapeBreakerHoldViaDrainingLaundering(t *testing.T) {
	// Regression (security HIGH, 2026-05-30 audit): a breaker-held provider
	// MUST NOT be able to launder itself back to `ready` by self-reporting
	// `draining` (which would clear the hold via applyStateCleanupLocked) and
	// then `ready`. Only a fresh Register or a coordinator MarkRecovered clears
	// a coordinator-owned hold.
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()
	registry.Register(&Provider{
		ProviderID:       "p1",
		AssignedID:       "current",
		ModelID:          "model-a",
		State:            StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		LastHeartbeatAt:  start,
		LastActivityAt:   start,
		MaxConcurrency:   1,
		MaxContextTokens: 20000,
	}, nil)

	if !registry.MarkDegradedForRecovery("p1", "current", RecoveryReasonBreaker) {
		t.Fatal("failed to set breaker recovery hold")
	}

	assertState := func(label string, want State) {
		t.Helper()
		p, ok := registry.Resolve("p1", "current")
		if !ok {
			t.Fatalf("%s: provider not found", label)
		}
		if p.State != want {
			t.Fatalf("%s: state = %s, want %s", label, p.State, want)
		}
	}

	// Exploit attempt via state_update: draining (would clear the hold) -> ready.
	registry.ApplyStateUpdate("p1", "current", StateUpdate{State: StateDraining})
	assertState("state_update draining while held", StateDegraded)
	registry.ApplyStateUpdate("p1", "current", StateUpdate{State: StateReady})
	assertState("state_update ready while held", StateDegraded)

	// Exploit attempt via heartbeat status: draining -> ready.
	registry.ApplyHeartbeat("p1", "current", HeartbeatUpdate{Status: StateDraining, ModelID: "model-a", SlotsFree: 1, SlotsTotal: 1, At: start.Add(time.Minute)})
	assertState("heartbeat draining while held", StateDegraded)
	registry.ApplyHeartbeat("p1", "current", HeartbeatUpdate{Status: StateReady, ModelID: "model-a", SlotsFree: 1, SlotsTotal: 1, At: start.Add(2 * time.Minute)})
	assertState("heartbeat ready while held", StateDegraded)

	// Exploit attempt via drain_status: a provider-sent drain_status routes
	// through the coordinator MarkState(draining) path. That path must NOT clear
	// the hold, so a follow-up `ready` (state_update or heartbeat) cannot make
	// the provider routable again.
	registry.MarkState("p1", "current", StateDraining)
	registry.ApplyStateUpdate("p1", "current", StateUpdate{State: StateReady})
	if p, _ := registry.Resolve("p1", "current"); p.State == StateReady {
		t.Fatal("drain_status laundering (state_update): provider reached ready while held")
	}
	registry.ApplyHeartbeat("p1", "current", HeartbeatUpdate{Status: StateReady, ModelID: "model-a", SlotsFree: 1, SlotsTotal: 1, At: start.Add(150 * time.Second)})
	if p, _ := registry.Resolve("p1", "current"); p.State == StateReady {
		t.Fatal("drain_status laundering (heartbeat): provider reached ready while held")
	}

	// Positive control: coordinator-driven recovery is still the only way back,
	// and it proves the hold was genuinely present the whole time.
	if !registry.MarkRecovered("p1", "current", start.Add(3*time.Minute)) {
		t.Fatal("MarkRecovered failed; hold should have been present")
	}
	assertState("after coordinator MarkRecovered", StateReady)
}

func assertProviderReady(t *testing.T, registry *Registry, lastActivityAt time.Time) {
	t.Helper()
	provider, ok := registry.Resolve("p1", "current")
	if !ok {
		t.Fatal("provider not found")
	}
	if provider.State != StateReady || provider.SlotsFree != 1 || !provider.LastActivityAt.Equal(lastActivityAt) {
		t.Fatalf("provider = %#v, want ready unchanged with last_activity_at %s", provider, lastActivityAt)
	}
}
