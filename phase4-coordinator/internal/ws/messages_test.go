package ws

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"
)

func TestParseNakAcceptsSwiftSpecShape(t *testing.T) {
	payload := []byte(`{"type":"nak","in_reply_to":"req-nak","error":{"code":"unknown_message_type","message":"Unrecognized message type: 'inference_request'"}}`)

	nak, field, err := ParseNak(payload)
	if err != nil {
		t.Fatalf("ParseNak field=%q err=%v", field, err)
	}
	if nak.Type != "nak" {
		t.Fatalf("type = %q", nak.Type)
	}
	if nak.InReplyTo != "req-nak" {
		t.Fatalf("in_reply_to = %q", nak.InReplyTo)
	}
	if nak.Error.Code != "unknown_message_type" {
		t.Fatalf("error.code = %q", nak.Error.Code)
	}
	if nak.Error.Message != "Unrecognized message type: 'inference_request'" {
		t.Fatalf("error.message = %q", nak.Error.Message)
	}
}

func TestParseDiagnosticStatusBoundsAndIdentity(t *testing.T) {
	payload := []byte(`{
		"type":"diagnostic_status",
		"schema_version":1,
		"provider_id":"provider-a",
		"assigned_id":"assigned-a",
		"binary_version":"1.8.65",
		"status":"ready",
		"model_id":"qwen",
		"model_loaded":true,
		"model_hash":"` + strings.Repeat("a", 64) + `",
		"model_hash_algorithm":"macprovider.snapshot-manifest.v1",
		"last_connection_failure":{"at":"2026-07-22T12:00:00Z","diagnostic":"network_offline: redacted"}
	}`)
	diag, field, err := ParseDiagnosticStatus(payload)
	if err != nil {
		t.Fatalf("ParseDiagnosticStatus field=%s err=%v", field, err)
	}
	if diag.ProviderID != "provider-a" || diag.AssignedID != "assigned-a" || !diag.ModelLoaded {
		t.Fatalf("parsed diagnostic mismatch: %#v", diag)
	}

	oversized := append([]byte(`{"type":"diagnostic_status","schema_version":1,"provider_id":"p","status":"ready","model_id":"m","pad":"`), bytes.Repeat([]byte("x"), 8192)...)
	oversized = append(oversized, []byte(`"}`)...)
	if _, field, err := ParseDiagnosticStatus(oversized); err == nil || field != "payload" {
		t.Fatalf("oversize accepted field=%s err=%v", field, err)
	}
	for name, body := range map[string]string{
		"missing assigned_id": `{"type":"diagnostic_status","schema_version":1,"provider_id":"p","status":"ready","model_id":"m","model_loaded":true}`,
		"null assigned_id":    `{"type":"diagnostic_status","schema_version":1,"provider_id":"p","assigned_id":null,"status":"ready","model_id":"m","model_loaded":true}`,
		"numeric assigned_id": `{"type":"diagnostic_status","schema_version":1,"provider_id":"p","assigned_id":1,"status":"ready","model_id":"m","model_loaded":true}`,
	} {
		if _, field, err := ParseDiagnosticStatus([]byte(body)); err == nil || !strings.Contains(field, "assigned_id") {
			t.Fatalf("%s accepted field=%s err=%v", name, field, err)
		}
	}
	for name, body := range map[string]string{
		"missing model_loaded": `{"type":"diagnostic_status","schema_version":1,"provider_id":"p","assigned_id":"a","status":"ready","model_id":"m"}`,
		"null model_loaded":    `{"type":"diagnostic_status","schema_version":1,"provider_id":"p","assigned_id":"a","status":"ready","model_id":"m","model_loaded":null}`,
		"numeric model_loaded": `{"type":"diagnostic_status","schema_version":1,"provider_id":"p","assigned_id":"a","status":"ready","model_id":"m","model_loaded":1}`,
	} {
		if _, field, err := ParseDiagnosticStatus([]byte(body)); err == nil || !strings.Contains(field, "model_loaded") {
			t.Fatalf("%s accepted field=%s err=%v", name, field, err)
		}
	}
}

func TestHandleDiagnosticStatusRequiresAssignedSession(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	store, err := providerevents.NewSQLiteStore(db)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	registry := pool.NewRegistry(nil)
	server := NewServer(config.Default(), registry, zerolog.Nop(), WithConnectionEventStore(store))
	now := time.Now().UTC()
	currentServerConn, currentProviderConn := net.Pipe()
	t.Cleanup(func() {
		_ = currentServerConn.Close()
		_ = currentProviderConn.Close()
	})
	if _, ok := registry.RegisterAt(&pool.Provider{
		ProviderID:      "provider-a",
		AssignedID:      "assigned-good",
		BinaryVersion:   "1.8.57",
		ModelID:         "model-a",
		State:           pool.StateReady,
		AuthState:       pool.AuthBearerValidated,
		ConnectedAt:     now,
		LastHeartbeatAt: now,
		LastActivityAt:  now,
		SlotsFree:       1,
		SlotsTotal:      1,
	}, currentServerConn, now); !ok {
		t.Fatal("register live provider failed")
	}

	mismatch := []byte(`{
		"type":"diagnostic_status",
		"schema_version":1,
		"provider_id":"provider-a",
		"assigned_id":"assigned-wrong",
		"status":"ready",
		"model_id":"model-a",
		"model_loaded":true
	}`)
	server.handleDiagnosticStatus(currentServerConn, "provider-a", "assigned-good", mismatch)
	if _, ok, err := store.GetLastKnown(context.Background(), "provider-a"); err != nil || ok {
		t.Fatalf("mismatched assigned_id persisted ok=%v err=%v", ok, err)
	}

	failureAt := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	matched := []byte(`{
		"type":"diagnostic_status",
		"schema_version":1,
		"provider_id":"provider-a",
		"assigned_id":"assigned-good",
		"observed_at":"2026-07-22T13:00:00Z",
		"status":"ready",
		"model_id":"model-a",
		"model_loaded":true,
		"last_connection_failure":{"at":"2026-07-22T12:00:00Z","diagnostic":"network_offline: redacted"}
	}`)
	staleServerConn, staleProviderConn := net.Pipe()
	t.Cleanup(func() {
		_ = staleServerConn.Close()
		_ = staleProviderConn.Close()
	})
	server.handleDiagnosticStatus(staleServerConn, "provider-a", "assigned-good", matched)
	if _, ok, err := store.GetLastKnown(context.Background(), "provider-a"); err != nil || ok {
		t.Fatalf("stale diagnostic_status persisted ok=%v err=%v", ok, err)
	}

	server.handleDiagnosticStatus(currentServerConn, "provider-a", "assigned-good", matched)
	deadline := time.Now().Add(2 * time.Second)
	for {
		snap, ok, err := store.GetLastKnown(context.Background(), "provider-a")
		if err != nil {
			t.Fatalf("get last-known: %v", err)
		}
		if ok {
			if snap.AssignedID != "assigned-good" || snap.Diagnostic == "" {
				t.Fatalf("last-known mismatch: %#v", snap)
			}
			if snap.DiagnosticAt == nil || !snap.DiagnosticAt.Equal(failureAt) {
				t.Fatalf("diagnostic_at = %v, want failure time %v", snap.DiagnosticAt, failureAt)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("matched diagnostic_status was not persisted")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestDiagnosticLastKnownIsRateLimitedAndQueueOnly(t *testing.T) {
	store := &countingConnectionEventStore{}
	now := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	server := &Server{
		connectionEvents:         store,
		connectionEventQueue:     make(chan connectionEventJob, 2),
		lastKnownFlush:           map[string]time.Time{},
		diagnosticLastKnownFlush: map[string]time.Time{},
		now:                      func() time.Time { return now },
	}
	server.connectionEventWorkerOnce.Do(func() {})
	snap := providerevents.LastKnown{ProviderID: "provider-a", AssignedID: "assigned-a", LastSeenAt: now}

	server.enqueueDiagnosticLastKnown(snap)
	server.enqueueDiagnosticLastKnown(providerevents.LastKnown{ProviderID: "provider-a", AssignedID: "assigned-a", LastSeenAt: now.Add(time.Second)})
	if got := len(server.connectionEventQueue); got != 1 {
		t.Fatalf("diagnostic rate limit queued %d snapshots, want 1", got)
	}
	now = now.Add(lastKnownMinInterval + time.Second)
	server.enqueueDiagnosticLastKnown(providerevents.LastKnown{ProviderID: "provider-a", AssignedID: "assigned-a", LastSeenAt: now})
	if got := len(server.connectionEventQueue); got != 2 {
		t.Fatalf("diagnostic after rate window queued %d snapshots, want 2", got)
	}
	if got := store.upserts.Load(); got != 0 {
		t.Fatalf("diagnostic enqueue used sync fallback upserts=%d", got)
	}

	full := &Server{
		connectionEvents:         store,
		connectionEventQueue:     make(chan connectionEventJob, 1),
		lastKnownFlush:           map[string]time.Time{},
		diagnosticLastKnownFlush: map[string]time.Time{},
		now:                      func() time.Time { return now },
	}
	full.connectionEventWorkerOnce.Do(func() {})
	full.connectionEventQueue <- connectionEventJob{}
	full.enqueueDiagnosticLastKnown(providerevents.LastKnown{ProviderID: "provider-b", AssignedID: "assigned-b", LastSeenAt: now})
	if got := store.upserts.Load(); got != 0 {
		t.Fatalf("full diagnostic queue used sync fallback upserts=%d", got)
	}
}

func TestParseHeartbeatPreservesRollingMetrics(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5}`)

	hb, presence, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if presence != (HeartbeatPresence{}) {
		t.Fatalf("presence = %+v, want zero", presence)
	}
	if hb.RequestsServedSinceLast != 12 {
		t.Fatalf("requests_served_since_last = %d", hb.RequestsServedSinceLast)
	}
	if hb.AvgLatencyMSSinceLast != 450.0 {
		t.Fatalf("avg_latency_ms_since_last = %v", hb.AvgLatencyMSSinceLast)
	}
	if hb.ThroughputTPSSinceLast != 18.5 {
		t.Fatalf("throughput_tps_since_last = %v", hb.ThroughputTPSSinceLast)
	}
}

func TestParseHeartbeatAcceptsCompleteVersionedSafetyTelemetry(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"safety_telemetry":{"schema_version":1,"provider_id":"provider-a","model_id":"model-a","model_loaded":true,"runtime_state":"ready","hardware_tier":"m1-16gb","requests_in_flight":0,"requests_queued":0,"memory_rss_mb":2048,"memory_capacity_mb":16384,"memory_pressure":"normal","thermal_state":"nominal","thermally_throttled":false,"restart_count":1,"uptime_s":120,"coordinator_connected":true,"observation_id":"observation-a","observed_at":"2026-07-14T12:00:00Z","valid_for_ms":90000}}`)

	hb, _, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if hb.SafetyTelemetry == nil || hb.SafetyTelemetry.ProviderID != "provider-a" || hb.SafetyTelemetry.MemoryPressure != "normal" {
		t.Fatalf("safety telemetry = %+v", hb.SafetyTelemetry)
	}
}

func TestParseHeartbeatAcceptsBuildAndSessionBoundV2SafetyTelemetry(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"model_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","model_hash_algorithm":"macprovider.snapshot-manifest.v1","safety_telemetry":{"schema_version":2,"provider_id":"provider-a","model_id":"model-a","model_loaded":true,"runtime_state":"ready","hardware_tier":"16GB","requests_in_flight":0,"requests_queued":0,"memory_rss_mb":2048,"memory_capacity_mb":16384,"memory_pressure":"normal","thermal_state":"nominal","thermally_throttled":false,"restart_count":1,"uptime_s":120,"coordinator_connected":true,"coordinator_session_id":"session-a","cpu_utilization_pct":12.5,"gpu_utilization_pct":null,"gpu_utilization_scope":"host","power_source":"external","binary_version":"1.8.33","compatibility_set_id":"set-a","model_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","model_hash_algorithm":"macprovider.snapshot-manifest.v1","observation_id":"observation-a","observed_at":"2026-07-14T12:00:00Z","valid_for_ms":90000}}`)

	hb, _, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if hb.SafetyTelemetry == nil || hb.SafetyTelemetry.SchemaVersion != 2 ||
		hb.SafetyTelemetry.CoordinatorSessionID != "session-a" || hb.SafetyTelemetry.CPUUtilizationPct == nil ||
		hb.SafetyTelemetry.GPUUtilizationPct != nil {
		t.Fatalf("safety telemetry = %+v", hb.SafetyTelemetry)
	}
}

func validV2SafetyHeartbeat() map[string]any {
	modelHash := strings.Repeat("a", 64)
	return map[string]any{
		"type": "heartbeat", "status": "ready", "model_id": "model-a", "model_params_b": 7.0,
		"ram_gb": 16, "max_context_tokens": 50000, "max_concurrency": 2, "slots_free": 1, "slots_total": 2,
		"throughput_tps_estimate": 19.8, "requests_served_since_last": 12,
		"avg_latency_ms_since_last": 450.0, "throughput_tps_since_last": 18.5,
		"model_hash": modelHash, "model_hash_algorithm": modelidentity.SnapshotManifestV1,
		"safety_telemetry": map[string]any{
			"schema_version": 2, "provider_id": "provider-a", "model_id": "model-a", "model_loaded": true,
			"runtime_state": "ready", "hardware_tier": "16GB", "requests_in_flight": 0, "requests_queued": 0,
			"memory_rss_mb": 2048, "memory_capacity_mb": 16384, "memory_pressure": "normal",
			"thermal_state": "nominal", "thermally_throttled": false, "restart_count": 1, "uptime_s": 120,
			"coordinator_connected": true, "coordinator_session_id": "session-a",
			"cpu_utilization_pct": 12.5, "gpu_utilization_pct": nil, "gpu_utilization_scope": "host",
			"power_source": "external", "binary_version": "1.8.33", "compatibility_set_id": "set-a",
			"model_hash": modelHash, "model_hash_algorithm": modelidentity.SnapshotManifestV1,
			"observation_id": "observation-a", "observed_at": "2026-07-14T12:00:00Z", "valid_for_ms": 90000,
		},
	}
}

type countingConnectionEventStore struct {
	upserts atomic.Int32
}

func (s *countingConnectionEventStore) Record(context.Context, providerevents.Event) error {
	return nil
}

func (s *countingConnectionEventStore) UpsertLastKnown(context.Context, providerevents.LastKnown) error {
	s.upserts.Add(1)
	return nil
}

func (s *countingConnectionEventStore) GetLastKnown(context.Context, string) (providerevents.LastKnown, bool, error) {
	return providerevents.LastKnown{}, false, nil
}

func (s *countingConnectionEventStore) ListLastKnown(context.Context, int, string, string) ([]providerevents.LastKnown, error) {
	return nil, nil
}

func (s *countingConnectionEventStore) ListEvents(context.Context, string, int) ([]providerevents.Event, error) {
	return nil, nil
}

func (s *countingConnectionEventStore) LatestEventProvider(context.Context, string) (providerevents.Event, bool, error) {
	return providerevents.Event{}, false, nil
}

func (s *countingConnectionEventStore) ReconcileBounds(context.Context) error {
	return nil
}

func TestParseHeartbeatBindsV2SafetyTelemetryToOuterIdentity(t *testing.T) {
	weightsHash := strings.Repeat("b", 64)
	accepted := validV2SafetyHeartbeat()
	accepted["weights_manifest_sha256"] = weightsHash
	accepted["weights_manifest_algorithm"] = modelidentity.SafetensorsManifestV1
	acceptedTelemetry := accepted["safety_telemetry"].(map[string]any)
	acceptedTelemetry["weights_manifest_sha256"] = weightsHash
	acceptedTelemetry["weights_manifest_algorithm"] = modelidentity.SafetensorsManifestV1
	if _, _, field, err := ParseHeartbeat(mustAuthJSON(t, accepted)); err != nil {
		t.Fatalf("ParseHeartbeat matched identities field=%q err=%v", field, err)
	}

	for name, mutate := range map[string]func(map[string]any, map[string]any){
		"missing telemetry model algorithm": func(_ map[string]any, telemetry map[string]any) {
			delete(telemetry, "model_hash_algorithm")
		},
		"unknown telemetry model algorithm": func(_ map[string]any, telemetry map[string]any) {
			telemetry["model_hash_algorithm"] = "sha256"
		},
		"missing outer model algorithm": func(heartbeat map[string]any, _ map[string]any) {
			delete(heartbeat, "model_hash_algorithm")
		},
		"mismatched model hash": func(_ map[string]any, telemetry map[string]any) {
			telemetry["model_hash"] = strings.Repeat("c", 64)
		},
		"padded telemetry model hash": func(_ map[string]any, telemetry map[string]any) {
			telemetry["model_hash"] = " " + strings.Repeat("a", 64)
		},
		"weights hash without algorithm": func(_ map[string]any, telemetry map[string]any) {
			telemetry["weights_manifest_sha256"] = weightsHash
		},
		"unknown telemetry weights algorithm": func(heartbeat map[string]any, telemetry map[string]any) {
			heartbeat["weights_manifest_sha256"] = weightsHash
			heartbeat["weights_manifest_algorithm"] = modelidentity.SafetensorsManifestV1
			telemetry["weights_manifest_sha256"] = weightsHash
			telemetry["weights_manifest_algorithm"] = "sha256"
		},
		"padded telemetry weights hash": func(heartbeat map[string]any, telemetry map[string]any) {
			heartbeat["weights_manifest_sha256"] = weightsHash
			heartbeat["weights_manifest_algorithm"] = modelidentity.SafetensorsManifestV1
			telemetry["weights_manifest_sha256"] = weightsHash + "\n"
			telemetry["weights_manifest_algorithm"] = modelidentity.SafetensorsManifestV1
		},
		"telemetry weights without outer authority": func(_ map[string]any, telemetry map[string]any) {
			telemetry["weights_manifest_sha256"] = weightsHash
			telemetry["weights_manifest_algorithm"] = modelidentity.SafetensorsManifestV1
		},
		"mismatched weights hash": func(heartbeat map[string]any, telemetry map[string]any) {
			heartbeat["weights_manifest_sha256"] = weightsHash
			heartbeat["weights_manifest_algorithm"] = modelidentity.SafetensorsManifestV1
			telemetry["weights_manifest_sha256"] = strings.Repeat("c", 64)
			telemetry["weights_manifest_algorithm"] = modelidentity.SafetensorsManifestV1
		},
	} {
		t.Run(name, func(t *testing.T) {
			payload := validV2SafetyHeartbeat()
			telemetry := payload["safety_telemetry"].(map[string]any)
			mutate(payload, telemetry)
			if _, _, field, err := ParseHeartbeat(mustAuthJSON(t, payload)); err == nil || !strings.HasPrefix(field, "safety_telemetry.") {
				t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
			}
		})
	}
}

func TestParseHeartbeatRejectsInvalidV2Utilization(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"model_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","model_hash_algorithm":"macprovider.snapshot-manifest.v1","safety_telemetry":{"schema_version":2,"provider_id":"provider-a","model_id":"model-a","model_loaded":true,"runtime_state":"ready","hardware_tier":"16GB","requests_in_flight":0,"requests_queued":0,"memory_rss_mb":2048,"memory_capacity_mb":16384,"memory_pressure":"normal","thermal_state":"nominal","thermally_throttled":false,"restart_count":1,"uptime_s":120,"coordinator_connected":true,"coordinator_session_id":"session-a","cpu_utilization_pct":101,"gpu_utilization_pct":10,"gpu_utilization_scope":"host","power_source":"external","binary_version":"1.8.33","compatibility_set_id":"set-a","model_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","model_hash_algorithm":"macprovider.snapshot-manifest.v1","observation_id":"observation-a","observed_at":"2026-07-14T12:00:00Z","valid_for_ms":90000}}`)
	_, _, field, err := ParseHeartbeat(payload)
	if err == nil || field != "safety_telemetry.cpu_utilization_pct" {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
}

func TestParseHeartbeatRejectsIncompleteSafetyTelemetry(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"safety_telemetry":{"schema_version":1}}`)
	_, _, field, err := ParseHeartbeat(payload)
	if err == nil || !strings.HasPrefix(field, "safety_telemetry.") {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
}

func TestParseIdlePrewarmEventAcceptsStructuredEvents(t *testing.T) {
	cases := []string{
		"idle_prewarm_fired",
		"idle_prewarm_completed",
		"idle_prewarm_cancelled_by_real_request",
		"idle_prewarm_failed",
	}
	for _, event := range cases {
		t.Run(event, func(t *testing.T) {
			got, field, err := ParseIdlePrewarmEvent([]byte(`{"type":"idle_prewarm_event","event":"` + event + `"}`))
			if err != nil {
				t.Fatalf("ParseIdlePrewarmEvent field=%q err=%v", field, err)
			}
			if got.Event != event || got.Reason != "" {
				t.Fatalf("event=%+v", got)
			}
		})
	}

	got, field, err := ParseIdlePrewarmEvent([]byte(`{"type":"idle_prewarm_event","event":"idle_prewarm_skipped","reason":"not_idle_yet"}`))
	if err != nil {
		t.Fatalf("ParseIdlePrewarmEvent skipped field=%q err=%v", field, err)
	}
	if got.Event != "idle_prewarm_skipped" || got.Reason != "not_idle_yet" {
		t.Fatalf("skipped event=%+v", got)
	}
}

func TestParseIdlePrewarmEventRejectsInvalidReasonShape(t *testing.T) {
	cases := []struct {
		name    string
		payload string
		field   string
	}{
		{
			name:    "missing reason",
			payload: `{"type":"idle_prewarm_event","event":"idle_prewarm_skipped"}`,
			field:   "reason",
		},
		{
			name:    "reason on non skip",
			payload: `{"type":"idle_prewarm_event","event":"idle_prewarm_completed","reason":"busy"}`,
			field:   "reason",
		},
		{
			name:    "bad reason",
			payload: `{"type":"idle_prewarm_event","event":"idle_prewarm_skipped","reason":"other"}`,
			field:   "reason",
		},
		{
			name:    "bad event",
			payload: `{"type":"idle_prewarm_event","event":"idle_prewarm_started"}`,
			field:   "event",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, field, err := ParseIdlePrewarmEvent([]byte(tc.payload))
			if err == nil {
				t.Fatal("ParseIdlePrewarmEvent err = nil")
			}
			if field != tc.field {
				t.Fatalf("field=%q want %q", field, tc.field)
			}
		})
	}
}

func TestParseHeartbeatAcceptsHardwareSummary(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"hardware_summary":{"chip":"Apple M4 Pro","bandwidth_gb_per_s":273,"network_power_kw":0.065,"gpu_cores_total":20,"cpu_cores_total":14}}`)

	hb, _, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if hb.HardwareSummary == nil {
		t.Fatal("HardwareSummary = nil")
	}
	if hb.HardwareSummary.Chip != "Apple M4 Pro" ||
		hb.HardwareSummary.BandwidthGBPerSec != 273 ||
		hb.HardwareSummary.NetworkPowerKW != 0.065 ||
		hb.HardwareSummary.GPUCoresTotal != 20 ||
		hb.HardwareSummary.CPUCoresTotal != 14 {
		t.Fatalf("HardwareSummary = %+v", hb.HardwareSummary)
	}
}

func TestParseHeartbeatIgnoresInvalidHardwareSummary(t *testing.T) {
	cases := []struct {
		name    string
		summary string
	}{
		{
			name:    "negative",
			summary: `{"chip":"Apple M4 Pro","bandwidth_gb_per_s":-1}`,
		},
		{
			name:    "oversized bandwidth",
			summary: `{"chip":"Apple M4 Pro","bandwidth_gb_per_s":9223372036854775807,"network_power_kw":0.065,"gpu_cores_total":20,"cpu_cores_total":14}`,
		},
		{
			name:    "oversized power",
			summary: `{"chip":"Apple M4 Pro","bandwidth_gb_per_s":273,"network_power_kw":1000000000000000000000000000000,"gpu_cores_total":20,"cpu_cores_total":14}`,
		},
		{
			name:    "oversized cores",
			summary: `{"chip":"Apple M4 Pro","bandwidth_gb_per_s":273,"network_power_kw":0.065,"gpu_cores_total":2147483647,"cpu_cores_total":2147483647}`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"hardware_summary":` + tc.summary + `}`)

			hb, _, field, err := ParseHeartbeat(payload)
			if err != nil {
				t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
			}
			if field != "" {
				t.Fatalf("field = %q want empty", field)
			}
			if hb.HardwareSummary != nil {
				t.Fatalf("HardwareSummary = %+v, want nil", hb.HardwareSummary)
			}
		})
	}
}

func TestParseHeartbeatAcceptsSpecDecodeOptInFieldsAsForwardCompatible(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"spec_decode_enabled":true,"spec_decode_draft_model_id":"mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit","spec_decode_num_draft_tokens":3,"spec_decode_drafted_tokens_since_last":30,"spec_decode_accepted_tokens_since_last":18,"spec_decode_acceptance_rate":0.6}`)

	hb, presence, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if presence != (HeartbeatPresence{}) {
		t.Fatalf("presence = %+v, want zero", presence)
	}
	if hb.RequestsServedSinceLast != 12 {
		t.Fatalf("requests_served_since_last = %d", hb.RequestsServedSinceLast)
	}
	if hb.AvgLatencyMSSinceLast != 450.0 {
		t.Fatalf("avg_latency_ms_since_last = %v", hb.AvgLatencyMSSinceLast)
	}
	if hb.ThroughputTPSSinceLast != 18.5 {
		t.Fatalf("throughput_tps_since_last = %v", hb.ThroughputTPSSinceLast)
	}
}

func TestInferenceResponseEndPreservesSettlementReceiptDeadline(t *testing.T) {
	payload := []byte(`{"type":"inference_response_end","request_id":"req-1","status":"complete","chunks_sent":1,"terminal_state_ts_unix_ms":1710000000123,"receipt_pending_deadline_seconds":120,"late_receipt_settlement":"not_settled","receipt":"tuple.sig"}`)

	var end InferenceResponseEnd
	if err := json.Unmarshal(payload, &end); err != nil {
		t.Fatalf("unmarshal end: %v", err)
	}
	if end.TerminalStateTSUnixMS != 1710000000123 {
		t.Fatalf("TerminalStateTSUnixMS = %d", end.TerminalStateTSUnixMS)
	}
	if end.ReceiptPendingDeadlineSeconds != 120 {
		t.Fatalf("ReceiptPendingDeadlineSeconds = %d", end.ReceiptPendingDeadlineSeconds)
	}
	if end.LateReceiptSettlement != "not_settled" {
		t.Fatalf("LateReceiptSettlement = %q", end.LateReceiptSettlement)
	}
}

func TestParseHeartbeatL1AcceptsLegacyAbsentSPEC011Fields(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5}`)

	hb, presence, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if presence != (HeartbeatPresence{}) {
		t.Fatalf("presence = %+v, want zero", presence)
	}
	if hb.ModelHash != "" || hb.Loading {
		t.Fatalf("SPEC-011 fields = (%q, %v), want zero", hb.ModelHash, hb.Loading)
	}
}

func TestParseHeartbeatAcceptsSPEC011Fields(t *testing.T) {
	hash := "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12"
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"model_hash":"` + hash + `","loading":true}`)

	hb, presence, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if !presence.ModelHash || !presence.Loading {
		t.Fatalf("presence = %+v, want both true", presence)
	}
	if hb.ModelHash != hash || !hb.Loading {
		t.Fatalf("SPEC-011 fields = (%q, %v)", hb.ModelHash, hb.Loading)
	}
}

func TestParseHeartbeatPreservesNamedModelIdentities(t *testing.T) {
	hash := strings.Repeat("a", 64)
	weights := strings.Repeat("b", 64)
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":3,"ram_gb":16,"max_context_tokens":4096,"max_concurrency":1,"slots_free":1,"slots_total":1,"throughput_tps_estimate":10,"requests_served_since_last":0,"avg_latency_ms_since_last":0,"throughput_tps_since_last":0,"model_hash":"` + hash + `","model_hash_algorithm":"` + modelidentity.SnapshotManifestV1 + `","weights_manifest_sha256":"` + weights + `","weights_manifest_algorithm":"` + modelidentity.SafetensorsManifestV1 + `"}`)
	hb, presence, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if !presence.ModelHash || !presence.ModelHashAlgorithm || !presence.WeightsManifestSHA256 || !presence.WeightsHashAlgorithm {
		t.Fatalf("presence = %+v", presence)
	}
	if hb.ModelHashAlgorithm != modelidentity.SnapshotManifestV1 ||
		hb.WeightsManifestSHA256 != weights ||
		hb.WeightsHashAlgorithm != modelidentity.SafetensorsManifestV1 {
		t.Fatalf("identity metadata = %+v", hb)
	}
}

func TestParseHeartbeatRejectsUnpairedIdentityMetadata(t *testing.T) {
	base := `{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":3,"ram_gb":16,"max_context_tokens":4096,"max_concurrency":1,"slots_free":1,"slots_total":1,"throughput_tps_estimate":10,"requests_served_since_last":0,"avg_latency_ms_since_last":0,"throughput_tps_since_last":0`
	for name, suffix := range map[string]string{
		"algorithm without model hash": `,"model_hash_algorithm":"` + modelidentity.SnapshotManifestV1 + `"}`,
		"unknown model algorithm":      `,"model_hash":"` + strings.Repeat("a", 64) + `","model_hash_algorithm":"sha256"}`,
		"malformed canonical hash":     `,"model_hash":"abc","model_hash_algorithm":"` + modelidentity.SnapshotManifestV1 + `"}`,
		"weights without algorithm":    `,"weights_manifest_sha256":"` + strings.Repeat("b", 64) + `"}`,
		"unknown weights algorithm":    `,"weights_manifest_sha256":"` + strings.Repeat("b", 64) + `","weights_manifest_algorithm":"sha256"}`,
		"malformed weights hash":       `,"weights_manifest_sha256":"abc","weights_manifest_algorithm":"` + modelidentity.SafetensorsManifestV1 + `"}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, _, err := ParseHeartbeat([]byte(base + suffix)); err == nil {
				t.Fatal("ParseHeartbeat accepted invalid identity metadata")
			}
		})
	}
}

func TestParseHeartbeatAcceptsLastAutoupdateEventObject(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"last_autoupdate_event":{"event":"provider_autoupdate","phase":"download","outcome":"failure","failure_class":"target_release_not_found"}}`)

	hb, _, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	if !json.Valid(hb.LastAutoupdateEvent) || !strings.Contains(string(hb.LastAutoupdateEvent), "target_release_not_found") {
		t.Fatalf("last_autoupdate_event = %s", hb.LastAutoupdateEvent)
	}
}

func TestParseHeartbeatRejectsOversizedLastAutoupdateEvent(t *testing.T) {
	large := `{"event":"provider_autoupdate","extra":"` + strings.Repeat("x", 4096) + `"}`
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"last_autoupdate_event":` + large + `}`)

	_, _, field, err := ParseHeartbeat(payload)
	if err == nil {
		t.Fatal("ParseHeartbeat err = nil")
	}
	if field != "last_autoupdate_event" {
		t.Fatalf("field = %q", field)
	}
}

func TestParseHeartbeatRejectsOversizedModelID(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"` + strings.Repeat("m", 257) + `","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5}`)

	_, _, field, err := ParseHeartbeat(payload)
	if err == nil {
		t.Fatal("ParseHeartbeat err = nil")
	}
	if field != "model_id" {
		t.Fatalf("field = %q", field)
	}
}

func TestParseStateUpdateAcceptsLastAutoupdateEvent(t *testing.T) {
	payload := []byte(`{"type":"state_update","state":"draining","reason":"autoupdate_to_1.7.0","since":"2026-06-29T15:00:00Z","metrics_snapshot":{"slots_free":0,"slots_total":1},"last_autoupdate_event":{"event":"provider_autoupdate","phase":"drain","outcome":"in_progress"}}`)

	update, field, err := ParseStateUpdate(payload)
	if err != nil {
		t.Fatalf("ParseStateUpdate field=%q err=%v", field, err)
	}
	if update.Reason != "autoupdate_to_1.7.0" {
		t.Fatalf("reason = %q", update.Reason)
	}
	if !json.Valid(update.LastAutoupdateEvent) {
		t.Fatalf("last_autoupdate_event invalid: %s", update.LastAutoupdateEvent)
	}
}

func TestParseDrainStatusAcceptsAutoupdateTimeoutSkipped(t *testing.T) {
	status, field, err := ParseDrainStatus([]byte(`{"type":"drain_status","phase":"timeout_skipped","inflight_requests":1,"estimated_drain_seconds":0}`))
	if err != nil {
		t.Fatalf("ParseDrainStatus field=%q err=%v", field, err)
	}
	if status.Phase != "timeout_skipped" {
		t.Fatalf("phase = %q", status.Phase)
	}
}

func TestAdmissionFramesAdvertiseAutoupdateDrainExtensions(t *testing.T) {
	ackBytes, err := json.Marshal(HelloAck{Type: "hello_ack", AutoupdateDrainExtensions: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(ackBytes), `"autoupdate_drain_extensions":true`) {
		t.Fatalf("hello_ack = %s", ackBytes)
	}
	responseBytes, err := json.Marshal(AuthResponse{Type: "auth_response", Version: 2, Status: "accepted", AutoupdateDrainExtensions: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(responseBytes), `"autoupdate_drain_extensions":true`) {
		t.Fatalf("auth_response = %s", responseBytes)
	}
}

func TestParseHeartbeatRejectsModelHashWrongType(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"model_hash":123}`)

	_, _, field, err := ParseHeartbeat(payload)
	if err == nil {
		t.Fatal("ParseHeartbeat err = nil")
	}
	if field != "model_hash" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseHeartbeatRejectsLoadingWrongType(t *testing.T) {
	payload := []byte(`{"type":"heartbeat","status":"ready","model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit","model_params_b":7.0,"ram_gb":16,"max_context_tokens":50000,"max_concurrency":2,"slots_free":1,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":12,"avg_latency_ms_since_last":450.0,"throughput_tps_since_last":18.5,"loading":"yes"}`)

	_, _, field, err := ParseHeartbeat(payload)
	if err == nil {
		t.Fatal("ParseHeartbeat err = nil")
	}
	if field != "loading" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseAuthInitialAcceptsLegacyAbsentSpec010(t *testing.T) {
	req, presence, field, err := ParseAuthRequest(mustAuthJSON(t, validAuthRequestInitial()))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if presence.SupportedModels || presence.PublishesSupportedModels {
		t.Fatalf("presence = %+v, want zero", presence)
	}
	if req.SupportedModels != nil {
		t.Fatalf("supported_models = %#v, want nil", req.SupportedModels)
	}
	if req.PublishesSupportedModels {
		t.Fatal("publishes_supported_models = true, want false")
	}
	if req.ProviderReceiptPublicKey != "" || req.ProviderReceiptPubkey != nil {
		t.Fatalf("receipt key = (%q, %#v), want absent", req.ProviderReceiptPublicKey, req.ProviderReceiptPubkey)
	}
	if req.ProviderAdmissionPublicKey != "" || req.ProviderAdmissionPubkey != nil {
		t.Fatalf("admission key = (%q, %#v), want absent", req.ProviderAdmissionPublicKey, req.ProviderAdmissionPubkey)
	}
}

func TestParseAuthInitialAcceptsTrustedPoolCapability(t *testing.T) {
	payload := validAuthRequestInitial()
	caps := payload["tier2_capabilities"].(map[string]any)
	caps["trusted_pool_v1"] = true
	req, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if !req.Tier2Capabilities.TrustedPoolV1 {
		t.Fatal("trusted_pool_v1 capability was not parsed")
	}
}

func TestHandshakeParsersRejectUnknownModelHashAlgorithm(t *testing.T) {
	const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	authPayload := validAuthRequestInitial()
	authPayload["model_hash"] = hash
	authPayload["model_hash_algorithm"] = "sha256"
	if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, authPayload)); err == nil || field != "model_hash_algorithm" {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}

	helloPayload := map[string]any{
		"type": "hello", "version": 1, "tier": 1, "provider_id": "p-ok",
		"hostname": "h-ok", "model_id": "m-ok", "model_hash": hash,
		"model_hash_algorithm": "sha256", "model_params_b": 3.0, "ram_gb": 16,
		"max_context_tokens": 4096, "max_concurrency": 1,
		"throughput_tps_estimate": 10.0, "binary_version": "1.8.40",
	}
	raw, err := json.Marshal(helloPayload)
	if err != nil {
		t.Fatalf("marshal hello: %v", err)
	}
	if _, field, err := ParseHello(raw); err == nil || field != "model_hash_algorithm" {
		t.Fatalf("ParseHello field=%q err=%v", field, err)
	}
}

func TestWireParsersRejectWhitespacePaddedIdentityDigests(t *testing.T) {
	modelHash := strings.Repeat("a", 64)
	weightsHash := strings.Repeat("b", 64)
	helloPayload := func() map[string]any {
		return map[string]any{
			"type": "hello", "version": 1, "tier": 1, "provider_id": "p-ok",
			"hostname": "h-ok", "model_id": "m-ok", "model_hash": modelHash,
			"model_hash_algorithm":    modelidentity.SnapshotManifestV1,
			"weights_manifest_sha256": weightsHash, "weights_manifest_algorithm": modelidentity.SafetensorsManifestV1,
			"model_params_b": 3.0, "ram_gb": 16, "max_context_tokens": 4096,
			"max_concurrency": 1, "throughput_tps_estimate": 10.0, "binary_version": "1.8.40",
		}
	}
	authPayload := func() map[string]any {
		payload := validAuthRequestInitial()
		payload["model_hash"] = modelHash
		payload["model_hash_algorithm"] = modelidentity.SnapshotManifestV1
		payload["weights_manifest_sha256"] = weightsHash
		payload["weights_manifest_algorithm"] = modelidentity.SafetensorsManifestV1
		return payload
	}
	heartbeatPayload := func() map[string]any {
		payload := validV2SafetyHeartbeat()
		payload["weights_manifest_sha256"] = weightsHash
		payload["weights_manifest_algorithm"] = modelidentity.SafetensorsManifestV1
		return payload
	}
	type parserCase struct {
		payload func() map[string]any
		parse   func([]byte) (string, error)
	}
	parsers := map[string]parserCase{
		"hello": {
			payload: helloPayload,
			parse: func(raw []byte) (string, error) {
				_, field, err := ParseHello(raw)
				return field, err
			},
		},
		"auth": {
			payload: authPayload,
			parse: func(raw []byte) (string, error) {
				_, _, field, err := ParseAuthRequest(raw)
				return field, err
			},
		},
		"heartbeat": {
			payload: heartbeatPayload,
			parse: func(raw []byte) (string, error) {
				_, _, field, err := ParseHeartbeat(raw)
				return field, err
			},
		},
	}
	for parserName, parser := range parsers {
		for field, padded := range map[string]string{
			"model_hash":              " " + modelHash,
			"weights_manifest_sha256": weightsHash + "\n",
		} {
			t.Run(parserName+"/"+field, func(t *testing.T) {
				payload := parser.payload()
				payload[field] = padded
				gotField, err := parser.parse(mustAuthJSON(t, payload))
				if err == nil || gotField != field {
					t.Fatalf("parser accepted padded digest: field=%q err=%v", gotField, err)
				}
			})
		}
	}
}

func TestParseAuthInitialAcceptsNumericStringVersion(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["version"] = "2"

	typ, version, err := ParseFirstAuthMessage(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseFirstAuthMessage err=%v", err)
	}
	if typ != "auth_request" || version != 2 {
		t.Fatalf("first auth = (%q, %d), want auth_request 2", typ, version)
	}

	req, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if req.Version != 2 {
		t.Fatalf("Version = %d, want 2", req.Version)
	}
}

func TestParseFirstAuthMessageWithFieldReportsVersion(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["version"] = "v2"

	typ, _, field, err := parseFirstAuthMessageWithField(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseFirstAuthMessageWithField err = nil, want error")
	}
	if typ != "auth_request" {
		t.Fatalf("type = %q, want auth_request", typ)
	}
	if field != "version" {
		t.Fatalf("field = %q, want version", field)
	}
}

func TestParseFirstAuthMessageWithFieldReportsMissingVersionType(t *testing.T) {
	payload := validAuthRequestInitial()
	delete(payload, "version")

	typ, _, field, err := parseFirstAuthMessageWithField(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseFirstAuthMessageWithField err = nil, want error")
	}
	if typ != "auth_request" {
		t.Fatalf("type = %q, want auth_request", typ)
	}
	if field != "missing version" {
		t.Fatalf("field = %q, want missing version", field)
	}
}

func TestParseAuthInitialAcceptsProviderReceiptPublicKey(t *testing.T) {
	payload := validAuthRequestInitial()
	pubkey := bytesOf(0x42, 32)
	payload["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(pubkey)

	req, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if req.ProviderReceiptPublicKey != base64.StdEncoding.EncodeToString(pubkey) {
		t.Fatalf("ProviderReceiptPublicKey = %q", req.ProviderReceiptPublicKey)
	}
	if string(req.ProviderReceiptPubkey) != string(pubkey) {
		t.Fatalf("ProviderReceiptPubkey = %#v, want %#v", req.ProviderReceiptPubkey, pubkey)
	}
}

func TestParseAuthInitialRejectsInvalidProviderReceiptPublicKey(t *testing.T) {
	for name, value := range map[string]string{
		"invalid_base64": "not base64",
		"wrong_length":   base64.StdEncoding.EncodeToString(bytesOf(0x42, 31)),
	} {
		t.Run(name, func(t *testing.T) {
			payload := validAuthRequestInitial()
			payload["provider_receipt_public_key"] = value

			_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
			if err == nil {
				t.Fatal("ParseAuthRequest err = nil")
			}
			if field != "provider_receipt_public_key" {
				t.Fatalf("badField = %q", field)
			}
		})
	}
}

func TestParseAuthInitialValidatesProviderAdmissionPublicKey(t *testing.T) {
	pubkey := bytesOf(0x43, 32)
	nextPubkey := bytesOf(0x44, 32)
	payload := validAuthRequestInitial()
	payload["provider_admission_public_key"] = base64.StdEncoding.EncodeToString(pubkey)
	payload["provider_admission_next_public_key"] = base64.StdEncoding.EncodeToString(nextPubkey)
	payload["provider_admission_recovery"] = true
	req, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if req.ProviderAdmissionPublicKey != base64.StdEncoding.EncodeToString(pubkey) ||
		string(req.ProviderAdmissionPubkey) != string(pubkey) ||
		req.ProviderAdmissionNextPublicKey != base64.StdEncoding.EncodeToString(nextPubkey) ||
		string(req.ProviderAdmissionNextPubkey) != string(nextPubkey) ||
		!req.ProviderAdmissionRecovery {
		t.Fatalf("admission keys current=(%q, %x) next=(%q, %x)",
			req.ProviderAdmissionPublicKey, req.ProviderAdmissionPubkey,
			req.ProviderAdmissionNextPublicKey, req.ProviderAdmissionNextPubkey)
	}

	for name, value := range map[string]string{
		"invalid_base64": "not base64",
		"wrong_length":   base64.StdEncoding.EncodeToString(bytesOf(0x43, 31)),
	} {
		t.Run(name, func(t *testing.T) {
			payload := validAuthRequestInitial()
			payload["provider_admission_public_key"] = value
			_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
			if err == nil || field != "provider_admission_public_key" {
				t.Fatalf("field=%q err=%v", field, err)
			}
		})
	}

	for name, value := range map[string]string{
		"invalid_base64": "not base64",
		"wrong_length":   base64.StdEncoding.EncodeToString(bytesOf(0x44, 31)),
	} {
		t.Run("next_"+name, func(t *testing.T) {
			payload := validAuthRequestInitial()
			payload["provider_admission_next_public_key"] = value
			_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
			if err == nil || field != "provider_admission_next_public_key" {
				t.Fatalf("field=%q err=%v", field, err)
			}
		})
	}
	payload = validAuthRequestInitial()
	payload["provider_admission_recovery"] = "true"
	if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload)); err == nil || field != "provider_admission_recovery" {
		t.Fatalf("recovery field=%q err=%v", field, err)
	}
}

func TestParseAuthInitialAcceptsSingleEntryCatalog(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["supported_models"] = []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}

	req, presence, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if !presence.SupportedModels || presence.PublishesSupportedModels {
		t.Fatalf("presence = %+v", presence)
	}
	if len(req.SupportedModels) != 1 || req.SupportedModels[0] != "mlx-community/Qwen2.5-7B-Instruct-4bit" {
		t.Fatalf("supported_models = %#v", req.SupportedModels)
	}
}

func TestParseAuthInitialRejectsOverlongEntry(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["supported_models"] = []string{strings.Repeat("x", 257)}

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if field != "supported_models entry exceeds 256 bytes" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseAuthInitialRejectsEmptyCatalog(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["supported_models"] = []string{}

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if field != "supported_models cannot be empty" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseAuthInitialRejectsOverlongCatalog(t *testing.T) {
	payload := validAuthRequestInitial()
	models := make([]string, 65)
	for i := range models {
		models[i] = "model-" + string(rune('A'+i))
	}
	models[0] = "mlx-community/Qwen2.5-7B-Instruct-4bit"
	payload["supported_models"] = models

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if field != "supported_models exceeds 64 entries" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseAuthInitialRejectsDuplicateUnderNFCASCIIFold(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["model_id"] = "Model-A"
	payload["supported_models"] = []string{"Model-A", "MODEL-A"}

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if field != "supported_models contains duplicate entries" {
		t.Fatalf("badField = %q", field)
	}
}

func TestParseAuthInitialRejectsMissingModelID(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["model_id"] = "X"
	payload["supported_models"] = []string{"Y"}

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	// SPEC-010 v1.5 R-3.1.4 / R-3.1.9 LOCKED containment substring.
	if field != "model_id not in supported_models" {
		t.Fatalf("badField = %q, want %q (SPEC-010 R-3.1.4 locked oracle)",
			field, "model_id not in supported_models")
	}
}

// TestParseAuthInitialRejectsSupportedModelsWrongType pins the SPEC-010
// v1.5 R-3.1.9 step-1 LOCKED substring "supported_models must be array
// of strings" for the JSON-type-check failure path. Without the exact
// substring, the wire-side AC-K.15 surfacing falls through to the
// generic envelope close (the pre-merge audit CRITICAL [code:1.1]).
func TestParseAuthInitialRejectsSupportedModelsWrongType(t *testing.T) {
	payload := validAuthRequestInitial()
	payload["supported_models"] = "not-an-array"

	_, _, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err == nil {
		t.Fatal("ParseAuthRequest err = nil")
	}
	if field != "supported_models must be array of strings" {
		t.Fatalf("badField = %q, want %q (SPEC-010 R-3.1.9 step-1 locked oracle)",
			field, "supported_models must be array of strings")
	}
}

func TestParseAuthProofAcceptsAbsentSpec010(t *testing.T) {
	req, presence, field, err := ParseAuthRequest(mustAuthJSON(t, validAuthRequestProof()))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if req.Stage != "proof" {
		t.Fatalf("stage = %q", req.Stage)
	}
	if presence.SupportedModels || presence.PublishesSupportedModels {
		t.Fatalf("presence = %+v, want zero", presence)
	}
}

func TestParseAuthProofRetainsSpec010WhenPresent(t *testing.T) {
	payload := validAuthRequestProof()
	payload["supported_models"] = []string{"X"}

	req, presence, field, err := ParseAuthRequest(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseAuthRequest field=%q err=%v", field, err)
	}
	if !presence.SupportedModels || presence.PublishesSupportedModels {
		t.Fatalf("presence = %+v", presence)
	}
	if len(req.SupportedModels) != 1 || req.SupportedModels[0] != "X" {
		t.Fatalf("supported_models = %#v", req.SupportedModels)
	}
}

func validAuthRequestInitial() map[string]any {
	return map[string]any{
		"type":                     "auth_request",
		"version":                  2,
		"stage":                    "initial",
		"provider_id":              "m4-anon",
		"hostname":                 "provider.local",
		"model_id":                 "mlx-community/Qwen2.5-7B-Instruct-4bit",
		"model_params_b":           7.0,
		"ram_gb":                   16,
		"max_context_tokens":       50000,
		"max_concurrency":          1,
		"throughput_tps_estimate":  19.8,
		"binary_version":           "0.1.0",
		"provider_ecdh_public_key": "test-public-key",
		"tier2_capabilities":       map[string]any{"encrypted_leg": true, "attestation": true, "aead_suites": []string{"AES-256-GCM"}},
	}
}

func validAuthRequestProof() map[string]any {
	return map[string]any{
		"type":            "auth_request",
		"version":         2,
		"stage":           "proof",
		"auth_attempt_id": "auth-1",
		"provider_id":     "m4-anon",
	}
}

func mustAuthJSON(t *testing.T, payload map[string]any) []byte {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("json marshal: %v", err)
	}
	return b
}

func bytesOf(value byte, count int) []byte {
	out := make([]byte, count)
	for i := range out {
		out[i] = value
	}
	return out
}

// TestParseHelloRejectsControlCharsInRequiredStrings pins SPEC-002
// v1.5.1 R-2 / issue #197 R4 security: provider-supplied required
// strings on a hello (provider_id, hostname, model_id, binary_version)
// MUST be rejected at parse time when they contain control characters
// (C0, DEL, C1) so they cannot inject terminal-CSI sequences into
// structured logs or close-frame reason strings. JSON “ decodes
// to U+009B and is valid UTF-8 but would otherwise pass the parser.
func TestParseHelloRejectsControlCharsInRequiredStrings(t *testing.T) {
	base := map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             "p-ok",
		"hostname":                "h-ok",
		"model_id":                "m-ok",
		"model_params_b":          7.0,
		"ram_gb":                  16,
		"max_context_tokens":      50000,
		"max_concurrency":         1,
		"throughput_tps_estimate": 19.8,
		"binary_version":          "0.1.0",
		"attestation":             nil,
	}
	for _, field := range []string{"provider_id", "hostname", "model_id", "binary_version"} {
		for name, bad := range map[string]string{
			"c0_null":      "p-\x00",
			"c0_lf":        "p-\n",
			"c1_csi_utf8":  "p-",
			"c1_low_utf8":  "p-",
			"c1_high_utf8": "p-",
			"del":          "p-\x7f",
		} {
			t.Run(field+"/"+name, func(t *testing.T) {
				payload := make(map[string]any, len(base))
				for k, v := range base {
					payload[k] = v
				}
				payload[field] = bad
				raw, err := json.Marshal(payload)
				if err != nil {
					t.Fatalf("marshal: %v", err)
				}
				_, badField, err := ParseHello(raw)
				if err == nil {
					t.Fatalf("ParseHello accepted %s=%q", field, bad)
				}
				if badField != field {
					t.Fatalf("badField=%q, want %q", badField, field)
				}
			})
		}
	}
}

func TestParseHelloRejectsOversizedHandshakeFields(t *testing.T) {
	base := map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             "p-ok",
		"hostname":                "h-ok",
		"model_id":                "m-ok",
		"model_params_b":          7.0,
		"ram_gb":                  16,
		"max_context_tokens":      50000,
		"max_concurrency":         1,
		"throughput_tps_estimate": 19.8,
		"binary_version":          "0.1.0",
		"attestation":             nil,
	}
	for _, tc := range []struct {
		name  string
		field string
		value any
	}{
		{name: "hostname", field: "hostname", value: strings.Repeat("h", 254)},
		{name: "model_id", field: "model_id", value: strings.Repeat("m", 257)},
		{name: "binary_version", field: "binary_version", value: strings.Repeat("1", 33)},
		{name: "attestation", field: "attestation", value: strings.Repeat("a", 1025)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload := make(map[string]any, len(base))
			for k, v := range base {
				payload[k] = v
			}
			payload[tc.field] = tc.value
			raw, err := json.Marshal(payload)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			_, badField, err := ParseHello(raw)
			if err == nil {
				t.Fatalf("ParseHello accepted oversized %s", tc.field)
			}
			if badField != tc.field {
				t.Fatalf("badField=%q, want %q", badField, tc.field)
			}
		})
	}
}

func TestParseAuthRequestRejectsOversizedHandshakeFields(t *testing.T) {
	initial := validAuthRequestInitial()
	initial["hostname"] = strings.Repeat("h", 254)
	if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, initial)); err == nil || field != "hostname" {
		t.Fatalf("oversized hostname field=%q err=%v, want hostname error", field, err)
	}

	initial = validAuthRequestInitial()
	initial["model_id"] = strings.Repeat("m", 257)
	if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, initial)); err == nil || field != "model_id" {
		t.Fatalf("oversized model_id field=%q err=%v, want model_id error", field, err)
	}

	initial = validAuthRequestInitial()
	initial["binary_version"] = strings.Repeat("1", 33)
	if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, initial)); err == nil || field != "binary_version" {
		t.Fatalf("oversized binary_version field=%q err=%v, want binary_version error", field, err)
	}

	proof := validAuthRequestProof()
	proof["attestation_token"] = strings.Repeat("a", 1025)
	if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, proof)); err == nil || field != "attestation_token" {
		t.Fatalf("oversized attestation_token field=%q err=%v, want attestation_token error", field, err)
	}
}
