package poolsnapshot

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type routabilityFakeSource struct {
	providers []pool.Provider
}

func (s routabilityFakeSource) Snapshot() []pool.Provider {
	return append([]pool.Provider(nil), s.providers...)
}

func TestRoutabilitySnapshotAggregatesAndRedacts(t *testing.T) {
	now := time.Date(2026, 8, 19, 12, 0, 0, 0, time.UTC)
	successAt := now.Add(-10 * time.Minute)
	providers := []pool.Provider{
		{
			ProviderID:               "provider-secret-1",
			AssignedID:               "assigned-secret-1",
			Hostname:                 "secret-host-1.local",
			EndpointURL:              "https://secret-host-1.local:11434",
			ModelID:                  "llama-3.1-8b",
			State:                    pool.StateReady,
			SlotsFree:                1,
			SlotsTotal:               2,
			MaxContextTokens:         131072,
			LastHeartbeatAt:          now.Add(-8 * time.Second),
			ConnectedAt:              now.Add(-2 * time.Hour),
			LastBuyerSuccessAt:       &successAt,
			ReceiptPubkey:            []byte("receipt-key-material"),
			AttestationStatus:        pool.AttestationStatusAttested,
			AttestationTier:          pool.AttestationTierHardware,
			HashStatus:               pool.HashStatusVerified,
			ModelHash:                "hash-must-not-leak",
			WeightsManifestSHA256:    "manifest-must-not-leak",
			SupportedModels:          []string{"declared-only"},
			PublishesSupportedModels: true,
		},
		{
			ProviderID:        "provider-secret-2",
			ModelID:           "llama-3.1-8b",
			State:             pool.StateReady,
			SlotsFree:         1,
			SlotsTotal:        1,
			MaxContextTokens:  65536,
			LastHeartbeatAt:   now.Add(-10 * time.Second),
			ConnectedAt:       now.Add(-30 * time.Minute),
			ReceiptPubkey:     []byte("receipt-key-material-2"),
			AttestationStatus: pool.AttestationStatusAttested,
			AttestationTier:   pool.AttestationTierSelfSigned,
		},
		{
			ProviderID:      "provider-secret-3",
			ModelID:         "busy-model",
			State:           pool.StateBusy,
			SlotsFree:       0,
			SlotsTotal:      1,
			LastHeartbeatAt: now.Add(-15 * time.Second),
			ConnectedAt:     now.Add(-10 * time.Minute),
			ReceiptPubkey:   []byte("receipt-key-material-3"),
		},
	}

	p := New(routabilityFakeSource{providers: providers})
	p.now = func() time.Time { return now }
	snap := p.RoutabilitySnapshot()

	if snap.Summary.State != "redundant" {
		t.Fatalf("summary state=%q want redundant", snap.Summary.State)
	}
	if snap.Summary.ProvidersTotal != 3 || snap.Summary.ProvidersRoutable != 2 || snap.Summary.ProvidersServingCapable != 3 {
		t.Fatalf("summary provider counts=%+v", snap.Summary)
	}

	byModel := map[string]string{}
	for _, m := range snap.Models {
		byModel[m.ModelID] = m.State
	}
	if got := byModel["llama-3.1-8b"]; got != "redundant" {
		t.Fatalf("llama state=%q want redundant", got)
	}
	if got := byModel["busy-model"]; got != "degraded" {
		t.Fatalf("busy-model state=%q want degraded", got)
	}
	if got := byModel["declared-only"]; got != "unknown" {
		t.Fatalf("declared-only state=%q want unknown", got)
	}

	raw, err := json.Marshal(snap)
	if err != nil {
		t.Fatalf("marshal snapshot: %v", err)
	}
	publicJSON := string(raw)
	for _, secret := range []string{
		"provider-secret-1",
		"provider-secret-2",
		"provider-secret-3",
		"assigned-secret-1",
		"secret-host-1.local",
		"receipt-key-material",
		"hash-must-not-leak",
		"manifest-must-not-leak",
	} {
		if strings.Contains(publicJSON, secret) {
			t.Fatalf("public routability JSON leaked %q: %s", secret, publicJSON)
		}
	}
	if !strings.Contains(publicJSON, `"provider_ref":"provider_`) {
		t.Fatalf("public routability JSON missing provider_ref pseudonyms: %s", publicJSON)
	}
	if strings.Contains(publicJSON, `"provider_ref":"provider_3b52a7f4e944"`) {
		t.Fatalf("public routability JSON used provider_id-derived pseudonym: %s", publicJSON)
	}
}

func TestRoutabilitySnapshotFiltersPrivateAdmissionAndSupportedModelOptIn(t *testing.T) {
	now := time.Date(2026, 8, 19, 12, 0, 0, 0, time.UTC)
	providers := []pool.Provider{
		{
			ProviderID:               "visible-provider",
			ModelID:                  "visible-active",
			State:                    pool.StateReady,
			SlotsFree:                1,
			SlotsTotal:               1,
			LastHeartbeatAt:          now.Add(-5 * time.Second),
			ReceiptPubkey:            []byte("receipt-visible"),
			SupportedModels:          []string{"hidden-supported-optout"},
			PublishesSupportedModels: false,
		},
		{
			ProviderID:               "untrusted-provider",
			ModelID:                  "hidden-active",
			State:                    pool.StateReady,
			SlotsFree:                1,
			SlotsTotal:               1,
			LastHeartbeatAt:          now.Add(-5 * time.Second),
			ReceiptPubkey:            []byte("receipt-hidden"),
			AuthState:                pool.AuthSelfMinted,
			SupportedModels:          []string{"hidden-supported-untrusted"},
			PublishesSupportedModels: true,
		},
		{
			ProviderID:               "admitted-publisher",
			ModelID:                  "visible-published-active",
			State:                    pool.StateBusy,
			SlotsFree:                0,
			SlotsTotal:               1,
			LastHeartbeatAt:          now.Add(-5 * time.Second),
			ReceiptPubkey:            []byte("receipt-publisher"),
			SupportedModels:          []string{"visible-supported"},
			PublishesSupportedModels: true,
		},
	}

	p := New(routabilityFakeSource{providers: providers})
	p.now = func() time.Time { return now }
	snap := p.RoutabilitySnapshot()

	if snap.Summary.ProvidersTotal != 2 {
		t.Fatalf("providers_total=%d want 2 public-admitted providers", snap.Summary.ProvidersTotal)
	}
	modelStates := map[string]string{}
	for _, model := range snap.Models {
		modelStates[model.ModelID] = model.State
	}
	for _, hidden := range []string{"hidden-active", "hidden-supported-optout", "hidden-supported-untrusted"} {
		if _, ok := modelStates[hidden]; ok {
			t.Fatalf("private/unpublished model %q appeared in public routability snapshot: %+v", hidden, snap.Models)
		}
	}
	if got := modelStates["visible-active"]; got != "operational" {
		t.Fatalf("visible-active state=%q want operational", got)
	}
	if got := modelStates["visible-published-active"]; got != "degraded" {
		t.Fatalf("visible-published-active state=%q want degraded", got)
	}
	if got := modelStates["visible-supported"]; got != "unknown" {
		t.Fatalf("visible-supported state=%q want unknown", got)
	}
}
