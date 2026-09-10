package ws

import (
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestCanonicalModelIdentityUsesSignedAutotuneRowWithoutTier2Fallback(t *testing.T) {
	const expected = "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a"
	catalog, err := autotune.ParseCatalog([]byte(`{
		"version":"test",
		"policy_version":"test-v1",
		"generated_at":"2026-07-18T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{"small":{
			"model_id":"model-a",
			"model_revision":"revision-a",
			"model_sha256":"` + expected + `",
			"min_ram_gb":4,
			"min_bandwidth_tier":"C",
			"bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},
			"runtime_status":"recommendable"
		}}
	}`))
	if err != nil {
		t.Fatalf("ParseCatalog: %v", err)
	}
	cfg := config.Default()
	cfg.Tier2.ObserveEnabled = true
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)
	server := &Server{cfg: cfg, tier2: cfg.Tier2, autotuneCatalog: catalog, now: func() time.Time { return now }}

	if got := server.verifyProviderModelIdentity("model-a", expected, expected, modelidentity.SnapshotManifestV1); got != pool.HashStatusVerified {
		t.Fatalf("matching canonical identity = %q", got)
	}
	if got := server.verifyProviderModelIdentity("model-a", expected, strings.Repeat("a", 64), modelidentity.SnapshotManifestV1); got != pool.HashStatusMismatch {
		t.Fatalf("mismatching canonical identity = %q", got)
	}
	if got := server.verifyProviderModelIdentity("unknown", "", expected, modelidentity.SnapshotManifestV1); got != pool.HashStatusUncatalogued {
		t.Fatalf("missing signed row reused fallback hash: %q", got)
	}
	if got := server.verifyProviderModelIdentity("model-a", expected, expected, "sha256"); got != pool.HashStatusInvalid {
		t.Fatalf("unknown explicit algorithm = %q", got)
	}

	server.tier2.ModelHashLegacyUntil = now.Add(time.Minute).Format(time.RFC3339)
	if got := server.verifyProviderModelIdentity("model-a", expected, expected, ""); got != pool.HashStatusUncatalogued {
		t.Fatalf("bridged missing algorithm = %q", got)
	}
	server.tier2.ModelHashLegacyUntil = now.Format(time.RFC3339)
	if got := server.verifyProviderModelIdentity("model-a", expected, expected, ""); got != pool.HashStatusInvalid {
		t.Fatalf("expired missing algorithm = %q", got)
	}
}

func TestModelHashLegacyDeadlineReloadFencesUntypedSessions(t *testing.T) {
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)
	cfg := config.Default()
	cfg.Tier2.ObserveEnabled = true
	cfg.Tier2.ModelHashLegacyUntil = now.Add(time.Hour).Format(time.RFC3339)
	registry := pool.NewRegistry(nil)
	for _, provider := range []*pool.Provider{
		{
			ProviderID: "legacy", AssignedID: "legacy-session", ModelID: "model-a",
			ModelHash: strings.Repeat("a", 64), HashStatus: pool.HashStatusUncatalogued,
			State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1,
		},
		{
			ProviderID: "modern", AssignedID: "modern-session", ModelID: "model-a",
			ModelHash: strings.Repeat("a", 64), ModelHashAlgorithm: modelidentity.SnapshotManifestV1,
			HashStatus: pool.HashStatusVerified, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1,
		},
	} {
		if _, ok := registry.Register(provider, nil); !ok {
			t.Fatalf("register %s", provider.ProviderID)
		}
	}
	server := NewServer(cfg, registry, zerolog.Nop(), WithNow(func() time.Time { return now }))
	next := cfg.Tier2
	next.ModelHashLegacyUntil = now.Format(time.RFC3339)
	server.SetTier2Config(next)

	legacy, _ := registry.Resolve("legacy", "legacy-session")
	modern, _ := registry.Resolve("modern", "modern-session")
	if legacy.HashStatus != pool.HashStatusInvalid {
		t.Fatalf("legacy HashStatus=%q, want invalid", legacy.HashStatus)
	}
	if modern.HashStatus != pool.HashStatusVerified {
		t.Fatalf("modern HashStatus=%q, want verified", modern.HashStatus)
	}
}

func TestCompatiblePreviousAdmissionKeepsExactSelectedRowIdentity(t *testing.T) {
	const previousHash = "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a"
	const currentHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	current := mustModelIdentityCatalog(t, "current", currentHash)
	previous := mustModelIdentityCatalog(t, "previous", previousHash)
	registry := pool.NewRegistry(nil)
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)
	registry.Register(&pool.Provider{
		ProviderID:           "provider-a",
		AssignedID:           "session-a",
		ModelID:              "model-a",
		CatalogAdmissionMode: "previous",
		CatalogReleaseID:     "previous",
		State:                pool.StateReady,
		LastHeartbeatAt:      now,
		LastActivityAt:       now,
		ConnectedAt:          now,
		MaxConcurrency:       1,
		SlotsFree:            1,
		SlotsTotal:           1,
	}, nil)
	cfg := config.Default()
	cfg.Tier2.ObserveEnabled = true
	server := &Server{
		cfg:                        cfg,
		tier2:                      cfg.Tier2,
		autotuneCatalog:            current,
		autotuneCompatibleCatalogs: map[string]*autotune.Catalog{"previous": previous},
		pool:                       registry,
		now:                        func() time.Time { return now },
	}
	hello := Hello{
		ModelID:          "model-a",
		CatalogReleaseID: "previous",
	}
	selected := server.expectedAdmissionModelHash(hello, "previous")
	if selected != previousHash {
		t.Fatalf("selected previous hash = %q", selected)
	}
	if heartbeatExpected := server.expectedProviderModelHash("provider-a", "session-a", "model-a"); heartbeatExpected != previousHash {
		t.Fatalf("heartbeat previous hash = %q", heartbeatExpected)
	}
	if got := server.verifyProviderModelIdentity("model-a", selected, previousHash, modelidentity.SnapshotManifestV1); got != pool.HashStatusVerified {
		t.Fatalf("previous signed row was compared against current row: %q", got)
	}
	if got := server.verifyProviderModelIdentity("model-a", currentHash, currentHash, modelidentity.SnapshotManifestV1); got != pool.HashStatusVerified {
		t.Fatalf("current signed row = %q", got)
	}
}

func mustModelIdentityCatalog(t *testing.T, version, hash string) *autotune.Catalog {
	t.Helper()
	catalog, err := autotune.ParseCatalog([]byte(`{
		"version":"` + version + `",
		"policy_version":"test-v1",
		"generated_at":"2026-07-18T00:00:00Z",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{"small":{
			"model_id":"model-a",
			"model_revision":"revision-a",
			"model_sha256":"` + hash + `",
			"min_ram_gb":4,
			"min_bandwidth_tier":"C",
			"bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},
			"runtime_status":"recommendable"
		}}
	}`))
	if err != nil {
		t.Fatalf("ParseCatalog: %v", err)
	}
	return catalog
}
