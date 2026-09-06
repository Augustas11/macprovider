package ws

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// fakeSupervisorEventSink records every RecordSupervisorEvent call.
type fakeSupervisorEventSink struct {
	mu     sync.Mutex
	calls  []onboarding.SupervisorEventRecord
	doneCh chan struct{}
}

func (f *fakeSupervisorEventSink) RecordSupervisorEvent(_ context.Context, rec onboarding.SupervisorEventRecord) error {
	f.mu.Lock()
	f.calls = append(f.calls, rec)
	f.mu.Unlock()
	if f.doneCh != nil {
		f.doneCh <- struct{}{}
	}
	return nil
}

func (f *fakeSupervisorEventSink) ResetSupervisorDwell(_ context.Context, _ string) error {
	return nil
}

func (f *fakeSupervisorEventSink) snapshot() []onboarding.SupervisorEventRecord {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]onboarding.SupervisorEventRecord(nil), f.calls...)
}

const oldInstanceUUID = "11111111-1111-1111-1111-111111111111"
const newInstanceUUID = "22222222-2222-2222-2222-222222222222"

const supervisorRestartBeacon = `{"schema":"macprovider.supervisor-event.v1","ts":"2026-09-05T00:00:00Z","kind":"restart","boot_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","seq":3,"supervisor_label":"provider-watchdog","supervisor_version":"1.0","restarts_total":1,"deferrals_total":0,"last_restart":{"seq":3,"ts":"2026-09-05T00:00:00Z","reason":"wedge","cooldown_state":"armed","service_instance":"11111111-1111-1111-1111-111111111111","model_liveness":{"token_age_ms":1500,"active_inference":true,"active_inference_age_ms":1500}},"last_deferral":null}`

func supervisorHeartbeatPayload(beacon, serviceInstanceID string) []byte {
	return []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":4,"slots_free":4,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0,"last_supervisor_event":` + beacon + `,"service_instance_id":"` + serviceInstanceID + `"}`)
}

// RFC-001 §7 / F5: a heartbeat carrying last_supervisor_event is durably
// upserted with its counters, kind, sticky last_restart detail, and the current
// (new) service_instance_id extracted.
func TestHeartbeatRecordsSupervisorEvent(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	sink := &fakeSupervisorEventSink{doneCh: make(chan struct{}, 1)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithSupervisorEventSink(sink))
	server.supervisorEventSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	server.handleHeartbeat(nil, "provider-a", "assigned-a", supervisorHeartbeatPayload(supervisorRestartBeacon, newInstanceUUID))
	waitOrTimeout(t, sink.doneCh)

	calls := sink.snapshot()
	if len(calls) != 1 {
		t.Fatalf("supervisor calls = %d, want 1", len(calls))
	}
	got := calls[0]
	if got.ProviderID != "provider-a" || got.BootID != "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" || got.Seq != 3 ||
		got.Kind != "restart" || got.RestartsTotal != 1 {
		t.Fatalf("unexpected record header: %+v", got)
	}
	if got.LastRestartSeq != 3 || got.LastRestartCooldown != "armed" ||
		got.LastRestartInstance != oldInstanceUUID || got.CurrentServiceInstance != newInstanceUUID {
		t.Fatalf("unexpected last_restart correlation: %+v", got)
	}
	if !strings.Contains(got.LastRestartModelLiveness, "token_age_ms") {
		t.Fatalf("model_liveness not carried: %q", got.LastRestartModelLiveness)
	}
}

// The CLI re-sends the SAME beacon on every heartbeat until a new seq; an
// identical echo must not re-upsert.
func TestHeartbeatSupervisorEventDedupedAcrossHeartbeats(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	sink := &fakeSupervisorEventSink{doneCh: make(chan struct{}, 4)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithSupervisorEventSink(sink))
	server.supervisorEventSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	payload := supervisorHeartbeatPayload(supervisorRestartBeacon, newInstanceUUID)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
	waitOrTimeout(t, sink.doneCh)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)

	time.Sleep(50 * time.Millisecond)
	if calls := sink.snapshot(); len(calls) != 1 {
		t.Fatalf("supervisor calls = %d, want 1 (deduped identical echo)", len(calls))
	}
}

// A malformed last_supervisor_event must NOT reject the heartbeat (observability
// -only, best-effort) — the frame is still processed and simply carries no
// supervisor record.
func TestHeartbeatMalformedSupervisorEventDoesNotReject(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	sink := &fakeSupervisorEventSink{doneCh: make(chan struct{}, 1)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithSupervisorEventSink(sink))
	server.supervisorEventSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	// last_supervisor_event is a JSON array (not an object): dropped, frame kept.
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":4,"slots_free":4,"slots_total":4,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0,"last_supervisor_event":[1,2,3],"service_instance_id":"new-inst"}`)
	server.handleHeartbeat(nil, "provider-a", "assigned-a", payload)

	time.Sleep(50 * time.Millisecond)
	if calls := sink.snapshot(); len(calls) != 0 {
		t.Fatalf("supervisor calls = %d, want 0 (malformed dropped)", len(calls))
	}
}

// Coordinator-side validation: a well-formed JSON object with the WRONG schema
// is dropped (not persisted) while the heartbeat is still accepted — the
// coordinator does not trust a modified provider blindly.
func TestHeartbeatWrongSchemaSupervisorEventDropped(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	sink := &fakeSupervisorEventSink{doneCh: make(chan struct{}, 1)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithSupervisorEventSink(sink))
	server.supervisorEventSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	badSchema := `{"schema":"evil.v9","kind":"restart","boot_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","seq":3,"supervisor_label":"provider-watchdog","supervisor_version":"1.0","restarts_total":1,"deferrals_total":0,"last_restart":null,"last_deferral":null}`
	server.handleHeartbeat(nil, "provider-a", "assigned-a", supervisorHeartbeatPayload(badSchema, newInstanceUUID))

	time.Sleep(50 * time.Millisecond)
	if calls := sink.snapshot(); len(calls) != 0 {
		t.Fatalf("supervisor calls = %d, want 0 (wrong schema dropped by coordinator validator)", len(calls))
	}
}

// A non-UUID boot_id (a path/hostname/PII, or an attacker-chosen partition key)
// is dropped by the coordinator validator while the heartbeat is still accepted.
func TestHeartbeatNonUUIDBootIDDropped(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	sink := &fakeSupervisorEventSink{doneCh: make(chan struct{}, 1)}
	server := NewServer(capacityTestConfig(0), registry, zerolog.Nop(),
		WithSupervisorEventSink(sink))
	server.supervisorEventSlots = make(chan struct{}, 2)
	registerCapacityTestProvider(t, server, registry, 4)

	badBoot := `{"schema":"macprovider.supervisor-event.v1","kind":"beacon","boot_id":"/Users/x/host","seq":2,"supervisor_label":"provider-watchdog","supervisor_version":"1.0","restarts_total":0,"deferrals_total":0,"last_restart":null,"last_deferral":null}`
	server.handleHeartbeat(nil, "provider-a", "assigned-a", supervisorHeartbeatPayload(badBoot, newInstanceUUID))

	time.Sleep(50 * time.Millisecond)
	if calls := sink.snapshot(); len(calls) != 0 {
		t.Fatalf("supervisor calls = %d, want 0 (non-UUID boot_id dropped)", len(calls))
	}
}
