package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
	"gopkg.in/yaml.v3"
)

const reloadTestHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const reloadOtherHash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

func TestNewHTTPServerAppliesTimeouts(t *testing.T) {
	server := newHTTPServer("127.0.0.1:0", http.NewServeMux())
	if server.ReadHeaderTimeout != 10*time.Second {
		t.Fatalf("ReadHeaderTimeout=%s want 10s", server.ReadHeaderTimeout)
	}
	if server.ReadTimeout == 0 {
		t.Fatal("ReadTimeout must be set")
	}
	if server.IdleTimeout == 0 {
		t.Fatal("IdleTimeout must be set")
	}
}

func TestReloadTier2RejectsStartupCatalogFieldChange(t *testing.T) {
	defer tier2.ResetForTest()
	startup, _, wsServer, buyerServer := reloadTestServers(config.Default())
	next := startup
	next.Tier2.CatalogPath = "/tmp/catalog.json"
	next.Tier2.CatalogPublicKey = "catalog-key"

	reloadTier2Config(writeReloadConfig(t, next), startup.Tier2, zerolog.Nop(), wsServer, buyerServer)

	got := fetchReloadTier2Metadata(t, buyerServer)
	if got.Phase != 0 || got.ModelHash.Active {
		t.Fatalf("tier2 metadata after rejected reload = %+v", got)
	}
}

func TestReloadTier2RejectsStartupOnlyTier2FieldChange(t *testing.T) {
	defer tier2.ResetForTest()
	startup, _, wsServer, buyerServer := reloadTestServers(config.Default())
	next := startup
	next.Tier2.ObserveEnabled = true
	next.Tier2.EncryptedLegRekeyAfterRequests++

	reloadTier2Config(writeReloadConfig(t, next), startup.Tier2, zerolog.Nop(), wsServer, buyerServer)

	got := fetchReloadTier2Metadata(t, buyerServer)
	if got.Phase != 0 || got.ModelHash.Active {
		t.Fatalf("tier2 metadata after rejected reload = %+v", got)
	}
}

func TestTier2StartupFieldsChangedCoversPhaseStartupOnlyFields(t *testing.T) {
	startup := config.Default().Tier2
	cases := map[string]func(config.Tier2Config) config.Tier2Config{
		"catalog_path_whitespace": func(next config.Tier2Config) config.Tier2Config {
			next.CatalogPath = "/tmp/catalog.json "
			return next
		},
		"catalog_public_key": func(next config.Tier2Config) config.Tier2Config {
			next.CatalogPublicKey = "catalog-key"
			return next
		},
		"encrypted_leg_aead": func(next config.Tier2Config) config.Tier2Config {
			next.EncryptedLegAEAD = "A128GCM"
			return next
		},
		"encrypted_leg_rekey_after_requests": func(next config.Tier2Config) config.Tier2Config {
			next.EncryptedLegRekeyAfterRequests++
			return next
		},
		"encrypted_leg_rekey_after_seconds": func(next config.Tier2Config) config.Tier2Config {
			next.EncryptedLegRekeyAfterSeconds++
			return next
		},
		"attestation_roots": func(next config.Tier2Config) config.Tier2Config {
			next.AttestationRoots = []string{"root-a"}
			return next
		},
		"attestation_formats": func(next config.Tier2Config) config.Tier2Config {
			next.AttestationFormats = []string{"tdx-quote-v1"}
			return next
		},
	}

	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			if !tier2StartupFieldsChanged(startup, mutate(startup)) {
				t.Fatal("startup-only tier2 field change was not detected")
			}
		})
	}
}

func TestTier2CatalogPathReloadComparisonMatchesLoaderSemantics(t *testing.T) {
	startup := config.Default().Tier2
	startup.CatalogPath = "/tmp/catalog.json "
	next := startup
	next.CatalogPath = "/tmp/catalog.json"

	if !tier2StartupFieldsChanged(startup, next) {
		t.Fatal("catalog path whitespace-only reload change was not detected")
	}
}

func TestTier2StartupFieldsChangedAllowsHotReloadableFutureFields(t *testing.T) {
	startup := config.Default().Tier2
	cases := map[string]func(config.Tier2Config) config.Tier2Config{
		"require_encrypted_leg": func(next config.Tier2Config) config.Tier2Config {
			next.RequireEncryptedLeg = true
			return next
		},
		"require_attestation": func(next config.Tier2Config) config.Tier2Config {
			next.RequireAttestation = true
			return next
		},
		"attestation_max_age_s": func(next config.Tier2Config) config.Tier2Config {
			next.AttestationMaxAgeS++
			return next
		},
		"behavioral_safety_enabled": func(next config.Tier2Config) config.Tier2Config {
			next.BehavioralSafetyEnabled = true
			return next
		},
		"output_size_cap_bytes": func(next config.Tier2Config) config.Tier2Config {
			next.OutputSizeCapBytes++
			return next
		},
		"response_time_anomaly_factor": func(next config.Tier2Config) config.Tier2Config {
			next.ResponseTimeAnomalyFactor += 0.5
			return next
		},
	}

	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			if tier2StartupFieldsChanged(startup, mutate(startup)) {
				t.Fatal("hot-reloadable Tier2Config field was treated as startup-only")
			}
		})
	}
}

func TestTier2ReloadFieldClassesCoversAllTier2ConfigFields(t *testing.T) {
	fields := reflect.TypeOf(config.Tier2Config{})
	seen := map[string]bool{}
	for i := 0; i < fields.NumField(); i++ {
		name := fields.Field(i).Name
		seen[name] = true
		if _, ok := tier2ReloadFieldClasses[name]; !ok {
			t.Errorf("Tier2Config field %q is not registered in tier2ReloadFieldClasses; add it as tier2HotReloadable or tier2StartupOnly", name)
		}
	}
	for name := range tier2ReloadFieldClasses {
		if !seen[name] {
			t.Fatalf("reload field class for unknown Tier2Config field %s", name)
		}
	}
}

func TestReloadTier2AppliesHotObserveFlag(t *testing.T) {
	defer tier2.ResetForTest()
	startup, _, wsServer, buyerServer := reloadTestServers(config.Default())
	next := startup
	next.Tier2.ObserveEnabled = true

	reloadTier2Config(writeReloadConfig(t, next), startup.Tier2, zerolog.Nop(), wsServer, buyerServer)

	got := fetchReloadTier2Metadata(t, buyerServer)
	if got.Phase != 0 || !got.ModelHash.Active {
		t.Fatalf("tier2 metadata after hot reload = %+v", got)
	}
}

func TestReloadTier2ReloadsSamePathCatalogContents(t *testing.T) {
	defer tier2.ResetForTest()
	catalogPath := t.TempDir() + "/catalog.json"
	raw, publicKey := signedReloadCatalogFixture(t, time.Now().UTC().Add(time.Hour), reloadTestHash)
	if err := os.WriteFile(catalogPath, raw, 0600); err != nil {
		t.Fatalf("write initial catalog: %v", err)
	}
	startup := config.Default()
	startup.Tier2.CatalogPath = catalogPath
	startup.Tier2.CatalogPublicKey = publicKey
	if err := tier2.Configure(startup.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("startup Configure: %v", err)
	}
	startup, _, wsServer, buyerServer := reloadTestServers(startup)
	replacement, _ := signedReloadCatalogFixture(t, time.Now().UTC().Add(time.Hour), reloadOtherHash)
	if err := os.WriteFile(catalogPath, replacement, 0600); err != nil {
		t.Fatalf("write replacement catalog: %v", err)
	}

	var logs bytes.Buffer
	reloadTier2Config(writeReloadConfig(t, startup), startup.Tier2, zerolog.New(&logs), wsServer, buyerServer)

	if got := tier2.VerifyProviderHash("model-a", reloadOtherHash); got != pool.HashStatusVerified {
		t.Fatalf("reloaded catalog hash status=%q want %q logs=%s", got, pool.HashStatusVerified, logs.String())
	}
	if got := tier2.VerifyProviderHash("model-a", reloadTestHash); got != pool.HashStatusMismatch {
		t.Fatalf("old catalog hash status=%q want %q", got, pool.HashStatusMismatch)
	}
}

func TestReloadTier2PreservesPreviousCatalogOnInvalidSamePathReload(t *testing.T) {
	defer tier2.ResetForTest()
	catalogPath := t.TempDir() + "/catalog.json"
	raw, publicKey := signedReloadCatalogFixture(t, time.Now().UTC().Add(time.Hour), reloadTestHash)
	if err := os.WriteFile(catalogPath, raw, 0600); err != nil {
		t.Fatalf("write initial catalog: %v", err)
	}
	startup := config.Default()
	startup.Tier2.CatalogPath = catalogPath
	startup.Tier2.CatalogPublicKey = publicKey
	if err := tier2.Configure(startup.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("startup Configure: %v", err)
	}
	startup, _, wsServer, buyerServer := reloadTestServers(startup)
	corrupted := bytes.Replace(raw, []byte("model-a"), []byte("model-b"), 1)
	if err := os.WriteFile(catalogPath, corrupted, 0600); err != nil {
		t.Fatalf("write corrupted catalog: %v", err)
	}

	var logs bytes.Buffer
	reloadTier2Config(writeReloadConfig(t, startup), startup.Tier2, zerolog.New(&logs), wsServer, buyerServer)

	if got := tier2.VerifyProviderHash("model-a", reloadTestHash); got != pool.HashStatusVerified {
		t.Fatalf("preserved catalog hash status=%q want %q logs=%s", got, pool.HashStatusVerified, logs.String())
	}
	if tier2.LoadFailed() {
		t.Fatalf("rejected reload mutated tier2 load state logs=%s", logs.String())
	}
}

func TestReloadTier2ReevaluatesExistingProviderHashes(t *testing.T) {
	defer tier2.ResetForTest()
	catalogPath := t.TempDir() + "/catalog.json"
	raw, publicKey := signedReloadCatalogFixture(t, time.Now().UTC().Add(time.Hour), reloadTestHash)
	if err := os.WriteFile(catalogPath, raw, 0600); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	startup := config.Default()
	startup.Tier2.CatalogPath = catalogPath
	startup.Tier2.CatalogPublicKey = publicKey
	if err := tier2.Configure(startup.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("startup Configure: %v", err)
	}
	startup, registry, wsServer, buyerServer := reloadTestServers(startup)
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
		ModelHash:             reloadTestHash,
		HashStatus:            "",
	}, nil)
	next := startup
	next.Tier2.ObserveEnabled = true

	reloadTier2Config(writeReloadConfig(t, next), startup.Tier2, zerolog.Nop(), wsServer, buyerServer)

	provider, ok := registry.Resolve("provider-a", "session-a")
	if !ok {
		t.Fatal("provider missing after reload")
	}
	if provider.HashStatus != pool.HashStatusVerified {
		t.Fatalf("provider hash status after reload=%q want %q", provider.HashStatus, pool.HashStatusVerified)
	}
}

func TestReloadTier2LogsHashStatusTransitions(t *testing.T) {
	defer tier2.ResetForTest()
	catalogPath := t.TempDir() + "/catalog.json"
	raw, publicKey := signedReloadCatalogFixture(t, time.Now().UTC().Add(time.Hour), reloadTestHash)
	if err := os.WriteFile(catalogPath, raw, 0600); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	startup := config.Default()
	startup.Tier2.CatalogPath = catalogPath
	startup.Tier2.CatalogPublicKey = publicKey
	if err := tier2.Configure(startup.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("startup Configure: %v", err)
	}
	var wsLogs bytes.Buffer
	startup, registry, wsServer, buyerServer := reloadTestServersWithLogger(startup, zerolog.New(&wsLogs))
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
		ModelHash:             reloadTestHash,
		HashStatus:            pool.HashStatusVerified,
	}, nil)
	replacement, _ := signedReloadCatalogFixture(t, time.Now().UTC().Add(time.Hour), reloadOtherHash)
	if err := os.WriteFile(catalogPath, replacement, 0600); err != nil {
		t.Fatalf("write replacement catalog: %v", err)
	}

	reloadTier2Config(writeReloadConfig(t, startup), startup.Tier2, zerolog.Nop(), wsServer, buyerServer)

	provider, ok := registry.Resolve("provider-a", "session-a")
	if !ok {
		t.Fatal("provider missing after reload")
	}
	if provider.HashStatus != pool.HashStatusMismatch {
		t.Fatalf("provider hash status after reload=%q want %q", provider.HashStatus, pool.HashStatusMismatch)
	}
	rawLog := wsLogs.String()
	if !strings.Contains(rawLog, `"event":"model_hash_mismatch"`) ||
		!strings.Contains(rawLog, `"provider_id":"provider-a"`) ||
		!strings.Contains(rawLog, `"decision":"exclude"`) {
		t.Fatalf("reload transition audit log missing mismatch event: %s", rawLog)
	}
}

func TestReloadTier2LogsHashRequiredExclusionWhenStatusUnchanged(t *testing.T) {
	defer tier2.ResetForTest()
	catalogPath := t.TempDir() + "/catalog.json"
	raw, publicKey := signedReloadCatalogFixture(t, time.Now().UTC().Add(time.Hour), reloadTestHash)
	if err := os.WriteFile(catalogPath, raw, 0600); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	startup := config.Default()
	startup.Tier2.CatalogPath = catalogPath
	startup.Tier2.CatalogPublicKey = publicKey
	startup.Tier2.ObserveEnabled = true
	if err := tier2.Configure(startup.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("startup Configure: %v", err)
	}
	var wsLogs bytes.Buffer
	startup, registry, wsServer, buyerServer := reloadTestServersWithLogger(startup, zerolog.New(&wsLogs))
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
		ModelHash:             "",
		HashStatus:            pool.HashStatusUncatalogued,
	}, nil)
	next := startup
	next.Tier2.RequireHashVerified = true

	reloadTier2Config(writeReloadConfig(t, next), startup.Tier2, zerolog.Nop(), wsServer, buyerServer)

	provider, ok := registry.Resolve("provider-a", "session-a")
	if !ok {
		t.Fatal("provider missing after reload")
	}
	if provider.HashStatus != pool.HashStatusUncatalogued {
		t.Fatalf("provider hash status after reload=%q want %q", provider.HashStatus, pool.HashStatusUncatalogued)
	}
	rawLog := wsLogs.String()
	if !strings.Contains(rawLog, `"event":"hash_required_provider_excluded"`) ||
		!strings.Contains(rawLog, `"provider_id":"provider-a"`) ||
		!strings.Contains(rawLog, `"config_flag":"tier2.require_hash_verified"`) {
		t.Fatalf("reload audit log missing hash-required exclusion event: %s", rawLog)
	}
}

func reloadTestServers(cfg config.Config) (config.Config, *pool.Registry, *providerws.Server, *buyer.Server) {
	return reloadTestServersWithLogger(cfg, zerolog.Nop())
}

func reloadTestServersWithLogger(cfg config.Config, logger zerolog.Logger) (config.Config, *pool.Registry, *providerws.Server, *buyer.Server) {
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Pool.WarmupGateEnabled = false
	registry := pool.NewRegistry(nil)
	wsServer := providerws.NewServer(cfg, registry, logger)
	buyerServer := buyer.NewServer(
		registry,
		logger,
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(cfg.Tier2),
		buyer.WithInternalAuthKey(cfg.Auth.OperatorKey),
	)
	return cfg, registry, wsServer, buyerServer
}

func writeReloadConfig(t *testing.T, cfg config.Config) string {
	t.Helper()
	raw, err := yaml.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal config: %v", err)
	}
	path := t.TempDir() + "/coordinator.yaml"
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

func fetchReloadTier2Metadata(t *testing.T, server *buyer.Server) struct {
	Phase     int `json:"phase"`
	ModelHash struct {
		Active bool `json:"active"`
	} `json:"model_hash"`
} {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/internal/routing", nil)
	req.Header.Set("Authorization", "Bearer operator-key")
	rr := httptest.NewRecorder()
	server.InternalHandler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var body struct {
		Tier2 struct {
			Phase     int `json:"phase"`
			ModelHash struct {
				Active bool `json:"active"`
			} `json:"model_hash"`
		} `json:"tier2"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("json: %v", err)
	}
	return body.Tier2
}

type reloadCanonicalCatalog struct {
	CatalogID string             `json:"catalog_id"`
	ExpiresAt string             `json:"expires_at"`
	IssuedAt  string             `json:"issued_at"`
	Models    []tier2.ModelEntry `json:"models"`
	Version   int                `json:"version"`
}

type reloadCatalogFile struct {
	CatalogID string             `json:"catalog_id"`
	ExpiresAt string             `json:"expires_at"`
	IssuedAt  string             `json:"issued_at"`
	Models    []tier2.ModelEntry `json:"models"`
	Signature tier2.Signature    `json:"signature"`
	Version   int                `json:"version"`
}

func signedReloadCatalogFixture(t *testing.T, expiresAt time.Time, sha string) ([]byte, string) {
	t.Helper()
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	privateKey := ed25519.NewKeyFromSeed(seed)
	publicKey := privateKey.Public().(ed25519.PublicKey)
	issuedAt := time.Now().UTC().Add(-time.Hour)
	if !issuedAt.Before(expiresAt) {
		issuedAt = expiresAt.Add(-time.Hour)
	}
	body := reloadCanonicalCatalog{
		CatalogID: "test-catalog",
		ExpiresAt: expiresAt.UTC().Format(time.RFC3339),
		IssuedAt:  issuedAt.Format(time.RFC3339),
		Models: []tier2.ModelEntry{{
			ArtifactKind: "mlx_weight_file",
			HashScope:    "primary_weight_file",
			ModelID:      "model-a",
			SHA256:       sha,
			Source:       "operator-curated",
		}},
		Version: 1,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("canonical marshal: %v", err)
	}
	sig := ed25519.Sign(privateKey, canonical)
	file := reloadCatalogFile{
		CatalogID: body.CatalogID,
		ExpiresAt: body.ExpiresAt,
		IssuedAt:  body.IssuedAt,
		Models:    body.Models,
		Signature: tier2.Signature{Alg: "Ed25519", KeyID: "test-key", Sig: base64.RawURLEncoding.EncodeToString(sig)},
		Version:   body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("catalog marshal: %v", err)
	}
	return raw, base64.RawURLEncoding.EncodeToString(publicKey)
}
