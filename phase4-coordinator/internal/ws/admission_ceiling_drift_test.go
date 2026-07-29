package ws

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
)

type recordingConnectionEventStore struct {
	mu     sync.Mutex
	events []providerevents.Event
}

type blockingAutotuneEvidence struct{}

func (blockingAutotuneEvidence) LatestVerified(ctx context.Context, _ string, _ time.Duration) (autotune.VerifiedEvidence, bool, error) {
	<-ctx.Done()
	return autotune.VerifiedEvidence{}, false, ctx.Err()
}

func (s *recordingConnectionEventStore) Record(_ context.Context, event providerevents.Event) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, event)
	return nil
}

func (s *recordingConnectionEventStore) UpsertLastKnown(context.Context, providerevents.LastKnown) error {
	return nil
}

func (s *recordingConnectionEventStore) GetLastKnown(context.Context, string) (providerevents.LastKnown, bool, error) {
	return providerevents.LastKnown{}, false, nil
}

func (s *recordingConnectionEventStore) ListLastKnown(context.Context, int, string, string) ([]providerevents.LastKnown, error) {
	return nil, nil
}

func (s *recordingConnectionEventStore) ListEvents(context.Context, string, int) ([]providerevents.Event, error) {
	return nil, nil
}

func (s *recordingConnectionEventStore) LatestEventProvider(context.Context, string) (providerevents.Event, bool, error) {
	return providerevents.Event{}, false, nil
}

func (s *recordingConnectionEventStore) ReconcileBounds(context.Context) error {
	return nil
}

func (s *recordingConnectionEventStore) snapshot() []providerevents.Event {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]providerevents.Event(nil), s.events...)
}

func TestHeartbeatModelChangeRecordsAdmissionCeilingDrift(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 7, 29, 12, 0, 0, 0, time.UTC)
	registry := pool.NewRegistry(nil)
	events := &recordingConnectionEventStore{}
	server := NewServer(config.Default(), registry, zerolog.Nop(),
		WithAutotuneCatalog(admissionCeilingTestCatalog(t)),
		WithConnectionEventStore(events),
		WithNow(func() time.Time { return now }),
	)
	registerAdmissionCeilingProvider(t, registry, pool.Provider{
		ProviderID:           "provider-a",
		AssignedID:           "assigned-a",
		ModelID:              "small-model",
		MaxAdmittedMinRAMGB:  8,
		MaxAdmittedModelID:   "small-model",
		CatalogAdmissionMode: "current",
		BinaryVersion:        "1.8.70",
	})

	server.handleHeartbeat(nil, "provider-a", "assigned-a", admissionCeilingHeartbeat("large-model"))
	server.FlushConnectionEvents(2 * time.Second)

	got := events.snapshot()
	if len(got) != 1 {
		t.Fatalf("events len = %d, want 1", len(got))
	}
	event := got[0]
	if event.Kind != providerevents.KindModelCeilingDrift || event.ProviderID != "provider-a" || event.SessionID != "assigned-a" {
		t.Fatalf("event = %+v, want model ceiling drift for provider/session", event)
	}
	if event.FailureReason != providerevents.ReasonOther || event.AuthStage != providerevents.AuthStageLiveness {
		t.Fatalf("event taxonomy = %+v", event)
	}
	if !strings.Contains(event.Diagnostic, "claimed_min_ram_gb=32") || !strings.Contains(event.Diagnostic, "max_admitted_min_ram_gb=8") {
		t.Fatalf("diagnostic = %q", event.Diagnostic)
	}
	if snap, ok := registry.Resolve("provider-a", "assigned-a"); !ok || snap.State == pool.StateDegraded {
		t.Fatalf("drift observation changed routing state: provider=%+v ok=%v", snap, ok)
	}
}

func TestHeartbeatModelCeilingDriftIsCoalesced(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 7, 29, 12, 0, 0, 0, time.UTC)
	registry := pool.NewRegistry(nil)
	events := &recordingConnectionEventStore{}
	server := NewServer(config.Default(), registry, zerolog.Nop(),
		WithAutotuneCatalog(admissionCeilingTestCatalog(t)),
		WithConnectionEventStore(events),
		WithNow(func() time.Time { return now }),
	)
	registerAdmissionCeilingProvider(t, registry, pool.Provider{
		ProviderID:           "provider-a",
		AssignedID:           "assigned-a",
		ModelID:              "small-model",
		MaxAdmittedMinRAMGB:  8,
		MaxAdmittedModelID:   "small-model",
		CatalogAdmissionMode: "current",
		BinaryVersion:        "1.8.70",
	})

	server.handleHeartbeat(nil, "provider-a", "assigned-a", admissionCeilingHeartbeat("large-model"))
	server.handleHeartbeat(nil, "provider-a", "assigned-a", admissionCeilingHeartbeat("small-model"))
	server.handleHeartbeat(nil, "provider-a", "assigned-a", admissionCeilingHeartbeat("large-model"))
	server.FlushConnectionEvents(2 * time.Second)

	got := events.snapshot()
	if len(got) != 1 {
		t.Fatalf("events len = %d, want 1", len(got))
	}
	if got[0].Kind != providerevents.KindModelCeilingDrift {
		t.Fatalf("kind = %q, want %q", got[0].Kind, providerevents.KindModelCeilingDrift)
	}
}

func TestHeartbeatModelCeilingDriftCoalescesAcrossReconnect(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 7, 29, 12, 0, 0, 0, time.UTC)
	registry := pool.NewRegistry(nil)
	events := &recordingConnectionEventStore{}
	server := NewServer(config.Default(), registry, zerolog.Nop(),
		WithAutotuneCatalog(admissionCeilingTestCatalog(t)),
		WithConnectionEventStore(events),
		WithNow(func() time.Time { return now }),
	)
	registerAdmissionCeilingProvider(t, registry, pool.Provider{
		ProviderID:           "provider-a",
		AssignedID:           "assigned-a",
		ModelID:              "small-model",
		MaxAdmittedMinRAMGB:  8,
		MaxAdmittedModelID:   "small-model",
		CatalogAdmissionMode: "current",
		BinaryVersion:        "1.8.70",
	})
	server.handleHeartbeat(nil, "provider-a", "assigned-a", admissionCeilingHeartbeat("large-model"))
	registerAdmissionCeilingProvider(t, registry, pool.Provider{
		ProviderID:           "provider-a",
		AssignedID:           "assigned-b",
		ModelID:              "small-model",
		MaxAdmittedMinRAMGB:  8,
		MaxAdmittedModelID:   "small-model",
		CatalogAdmissionMode: "current",
		BinaryVersion:        "1.8.70",
	})
	server.handleHeartbeat(nil, "provider-a", "assigned-b", admissionCeilingHeartbeat("large-model"))
	server.FlushConnectionEvents(2 * time.Second)

	got := events.snapshot()
	if len(got) != 1 {
		t.Fatalf("events len = %d, want 1", len(got))
	}
	if got[0].SessionID != "assigned-a" {
		t.Fatalf("session_id = %q, want only first session event", got[0].SessionID)
	}
}

func TestHeartbeatModelChangeWithoutCapRecordsMissingAdmissionCap(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 7, 29, 12, 0, 0, 0, time.UTC)
	registry := pool.NewRegistry(nil)
	events := &recordingConnectionEventStore{}
	server := NewServer(config.Default(), registry, zerolog.Nop(),
		WithAutotuneCatalog(admissionCeilingTestCatalog(t)),
		WithConnectionEventStore(events),
		WithNow(func() time.Time { return now }),
	)
	registerAdmissionCeilingProvider(t, registry, pool.Provider{
		ProviderID:           "provider-a",
		AssignedID:           "assigned-a",
		ModelID:              "small-model",
		CatalogAdmissionMode: "current",
		BinaryVersion:        "1.8.70",
	})

	server.handleHeartbeat(nil, "provider-a", "assigned-a", admissionCeilingHeartbeat("large-model"))
	server.FlushConnectionEvents(2 * time.Second)

	got := events.snapshot()
	if len(got) != 1 {
		t.Fatalf("events len = %d, want 1", len(got))
	}
	if got[0].Kind != providerevents.KindMissingAdmissionCap {
		t.Fatalf("kind = %q, want %q", got[0].Kind, providerevents.KindMissingAdmissionCap)
	}
	if !strings.Contains(got[0].Diagnostic, "max_admitted_min_ram_gb=0") {
		t.Fatalf("diagnostic = %q", got[0].Diagnostic)
	}
}

func TestGateOffAutotuneObservationTimeoutAdmits(t *testing.T) {
	t.Parallel()
	server := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop(),
		WithAutotuneCatalog(admissionCeilingTestCatalog(t)),
		WithAutotuneEvidenceStore(blockingAutotuneEvidence{}),
	)

	start := time.Now()
	observation, ok := server.checkAutotuneHelloGate(nil, Hello{ProviderID: "provider-a", ModelID: "small-model"})
	elapsed := time.Since(start)

	if !ok {
		t.Fatal("gate-off timeout rejected admission")
	}
	if observation.MaxAdmittedMinRAMGB != 0 || observation.MaxAdmittedModelID != "" {
		t.Fatalf("observation after timeout = %+v, want empty fail-open observation", observation)
	}
	if elapsed > autotuneEvidenceLookupTimeout+time.Second {
		t.Fatalf("lookup took %s, want bounded near %s", elapsed, autotuneEvidenceLookupTimeout)
	}
}

func TestAdmissionCeilingEventClockRegressionResetsWindow(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 7, 29, 12, 0, 0, 0, time.UTC)
	server := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop(),
		WithNow(func() time.Time { return now }),
	)

	if _, ok := server.reserveAdmissionCeilingEvent("provider-a", providerevents.KindModelCeilingDrift); !ok {
		t.Fatal("first event suppressed")
	}
	now = now.Add(-time.Hour)
	if _, ok := server.reserveAdmissionCeilingEvent("provider-a", providerevents.KindModelCeilingDrift); !ok {
		t.Fatal("clock regression suppressed event")
	}
}

func registerAdmissionCeilingProvider(t *testing.T, registry *pool.Registry, provider pool.Provider) {
	t.Helper()
	provider.Hostname = "mac-a"
	provider.RAMGB = 16
	provider.MaxConcurrency = 2
	provider.SlotsFree = 2
	provider.SlotsTotal = 2
	provider.LastHeartbeatAt = time.Date(2026, 7, 29, 12, 0, 0, 0, time.UTC)
	provider.State = pool.StateReady
	if _, registered := registry.RegisterAt(&provider, nil, provider.LastHeartbeatAt); !registered {
		t.Fatal("register provider failed")
	}
}

func admissionCeilingHeartbeat(modelID string) []byte {
	return []byte(`{"type":"heartbeat","status":"ready","model_id":"` + modelID + `","model_params_b":30.0,"ram_gb":16,"max_context_tokens":32768,"max_concurrency":2,"slots_free":2,"slots_total":2,"throughput_tps_estimate":19.8,"requests_served_since_last":0,"avg_latency_ms_since_last":0.0,"throughput_tps_since_last":0.0}`)
}

func admissionCeilingTestCatalog(t *testing.T) *autotune.Catalog {
	t.Helper()
	catalog, err := autotune.ParseCatalog([]byte(`{
		"version":"test-admission-ceiling",
		"policy_version":"test",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"small":{"model_id":"small-model","min_ram_gb":8,"min_bandwidth_tier":"low","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommended"},
			"large":{"model_id":"large-model","min_ram_gb":32,"min_bandwidth_tier":"high","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommended"}
		}
	}`))
	if err != nil {
		t.Fatalf("parse catalog: %v", err)
	}
	return catalog
}
