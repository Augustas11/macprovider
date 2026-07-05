package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	statsmetrics "github.com/augstar/macprovider-coordinator/internal/stats/metrics"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/prometheus/client_golang/prometheus"
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

func TestOperatorMetricsHandlerRequiresOperatorBearer(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := statsmetrics.New(reg)
	m.IncRegisterSource("app")
	handler := operatorMetricsHandler("operator-secret", reg)

	for _, tc := range []struct {
		name   string
		bearer string
		want   int
	}{
		{name: "missing", want: http.StatusUnauthorized},
		{name: "gateway token rejected", bearer: "gateway-secret", want: http.StatusUnauthorized},
		{name: "operator accepted", bearer: "operator-secret", want: http.StatusOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/admin/metrics", nil)
			if tc.bearer != "" {
				req.Header.Set("Authorization", "Bearer "+tc.bearer)
			}
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)
			if rr.Code != tc.want {
				t.Fatalf("status=%d want=%d body=%s", rr.Code, tc.want, rr.Body.String())
			}
			if tc.want == http.StatusOK && !strings.Contains(rr.Body.String(), "provider_register_source_total") {
				t.Fatalf("/admin/metrics missing register counter: %s", rr.Body.String())
			}
		})
	}
}

func TestBuyerRegisterRouteFeatureGate(t *testing.T) {
	base := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "base", http.StatusTeapot)
	})
	register := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	hardwareEvidence := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusAccepted)
	})

	disabled := buyerHandlerWithOptionalProviderEndpoints(base, false, register, hardwareEvidence)
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", nil)
	rr := httptest.NewRecorder()
	disabled.ServeHTTP(rr, req)
	if rr.Code != http.StatusTeapot {
		t.Fatalf("disabled route status=%d want base handler 418", rr.Code)
	}
	evidenceReq := httptest.NewRequest(http.MethodPost, "/v1/providers/hardware-evidence", nil)
	rr = httptest.NewRecorder()
	disabled.ServeHTTP(rr, evidenceReq)
	if rr.Code != http.StatusTeapot {
		t.Fatalf("disabled evidence route status=%d want base handler 418", rr.Code)
	}

	walletReq := httptest.NewRequest(http.MethodPost, "/v1/provider/wallet", nil)
	rr = httptest.NewRecorder()
	disabled.ServeHTTP(rr, walletReq)
	if rr.Code != http.StatusNotImplemented || !strings.Contains(rr.Body.String(), "wallet_change_requires_spec_027") {
		t.Fatalf("disabled wallet route status=%d body=%s, want 501 wallet_change_requires_spec_027", rr.Code, rr.Body.String())
	}

	enabled := buyerHandlerWithOptionalProviderEndpoints(base, true, register, hardwareEvidence)
	rr = httptest.NewRecorder()
	enabled.ServeHTTP(rr, req)
	if rr.Code != http.StatusNoContent {
		t.Fatalf("enabled route status=%d want 204", rr.Code)
	}
	rr = httptest.NewRecorder()
	enabled.ServeHTTP(rr, evidenceReq)
	if rr.Code != http.StatusAccepted {
		t.Fatalf("enabled evidence route status=%d want 202", rr.Code)
	}

	rr = httptest.NewRecorder()
	enabled.ServeHTTP(rr, walletReq)
	if rr.Code != http.StatusNotImplemented || !strings.Contains(rr.Body.String(), "wallet_change_requires_spec_027") {
		t.Fatalf("wallet route status=%d body=%s, want 501 wallet_change_requires_spec_027", rr.Code, rr.Body.String())
	}
}

func TestNginxProviderRoutesBeforeV1CatchAll(t *testing.T) {
	body, err := os.ReadFile("../../dist/nginx-coordinator.streamvc.live.conf")
	if err != nil {
		t.Fatalf("read nginx config: %v", err)
	}
	cfg := string(body)
	registerRoute := strings.Index(cfg, "location = /v1/providers/register")
	evidenceRoute := strings.Index(cfg, "location = /v1/providers/hardware-evidence")
	catchAll := strings.Index(cfg, "location /v1/ {\n        return 404;")
	if registerRoute < 0 {
		t.Fatal("missing exact /v1/providers/register route")
	}
	if evidenceRoute < 0 {
		t.Fatal("missing exact /v1/providers/hardware-evidence route")
	}
	if catchAll < 0 {
		t.Fatal("missing /v1/ catch-all route")
	}
	if registerRoute > catchAll {
		t.Fatal("/v1/providers/register route must appear before /v1/ catch-all")
	}
	if evidenceRoute > catchAll {
		t.Fatal("/v1/providers/hardware-evidence route must appear before /v1/ catch-all")
	}
	for _, needle := range []string{
		"proxy_pass http://127.0.0.1:8443/v1/providers/register;",
		"proxy_set_header Authorization $http_authorization;",
		"add_header Cache-Control \"no-store\" always;",
	} {
		if !strings.Contains(cfg[registerRoute:catchAll], needle) {
			t.Fatalf("register route missing %q", needle)
		}
	}
	for _, needle := range []string{
		"proxy_pass http://127.0.0.1:8443/v1/providers/hardware-evidence;",
		"limit_req zone=ws_provider_rate burst=5 nodelay;",
		"proxy_set_header Authorization $http_authorization;",
		"client_max_body_size 128k;",
		"add_header Cache-Control \"no-store\" always;",
	} {
		if !strings.Contains(cfg[evidenceRoute:catchAll], needle) {
			t.Fatalf("hardware evidence route missing %q", needle)
		}
	}
}

func TestNginxWalletRouteBeforeV1CatchAll(t *testing.T) {
	body, err := os.ReadFile("../../dist/nginx-coordinator.streamvc.live.conf")
	if err != nil {
		t.Fatalf("read nginx config: %v", err)
	}
	cfg := string(body)
	route := strings.Index(cfg, "location = /v1/provider/wallet")
	catchAll := strings.Index(cfg, "location /v1/ {\n        return 404;")
	if route < 0 {
		t.Fatal("missing exact /v1/provider/wallet route")
	}
	if catchAll < 0 {
		t.Fatal("missing /v1/ catch-all route")
	}
	if route > catchAll {
		t.Fatal("/v1/provider/wallet route must appear before /v1/ catch-all")
	}
	for _, needle := range []string{
		"proxy_pass http://127.0.0.1:8443/v1/provider/wallet;",
		"proxy_set_header Authorization $http_authorization;",
		"add_header Cache-Control \"no-store\" always;",
	} {
		if !strings.Contains(cfg[route:catchAll], needle) {
			t.Fatalf("wallet route missing %q", needle)
		}
	}
}

func TestNginxV2ProviderAliasesExistingWSHandler(t *testing.T) {
	body, err := os.ReadFile("../../dist/nginx-coordinator.streamvc.live.conf")
	if err != nil {
		t.Fatalf("read nginx config: %v", err)
	}
	cfg := string(body)
	route := strings.Index(cfg, "location = /v2/provider")
	if route < 0 {
		t.Fatal("missing exact /v2/provider route")
	}
	next := strings.Index(cfg[route+1:], "location ")
	block := cfg[route:]
	if next >= 0 {
		block = cfg[route : route+1+next]
	}
	for _, needle := range []string{
		"proxy_pass http://127.0.0.1:8444/ws/provider;",
		"proxy_set_header Upgrade $http_upgrade;",
		"proxy_buffering off;",
	} {
		if !strings.Contains(block, needle) {
			t.Fatalf("/v2/provider route missing %q", needle)
		}
	}
}

func TestSetupCanarySanctionStoreHonorsCanaryEnabled(t *testing.T) {
	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open request log store: %v", err)
	}
	defer reqStore.Close()
	seedStore, err := providerws.NewSQLiteCanarySanctionStore(reqStore.DB())
	if err != nil {
		t.Fatalf("open canary store: %v", err)
	}
	checkedAt := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
	if err := seedStore.UpsertCanarySanction(context.Background(), pool.CanarySanctionSnapshot{
		ProviderID:    "pinned-a",
		FailCount:     2,
		LastCheckedAt: &checkedAt,
		LastFailedAt:  &checkedAt,
	}); err != nil {
		t.Fatalf("seed canary sanction: %v", err)
	}

	disabledCfg := config.Default()
	disabledCfg.Pool.CanaryEnabled = false
	disabledRegistry := pool.NewRegistry(nil)
	store, err := setupCanarySanctionStore(context.Background(), disabledCfg, reqStore.DB(), disabledRegistry)
	if err != nil {
		t.Fatalf("setup disabled canary store: %v", err)
	}
	if store != nil {
		t.Fatal("disabled canary setup returned a store")
	}
	disabledRegistry.Register(&pool.Provider{
		ProviderID:     "pinned-a",
		AssignedID:     "session-disabled",
		ModelID:        "model-a",
		Tier:           pool.TierPinned,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}, nil)
	disabledProvider, ok := disabledRegistry.Resolve("pinned-a", "session-disabled")
	if !ok {
		t.Fatal("disabled provider not found")
	}
	if disabledProvider.State != pool.StateReady || !disabledProvider.RoutingEligible() {
		t.Fatalf("disabled canary applied persisted sanction: %+v", disabledProvider)
	}

	enabledCfg := config.Default()
	enabledCfg.Pool.CanaryEnabled = true
	enabledCfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{{
		Prompt:   "Private challenge with {nonce}",
		Expected: "private-{nonce}",
	}}
	enabledRegistry := pool.NewRegistry(nil)
	store, err = setupCanarySanctionStore(context.Background(), enabledCfg, reqStore.DB(), enabledRegistry)
	if err != nil {
		t.Fatalf("setup enabled canary store: %v", err)
	}
	if store == nil {
		t.Fatal("enabled canary setup returned nil store")
	}
	enabledRegistry.Register(&pool.Provider{
		ProviderID:     "pinned-a",
		AssignedID:     "session-enabled",
		ModelID:        "model-a",
		Tier:           pool.TierPinned,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}, nil)
	enabledProvider, ok := enabledRegistry.Resolve("pinned-a", "session-enabled")
	if !ok {
		t.Fatal("enabled provider not found")
	}
	if enabledProvider.State != pool.StateDegraded || enabledProvider.RoutingEligible() {
		t.Fatalf("enabled canary did not apply persisted sanction: %+v", enabledProvider)
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
