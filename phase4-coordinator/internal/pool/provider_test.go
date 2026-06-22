package pool

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"
)

// TestApplyHeartbeatSwapEmitterCalledWithoutPoolLock pins the M2-2 / ARCH-2
// invariant: the swap emitter MUST NOT run while Registry.mu is held.
// The callback re-enters Registry via ModelKnown, which takes r.mu.RLock.
// sync.RWMutex is not reentrant, so under the pre-M2-2 design (emitter
// called while Lock is held) this would deadlock.
func TestApplyHeartbeatSwapEmitterCalledWithoutPoolLock(t *testing.T) {
	var (
		seenModelLookup bool
		emitterReturned = make(chan struct{})
	)
	var registry *Registry
	registry = NewRegistry(nil,
		WithHeartbeatHashVerifier(func(modelID, reportedHash string) HashStatus {
			return HashStatusVerified
		}),
		WithSwapEmitter(func(event SwapEvent) {
			defer close(emitterReturned)
			// Would deadlock under the old "emit-while-mu-locked" design.
			// Under the M2-2 design (emit after Unlock) this returns
			// promptly with the expected result.
			seenModelLookup = registry.ModelKnown(event.ToModelID)
		}),
	)
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)
	registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", true, start.Add(time.Minute)))

	done := make(chan struct{})
	go func() {
		registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-b", "hash-b", false, start.Add(2*time.Minute)))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("ApplyHeartbeat did not return — likely deadlock: emitter ran under r.mu (M2-2 regression)")
	}
	select {
	case <-emitterReturned:
	case <-time.After(time.Second):
		t.Fatal("emitter callback did not run")
	}
	if !seenModelLookup {
		t.Fatal("ModelKnown should have observed model-b after swap completion")
	}
}

// TestApplyHeartbeatSlowSwapEmitterDoesNotStallHeartbeat asserts the
// audit-store contention story from M2-2: with a slow emitter (sleep 1s),
// ApplyHeartbeat itself MUST complete within <50ms because in production
// cmd/coordinator dispatches the emitter onto a buffered channel. This
// test simulates that dispatch by using a Go channel as the emitter.
// Audit ref: PERF-2 in REPO_AUDIT.md §3.6.
func TestApplyHeartbeatSlowSwapEmitterDoesNotStallHeartbeat(t *testing.T) {
	// Production wiring (cmd/coordinator/main.go) hands the emitter a
	// non-blocking channel send. This test reproduces that pattern.
	swapCh := make(chan SwapEvent, 64)
	registry := NewRegistry(nil,
		WithHeartbeatHashVerifier(func(modelID, reportedHash string) HashStatus {
			return HashStatusVerified
		}),
		WithSwapEmitter(func(event SwapEvent) {
			select {
			case swapCh <- event:
			default:
			}
		}),
	)
	go func() {
		// Slow downstream consumer — like a busy_timeout-hit SQLite write.
		for range swapCh {
			time.Sleep(time.Second)
		}
	}()
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)
	registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", true, start.Add(time.Minute)))

	began := time.Now()
	registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-b", "hash-b", false, start.Add(2*time.Minute)))
	if elapsed := time.Since(began); elapsed > 50*time.Millisecond {
		t.Fatalf("ApplyHeartbeat took %v; want <50ms — slow emitter is back-pressuring heartbeat (M2-2 regression)", elapsed)
	}
}

func TestProviderJSONL1ByteIdenticalDefault(t *testing.T) {
	p := providerJSONL1Baseline()

	got, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("marshal provider: %v", err)
	}

	// Regenerate by running the test, copying the `got` value from the failure diff, and pasting here. Any diff against this constant for a default-zero new-field set is an L-1 regression per SPEC-001 v1.3 §6.7.3 cell 1.
	const expected = `{"provider_id":"test-provider-1","assigned_id":"p_01H000000000000000000000","hostname":"test-host","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.6,"ram_gb":16,"max_context_tokens":8192,"max_concurrency":1,"slots_free":1,"slots_total":1,"throughput_tps_estimate":42.5,"endpoint_url":"","tier":"pinned","inference_path":"ws_tunneled","admitted_at":"2026-06-07T12:00:00Z","state":"ready","last_heartbeat_at":"2026-06-07T12:05:00Z","last_activity_at":"2026-06-07T12:05:00Z","connected_at":"2026-06-07T12:00:00Z","binary_version":"1.2.4"}`
	if !bytes.Equal(got, []byte(expected)) {
		t.Fatalf("provider JSON mismatch\n got: %s\nwant: %s", got, expected)
	}

	var fields map[string]any
	if err := json.Unmarshal(got, &fields); err != nil {
		t.Fatalf("unmarshal provider json: %v", err)
	}
	for _, key := range []string{
		"supported_models",
		"publishes_supported_models",
		"last_loading_state",
		"loading_started_at",
		"LastLoadingState",
		"LoadingStartedAt",
	} {
		if _, ok := fields[key]; ok {
			t.Fatalf("default provider JSON unexpectedly included %q: %s", key, got)
		}
	}
}

func TestProviderJSONSerializesNewFieldsWhenSet(t *testing.T) {
	p := providerJSONL1Baseline()
	p.SupportedModels = []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}
	p.PublishesSupportedModels = true
	p.LastLoadingState = true
	p.LoadingStartedAt = time.Date(2026, 6, 7, 12, 4, 30, 0, time.UTC)
	p.CanaryFailCount = 2
	checkedAt := time.Date(2026, 6, 7, 12, 6, 0, 0, time.UTC)
	failedAt := time.Date(2026, 6, 7, 12, 6, 0, 0, time.UTC)
	p.CanaryLastCheckedAt = &checkedAt
	p.CanaryLastFailedAt = &failedAt

	got, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("marshal provider: %v", err)
	}

	var fields map[string]any
	if err := json.Unmarshal(got, &fields); err != nil {
		t.Fatalf("unmarshal provider json: %v", err)
	}
	models, ok := fields["supported_models"].([]any)
	if !ok || len(models) != 1 || models[0] != "mlx-community/Qwen2.5-7B-Instruct-4bit" {
		t.Fatalf("supported_models = %#v, want one model id", fields["supported_models"])
	}
	if fields["publishes_supported_models"] != true {
		t.Fatalf("publishes_supported_models = %#v, want true", fields["publishes_supported_models"])
	}
	if fields["canary_fail_count"] != float64(2) {
		t.Fatalf("canary_fail_count = %#v, want 2", fields["canary_fail_count"])
	}
	if fields["canary_last_checked_at"] != "2026-06-07T12:06:00Z" {
		t.Fatalf("canary_last_checked_at = %#v", fields["canary_last_checked_at"])
	}
	if fields["canary_last_failed_at"] != "2026-06-07T12:06:00Z" {
		t.Fatalf("canary_last_failed_at = %#v", fields["canary_last_failed_at"])
	}
	for _, key := range []string{
		"last_loading_state",
		"loading_started_at",
		"LastLoadingState",
		"LoadingStartedAt",
	} {
		if _, ok := fields[key]; ok {
			t.Fatalf("internal loading field %q leaked in provider JSON: %s", key, got)
		}
	}
}

func providerJSONL1Baseline() Provider {
	return Provider{
		ProviderID:            "test-provider-1",
		AssignedID:            "p_01H000000000000000000000",
		Hostname:              "test-host",
		ModelID:               "mlx-community/Qwen2.5-7B-Instruct-4bit",
		ModelParamsB:          7.6,
		RAMGB:                 16,
		MaxContextTokens:      8192,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 42.5,
		EndpointURL:           "",
		Tier:                  TierPinned,
		InferencePath:         InferencePathWSTunneled,
		AdmittedAt:            time.Date(2026, 6, 7, 12, 0, 0, 0, time.UTC),
		State:                 StateReady,
		LastHeartbeatAt:       time.Date(2026, 6, 7, 12, 5, 0, 0, time.UTC),
		LastActivityAt:        time.Date(2026, 6, 7, 12, 5, 0, 0, time.UTC),
		ConnectedAt:           time.Date(2026, 6, 7, 12, 0, 0, 0, time.UTC),
		BinaryVersion:         "1.2.4",
	}
}

// fix-pass-4 (PR #69): RoutingEligible is now exclusively about credential
// trust + slot availability. HashStatus filtering moved to Tier-2-aware
// buyer code (tier2ProviderExcludedStatus) so the operator-configurable
// "ignore stale mismatches when hash enforcement is disabled" semantics
// can be honored. The predicate must NOT exclude hash-mismatched providers
// unconditionally — that would make a config-disabled inactive state
// reject providers the operator chose to admit.
func TestRoutingEligibleIgnoresHashStatus(t *testing.T) {
	base := Provider{State: StateReady, SlotsFree: 1}
	if !base.RoutingEligible() {
		t.Fatal("zero hash status should preserve default routing eligibility")
	}
	if base.AttestationStatus != "" {
		t.Fatalf("zero provider attestation status = %q, want empty legacy default", base.AttestationStatus)
	}
	mismatch := base
	mismatch.HashStatus = HashStatusMismatch
	if !mismatch.RoutingEligible() {
		t.Fatal("hash_mismatch must NOT be excluded by RoutingEligible — Tier-2 hash filtering is config-aware and lives elsewhere")
	}
	invalid := base
	invalid.HashStatus = HashStatusInvalid
	if !invalid.RoutingEligible() {
		t.Fatal("hash_invalid must NOT be excluded by RoutingEligible — Tier-2 hash filtering is config-aware and lives elsewhere")
	}
	bearerless := base
	bearerless.AuthState = AuthBearerlessDuplicate
	if bearerless.RoutingEligible() {
		t.Fatal("AuthBearerlessDuplicate MUST be excluded — SPEC-003 v0.8.3 FR-C9.4 credential trust gate")
	}
}

func TestRecordCanaryResultTripsProvisionalUnavailable(t *testing.T) {
	registry := NewRegistry(nil)
	provider := &Provider{
		ProviderID:     "provisional-a",
		AssignedID:     "session-a",
		ModelID:        "model-a",
		Tier:           TierProvisional,
		State:          StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, nil)
	at := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)

	first := registry.RecordCanaryResult("provisional-a", "session-a", false, at, 3)
	if !first.Current || first.Count != 1 || first.Tripped != CanaryTripNone {
		t.Fatalf("first canary result = %+v", first)
	}
	second := registry.RecordCanaryResult("provisional-a", "session-a", false, at.Add(time.Minute), 3)
	if !second.Current || second.Count != 2 || second.Tripped != CanaryTripNone {
		t.Fatalf("second canary result = %+v", second)
	}
	third := registry.RecordCanaryResult("provisional-a", "session-a", false, at.Add(2*time.Minute), 3)
	if !third.Current || third.Count != 3 || third.Tripped != CanaryTripUnavailable || third.Tier != TierProvisional {
		t.Fatalf("third canary result = %+v", third)
	}
	got, ok := registry.Resolve("provisional-a", "session-a")
	if !ok {
		t.Fatal("provider not found")
	}
	if got.State != StateUnavailable {
		t.Fatalf("state = %q, want unavailable", got.State)
	}
	if got.CanaryFailCount != 3 {
		t.Fatalf("canary fail count = %d, want 3", got.CanaryFailCount)
	}
}

func TestRecordCanaryResultHoldsPinnedDegraded(t *testing.T) {
	registry := NewRegistry(nil)
	provider := &Provider{
		ProviderID:     "pinned-a",
		AssignedID:     "session-a",
		ModelID:        "model-a",
		Tier:           TierPinned,
		State:          StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, nil)
	at := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)

	first := registry.RecordCanaryResult("pinned-a", "session-a", false, at, 2)
	if first.Count != 1 || first.Tripped != CanaryTripNone {
		t.Fatalf("first canary result = %+v", first)
	}
	second := registry.RecordCanaryResult("pinned-a", "session-a", false, at.Add(time.Minute), 2)
	if second.Count != 2 || second.Tripped != CanaryTripDegraded || second.Tier != TierPinned {
		t.Fatalf("second canary result = %+v", second)
	}
	if ok := registry.MarkState("pinned-a", "session-a", StateReady); ok {
		t.Fatal("pinned canary hold should block coordinator ready promotion")
	}
	if _, _, ok := registry.ApplyHeartbeat("pinned-a", "session-a", HeartbeatUpdate{
		Status:     StateReady,
		ModelID:    "model-a",
		SlotsFree:  1,
		SlotsTotal: 1,
		At:         at.Add(2 * time.Minute),
	}); !ok {
		t.Fatal("heartbeat should still update telemetry while canary hold blocks ready promotion")
	}
	got, ok := registry.Resolve("pinned-a", "session-a")
	if !ok {
		t.Fatal("provider not found")
	}
	if got.State != StateDegraded {
		t.Fatalf("state = %q, want degraded", got.State)
	}

	replacement := &Provider{
		ProviderID:     "pinned-a",
		AssignedID:     "session-b",
		ModelID:        "model-a",
		Tier:           TierPinned,
		State:          StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(replacement, nil)
	reconnected, ok := registry.Resolve("pinned-a", "session-b")
	if !ok {
		t.Fatal("reconnected provider not found")
	}
	if reconnected.State != StateDegraded || reconnected.RoutingEligible() {
		t.Fatalf("reconnected canary-sanctioned provider = %+v, want degraded and unroutable", reconnected)
	}
	if reconnected.CanaryFailCount != 2 {
		t.Fatalf("reconnected canary fail count = %d, want 2", reconnected.CanaryFailCount)
	}
	if !registry.CanaryRecoveryEligible("pinned-a", "session-b") {
		t.Fatal("reconnected canary-sanctioned provider should be eligible for canary recovery probe")
	}
	if registry.MarkRecovered("pinned-a", "session-b", at.Add(3*time.Minute)) {
		t.Fatal("generic recovery must not clear canary hold")
	}
	if registry.MarkDegradedForRecovery("pinned-a", "session-b", RecoveryReasonBreaker) {
		t.Fatal("generic degraded recovery must not overwrite canary hold")
	}
	stillHeld, ok := registry.Resolve("pinned-a", "session-b")
	if !ok {
		t.Fatal("held provider not found")
	}
	if stillHeld.State != StateDegraded || !registry.CanaryRecoveryEligible("pinned-a", "session-b") {
		t.Fatalf("generic recovery changed canary hold: %+v", stillHeld)
	}

	pass := registry.RecordCanaryResult("pinned-a", "session-b", true, at.Add(3*time.Minute), 2)
	if !pass.Current || !pass.Passed || pass.Count != 0 || !pass.SanctionCleared {
		t.Fatalf("passing canary result = %+v", pass)
	}
	recovered, ok := registry.Resolve("pinned-a", "session-b")
	if !ok {
		t.Fatal("recovered provider not found")
	}
	if recovered.State != StateReady || !recovered.RoutingEligible() || recovered.CanaryFailCount != 0 {
		t.Fatalf("recovered provider = %+v, want ready/routable with fail count reset", recovered)
	}
	if registry.CanaryRecoveryEligible("pinned-a", "session-b") {
		t.Fatal("canary recovery hold should clear after passing canary")
	}

	next := &Provider{
		ProviderID:     "pinned-a",
		AssignedID:     "session-c",
		ModelID:        "model-a",
		Tier:           TierPinned,
		State:          StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(next, nil)
	nextResolved, ok := registry.Resolve("pinned-a", "session-c")
	if !ok {
		t.Fatal("next provider not found")
	}
	if nextResolved.State != StateReady || nextResolved.CanaryFailCount != 0 {
		t.Fatalf("post-recovery reconnect = %+v, want no persisted canary sanction", nextResolved)
	}
}

func TestLoadedCanarySanctionHoldsPinnedProviderAfterRestart(t *testing.T) {
	beforeRestart := NewRegistry(nil)
	provider := &Provider{
		ProviderID:     "pinned-restart",
		AssignedID:     "session-a",
		ModelID:        "model-a",
		Tier:           TierPinned,
		State:          StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	beforeRestart.Register(provider, nil)
	at := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
	beforeRestart.RecordCanaryResult("pinned-restart", "session-a", false, at, 2)
	beforeRestart.RecordCanaryResult("pinned-restart", "session-a", false, at.Add(time.Minute), 2)
	snapshots := beforeRestart.CanarySanctions()
	if len(snapshots) != 1 {
		t.Fatalf("canary sanctions = %+v, want one snapshot", snapshots)
	}

	afterRestart := NewRegistry(nil)
	afterRestart.LoadCanarySanctions(snapshots)
	reconnected := &Provider{
		ProviderID:     "pinned-restart",
		AssignedID:     "session-b",
		ModelID:        "model-a",
		Tier:           TierPinned,
		State:          StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	afterRestart.Register(reconnected, nil)
	got, ok := afterRestart.Resolve("pinned-restart", "session-b")
	if !ok {
		t.Fatal("reconnected provider not found")
	}
	if got.State != StateDegraded || got.RoutingEligible() || got.CanaryFailCount != 2 {
		t.Fatalf("reconnected persisted canary-sanctioned provider = %+v, want degraded, unroutable, count=2", got)
	}
	if !afterRestart.CanaryRecoveryEligible("pinned-restart", "session-b") {
		t.Fatal("loaded sanction should create a canary recovery hold for the new session")
	}
}

func TestStaleTerminalCanaryPassDoesNotClearSanction(t *testing.T) {
	registry := NewRegistry(nil)
	provider := &Provider{
		ProviderID:     "pinned-terminal",
		AssignedID:     "session-a",
		ModelID:        "model-a",
		Tier:           TierPinned,
		State:          StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, nil)
	at := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
	registry.RecordCanaryResult("pinned-terminal", "session-a", false, at, 1)
	if !registry.MarkState("pinned-terminal", "session-a", StateUnavailable) {
		t.Fatal("mark unavailable failed")
	}
	pass := registry.RecordCanaryResult("pinned-terminal", "session-a", true, at.Add(time.Minute), 1)
	if !pass.Current || !pass.Passed || pass.SanctionCleared {
		t.Fatalf("stale terminal pass = %+v, want current/pass without sanction clear", pass)
	}
	sanctions := registry.CanarySanctions()
	if len(sanctions) != 1 || sanctions[0].ProviderID != "pinned-terminal" {
		t.Fatalf("canary sanctions after stale pass = %+v, want retained sanction", sanctions)
	}
}

func TestCanaryPassDoesNotUndoDrain(t *testing.T) {
	registry := NewRegistry(nil)
	provider := &Provider{
		ProviderID:     "pinned-drain",
		AssignedID:     "session-a",
		ModelID:        "model-a",
		Tier:           TierPinned,
		State:          StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, nil)
	at := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)

	registry.RecordCanaryResult("pinned-drain", "session-a", false, at, 1)
	if !registry.MarkState("pinned-drain", "session-a", StateDraining) {
		t.Fatal("mark draining")
	}
	pass := registry.RecordCanaryResult("pinned-drain", "session-a", true, at.Add(time.Minute), 1)
	if !pass.Current || !pass.Passed {
		t.Fatalf("passing canary result = %+v", pass)
	}
	got, ok := registry.Resolve("pinned-drain", "session-a")
	if !ok {
		t.Fatal("provider not found")
	}
	if got.State != StateDraining || got.RoutingEligible() {
		t.Fatalf("passing canary during drain = %+v, want draining and unroutable", got)
	}
	if !registry.CanaryRecoveryEligible("pinned-drain", "session-a") {
		t.Fatal("canary hold should remain while provider is draining")
	}
}

func TestStaleCanaryFailureDoesNotOverrideDrainOrUnavailable(t *testing.T) {
	for _, terminal := range []State{StateDraining, StateUnavailable} {
		t.Run(string(terminal), func(t *testing.T) {
			registry := NewRegistry(nil)
			provider := &Provider{
				ProviderID:     "pinned-stale-" + string(terminal),
				AssignedID:     "session-a",
				ModelID:        "model-a",
				Tier:           TierPinned,
				State:          StateReady,
				SlotsFree:      1,
				SlotsTotal:     1,
				MaxConcurrency: 1,
			}
			registry.Register(provider, nil)
			at := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
			if !registry.MarkState(provider.ProviderID, provider.AssignedID, terminal) {
				t.Fatalf("mark %s", terminal)
			}

			result := registry.RecordCanaryResult(provider.ProviderID, provider.AssignedID, false, at, 1)
			if !result.Current || result.Count != 0 || result.Tripped != CanaryTripNone {
				t.Fatalf("stale canary result after %s = %+v", terminal, result)
			}
			got, ok := registry.Resolve(provider.ProviderID, provider.AssignedID)
			if !ok {
				t.Fatal("provider not found")
			}
			if got.State != terminal || got.CanaryFailCount != 0 || registry.CanaryRecoveryEligible(provider.ProviderID, provider.AssignedID) {
				t.Fatalf("stale canary failure changed terminal state: %+v", got)
			}
		})
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

func TestApplyHeartbeatL1ByteIdenticalLegacyPath(t *testing.T) {
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)

	provider, _, ok := registry.ApplyHeartbeat("p1", "current", heartbeatUpdateAt("model-a", start.Add(time.Minute)))
	if !ok {
		t.Fatal("heartbeat not applied")
	}
	if provider.ModelHash != "hash-a" || provider.HashStatus != HashStatusVerified {
		t.Fatalf("legacy unchanged hash state = (%q, %q)", provider.ModelHash, provider.HashStatus)
	}
	if provider.LastLoadingState {
		t.Fatal("LastLoadingState changed on absent loading")
	}
	if !provider.LoadingStartedAt.IsZero() {
		t.Fatalf("LoadingStartedAt = %s, want zero", provider.LoadingStartedAt)
	}

	provider, _, ok = registry.ApplyHeartbeat("p1", "current", heartbeatUpdateAt("model-b", start.Add(2*time.Minute)))
	if !ok {
		t.Fatal("second heartbeat not applied")
	}
	if provider.ModelHash != "" || provider.HashStatus != HashStatusUncatalogued {
		t.Fatalf("legacy model change hash state = (%q, %q), want cleared uncatalogued", provider.ModelHash, provider.HashStatus)
	}
}

func TestApplyHeartbeatSPEC011PathUpdatesHashOnModelIDChange(t *testing.T) {
	registry := NewRegistry(nil, WithHeartbeatHashVerifier(func(modelID, reportedHash string) HashStatus {
		return HashStatusVerified
	}))
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusMismatch, start)

	provider, _, ok := registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-b", "ab12", false, start.Add(time.Minute)))
	if !ok {
		t.Fatal("heartbeat not applied")
	}
	if provider.ModelHash != "ab12" || provider.HashStatus != HashStatusVerified {
		t.Fatalf("SPEC-011 model change hash state = (%q, %q)", provider.ModelHash, provider.HashStatus)
	}
}

func TestApplyHeartbeatSPEC011PathReVerifiesOnHashChangeSameModelID(t *testing.T) {
	registry := NewRegistry(nil, WithHeartbeatHashVerifier(func(modelID, reportedHash string) HashStatus {
		return HashStatusMismatch
	}))
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)

	provider, _, ok := registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-b", false, start.Add(time.Minute)))
	if !ok {
		t.Fatal("heartbeat not applied")
	}
	if provider.ModelHash != "hash-b" || provider.HashStatus != HashStatusMismatch {
		t.Fatalf("SPEC-011 same-model hash state = (%q, %q)", provider.ModelHash, provider.HashStatus)
	}
}

func TestApplyHeartbeatSPEC011PathNoChangeWhenBothModelIDAndHashUnchanged(t *testing.T) {
	verifierCalls := 0
	registry := NewRegistry(nil, WithHeartbeatHashVerifier(func(modelID, reportedHash string) HashStatus {
		verifierCalls++
		return HashStatusMismatch
	}))
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)

	provider, _, ok := registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", false, start.Add(time.Minute)))
	if !ok {
		t.Fatal("heartbeat not applied")
	}
	if verifierCalls != 0 {
		t.Fatalf("verifierCalls = %d, want 0", verifierCalls)
	}
	if provider.ModelHash != "hash-a" || provider.HashStatus != HashStatusVerified {
		t.Fatalf("unchanged SPEC-011 hash state = (%q, %q)", provider.ModelHash, provider.HashStatus)
	}
}

func TestApplyHeartbeatPathSelectionIsPerHeartbeatNotSticky(t *testing.T) {
	registry := NewRegistry(nil, WithHeartbeatHashVerifier(func(modelID, reportedHash string) HashStatus {
		return HashStatusVerified
	}))
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusMismatch, start)

	if provider, _, ok := registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-b", false, start.Add(time.Minute))); !ok || provider.ModelHash != "hash-b" || provider.HashStatus != HashStatusVerified {
		t.Fatalf("frame #1 provider=%+v ok=%v", provider, ok)
	}
	provider, _, ok := registry.ApplyHeartbeat("p1", "current", heartbeatUpdateAt("model-b", start.Add(2*time.Minute)))
	if !ok {
		t.Fatal("frame #2 heartbeat not applied")
	}
	if provider.ModelHash != "" || provider.HashStatus != HashStatusUncatalogued {
		t.Fatalf("frame #2 hash state = (%q, %q), want legacy clear", provider.ModelHash, provider.HashStatus)
	}
	// Frame #3 — SPEC-011 re-entry after the LEGACY clear. Per AC-K.8,
	// path selection is per-heartbeat and presence-keyed: a binary that
	// re-includes model_hash MUST re-take the SPEC-011 path, updating
	// the hash and re-invoking the verifier even though frame #2 had
	// cleared the prior hash via the LEGACY path.
	provider, _, ok = registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-c", "hash-c", false, start.Add(3*time.Minute)))
	if !ok {
		t.Fatal("frame #3 heartbeat not applied")
	}
	if provider.ModelHash != "hash-c" || provider.HashStatus != HashStatusVerified {
		t.Fatalf("frame #3 hash state = (%q, %q), want SPEC-011 repopulation", provider.ModelHash, provider.HashStatus)
	}
}

// TestApplyHeartbeatSwapEmitterDoesNotFireWhenModelIDUnchanged
// regression-pins the [sec:1.1] R2 closure: a malicious provider
// that pulses loading:true → loading:false on the SAME model_id
// (forged or genuine same-model re-load) MUST NOT fire the
// operator_model_swap emitter. SPEC-002 v1.3.5 §7.10 R-7.10.6 gates
// emission on "loading:false carrying the NEW model_id".
func TestApplyHeartbeatSwapEmitterDoesNotFireWhenModelIDUnchanged(t *testing.T) {
	called := false
	registry := NewRegistry(nil,
		WithHeartbeatHashVerifier(func(modelID, reportedHash string) HashStatus {
			return HashStatusVerified
		}),
		WithSwapEmitter(func(event SwapEvent) {
			called = true
		}),
	)
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)

	registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", true, start.Add(time.Minute)))
	registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", false, start.Add(2*time.Minute)))
	if called {
		t.Fatal("emitter fired on a same-model loading pulse")
	}
}

func TestApplyHeartbeatLoadingStartedAtStampedOnFalseToTrueTransition(t *testing.T) {
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)
	first := start.Add(time.Minute)
	second := start.Add(2 * time.Minute)

	provider, _, ok := registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", true, first))
	if !ok {
		t.Fatal("first heartbeat not applied")
	}
	if !provider.LoadingStartedAt.Equal(first) {
		t.Fatalf("LoadingStartedAt = %s, want %s", provider.LoadingStartedAt, first)
	}
	provider, _, ok = registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", true, second))
	if !ok {
		t.Fatal("second heartbeat not applied")
	}
	if !provider.LoadingStartedAt.Equal(first) {
		t.Fatalf("LoadingStartedAt restamped to %s, want %s", provider.LoadingStartedAt, first)
	}
}

func TestApplyHeartbeatLastLoadingStateTracksPerHeartbeat(t *testing.T) {
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)

	for i, loading := range []bool{true, true, false, false} {
		provider, _, ok := registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", loading, start.Add(time.Duration(i+1)*time.Minute)))
		if !ok {
			t.Fatalf("heartbeat %d not applied", i)
		}
		if provider.LastLoadingState != loading {
			t.Fatalf("heartbeat %d LastLoadingState = %v, want %v", i, provider.LastLoadingState, loading)
		}
	}
}

func TestApplyHeartbeatLoadingAbsentLeavesStateUntouched(t *testing.T) {
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)

	for i := 1; i <= 3; i++ {
		provider, _, ok := registry.ApplyHeartbeat("p1", "current", heartbeatUpdateAt("model-a", start.Add(time.Duration(i)*time.Minute)))
		if !ok {
			t.Fatalf("heartbeat %d not applied", i)
		}
		if provider.LastLoadingState || !provider.LoadingStartedAt.IsZero() {
			t.Fatalf("heartbeat %d loading state = (%v, %s), want zero", i, provider.LastLoadingState, provider.LoadingStartedAt)
		}
	}
}

func TestApplyHeartbeatSwapEmitterFiresOnPostSwapTransition(t *testing.T) {
	var events []SwapEvent
	registry := NewRegistry(nil,
		WithHeartbeatHashVerifier(func(modelID, reportedHash string) HashStatus {
			return HashStatusVerified
		}),
		WithSwapEmitter(func(event SwapEvent) {
			events = append(events, event)
		}),
	)
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)
	loadingAt := start.Add(time.Minute)
	completedAt := start.Add(2 * time.Minute)

	registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", true, loadingAt))
	registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-b", "hash-b", false, completedAt))

	if len(events) != 1 {
		t.Fatalf("events = %d, want 1", len(events))
	}
	event := events[0]
	if event.ProviderID != "p1" || event.AssignedID != "current" || event.FromModelID != "model-a" || event.FromModelHash != "hash-a" || event.ToModelID != "model-b" || event.ToModelHash != "hash-b" || event.HashVerificationResult != HashStatusVerified || !event.LoadingStartedAt.Equal(loadingAt) || !event.CompletedAt.Equal(completedAt) {
		t.Fatalf("event = %+v", event)
	}
}

func TestApplyHeartbeatSwapEmitterDoesNotFireOnLegacyPath(t *testing.T) {
	called := false
	registry := NewRegistry(nil, WithSwapEmitter(func(event SwapEvent) {
		called = true
	}))
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)

	registry.ApplyHeartbeat("p1", "current", legacyLoadingHeartbeatUpdate("model-a", true, start.Add(time.Minute)))
	registry.ApplyHeartbeat("p1", "current", legacyLoadingHeartbeatUpdate("model-b", false, start.Add(2*time.Minute)))
	if called {
		t.Fatal("emitter fired on legacy path")
	}
}

func TestApplyHeartbeatSwapEmitterDoesNotFireWhenNoPriorLoading(t *testing.T) {
	called := false
	registry := NewRegistry(nil, WithSwapEmitter(func(event SwapEvent) {
		called = true
	}))
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)

	registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", false, start.Add(time.Minute)))
	registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-b", "hash-b", false, start.Add(2*time.Minute)))
	if called {
		t.Fatal("emitter fired without prior loading")
	}
}

// TestModelKnownShrinksOnProviderDisconnect pins the M2-5 / PERF-5
// guarantee: ModelKnown answers from currently-connected providers only.
// Pre-M2-5 the registry-wide seenModels map accumulated forever — a
// 31-day model id observed once still answered true 1y later.
func TestModelKnownShrinksOnProviderDisconnect(t *testing.T) {
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()

	registry.Register(&Provider{
		ProviderID:       "p1",
		AssignedID:       "s1",
		ModelID:          "model-a",
		State:            StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		LastHeartbeatAt:  start,
		LastActivityAt:   start,
		MaxConcurrency:   1,
		MaxContextTokens: 20000,
	}, nil)

	if !registry.ModelKnown("model-a") {
		t.Fatal("ModelKnown(model-a) = false while p1 is connected reporting it")
	}
	// Heartbeat with a different model id — that model is also seen.
	registry.ApplyHeartbeat("p1", "s1", heartbeatUpdateAt("model-b", start.Add(time.Minute)))
	if !registry.ModelKnown("model-b") {
		t.Fatal("ModelKnown(model-b) = false after p1 reported it via heartbeat")
	}
	// model-a should still be remembered (p1 reported it earlier this session).
	if !registry.ModelKnown("model-a") {
		t.Fatal("ModelKnown(model-a) = false; per-session memory regressed")
	}
	// Disconnect p1 — both models it ever reported should drop from the
	// global view.
	if !registry.RemoveIfSession("p1", "s1") {
		t.Fatal("RemoveIfSession returned false")
	}
	if registry.ModelKnown("model-a") {
		t.Fatal("ModelKnown(model-a) still true after the only provider serving it disconnected — leak (PERF-5)")
	}
	if registry.ModelKnown("model-b") {
		t.Fatal("ModelKnown(model-b) still true after the only provider serving it disconnected — leak (PERF-5)")
	}
}

// TestRegisterReplaceSessionClearsSeenModels pins the M2-5 / PERF-5 fix for the
// codex code-audit 2026-06-11 #47 finding: a session replacement (same
// provider_id, new assigned_id) MUST clear the per-provider seen-model
// history, else stale model ids from the prior session survive into the
// new one and ModelKnown over-reports.
func TestRegisterReplaceSessionClearsSeenModels(t *testing.T) {
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()

	// Session 1: register p1@s1 reporting model-a, heartbeat in model-b.
	registry.Register(&Provider{
		ProviderID:       "p1",
		AssignedID:       "s1",
		ModelID:          "model-a",
		State:            StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		LastHeartbeatAt:  start,
		LastActivityAt:   start,
		MaxConcurrency:   1,
		MaxContextTokens: 20000,
	}, nil)
	registry.ApplyHeartbeat("p1", "s1", heartbeatUpdateAt("model-b", start.Add(time.Minute)))
	if !registry.ModelKnown("model-a") || !registry.ModelKnown("model-b") {
		t.Fatal("session-1 seen models not recorded")
	}

	// Session 2 replaces session 1 with a different model entirely.
	// (Same provider_id, new assigned_id — the direct-replacement path
	// inside Register, not the RemoveIfSession path.)
	registry.Register(&Provider{
		ProviderID:       "p1",
		AssignedID:       "s2",
		ModelID:          "model-c",
		State:            StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		LastHeartbeatAt:  start.Add(2 * time.Minute),
		LastActivityAt:   start.Add(2 * time.Minute),
		MaxConcurrency:   1,
		MaxContextTokens: 20000,
	}, nil)
	if !registry.ModelKnown("model-c") {
		t.Fatal("session-2 model not recorded after replacement")
	}
	if registry.ModelKnown("model-a") {
		t.Fatal("ModelKnown(model-a) leaked across session replacement; prior history should be cleared")
	}
	if registry.ModelKnown("model-b") {
		t.Fatal("ModelKnown(model-b) leaked across session replacement; prior history should be cleared")
	}
}

// TestSeenModelsCappedPerProvider pins the M2-5 / PERF-5 per-provider cap.
// A single misbehaving provider cannot grow its inner set without bound.
func TestSeenModelsCappedPerProvider(t *testing.T) {
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()
	registry.Register(&Provider{
		ProviderID:       "p1",
		AssignedID:       "s1",
		ModelID:          "model-0",
		State:            StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		LastHeartbeatAt:  start,
		LastActivityAt:   start,
		MaxConcurrency:   1,
		MaxContextTokens: 20000,
	}, nil)
	// Drive the per-provider set well past the cap with 200 distinct model ids.
	for i := 0; i < 200; i++ {
		modelID := "model-" + itoaForTest(i)
		registry.ApplyHeartbeat("p1", "s1", heartbeatUpdateAt(modelID, start.Add(time.Duration(i+1)*time.Second)))
	}
	registry.mu.RLock()
	got := len(registry.seenModelsByProvider["p1"])
	registry.mu.RUnlock()
	if got > maxSeenModelsPerProvider {
		t.Fatalf("seenModelsByProvider[p1] = %d entries, want <= %d (cap)", got, maxSeenModelsPerProvider)
	}
}

func TestApplyHeartbeatSwapEmitterNilDoesNotCrash(t *testing.T) {
	registry := NewRegistry(nil)
	start := time.Unix(1716768000, 0).UTC()
	registerHeartbeatProvider(t, registry, "model-a", "hash-a", HashStatusVerified, start)

	registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-a", "hash-a", true, start.Add(time.Minute)))
	if _, _, ok := registry.ApplyHeartbeat("p1", "current", spec011HeartbeatUpdate("model-b", "hash-b", false, start.Add(2*time.Minute))); !ok {
		t.Fatal("swap completion heartbeat not applied")
	}
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

// itoaForTest is a tiny stdlib-free integer-to-string for test loops
// that need distinct model ids. The pool package already avoids strconv;
// keep that style here.
func itoaForTest(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

func registerHeartbeatProvider(t *testing.T, registry *Registry, modelID, modelHash string, hashStatus HashStatus, at time.Time) {
	t.Helper()
	registry.Register(&Provider{
		ProviderID:            "p1",
		AssignedID:            "current",
		ModelID:               modelID,
		ModelHash:             modelHash,
		HashStatus:            hashStatus,
		State:                 StateReady,
		SlotsFree:             1,
		SlotsTotal:            1,
		LastHeartbeatAt:       at,
		LastActivityAt:        at,
		MaxConcurrency:        1,
		MaxContextTokens:      20000,
		ThroughputTPSEstimate: 20,
	}, nil)
}

func heartbeatUpdateAt(modelID string, at time.Time) HeartbeatUpdate {
	return HeartbeatUpdate{
		Status:                StateReady,
		ModelID:               modelID,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		At:                    at,
	}
}

func spec011HeartbeatUpdate(modelID, modelHash string, loading bool, at time.Time) HeartbeatUpdate {
	update := heartbeatUpdateAt(modelID, at)
	update.ModelHash = modelHash
	update.ModelHashPresent = true
	update.Loading = loading
	update.LoadingPresent = true
	return update
}

func legacyLoadingHeartbeatUpdate(modelID string, loading bool, at time.Time) HeartbeatUpdate {
	update := heartbeatUpdateAt(modelID, at)
	update.Loading = loading
	update.LoadingPresent = true
	return update
}

// TestRegistryRefusesBearerlessDuplicateReplacement directly exercises the
// pool.Registry eviction defense layer (SPEC-003 v0.8.3 fix-pass-3 codex
// security MAJOR-1). Under v0.8.4 composition this layer is reached only
// via the IssueToken race-loss path, but the layer must still refuse the
// replacement deterministically. Doesn't depend on the WS handler so the
// branch is unambiguously exercised regardless of the composed wire
// contract.
func TestRegistryRefusesBearerlessDuplicateReplacement(t *testing.T) {
	registry := NewRegistry(nil)
	existing := &Provider{
		ProviderID: "claimed-provider",
		AssignedID: "session-legitimate",
		ModelID:    "model-a",
		State:      StateReady,
		SlotsFree:  1,
		SlotsTotal: 1,
		AuthState:  AuthBearerValidated,
	}
	if _, ok := registry.Register(existing, nil); !ok {
		t.Fatal("legitimate Bearer-validated session: initial Register must succeed")
	}
	incoming := &Provider{
		ProviderID: "claimed-provider",
		AssignedID: "session-attacker",
		ModelID:    "model-a",
		State:      StateReady,
		SlotsFree:  1,
		SlotsTotal: 1,
		AuthState:  AuthBearerlessDuplicate,
	}
	old, ok := registry.Register(incoming, nil)
	if ok {
		t.Fatalf("registry.Register(bearer-less duplicate) = (old=%v, ok=true), want (nil, false)", old)
	}
	if old != nil {
		t.Fatalf("registry.Register(bearer-less duplicate) returned old=%v, want nil (no replacement should have happened)", old)
	}
	resolved, found := registry.Resolve("claimed-provider", "session-legitimate")
	if !found {
		t.Fatal("legitimate session resolution failed; eviction defense did not protect it")
	}
	if resolved.AssignedID != "session-legitimate" {
		t.Fatalf("resolved.AssignedID = %q, want session-legitimate (AuthBearerlessDuplicate must not replace)", resolved.AssignedID)
	}
}

// TestRegistryRefusesNonBearerReplacementOfRoutableBearerValidated directly
// exercises the proven-session protection layer added in SPEC-003 v0.8.4
// fix-pass-5 (codex security MAJOR-2). An incoming AuthSelfMinted session
// MUST NOT be allowed to last-writer-wins evict an existing routable
// AuthBearerValidated session, because that would let a concurrent
// tokenless self-heal race displace a legitimate Bearer-validated provider.
func TestRegistryRefusesNonBearerReplacementOfRoutableBearerValidated(t *testing.T) {
	registry := NewRegistry(nil)
	existing := &Provider{
		ProviderID: "claimed-provider",
		AssignedID: "session-legitimate",
		ModelID:    "model-a",
		State:      StateReady,
		SlotsFree:  1,
		SlotsTotal: 1,
		AuthState:  AuthBearerValidated,
	}
	if _, ok := registry.Register(existing, nil); !ok {
		t.Fatal("legitimate Bearer-validated session: initial Register must succeed")
	}
	incoming := &Provider{
		ProviderID: "claimed-provider",
		AssignedID: "session-self-mint",
		ModelID:    "model-a",
		State:      StateReady,
		SlotsFree:  1,
		SlotsTotal: 1,
		AuthState:  AuthSelfMinted,
	}
	old, ok := registry.Register(incoming, nil)
	if ok {
		t.Fatalf("registry.Register(self-minted) over existing AuthBearerValidated = (old=%v, ok=true), want (nil, false)", old)
	}
	if old != nil {
		t.Fatalf("registry.Register(self-minted) returned old=%v, want nil", old)
	}
	resolved, found := registry.Resolve("claimed-provider", "session-legitimate")
	if !found || resolved.AssignedID != "session-legitimate" {
		t.Fatal("legitimate Bearer-validated session was displaced by AuthSelfMinted; fix-pass-5 proven-session protection failed")
	}

	// Conversely: a NEW Bearer-validated incoming SHOULD be allowed to
	// replace (legitimate provider reconnect with a valid Bearer is
	// always trusted).
	bearerReplacement := &Provider{
		ProviderID: "claimed-provider",
		AssignedID: "session-rebearer",
		ModelID:    "model-a",
		State:      StateReady,
		SlotsFree:  1,
		SlotsTotal: 1,
		AuthState:  AuthBearerValidated,
	}
	_, ok = registry.Register(bearerReplacement, nil)
	if !ok {
		t.Fatal("legitimate AuthBearerValidated reconnect MUST be allowed to replace an existing AuthBearerValidated session")
	}
}
