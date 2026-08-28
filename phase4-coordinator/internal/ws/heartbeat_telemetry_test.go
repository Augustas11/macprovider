package ws

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// fakeHardwareProfileRefresher records every RefreshProviderHardwareProfile
// call and signals doneCh so async tests do not need a sleep-based wait.
type fakeHardwareProfileRefresher struct {
	mu      sync.Mutex
	calls   []hardwareProfileRefreshCall
	doneCh  chan struct{}
	failErr error
}

type hardwareProfileRefreshCall struct {
	providerID string
	appVersion string
	observedAt time.Time
}

func (f *fakeHardwareProfileRefresher) RefreshProviderHardwareProfile(_ context.Context, providerID, appVersion string, observedAt time.Time) error {
	f.mu.Lock()
	f.calls = append(f.calls, hardwareProfileRefreshCall{providerID, appVersion, observedAt})
	f.mu.Unlock()
	if f.doneCh != nil {
		f.doneCh <- struct{}{}
	}
	return f.failErr
}

func (f *fakeHardwareProfileRefresher) snapshot() []hardwareProfileRefreshCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]hardwareProfileRefreshCall(nil), f.calls...)
}

// fakeAutoupdateOutcomeSink records every RecordAutoupdateOutcome call.
type fakeAutoupdateOutcomeSink struct {
	mu     sync.Mutex
	calls  []onboarding.AutoupdateOutcomeRecord
	doneCh chan struct{}
}

func (f *fakeAutoupdateOutcomeSink) RecordAutoupdateOutcome(_ context.Context, rec onboarding.AutoupdateOutcomeRecord) error {
	f.mu.Lock()
	f.calls = append(f.calls, rec)
	f.mu.Unlock()
	if f.doneCh != nil {
		f.doneCh <- struct{}{}
	}
	return nil
}

func (f *fakeAutoupdateOutcomeSink) snapshot() []onboarding.AutoupdateOutcomeRecord {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]onboarding.AutoupdateOutcomeRecord(nil), f.calls...)
}

func waitOrTimeout(t *testing.T, ch chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for async telemetry dispatch")
	}
}

// Epic #1235 Child B / B1: a heartbeat refreshes the durable
// provider_hardware_profiles row's freshness + reported version, using the
// binary version already known from this connection's Hello (heartbeat itself
// carries no binary_version field). It is observe-only: the refresher signature
// carries NO chip/memory, so a heartbeat can never mutate the trust-relevant
// hardware-identity columns (which would trip the migration-019 verified-clear
// trigger and affect admission).
func TestHeartbeatRefreshesHardwareProfile(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	refresher := &fakeHardwareProfileRefresher{doneCh: make(chan struct{}, 1)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithHardwareProfileRefresher(refresher))
	server.hardwareProfileRefreshSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	// Even a heartbeat that DOES carry a hardware_summary must not forward chip/ram
	// to the refresh — the refresher only ever receives providerID/appVersion.
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":32,"max_context_tokens":32768,"max_concurrency":4,"slots_free":4,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0,"hardware_summary":{"chip":"Apple M3 Max","gpu_cores_total":40,"cpu_cores_total":16}}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
	waitOrTimeout(t, refresher.doneCh)

	calls := refresher.snapshot()
	if len(calls) != 1 {
		t.Fatalf("refresh calls = %d, want 1", len(calls))
	}
	got := calls[0]
	if got.providerID != "provider-a" {
		t.Errorf("providerID = %q, want provider-a", got.providerID)
	}
	// capacityTestHello sets BinaryVersion "1.8.48"; the heartbeat wire itself
	// has no binary_version field, so this must come from the pool entry's
	// value learned at Hello.
	if got.appVersion != "1.8.48" {
		t.Errorf("appVersion = %q, want the Hello-reported binary version 1.8.48", got.appVersion)
	}
}

// A heartbeat with no hardware_summary still refreshes freshness + binary
// version (the refresh never depended on hardware fields).
func TestHeartbeatRefreshesHardwareProfileWithoutHardwareSummary(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	refresher := &fakeHardwareProfileRefresher{doneCh: make(chan struct{}, 1)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithHardwareProfileRefresher(refresher))
	server.hardwareProfileRefreshSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":4,"slots_free":4,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
	waitOrTimeout(t, refresher.doneCh)

	calls := refresher.snapshot()
	if len(calls) != 1 {
		t.Fatalf("refresh calls = %d, want 1", len(calls))
	}
	if calls[0].appVersion != "1.8.48" {
		t.Errorf("appVersion = %q, want 1.8.48", calls[0].appVersion)
	}
}

// The refresh is throttled per provider: a second heartbeat within the
// interval must not dispatch another Postgres write.
func TestHeartbeatHardwareProfileRefreshIsThrottled(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	refresher := &fakeHardwareProfileRefresher{doneCh: make(chan struct{}, 4)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithHardwareProfileRefresher(refresher))
	server.hardwareProfileRefreshSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":4,"slots_free":4,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
	waitOrTimeout(t, refresher.doneCh)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)

	// Give any (incorrect) second dispatch a moment to land before asserting
	// it did not.
	time.Sleep(50 * time.Millisecond)
	if calls := refresher.snapshot(); len(calls) != 1 {
		t.Fatalf("refresh calls = %d, want 1 (throttled)", len(calls))
	}
}

// No refresher wired (nil) must be a no-op, not a panic — the default
// pre-Child-B behavior.
func TestHeartbeatHardwareProfileRefreshNilIsNoop(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop())
	registerCapacityTestProvider(t, server, registry, 4)

	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":4,"slots_free":4,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
}

// Epic #1235 Child B / B2: a heartbeat carrying last_autoupdate_event is
// durably ingested with its outcome/reason/phase scalars extracted.
func TestHeartbeatRecordsAutoupdateOutcome(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	sink := &fakeAutoupdateOutcomeSink{doneCh: make(chan struct{}, 1)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithAutoupdateOutcomeSink(sink))
	server.autoupdateOutcomeSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":4,"slots_free":4,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0,"last_autoupdate_event":{"event":"provider_autoupdate","update_id":"upd-1","current_version":"1.8.48","target_version":"1.8.50","source":"coordinator","phase":"swap","outcome":"success","reason":"binary_swap_complete","attempt":1,"timestamp":"2026-08-27T00:00:00Z"}}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
	waitOrTimeout(t, sink.doneCh)

	calls := sink.snapshot()
	if len(calls) != 1 {
		t.Fatalf("outcome calls = %d, want 1", len(calls))
	}
	got := calls[0]
	if got.ProviderID != "provider-a" || got.UpdateID != "upd-1" || got.Phase != "swap" ||
		got.Outcome != "success" || got.Reason != "binary_swap_complete" ||
		got.CurrentVersion != "1.8.48" || got.TargetVersion != "1.8.50" {
		t.Fatalf("unexpected record: %+v", got)
	}
}

// The provider CLI resends the SAME last_autoupdate_event on every heartbeat
// for the rest of the connection; repeating it must not fan out into one row
// per heartbeat.
func TestHeartbeatAutoupdateOutcomeDedupedAcrossHeartbeats(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	sink := &fakeAutoupdateOutcomeSink{doneCh: make(chan struct{}, 4)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithAutoupdateOutcomeSink(sink))
	server.autoupdateOutcomeSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":4,"slots_free":4,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0,"last_autoupdate_event":{"event":"provider_autoupdate","update_id":"upd-1","current_version":"1.8.48","target_version":"1.8.50","source":"coordinator","phase":"swap","outcome":"success","reason":"binary_swap_complete","attempt":1,"timestamp":"2026-08-27T00:00:00Z"}}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
	waitOrTimeout(t, sink.doneCh)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)

	time.Sleep(50 * time.Millisecond)
	if calls := sink.snapshot(); len(calls) != 1 {
		t.Fatalf("outcome calls = %d, want 1 (deduped identical echo)", len(calls))
	}
}

// A genuinely NEW event (different phase/outcome) after a prior one must
// still be recorded — dedup is by exact content, not a one-shot latch.
func TestHeartbeatAutoupdateOutcomeRecordsDistinctEvents(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	sink := &fakeAutoupdateOutcomeSink{doneCh: make(chan struct{}, 4)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithAutoupdateOutcomeSink(sink))
	server.autoupdateOutcomeSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	const base = `{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":4,"slots_free":4,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0,"last_autoupdate_event":{"event":"provider_autoupdate","update_id":"upd-1","current_version":"1.8.48","target_version":"1.8.50","source":"coordinator","phase":"swap","outcome":%q,"reason":%q,"attempt":1,"timestamp":"2026-08-27T00:00:00Z"}}`
	first := []byte(fmt.Sprintf(base, "in_progress", "binary_swap_started"))
	second := []byte(fmt.Sprintf(base, "success", "binary_swap_complete"))

	server.handleHeartbeat(nil, "provider-a", "assigned-a", first)
	waitOrTimeout(t, sink.doneCh)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", second)
	waitOrTimeout(t, sink.doneCh)

	calls := sink.snapshot()
	if len(calls) != 2 {
		t.Fatalf("outcome calls = %d, want 2 (two distinct events)", len(calls))
	}
	if calls[0].Outcome != "in_progress" || calls[1].Outcome != "success" {
		t.Fatalf("unexpected outcomes: %+v", calls)
	}
}
