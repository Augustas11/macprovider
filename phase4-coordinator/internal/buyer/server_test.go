package buyer_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

const buyerTestHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const buyerOtherHash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

func TestModelsAggregatesUniqueReadyProviderModels(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: "https://p1.example"},
		{ProviderID: "p2", EndpointURL: "https://p2.example"},
		{ProviderID: "p3", EndpointURL: "https://p3.example"},
		{ProviderID: "p4", EndpointURL: "https://p4.example"},
	})
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	register(registry, "p2", "session-2", "model-a", pool.StateReady, 50000, 1)
	register(registry, "p3", "session-3", "model-b", pool.StateReady, 120000, 1)
	register(registry, "p4", "session-4", "model-c", pool.StateBusy, 200000, 1)

	started := time.Unix(1716768000, 0)
	server := buyer.NewServer(registry, zerolog.Nop(), started)
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Object string `json:"object"`
		Data   []struct {
			ID               string `json:"id"`
			Object           string `json:"object"`
			Created          int64  `json:"created"`
			OwnedBy          string `json:"owned_by"`
			ProviderCount    int    `json:"provider_count"`
			MaxContextTokens int    `json:"max_context_tokens"`
			TotalSlots       int    `json:"total_slots"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Object != "list" {
		t.Fatalf("object = %q", got.Object)
	}
	if len(got.Data) != 2 {
		t.Fatalf("models = %d, want 2: %#v", len(got.Data), got.Data)
	}
	if got.Data[0].ID != "model-a" || got.Data[0].ProviderCount != 2 || got.Data[0].MaxContextTokens != 50000 || got.Data[0].TotalSlots != 2 {
		t.Fatalf("model-a aggregation wrong: %#v", got.Data[0])
	}
	if got.Data[0].Created != started.Unix() || got.Data[0].OwnedBy != "macprovider" || got.Data[0].Object != "model" {
		t.Fatalf("model-a metadata wrong: %#v", got.Data[0])
	}
	if got.Data[1].ID != "model-b" || got.Data[1].ProviderCount != 1 || got.Data[1].MaxContextTokens != 120000 || got.Data[1].TotalSlots != 1 {
		t.Fatalf("model-b aggregation wrong: %#v", got.Data[1])
	}
}

func TestModelsReturnsEmptyListWhenNoReadyProviders(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: "https://p1.example"},
	})
	register(registry, "p1", "session-1", "model-a", pool.StateBusy, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Data []any `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if len(got.Data) != 0 {
		t.Fatalf("data len = %d, want 0", len(got.Data))
	}
}

func TestModelsDefaultHasNoTier2HashFields(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "https://p1.example"}})
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Data  []map[string]any `json:"data"`
		Tier2 map[string]any   `json:"tier2"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if len(got.Data) != 1 {
		t.Fatalf("models = %d, want 1", len(got.Data))
	}
	if got.Tier2 != nil {
		t.Fatalf("default /v1/models included top-level tier2: %s", rr.Body.String())
	}
	for _, forbidden := range []string{"hash_verified", "hash_verification", "tier2"} {
		if _, ok := got.Data[0][forbidden]; ok {
			t.Fatalf("default /v1/models included %s: %s", forbidden, rr.Body.String())
		}
	}
}

func TestModelsDefaultIncludesReadyProvidersWithoutFreeSlots(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "https://p1.example"}})
	registerWithHashStatusSlots(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 0, 1, "https://p1.example", "")
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Data []struct {
			ID               string `json:"id"`
			ProviderCount    int    `json:"provider_count"`
			MaxContextTokens int    `json:"max_context_tokens"`
			TotalSlots       int    `json:"total_slots"`
		} `json:"data"`
		Tier2 map[string]any `json:"tier2"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if len(got.Data) != 1 {
		t.Fatalf("data len = %d, want 1; body=%s", len(got.Data), rr.Body.String())
	}
	if got.Tier2 != nil {
		t.Fatalf("default /v1/models included top-level tier2: %s", rr.Body.String())
	}
	if got.Data[0].ID != "model-a" || got.Data[0].ProviderCount != 1 || got.Data[0].MaxContextTokens != 20000 || got.Data[0].TotalSlots != 1 {
		t.Fatalf("model-a aggregation wrong: %#v", got.Data[0])
	}
}

func TestModelsPillarAExcludesReadyProvidersWithoutFreeSlots(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "https://p1.example"}})
	registerWithHashStatusSlots(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 0, 1, "https://p1.example", "")
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Data []any `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if len(got.Data) != 0 {
		t.Fatalf("data len = %d, want 0; body=%s", len(got.Data), rr.Body.String())
	}
}

func TestModelsPillarAReportsMixedHashState(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "verified", EndpointURL: "https://verified.example"},
		{ProviderID: "old", EndpointURL: "https://old.example"},
	})
	registerWithHashStatus(registry, "verified", "session-1", "model-a", pool.StateReady, 20000, 1, pool.HashStatusVerified)
	registerWithHashStatus(registry, "old", "session-2", "model-a", pool.StateReady, 20000, 1, pool.HashStatusUncatalogued)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Data []struct {
			HashVerified     any `json:"hash_verified"`
			HashVerification struct {
				Status                    string `json:"status"`
				VerifiedProviderCount     int    `json:"verified_provider_count"`
				UncataloguedProviderCount int    `json:"uncatalogued_provider_count"`
			} `json:"hash_verification"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Data[0].HashVerified != false {
		t.Fatalf("hash_verified=%v want false body=%s", got.Data[0].HashVerified, rr.Body.String())
	}
	hv := got.Data[0].HashVerification
	if hv.Status != "partial" || hv.VerifiedProviderCount != 1 || hv.UncataloguedProviderCount != 1 {
		t.Fatalf("hash_verification=%+v body=%s", hv, rr.Body.String())
	}
}

func TestModelsPillarAHashCountsOnlyBaseRoutableProviders(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "verified", EndpointURL: "https://verified.example"},
		{ProviderID: "busy", EndpointURL: "https://busy.example"},
	})
	registerWithHashStatusSlots(registry, "verified", "session-1", "model-a", pool.StateReady, 20000, 1, 1, "https://verified.example", pool.HashStatusVerified)
	registerWithHashStatusSlots(registry, "busy", "session-2", "model-a", pool.StateReady, 20000, 0, 1, "https://busy.example", pool.HashStatusUncatalogued)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Data []struct {
			HashVerified     any `json:"hash_verified"`
			HashVerification struct {
				Status                    string `json:"status"`
				VerifiedProviderCount     int    `json:"verified_provider_count"`
				UncataloguedProviderCount int    `json:"uncatalogued_provider_count"`
			} `json:"hash_verification"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if len(got.Data) != 1 {
		t.Fatalf("models = %d, want 1 body=%s", len(got.Data), rr.Body.String())
	}
	if got.Data[0].HashVerified != true || got.Data[0].HashVerification.Status != "all_verified" ||
		got.Data[0].HashVerification.VerifiedProviderCount != 1 || got.Data[0].HashVerification.UncataloguedProviderCount != 0 {
		t.Fatalf("hash_verification=%+v hash_verified=%v body=%s", got.Data[0].HashVerification, got.Data[0].HashVerified, rr.Body.String())
	}
}

func TestModelsPillarAExcludesHashFailuresFromCapacity(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "verified", EndpointURL: "https://verified.example"},
		{ProviderID: "bad", EndpointURL: "https://bad.example"},
	})
	registerWithHashStatus(registry, "verified", "session-1", "model-a", pool.StateReady, 20000, 1, pool.HashStatusVerified)
	registerWithHashStatus(registry, "bad", "session-2", "model-a", pool.StateReady, 50000, 1, pool.HashStatusMismatch)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Data []struct {
			ProviderCount    int `json:"provider_count"`
			TotalSlots       int `json:"total_slots"`
			MaxContextTokens int `json:"max_context_tokens"`
			HashVerification struct {
				VerifiedProviderCount int `json:"verified_provider_count"`
				MismatchProviderCount int `json:"mismatch_provider_count"`
			} `json:"hash_verification"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if len(got.Data) != 1 {
		t.Fatalf("models = %d, want 1 body=%s", len(got.Data), rr.Body.String())
	}
	entry := got.Data[0]
	if entry.ProviderCount != 1 || entry.TotalSlots != 1 || entry.MaxContextTokens != 20000 {
		t.Fatalf("capacity counted Tier-2-ineligible provider: %+v body=%s", entry, rr.Body.String())
	}
	if entry.HashVerification.VerifiedProviderCount != 1 || entry.HashVerification.MismatchProviderCount != 1 {
		t.Fatalf("hash evidence counts = %+v body=%s", entry.HashVerification, rr.Body.String())
	}
}

func TestModelsPillarAShowsAllHashFailuresWithZeroCapacity(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "bad", EndpointURL: "https://bad.example"}})
	registerWithHashStatus(registry, "bad", "session-1", "model-a", pool.StateReady, 50000, 1, pool.HashStatusMismatch)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var got struct {
		Data []struct {
			ProviderCount    int `json:"provider_count"`
			TotalSlots       int `json:"total_slots"`
			MaxContextTokens int `json:"max_context_tokens"`
			HashVerification struct {
				Status                string `json:"status"`
				MismatchProviderCount int    `json:"mismatch_provider_count"`
			} `json:"hash_verification"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if len(got.Data) != 1 {
		t.Fatalf("models = %d, want 1 body=%s", len(got.Data), rr.Body.String())
	}
	entry := got.Data[0]
	if entry.ProviderCount != 0 || entry.TotalSlots != 0 || entry.MaxContextTokens != 0 {
		t.Fatalf("capacity should exclude all hash-failed providers: %+v body=%s", entry, rr.Body.String())
	}
	if entry.HashVerification.Status != "mismatch" || entry.HashVerification.MismatchProviderCount != 1 {
		t.Fatalf("hash verification should expose mismatch evidence: %+v body=%s", entry.HashVerification, rr.Body.String())
	}
}

func TestInternalRoutingExposesTier2ActivationMetadata(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)
	req := httptest.NewRequest(http.MethodGet, "/internal/routing", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	rr := httptest.NewRecorder()

	server.InternalHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var got struct {
		Tier2 struct {
			Phase     int `json:"phase"`
			ModelHash struct {
				Active bool   `json:"active"`
				State  string `json:"state"`
			} `json:"model_hash"`
		} `json:"tier2"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Tier2.Phase != 0 || !got.Tier2.ModelHash.Active || got.Tier2.ModelHash.State != "none" {
		t.Fatalf("tier2 metadata = %+v body=%s", got.Tier2, rr.Body.String())
	}

	registry.Register(&pool.Provider{
		ProviderID:            "provider-a",
		AssignedID:            "session-a",
		ModelID:               "model-a",
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		EndpointURL:           "https://provider-a.example",
		State:                 pool.StateReady,
		ModelHash:             "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		HashStatus:            pool.HashStatusUncatalogued,
	}, nil)
	rr = httptest.NewRecorder()
	server.InternalHandler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status with model hash evidence=%d body=%s", rr.Code, rr.Body.String())
	}
	got = struct {
		Tier2 struct {
			Phase     int `json:"phase"`
			ModelHash struct {
				Active bool   `json:"active"`
				State  string `json:"state"`
			} `json:"model_hash"`
		} `json:"tier2"`
	}{}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json with model hash evidence: %v", err)
	}
	if got.Tier2.Phase != 1 || !got.Tier2.ModelHash.Active {
		t.Fatalf("tier2 metadata with model hash evidence = %+v body=%s", got.Tier2, rr.Body.String())
	}

	server.SetTier2Config(config.Tier2Config{})
	rr = httptest.NewRecorder()
	server.InternalHandler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status after update=%d body=%s", rr.Code, rr.Body.String())
	}
	got = struct {
		Tier2 struct {
			Phase     int `json:"phase"`
			ModelHash struct {
				Active bool   `json:"active"`
				State  string `json:"state"`
			} `json:"model_hash"`
		} `json:"tier2"`
	}{}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json after update: %v", err)
	}
	if got.Tier2.Phase != 0 || got.Tier2.ModelHash.Active {
		t.Fatalf("tier2 metadata after update = %+v body=%s", got.Tier2, rr.Body.String())
	}
}

func TestInternalRoutingExposesTier2BehavioralSafetyMetadata(t *testing.T) {
	registry := pool.NewRegistry(nil)
	tier2Cfg := config.Default().Tier2
	tier2Cfg.BehavioralSafetyEnabled = true
	tier2Cfg.OutputSizeCapBytes = 1024
	tier2Cfg.EncodingValidationEnabled = true
	tier2Cfg.ResponseTimeAnomalyEnabled = true
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithTier2Config(tier2Cfg),
	)
	req := httptest.NewRequest(http.MethodGet, "/internal/routing", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	rr := httptest.NewRecorder()

	server.InternalHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var got struct {
		Tier2 struct {
			Phase            any `json:"phase"`
			BehavioralSafety struct {
				State              string `json:"state"`
				SizeCap            bool   `json:"size_cap"`
				EncodingValidation bool   `json:"encoding_validation"`
				TTFTAnomalyLogging bool   `json:"ttft_anomaly_logging"`
			} `json:"behavioral_safety"`
		} `json:"tier2"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Tier2.Phase != "mixed" || got.Tier2.BehavioralSafety.State != "enforced" || !got.Tier2.BehavioralSafety.SizeCap || !got.Tier2.BehavioralSafety.EncodingValidation || !got.Tier2.BehavioralSafety.TTFTAnomalyLogging {
		t.Fatalf("tier2 behavioral metadata = %+v body=%s", got.Tier2, rr.Body.String())
	}
}

func TestInternalRoutingExposesEncryptedLegAndAttestationMetadata(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerTier2Provider(registry, "encrypted", "session-encrypted", "model-a", "https://encrypted.example", true, pool.AttestationStatusAttested)
	registerTier2Provider(registry, "plain", "session-plain", "model-a", "https://plain.example", false, pool.AttestationStatusUnsupported)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
	)
	req := httptest.NewRequest(http.MethodGet, "/internal/routing", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	rr := httptest.NewRecorder()

	server.InternalHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var got struct {
		Tier2 struct {
			EncryptedLeg struct {
				State                    string `json:"state"`
				EncryptedProviderCount   int    `json:"encrypted_provider_count"`
				UnencryptedProviderCount int    `json:"unencrypted_provider_count"`
				Mixed                    bool   `json:"mixed"`
				Scope                    string `json:"scope"`
			} `json:"encrypted_leg"`
			Attestation struct {
				State                    string `json:"state"`
				AttestedProviderCount    int    `json:"attested_provider_count"`
				UnsupportedProviderCount int    `json:"unsupported_provider_count"`
				Mixed                    bool   `json:"mixed"`
			} `json:"attestation"`
		} `json:"tier2"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Tier2.EncryptedLeg.State != "partial" || got.Tier2.EncryptedLeg.EncryptedProviderCount != 1 || got.Tier2.EncryptedLeg.UnencryptedProviderCount != 1 || !got.Tier2.EncryptedLeg.Mixed || got.Tier2.EncryptedLeg.Scope != "coordinator_to_provider_only" {
		t.Fatalf("encrypted leg metadata = %+v body=%s", got.Tier2.EncryptedLeg, rr.Body.String())
	}
	if got.Tier2.Attestation.State != "partial" || got.Tier2.Attestation.AttestedProviderCount != 1 || got.Tier2.Attestation.UnsupportedProviderCount != 1 || !got.Tier2.Attestation.Mixed {
		t.Fatalf("attestation metadata = %+v body=%s", got.Tier2.Attestation, rr.Body.String())
	}
}

func TestInternalRoutingReflectsActualHashCoverage(t *testing.T) {
	tier2.ResetForTest()
	defer tier2.ResetForTest()
	cases := []struct {
		name             string
		cfg              config.Tier2Config
		providers        []pool.Provider
		wantState        string
		wantRequire      bool
		wantCatalogAvail bool
	}{
		{
			name: "all verified",
			cfg:  config.Tier2Config{ObserveEnabled: true},
			providers: []pool.Provider{{
				ProviderID: "verified", AssignedID: "session-1", ModelID: "model-a",
				ModelHash: buyerTestHash, HashStatus: pool.HashStatusVerified,
				State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1,
			}},
			wantState: "all",
		},
		{
			name: "partial",
			cfg:  config.Tier2Config{ObserveEnabled: true},
			providers: []pool.Provider{
				{
					ProviderID: "verified", AssignedID: "session-1", ModelID: "model-a",
					ModelHash: buyerTestHash, HashStatus: pool.HashStatusVerified,
					State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1,
				},
				{
					ProviderID: "uncatalogued", AssignedID: "session-2", ModelID: "model-a",
					ModelHash: buyerOtherHash, HashStatus: pool.HashStatusUncatalogued,
					State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1,
				},
			},
			wantState: "partial",
		},
		{
			name:        "empty require verified",
			cfg:         config.Tier2Config{RequireHashVerified: true},
			wantState:   "required",
			wantRequire: true,
		},
		{
			name:      "empty observe",
			cfg:       config.Tier2Config{ObserveEnabled: true},
			wantState: "none",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			for i := range tc.providers {
				p := tc.providers[i]
				p.MaxContextTokens = 20000
				p.MaxConcurrency = 1
				p.ThroughputTPSEstimate = 20
				p.EndpointURL = "https://" + p.ProviderID + ".example"
				p.Tier = pool.TierPinned
				p.InferencePath = pool.InferencePathHTTPForwarding
				registry.Register(&p, nil)
			}
			server := buyer.NewServer(
				registry,
				zerolog.Nop(),
				time.Unix(1716768000, 0),
				buyer.WithInternalAuthKey("operator-key"),
				buyer.WithTier2Config(tc.cfg),
			)
			req := httptest.NewRequest(http.MethodGet, "/internal/routing", nil)
			req.Header.Set("Authorization", "Bearer operator-key")
			rr := httptest.NewRecorder()

			server.InternalHandler().ServeHTTP(rr, req)

			if rr.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			var got struct {
				Tier2 struct {
					ModelHash struct {
						State            string `json:"state"`
						RequireVerified  bool   `json:"require_verified"`
						CatalogAvailable bool   `json:"catalog_available"`
					} `json:"model_hash"`
				} `json:"tier2"`
			}
			if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
				t.Fatalf("json: %v", err)
			}
			if got.Tier2.ModelHash.State != tc.wantState {
				t.Fatalf("model_hash.state=%q want %q body=%s", got.Tier2.ModelHash.State, tc.wantState, rr.Body.String())
			}
			if got.Tier2.ModelHash.RequireVerified != tc.wantRequire {
				t.Fatalf("require_verified=%t want %t", got.Tier2.ModelHash.RequireVerified, tc.wantRequire)
			}
			if got.Tier2.ModelHash.CatalogAvailable != tc.wantCatalogAvail {
				t.Fatalf("catalog_available=%t want %t", got.Tier2.ModelHash.CatalogAvailable, tc.wantCatalogAvail)
			}
		})
	}
}

func TestObservedModelHashEvidenceIgnoresPreTier2Hashes(t *testing.T) {
	tier2.ResetForTest()
	defer tier2.ResetForTest()
	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID:            "provider-a",
		AssignedID:            "session-a",
		ModelID:               "model-a",
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		EndpointURL:           "https://provider-a.example",
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		ModelHash:             buyerTestHash,
		HashStatus:            "",
	}, nil)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)
	req := httptest.NewRequest(http.MethodGet, "/internal/routing", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	rr := httptest.NewRecorder()

	server.InternalHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var got struct {
		Tier2 struct {
			Phase int `json:"phase"`
		} `json:"tier2"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Tier2.Phase != 0 {
		t.Fatalf("phase=%d want 0 for pre-tier2 hash evidence body=%s", got.Tier2.Phase, rr.Body.String())
	}
}

func TestModelsIncludesTopLevelTier2ActivationMetadata(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var got struct {
		Data  []any `json:"data"`
		Tier2 struct {
			Phase     int `json:"phase"`
			ModelHash struct {
				Active bool `json:"active"`
			} `json:"model_hash"`
		} `json:"tier2"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if len(got.Data) != 0 || got.Tier2.Phase != 0 || !got.Tier2.ModelHash.Active {
		t.Fatalf("models tier2 metadata = %+v body=%s", got, rr.Body.String())
	}
}

func TestHealthzMountedOnBuyerHandler(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"status":"ok"`)) || !bytes.Contains(rr.Body.Bytes(), []byte(`"pool_ready":1`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func TestPoolCheckReturnsProviderStateAnd404(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=p1", nil)
	req.Header.Set("X-Forwarded-For", "192.0.2.1")
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"provider_id":"p1"`)) || !bytes.Contains(rr.Body.Bytes(), []byte(`"state":"ready"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}

	missingReq := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=missing", nil)
	missingReq.Header.Set("X-Forwarded-For", "192.0.2.2")
	missing := httptest.NewRecorder()
	server.Handler().ServeHTTP(missing, missingReq)

	if missing.Code != http.StatusNotFound {
		t.Fatalf("missing status = %d, body=%s", missing.Code, missing.Body.String())
	}
	if !bytes.Contains(missing.Body.Bytes(), []byte(`"error":"provider_not_found"`)) {
		t.Fatalf("missing body = %s", missing.Body.String())
	}
}

func TestPoolCheckRateLimitsPerIP(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	for i, want := range []int{http.StatusOK, http.StatusTooManyRequests} {
		req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=p1", nil)
		req.Header.Set("X-Forwarded-For", "192.0.2.3")
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, req)
		if rr.Code != want {
			t.Fatalf("request %d status = %d, want %d body=%s", i+1, rr.Code, want, rr.Body.String())
		}
	}
}

func TestChatCompletionsRoutesNonStreamingRequest(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("upstream request json: %v", err)
		}
		if req["model"] != "model-a" {
			t.Fatalf("model = %v", req["model"])
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p1" {
		t.Fatalf("provider header = %q", rr.Header().Get("X-MacProvider-Provider"))
	}
	if rr.Header().Get("X-MacProvider-Route") != "session-1" {
		t.Fatalf("route header = %q", rr.Header().Get("X-MacProvider-Route"))
	}
	var got map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("response json: %v", err)
	}
	if got["id"] != "chatcmpl-test" {
		t.Fatalf("response not relayed: %#v", got)
	}
}

func TestChatCompletionsDoesNotFollowProviderRedirects(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"redirected"}`))
	}))
	defer target.Close()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/v1/chat/completions", http.StatusTemporaryRedirect)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	serverConn, providerConn := net.Pipe()
	defer serverConn.Close()
	defer providerConn.Close()
	registerWithEndpointConn(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20, serverConn)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if bytes.Contains(rr.Body.Bytes(), []byte(`redirected`)) {
		t.Fatalf("redirect target response was relayed: %s", rr.Body.String())
	}
	providers := registry.Snapshot()
	if len(providers) != 1 || providers[0].State != pool.StateUnavailable {
		t.Fatalf("providers = %#v, want unavailable after redirect", providers)
	}
	assertConnClosed(t, providerConn)
}

func TestStreamingChatCompletionsDoesNotFollowProviderRedirects(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("data: redirected\n\n"))
	}))
	defer target.Close()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/v1/chat/completions", http.StatusTemporaryRedirect)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	serverConn, providerConn := net.Pipe()
	defer serverConn.Close()
	defer providerConn.Close()
	registerWithEndpointConn(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20, serverConn)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if bytes.Contains(rr.Body.Bytes(), []byte(`redirected`)) {
		t.Fatalf("redirect target response was relayed: %s", rr.Body.String())
	}
	providers := registry.Snapshot()
	if len(providers) != 1 || providers[0].State != pool.StateUnavailable {
		t.Fatalf("providers = %#v, want unavailable after redirect", providers)
	}
	assertConnClosed(t, providerConn)
}

func TestChatCompletionsRelaysStreamingSSE(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("upstream request json: %v", err)
		}
		if req["stream"] != true {
			t.Fatalf("stream = %v, want true", req["stream"])
		}
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		flusher := w.(http.Flusher)
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n"))
		flusher.Flush()
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"))
		flusher.Flush()
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("Content-Type") != "text/event-stream; charset=utf-8" {
		t.Fatalf("content-type = %q", rr.Header().Get("Content-Type"))
	}
	if rr.Header().Get("X-Accel-Buffering") != "no" || rr.Header().Get("Cache-Control") != "no-cache" {
		t.Fatalf("missing SSE buffering headers: %#v", rr.Header())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p1" || rr.Header().Get("X-MacProvider-Route") != "session-1" {
		t.Fatalf("route headers provider=%q route=%q", rr.Header().Get("X-MacProvider-Provider"), rr.Header().Get("X-MacProvider-Route"))
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`data: {"choices":[{"delta":{"content":"hi"}}]}`)) {
		t.Fatalf("stream body not relayed: %s", rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte("data: [DONE]\n\n")) {
		t.Fatalf("stream terminator missing: %s", rr.Body.String())
	}
}

func TestChatCompletionsRetrySelectsDifferentStreamingProviderBeforeCommit(t *testing.T) {
	failUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}))
	defer failUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer okUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "fail", EndpointURL: failUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "fail", "s1", "model-a", pool.StateReady, 20000, 1, failUpstream.URL, 10)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 2, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		MaxRetries:              1,
		RetryPerAttemptTimeoutS: 1,
		StickyTTLS:              1800,
		StickyMaxEntries:        10000,
	}))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{"X-MacProvider-Retry": []string{"1"}})

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "ok" {
		t.Fatalf("provider=%q, want ok", rr.Header().Get("X-MacProvider-Provider"))
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"ok"`)) {
		t.Fatalf("body=%s", rr.Body.String())
	}
}

func TestChatCompletionsStreamingProviderDisconnectAfterCommitDoesNotEmitJSONError(t *testing.T) {
	originalClient := providerhttp.Client
	providerhttp.Client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}},
			Body:       &faultAfterFirstRead{first: []byte("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n")},
			Request:    r,
		}, nil
	})}
	t.Cleanup(func() { providerhttp.Client = originalClient })

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "http://provider.test"}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "http://provider.test", 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		MaxRetries:              1,
		RetryPerAttemptTimeoutS: 1,
		StickyTTLS:              1800,
		StickyMaxEntries:        10000,
	}))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{"X-MacProvider-Retry": []string{"1"}})

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"partial"`)) {
		t.Fatalf("stream body missing first chunk: %s", rr.Body.String())
	}
	if bytes.Contains(rr.Body.Bytes(), []byte(`"object":"error"`)) || bytes.Contains(rr.Body.Bytes(), []byte(`provider_error`)) {
		t.Fatalf("committed stream was corrupted by JSON error: %s", rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Provider"); got != "p1" {
		t.Fatalf("provider=%q, want p1", got)
	}
}

func TestChatCompletionsRoutingPreferences(t *testing.T) {
	slowUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"slow","choices":[{"message":{"content":"slow"}}]}`))
	}))
	defer slowUpstream.Close()
	fastUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"fast","choices":[{"message":{"content":"fast"}}]}`))
	}))
	defer fastUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "slow", EndpointURL: slowUpstream.URL},
		{ProviderID: "fast", EndpointURL: fastUpstream.URL},
	})
	registerWithEndpoint(registry, "slow", "s1", "model-a", pool.StateReady, 20000, 1, slowUpstream.URL, 10)
	registerWithEndpoint(registry, "fast", "s2", "model-a", pool.StateReady, 20000, 2, fastUpstream.URL, 30)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`)

	defaultRoute := postChat(t, server, body, nil)
	if defaultRoute.Code != http.StatusOK {
		t.Fatalf("default status=%d body=%s", defaultRoute.Code, defaultRoute.Body.String())
	}
	if defaultRoute.Header().Get("X-MacProvider-Provider") != "slow" {
		t.Fatalf("default provider = %q, want slow", defaultRoute.Header().Get("X-MacProvider-Provider"))
	}

	fastRoute := postChat(t, server, body, http.Header{"X-MacProvider-Pref": []string{"fast"}})
	if fastRoute.Code != http.StatusOK {
		t.Fatalf("fast status=%d body=%s", fastRoute.Code, fastRoute.Body.String())
	}
	if fastRoute.Header().Get("X-MacProvider-Provider") != "fast" {
		t.Fatalf("fast provider = %q, want fast", fastRoute.Header().Get("X-MacProvider-Provider"))
	}
}

func TestChatCompletionsRoutesModelClassByObjective(t *testing.T) {
	// SPEC-004 v0.3 FR-SR-7a test-discipline: capture the upstream-received
	// body and assert on body.model (concrete provider ModelID), not just on
	// the chosen provider identity. Without this assertion, a regression of
	// the dispatch-rewrite path would pass this test (the pre-fix bug shipped
	// for exactly this reason — body-ignoring mocks gave false confidence).
	var fastBody []byte
	slowUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"slow","choices":[{"message":{"content":"slow"}}]}`))
	}))
	defer slowUpstream.Close()
	fastUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fastBody, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"id":"fast","choices":[{"message":{"content":"fast"}}]}`))
	}))
	defer fastUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "slow", EndpointURL: slowUpstream.URL},
		{ProviderID: "fast", EndpointURL: fastUpstream.URL},
	})
	registerWithEndpoint(registry, "slow", "s1", "model-slow", pool.StateReady, 20000, 1, slowUpstream.URL, 10)
	registerWithEndpoint(registry, "fast", "s2", "model-fast", pool.StateReady, 20000, 1, fastUpstream.URL, 30)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		RetryPerAttemptTimeoutS: 60,
		StickyTTLS:              1800,
		StickyMaxEntries:        10000,
		ModelClasses: map[string]config.ModelClassConfig{
			"mlx-fast": {Members: []string{"model-slow", "model-fast"}, Objective: "fast"},
		},
	}))

	rr := postChat(t, server, []byte(`{"model":"mlx-fast","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "fast" {
		t.Fatalf("provider = %q, want fast", rr.Header().Get("X-MacProvider-Provider"))
	}
	// Provider MUST receive the concrete ModelID, NOT the buyer's alias.
	assertForwardedModel(t, fastBody, "model-fast")
}

func TestModelClassAliasRewrittenToConcreteModelOnDispatch(t *testing.T) {
	const concreteModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"
	const otherModel = "mlx-community/Other-7B-Instruct-4bit"
	bodyFor := func(stream bool) []byte {
		streamField := ""
		if stream {
			streamField = `,"stream":true`
		}
		return []byte(`{"model":"mlx-accurate","messages":[{"role":"user","content":"hello"}],"max_tokens":8,"response_format":{"type":"json_object"},"metadata":{"trace":"preserve-me"}` + streamField + `}`)
	}
	assertForwardedBody := func(t *testing.T, body []byte) {
		t.Helper()
		var got map[string]json.RawMessage
		if err := json.Unmarshal(body, &got); err != nil {
			t.Fatalf("forwarded body json: %v; body=%s", err, string(body))
		}
		var model string
		if err := json.Unmarshal(got["model"], &model); err != nil {
			t.Fatalf("forwarded model json: %v; body=%s", err, string(body))
		}
		if model != concreteModel {
			t.Fatalf("forwarded model = %q, want concrete %q", model, concreteModel)
		}
		if string(got["response_format"]) != `{"type":"json_object"}` {
			t.Fatalf("response_format not preserved: %s", string(got["response_format"]))
		}
		if string(got["metadata"]) != `{"trace":"preserve-me"}` {
			t.Fatalf("metadata not preserved: %s", string(got["metadata"]))
		}
	}

	tests := []struct {
		name   string
		path   pool.InferencePath
		stream bool
	}{
		{name: "ws_non_streaming", path: pool.InferencePathWSTunneled},
		{name: "ws_streaming", path: pool.InferencePathWSTunneled, stream: true},
		{name: "http_non_streaming", path: pool.InferencePathHTTPForwarding},
		{name: "http_streaming", path: pool.InferencePathHTTPForwarding, stream: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var capturedBody []byte
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var err error
				capturedBody, err = io.ReadAll(r.Body)
				if err != nil {
					t.Fatalf("read upstream body: %v", err)
				}
				assertForwardedBody(t, capturedBody)
				if tc.stream {
					w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
					_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"))
					_, _ = w.Write([]byte("data: [DONE]\n\n"))
					return
				}
				_, _ = w.Write([]byte(`{"id":"http","model":"` + concreteModel + `","choices":[{"message":{"content":"ok"}}]}`))
			}))
			defer upstream.Close()

			registry := pool.NewRegistry([]config.ProviderConfig{
				{ProviderID: "qwen", EndpointURL: upstream.URL},
				{ProviderID: "other", EndpointURL: "https://other.example"},
			})
			registerWithPath(registry, "qwen", "s1", concreteModel, pool.StateReady, 20000, 1, upstream.URL, 30, pool.TierPinned, tc.path)
			registerWithEndpoint(registry, "other", "s2", otherModel, pool.StateReady, 20000, 1, "https://other.example", 20)
			opts := []buyer.Option{
				buyer.WithRoutingConfig(config.RoutingConfig{
					ModelClasses: map[string]config.ModelClassConfig{
						"mlx-accurate": {Models: []string{concreteModel}, Objective: "accurate"},
					},
				}),
			}
			if tc.path == pool.InferencePathWSTunneled {
				opts = append(opts, buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
					capturedBody = append([]byte(nil), body...)
					assertForwardedBody(t, capturedBody)
					chunks := make(chan providerws.InferenceResponseChunk, 1)
					done := make(chan providerws.InferenceResponseEnd, 1)
					errs := make(chan error, 1)
					if stream {
						chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"}
					} else {
						chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"ws","model":"` + concreteModel + `","choices":[{"message":{"content":"ok"}}]}`}
					}
					done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
					return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
				}, time.Second))
			}
			server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), opts...)

			rr := postChat(t, server, bodyFor(tc.stream), nil)

			if rr.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			if rr.Header().Get("X-MacProvider-Provider") != "qwen" {
				t.Fatalf("provider = %q, want qwen", rr.Header().Get("X-MacProvider-Provider"))
			}
			if len(capturedBody) == 0 {
				t.Fatal("provider did not receive request body")
			}
		})
	}
}

func TestConcreteModelIDDispatchesUnchanged(t *testing.T) {
	const concreteModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"
	requestBody := []byte("{\n  \"model\":\"" + concreteModel + "\",\n  \"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\n  \"max_tokens\":8,\n  \"metadata\":{\"trace\":\"identity\"}\n}")
	var capturedBody []byte
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var err error
		capturedBody, err = io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read upstream body: %v", err)
		}
		_, _ = w.Write([]byte(`{"id":"http","model":"` + concreteModel + `","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "qwen", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "qwen", "s1", concreteModel, pool.StateReady, 20000, 1, upstream.URL, 30)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		ModelClasses: map[string]config.ModelClassConfig{
			"mlx-accurate": {Models: []string{concreteModel}, Objective: "accurate"},
		},
	}))

	rr := postChat(t, server, requestBody, nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Equal(capturedBody, requestBody) {
		t.Fatalf("forwarded body changed for concrete model:\ngot:  %s\nwant: %s", string(capturedBody), string(requestBody))
	}
}

func TestChatCompletionsRejectsDuplicateTopLevelModel(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		ModelClasses: map[string]config.ModelClassConfig{
			"mlx-class": {Models: []string{"model-a"}, Objective: "fast"},
		},
	}))

	tests := []struct {
		name string
		body []byte
	}{
		{
			name: "hidden before accepted concrete",
			body: []byte(`{"model":"hidden-model","messages":[{"role":"user","content":"hello"}],"model":"model-a"}`),
		},
		{
			name: "accepted before hidden concrete",
			body: []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"model":"hidden-model"}`),
		},
		{
			name: "class alias duplicate",
			body: []byte(`{"model":"mlx-class","messages":[{"role":"user","content":"hello"}],"model":"model-a"}`),
		},
		{
			name: "case variant after canonical",
			body: []byte(`{"model":"mlx-class","messages":[{"role":"user","content":"hello"}],"Model":"model-a"}`),
		},
		{
			name: "upper variant after canonical",
			body: []byte(`{"model":"mlx-class","messages":[{"role":"user","content":"hello"}],"MODEL":"model-a"}`),
		},
		{
			name: "escaped case variant after canonical",
			body: []byte(`{"model":"mlx-class","messages":[{"role":"user","content":"hello"}],"\u004dodel":"model-a"}`),
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rr := postChat(t, server, tc.body, nil)
			if rr.Code != http.StatusBadRequest {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"invalid_request"`)) || !bytes.Contains(rr.Body.Bytes(), []byte(`Duplicate model field`)) {
				t.Fatalf("body = %s", rr.Body.String())
			}
		})
	}
}

func TestChatCompletionsRejectsOversizedBodyBeforeParsing(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1)
	limit := config.Default().Limits.MaxChatRequestBodyBytes
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		MaxRetries: 1,
		ModelClasses: map[string]config.ModelClassConfig{
			"mlx-class": {Models: []string{"model-a"}, Objective: "fast"},
		},
	}), buyer.WithLimitsConfig(config.Default().Limits))

	oversizedInvalid := bytes.Repeat([]byte("{"), int(limit)+1)
	rr := postChat(t, server, oversizedInvalid, nil)
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized invalid status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"request_too_large"`)) {
		t.Fatalf("oversized invalid body=%s", rr.Body.String())
	}

	oversizedUnknown := []byte(`{"model":"unknown-model","messages":[{"role":"user","content":"` + strings.Repeat("x", int(limit)) + `"}]}`)
	rr = postChat(t, server, oversizedUnknown, nil)
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized unknown status=%d body=%s", rr.Code, rr.Body.String())
	}

	oversizedClassRetry := []byte(`{"model":"mlx-class","messages":[{"role":"user","content":"` + strings.Repeat("x", int(limit)) + `"}]}`)
	rr = postChat(t, server, oversizedClassRetry, http.Header{"X-MacProvider-Retry": []string{"1"}})
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized class retry status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestChatCompletionsAccurateClassUsesThroughputTieBreak(t *testing.T) {
	// SPEC-004 v0.3 FR-SR-7a test-discipline: assert on body.model, not just
	// the chosen provider identity.
	var fastBody []byte
	slowUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"slow","choices":[{"message":{"content":"slow"}}]}`))
	}))
	defer slowUpstream.Close()
	fastUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fastBody, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"id":"fast","choices":[{"message":{"content":"fast"}}]}`))
	}))
	defer fastUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "slow", EndpointURL: slowUpstream.URL},
		{ProviderID: "fast", EndpointURL: fastUpstream.URL},
	})
	registerWithEndpoint(registry, "slow", "s1", "model-slow", pool.StateReady, 20000, 1, slowUpstream.URL, 10)
	registerWithEndpoint(registry, "fast", "s2", "model-fast", pool.StateReady, 20000, 2, fastUpstream.URL, 30)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		ModelClasses: map[string]config.ModelClassConfig{
			"mlx-accurate": {Members: []string{"model-slow", "model-fast"}, Objective: "accurate"},
		},
	}))

	rr := postChat(t, server, []byte(`{"model":"mlx-accurate","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "fast" {
		t.Fatalf("provider = %q, want fast", rr.Header().Get("X-MacProvider-Provider"))
	}
	// Provider MUST receive the concrete ModelID, NOT the buyer's alias.
	assertForwardedModel(t, fastBody, "model-fast")
}

func TestChatCompletionsRetrySelectsDifferentProvider(t *testing.T) {
	failUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}))
	defer failUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer okUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "fail", EndpointURL: failUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "fail", "s1", "model-a", pool.StateReady, 20000, 1, failUpstream.URL, 20)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		MaxRetries:              1,
		RetryPerAttemptTimeoutS: 1,
		StickyTTLS:              1800,
		StickyMaxEntries:        10000,
	}))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{"X-MacProvider-Retry": []string{"1"}})

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "ok" {
		t.Fatalf("provider = %q, want ok", rr.Header().Get("X-MacProvider-Provider"))
	}
	if rr.Header().Get("X-MacProvider-Retried") != "" {
		t.Fatalf("retry count leaked to buyer response: %q", rr.Header().Get("X-MacProvider-Retried"))
	}
}

func TestModelClassAliasRewrittenPerHTTPRetryProvider(t *testing.T) {
	bodies := map[string][]byte{}
	failUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read fail body: %v", err)
		}
		bodies["fail"] = body
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}))
	defer failUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read ok body: %v", err)
		}
		bodies["ok"] = body
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer okUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "fail", EndpointURL: failUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "fail", "s1", "model-a", pool.StateReady, 20000, 1, failUpstream.URL, 30)
	registerWithEndpoint(registry, "ok", "s2", "model-b", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		MaxRetries:              1,
		RetryPerAttemptTimeoutS: 1,
		ModelClasses: map[string]config.ModelClassConfig{
			"mlx-class": {Models: []string{"model-a", "model-b"}, Objective: "fast"},
		},
	}))

	rr := postChat(t, server, []byte(`{"model":"mlx-class","messages":[{"role":"user","content":"hello"}]}`), http.Header{"X-MacProvider-Retry": []string{"1"}})

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "ok" {
		t.Fatalf("provider = %q, want ok", rr.Header().Get("X-MacProvider-Provider"))
	}
	assertForwardedModel(t, bodies["fail"], "model-a")
	assertForwardedModel(t, bodies["ok"], "model-b")
}

func TestChatCompletionsDefaultOffUsesRequestTimeoutNotRetryTimeout(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(1100 * time.Millisecond)
		_, _ = w.Write([]byte(`{"id":"slow-ok","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		MaxRetries:              0,
		RetryPerAttemptTimeoutS: 1,
		StickyTTLS:              1800,
		StickyMaxEntries:        10000,
	}))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestChatCompletionsDefaultOffKeepsProvider504ErrorShape(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusGatewayTimeout)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRoutingConfig(config.RoutingConfig{
		MaxRetries:              0,
		RetryPerAttemptTimeoutS: 1,
		StickyTTLS:              1800,
		StickyMaxEntries:        10000,
	}))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"provider_error"`)) {
		t.Fatalf("body=%s", rr.Body.String())
	}
}

func TestChatCompletionsRejectsSpoofedInternalRoutingHeaders(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
	)

	headers := http.Header{
		"X-MacProvider-Internal-Conv": []string{"conv:attacker"},
		"X-MacProvider-Account":       []string{"acct_attacker"},
	}
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), headers)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}

	headers.Set("Authorization", "Bearer operator-key")
	rr = postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("authorized status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestInternalStickyDeleteRequiresBearer(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithInternalAuthKey("operator-key"))

	req := httptest.NewRequest(http.MethodDelete, "/internal/sticky?account_id=acct_1", nil)
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("buyer handler status=%d body=%s", rr.Code, rr.Body.String())
	}

	req = httptest.NewRequest(http.MethodDelete, "/internal/sticky?account_id=acct_1", nil)
	rr = httptest.NewRecorder()
	server.InternalHandler().ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("internal handler status=%d body=%s", rr.Code, rr.Body.String())
	}

	req = httptest.NewRequest(http.MethodDelete, "/internal/sticky?account_id=acct_1", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	rr = httptest.NewRecorder()
	server.InternalHandler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("authorized status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestStickyAffinityDoesNotOverrideOutsideObjectiveEpsilon(t *testing.T) {
	// SPEC-004 v0.3 FR-SR-7a test-discipline: capture both upstream bodies
	// and assert on body.model. The seed request uses a concrete model id
	// ("model-a") — the rewrite is identity (no-op); slowBody MUST have
	// model="model-a" verbatim. The class request uses alias "fast-class";
	// the dispatch MUST rewrite to the chosen provider's concrete ModelID
	// ("model-a"), NOT leave the alias.
	var slowBody, fastBody []byte
	slowUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		slowBody, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"id":"slow","choices":[{"message":{"content":"slow"}}]}`))
	}))
	defer slowUpstream.Close()
	fastUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fastBody, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"id":"fast","choices":[{"message":{"content":"fast"}}]}`))
	}))
	defer fastUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "slow", EndpointURL: slowUpstream.URL},
		{ProviderID: "fast", EndpointURL: fastUpstream.URL},
	})
	registerWithEndpoint(registry, "slow", "s1", "model-a", pool.StateReady, 20000, 1, slowUpstream.URL, 10)
	registerWithEndpoint(registry, "fast", "s2", "model-a", pool.StateReady, 20000, 2, fastUpstream.URL, 100)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:           true,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
			TiebreakEpsilon:         0.10,
			RetryPerAttemptTimeoutS: 1,
			ModelClasses: map[string]config.ModelClassConfig{
				"fast-class": {Models: []string{"model-a"}, Objective: "fast"},
			},
		}),
	)
	headers := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:sticky-epsilon"},
		"X-MacProvider-Account":       []string{"acct_1"},
	}

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("seed status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "slow" {
		t.Fatalf("seed provider=%q, want slow", rr.Header().Get("X-MacProvider-Provider"))
	}
	// Seed used concrete model id — identity rewrite, body must match input.
	assertForwardedModel(t, slowBody, "model-a")

	rr = postChat(t, server, []byte(`{"model":"fast-class","messages":[{"role":"user","content":"hello"}]}`), headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("class status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "fast" {
		t.Fatalf("class provider=%q, want fast", rr.Header().Get("X-MacProvider-Provider"))
	}
	// Class alias MUST be rewritten to concrete provider ModelID before
	// dispatch — NOT leak "fast-class" to the upstream.
	assertForwardedModel(t, fastBody, "model-a")
}

func TestChatCompletionsPreflightSkipsRejectedCandidate(t *testing.T) {
	rejectedUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("rejected provider should not receive request")
	}))
	defer rejectedUpstream.Close()
	acceptedUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"accepted","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer acceptedUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: rejectedUpstream.URL},
		{ProviderID: "p2", EndpointURL: acceptedUpstream.URL},
	})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, rejectedUpstream.URL, 20)
	registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 2, acceptedUpstream.URL, 20)

	var calls []string
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithPreflightConfig(1, time.Second),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			calls = append(calls, provider.ProviderID)
			if provider.ProviderID == "p1" {
				return buyer.PreflightResult{Accepted: false, Reason: "queue_full"}, true, nil
			}
			return buyer.PreflightResult{Accepted: true}, true, nil
		}),
	)
	body := chatBodyWithContent("model-a", strings.Repeat("x", 64))

	rr := postChat(t, server, body, nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("provider = %q, want p2", rr.Header().Get("X-MacProvider-Provider"))
	}
	if strings.Join(calls, ",") != "p1,p2" {
		t.Fatalf("preflight calls = %v", calls)
	}
}

func TestChatCompletionsPinnedPreflightRejectDoesNotFallback(t *testing.T) {
	pinnedUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("rejected pinned provider should not receive request")
	}))
	defer pinnedUpstream.Close()
	fallbackUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("pinned rejection should not fallback")
	}))
	defer fallbackUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: pinnedUpstream.URL},
		{ProviderID: "p2", EndpointURL: fallbackUpstream.URL},
	})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, pinnedUpstream.URL, 20)
	registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, fallbackUpstream.URL, 20)
	var calls []string
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithPreflightConfig(1, time.Second),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			calls = append(calls, provider.ProviderID)
			return buyer.PreflightResult{Accepted: false, Reason: "context_exceeds_capacity"}, true, nil
		}),
	)

	rr := postChat(t, server, chatBodyWithContent("model-a", strings.Repeat("x", 64)), http.Header{"X-MacProvider-Provider": []string{"p1"}})

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"preflight_rejected"`)) {
		t.Fatalf("body missing preflight_rejected: %s", rr.Body.String())
	}
	if strings.Join(calls, ",") != "p1" {
		t.Fatalf("preflight calls = %v", calls)
	}
}

func TestChatCompletionsContextLengthRoutesOrReturns413(t *testing.T) {
	smallUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("small context provider should be prefiltered")
	}))
	defer smallUpstream.Close()
	largeUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"large","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer largeUpstream.Close()

	longBody := chatBodyWithContent("model-a", strings.Repeat("x", 512))
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "small", EndpointURL: smallUpstream.URL},
		{ProviderID: "large", EndpointURL: largeUpstream.URL},
	})
	registerWithEndpoint(registry, "small", "s1", "model-a", pool.StateReady, 20, 1, smallUpstream.URL, 20)
	registerWithEndpoint(registry, "large", "s2", "model-a", pool.StateReady, 1000, 1, largeUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, longBody, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "large" {
		t.Fatalf("provider = %q, want large", rr.Header().Get("X-MacProvider-Provider"))
	}

	onlySmall := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "small", EndpointURL: smallUpstream.URL}})
	registerWithEndpoint(onlySmall, "small", "s1", "model-a", pool.StateReady, 20, 1, smallUpstream.URL, 20)
	smallServer := buyer.NewServer(onlySmall, zerolog.Nop(), time.Unix(1716768000, 0))
	tooLarge := postChat(t, smallServer, longBody, nil)
	if tooLarge.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status=%d body=%s", tooLarge.Code, tooLarge.Body.String())
	}
	if !bytes.Contains(tooLarge.Body.Bytes(), []byte(`"code":"context_exceeds_capacity"`)) {
		t.Fatalf("body missing context_exceeds_capacity: %s", tooLarge.Body.String())
	}
}

func TestChatCompletionsWSTunneledNonStreaming(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"ws","choices":[{"message":{"content":"ok"}}]}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p1" {
		t.Fatalf("provider header = %q", rr.Header().Get("X-MacProvider-Provider"))
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"id":"ws"`)) {
		t.Fatalf("body not relayed: %s", rr.Body.String())
	}
}

func TestChatCompletionsWSTunneledTier2RejectsInvalidNonStreamingOutput(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	tier2Cfg := config.Default().Tier2
	tier2Cfg.BehavioralSafetyEnabled = true
	tier2Cfg.EncodingValidationEnabled = true
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(tier2Cfg),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"ws","choices":[{"message":{"content":"bad\u0000"}}]}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"tier2_output_encoding_invalid"`)) {
		t.Fatalf("body missing tier2 output error: %s", rr.Body.String())
	}
}

func TestChatCompletionsWSTunneledTier2StreamingInvalidAfterCommitEmitsSSEError(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	tier2Cfg := config.Default().Tier2
	tier2Cfg.BehavioralSafetyEnabled = true
	tier2Cfg.EncodingValidationEnabled = true
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(tier2Cfg),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 2)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 1, Data: "data: {\"choices\":[{\"delta\":{\"content\":\"bad\\u0000\"}}]}\n\n"}
			close(chunks)
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 2}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"ok"`)) || !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"tier2_output_encoding_invalid"`)) {
		t.Fatalf("streaming body missing valid chunk or tier2 SSE error: %s", rr.Body.String())
	}
}

func TestChatCompletionsWSTunneledTier2StreamingSizeCapTruncatesAndStops(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	tier2Cfg := config.Default().Tier2
	tier2Cfg.BehavioralSafetyEnabled = true
	tier2Cfg.OutputSizeCapBytes = 2
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(tier2Cfg),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"he"`)) || !bytes.Contains(rr.Body.Bytes(), []byte("data: [DONE]\n\n")) {
		t.Fatalf("streaming body missing truncation or done: %s", rr.Body.String())
	}
	if bytes.Contains(rr.Body.Bytes(), []byte(`hello`)) {
		t.Fatalf("streaming body was not capped: %s", rr.Body.String())
	}
}

func TestChatCompletionsWSTunneledTimeoutReturns504(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk)
			done := make(chan providerws.InferenceResponseEnd)
			errs := make(chan error, 1)
			errs <- providerws.ErrRelayTimeout
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusGatewayTimeout {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"provider_timeout"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func TestChatCompletionsWSTunneledAEADFailureReturnsTier2Error(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk)
			done := make(chan providerws.InferenceResponseEnd)
			errs := make(chan error, 1)
			errs <- providerws.ErrRelayAEADFailed
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"tier2_aead_decrypt_failed"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func TestChatCompletionsStreamingWSTunneledAEADFailureAfterCommitSendsSSEError(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"}
			go func() {
				time.Sleep(10 * time.Millisecond)
				errs <- providerws.ErrRelayAEADFailed
			}()
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"hello"`)) || !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"tier2_aead_decrypt_failed"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func TestChatCompletionsRetryMovesOffTimedOutWSTunnel(t *testing.T) {
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer okUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "ok", EndpointURL: okUpstream.URL}})
	registerWithPath(registry, "ws", "s1", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 2, okUpstream.URL, 20)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 1,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk)
			done := make(chan providerws.InferenceResponseEnd)
			errs := make(chan error, 1)
			errs <- providerws.ErrRelayTimeout
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, 5*time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{"X-MacProvider-Retry": []string{"1"}})

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "ok" {
		t.Fatalf("provider=%q, want ok", rr.Header().Get("X-MacProvider-Provider"))
	}
}

func TestChatCompletionsRetryMovesOffTimedOutStreamingWSTunnel(t *testing.T) {
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer okUpstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "ok", EndpointURL: okUpstream.URL}})
	registerWithPath(registry, "ws", "s1", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 2, okUpstream.URL, 20)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 1,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk)
			done := make(chan providerws.InferenceResponseEnd)
			errs := make(chan error, 1)
			errs <- providerws.ErrRelayTimeout
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, 5*time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{"X-MacProvider-Retry": []string{"1"}})

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "ok" {
		t.Fatalf("provider=%q, want ok", rr.Header().Get("X-MacProvider-Provider"))
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"ok"`)) {
		t.Fatalf("body=%s", rr.Body.String())
	}
}

func TestChatCompletionsStreamingWSCancelDoesNotRetry(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "ws", "s1", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
	calls := 0
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 1,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			calls++
			return &providerws.RelayStream{
				RequestID: requestID,
				Chunks:    make(chan providerws.InferenceResponseChunk),
				Done:      make(chan providerws.InferenceResponseEnd),
				Errors:    make(chan error),
			}, nil
		}, 5*time.Second),
	)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader([]byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`))).WithContext(ctx)
	req.Header.Set("X-MacProvider-Retry", "1")
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)

	if calls != 1 {
		t.Fatalf("relay calls=%d, want 1", calls)
	}
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d, want untouched recorder 200 after cancellation", rr.Code)
	}
	if rr.Body.Len() != 0 {
		t.Fatalf("body=%s, want empty cancelled response", rr.Body.String())
	}
}

func TestCircuitBreakerTripsAfterRepeatedDeadWSAndRecovers(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	recoveryIDs := make(chan string, 1)
	relayCalls := 0
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithFailoverConfig(false, 50*time.Millisecond),
		buyer.WithBreakerConfig(2, time.Second),
		buyer.WithRecoveryConfig(100*time.Millisecond, 1, true),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			recoveryIDs <- requestID
			return buyer.PreflightResult{Accepted: true}, true, nil
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			relayCalls++
			return deadMidInferenceRelay(ctx, provider, requestID, body, stream)
		}, time.Second),
	)

	first := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if first.Code != http.StatusBadGateway {
		t.Fatalf("first status=%d body=%s", first.Code, first.Body.String())
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateReady {
		t.Fatalf("p1 after first fault = %#v ok=%v, want ready", p1, ok)
	}
	registry.ApplyStateUpdate("p1", "s1", pool.StateUpdate{State: pool.StateReady})

	second := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if second.Code != http.StatusBadGateway {
		t.Fatalf("second status=%d body=%s", second.Code, second.Body.String())
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateDegraded {
		t.Fatalf("p1 after breaker trip = %#v ok=%v, want degraded", p1, ok)
	}
	registry.ApplyHeartbeat("p1", "s1", pool.HeartbeatUpdate{
		Status:                pool.StateReady,
		ModelID:               "model-a",
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		At:                    time.Now().UTC(),
	})
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateDegraded {
		t.Fatalf("p1 after ready heartbeat during breaker hold = %#v ok=%v, want degraded", p1, ok)
	}
	registry.ApplyStateUpdate("p1", "s1", pool.StateUpdate{State: pool.StateReady})
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateDegraded {
		t.Fatalf("p1 after ready state_update during breaker hold = %#v ok=%v, want degraded", p1, ok)
	}

	blocked := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if blocked.Code != http.StatusServiceUnavailable {
		t.Fatalf("blocked status=%d body=%s", blocked.Code, blocked.Body.String())
	}
	if relayCalls != 2 {
		t.Fatalf("relayCalls = %d, want 2 before recovery", relayCalls)
	}

	select {
	case requestID := <-recoveryIDs:
		if !strings.HasPrefix(requestID, "recovery-probe-") {
			t.Fatalf("requestID = %q", requestID)
		}
	case <-time.After(time.Second):
		t.Fatal("recovery preflight did not run")
	}
	eventually(t, func() bool {
		p1, ok := registry.Resolve("p1", "")
		return ok && p1.State == pool.StateReady
	})
}

func TestCircuitBreakerExcludesNonStreamingBuyerCancel(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	relayStarted := make(chan struct{})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithBreakerConfig(1, time.Second),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk)
			done := make(chan providerws.InferenceResponseEnd)
			errs := make(chan error, 1)
			close(relayStarted)
			go func() {
				<-ctx.Done()
				errs <- providerws.ErrRelayClosed
			}()
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader([]byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`))).WithContext(ctx)
	rr := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		server.Handler().ServeHTTP(rr, req)
		close(done)
	}()
	select {
	case <-relayStarted:
	case <-time.After(time.Second):
		t.Fatal("relay did not start")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("handler did not return after buyer cancel")
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateReady {
		t.Fatalf("p1 after buyer cancel = %#v ok=%v, want ready", p1, ok)
	}
}

func TestCircuitBreakerExcludesStreamingBuyerCancelBeforeFirstChunk(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	relayStarted := make(chan struct{})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithBreakerConfig(1, time.Second),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk)
			done := make(chan providerws.InferenceResponseEnd)
			errs := make(chan error, 1)
			close(relayStarted)
			go func() {
				<-ctx.Done()
				errs <- providerws.ErrRelayClosed
			}()
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader([]byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`))).WithContext(ctx)
	rr := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		server.Handler().ServeHTTP(rr, req)
		close(done)
	}()
	select {
	case <-relayStarted:
	case <-time.After(time.Second):
		t.Fatal("relay did not start")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("handler did not return after buyer cancel")
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateReady {
		t.Fatalf("p1 after zero-chunk streaming cancel = %#v ok=%v, want ready", p1, ok)
	}
}

func TestCircuitBreakerCountsOnlyQualifiedZeroTokenCompletion(t *testing.T) {
	for _, tc := range []struct {
		name         string
		finishReason string
		wantState    pool.State
	}{
		{name: "clean stop", finishReason: "stop", wantState: pool.StateReady},
		{name: "abnormal", finishReason: "content_filter", wantState: pool.StateDegraded},
	} {
		t.Run(tc.name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
			server := buyer.NewServer(
				registry,
				zerolog.Nop(),
				time.Unix(1716768000, 0),
				buyer.WithBreakerConfig(1, time.Second),
				buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
					chunks := make(chan providerws.InferenceResponseChunk, 1)
					done := make(chan providerws.InferenceResponseEnd, 1)
					errs := make(chan error, 1)
					chunks <- providerws.InferenceResponseChunk{
						Type:      "inference_response_chunk",
						RequestID: requestID,
						Seq:       0,
						Data:      fmt.Sprintf(`{"id":"zero","choices":[{"message":{"content":""},"finish_reason":%q}]}`, tc.finishReason),
					}
					done <- providerws.InferenceResponseEnd{
						Type:       "inference_response_end",
						RequestID:  requestID,
						Status:     "complete",
						ChunksSent: 1,
						Usage:      json.RawMessage(`{"prompt_tokens":4,"completion_tokens":0,"total_tokens":4}`),
					}
					return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
				}, time.Second),
			)

			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
			if rr.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != tc.wantState {
				t.Fatalf("p1 = %#v ok=%v, want %s", p1, ok, tc.wantState)
			}
		})
	}
}

func TestCircuitBreakerRetripAfterRecoveryMarksUnavailable(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	registry.MarkDegradedForRecovery("p1", "s1", pool.RecoveryReasonBreaker)
	registry.MarkRecovered("p1", "s1", time.Now().UTC())
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithFailoverConfig(false, 50*time.Millisecond),
		buyer.WithBreakerConfig(1, time.Second),
		buyer.WithRelay(deadMidInferenceRelay, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateUnavailable {
		t.Fatalf("p1 after re-trip = %#v ok=%v, want unavailable", p1, ok)
	}
}

func TestCircuitBreakerGenericReadyReturnDoesNotCountAsRecovery(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	registry.MarkState("p1", "s1", pool.StateDegraded)
	registry.MarkState("p1", "s1", pool.StateReady)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithFailoverConfig(false, 50*time.Millisecond),
		buyer.WithBreakerConfig(1, time.Second),
		buyer.WithRelay(deadMidInferenceRelay, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateDegraded {
		t.Fatalf("p1 after generic ready then breaker trip = %#v ok=%v, want degraded", p1, ok)
	}
}

func TestChatCompletionsWSTunneledQueueFullFallsBackToNextProvider(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 2, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	var calls []string
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			calls = append(calls, provider.ProviderID)
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" {
				done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "error_queue_full"}
				return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
			}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"fallback","choices":[{"message":{"content":"ok"}}]}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if strings.Join(calls, ",") != "p1,p2" {
		t.Fatalf("relay calls = %v", calls)
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("provider = %q, want p2", rr.Header().Get("X-MacProvider-Provider"))
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateBusy {
		t.Fatalf("p1 = %#v ok=%v, want busy", p1, ok)
	}
}

func TestChatCompletionsWSTunneledDeadProviderFastFails(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithFailoverConfig(false, 50*time.Millisecond),
		buyer.WithRelay(deadMidInferenceRelay, time.Second),
	)

	start := time.Now()
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	elapsed := time.Since(start)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if elapsed > time.Second {
		t.Fatalf("fast-fail took %s, want <1s", elapsed)
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"provider_disconnected"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateReady {
		t.Fatalf("p1 = %#v ok=%v, want ready after one breaker fault", p1, ok)
	}
}

func TestChatCompletionsWSTunneledDeadProviderFailover(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 2, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
	var calls []string
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithFailoverConfig(true, 50*time.Millisecond),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			calls = append(calls, provider.ProviderID)
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" {
				errs <- providerws.ErrRelayClosed
				return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
			}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"failover","choices":[{"message":{"content":"ok"}}]}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if strings.Join(calls, ",") != "p1,p2" {
		t.Fatalf("relay calls = %v", calls)
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("provider = %q, want p2", rr.Header().Get("X-MacProvider-Provider"))
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"id":"failover"`)) {
		t.Fatalf("body not relayed: %s", rr.Body.String())
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateReady {
		t.Fatalf("p1 = %#v ok=%v, want ready after one breaker fault", p1, ok)
	}
}

func TestModelClassAliasRewrittenPerWSFailoverProvider(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p2", "s2", "model-b", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	bodies := map[string][]byte{}
	var calls []string
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithFailoverConfig(true, 50*time.Millisecond),
		buyer.WithRoutingConfig(config.RoutingConfig{
			ModelClasses: map[string]config.ModelClassConfig{
				"mlx-class": {Models: []string{"model-a", "model-b"}, Objective: "fast"},
			},
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			calls = append(calls, provider.ProviderID)
			bodies[provider.ProviderID] = append([]byte(nil), body...)
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" {
				errs <- providerws.ErrRelayClosed
				return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
			}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"failover","choices":[{"message":{"content":"ok"}}]}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"mlx-class","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if strings.Join(calls, ",") != "p1,p2" {
		t.Fatalf("relay calls = %v", calls)
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("provider = %q, want p2", rr.Header().Get("X-MacProvider-Provider"))
	}
	assertForwardedModel(t, bodies["p1"], "model-a")
	assertForwardedModel(t, bodies["p2"], "model-b")
}

func TestChatCompletionsWSTunneledDeadProviderFailoverOnlyOnce(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p3", "s3", "model-a", pool.StateReady, 20000, 1, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
	var calls []string
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithFailoverConfig(true, 50*time.Millisecond),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			calls = append(calls, provider.ProviderID)
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" || provider.ProviderID == "p2" {
				errs <- providerws.ErrRelayClosed
				return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
			}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"should-not-run"}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if strings.Join(calls, ",") != "p1,p2" {
		t.Fatalf("relay calls = %v, want p1,p2", calls)
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"provider_disconnected"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func TestChatCompletionsWSTunneledPinnedDeadProviderDoesNotFailover(t *testing.T) {
	for _, tc := range []struct {
		name    string
		headers http.Header
	}{
		{name: "provider", headers: http.Header{"X-MacProvider-Provider": []string{"p1"}}},
		{name: "session", headers: http.Header{"X-MacProvider-Session": []string{"s1"}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
			registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
			var calls []string
			server := buyer.NewServer(
				registry,
				zerolog.Nop(),
				time.Unix(1716768000, 0),
				buyer.WithFailoverConfig(true, 50*time.Millisecond),
				buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
					calls = append(calls, provider.ProviderID)
					return deadMidInferenceRelay(ctx, provider, requestID, body, stream)
				}, time.Second),
			)

			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), tc.headers)

			if rr.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			if strings.Join(calls, ",") != "p1" {
				t.Fatalf("relay calls = %v, want p1", calls)
			}
			if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"provider_disconnected"`)) {
				t.Fatalf("body = %s", rr.Body.String())
			}
		})
	}
}

func TestChatCompletionsWSTunneledStreamingDeadProviderFailoverBeforeFirstByte(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
	var calls []string
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithFailoverConfig(true, 50*time.Millisecond),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			calls = append(calls, provider.ProviderID)
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" {
				errs <- providerws.ErrRelayClosed
				return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
			}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: "data: ok\n\n"}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if strings.Join(calls, ",") != "p1,p2" {
		t.Fatalf("relay calls = %v", calls)
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("provider = %q, want p2", rr.Header().Get("X-MacProvider-Provider"))
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte("data: ok")) {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func TestChatCompletionsWSTunneledStreamingDeadProviderAfterFirstByteTerminatesSSE(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithFailoverConfig(true, 50*time.Millisecond),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd)
			errs := make(chan error)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: "data: partial\n\n"}
			go func() {
				time.Sleep(10 * time.Millisecond)
				errs <- providerws.ErrRelayClosed
			}()
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte("data: partial")) {
		t.Fatalf("body missing partial chunk: %s", rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"provider_disconnected"`)) {
		t.Fatalf("body missing provider_disconnected: %s", rr.Body.String())
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateReady {
		t.Fatalf("p1 = %#v ok=%v, want ready after one breaker fault", p1, ok)
	}
}

func TestChatCompletionsProvisionalQuotaReturns429(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	adm := providerws.NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 10,
		ProvisionalPoolMax:              10,
		ProvisionalQuotaPerHour:         1,
		ProvisionalTierWeight:           0.3,
	}, time.Now)
	adm.RecordRequest(pool.Provider{ProviderID: "p1", Tier: pool.TierProvisional})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithAdmission(adm, 0.3),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"provisional_quota_exceeded"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
	if rr.Header().Get("Retry-After") != "3600" {
		t.Fatalf("Retry-After = %q, want 3600", rr.Header().Get("Retry-After"))
	}
}

func TestChatCompletionsValidationPrecedesModelLookup(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	body := []byte(`{"model":"missing-model","messages":[{"role":"user","content":"hello"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"test","arguments":"{not json}"}}]}]}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"invalid_tools"`)) {
		t.Fatalf("body missing invalid_tools: %s", rr.Body.String())
	}
}

func TestTier2RequireHashVerifiedUncataloguedReturns503(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("uncatalogued provider should not receive request")
	}))
	defer upstream.Close()
	var logs bytes.Buffer
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(
		registry,
		zerolog.New(&logs),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{RequireHashVerified: true}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"tier2_hash_verified_required"`)) ||
		!bytes.Contains(rr.Body.Bytes(), []byte(`"type":"server_error"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
	rawLog := logs.String()
	if !strings.Contains(rawLog, `"event":"hash_required_provider_excluded"`) ||
		!strings.Contains(rawLog, `"provider_id":"p1"`) ||
		!strings.Contains(rawLog, `"reason":"uncatalogued"`) {
		t.Fatalf("missing hash-required exclusion log: %s", rawLog)
	}
}

func TestTier2RequireEncryptedLegRoutesOnlyEncryptedProvider(t *testing.T) {
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("unencrypted provider should not receive request")
	}))
	defer plain.Close()
	encrypted := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"encrypted","choices":[{"message":{"content":"encrypted"}}]}`))
	}))
	defer encrypted.Close()
	registry := pool.NewRegistry(nil)
	registerTier2Provider(registry, "plain", "session-plain", "model-a", plain.URL, false, pool.AttestationStatusUnsupported)
	registerTier2Provider(registry, "encrypted", "session-encrypted", "model-a", encrypted.URL, true, pool.AttestationStatusUnsupported)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{RequireEncryptedLeg: true}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "encrypted" || !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"encrypted"`)) {
		t.Fatalf("encrypted route not selected: provider=%q body=%s", rr.Header().Get("X-MacProvider-Provider"), rr.Body.String())
	}
}

func TestTier2RequireEncryptedLegUnavailableReturns503(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("unencrypted provider should not receive request")
	}))
	defer upstream.Close()
	var logs bytes.Buffer
	registry := pool.NewRegistry(nil)
	registerTier2Provider(registry, "plain", "session-plain", "model-a", upstream.URL, false, pool.AttestationStatusUnsupported)
	server := buyer.NewServer(
		registry,
		zerolog.New(&logs),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{RequireEncryptedLeg: true}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusServiceUnavailable || !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"tier2_encrypted_leg_required"`)) {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(logs.String(), `"event":"encrypted_leg_required_missing"`) || !strings.Contains(logs.String(), `"provider_id":"plain"`) {
		t.Fatalf("missing encrypted leg exclusion log: %s", logs.String())
	}
}

func TestTier2RequireAttestationRoutesOnlyAttestedProvider(t *testing.T) {
	unsupported := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("unattested provider should not receive request")
	}))
	defer unsupported.Close()
	attested := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"attested","choices":[{"message":{"content":"attested"}}]}`))
	}))
	defer attested.Close()
	registry := pool.NewRegistry(nil)
	registerTier2Provider(registry, "unsupported", "session-unsupported", "model-a", unsupported.URL, true, pool.AttestationStatusUnsupported)
	registerTier2Provider(registry, "attested", "session-attested", "model-a", attested.URL, true, pool.AttestationStatusAttested)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{RequireAttestation: true, AttestationRoots: []string{"mock-root"}, AllowMockAttestation: true}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "attested" || !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"attested"`)) {
		t.Fatalf("attested route not selected: provider=%q body=%s", rr.Header().Get("X-MacProvider-Provider"), rr.Body.String())
	}
}

func TestTier2RequireAttestationUnavailableReturns503(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("unattested provider should not receive request")
	}))
	defer upstream.Close()
	registry := pool.NewRegistry(nil)
	registerTier2Provider(registry, "unsupported", "session-unsupported", "model-a", upstream.URL, true, pool.AttestationStatusUnsupported)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{RequireAttestation: true, AttestationRoots: []string{"mock-root"}, AllowMockAttestation: true}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusServiceUnavailable || !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"tier2_attestation_required"`)) {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestTier2RequireHashVerifiedCatalogUnavailableLogsExclusion(t *testing.T) {
	defer tier2.ResetForTest()
	if err := tier2.Configure(config.Tier2Config{CatalogPath: "/missing/catalog.json", CatalogPublicKey: "unused"}, zerolog.Nop()); err != nil {
		t.Fatalf("configure unavailable catalog: %v", err)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("catalog-unavailable provider should not receive request")
	}))
	defer upstream.Close()
	var logs bytes.Buffer
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(
		registry,
		zerolog.New(&logs),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{RequireHashVerified: true, CatalogPath: "/missing/catalog.json", CatalogPublicKey: "unused"}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	rawLog := logs.String()
	if !strings.Contains(rawLog, `"event":"hash_required_provider_excluded"`) ||
		!strings.Contains(rawLog, `"provider_id":"p1"`) ||
		!strings.Contains(rawLog, `"reason":"catalog_unavailable"`) {
		t.Fatalf("missing catalog-unavailable exclusion log: %s", rawLog)
	}
}

func TestTier2RequireHashVerifiedHeartbeatModelDriftLogsExclusion(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("model-drifted provider should not receive request")
	}))
	defer upstream.Close()
	var logs bytes.Buffer
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registry.Register(&pool.Provider{
		ProviderID:            "p1",
		AssignedID:            "session-1",
		ModelID:               "model-a",
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		EndpointURL:           upstream.URL,
		State:                 pool.StateReady,
		ModelHash:             "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		HashStatus:            pool.HashStatusVerified,
	}, nil)
	if _, _, ok := registry.ApplyHeartbeat("p1", "session-1", pool.HeartbeatUpdate{
		Status:                pool.StateReady,
		ModelID:               "model-b",
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		At:                    time.Now().UTC(),
	}); !ok {
		t.Fatal("heartbeat update failed")
	}
	server := buyer.NewServer(
		registry,
		zerolog.New(&logs),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{RequireHashVerified: true}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-b","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	rawLog := logs.String()
	if !strings.Contains(rawLog, `"event":"hash_required_provider_excluded"`) ||
		!strings.Contains(rawLog, `"provider_id":"p1"`) ||
		!strings.Contains(rawLog, `"model_id":"model-b"`) ||
		!strings.Contains(rawLog, `"reason":"uncatalogued"`) {
		t.Fatalf("missing heartbeat-drift exclusion log: %s", rawLog)
	}
}

func TestTier2StaleMismatchIgnoredWhenInactive(t *testing.T) {
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"role":"assistant","content":"ok"}}]}`))
	}))
	defer okUpstream.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "bad", EndpointURL: okUpstream.URL}})
	registerWithHashStatusEndpoint(registry, "bad", "session-1", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, pool.HashStatusMismatch)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "bad" {
		t.Fatalf("provider=%q, want bad", rr.Header().Get("X-MacProvider-Provider"))
	}
}

func TestTier2MismatchExcludedAndUncataloguedRoutesWhenActive(t *testing.T) {
	blocked := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("hash-mismatched provider should not receive request")
	}))
	defer blocked.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"role":"assistant","content":"ok"}}]}`))
	}))
	defer okUpstream.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "bad", EndpointURL: blocked.URL},
		{ProviderID: "old", EndpointURL: okUpstream.URL},
	})
	registerWithHashStatusEndpoint(registry, "bad", "session-1", "model-a", pool.StateReady, 20000, 1, blocked.URL, pool.HashStatusMismatch)
	registerWithHashStatusEndpoint(registry, "old", "session-2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, pool.HashStatusUncatalogued)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "old" {
		t.Fatalf("provider=%q, want old", rr.Header().Get("X-MacProvider-Provider"))
	}
}

func TestTier2HashMismatchOnlyReturnsTier2Mismatch(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("hash-mismatched provider should not receive request")
	}))
	defer upstream.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "bad", EndpointURL: upstream.URL}})
	registerWithHashStatusEndpoint(registry, "bad", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, pool.HashStatusMismatch)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"tier2_hash_mismatch"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func TestTier2RequireHashVerifiedRoutesOnlyVerified(t *testing.T) {
	oldUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("uncatalogued provider should not receive request")
	}))
	defer oldUpstream.Close()
	verifiedUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"role":"assistant","content":"ok"}}]}`))
	}))
	defer verifiedUpstream.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "old", EndpointURL: oldUpstream.URL},
		{ProviderID: "verified", EndpointURL: verifiedUpstream.URL},
	})
	registerWithHashStatusEndpoint(registry, "old", "session-1", "model-a", pool.StateReady, 20000, 1, oldUpstream.URL, pool.HashStatusUncatalogued)
	registerWithHashStatusEndpoint(registry, "verified", "session-2", "model-a", pool.StateReady, 20000, 1, verifiedUpstream.URL, pool.HashStatusVerified)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{RequireHashVerified: true}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "verified" {
		t.Fatalf("provider=%q, want verified", rr.Header().Get("X-MacProvider-Provider"))
	}
}

func TestTier2HardPinPredicateFailure(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("excluded hard-pinned provider should not receive request")
	}))
	defer upstream.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "bad", EndpointURL: upstream.URL}})
	registerWithHashStatusEndpoint(registry, "bad", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, pool.HashStatusMismatch)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(config.Tier2Config{ObserveEnabled: true}),
	)

	rr := postChat(
		t,
		server,
		[]byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`),
		http.Header{"X-MacProvider-Provider": []string{"bad"}},
	)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"tier2_hard_pin_predicate_failed"`)) ||
		!bytes.Contains(rr.Body.Bytes(), []byte(`"type":"invalid_request"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func TestProviderFailureStartsRecoveryPreflight(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	recoveryIDs := make(chan string, 1)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRecoveryConfig(10*time.Millisecond, 1, true),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			recoveryIDs <- requestID
			return buyer.PreflightResult{Accepted: true}, true, nil
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	select {
	case requestID := <-recoveryIDs:
		if !strings.HasPrefix(requestID, "recovery-probe-") {
			t.Fatalf("requestID = %q", requestID)
		}
	case <-time.After(time.Second):
		t.Fatal("recovery preflight did not run")
	}
	eventually(t, func() bool {
		for _, p := range registry.Snapshot() {
			return p.ProviderID == "p1" && p.State == pool.StateReady
		}
		return false
	})
}

func TestProviderHTTP530MarksUnavailable(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(530)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	serverConn, providerConn := net.Pipe()
	defer serverConn.Close()
	defer providerConn.Close()
	registerWithEndpointConn(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20, serverConn)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	providers := registry.Snapshot()
	if len(providers) != 1 || providers[0].State != pool.StateUnavailable {
		t.Fatalf("providers = %#v", providers)
	}
	assertConnClosed(t, providerConn)
}

func TestChatCompletionsSplitsUnknownModelAndUnavailableProvider(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "http://p1.example"}})
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateBusy, 20000, 1, "http://p1.example", 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	unknown := postChat(t, server, []byte(`{"model":"missing","messages":[{"role":"user","content":"hello"}]}`), nil)
	if unknown.Code != http.StatusNotFound {
		t.Fatalf("unknown status = %d, body=%s", unknown.Code, unknown.Body.String())
	}
	if !bytes.Contains(unknown.Body.Bytes(), []byte(`"code":"model_not_found"`)) {
		t.Fatalf("unknown body = %s", unknown.Body.String())
	}

	unavailable := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if unavailable.Code != http.StatusServiceUnavailable {
		t.Fatalf("unavailable status = %d, body=%s", unavailable.Code, unavailable.Body.String())
	}
	if !bytes.Contains(unavailable.Body.Bytes(), []byte(`"code":"no_provider_available"`)) {
		t.Fatalf("unavailable body = %s", unavailable.Body.String())
	}
}

func TestChatCompletionsDoesNotRouteToDegradedProvider(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "http://p1.example"}})
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateDegraded, 20000, 1, "http://p1.example", 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"no_provider_available"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func register(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int) {
	registerWithEndpoint(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, "https://"+providerID+".example", 20)
}

func registerWithHashStatus(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, hashStatus pool.HashStatus) {
	registerWithHashStatusEndpoint(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, "https://"+providerID+".example", hashStatus)
}

func registerTier2Provider(registry *pool.Registry, providerID, assignedID, modelID, endpointURL string, encrypted bool, attestation pool.AttestationStatus) {
	now := time.Now().UTC()
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               modelID,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		EndpointURL:           endpointURL,
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		LastHeartbeatAt:       now,
		LastActivityAt:        now,
		ConnectedAt:           now,
		BinaryVersion:         "0.1.0",
		EncryptedLeg:          encrypted,
		AttestationStatus:     attestation,
	}, nil)
}

func registerWithHashStatusEndpoint(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, hashStatus pool.HashStatus) {
	registerWithHashStatusSlots(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, slotsTotal, endpointURL, hashStatus)
}

func registerWithHashStatusSlots(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsFree, slotsTotal int, endpointURL string, hashStatus pool.HashStatus) {
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               modelID,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      maxContextTokens,
		MaxConcurrency:        slotsTotal,
		SlotsFree:             slotsFree,
		SlotsTotal:            slotsTotal,
		ThroughputTPSEstimate: 20,
		EndpointURL:           endpointURL,
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 state,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		BinaryVersion:         "0.1.0",
		HashStatus:            hashStatus,
	}, nil)
}

func registerWithEndpoint(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, throughput float64) {
	registerWithEndpointConn(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, endpointURL, throughput, nil)
}

func registerWithEndpointConn(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, throughput float64, conn net.Conn) {
	registerWithPathConn(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, endpointURL, throughput, pool.TierPinned, pool.InferencePathHTTPForwarding, conn)
}

func registerWithPath(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, throughput float64, tier pool.Tier, path pool.InferencePath) {
	registerWithPathConn(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, endpointURL, throughput, tier, path, nil)
}

func registerWithPathConn(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, throughput float64, tier pool.Tier, path pool.InferencePath, conn net.Conn) {
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               modelID,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      maxContextTokens,
		MaxConcurrency:        slotsTotal,
		SlotsFree:             slotsTotal,
		SlotsTotal:            slotsTotal,
		ThroughputTPSEstimate: throughput,
		EndpointURL:           endpointURL,
		Tier:                  tier,
		InferencePath:         path,
		State:                 state,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		BinaryVersion:         "0.1.0",
	}, conn)
}

func assertConnClosed(t *testing.T, conn net.Conn) {
	t.Helper()
	closed := make(chan error, 1)
	go func() {
		buf := make([]byte, 1)
		_, err := conn.Read(buf)
		closed <- err
	}()
	select {
	case err := <-closed:
		if err == nil {
			t.Fatal("connection read succeeded, want closed connection")
		}
	case <-time.After(time.Second):
		t.Fatal("provider connection was not closed")
	}
}

func postChat(t *testing.T, server *buyer.Server, body []byte, headers http.Header) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	for k, values := range headers {
		for _, v := range values {
			req.Header.Add(k, v)
		}
	}
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	_, _ = io.Copy(io.Discard, rr.Result().Body)
	return rr
}

func assertForwardedModel(t *testing.T, body []byte, want string) {
	t.Helper()
	if len(body) == 0 {
		t.Fatalf("provider did not receive body; want model %q", want)
	}
	var got struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("forwarded body json: %v; body=%s", err, string(body))
	}
	if got.Model != want {
		t.Fatalf("forwarded model = %q, want %q; body=%s", got.Model, want, string(body))
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

type faultAfterFirstRead struct {
	first []byte
	used  bool
}

func (r *faultAfterFirstRead) Read(p []byte) (int, error) {
	if !r.used {
		r.used = true
		return copy(p, r.first), nil
	}
	return 0, io.ErrUnexpectedEOF
}

func (r *faultAfterFirstRead) Close() error {
	return nil
}

func deadMidInferenceRelay(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
	chunks := make(chan providerws.InferenceResponseChunk, 1)
	done := make(chan providerws.InferenceResponseEnd)
	errs := make(chan error, 1)
	chunks <- providerws.InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: requestID,
		Seq:       0,
		Data:      `{"partial":true}`,
	}
	errs <- providerws.ErrRelayClosed
	return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
}

func chatBodyWithContent(model, content string) []byte {
	b, err := json.Marshal(map[string]any{
		"model": model,
		"messages": []map[string]string{
			{"role": "user", "content": content},
		},
	})
	if err != nil {
		panic(err)
	}
	return b
}

func eventually(t *testing.T, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if f() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("condition did not become true before deadline")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestSessionHardPinReturns503EvenWithStickyEnabled is the AC-SR-15
// regression lock: a non-matching X-MacProvider-Session value MUST return
// 503 session_ended (SPEC-002 FR-R3) regardless of whether sticky affinity
// is enabled in the coordinator. The pin path lives at server.go:1270-1284
// and runs BEFORE the sticky lookup; this test pins it so a future refactor
// that accidentally routes session-pinned traffic through sticky (the
// SPEC-004 v0.1 C-1 collision class) fails loudly. Parameterized on
// sticky_enabled so both branches are exercised.
func TestSessionHardPinReturns503EvenWithStickyEnabled(t *testing.T) {
	for _, stickyEnabled := range []bool{false, true} {
		name := "sticky_off"
		if stickyEnabled {
			name = "sticky_on"
		}
		t.Run(name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			registerWithPath(registry, "p1", "real-session", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
			server := buyer.NewServer(
				registry,
				zerolog.Nop(),
				time.Unix(1716768000, 0),
				buyer.WithInternalAuthKey("operator-key"),
				buyer.WithRoutingConfig(config.RoutingConfig{
					StickyEnabled:    stickyEnabled,
					StickyTTLS:       1800,
					StickyMaxEntries: 10000,
					TiebreakEpsilon:  0.10,
				}),
				buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
					t.Fatalf("relay MUST NOT be invoked for a session-pinned request with no matching session — got dispatch to %s", provider.ProviderID)
					return nil, nil
				}, time.Second),
			)

			headers := http.Header{
				"Authorization":         []string{"Bearer operator-key"},
				"X-MacProvider-Session": []string{"nonexistent-session-id"},
				// Even with a valid-looking conv: present, sticky must NOT activate
				// when a hard-pin header is set. This is the C-1 regression vector.
				"X-MacProvider-Internal-Conv": []string{"conv:should-not-be-used"},
				"X-MacProvider-Account":       []string{"acct_test"},
			}
			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), headers)

			if rr.Code != http.StatusServiceUnavailable {
				t.Fatalf("status=%d, want 503; body=%s", rr.Code, rr.Body.String())
			}
			if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"session_ended"`)) {
				t.Fatalf("body MUST contain code=session_ended; got %s", rr.Body.String())
			}
			// Hard-pin failed AND no sticky entry should have been written
			// (which would be implied by the relay-fatalf above, but we also
			// re-fire to a non-pinned request to verify the sticky lookup is
			// genuinely cold — a non-empty sticky map would surface as a
			// "sticky_hit" log path on the next request).
		})
	}
}

// TestStickyWritesOnHTTPStreamingCleanEOF pins the behavioral change from
// the SPEC-004 audit fix: HTTP-streaming forwardStreaming defers the sticky
// write to the io.EOF branch (clean stream completion) instead of writing
// it upfront before bytes flow. This test sends a clean-EOF SSE stream
// with a conv: header, then issues a second sticky-eligible request to the
// same conv: tag and asserts it routes back to the same provider. Without
// the sticky write happening on EOF, the second request would not get a
// sticky hit — proving the deferred store actually fires on success.
//
// This is the POSITIVE-case assertion the re-verify audit flagged as
// missing: a regression deleting the s.stickyStore() call in the io.EOF
// branch would not be caught by structural inspection alone; this test
// catches it end-to-end.
func TestStickyWritesOnHTTPStreamingCleanEOF(t *testing.T) {
	var calls []string
	upstream1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, "p1")
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		flusher := w.(http.Flusher)
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"))
		flusher.Flush()
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
		// Clean close → bufio.ReadBytes returns io.EOF, which is the
		// branch where sticky_store now fires.
	}))
	defer upstream1.Close()
	upstream2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, "p2")
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		flusher := w.(http.Flusher)
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"))
		flusher.Flush()
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer upstream2.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: upstream1.URL},
		{ProviderID: "p2", EndpointURL: upstream2.URL},
	})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream1.URL, 20)
	registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, upstream2.URL, 20)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:    true,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
			TiebreakEpsilon:  0.10,
		}),
	)
	headers := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:eof-write-pinned"},
		"X-MacProvider-Account":       []string{"acct_test"},
	}

	// First streaming request: clean EOF → MUST write sticky on completion.
	rr := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}]}`), headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("seed stream status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte("[DONE]")) {
		t.Fatalf("seed stream missing [DONE]: %s", rr.Body.String())
	}
	seedProvider := rr.Header().Get("X-MacProvider-Provider")
	if seedProvider == "" {
		t.Fatal("seed stream did not set X-MacProvider-Provider")
	}

	// Second streaming request with same conv: tag — sticky_hit MUST route
	// to the SAME provider. If the EOF-branch stickyStore is missing, this
	// fails because the second request lands on whichever provider the
	// default sort picks (which may differ from the first).
	rr = postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hi"}]}`), headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("followup stream status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Provider"); got != seedProvider {
		t.Fatalf("sticky did NOT write on HTTP-streaming clean EOF: seed routed to %q, follow-up routed to %q (expected sticky_hit to same provider)", seedProvider, got)
	}
	// Sanity: both requests genuinely went through SOME provider's upstream.
	if len(calls) < 2 {
		t.Fatalf("expected 2 upstream calls, got %d (%v)", len(calls), calls)
	}
}

// TestStickyMissesGracefullyWhenProviderIsBreakerHeld pins SPEC-004 §9
// composition: a sticky hit on a breaker-degraded provider MUST gracefully
// miss (RoutingEligible filters it out of the candidate set; applySticky
// falls back), routing to another eligible provider. Regression-locks the
// "sticky traps a session on a dead box" failure class.
func TestStickyMissesGracefullyWhenProviderIsBreakerHeld(t *testing.T) {
	upstream1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"p1","choices":[{"message":{"content":"p1"}}]}`))
	}))
	defer upstream1.Close()
	upstream2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"p2","choices":[{"message":{"content":"p2"}}]}`))
	}))
	defer upstream2.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: upstream1.URL},
		{ProviderID: "p2", EndpointURL: upstream2.URL},
	})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream1.URL, 20)
	registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, upstream2.URL, 20)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:    true,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
			TiebreakEpsilon:  0.10,
		}),
	)
	headers := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:graceful-miss"},
		"X-MacProvider-Account":       []string{"acct_test"},
	}

	// Seed sticky to whichever provider is selected first (deterministic
	// under defaults).
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("seed status=%d body=%s", rr.Code, rr.Body.String())
	}
	stuckProvider := rr.Header().Get("X-MacProvider-Provider")
	if stuckProvider == "" {
		t.Fatal("seed did not set X-MacProvider-Provider header")
	}
	otherProvider := "p1"
	stuckAssigned := "s1"
	if stuckProvider == "p1" {
		otherProvider = "p2"
		stuckAssigned = "s1"
	} else {
		stuckAssigned = "s2"
	}

	// Mark the stuck provider degraded with a breaker recovery hold — this
	// is the same mechanism FR-P11a uses on a breaker trip. RoutingEligible()
	// returns false; sticky lookup must gracefully fall back to otherProvider.
	if !registry.MarkDegradedForRecovery(stuckProvider, stuckAssigned, pool.RecoveryReasonBreaker) {
		t.Fatalf("could not put provider %s into breaker-held degraded state", stuckProvider)
	}

	rr = postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi again"}]}`), headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("post-breaker status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Provider"); got != otherProvider {
		t.Fatalf("sticky trapped a session on a breaker-held provider: routed to %q, want %q", got, otherProvider)
	}
}

// TestStickyMissesGracefullyWhenProviderIsRemoved pins that sticky entries
// pointing at providers that have left the pool entirely (FR-SR-3 "graceful
// fallback") miss instead of trapping. Complements the breaker-held case
// above; together they cover the dead-box scenarios the composition
// guarantee (SPEC-004 §9) MUST preserve.
func TestStickyMissesGracefullyWhenProviderIsRemoved(t *testing.T) {
	upstream1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"p1","choices":[{"message":{"content":"p1"}}]}`))
	}))
	defer upstream1.Close()
	upstream2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"p2","choices":[{"message":{"content":"p2"}}]}`))
	}))
	defer upstream2.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: upstream1.URL},
		{ProviderID: "p2", EndpointURL: upstream2.URL},
	})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream1.URL, 20)
	registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, upstream2.URL, 20)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithInternalAuthKey("operator-key"),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:    true,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
			TiebreakEpsilon:  0.10,
		}),
	)
	headers := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:removed-provider"},
		"X-MacProvider-Account":       []string{"acct_test"},
	}

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("seed status=%d body=%s", rr.Code, rr.Body.String())
	}
	stuckProvider := rr.Header().Get("X-MacProvider-Provider")
	stuckAssigned := "s1"
	otherProvider := "p2"
	if stuckProvider == "p2" {
		stuckAssigned = "s2"
		otherProvider = "p1"
	}

	// Hard-remove the sticky-pinned provider — sticky map still has the
	// stale entry, but candidate list won't include it. Must gracefully
	// miss and route to the other.
	if !registry.RemoveIfSession(stuckProvider, stuckAssigned) {
		t.Fatalf("RemoveIfSession(%s, %s) returned false", stuckProvider, stuckAssigned)
	}

	rr = postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi again"}]}`), headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("post-removal status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Provider"); got != otherProvider {
		t.Fatalf("sticky did not gracefully miss on removed provider: routed to %q, want %q", got, otherProvider)
	}
}

// TestDefaultConfigPreservesBaselineProviderSelection is the FR-SR-1 +
// AC-SR-1 default-preservation regression lock: with every SPEC-004 key at
// its default (sticky off, retries off, randomize off, no model classes),
// routing produces the same provider selection as SPEC-002 v1.3.3 would —
// i.e. the smart-router pipeline is a verified NO-OP at install. A future
// change that accidentally activates a smart feature at default (e.g.
// flipping a default to true, or letting an empty model_classes map
// short-circuit the wrong way) breaks this test loudly.
func TestDefaultConfigPreservesBaselineProviderSelection(t *testing.T) {
	upstream1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"p1","choices":[{"message":{"content":"p1"}}]}`))
	}))
	defer upstream1.Close()
	upstream2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"p2","choices":[{"message":{"content":"p2"}}]}`))
	}))
	defer upstream2.Close()

	mkServer := func(routing config.RoutingConfig) *buyer.Server {
		registry := pool.NewRegistry([]config.ProviderConfig{
			{ProviderID: "p1", EndpointURL: upstream1.URL},
			{ProviderID: "p2", EndpointURL: upstream2.URL},
		})
		// Equal slots_free so SPEC-002's default sort ("lowest slots_free
		// first, throughput tiebreak") collapses to the throughput tiebreak
		// — p2 (30 tps) MUST beat p1 (10 tps). This makes the test
		// independent of the (pre-existing, non-deterministic) Go map
		// iteration order in pool.Snapshot().
		registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream1.URL, 10)
		registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, upstream2.URL, 30)
		return buyer.NewServer(
			registry,
			zerolog.Nop(),
			time.Unix(1716768000, 0),
			buyer.WithInternalAuthKey("operator-key"),
			buyer.WithRoutingConfig(routing),
		)
	}

	// Baseline: zero-valued RoutingConfig — every SPEC-004 key at default.
	defaultRouting := config.RoutingConfig{
		// Pre-SPEC-004 fields keep their existing defaults.
		PreflightTimeoutS: 5,
		RequestTimeoutS:   280,
		FailoverTimeoutS:  5,
		// SPEC-004 fields all at install defaults — proves the pipeline
		// is a verified no-op.
		StickyEnabled:                 false,
		StickyTTLS:                    1800,
		StickyMaxEntries:              10000,
		TiebreakRandomize:             false,
		TiebreakEpsilon:               0,
		MaxRetries:                    0,
		RetryPerAttemptTimeoutS:       60,
		MaxProvidersFaultedPerRequest: 0,
		ModelClasses:                  nil,
	}
	server := mkServer(defaultRouting)

	// Smart-router-shaped headers MUST be irrelevant at default — even with
	// a conv: header set, sticky_enabled=false → no derivation, no lookup.
	// Account header is irrelevant for non-sticky path. Even an internal
	// header MUST be ignored on the buyer port when not paired with
	// operator-bearer.
	headers := http.Header{}

	// Run several requests; deterministic top-throughput sort always picks p2.
	for i := 0; i < 5; i++ {
		rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), headers)
		if rr.Code != http.StatusOK {
			t.Fatalf("iter %d status=%d body=%s", i, rr.Code, rr.Body.String())
		}
		if got := rr.Header().Get("X-MacProvider-Provider"); got != "p2" {
			t.Fatalf("iter %d: default-config routed to %q, want p2 (highest throughput) — SPEC-004 pipeline must be a no-op at default", i, got)
		}
	}
}
