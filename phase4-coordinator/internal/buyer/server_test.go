package buyer_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
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

func TestGatewayContextRequiredRejectsChatBeforeIdempotency(t *testing.T) {
	registry := pool.NewRegistry(nil)
	store, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	defer store.Close()
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("gateway-secret"),
		buyer.WithRequireGatewayContext(true),
		buyer.WithRequestLog(store),
	)

	body := `{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Idempotency-Key", "idem-direct")
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s, want 401 before idempotency reservation", rr.Code, rr.Body.String())
	}

	replayReqID, replay, err := store.ReserveIdempotencyKey(context.Background(), "acct_test", "idem-direct", buyerTestHash, "req-later", time.Now())
	if err != nil {
		t.Fatalf("ReserveIdempotencyKey after rejected request: %v", err)
	}
	if replay || replayReqID != "req-later" {
		t.Fatalf("reservation replay=%v request_id=%q, want fresh req-later", replay, replayReqID)
	}
}

func TestGatewayContextRequiredAllowsAuthenticatedGatewayContext(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("gateway-secret"),
		buyer.WithRequireGatewayContext(true),
	)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{`))
	req.Header.Set("Authorization", "Bearer gateway-secret")
	req.Header.Set("X-MacProvider-Account", "acct_gateway")
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	if rr.Code == http.StatusUnauthorized {
		t.Fatalf("authenticated gateway context was rejected: body=%s", rr.Body.String())
	}
}

func TestRateCardProjectionReturnsRecommendationSchema(t *testing.T) {
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.25,
		ProviderShare:    0.875,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {
				PromptCreditsPerMtok:         100000,
				PromptCacheHitCreditsPerMtok: 25000,
				CompletionCreditsPerMtok:     200000,
			},
			"mlx-community/gpt-oss-20b-MXFP4-Q8": {
				PromptCreditsPerMtok:         300000,
				PromptCacheHitCreditsPerMtok: 75000,
				CompletionCreditsPerMtok:     400000,
			},
			"openai/gpt-oss-20b": {
				PromptCreditsPerMtok:         500000,
				PromptCacheHitCreditsPerMtok: 125000,
				CompletionCreditsPerMtok:     600000,
			},
		},
	}
	server := buyer.NewServer(
		pool.NewRegistry(nil),
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithBilling(nil, rewards),
		buyer.WithRateCardUSDPerMillionCredits(1.5),
	)

	req := httptest.NewRequest(http.MethodGet, "/v1/rate-card", nil)
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var got struct {
		Version              string  `json:"version"`
		GeneratedAt          string  `json:"generated_at"`
		USDPerMillionCredits float64 `json:"usd_per_million_credits"`
		Rows                 map[string]struct {
			PromptRatePerMtok         int64 `json:"prompt_rate_per_mtok"`
			PromptCacheHitRatePerMtok int64 `json:"prompt_cache_hit_rate_per_mtok"`
			CompletionRatePerMtok     int64 `json:"completion_rate_per_mtok"`
			ProviderShareBPS          int64 `json:"provider_share_bps"`
			GlobalMultiplierPPM       int64 `json:"global_multiplier_ppm"`
		} `json:"rows"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Version == "" {
		t.Fatalf("version empty: %s", rr.Body.String())
	}
	if _, err := time.Parse(time.RFC3339, got.GeneratedAt); err != nil {
		t.Fatalf("generated_at not RFC3339: %q", got.GeneratedAt)
	}
	if got.USDPerMillionCredits != 1.5 {
		t.Fatalf("usd_per_million_credits=%v want 1.5", got.USDPerMillionCredits)
	}
	row, ok := got.Rows["model-a"]
	if !ok {
		t.Fatalf("model-a row missing: %s", rr.Body.String())
	}
	if row.PromptRatePerMtok != 100000 || row.PromptCacheHitRatePerMtok != 25000 || row.CompletionRatePerMtok != 200000 || row.ProviderShareBPS != 8750 || row.GlobalMultiplierPPM != 1250000 {
		t.Fatalf("unexpected row: %+v", row)
	}
	if _, ok := got.Rows["mlx-community/gpt-oss-20b-MXFP4-Q8"]; ok {
		t.Fatalf("raw alias row leaked into recommendation projection: %s", rr.Body.String())
	}
	normalized, ok := got.Rows["openai/gpt-oss-20b"]
	if !ok {
		t.Fatalf("normalized gpt-oss row missing: %s", rr.Body.String())
	}
	if normalized.PromptRatePerMtok != 500000 || normalized.PromptCacheHitRatePerMtok != 125000 || normalized.CompletionRatePerMtok != 600000 {
		t.Fatalf("canonical row did not win normalized collision: %+v", normalized)
	}
	canonical := `{"global_multiplier_ppm":1250000,"provider_share_bps":8750,"rows":{"model-a":{"completion_rate_per_mtok":200000,"global_multiplier_ppm":1250000,"prompt_cache_hit_rate_per_mtok":25000,"prompt_rate_per_mtok":100000,"provider_share_bps":8750},"openai/gpt-oss-20b":{"completion_rate_per_mtok":600000,"global_multiplier_ppm":1250000,"prompt_cache_hit_rate_per_mtok":125000,"prompt_rate_per_mtok":500000,"provider_share_bps":8750}},"usd_per_million_credits":1.5}`
	sum := sha256.Sum256([]byte(canonical))
	if got.Version != hex.EncodeToString(sum[:]) {
		t.Fatalf("version hash mismatch: got %s want hash of %s", got.Version, canonical)
	}
}

func TestRateCardProjectionDoesNotNormalizeDefaultAliases(t *testing.T) {
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1,
		ProviderShare:    0.9,
		RateCard: map[string]config.RateCardEntry{
			"default": {
				PromptCreditsPerMtok:     100000,
				CompletionCreditsPerMtok: 200000,
			},
			"DEFAULT": {
				PromptCreditsPerMtok:     300000,
				CompletionCreditsPerMtok: 400000,
			},
			" default ": {
				PromptCreditsPerMtok:     500000,
				CompletionCreditsPerMtok: 600000,
			},
			"mlx-community/default-4bit": {
				PromptCreditsPerMtok:     700000,
				CompletionCreditsPerMtok: 800000,
			},
		},
	}
	server := buyer.NewServer(
		pool.NewRegistry(nil),
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithBilling(nil, rewards),
	)

	req := httptest.NewRequest(http.MethodGet, "/v1/rate-card", nil)
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var got struct {
		Rows map[string]struct {
			PromptRatePerMtok     int64 `json:"prompt_rate_per_mtok"`
			CompletionRatePerMtok int64 `json:"completion_rate_per_mtok"`
		} `json:"rows"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if len(got.Rows) != 1 {
		t.Fatalf("rows=%#v, want only literal default", got.Rows)
	}
	row, ok := got.Rows["default"]
	if !ok {
		t.Fatalf("literal default row missing: %#v", got.Rows)
	}
	if row.PromptRatePerMtok != 100000 || row.CompletionRatePerMtok != 200000 {
		t.Fatalf("default alias overrode literal default: %+v", row)
	}
}

func TestRateCardProjectionBuyerMuxOnly(t *testing.T) {
	server := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0))

	req := httptest.NewRequest(http.MethodGet, "/v1/rate-card", nil)
	buyerRR := httptest.NewRecorder()
	server.Handler().ServeHTTP(buyerRR, req)
	if buyerRR.Code != http.StatusOK {
		t.Fatalf("buyer mux status=%d body=%s", buyerRR.Code, buyerRR.Body.String())
	}

	internalRR := httptest.NewRecorder()
	server.InternalHandler().ServeHTTP(internalRR, req)
	if internalRR.Code != http.StatusNotFound {
		t.Fatalf("internal/provider mux status=%d want 404", internalRR.Code)
	}
}

func TestRateCardProjectionVersionChangesOnlyForProjectionFields(t *testing.T) {
	base := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {
				PromptCreditsPerMtok:     100000,
				CompletionCreditsPerMtok: 200000,
			},
		},
	}
	baseVersion := rateCardVersionFromServer(t,
		buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithBilling(nil, base), buyer.WithRateCardUSDPerMillionCredits(1.0)),
	)

	rowsChanged := base
	rowsChanged.RateCard = map[string]config.RateCardEntry{
		"model-a": {PromptCreditsPerMtok: 100000, CompletionCreditsPerMtok: 200001},
	}
	assertRateCardVersionChanged(t, baseVersion, rowsChanged, 1.0)

	cacheHitRateChanged := base
	cacheHitRateChanged.RateCard = map[string]config.RateCardEntry{
		"model-a": {PromptCreditsPerMtok: 100000, PromptCacheHitCreditsPerMtok: 50000, CompletionCreditsPerMtok: 200000},
	}
	assertRateCardVersionChanged(t, baseVersion, cacheHitRateChanged, 1.0)

	shareChanged := base
	shareChanged.ProviderShare = 0.91
	assertRateCardVersionChanged(t, baseVersion, shareChanged, 1.0)

	multiplierChanged := base
	multiplierChanged.GlobalMultiplier = 1.1
	assertRateCardVersionChanged(t, baseVersion, multiplierChanged, 1.0)

	usdChangedVersion := rateCardVersionFromServer(t,
		buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithBilling(nil, base), buyer.WithRateCardUSDPerMillionCredits(2.0)),
	)
	if usdChangedVersion == baseVersion {
		t.Fatalf("version did not change when usd_per_million_credits changed: %s", baseVersion)
	}

	unrelatedVersion := rateCardVersionFromServer(t,
		buyer.NewServer(
			pool.NewRegistry(nil),
			zerolog.Nop(),
			time.Unix(1716768000, 0),
			buyer.WithBilling(nil, base),
			buyer.WithBillingSnapshotID(999),
			buyer.WithGatewayServiceToken("operator-key-does-not-affect-rate-card"),
			buyer.WithRateCardUSDPerMillionCredits(1.0),
		),
	)
	if unrelatedVersion != baseVersion {
		t.Fatalf("version changed for unrelated operator/snapshot state: got %s want %s", unrelatedVersion, baseVersion)
	}
}

func TestSetBillingConfigReloadsRateCardUSDCredits(t *testing.T) {
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {PromptCreditsPerMtok: 100000, CompletionCreditsPerMtok: 200000},
		},
	}
	server := buyer.NewServer(
		pool.NewRegistry(nil),
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithBilling(nil, rewards),
		buyer.WithRateCardUSDPerMillionCredits(1.0),
	)
	baseVersion := rateCardVersionFromServer(t, server)

	server.SetBillingConfig(rewards, 2, 2.0)

	gotVersion := rateCardVersionFromServer(t, server)
	wantVersion := rateCardVersionFromServer(t,
		buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithBilling(nil, rewards), buyer.WithRateCardUSDPerMillionCredits(2.0)),
	)
	if gotVersion == baseVersion {
		t.Fatalf("version did not change after SetBillingConfig usd reload: %s", gotVersion)
	}
	if gotVersion != wantVersion {
		t.Fatalf("reloaded rate-card version=%s want %s", gotVersion, wantVersion)
	}
}

func TestNginxRateCardAllowThroughBeforeV1CatchAll(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "dist", "nginx-coordinator.streamvc.live.conf"))
	if err != nil {
		t.Fatalf("read nginx config: %v", err)
	}
	cfg := string(b)
	location := strings.Index(cfg, "location = /v1/rate-card")
	catchAll := strings.Index(cfg, "location /v1/ {\n        return 404;")
	if location < 0 {
		t.Fatalf("rate-card location missing")
	}
	if catchAll < 0 {
		t.Fatalf("/v1/ 404 catch-all missing")
	}
	if location > catchAll {
		t.Fatalf("rate-card location appears after /v1/ catch-all")
	}
	for _, needle := range []string{
		"proxy_pass http://127.0.0.1:8443/v1/rate-card$is_args$args;",
		"proxy_set_header Host $host;",
		"proxy_set_header X-Real-IP $remote_addr;",
		"proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
		"proxy_set_header X-Forwarded-Proto $scheme;",
	} {
		if !strings.Contains(cfg[location:catchAll], needle) {
			t.Fatalf("rate-card nginx block missing %q", needle)
		}
	}
}

func assertRateCardVersionChanged(t *testing.T, baseVersion string, rewards config.RewardsConfig, usdPerMillionCredits float64) {
	t.Helper()
	got := rateCardVersionFromServer(t,
		buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithBilling(nil, rewards), buyer.WithRateCardUSDPerMillionCredits(usdPerMillionCredits)),
	)
	if got == baseVersion {
		t.Fatalf("version did not change: %s", got)
	}
}

func rateCardVersionFromServer(t *testing.T, server *buyer.Server) string {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/v1/rate-card", nil)
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var got struct {
		Version string `json:"version"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Version == "" {
		t.Fatalf("version empty: %s", rr.Body.String())
	}
	return got.Version
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
		buyer.WithGatewayServiceToken("operator-key"),
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
		buyer.WithGatewayServiceToken("operator-key"),
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
	// A status-attested provider with only a self-signed SE key must NOT count
	// as attested on this surface (#759) — only hardware-tier attestation does.
	registerTier2Provider(registry, "selfsigned", "session-selfsigned", "model-a", "https://selfsigned.example", false, pool.AttestationStatusAttested)
	if !registry.SetSEPublicKey("encrypted", "session-encrypted", make([]byte, 64), pool.AttestationTierHardware) {
		t.Fatal("failed to set hardware attestation tier on provider \"encrypted\"")
	}
	if !registry.SetSEPublicKey("selfsigned", "session-selfsigned", make([]byte, 64), pool.AttestationTierSelfSigned) {
		t.Fatal("failed to set self-signed attestation tier on provider \"selfsigned\"")
	}
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
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
	if got.Tier2.EncryptedLeg.State != "partial" || got.Tier2.EncryptedLeg.EncryptedProviderCount != 1 || got.Tier2.EncryptedLeg.UnencryptedProviderCount != 2 || !got.Tier2.EncryptedLeg.Mixed || got.Tier2.EncryptedLeg.Scope != "coordinator_to_provider_only" {
		t.Fatalf("encrypted leg metadata = %+v body=%s", got.Tier2.EncryptedLeg, rr.Body.String())
	}
	// Only the hardware-tier provider counts as attested; the self-signed
	// status-attested provider lands in the unsupported bucket (#759).
	if got.Tier2.Attestation.State != "partial" || got.Tier2.Attestation.AttestedProviderCount != 1 || got.Tier2.Attestation.UnsupportedProviderCount != 2 || !got.Tier2.Attestation.Mixed {
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
				buyer.WithGatewayServiceToken("operator-key"),
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
		buyer.WithGatewayServiceToken("operator-key"),
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
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"version":"dev"`)) {
		t.Fatalf("/healthz must surface the build version; body = %s", rr.Body.String())
	}
}

func TestHealthzExcludesPendingReceiptCandidateFromReadyCapacity(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerPendingReceiptCandidate(t, registry, "p1", "session-1", "model-a")
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"pool_size":1`)) || !bytes.Contains(rr.Body.Bytes(), []byte(`"pool_ready":0`)) {
		t.Fatalf("pending receipt candidate must remain visible but not ready capacity; body=%s", rr.Body.String())
	}
}

func TestHealthzExcludesAuthSelfMintedFromReadyCapacity(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "https://p1.example"}})
	registerAuthState(registry, "p1", "session-1", "model-a", "https://p1.example", pool.AuthSelfMinted)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"pool_size":1`)) || !bytes.Contains(rr.Body.Bytes(), []byte(`"pool_ready":0`)) {
		t.Fatalf("self-minted provider must remain visible but not ready capacity; body=%s", rr.Body.String())
	}
}

func TestHealthzAcceptsHEAD(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	// Drive a real server so the net/http transport strips the HEAD body,
	// matching production (a plain ResponseRecorder does not strip it).
	ts := httptest.NewServer(server.Handler())
	defer ts.Close()

	req, err := http.NewRequest(http.MethodHead, ts.URL+"/healthz", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("healthz HEAD: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("HEAD /healthz status = %d, want 200", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if len(body) != 0 {
		t.Fatalf("HEAD /healthz must return no body; got %q", body)
	}
}

func TestHealthzReportsInjectedVersion(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithVersion("v1.3.0-7-gabcdef0"))
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()

	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"version":"v1.3.0-7-gabcdef0"`)) {
		t.Fatalf("/healthz did not surface injected version; body = %s", rr.Body.String())
	}
}

func TestPoolCheckReturnsProviderStateAnd404(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=p1", nil)
	req.RemoteAddr = "198.51.100.1:12345"
	req.Header.Set("X-Forwarded-For", "192.0.2.1")
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"provider_id":"p1"`)) || !bytes.Contains(rr.Body.Bytes(), []byte(`"state":"ready"`)) {
		t.Fatalf("body = %s", rr.Body.String())
	}
	if bytes.Contains(rr.Body.Bytes(), []byte(`"buyer_serving"`)) || bytes.Contains(rr.Body.Bytes(), []byte(`"catalog_release_id"`)) {
		t.Fatalf("public pool check leaked deployment evidence: %s", rr.Body.String())
	}

	missingReq := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=missing", nil)
	missingReq.RemoteAddr = "198.51.100.2:12345"
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

func TestPoolCheckReportsExactCatalogAdmissionAndServingEligibility(t *testing.T) {
	for _, tc := range []struct {
		name         string
		state        pool.State
		buyerServing bool
		tier2Config  config.Tier2Config
	}{
		{name: "busy remains buyer serving", state: pool.StateBusy, buyerServing: true},
		{name: "degraded is not buyer serving", state: pool.StateDegraded, buyerServing: false},
		{name: "tier2 excluded is not buyer serving", state: pool.StateReady, buyerServing: false, tier2Config: config.Tier2Config{RequireEncryptedLeg: true}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			now := time.Now().UTC()
			registry.Register(&pool.Provider{
				ProviderID:             "catalog-canary",
				AssignedID:             "session-1",
				Hostname:               "catalog-canary.local",
				ModelID:                "model-a",
				MaxContextTokens:       20000,
				MaxConcurrency:         1,
				SlotsFree:              1,
				SlotsTotal:             1,
				Tier:                   pool.TierPinned,
				InferencePath:          pool.InferencePathHTTPForwarding,
				State:                  tc.state,
				LastHeartbeatAt:        now,
				LastActivityAt:         now,
				ConnectedAt:            now,
				CatalogAdmissionMode:   "current",
				CatalogReleaseID:       "release-current",
				CatalogPolicyVersion:   "autotune-policy-v1",
				CandidateCatalogSHA256: strings.Repeat("a", 64),
				CatalogSignerKeyID:     "signer-v4",
				CandidateRowIdentity:   strings.Repeat("b", 64),
			}, nil)
			server := buyer.NewServer(
				registry,
				zerolog.Nop(),
				time.Unix(1716768000, 0),
				buyer.WithOperatorKey("operator-secret"),
				buyer.WithTier2Config(tc.tier2Config),
			)
			req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=catalog-canary&details=deployment", nil)
			req.RemoteAddr = "198.51.100.1:12345"
			req.Header.Set("Authorization", "Bearer operator-secret")
			rr := httptest.NewRecorder()
			server.Handler().ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
			}
			var response map[string]any
			if err := json.Unmarshal(rr.Body.Bytes(), &response); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if response["buyer_serving"] != tc.buyerServing || response["catalog_admission_mode"] != "current" || response["catalog_release_id"] != "release-current" || response["catalog_candidate_sha256"] != strings.Repeat("a", 64) || response["catalog_row_identity"] != strings.Repeat("b", 64) || response["catalog_evidence_source"] != "provider_reported" {
				t.Fatalf("response = %+v", response)
			}
		})
	}
}

func TestPoolCheckReadinessEvidenceIsPublicAndLegacyIsNotBuyerServing(t *testing.T) {
	for _, tc := range []struct {
		name          string
		admissionMode string
		buyerServing  bool
		withEnvelope  bool
	}{
		{name: "current envelope", admissionMode: "current", buyerServing: true, withEnvelope: true},
		{name: "legacy remains visible", admissionMode: "legacy", buyerServing: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			now := time.Now().UTC()
			provider := &pool.Provider{
				ProviderID:           "readiness-provider",
				AssignedID:           "session-1",
				ModelID:              "model-a",
				MaxContextTokens:     20000,
				MaxConcurrency:       1,
				SlotsFree:            1,
				SlotsTotal:           1,
				State:                pool.StateReady,
				LastHeartbeatAt:      now,
				LastActivityAt:       now,
				ConnectedAt:          now,
				CatalogAdmissionMode: tc.admissionMode,
			}
			if tc.withEnvelope {
				provider.CatalogReleaseID = "release-current"
				provider.CatalogPolicyVersion = "autotune-policy-v1"
				provider.CandidateCatalogSHA256 = strings.Repeat("a", 64)
				provider.CatalogSignerKeyID = "signer-v4"
				provider.CandidateRowIdentity = strings.Repeat("b", 64)
			}
			registry.Register(provider, nil)
			server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithOperatorKey("operator-secret"))
			req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=readiness-provider&assigned_id=session-1&details=readiness", nil)
			req.RemoteAddr = "198.51.100.1:12345"
			rr := httptest.NewRecorder()
			server.Handler().ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
			}
			var response map[string]any
			if err := json.Unmarshal(rr.Body.Bytes(), &response); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if response["provider_id"] != "readiness-provider" || response["assigned_id"] != "session-1" || response["buyer_serving"] != tc.buyerServing || response["catalog_admission_mode"] != tc.admissionMode || response["catalog_evidence_source"] != "provider_reported" {
				t.Fatalf("response = %+v", response)
			}
			if tc.withEnvelope && (response["catalog_release_id"] != "release-current" || response["catalog_policy_version"] != "autotune-policy-v1" || response["catalog_candidate_sha256"] != strings.Repeat("a", 64) || response["catalog_signer_key_id"] != "signer-v4" || response["catalog_row_identity"] != strings.Repeat("b", 64)) {
				t.Fatalf("readiness envelope = %+v", response)
			}
		})
	}
}

func TestPoolCheckReadinessRequiresExactAssignedSession(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	for _, tc := range []struct {
		name string
		url  string
		want int
	}{
		{name: "missing assigned session", url: "/v1/pool/check?provider_id=p1&details=readiness", want: http.StatusBadRequest},
		{name: "stale assigned session", url: "/v1/pool/check?provider_id=p1&assigned_id=session-old&details=readiness", want: http.StatusNotFound},
		{name: "exact assigned session", url: "/v1/pool/check?provider_id=p1&assigned_id=session-1&details=readiness", want: http.StatusOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, tc.url, nil)
			req.RemoteAddr = "198.51.100.50:12345"
			rr := httptest.NewRecorder()
			server.Handler().ServeHTTP(rr, req)
			if rr.Code != tc.want {
				t.Fatalf("status = %d, want %d body=%s", rr.Code, tc.want, rr.Body.String())
			}
			if tc.want == http.StatusOK {
				var response map[string]any
				if err := json.Unmarshal(rr.Body.Bytes(), &response); err != nil {
					t.Fatalf("decode response: %v", err)
				}
				if response["provider_id"] != "p1" || response["assigned_id"] != "session-1" {
					t.Fatalf("response identity = %+v", response)
				}
			}
		})
	}
}

func TestPoolCheckDeploymentEvidenceRequiresAuthorization(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithOperatorKey("operator-secret"),
		buyer.WithGatewayServiceToken("service-secret"),
	)
	for _, tc := range []struct {
		name   string
		bearer string
		remote string
		want   int
	}{
		{name: "missing bearer", remote: "198.51.100.11:12345", want: http.StatusUnauthorized},
		{name: "service token is not operator auth", bearer: "service-secret", remote: "198.51.100.12:12345", want: http.StatusUnauthorized},
		{name: "operator bearer", bearer: "operator-secret", remote: "198.51.100.13:12345", want: http.StatusOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=p1&details=deployment", nil)
			req.RemoteAddr = tc.remote
			if tc.bearer != "" {
				req.Header.Set("Authorization", "Bearer "+tc.bearer)
			}
			rr := httptest.NewRecorder()
			server.Handler().ServeHTTP(rr, req)
			if rr.Code != tc.want {
				t.Fatalf("status = %d, want %d body=%s", rr.Code, tc.want, rr.Body.String())
			}
		})
	}
}

func TestPoolCheckRateLimitsPerIP(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	for i, want := range []int{http.StatusOK, http.StatusTooManyRequests} {
		req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=p1", nil)
		req.RemoteAddr = "198.51.100.10:12345"
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, req)
		if rr.Code != want {
			t.Fatalf("request %d status = %d, want %d body=%s", i+1, rr.Code, want, rr.Body.String())
		}
	}
}

func TestPoolCheckReadinessUsesProviderScopedBurstBehindNAT(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	register(registry, "p2", "session-2", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	for i := 0; i < 70; i++ {
		req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=p1&assigned_id=session-1&details=readiness", nil)
		req.RemoteAddr = "198.51.100.10:12345"
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, req)
		want := http.StatusOK
		if i >= 6 {
			want = http.StatusTooManyRequests
		}
		if rr.Code != want {
			t.Fatalf("p1 request %d status = %d, want %d body=%s", i+1, rr.Code, want, rr.Body.String())
		}
		if want == http.StatusTooManyRequests && rr.Header().Get("Retry-After") != "1" {
			t.Fatalf("Retry-After = %q", rr.Header().Get("Retry-After"))
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=p2&assigned_id=session-2&details=readiness", nil)
	req.RemoteAddr = "198.51.100.10:54321"
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("second provider behind same NAT status = %d, body=%s", rr.Code, rr.Body.String())
	}
}

func TestPoolCheckReadinessBoundsRotatingProviderIDsPerSource(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	for i := 0; i < 61; i++ {
		req := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/v1/pool/check?provider_id=rotating-%d&assigned_id=session-%d&details=readiness", i, i), nil)
		req.RemoteAddr = "198.51.100.10:12345"
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, req)
		if i < 60 && rr.Code == http.StatusTooManyRequests {
			t.Fatalf("request %d unexpectedly rate limited", i+1)
		}
		if i == 60 && rr.Code != http.StatusTooManyRequests {
			t.Fatalf("request %d status = %d, want %d body=%s", i+1, rr.Code, http.StatusTooManyRequests, rr.Body.String())
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=independent&assigned_id=session-independent&details=readiness", nil)
	req.RemoteAddr = "198.51.100.11:12345"
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	if rr.Code == http.StatusTooManyRequests {
		t.Fatalf("independent source unexpectedly rate limited: body=%s", rr.Body.String())
	}
}

func TestPoolCheckRateLimitIgnoresSpoofedXForwardedFor(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	for i, forwarded := range []string{"192.0.2.10", "192.0.2.11"} {
		req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=p1", nil)
		req.RemoteAddr = "198.51.100.20:54321"
		req.Header.Set("X-Forwarded-For", forwarded)
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, req)
		want := http.StatusOK
		if i == 1 {
			want = http.StatusTooManyRequests
		}
		if rr.Code != want {
			t.Fatalf("request %d status = %d, want %d body=%s", i+1, rr.Code, want, rr.Body.String())
		}
	}
}

func TestPoolCheckRateLimiterEvictsToBoundUniqueKeys(t *testing.T) {
	registry := pool.NewRegistry(nil)
	register(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithPoolCheckLimiter(2, time.Hour),
	)

	for i := 1; i <= 5; i++ {
		req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=p1", nil)
		req.RemoteAddr = fmt.Sprintf("198.51.100.%d:12345", i)
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("unique request %d status = %d, body=%s", i, rr.Code, rr.Body.String())
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/pool/check?provider_id=p1", nil)
	req.RemoteAddr = "198.51.100.1:54321"
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("evicted first key status = %d, want %d body=%s", rr.Code, http.StatusOK, rr.Body.String())
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

// TestChatCompletionsRoutesCatalogKeyToHFModelID pins issue #900: a
// buyer request using the rate-card / catalog key must route to the
// provider serving the equivalent HuggingFace model id, and the
// upstream dispatch body must carry the provider's ModelID.
func TestChatCompletionsRoutesCatalogKeyToHFModelID(t *testing.T) {
	const hfID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
	const catalogKey = "openai/gpt-oss-20b"

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("upstream request json: %v", err)
		}
		if req["model"] != hfID {
			t.Fatalf("upstream model = %v, want rewritten provider ModelID %q", req["model"], hfID)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chatcmpl-oss","object":"chat.completion","created":1716768000,"model":"` + hfID + `","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "session-1", hfID, pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	catalogRR := postChat(t, server, []byte(`{"model":"`+catalogKey+`","messages":[{"role":"user","content":"hello"}],"stream":false}`), nil)
	if catalogRR.Code != http.StatusOK {
		t.Fatalf("catalog-key status = %d, body=%s", catalogRR.Code, catalogRR.Body.String())
	}
	if catalogRR.Header().Get("X-MacProvider-Provider") != "p1" {
		t.Fatalf("catalog-key provider header = %q", catalogRR.Header().Get("X-MacProvider-Provider"))
	}

	hfRR := postChat(t, server, []byte(`{"model":"`+hfID+`","messages":[{"role":"user","content":"hello"}],"stream":false}`), nil)
	if hfRR.Code != http.StatusOK {
		t.Fatalf("HF-id status = %d, body=%s", hfRR.Code, hfRR.Body.String())
	}

	pinnedRR := postChat(t, server, []byte(`{"model":"`+catalogKey+`","messages":[{"role":"user","content":"hello"}],"stream":false}`), http.Header{
		"X-MacProvider-Provider": []string{"p1"},
	})
	if pinnedRR.Code != http.StatusOK {
		t.Fatalf("pinned catalog-key status = %d, body=%s", pinnedRR.Code, pinnedRR.Body.String())
	}
	if pinnedRR.Header().Get("X-MacProvider-Provider") != "p1" {
		t.Fatalf("pinned catalog-key provider header = %q", pinnedRR.Header().Get("X-MacProvider-Provider"))
	}
}

func TestHTTPForwardingStripsReceiptFromProviderWithoutPublishedReceiptKey(t *testing.T) {
	const spoofedReceipt = "spoofed.receipt"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-MacProvider-Receipt", spoofedReceipt)
		_, _ = w.Write([]byte(`{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("receipt header = %q, want stripped for provider without receipt pubkey", got)
	}
}

func TestHTTPForwardingPassesReceiptFromProviderWithPublishedReceiptKey(t *testing.T) {
	const receipt = "trusted.receipt"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-MacProvider-Receipt", receipt)
		_, _ = w.Write([]byte(`{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpointReceiptPubkey(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20, bytes.Repeat([]byte{0x61}, 32))
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != receipt {
		t.Fatalf("receipt header = %q, want %q", got, receipt)
	}
}

func TestHTTPForwardingStripsReceiptWhenPillarDTruncatesBody(t *testing.T) {
	const receipt = "originalbytes.http.signed.receipt"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-MacProvider-Receipt", receipt)
		_, _ = w.Write([]byte(`{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"this content is longer than the cap and will get truncated"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":20,"total_tokens":24}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpointReceiptPubkey(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20, bytes.Repeat([]byte{0x61}, 32))
	tier2Cfg := config.Default().Tier2
	tier2Cfg.BehavioralSafetyEnabled = true
	tier2Cfg.OutputSizeCapBytes = 8
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(tier2Cfg),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if bytes.Contains(rr.Body.Bytes(), []byte("truncated")) {
		t.Fatalf("body was not truncated by PillarD: %s", rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("receipt header = %q, want stripped because PillarD mutated the body the provider signed", got)
	}
}

func TestHTTPForwardingStripsV04SettlementReceiptFromBuyerResponse(t *testing.T) {
	receipt := base64.StdEncoding.EncodeToString([]byte(`{"receipt_version":"4","terminal_state_ts_unix_ms":1782864001789}`)) + "." + base64.StdEncoding.EncodeToString([]byte("signature"))
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-MacProvider-Receipt", receipt)
		_, _ = w.Write([]byte(`{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpointReceiptPubkey(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20, bytes.Repeat([]byte{0x61}, 32))
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("v0.4 settlement receipt header leaked to buyer: %q", got)
	}
}

func TestHTTPForwardingPassesTrustedNullUsageReceipt(t *testing.T) {
	const receipt = "trusted.null-usage.receipt"
	body := []byte(`{"error":{"message":"model not loaded","type":"api_error","param":null,"code":"error_model_not_loaded"}}`)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-MacProvider-Receipt", receipt)
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write(body)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpointReceiptPubkey(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20, bytes.Repeat([]byte{0x62}, 32))
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`), nil)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d body=%s", rr.Code, http.StatusServiceUnavailable, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != receipt {
		t.Fatalf("receipt header = %q, want %q", got, receipt)
	}
	if got := rr.Header().Get("X-MacProvider-Provider"); got != "p1" {
		t.Fatalf("provider header = %q", got)
	}
	if got := rr.Header().Get("X-MacProvider-Route"); got != "session-1" {
		t.Fatalf("route header = %q", got)
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte("error_model_not_loaded")) {
		t.Fatalf("body = %s, want provider error body", rr.Body.String())
	}
}

func TestRequestLogNilGuard(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
}

func TestRequestLogBuyerMultiAttemptRows(t *testing.T) {
	const requestID = "11111111-1111-4111-8111-111111111111"
	var providerRequestIDs []string
	failUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("X-Request-ID")
		if got == "" || got == requestID {
			t.Fatalf("fail X-Request-ID = %q, want coordinator-generated value", got)
		}
		providerRequestIDs = append(providerRequestIDs, got)
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}))
	defer failUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("X-Request-ID")
		if got == "" || got == requestID {
			t.Fatalf("ok X-Request-ID = %q, want coordinator-generated value", got)
		}
		providerRequestIDs = append(providerRequestIDs, got)
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "fail", EndpointURL: failUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "fail", "s1", "model-a", pool.StateReady, 20000, 1, failUpstream.URL, 30)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 1,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
		"X-MacProvider-Retry": []string{"1"},
		"X-Request-ID":        []string{requestID},
	})

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if len(providerRequestIDs) != 2 || providerRequestIDs[0] != providerRequestIDs[1] {
		t.Fatalf("provider request IDs = %#v, want same coordinator-generated ID across attempts", providerRequestIDs)
	}
	rows := queryRequestLogRows(t, dbPath, providerRequestIDs[0])
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2: %#v", len(rows), rows)
	}
	if rows[0].ID >= rows[1].ID {
		t.Fatalf("ids not increasing: %#v", rows)
	}
	if rows[0].ProviderAssignedID.String != "s1" || rows[1].ProviderAssignedID.String != "s2" {
		t.Fatalf("provider assignments = %#v, want s1 then s2", rows)
	}
	if rows[0].Retried != 0 || rows[1].Retried != 1 {
		t.Fatalf("retried values = %d,%d want 0,1", rows[0].Retried, rows[1].Retried)
	}
	if rows[1].PromptTokens.Int64 != 4 || !rows[1].PromptTokens.Valid || rows[1].CompletionTokens.Int64 != 2 || !rows[1].CompletionTokens.Valid {
		t.Fatalf("success usage not logged: %#v", rows[1])
	}
}

func TestRequestLogBuyerPinnedClientRequestIDDoesNotReuseBillingID(t *testing.T) {
	const clientRequestID = "44444444-4444-4444-8444-444444444444"
	var providerRequestIDs []string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("X-Request-ID")
		if got == "" || got == clientRequestID {
			t.Fatalf("provider X-Request-ID = %q, want coordinator-generated value", got)
		}
		providerRequestIDs = append(providerRequestIDs, got)
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRequestLog(reqLog))
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`)
	for i := 0; i < 2; i++ {
		rr := postChat(t, server, body, http.Header{"X-Request-ID": []string{clientRequestID}})
		if rr.Code != http.StatusOK {
			t.Fatalf("request %d status=%d body=%s", i, rr.Code, rr.Body.String())
		}
	}
	if len(providerRequestIDs) != 2 || providerRequestIDs[0] == providerRequestIDs[1] {
		t.Fatalf("provider request IDs = %#v, want distinct coordinator-generated IDs", providerRequestIDs)
	}
	if rows := queryRequestLogRows(t, dbPath, clientRequestID); len(rows) != 0 {
		t.Fatalf("request_log used buyer request ID: %#v", rows)
	}
	for _, id := range providerRequestIDs {
		if rows := queryRequestLogRows(t, dbPath, id); len(rows) != 1 {
			t.Fatalf("request_log rows for %s = %d, want 1: %#v", id, len(rows), rows)
		}
	}
	// SPEC-002 v1.4.2 R-2: external_request_id MUST equal the inbound
	// X-Request-ID on EVERY row of one logical request, **regardless of
	// pinning** (i.e., even when per-row request_id differs). This test
	// covers the pinned-retry-shape branch: each row carries a distinct
	// coordinator-generated request_id (asserted above via
	// providerRequestIDs[0] != providerRequestIDs[1]) yet both rows must
	// carry the same external_request_id.
	allRows := queryAllRequestLogRows(t, dbPath)
	if len(allRows) != 2 {
		t.Fatalf("queryAllRequestLogRows = %d rows, want 2", len(allRows))
	}
	for i, row := range allRows {
		if !row.ExternalRequestID.Valid || row.ExternalRequestID.String != clientRequestID {
			t.Fatalf("row[%d] external_request_id = %#v, want %q", i, row.ExternalRequestID, clientRequestID)
		}
	}
	if allRows[0].RequestID == allRows[1].RequestID {
		t.Fatalf("guarded invariant broken: expected distinct request_id per row, got %q twice", allRows[0].RequestID)
	}
}

// SPEC-002 v1.4.2 R-2 / §11 + issue #188: when an inbound buyer
// request carries an X-Request-ID header, the coordinator MUST store
// that value in request_log.external_request_id on every row that
// covers the logical request (success row + any retry rows). This is
// the reconciliation join-key shared with gateway usage_events.
// request_log.request_id continues to be the coordinator's per-attempt
// internal id (unchanged behavior); SPEC-002 v1.4.2 names the inbound
// header value as external_request_id specifically to avoid disturbing
// the per-attempt-unique invariant the existing test suite verifies.
func TestRequestLogPreservesInboundXRequestIDAcrossAttempts(t *testing.T) {
	const externalID = "55555555-5555-4555-8555-555555555555"
	failUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}))
	defer failUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "fail", EndpointURL: failUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "fail", "s1", "model-a", pool.StateReady, 20000, 1, failUpstream.URL, 30)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 1,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
		"X-MacProvider-Retry": []string{"1"},
		"X-Request-ID":        []string{externalID},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}

	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2 (fail + ok attempt): %#v", len(rows), rows)
	}
	for i, row := range rows {
		if !row.ExternalRequestID.Valid || row.ExternalRequestID.String != externalID {
			t.Fatalf("row[%d] external_request_id = %#v, want %q", i, row.ExternalRequestID, externalID)
		}
		// Existing invariant preserved: per-attempt request_id is coord-generated
		// and MUST NOT equal the buyer's X-Request-ID.
		if row.RequestID == externalID {
			t.Fatalf("row[%d] request_id == buyer X-Request-ID; should be coord-generated", i)
		}
	}
	// In the non-pinned retry path (this test), both attempt rows share
	// the SAME coord-generated request_id (see existing
	// TestRequestLogBuyerMultiAttemptRows at line ~1093). The shared
	// external_request_id above is the property new to v1.4.2.
	if rows[0].RequestID != rows[1].RequestID {
		t.Fatalf("non-pinned retry rows should share request_id; got %q vs %q", rows[0].RequestID, rows[1].RequestID)
	}
}

// When the inbound request carries NO X-Request-ID, the coordinator
// MUST still log a row but external_request_id is NULL (empty
// sql.NullString). Existing buyer flows that omit the header remain
// observable.
// Malformed inbound X-Request-ID headers (control characters,
// over-128 bytes) MUST be rejected at the handler boundary and stored
// as NULL, not passed through to the persistent log column.
// Defense-in-depth per the codex security-lane audit (ISS-188 R1).
// The inbound header is buyer-controllable; an empty / NULL
// external_request_id loses the reconciliation join for this row but
// keeps malformed payloads out of structured logs and DB rows.
func TestRequestLogExternalRequestIDRejectsMalformedHeader(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer upstream.Close()

	for name, badHeader := range map[string]string{
		"control_null": "req-\x00abc",
		"control_lf":   "req-\nabc",
		"del_char":     "req-\x7fabc",
		"over_128":     strings.Repeat("a", 129),
		// SPEC-002 v1.5.1 R-2 / issue #197 R1 security + code lanes:
		// raw C1 bytes must be rejected at byte level (rune iteration
		// would decode 0x80-0x9f to utf8.RuneError and accept them).
		"c1_low":             "req-\x80abc",
		"c1_csi":             "req-\x9babc",
		"c1_high":            "req-\x9fabc",
		"invalid_utf8_lead":  "req-\xc3abc",
		"invalid_utf8_alone": "req-\xff",
	} {
		t.Run(name, func(t *testing.T) {
			reqLog, dbPath := openBuyerRequestLog(t)
			defer reqLog.Close()
			registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
			registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
			server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRequestLog(reqLog))

			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`),
				http.Header{"X-Request-ID": []string{badHeader}})
			if rr.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			rows := queryAllRequestLogRows(t, dbPath)
			if len(rows) != 1 {
				t.Fatalf("rows=%d want 1: %#v", len(rows), rows)
			}
			if rows[0].ExternalRequestID.Valid {
				t.Fatalf("malformed inbound header persisted as %#v; want NULL",
					rows[0].ExternalRequestID)
			}
		})
	}
}

// TestRequestLogModelFieldSanitized pins SPEC-002 v1.5.1 R3 security:
// buyer-supplied `model` JSON value must be sanitized before persisting
// to request_log.model. JSON tolerates `""` (valid UTF-8 for
// U+009B CSI), so a buyer can land C1 codepoints in the model column
// unless we sanitize on the way in. The sanitizer strips C1 codepoints
// so the persisted value loses them (and the model lookup naturally
// fails because no provider serves a malformed model name).
func TestRequestLogModelFieldSanitized(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRequestLog(reqLog))

	// model contains valid UTF-8 for U+009B (CSI). The sanitizer
	// strips C1 codepoints → "modelabc" lands in request_log; lookup
	// then 404s because no provider serves that name. The key
	// assertion is that the persisted column does not contain raw
	// or escaped C1.
	body := []byte("{\"model\":\"model\xc2\x9babc\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}")
	rr := postChat(t, server, body, nil)
	if rr.Code == http.StatusOK {
		t.Fatalf("expected 4xx for C1-bearing model; got status=%d body=%s", rr.Code, rr.Body.String())
	}
	// The unknown-model buyer-failure path writes a 4xx request_log
	// row via logBuyerFailure. That row's model column MUST contain
	// the SANITIZED value (C1 stripped, "modelabc") - proving the
	// sanitizer is on the persistence path even for buyer-failure
	// rows, not just success rows.
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("rows=%d, want 1 buyer-failure row: %#v", len(rows), rows)
	}
	row := rows[0]
	if strings.ContainsRune(row.Model, 0x9b) {
		t.Fatalf("request_log.model contains C1 codepoint U+009B: %q", row.Model)
	}
	if row.Model != "modelabc" {
		t.Fatalf("request_log.model = %q, want %q (C1 stripped)", row.Model, "modelabc")
	}
}

func TestRequestLogExternalRequestIDNullWhenHeaderAbsent(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer upstream.Close()
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRequestLog(reqLog))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("rows=%d want 1: %#v", len(rows), rows)
	}
	if rows[0].ExternalRequestID.Valid {
		t.Fatalf("external_request_id = %#v, want NULL", rows[0].ExternalRequestID)
	}
}

func TestSuccessfulNonStreamingBillingClampsInflatedProviderCompletion(t *testing.T) {
	responseBody := []byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":10000000,"total_tokens":10000004}}`)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(responseBody)
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
		},
	}
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithTier2Config(config.Tier2Config{OutputBytesPerTokenCeiling: 16}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	row := queryLatestBillingRow(t, dbPath)
	wantEstimate := int64((len(responseBody) + 15) / 16)
	if row.UsageSource != "byte_estimated" {
		t.Fatalf("usage_source=%q want byte_estimated", row.UsageSource)
	}
	if row.EstimatedCompletionTokens != wantEstimate {
		t.Fatalf("estimated_completion_tokens=%d want %d", row.EstimatedCompletionTokens, wantEstimate)
	}
	if row.CompletionTokens != 10000000 {
		t.Fatalf("stored provider completion_tokens=%d want 10000000", row.CompletionTokens)
	}
	wantGross := int64(4 + 2*wantEstimate)
	if row.GrossCredits != wantGross {
		t.Fatalf("gross_credits=%d want %d", row.GrossCredits, wantGross)
	}
}

func TestNonStreamingCompletesIncompleteProviderUsageBeforeForwarding(t *testing.T) {
	responseBody := []byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"cached_prompt_tokens":null}}`)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(responseBody)
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
		},
	}
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithTier2Config(config.Tier2Config{OutputBytesPerTokenCeiling: 16}),
	)

	requestBody := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`)
	rr := postChat(t, server, requestBody, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var out struct {
		Usage struct {
			PromptTokens       int64 `json:"prompt_tokens"`
			CachedPromptTokens int64 `json:"cached_prompt_tokens"`
			CompletionTokens   int64 `json:"completion_tokens"`
			TotalTokens        int64 `json:"total_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
		t.Fatalf("response json: %v body=%s", err, rr.Body.String())
	}
	wantPrompt := int64(len(requestBody) / 4)
	if wantPrompt < 1 {
		wantPrompt = 1
	}
	wantCompletion := int64((len(responseBody) + 15) / 16)
	if out.Usage.PromptTokens != wantPrompt || out.Usage.CachedPromptTokens != 0 || out.Usage.CompletionTokens != wantCompletion || out.Usage.TotalTokens != wantPrompt+wantCompletion {
		t.Fatalf("usage=%+v, want complete estimated usage with prompt=%d completion=%d", out.Usage, wantPrompt, wantCompletion)
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open billing db: %v", err)
	}
	defer db.Close()
	var usageSource string
	var quarantined int
	var reason sql.NullString
	if err := db.QueryRow(`SELECT usage_source, quarantined, quarantine_reason FROM ledger_request_credits ORDER BY id DESC LIMIT 1`).Scan(&usageSource, &quarantined, &reason); err != nil {
		t.Fatalf("query billing row: %v", err)
	}
	if usageSource != "byte_estimated" || quarantined != 1 || !reason.Valid || reason.String != "invalid_cached_prompt_tokens" {
		t.Fatalf("billing row usage_source/quarantine/reason = %s/%d/%#v, want byte_estimated/1/invalid_cached_prompt_tokens", usageSource, quarantined, reason)
	}
}

func TestStreamingBillingMergesLaterPartialUsageWithPriorPrompt(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		_, _ = w.Write([]byte("data: {\"id\":\"chunk\",\"usage\":{\"prompt_tokens\":3,\"cached_prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":3},\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"id\":\"chunk\",\"usage\":{\"completion_tokens\":1},\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
		},
	}
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithTier2Config(config.Tier2Config{OutputBytesPerTokenCeiling: 16}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	row := queryLatestBillingRow(t, dbPath)
	if row.UsageSource != "byte_estimated" {
		t.Fatalf("usage_source=%q want byte_estimated", row.UsageSource)
	}
	if row.CompletionTokens != 1 {
		t.Fatalf("completion_tokens=%d want 1", row.CompletionTokens)
	}
	wantGross := int64(5)
	if row.GrossCredits != wantGross {
		t.Fatalf("gross_credits=%d want %d from preserved prompt=3 and completion=1", row.GrossCredits, wantGross)
	}
	if row.Quarantined != 0 || row.QuarantineReason.Valid {
		t.Fatalf("row quarantined=%d reason=%#v, want clean", row.Quarantined, row.QuarantineReason)
	}
}

func TestStreamingOutputExceededAfterObservedUsagePaysZeroProviderCredits(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		_, _ = w.Write([]byte("data: {\"id\":\"chunk\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"id\":\"chunk\",\"usage\":{\"prompt_tokens\":3,\"cached_prompt_tokens\":0,\"completion_tokens\":100,\"total_tokens\":103},\"choices\":[{\"delta\":{},\"finish_reason\":null}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"id\":\"chunk\",\"choices\":[{\"delta\":{\"content\":\"" + strings.Repeat("x", 31) + "\"}}]}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
		},
	}
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithTier2Config(config.Tier2Config{OutputBytesPerTokenCeiling: 16}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true,"max_tokens":4}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"content":"ok"`) || !strings.Contains(rr.Body.String(), "stream_output_exceeded") {
		t.Fatalf("stream body missing forwarded prefix or terminal error: %s", rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), strings.Repeat("x", 31)) {
		t.Fatalf("stream body forwarded over-cap content: %s", rr.Body.String())
	}

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open billing db: %v", err)
	}
	defer db.Close()
	var usageSource, faultFlag string
	var grossCredits, providerCredits int64
	var promptTokens, completionTokens, estimatedCompletionTokens sql.NullInt64
	if err := db.QueryRow(`
SELECT usage_source, gross_credits, provider_credits, prompt_tokens, completion_tokens,
       estimated_completion_tokens, fault_flag
FROM ledger_request_credits
ORDER BY id DESC LIMIT 1`).Scan(
		&usageSource,
		&grossCredits,
		&providerCredits,
		&promptTokens,
		&completionTokens,
		&estimatedCompletionTokens,
		&faultFlag,
	); err != nil {
		t.Fatalf("query billing row: %v", err)
	}
	if usageSource != billing.UsageByteEstimated || grossCredits != 0 || providerCredits != 0 || promptTokens.Valid || completionTokens.Valid || !estimatedCompletionTokens.Valid || estimatedCompletionTokens.Int64 != 0 || faultFlag != billing.FaultBreakerQualifying {
		t.Fatalf("billing row usage/gross/provider/prompt/completion/estimated/fault = %s/%d/%d/%#v/%#v/%#v/%s, want byte_estimated/0/0/NULL/NULL/0/%s",
			usageSource, grossCredits, providerCredits, promptTokens, completionTokens, estimatedCompletionTokens, faultFlag, billing.FaultBreakerQualifying)
	}

	outputRows := querySettlementAttemptOutputs(t, dbPath)
	if len(outputRows) != 1 {
		t.Fatalf("settlement output rows=%d want 1: %#v", len(outputRows), outputRows)
	}
	row := outputRows[0]
	if row.TerminalState != billing.TerminalStateProviderError || row.UsageSource != billing.UsageSourceByteEstimated || row.Start != 0 || row.End != 2 || row.OutputAvailable != 1 {
		t.Fatalf("settlement output row=%#v, want provider_error byte_estimated delivered prefix [0,2)", row)
	}
}

func TestStreamingBillingLatchesInvalidCachedPromptTokensAfterLaterValidUsage(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		_, _ = w.Write([]byte("data: {\"id\":\"chunk\",\"usage\":{\"prompt_tokens\":3,\"cached_prompt_tokens\":4,\"completion_tokens\":0,\"total_tokens\":3},\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"id\":\"chunk\",\"usage\":{\"prompt_tokens\":3,\"cached_prompt_tokens\":0,\"completion_tokens\":1,\"total_tokens\":4},\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
		},
	}
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithTier2Config(config.Tier2Config{OutputBytesPerTokenCeiling: 16}),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), `"cached_prompt_tokens":4`) {
		t.Fatalf("stream leaked invalid cached_prompt_tokens to buyer: %s", rr.Body.String())
	}
	row := queryLatestBillingRow(t, dbPath)
	if row.UsageSource != "byte_estimated" {
		t.Fatalf("usage_source=%q want byte_estimated", row.UsageSource)
	}
	if row.CachedPromptTokens.Valid {
		t.Fatalf("cached_prompt_tokens=%#v want NULL", row.CachedPromptTokens)
	}
	if row.Quarantined != 1 || !row.QuarantineReason.Valid || row.QuarantineReason.String != "invalid_cached_prompt_tokens" {
		t.Fatalf("row quarantined=%d reason=%#v, want invalid_cached_prompt_tokens", row.Quarantined, row.QuarantineReason)
	}
}

func TestNonStreamingBillingDiscountsCachedPromptTokensOnlyOnStickyHit(t *testing.T) {
	var calls int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Content-Type", "application/json")
		if calls == 1 {
			_, _ = w.Write([]byte(`{"id":"seed","choices":[{"message":{"content":"seed"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}`))
			return
		}
		_, _ = w.Write([]byte(`{"id":"hit","choices":[{"message":{"content":"hit"}}],"usage":{"prompt_tokens":10,"cached_prompt_tokens":4,"completion_tokens":2,"total_tokens":12}}`))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {
				PromptCreditsPerMtok:         1000000,
				PromptCacheHitCreditsPerMtok: 250000,
				CompletionCreditsPerMtok:     2000000,
			},
		},
	}
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: upstream.URL},
		{ProviderID: "p2", EndpointURL: upstream.URL},
	})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:           true,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
			RetryPerAttemptTimeoutS: 1,
		}),
	)
	headers := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:cache-hit"},
		"X-MacProvider-Account":       []string{"acct_cache"},
	}
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`)

	seed := postChat(t, server, body, headers)
	if seed.Code != http.StatusOK {
		t.Fatalf("seed status=%d body=%s", seed.Code, seed.Body.String())
	}
	seedProvider := seed.Header().Get("X-MacProvider-Provider")
	if seedProvider == "" {
		t.Fatalf("seed provider header empty")
	}
	rr := postChat(t, server, body, headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("hit status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Provider"); got != seedProvider {
		t.Fatalf("sticky provider=%q want seeded provider %q", got, seedProvider)
	}
	assertResponseCachedPromptTokens(t, rr.Body.Bytes(), 4)
	row := queryLatestBillingRow(t, dbPath)
	if !row.CachedPromptTokens.Valid || row.CachedPromptTokens.Int64 != 4 {
		t.Fatalf("cached_prompt_tokens=%#v want 4", row.CachedPromptTokens)
	}
	if row.Quarantined != 0 || row.QuarantineReason.Valid {
		t.Fatalf("row quarantined=%d reason=%#v, want clean", row.Quarantined, row.QuarantineReason)
	}
	if row.GrossCredits != 11 {
		t.Fatalf("gross_credits=%d want 11", row.GrossCredits)
	}
}

func TestNonStreamingBillingDiscountsCachedPromptTokensOnSingleProviderStickyHit(t *testing.T) {
	var calls int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Content-Type", "application/json")
		if calls == 1 {
			_, _ = w.Write([]byte(`{"id":"seed","choices":[{"message":{"content":"seed"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}`))
			return
		}
		_, _ = w.Write([]byte(`{"id":"hit","choices":[{"message":{"content":"hit"}}],"usage":{"prompt_tokens":10,"cached_prompt_tokens":4,"completion_tokens":2,"total_tokens":12}}`))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {
				PromptCreditsPerMtok:         1000000,
				PromptCacheHitCreditsPerMtok: 250000,
				CompletionCreditsPerMtok:     2000000,
			},
		},
	}
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:           true,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
			RetryPerAttemptTimeoutS: 1,
		}),
	)
	headers := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:single-cache-hit"},
		"X-MacProvider-Account":       []string{"acct_cache"},
	}
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`)

	seed := postChat(t, server, body, headers)
	if seed.Code != http.StatusOK {
		t.Fatalf("seed status=%d body=%s", seed.Code, seed.Body.String())
	}
	rr := postChat(t, server, body, headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("hit status=%d body=%s", rr.Code, rr.Body.String())
	}
	assertResponseCachedPromptTokens(t, rr.Body.Bytes(), 4)
	row := queryLatestBillingRow(t, dbPath)
	if !row.CachedPromptTokens.Valid || row.CachedPromptTokens.Int64 != 4 {
		t.Fatalf("cached_prompt_tokens=%#v want 4", row.CachedPromptTokens)
	}
	if row.Quarantined != 0 || row.QuarantineReason.Valid {
		t.Fatalf("row quarantined=%d reason=%#v, want clean", row.Quarantined, row.QuarantineReason)
	}
	if row.GrossCredits != 11 {
		t.Fatalf("gross_credits=%d want 11", row.GrossCredits)
	}
}

// TestWSTunneledStickyEligibleForwardsConversationKeyOnBothMissAndHit asserts
// the corrected behavior: coord forwards X-MacProvider-Internal-Conv to the
// provider on every sticky-eligible request, not just on sticky_hit. The
// original PR #332 gated forwarding on state.stickyResult == "hit"; that
// gate made the provider-side ConversationCache architecturally incapable
// of populating (turn 1 is always a sticky miss, so the provider never got
// a key to store the KV state under; turn 2 was a hit and looked up an
// empty cache). Prod verify against api.streamvc.live on 2026-07-03 with
// binary v1.7.9 + coord fe175d0 reproduced this: sticky_hit confirmed in
// coord logs, both turns on same provider mac, but cached_prompt_tokens=0
// on turn 2. This test codifies the fix.
func TestWSTunneledStickyEligibleForwardsConversationKeyOnBothMissAndHit(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)

	var forwardedKeys []string
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:    true,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			forwardedKeys = append(forwardedKeys, providerws.ConversationKeyFromContext(ctx))
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{
				Type:      "inference_response_chunk",
				RequestID: requestID,
				Seq:       0,
				Data:      `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`,
			}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`)
	headers := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:ws-cache"},
		"X-MacProvider-Account":       []string{"acct_cache"},
	}

	// Turn 1: sticky miss (nothing established yet). Provider MUST still
	// receive the conversation_key so its ConversationCache.begin() can
	// enter the populate-on-first-turn path (cold_start miss lease → commit
	// on inference completion).
	seed := postChat(t, server, body, headers)
	if seed.Code != http.StatusOK {
		t.Fatalf("seed status=%d body=%s", seed.Code, seed.Body.String())
	}
	// Turn 2: sticky hit (state established after turn 1). Provider looks up
	// under the same key and finds the entry stored on turn 1.
	hit := postChat(t, server, body, headers)
	if hit.Code != http.StatusOK {
		t.Fatalf("hit status=%d body=%s", hit.Code, hit.Body.String())
	}
	// Turn 3: different conversation key (sticky miss for THIS key). Same
	// contract as turn 1 — provider must receive the new key to start a
	// separate cache bucket for it.
	missHeaders := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:ws-cache-miss"},
		"X-MacProvider-Account":       []string{"acct_cache"},
	}
	miss := postChat(t, server, body, missHeaders)
	if miss.Code != http.StatusOK {
		t.Fatalf("miss status=%d body=%s", miss.Code, miss.Body.String())
	}

	if len(forwardedKeys) != 3 {
		t.Fatalf("forwarded keys = %#v, want 3 calls", forwardedKeys)
	}
	// All three calls must forward the conversation_key present in the
	// header. Empty on seed would recreate the "cache never populates" bug.
	if forwardedKeys[0] != "conv:ws-cache" {
		t.Fatalf("seed forwarded conversation_key=%q, want conv:ws-cache (must populate turn 1 for turn 2 to hit)", forwardedKeys[0])
	}
	if forwardedKeys[1] != "conv:ws-cache" {
		t.Fatalf("hit forwarded conversation_key=%q, want conv:ws-cache", forwardedKeys[1])
	}
	if forwardedKeys[2] != "conv:ws-cache-miss" {
		t.Fatalf("miss forwarded conversation_key=%q, want conv:ws-cache-miss", forwardedKeys[2])
	}
}

// TestStickyEligibleWithoutInternalConvHeaderForwardsEmpty locks in the
// header-presence check: if the gateway did not set X-MacProvider-Internal-Conv
// (e.g. demo path, buyer did not send X-MacProvider-Conversation), coord
// MUST NOT invent a key. Empty string forwarded → provider bypasses cache
// entirely (ConversationCache.begin() returns nil on empty key). Prevents
// cache-poisoning by a downstream that never opted into sticky routing.
func TestStickyEligibleWithoutInternalConvHeaderForwardsEmpty(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)

	var forwardedKeys []string
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:    true,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			forwardedKeys = append(forwardedKeys, providerws.ConversationKeyFromContext(ctx))
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{
				Type:      "inference_response_chunk",
				RequestID: requestID,
				Seq:       0,
				Data:      `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`,
			}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`)
	headers := http.Header{
		"Authorization":         []string{"Bearer operator-key"},
		"X-MacProvider-Account": []string{"acct_no_conv"},
	}
	resp := postChat(t, server, body, headers)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if len(forwardedKeys) != 1 || forwardedKeys[0] != "" {
		t.Fatalf("forwardedKeys=%#v, want single empty entry (no header → no key)", forwardedKeys)
	}
}

// TestStickyEligibleRejectsInternalConvWithoutConvPrefix locks in the
// "conv:" prefix check: gateway-issued keys start with "conv:", so a header
// with any other shape is a spoof from an unexpected downstream. Coord must
// not forward it — otherwise a downstream could inject a raw string that
// might collide with a legitimate cache key on the provider.
func TestStickyEligibleRejectsInternalConvWithoutConvPrefix(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)

	var forwardedKeys []string
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:    true,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			forwardedKeys = append(forwardedKeys, providerws.ConversationKeyFromContext(ctx))
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{
				Type:      "inference_response_chunk",
				RequestID: requestID,
				Seq:       0,
				Data:      `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`,
			}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`)
	headers := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"raw-string-not-a-conv-key"},
		"X-MacProvider-Account":       []string{"acct_bad"},
	}
	resp := postChat(t, server, body, headers)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if len(forwardedKeys) != 1 || forwardedKeys[0] != "" {
		t.Fatalf("forwardedKeys=%#v, want single empty entry (header not conv:-prefixed → no key)", forwardedKeys)
	}
}

func TestNonStreamingBillingQuarantinesCachedPromptTokensWhenStickyProviderPreflightRejected(t *testing.T) {
	p1Upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"seed","choices":[{"message":{"content":"seed"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}`))
	}))
	defer p1Upstream.Close()
	p2Upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"fallback","choices":[{"message":{"content":"fallback"}}],"usage":{"prompt_tokens":10,"cached_prompt_tokens":4,"completion_tokens":2,"total_tokens":12}}`))
	}))
	defer p2Upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {
				PromptCreditsPerMtok:         1000000,
				PromptCacheHitCreditsPerMtok: 250000,
				CompletionCreditsPerMtok:     2000000,
			},
		},
	}
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: p1Upstream.URL},
		{ProviderID: "p2", EndpointURL: p2Upstream.URL},
	})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, p1Upstream.URL, 20)
	registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 2, p2Upstream.URL, 20)
	p1PreflightCalls := 0
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithPreflightConfig(1, time.Second),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			if provider.ProviderID == "p1" {
				p1PreflightCalls++
				if p1PreflightCalls > 1 {
					return buyer.PreflightResult{Accepted: false, Reason: "queue_full"}, true, nil
				}
			}
			return buyer.PreflightResult{Accepted: true}, true, nil
		}),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:           true,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
			RetryPerAttemptTimeoutS: 1,
		}),
	)
	headers := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:preflight-cache-hit"},
		"X-MacProvider-Account":       []string{"acct_cache"},
	}
	body := chatBodyWithContent("model-a", strings.Repeat("x", 64))

	seed := postChat(t, server, body, headers)
	if seed.Code != http.StatusOK {
		t.Fatalf("seed status=%d body=%s", seed.Code, seed.Body.String())
	}
	if got := seed.Header().Get("X-MacProvider-Provider"); got != "p1" {
		t.Fatalf("seed provider=%q want p1", got)
	}
	rr := postChat(t, server, body, headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("fallback status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Provider"); got != "p2" {
		t.Fatalf("fallback provider=%q want p2", got)
	}
	assertResponseCachedPromptTokens(t, rr.Body.Bytes(), 0)
	row := queryLatestBillingRow(t, dbPath)
	if row.CachedPromptTokens.Valid {
		t.Fatalf("cached_prompt_tokens=%#v want NULL", row.CachedPromptTokens)
	}
	if row.Quarantined != 1 || !row.QuarantineReason.Valid || row.QuarantineReason.String != "ambiguous_cache" {
		t.Fatalf("row quarantined=%d reason=%#v, want ambiguous_cache quarantine", row.Quarantined, row.QuarantineReason)
	}
	if row.GrossCredits != 0 {
		t.Fatalf("gross_credits=%d want 0", row.GrossCredits)
	}
}

func TestNonStreamingBillingQuarantinesPositiveCachedPromptTokensWithoutStickyHit(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ambiguous","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":10,"cached_prompt_tokens":4,"completion_tokens":2,"total_tokens":12}}`))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {
				PromptCreditsPerMtok:         1000000,
				PromptCacheHitCreditsPerMtok: 250000,
				CompletionCreditsPerMtok:     2000000,
			},
		},
	}
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	assertResponseCachedPromptTokens(t, rr.Body.Bytes(), 0)
	row := queryLatestBillingRow(t, dbPath)
	if row.CachedPromptTokens.Valid {
		t.Fatalf("cached_prompt_tokens=%#v want NULL", row.CachedPromptTokens)
	}
	if row.Quarantined != 1 || !row.QuarantineReason.Valid || row.QuarantineReason.String != "ambiguous_cache" {
		t.Fatalf("quarantine=%d reason=%#v want ambiguous_cache", row.Quarantined, row.QuarantineReason)
	}
	if row.GrossCredits != 0 {
		t.Fatalf("gross_credits=%d want 0 for quarantined row", row.GrossCredits)
	}
}

func TestIdempotencyKeyRejectsReplayAndBodyMismatchBeforeProvider(t *testing.T) {
	var calls int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer upstream.Close()

	reqLog, _ := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRequestLog(reqLog))

	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`)
	headers := http.Header{"Idempotency-Key": []string{"idem-1"}}
	rr := postChat(t, server, body, headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("first status=%d body=%s", rr.Code, rr.Body.String())
	}
	rr = postChat(t, server, body, headers)
	if rr.Code != http.StatusConflict || !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"idempotency_key_replayed"`)) {
		t.Fatalf("replay status=%d body=%s", rr.Code, rr.Body.String())
	}
	otherBody := []byte(`{"model":"model-a","messages":[{"role":"user","content":"different"}]}`)
	rr = postChat(t, server, otherBody, headers)
	if rr.Code != http.StatusConflict || !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"idempotency_key_body_mismatch"`)) {
		t.Fatalf("mismatch status=%d body=%s", rr.Code, rr.Body.String())
	}
	if calls != 1 {
		t.Fatalf("provider calls=%d want 1", calls)
	}
}

func TestRawHTTPStreamingBuyerCancelDoesNotBreakerFaultProvider(t *testing.T) {
	firstChunk := make(chan struct{})
	cancelSeen := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		flusher, _ := w.(http.Flusher)
		_, _ = fmt.Fprint(w, `data: {"id":"chunk","usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6},"choices":[{"delta":{"content":"ok"}}]}`+"\n\n")
		if flusher != nil {
			flusher.Flush()
		}
		close(firstChunk)
		<-r.Context().Done()
		close(cancelSeen)
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
	rewards := config.RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]config.RateCardEntry{
			"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
		},
	}
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
	)
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`)).WithContext(ctx)
	rr := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		server.Handler().ServeHTTP(rr, req)
		close(done)
	}()
	select {
	case <-firstChunk:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for first stream chunk")
	}
	time.Sleep(50 * time.Millisecond)
	cancel()
	select {
	case <-cancelSeen:
	case <-time.After(2 * time.Second):
		t.Fatal("upstream did not see buyer cancellation")
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("coordinator did not finish after buyer cancellation")
	}
	if got := rr.Code; got != http.StatusOK {
		t.Fatalf("response code=%d body=%s", got, rr.Body.String())
	}
	gross, providerCredits, fault := queryBillingCredit(t, dbPath)
	if gross <= 0 || providerCredits <= 0 || fault != billing.FaultNone {
		t.Fatalf("billing row gross=%d provider=%d fault=%s, want paid non-breaker row", gross, providerCredits, fault)
	}
	provider, ok := providerByID(registry, "p1")
	if !ok || provider.State != pool.StateReady {
		t.Fatalf("provider after buyer cancel = %#v ok=%v, want ready", provider, ok)
	}
}

func TestRequestLogBuyerErrorCodePopulation(t *testing.T) {
	const requestID = "22222222-2222-4222-8222-222222222222"
	var relayRequestID string
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, gotRequestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			if gotRequestID == "" || gotRequestID == requestID {
				t.Fatalf("relay request_id = %q, want coordinator-generated value", gotRequestID)
			}
			relayRequestID = gotRequestID
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: gotRequestID, Status: "error_model_not_loaded"}
			return &providerws.RelayStream{RequestID: gotRequestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
		"X-Request-ID": []string{requestID},
	})

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	rows := queryRequestLogRows(t, dbPath, relayRequestID)
	if len(rows) != 1 {
		t.Fatalf("request_log rows = %d, want 1: %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusServiceUnavailable {
		t.Fatalf("logged status = %d, want 503", rows[0].Status)
	}
	if !rows[0].ErrorCode.Valid || rows[0].ErrorCode.String != "error_model_not_loaded" {
		t.Fatalf("error_code = %#v, want error_model_not_loaded", rows[0].ErrorCode)
	}
	if rows[0].PromptTokens.Valid || rows[0].CompletionTokens.Valid {
		t.Fatalf("usage tokens = %#v/%#v, want NULL", rows[0].PromptTokens, rows[0].CompletionTokens)
	}
}

func TestRequestLogBuyerValidationFailure(t *testing.T) {
	const requestID = "33333333-3333-4333-8333-333333333333"
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithRequestLog(reqLog))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":"bad"}`), http.Header{"X-Request-ID": []string{requestID}})

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("request_log rows = %d, want 1: %#v", len(rows), rows)
	}
	if rows[0].RequestID == requestID {
		t.Fatalf("request_log used buyer X-Request-ID %q", requestID)
	}
	if rows[0].ProviderAssignedID.Valid {
		t.Fatalf("provider_assigned_id = %#v, want NULL", rows[0].ProviderAssignedID)
	}
	if rows[0].Status != http.StatusBadRequest || rows[0].Model != "model-a" {
		t.Fatalf("row = %#v, want 400/model-a", rows[0])
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

func TestChatCompletionsRejectsOversizedProviderBody(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(bytes.Repeat([]byte("x"), 16<<20+1))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 10)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`provider_failed`)) {
		t.Fatalf("body missing provider_failed: %s", rr.Body.String())
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
	jsonSchemaResponseFormat := `"response_format":{"type":"json_schema","json_schema":{"name":"person-v1","strict":true,"schema":{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"number"}},"required":["name","age"],"additionalProperties":false}}}`
	bodyFor := func(stream bool) []byte {
		streamField := ""
		responseFormat := jsonSchemaResponseFormat + `,`
		if stream {
			streamField = `,"stream":true`
			responseFormat = ""
		}
		return []byte(`{"model":"mlx-accurate","messages":[{"role":"user","content":"hello"}],"max_tokens":8,"seed":12345,"presence_penalty":0.25,"frequency_penalty":-0.5,` + responseFormat + `"metadata":{"trace":"preserve-me"}` + streamField + `}`)
	}
	assertForwardedBody := func(t *testing.T, body []byte, expectResponseFormat bool) {
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
		if expectResponseFormat {
			if string(got["response_format"]) != `{"type":"json_schema","json_schema":{"name":"person-v1","strict":true,"schema":{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"number"}},"required":["name","age"],"additionalProperties":false}}}` {
				t.Fatalf("response_format not preserved: %s", string(got["response_format"]))
			}
		} else if _, ok := got["response_format"]; ok {
			t.Fatalf("streaming response_format should be omitted in this fixture: %s", string(got["response_format"]))
		}
		if string(got["seed"]) != `12345` {
			t.Fatalf("seed not preserved: %s", string(got["seed"]))
		}
		if string(got["presence_penalty"]) != `0.25` {
			t.Fatalf("presence_penalty not preserved: %s", string(got["presence_penalty"]))
		}
		if string(got["frequency_penalty"]) != `-0.5` {
			t.Fatalf("frequency_penalty not preserved: %s", string(got["frequency_penalty"]))
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
				assertForwardedBody(t, capturedBody, !tc.stream)
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
					assertForwardedBody(t, capturedBody, !tc.stream)
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
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"request_body_too_large"`)) {
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
		buyer.WithGatewayServiceToken("operator-key"),
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
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithGatewayServiceToken("operator-key"))

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
		buyer.WithGatewayServiceToken("operator-key"),
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

func TestChatCompletionsWSTunneledNonStreamingResponseCap(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 2)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: strings.Repeat("a", 16<<20)}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 1, Data: "x"}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 2}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"provider_response_too_large"`)) {
		t.Fatalf("body missing provider_response_too_large: %s", rr.Body.String())
	}
}

func TestChatCompletionsWSTunneledTier2RejectsInvalidNonStreamingOutput(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	tier2Cfg := config.Default().Tier2
	tier2Cfg.BehavioralSafetyEnabled = true
	tier2Cfg.EncodingValidationEnabled = true
	recoveryIDs := make(chan string, 1)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(tier2Cfg),
		buyer.WithRecoveryConfig(10*time.Millisecond, 1, true),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			recoveryIDs <- requestID
			return buyer.PreflightResult{Accepted: true}, true, nil
		}),
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
	select {
	case requestID := <-recoveryIDs:
		if !strings.HasPrefix(requestID, "recovery-probe-") {
			t.Fatalf("requestID = %q", requestID)
		}
	case <-time.After(time.Second):
		t.Fatal("recovery preflight did not run")
	}
}

func TestChatCompletionsHTTPNonStreamingAppliesTier2OutputGuard(t *testing.T) {
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	var upstreamCalls int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamCalls++
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"id":"http","choices":[{"message":{"content":"bad\u0000"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	recoveryIDs := make(chan string, 1)
	tier2Cfg := config.Default().Tier2
	tier2Cfg.BehavioralSafetyEnabled = true
	tier2Cfg.EncodingValidationEnabled = true
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithTier2Config(tier2Cfg),
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
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"code":"tier2_output_encoding_invalid"`)) {
		t.Fatalf("body missing tier2 output error: %s", rr.Body.String())
	}
	if bytes.Contains(rr.Body.Bytes(), []byte(`bad`)) {
		t.Fatalf("blocked provider output leaked to buyer: %s", rr.Body.String())
	}
	if upstreamCalls != 1 {
		t.Fatalf("upstreamCalls=%d want 1", upstreamCalls)
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("request_log rows=%d want 1: %#v", len(rows), rows)
	}
	if rows[0].Status != http.StatusBadGateway {
		t.Fatalf("logged status=%d want 502", rows[0].Status)
	}
	if !rows[0].ErrorCode.Valid || rows[0].ErrorCode.String != "tier2_output_encoding_invalid" {
		t.Fatalf("logged error_code=%v want tier2_output_encoding_invalid", rows[0].ErrorCode)
	}
	if rows[0].PromptTokens.Valid || rows[0].CompletionTokens.Valid {
		t.Fatalf("blocked response logged billable tokens: prompt=%v completion=%v", rows[0].PromptTokens, rows[0].CompletionTokens)
	}
	select {
	case requestID := <-recoveryIDs:
		if !strings.HasPrefix(requestID, "recovery-probe-") {
			t.Fatalf("requestID = %q", requestID)
		}
	case <-time.After(time.Second):
		t.Fatal("recovery preflight did not run")
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

// Round-2 audit HIGH (M11 close-out): the WS-tunneled receipt forwarding
// path landed in C1's fix without an end-to-end test. These three cases
// pin the contract:
//   - end.Receipt is forwarded as X-MacProvider-Receipt when the
//     provider's pubkey is published on /poolz;
//   - the receipt is stripped when no pubkey is published;
//   - the receipt is stripped when PillarD mutates the buyer-visible body,
//     because the provider's signature no longer applies to the bytes the
//     buyer receives. The third case is the integrity gap the previous
//     round-2 HIGH flagged.
func TestChatCompletionsWSTunneledForwardsReceiptFromInferenceResponseEnd(t *testing.T) {
	const receipt = "trusted.ws.receipt"
	registry := pool.NewRegistry(nil)
	registerWithPathConnReceiptPubkey(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled, nil, bytes.Repeat([]byte{0x65}, 32))
	slotsFree := 1
	registry.ApplyStateUpdate("p1", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"ws","choices":[{"message":{"content":"ok"}}]}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1, Receipt: receipt}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != receipt {
		t.Fatalf("receipt header = %q, want %q", got, receipt)
	}
}

func TestChatCompletionsWSTunneledStripsReceiptWhenProviderHasNoReceiptPubkey(t *testing.T) {
	const receipt = "spoofed.ws.receipt"
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
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1, Receipt: receipt}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("receipt header = %q, want stripped because provider has no published receipt pubkey", got)
	}
}

func TestChatCompletionsWSTunneledStripsReceiptWhenPillarDTruncatesBody(t *testing.T) {
	const receipt = "originalbytes.signed.receipt"
	registry := pool.NewRegistry(nil)
	registerWithPathConnReceiptPubkey(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled, nil, bytes.Repeat([]byte{0x66}, 32))
	slotsFree := 1
	registry.ApplyStateUpdate("p1", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: time.Now().UTC()})
	tier2Cfg := config.Default().Tier2
	tier2Cfg.BehavioralSafetyEnabled = true
	tier2Cfg.OutputSizeCapBytes = 8
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithTier2Config(tier2Cfg),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"ws","choices":[{"message":{"content":"this content is longer than the cap and will get truncated"}}]}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1, Receipt: receipt}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if bytes.Contains(rr.Body.Bytes(), []byte("truncated")) {
		t.Fatalf("body was not truncated by PillarD: %s", rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("receipt header = %q, want stripped because PillarD mutated the body the provider signed", got)
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

func TestChatCompletionsStreamingWSTunneledPreCommitGenericFailureWritesSingleError(t *testing.T) {
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
			errs <- errors.New("provider failed before first chunk")
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`), nil)

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	if strings.Contains(body, "data:") {
		t.Fatalf("pre-commit failure wrote SSE after JSON error: %s", body)
	}
	if count := strings.Count(body, `"error"`); count != 1 {
		t.Fatalf("error envelope count=%d body=%s", count, body)
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

// Regression: M1-2 ARCH-1/CODE-1 divergence 1. Streaming-WS forwardWS returning
// wsForwardQueueFull must mark the provider StateBusy, matching the non-streaming
// loop's behavior. Pre-fix: streaming branch never called pool.MarkState; provider
// stayed StateReady and could be re-selected immediately.
func TestChatCompletionsStreamingWSTunneledQueueFullMarksProviderBusy(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 2, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
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
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" {
				done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "error_queue_full"}
				return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
			}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, 10*time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), http.Header{"X-MacProvider-Retry": []string{"1"}})

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("provider = %q, want p2", rr.Header().Get("X-MacProvider-Provider"))
	}
	if p1, ok := registry.Resolve("p1", ""); !ok || p1.State != pool.StateBusy {
		t.Fatalf("p1 = %#v ok=%v, want busy", p1, ok)
	}
}

// Regression: M1-2 ARCH-1/CODE-1 divergence 2. Non-streaming QueueFull path must
// increment explicitRetries (and faultedProviders) after the successful routing
// transition, matching the timeout-retry pattern. Pre-fix: the retry hop after
// QueueFull logged retried=0 on the next attempt's request_log row.
func TestChatCompletionsWSTunneledQueueFullIncrementsExplicitRetries(t *testing.T) {
	const requestID = "22222222-2222-4222-8222-222222222222"
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 2, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{
			MaxRetries:              1,
			RetryPerAttemptTimeoutS: 1,
			StickyTTLS:              1800,
			StickyMaxEntries:        10000,
		}),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" {
				done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "error_queue_full"}
				return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
			}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
		"X-MacProvider-Retry": []string{"1"},
		"X-Request-ID":        []string{requestID},
	})

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	rows := queryAllRequestLogRows(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2: %#v", len(rows), rows)
	}
	if rows[0].ProviderAssignedID.String != "s1" || rows[1].ProviderAssignedID.String != "s2" {
		t.Fatalf("provider assignments = %#v, want s1 then s2", rows)
	}
	if rows[0].Retried != 0 {
		t.Fatalf("rows[0].Retried = %d, want 0", rows[0].Retried)
	}
	if rows[1].Retried != 1 {
		t.Fatalf("rows[1].Retried = %d, want 1 (QueueFull retry hop must bump explicitRetries)", rows[1].Retried)
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
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `data: {"choices":[{"delta":{"content":"ok"}}]}` + "\n\n"}
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
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"ok"`)) {
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
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `data: {"choices":[{"delta":{"content":"partial"}}]}` + "\n\n"}
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
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"content":"partial"`)) {
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
	// M3 (finding H2 3-lane re-audit): the Retry-After:3600 hint and the
	// envelope's retryable field must agree — a buyer honoring either
	// signal reaches the same conclusion.
	if !bytes.Contains(rr.Body.Bytes(), []byte(`"retryable":true`)) {
		t.Fatalf("provisional_quota_exceeded must be retryable=true; body = %s", rr.Body.String())
	}
	if rr.Header().Get("Retry-After") != "3600" {
		t.Fatalf("Retry-After = %q, want 3600", rr.Header().Get("Retry-After"))
	}
}

func TestChatCompletionsValidationPrecedesModelLookup(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	body := []byte(`{"model":"missing-model","messages":[{"role":"user","content":"hello"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_0123456789abcdef","type":"function","function":{"name":"test","arguments":"{not json}"}}]}]}`)
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
	registry.UpdateHashStatuses(func(pool.Provider) pool.HashStatus {
		return pool.HashStatusCatalogUnavailable
	})
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

// SPEC-002 § 7.2 / issue #185: when the only provider for a model
// disconnects (cold-start race), the next buyer request for that
// model MUST return 503 no_provider_available, not 404
// model_not_found. The model is in pool-lifetime history; the
// distinction matters because OpenAI-compatible clients treat 404
// as misconfiguration ("the model id is wrong, stop trying") and
// 503 as transient ("back off, retry").
//
// Pre-#185, ModelKnown iterated only seenModelsByProvider, which the
// M2-5 / PERF-5 audit had wired up to drop on provider disconnect.
// This test pins the new lifetime accumulator (seenModelsLifetime) so
// a future PERF revert doesn't silently reintroduce the spec
// violation.
func TestChatCompletionsColdStartRaceReturnsNoProviderAvailable(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "http://p1.example"}})
	// 1. Provider registers and advertises model-a.
	registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, "http://p1.example", 20)
	// 2. Provider disconnects (the cold-start race). RemoveIfSession
	// drops seenModelsByProvider["p1"] per M2-5 / PERF-5. The model is
	// only retained via seenModelsLifetime.
	if !registry.RemoveIfSession("p1", "session-1") {
		t.Fatalf("RemoveIfSession returned false; provider was not registered as expected")
	}
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	// 3. Buyer asks for the recently-seen model. Must be 503
	// no_provider_available, NOT 404 model_not_found. Assert the full
	// OpenAI error envelope shape so SDK clients can correctly route
	// on (code, type), not just status (code-lane R1 MAJOR).
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("cold-start race status = %d, want 503; body=%s", rr.Code, rr.Body.String())
	}
	assertOpenAIErrorEnvelope(t, rr, "no_provider_available", "service_unavailable")

	// 4. A model id NEVER advertised in this coordinator's lifetime
	// still returns 404 model_not_found — the never-seen path is
	// unchanged.
	unseen := postChat(t, server, []byte(`{"model":"nonexistent-model-9000-test-only","messages":[{"role":"user","content":"hi"}]}`), nil)
	if unseen.Code != http.StatusNotFound {
		t.Fatalf("never-seen model status = %d, want 404; body=%s", unseen.Code, unseen.Body.String())
	}
	assertOpenAIErrorEnvelope(t, unseen, "model_not_found", "invalid_request_error")
}

// TestChatCompletionsDeclaredButColdModelReturns503 pins the buyer-
// visible half of SPEC-010 v1.5 R-3.3.4: a request for a model that a
// connected provider DECLARES supporting (supported_models) but is not
// currently serving (cold) must return 503 no_provider_available
// (transient/retryable — the provider may warm it), NOT 404
// model_not_found. A model that no provider declares still returns 404.
func TestChatCompletionsDeclaredButColdModelReturns503(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "http://p1.example"}})
	// Provider serves model-served but declares support for
	// model-declared-cold (it is warm-capable but not currently
	// loaded). R-3.1.4: the served model_id MUST appear in
	// supported_models, so model-served is listed too (codex code-lane
	// audit of PR #555).
	registry.Register(&pool.Provider{
		ProviderID:            "p1",
		AssignedID:            "s1",
		Hostname:              "p1.local",
		ModelID:               "model-served",
		SupportedModels:       []string{"model-served", "model-declared-cold"},
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		EndpointURL:           "http://p1.example",
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		BinaryVersion:         "0.1.0",
	}, nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	// (b) Declared-but-cold model: no provider currently serves it, but
	// it is in the seen-model union (R-3.3.4) → 503, not 404.
	cold := postChat(t, server, []byte(`{"model":"model-declared-cold","messages":[{"role":"user","content":"hello"}]}`), nil)
	if cold.Code != http.StatusServiceUnavailable {
		t.Fatalf("declared-but-cold model status = %d, want 503; body=%s", cold.Code, cold.Body.String())
	}
	assertOpenAIErrorEnvelope(t, cold, "no_provider_available", "service_unavailable")
	assertRetryableAndNoProviderBodyForwarded(t, cold, true)

	// (c) A model no provider declares stays 404 model_not_found — the
	// union must not turn genuinely-unknown models into 503.
	unknown := postChat(t, server, []byte(`{"model":"model-nobody-declares-9000","messages":[{"role":"user","content":"hi"}]}`), nil)
	if unknown.Code != http.StatusNotFound {
		t.Fatalf("undeclared model status = %d, want 404; body=%s", unknown.Code, unknown.Body.String())
	}
	assertOpenAIErrorEnvelope(t, unknown, "model_not_found", "invalid_request_error")
	assertRetryableAndNoProviderBodyForwarded(t, unknown, false)
}

// TestChatCompletionsDeclaredModelBeyondSeenIndexCapsReturns503 pins
// the buyer-visible half of the codex code-lane HIGH finding on PR
// #555: a provider whose declared catalog is wider than the seen-index
// caps (maxSeenModelsPerProvider=32 per-session,
// maxLifetimeContribPerProvider=128 per-provider lifetime) still gets
// 503 no_provider_available for a declared-but-cold model beyond those
// caps, because ModelKnown falls back to scanning the live, currently-
// connected provider's SupportedModels directly.
func TestChatCompletionsDeclaredModelBeyondSeenIndexCapsReturns503(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "http://p1.example"}})

	const totalSupported = 200
	supported := make([]string, totalSupported)
	// R-3.1.4: served model_id must appear in supported_models; this
	// duplicate entry consumes no extra seen-index budget.
	supported[0] = "model-served"
	for i := 1; i < totalSupported; i++ {
		supported[i] = fmt.Sprintf("declared-model-%03d", i)
	}
	// supported[150] is well past both the 32-entry per-session cap
	// and the 128-entry per-provider lifetime cap (see the pool-level
	// TestModelKnownFindsDeclaredModelBeyondSeenIndexCaps for the exact
	// slot accounting).
	beyondCapsModel := supported[150]

	registry.Register(&pool.Provider{
		ProviderID:            "p1",
		AssignedID:            "s1",
		Hostname:              "p1.local",
		ModelID:               "model-served",
		SupportedModels:       supported,
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		EndpointURL:           "http://p1.example",
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		LastHeartbeatAt:       time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		BinaryVersion:         "0.1.0",
	}, nil)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"`+beyondCapsModel+`","messages":[{"role":"user","content":"hello"}]}`), nil)
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("declared model beyond seen-index caps status = %d, want 503; body=%s", rr.Code, rr.Body.String())
	}
	assertOpenAIErrorEnvelope(t, rr, "no_provider_available", "service_unavailable")
	assertRetryableAndNoProviderBodyForwarded(t, rr, true)
}

// assertRetryableAndNoProviderBodyForwarded asserts error.retryable
// matches wantRetryable and that the response body is EXACTLY the
// OpenAI error envelope shape — a single top-level "error" key — so a
// provider's partial/forwarded completion payload cannot have leaked
// into the 503/404 response. Codex code-lane audit of PR #555.
func assertRetryableAndNoProviderBodyForwarded(t *testing.T, rr *httptest.ResponseRecorder, wantRetryable bool) {
	t.Helper()
	var body struct {
		Error struct {
			Retryable bool `json:"retryable"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode envelope: %v; body=%s", err, rr.Body.String())
	}
	if body.Error.Retryable != wantRetryable {
		t.Fatalf("error.retryable = %v, want %v; body=%s", body.Error.Retryable, wantRetryable, rr.Body.String())
	}
	var topLevel map[string]json.RawMessage
	if err := json.Unmarshal(rr.Body.Bytes(), &topLevel); err != nil {
		t.Fatalf("decode top-level body: %v; body=%s", err, rr.Body.String())
	}
	if len(topLevel) != 1 {
		t.Fatalf("response body has %d top-level keys, want exactly 1 (\"error\"); a provider body may have been forwarded: %s", len(topLevel), rr.Body.String())
	}
	if _, ok := topLevel["error"]; !ok {
		t.Fatalf("response body missing top-level \"error\" key: %s", rr.Body.String())
	}
}

// assertOpenAIErrorEnvelope decodes the response body and verifies
// the full OpenAI error envelope shape (error.code, error.type,
// error.message non-empty, error.param is null). Used by the cold-
// start race test to ensure OpenAI-compatible SDK clients can route
// on a structured error rather than a substring match.
func assertOpenAIErrorEnvelope(t *testing.T, rr *httptest.ResponseRecorder, wantCode, wantType string) {
	t.Helper()
	var body struct {
		Error struct {
			Code    string `json:"code"`
			Type    string `json:"type"`
			Message string `json:"message"`
			Param   any    `json:"param"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("error envelope decode failed: %v; body=%s", err, rr.Body.String())
	}
	if body.Error.Code != wantCode {
		t.Fatalf("error.code = %q, want %q; body=%s", body.Error.Code, wantCode, rr.Body.String())
	}
	if body.Error.Type != wantType {
		t.Fatalf("error.type = %q, want %q; body=%s", body.Error.Type, wantType, rr.Body.String())
	}
	if body.Error.Message == "" {
		t.Fatalf("error.message is empty; body=%s", rr.Body.String())
	}
	if body.Error.Param != nil {
		t.Fatalf("error.param = %v, want null; body=%s", body.Error.Param, rr.Body.String())
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

func registerPendingReceiptCandidate(t *testing.T, registry *pool.Registry, providerID, assignedID, modelID string) {
	t.Helper()
	_, registered, refusal := registry.RegisterAtDetailed(&pool.Provider{
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
		EndpointURL:           "https://" + providerID + ".example",
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		LastHeartbeatAt:       time.Now().UTC(),
		LastActivityAt:        time.Now().UTC(),
		ConnectedAt:           time.Now().UTC(),
		BinaryVersion:         "0.1.0",
		AuthState:             pool.AuthBearerValidated,
		ReceiptPubkey:         bytes.Repeat([]byte{0x61}, 32),
	}, nil, time.Now().UTC())
	if !registered || refusal != pool.RegisterRefusalNone {
		t.Fatalf("register pending receipt candidate: registered=%v refusal=%v", registered, refusal)
	}
	provider, ok := registry.Resolve(providerID, assignedID)
	if !ok || provider.RoutingEligible() || len(provider.PendingReceiptPubkey) == 0 {
		t.Fatalf("pending receipt candidate = %+v ok=%v; want visible but non-routable", provider, ok)
	}
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

func registerWithEndpointReceiptPubkey(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, throughput float64, receiptPubkey []byte) {
	registerWithPathConnReceiptPubkey(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, endpointURL, throughput, pool.TierPinned, pool.InferencePathHTTPForwarding, nil, receiptPubkey)
	slotsFree := slotsTotal
	registry.ApplyStateUpdate(providerID, assignedID, pool.StateUpdate{State: state, SlotsFree: &slotsFree, At: time.Now().UTC()})
}

func registerWithEndpointConn(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, throughput float64, conn net.Conn) {
	registerWithPathConn(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, endpointURL, throughput, pool.TierPinned, pool.InferencePathHTTPForwarding, conn)
}

func registerWithPath(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, throughput float64, tier pool.Tier, path pool.InferencePath) {
	registerWithPathConn(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, endpointURL, throughput, tier, path, nil)
}

func registerWithPathConn(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, throughput float64, tier pool.Tier, path pool.InferencePath, conn net.Conn) {
	registerWithPathConnReceiptPubkey(registry, providerID, assignedID, modelID, state, maxContextTokens, slotsTotal, endpointURL, throughput, tier, path, conn, nil)
}

func registerWithPathConnReceiptPubkey(registry *pool.Registry, providerID, assignedID, modelID string, state pool.State, maxContextTokens, slotsTotal int, endpointURL string, throughput float64, tier pool.Tier, path pool.InferencePath, conn net.Conn, receiptPubkey []byte) {
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
		ReceiptPubkey:         append([]byte(nil), receiptPubkey...),
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

type requestLogTestRow struct {
	ID                 int64
	RequestID          string
	ExternalRequestID  sql.NullString
	Model              string
	ProviderAssignedID sql.NullString
	PromptTokens       sql.NullInt64
	CompletionTokens   sql.NullInt64
	TTFTMs             sql.NullFloat64
	DecodeMs           sql.NullFloat64
	Status             int
	ErrorCode          sql.NullString
	Retried            int
}

type requestLogQueueWaitRow struct {
	RequestID   string
	QueueWaitMs float64
	Status      int
}

func openBuyerRequestLog(t *testing.T) (*requestlog.Store, string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open request log: %v", err)
	}
	createBuyerAuditLogForTest(t, store.DB())
	return store, dbPath
}

func createBuyerAuditLogForTest(t *testing.T, db *sql.DB) {
	t.Helper()
	if _, err := db.Exec(`
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT,
    payload_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_event_type ON audit_log(event_type);
`); err != nil {
		t.Fatalf("create audit_log: %v", err)
	}
}

func queryRequestLogRows(t *testing.T, dbPath, requestID string) []requestLogTestRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open request log db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT id, request_id, external_request_id, model, provider_assigned_id,
       prompt_tokens, completion_tokens, ttft_ms, decode_ms, status, error_code, retried
FROM request_log
WHERE request_id = ?
ORDER BY id ASC`, requestID)
	if err != nil {
		t.Fatalf("query request log: %v", err)
	}
	defer rows.Close()
	var got []requestLogTestRow
	for rows.Next() {
		var row requestLogTestRow
		if err := rows.Scan(
			&row.ID,
			&row.RequestID,
			&row.ExternalRequestID,
			&row.Model,
			&row.ProviderAssignedID,
			&row.PromptTokens,
			&row.CompletionTokens,
			&row.TTFTMs,
			&row.DecodeMs,
			&row.Status,
			&row.ErrorCode,
			&row.Retried,
		); err != nil {
			t.Fatalf("scan request log: %v", err)
		}
		got = append(got, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("request log rows: %v", err)
	}
	return got
}

func queryAllRequestLogRows(t *testing.T, dbPath string) []requestLogTestRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open request log db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT id, request_id, external_request_id, model, provider_assigned_id,
       prompt_tokens, completion_tokens, ttft_ms, decode_ms, status, error_code, retried
FROM request_log
ORDER BY id ASC`)
	if err != nil {
		t.Fatalf("query request log: %v", err)
	}
	defer rows.Close()
	var got []requestLogTestRow
	for rows.Next() {
		var row requestLogTestRow
		if err := rows.Scan(
			&row.ID,
			&row.RequestID,
			&row.ExternalRequestID,
			&row.Model,
			&row.ProviderAssignedID,
			&row.PromptTokens,
			&row.CompletionTokens,
			&row.TTFTMs,
			&row.DecodeMs,
			&row.Status,
			&row.ErrorCode,
			&row.Retried,
		); err != nil {
			t.Fatalf("scan request log: %v", err)
		}
		got = append(got, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("request log rows: %v", err)
	}
	return got
}

func queryAllRequestLogRowsWithQueueWait(t *testing.T, dbPath string) []requestLogQueueWaitRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open request log db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT request_id, queue_wait_ms, status
FROM request_log
ORDER BY id ASC`)
	if err != nil {
		t.Fatalf("query request log queue wait: %v", err)
	}
	defer rows.Close()
	var got []requestLogQueueWaitRow
	for rows.Next() {
		var row requestLogQueueWaitRow
		if err := rows.Scan(&row.RequestID, &row.QueueWaitMs, &row.Status); err != nil {
			t.Fatalf("scan request log queue wait: %v", err)
		}
		got = append(got, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("request log queue wait rows: %v", err)
	}
	return got
}

func queryBillingCredit(t *testing.T, dbPath string) (int64, int64, string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open billing db: %v", err)
	}
	defer db.Close()
	var gross, provider int64
	var fault string
	if err := db.QueryRow(`SELECT gross_credits, provider_credits, fault_flag FROM ledger_request_credits ORDER BY id DESC LIMIT 1`).Scan(&gross, &provider, &fault); err != nil {
		t.Fatalf("query billing credit: %v", err)
	}
	return gross, provider, fault
}

type billingRow struct {
	GrossCredits              int64
	CompletionTokens          int64
	EstimatedCompletionTokens int64
	UsageSource               string
	CachedPromptTokens        sql.NullInt64
	Quarantined               int
	QuarantineReason          sql.NullString
}

func queryLatestBillingRow(t *testing.T, dbPath string) billingRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open billing db: %v", err)
	}
	defer db.Close()
	var row billingRow
	if err := db.QueryRow(`
SELECT gross_credits, completion_tokens, estimated_completion_tokens, usage_source,
       cached_prompt_tokens, quarantined, quarantine_reason
FROM ledger_request_credits
ORDER BY id DESC LIMIT 1`).Scan(
		&row.GrossCredits,
		&row.CompletionTokens,
		&row.EstimatedCompletionTokens,
		&row.UsageSource,
		&row.CachedPromptTokens,
		&row.Quarantined,
		&row.QuarantineReason,
	); err != nil {
		t.Fatalf("query billing row: %v", err)
	}
	return row
}

func assertResponseCachedPromptTokens(t *testing.T, body []byte, want int64) {
	t.Helper()
	var got struct {
		Usage struct {
			CachedPromptTokens int64 `json:"cached_prompt_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("response json: %v body=%s", err, string(body))
	}
	if got.Usage.CachedPromptTokens != want {
		t.Fatalf("response cached_prompt_tokens=%d want %d body=%s", got.Usage.CachedPromptTokens, want, string(body))
	}
}

func providerByID(registry *pool.Registry, providerID string) (pool.Provider, bool) {
	for _, provider := range registry.Snapshot() {
		if provider.ProviderID == providerID {
			return provider, true
		}
	}
	return pool.Provider{}, false
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
				buyer.WithGatewayServiceToken("operator-key"),
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
		buyer.WithGatewayServiceToken("operator-key"),
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
		buyer.WithGatewayServiceToken("operator-key"),
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
		buyer.WithGatewayServiceToken("operator-key"),
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

// TestSPEC004DefaultConfigRegression is the BUILD-prompt-named alias
// for the AC-SR-1 default-preservation regression. The Pillar-
// completion checklist verifies Phase B with
// `go test -count=1 -run TestSPEC004DefaultConfigRegression ./...`,
// so the canonical byte-identity test MUST match that regex. Body
// delegates to the load-bearing
// TestDefaultConfigPreservesBaselineProviderSelection so both
// callable names remain valid (downstream code, runbooks, prior CI
// command references all continue to work).
func TestSPEC004DefaultConfigRegression(t *testing.T) {
	TestDefaultConfigPreservesBaselineProviderSelection(t)
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
			buyer.WithGatewayServiceToken("operator-key"),
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

// TestStickyAccountMismatchEmitsWarnLog — issue #266 T3e HTTP-path
// integration test for the sticky_account_mismatch warn emission
// added in T1. Pre-T3 we had a unit test on sticky.Map.Update
// confirming the boolean return, but no end-to-end coverage that
// the buyer's HTTP path actually emits the Warn through the full
// pipeline. Test sends two requests with the same conv-key but
// different X-MacProvider-Account headers and asserts:
//   - the second request emits exactly one sticky_account_mismatch
//     log row with the correct provider_id + model_scope
//   - the sticky entry's original AccountID attribution survives
//     (no account_id leak under cross-account refresh attempt)
func TestStickyAccountMismatchEmitsWarnLog(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 4, upstream.URL, 20)

	var logBuf bytes.Buffer
	server := buyer.NewServer(
		registry,
		zerolog.New(&logBuf),
		time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("operator-key"),
		buyer.WithRoutingConfig(config.RoutingConfig{
			StickyEnabled:    true,
			StickyTTLS:       1800,
			StickyMaxEntries: 10000,
		}),
	)

	// First request lands the sticky entry under acct_alice.
	h1 := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:t3e-mismatch"},
		"X-MacProvider-Account":       []string{"acct_alice"},
	}
	rr1 := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), h1)
	if rr1.Code != http.StatusOK {
		t.Fatalf("seed request: status=%d body=%s", rr1.Code, rr1.Body.String())
	}

	// Pre-mismatch baseline: the warn log should NOT yet contain
	// the mismatch event.
	if strings.Contains(logBuf.String(), `"event":"sticky_account_mismatch"`) {
		t.Fatalf("baseline: did not expect sticky_account_mismatch log yet; got %s", logBuf.String())
	}
	logBuf.Reset()

	// Second request: SAME conv-key, DIFFERENT account.
	h2 := http.Header{
		"Authorization":               []string{"Bearer operator-key"},
		"X-MacProvider-Internal-Conv": []string{"conv:t3e-mismatch"},
		"X-MacProvider-Account":       []string{"acct_mallory"},
	}
	rr2 := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), h2)
	if rr2.Code != http.StatusOK {
		t.Fatalf("mismatch request: status=%d body=%s", rr2.Code, rr2.Body.String())
	}

	// Assert exactly ONE sticky_account_mismatch warn was emitted
	// AND it carries the expected fields. The pre-T1 inline path
	// emitted on EVERY mismatch; T1 added the per-conversation-key
	// rate limiter (1/min/key) so a SINGLE warn per window is the
	// correct post-T1 shape.
	logOut := logBuf.String()
	count := strings.Count(logOut, `"event":"sticky_account_mismatch"`)
	if count != 1 {
		t.Fatalf("expected exactly 1 sticky_account_mismatch log row; got %d in %s", count, logOut)
	}
	if !strings.Contains(logOut, `"provider_id":"p1"`) {
		t.Fatalf("expected provider_id=p1 in warn; got %s", logOut)
	}
	if !strings.Contains(logOut, `"model_scope":"model-a"`) {
		t.Fatalf("expected model_scope=model-a in warn; got %s", logOut)
	}
}

// TestSPEC004DefaultConfigRegression_EmptyPool — AC-SR-1 expansion
// per issue #266 T3d. With NO providers registered, the buyer's
// upstream `pool.ModelKnown` gate fires BEFORE the smart-router
// pipeline, so the canonical envelope is 404 model_not_found with
// the invalid_request_error type. (The 503 no_provider_available
// envelope is reserved for "model exists in pool but no candidate
// passed filtering"; see the AllReadyButCapacityZero test below.)
// The test pins the contract so a future smart-router change can't
// silently mask the empty-pool case under a different status or
// error code.
func TestSPEC004DefaultConfigRegression_EmptyPool(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRoutingConfig(config.RoutingConfig{PreflightTimeoutS: 5, RequestTimeoutS: 280, FailoverTimeoutS: 5}),
	)
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
	if rr.Code != http.StatusNotFound {
		t.Fatalf("empty pool: expected 404; got %d body=%s", rr.Code, rr.Body.String())
	}
	assertOpenAIErrorEnvelope(t, rr, "model_not_found", "invalid_request_error")
}

// TestSPEC004DefaultConfigRegression_AllReadyButCapacityZero — AC-SR-1
// expansion per #266 T3d. When every advertised provider is at zero
// free slots (busy/full), the buyer envelope MUST be 503
// no_provider_available — the SPEC-002 §F-4 composition contract
// surfaces "every otherwise-eligible candidate was dropped by capacity"
// as no_provider_available, NOT a model_not_found 404. Default-config
// regression: the routing.EligibleCandidates extraction MUST preserve
// the capacity gate.
func TestSPEC004DefaultConfigRegression_AllReadyButCapacityZero(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "full1", EndpointURL: upstream.URL},
		{ProviderID: "full2", EndpointURL: upstream.URL},
	})
	// SlotsTotal=1 then immediately update to SlotsFree=0 — both
	// providers advertise model-a but neither has capacity.
	registerWithEndpoint(registry, "full1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 10)
	registerWithEndpoint(registry, "full2", "s2", "model-a", pool.StateReady, 20000, 1, upstream.URL, 30)
	zero := 0
	registry.ApplyStateUpdate("full1", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	registry.ApplyStateUpdate("full2", "s2", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})

	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRoutingConfig(config.RoutingConfig{PreflightTimeoutS: 5, RequestTimeoutS: 280, FailoverTimeoutS: 5}),
	)
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("all-capacity-zero: expected 503; got %d body=%s", rr.Code, rr.Body.String())
	}
	assertOpenAIErrorEnvelope(t, rr, "no_provider_available", "service_unavailable")
}

func TestSlotQueueWaitsForReadyProviderCapacity(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "queued", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "queued", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 10)
	zero := 0
	registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithSlotQueueConfig(4, 100*time.Millisecond, time.Millisecond),
	)

	go func() {
		time.Sleep(10 * time.Millisecond)
		one := 1
		registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
	}()

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{"X-Request-ID": []string{"queue-success"}})
	if rr.Code != http.StatusOK {
		t.Fatalf("queued request status = %d, want 200 body=%s", rr.Code, rr.Body.String())
	}
	rows := queryAllRequestLogRowsWithQueueWait(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("request_log rows = %d, want 1: %#v", len(rows), rows)
	}
	if rows[0].QueueWaitMs <= 0 {
		t.Fatalf("queue_wait_ms = %v, want > 0", rows[0].QueueWaitMs)
	}
}

func TestSlotQueueExpiresToNoProviderAvailable(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("upstream should not receive expired queued request")
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "queued", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "queued", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 10)
	zero := 0
	registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithSlotQueueConfig(4, 20*time.Millisecond, time.Millisecond),
	)

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("expired queued request status = %d, want 503 body=%s", rr.Code, rr.Body.String())
	}
	assertOpenAIErrorEnvelope(t, rr, "no_provider_available", "service_unavailable")
}

func TestSlotQueueCapRejectsFifthPendingPerProvider(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("upstream should not receive capped queued request")
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "queued", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "queued", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 10)
	zero := 0
	registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithSlotQueueConfig(4, 100*time.Millisecond, time.Millisecond),
	)

	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		go func() {
			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
			if rr.Code != http.StatusServiceUnavailable {
				errs <- fmt.Errorf("background status = %d, want 503", rr.Code)
				return
			}
			errs <- nil
		}()
	}
	time.Sleep(10 * time.Millisecond)
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("fifth queued request status = %d, want 503 body=%s", rr.Code, rr.Body.String())
	}
	assertOpenAIErrorEnvelope(t, rr, "no_provider_available", "service_unavailable")
	for i := 0; i < 4; i++ {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
}

func TestSlotQueueDoesNotWaitForDrainingProvider(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("upstream should not receive draining request")
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "draining", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "draining", "s1", "model-a", pool.StateDraining, 20000, 1, upstream.URL, 10)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithSlotQueueConfig(4, 100*time.Millisecond, time.Millisecond),
	)

	start := time.Now()
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("draining request status = %d, want 503 body=%s", rr.Code, rr.Body.String())
	}
	if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
		t.Fatalf("draining request waited %v; should reject without queue deadline", elapsed)
	}
	assertOpenAIErrorEnvelope(t, rr, "no_provider_available", "service_unavailable")
}

func TestSlotQueueDoesNotApplyToHardPinnedProvider(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("upstream should not receive pinned busy request")
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "pinned", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "pinned", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 10)
	zero := 0
	registry.ApplyStateUpdate("pinned", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithSlotQueueConfig(4, 100*time.Millisecond, time.Millisecond),
	)

	start := time.Now()
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{"X-MacProvider-Provider": []string{"pinned"}})
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("pinned busy request status = %d, want 503 body=%s", rr.Code, rr.Body.String())
	}
	if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
		t.Fatalf("pinned busy request waited %v; hard pins should not enter slot queue", elapsed)
	}
	assertOpenAIErrorEnvelope(t, rr, "no_provider_available", "service_unavailable")
}

func TestSlotQueueExitsWhenQueuedProviderStartsDraining(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("upstream should not receive queued draining request")
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "queued", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "queued", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 10)
	zero := 0
	registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithSlotQueueConfig(4, 150*time.Millisecond, time.Millisecond),
	)
	go func() {
		time.Sleep(10 * time.Millisecond)
		registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateDraining, At: time.Now().UTC()})
	}()

	start := time.Now()
	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("queued draining request status = %d, want 503 body=%s", rr.Code, rr.Body.String())
	}
	if elapsed := time.Since(start); elapsed > 75*time.Millisecond {
		t.Fatalf("queued draining request waited %v; should exit before queue deadline", elapsed)
	}
	assertOpenAIErrorEnvelope(t, rr, "no_provider_available", "service_unavailable")
}

func TestSlotQueueFallsThroughAfterQueuedPreflightReject(t *testing.T) {
	p1Upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("preflight-rejected provider should not receive request")
	}))
	defer p1Upstream.Close()
	p2Upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer p2Upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "p1", EndpointURL: p1Upstream.URL},
		{ProviderID: "p2", EndpointURL: p2Upstream.URL},
	})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, p1Upstream.URL, 10)
	registerWithEndpoint(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, p2Upstream.URL, 20)
	zero := 0
	registry.ApplyStateUpdate("p1", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	registry.ApplyStateUpdate("p2", "s2", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithSlotQueueConfig(4, 300*time.Millisecond, time.Millisecond),
		buyer.WithPreflightConfig(1, 300*time.Millisecond),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			if provider.ProviderID == "p1" {
				time.Sleep(120 * time.Millisecond)
				return buyer.PreflightResult{Accepted: false, Reason: "queue_full"}, true, nil
			}
			return buyer.PreflightResult{Accepted: true}, true, nil
		}),
	)
	go func() {
		time.Sleep(10 * time.Millisecond)
		one := 1
		registry.ApplyStateUpdate("p1", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
		registry.ApplyStateUpdate("p2", "s2", pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
	}()

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
	if rr.Code != http.StatusOK {
		t.Fatalf("queued preflight fallback status = %d, want 200 body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "p2" {
		t.Fatalf("provider header = %q, want p2", rr.Header().Get("X-MacProvider-Provider"))
	}
	rows := queryAllRequestLogRowsWithQueueWait(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("request_log rows = %d, want 1: %#v", len(rows), rows)
	}
	if rows[0].QueueWaitMs <= 0 {
		t.Fatalf("queue_wait_ms = %v, want > 0", rows[0].QueueWaitMs)
	}
	if rows[0].QueueWaitMs >= 80 {
		t.Fatalf("queue_wait_ms = %v, want queue wait excluding rejected provider preflight latency", rows[0].QueueWaitMs)
	}
}

func TestSlotQueueWaitExcludesPreflightLatency(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "queued", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "queued", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 10)
	zero := 0
	registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithSlotQueueConfig(4, 300*time.Millisecond, time.Millisecond),
		buyer.WithPreflightConfig(1, 250*time.Millisecond),
		buyer.WithPreflight(func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (buyer.PreflightResult, bool, error) {
			time.Sleep(120 * time.Millisecond)
			return buyer.PreflightResult{Accepted: true}, true, nil
		}),
	)
	go func() {
		time.Sleep(10 * time.Millisecond)
		one := 1
		registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
	}()

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{"X-Request-ID": []string{"queue-preflight"}})
	if rr.Code != http.StatusOK {
		t.Fatalf("queued request status = %d, want 200 body=%s", rr.Code, rr.Body.String())
	}
	rows := queryAllRequestLogRowsWithQueueWait(t, dbPath)
	if len(rows) != 1 {
		t.Fatalf("request_log rows = %d, want 1: %#v", len(rows), rows)
	}
	if rows[0].QueueWaitMs <= 0 {
		t.Fatalf("queue_wait_ms = %v, want > 0", rows[0].QueueWaitMs)
	}
	if rows[0].QueueWaitMs >= 80 {
		t.Fatalf("queue_wait_ms = %v, want slot wait without 120ms preflight latency", rows[0].QueueWaitMs)
	}
}

func TestSlotQueueReservationPreventsSingleSlotOverDispatch(t *testing.T) {
	hits := make(chan struct{}, 4)
	release := make(chan struct{}, 4)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits <- struct{}{}
		<-release
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "queued", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "queued", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 10)
	zero := 0
	registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithSlotQueueConfig(4, 250*time.Millisecond, time.Millisecond),
	)

	errs := make(chan error, 3)
	startRequest := func() {
		go func() {
			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
			if rr.Code != http.StatusOK && rr.Code != http.StatusServiceUnavailable {
				errs <- fmt.Errorf("status = %d body=%s", rr.Code, rr.Body.String())
				return
			}
			errs <- nil
		}()
	}
	startRequest()
	startRequest()
	time.Sleep(10 * time.Millisecond)
	one := 1
	registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
	select {
	case <-hits:
	case <-time.After(75 * time.Millisecond):
		t.Fatal("first queued request did not dispatch after slot recovery")
	}
	startRequest()
	select {
	case <-hits:
		t.Fatal("another request dispatched while the single recovered slot was reserved")
	case <-time.After(25 * time.Millisecond):
	}
	release <- struct{}{}
	release <- struct{}{}
	release <- struct{}{}
	for i := 0; i < 3; i++ {
		select {
		case err := <-errs:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(500 * time.Millisecond):
			t.Fatal("request did not complete")
		}
	}
}

func TestSlotQueueReservationBlocksPinnedOverDispatch(t *testing.T) {
	hits := make(chan struct{}, 2)
	release := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits <- struct{}{}
		<-release
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "queued", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "queued", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 10)
	zero := 0
	registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithSlotQueueConfig(4, 250*time.Millisecond, time.Millisecond),
	)

	queuedDone := make(chan int, 1)
	go func() {
		rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{})
		queuedDone <- rr.Code
	}()
	time.Sleep(10 * time.Millisecond)
	one := 1
	registry.ApplyStateUpdate("queued", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
	select {
	case <-hits:
	case <-time.After(75 * time.Millisecond):
		t.Fatal("queued request did not dispatch after slot recovery")
	}

	pinned := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{"X-MacProvider-Provider": []string{"queued"}})
	if pinned.Code != http.StatusServiceUnavailable {
		t.Fatalf("pinned status = %d, want 503 while queued reservation owns only free slot; body=%s", pinned.Code, pinned.Body.String())
	}
	assertOpenAIErrorEnvelope(t, pinned, "no_provider_available", "service_unavailable")
	select {
	case <-hits:
		t.Fatal("pinned request dispatched while queued reservation owned the only free slot")
	default:
	}

	release <- struct{}{}
	select {
	case status := <-queuedDone:
		if status != http.StatusOK {
			t.Fatalf("queued status = %d, want 200", status)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("queued request did not finish")
	}
}

func TestSlotQueueBurstSweepAvoidsBuyerVisible503(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	providers := make([]config.ProviderConfig, 0, 8)
	for i := 0; i < 8; i++ {
		providers = append(providers, config.ProviderConfig{ProviderID: fmt.Sprintf("p%d", i), EndpointURL: upstream.URL})
	}
	registry := pool.NewRegistry(providers)
	zero := 0
	for i := 0; i < 8; i++ {
		providerID := fmt.Sprintf("p%d", i)
		assignedID := fmt.Sprintf("s%d", i)
		registerWithEndpoint(registry, providerID, assignedID, "model-a", pool.StateReady, 20000, 1, upstream.URL, float64(10+i))
		registry.ApplyStateUpdate(providerID, assignedID, pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	}
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithSlotQueueConfig(4, 750*time.Millisecond, time.Millisecond),
	)

	const requests = 30
	results := make(chan int, requests)
	started := make(chan struct{}, requests)
	for i := 0; i < requests; i++ {
		i := i
		go func() {
			started <- struct{}{}
			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{"X-Request-ID": []string{fmt.Sprintf("queue-burst-%02d", i)}})
			results <- rr.Code
		}()
	}
	for i := 0; i < requests; i++ {
		<-started
	}
	time.Sleep(10 * time.Millisecond)
	one := 1
	for i := 0; i < 8; i++ {
		registry.ApplyStateUpdate(fmt.Sprintf("p%d", i), fmt.Sprintf("s%d", i), pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
	}
	for i := 0; i < requests; i++ {
		select {
		case status := <-results:
			if status != http.StatusOK {
				t.Fatalf("burst request %d status = %d, want 200", i, status)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for burst request")
		}
	}
	rows := queryAllRequestLogRowsWithQueueWait(t, dbPath)
	if len(rows) != requests {
		t.Fatalf("request_log rows = %d, want %d", len(rows), requests)
	}
	waits := make([]float64, 0, len(rows))
	for _, row := range rows {
		if row.Status != http.StatusOK {
			t.Fatalf("request_log status = %d, want 200 for row %#v", row.Status, row)
		}
		waits = append(waits, row.QueueWaitMs)
	}
	sort.Float64s(waits)
	p95 := waits[int(math.Ceil(float64(len(waits))*0.95))-1]
	if p95 >= 400 {
		t.Fatalf("queue_wait_ms p95 = %.1f, want < 400; waits=%v", p95, waits)
	}
}

func TestSlotQueueAppliesToHTTPRetryReplacementProvider(t *testing.T) {
	failUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}))
	defer failUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "fail", EndpointURL: failUpstream.URL},
		{ProviderID: "queued", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "fail", "s1", "model-a", pool.StateReady, 20000, 1, failUpstream.URL, 30)
	registerWithEndpoint(registry, "queued", "s2", "model-a", pool.StateReady, 20000, 1, okUpstream.URL, 20)
	zero := 0
	registry.ApplyStateUpdate("queued", "s2", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{MaxRetries: 1, RetryPerAttemptTimeoutS: 1}),
		buyer.WithSlotQueueConfig(4, 100*time.Millisecond, time.Millisecond),
	)
	go func() {
		time.Sleep(10 * time.Millisecond)
		one := 1
		registry.ApplyStateUpdate("queued", "s2", pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
	}()

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{"X-MacProvider-Retry": []string{"1"}})
	if rr.Code != http.StatusOK {
		t.Fatalf("retry queued request status = %d, want 200 body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("X-MacProvider-Provider") != "queued" {
		t.Fatalf("provider header = %q, want queued", rr.Header().Get("X-MacProvider-Provider"))
	}
	rows := queryAllRequestLogRowsWithQueueWait(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2: %#v", len(rows), rows)
	}
	if rows[0].QueueWaitMs != 0 {
		t.Fatalf("failed attempt queue_wait_ms = %v, want 0", rows[0].QueueWaitMs)
	}
	if rows[1].QueueWaitMs <= 0 || rows[1].Status != http.StatusOK {
		t.Fatalf("replacement row = %#v, want success with queue_wait_ms > 0", rows[1])
	}
}

func TestSlotQueueWaitDoesNotCarryIntoImmediateRetryAttempt(t *testing.T) {
	var registry *pool.Registry
	failUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		one := 1
		registry.ApplyStateUpdate("ok", "s2", pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}))
	defer failUpstream.Close()
	okUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer okUpstream.Close()

	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry = pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "queued-fail", EndpointURL: failUpstream.URL},
		{ProviderID: "ok", EndpointURL: okUpstream.URL},
	})
	registerWithEndpoint(registry, "queued-fail", "s1", "model-a", pool.StateReady, 20000, 1, failUpstream.URL, 30)
	registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateDraining, 20000, 1, okUpstream.URL, 20)
	zero := 0
	registry.ApplyStateUpdate("queued-fail", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithRoutingConfig(config.RoutingConfig{MaxRetries: 1, RetryPerAttemptTimeoutS: 1}),
		buyer.WithSlotQueueConfig(4, 120*time.Millisecond, time.Millisecond),
	)
	go func() {
		time.Sleep(10 * time.Millisecond)
		one := 1
		registry.ApplyStateUpdate("queued-fail", "s1", pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
	}()

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{"X-MacProvider-Retry": []string{"1"}})
	if rr.Code != http.StatusOK {
		t.Fatalf("retry request status = %d, want 200 body=%s", rr.Code, rr.Body.String())
	}
	rows := queryAllRequestLogRowsWithQueueWait(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2: %#v", len(rows), rows)
	}
	if rows[0].QueueWaitMs <= 0 {
		t.Fatalf("queued failing row queue_wait_ms = %v, want > 0", rows[0].QueueWaitMs)
	}
	if rows[1].QueueWaitMs != 0 || rows[1].Status != http.StatusOK {
		t.Fatalf("immediate retry row = %#v, want success with queue_wait_ms 0", rows[1])
	}
}

func TestSlotQueueAppliesToWSFailoverReplacementProvider(t *testing.T) {
	const requestID = "33333333-3333-4333-8333-333333333333"
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	registry := pool.NewRegistry(nil)
	registerWithPath(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, "", 30, pool.TierProvisional, pool.InferencePathWSTunneled)
	registerWithPath(registry, "p2", "s2", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
	zero := 0
	registry.ApplyStateUpdate("p2", "s2", pool.StateUpdate{State: pool.StateReady, SlotsFree: &zero, At: time.Now().UTC()})
	var calls []string
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithFailoverConfig(true, 50*time.Millisecond),
		buyer.WithSlotQueueConfig(4, 120*time.Millisecond, time.Millisecond),
		buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
			calls = append(calls, provider.ProviderID)
			chunks := make(chan providerws.InferenceResponseChunk, 1)
			done := make(chan providerws.InferenceResponseEnd, 1)
			errs := make(chan error, 1)
			if provider.ProviderID == "p1" {
				errs <- providerws.ErrRelayClosed
				return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
			}
			chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"failover","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`}
			done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
			return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
		}, time.Second),
	)
	go func() {
		time.Sleep(10 * time.Millisecond)
		one := 1
		registry.ApplyStateUpdate("p2", "s2", pool.StateUpdate{State: pool.StateReady, SlotsFree: &one, At: time.Now().UTC()})
	}()

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), http.Header{"X-Request-ID": []string{requestID}})
	if rr.Code != http.StatusOK {
		t.Fatalf("failover queued request status = %d, want 200 body=%s", rr.Code, rr.Body.String())
	}
	if strings.Join(calls, ",") != "p1,p2" {
		t.Fatalf("relay calls = %v, want p1,p2", calls)
	}
	rows := queryAllRequestLogRowsWithQueueWait(t, dbPath)
	if len(rows) != 2 {
		t.Fatalf("request_log rows = %d, want 2: %#v", len(rows), rows)
	}
	if rows[0].QueueWaitMs != 0 {
		t.Fatalf("failed failover source row queue_wait_ms = %v, want 0", rows[0].QueueWaitMs)
	}
	if rows[1].QueueWaitMs <= 0 || rows[1].Status != http.StatusOK {
		t.Fatalf("failover target row = %#v, want success with queue_wait_ms > 0", rows[1])
	}
}

// TestSPEC004DefaultConfigRegression_ContextTooSmall — AC-SR-1
// expansion per #266 T3d. When every candidate's MaxContextTokens
// is strictly less than the request estimated tokens, the buyer
// MUST surface 413 context_exceeds_capacity. Pre-T2 buyer
// dispatch enforced this; the routing.EligibleCandidates extraction
// MUST preserve it through the sort + tiebreak path.
func TestSPEC004DefaultConfigRegression_ContextTooSmall(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "tiny", EndpointURL: upstream.URL}})
	// Tiny max-context: 16 tokens is below the buyer's request estimate.
	registerWithEndpoint(registry, "tiny", "s1", "model-a", pool.StateReady, 16, 1, upstream.URL, 10)
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRoutingConfig(config.RoutingConfig{PreflightTimeoutS: 5, RequestTimeoutS: 280, FailoverTimeoutS: 5}),
	)
	// Craft a prompt large enough to exceed 16 tokens with margin.
	longPrompt := strings.Repeat("the quick brown fox jumps over the lazy dog ", 80)
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"` + longPrompt + `"}]}`)
	rr := postChat(t, server, body, http.Header{})
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("context-too-small: expected 413; got %d body=%s", rr.Code, rr.Body.String())
	}
	assertOpenAIErrorEnvelope(t, rr, "context_exceeds_capacity", "invalid_request_error")
}

// registerBearerlessDuplicate registers a provider in the AuthBearerlessDuplicate
// state — slot-holding, StateReady, but never routable per
// pool.Provider.RoutingEligible(). Mirrors the v1.2.5 bearer-less reconnect case
// that v0.8.3 admits and quarantines.
func registerBearerlessDuplicate(registry *pool.Registry, providerID, assignedID, modelID, endpointURL string) {
	registerAuthState(registry, providerID, assignedID, modelID, endpointURL, pool.AuthBearerlessDuplicate)
}

func registerAuthState(registry *pool.Registry, providerID, assignedID, modelID, endpointURL string, authState pool.AuthState) {
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
		AuthState:             authState,
	}, nil)
}

// TestChatCompletionsExcludesAuthBearerlessDuplicate verifies that a provider in
// AuthBearerlessDuplicate state is NEVER routable, even though it holds a slot
// and reports StateReady. Regression for fix-pass-4: the buyer routing path must
// delegate to pool.Provider.RoutingEligible() — the single authority —
// rather than a local slot/state-only predicate.
func TestChatCompletionsExcludesAuthBearerlessDuplicate(t *testing.T) {
	upstreamHit := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamHit = true
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"id":"ok"}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerBearerlessDuplicate(registry, "p1", "session-1", "model-a", upstream.URL)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"stream":false}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503; body=%s", rr.Code, rr.Body.String())
	}
	if upstreamHit {
		t.Fatalf("upstream MUST NOT be invoked for AuthBearerlessDuplicate provider — billing identity would accrue under unauthenticated provider_id")
	}
	if got := rr.Header().Get("X-MacProvider-Provider"); got != "" {
		t.Fatalf("X-MacProvider-Provider = %q, want empty (no candidate)", got)
	}
}

// TestChatCompletionsPinnedHeaderRejectsAuthBearerlessDuplicate verifies the
// hard-pin path (X-MacProvider-Provider header) also rejects bearer-less
// duplicates. Fix-pass-4 target site: validatePinnedProviderForRequest.
func TestChatCompletionsPinnedHeaderRejectsAuthBearerlessDuplicate(t *testing.T) {
	upstreamHit := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamHit = true
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"id":"ok"}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerBearerlessDuplicate(registry, "p1", "session-1", "model-a", upstream.URL)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"stream":false}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("X-MacProvider-Provider", "p1")
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("pinned status = %d, want 503; body=%s", rr.Code, rr.Body.String())
	}
	if upstreamHit {
		t.Fatalf("pinned upstream MUST NOT be invoked for AuthBearerlessDuplicate provider")
	}
}

// TestModelsExcludesAuthBearerlessDuplicateFromCapacity verifies the
// /v1/models surface does not advertise capacity (provider count, total slots)
// from bearer-less duplicates. They hold slots but must not be reflected in
// publicly-advertised network capacity.
func TestModelsExcludesAuthBearerlessDuplicateFromCapacity(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "good", EndpointURL: "https://good.example"},
		{ProviderID: "bad", EndpointURL: "https://bad.example"},
	})
	// One Bearer-validated provider (counted) + one bearer-less duplicate (excluded).
	register(registry, "good", "session-good", "model-a", pool.StateReady, 20000, 1)
	registerBearerlessDuplicate(registry, "bad", "session-bad", "model-a", "https://bad.example")

	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Data []struct {
			ID            string `json:"id"`
			ProviderCount int    `json:"provider_count"`
			TotalSlots    int    `json:"total_slots"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("json: %v", err)
	}
	var modelA struct {
		ProviderCount int
		TotalSlots    int
		found         bool
	}
	for _, m := range resp.Data {
		if m.ID == "model-a" {
			modelA.ProviderCount = m.ProviderCount
			modelA.TotalSlots = m.TotalSlots
			modelA.found = true
		}
	}
	if !modelA.found {
		t.Fatalf("model-a not in response; body=%s", rr.Body.String())
	}
	if modelA.ProviderCount != 1 {
		t.Fatalf("provider_count = %d, want 1 (good only; bad is AuthBearerlessDuplicate)", modelA.ProviderCount)
	}
	if modelA.TotalSlots != 1 {
		t.Fatalf("total_slots = %d, want 1 (good only)", modelA.TotalSlots)
	}
}

func TestModelsExcludesAuthSelfMintedFromCapacity(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{
		{ProviderID: "good", EndpointURL: "https://good.example"},
		{ProviderID: "bad", EndpointURL: "https://bad.example"},
	})
	register(registry, "good", "session-good", "model-a", pool.StateReady, 20000, 1)
	registerAuthState(registry, "bad", "session-bad", "model-a", "https://bad.example", pool.AuthSelfMinted)

	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Data []struct {
			ID            string `json:"id"`
			ProviderCount int    `json:"provider_count"`
			TotalSlots    int    `json:"total_slots"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("json: %v", err)
	}
	for _, m := range resp.Data {
		if m.ID == "model-a" {
			if m.ProviderCount != 1 {
				t.Fatalf("provider_count = %d, want 1 (good only; self-minted excluded)", m.ProviderCount)
			}
			if m.TotalSlots != 1 {
				t.Fatalf("total_slots = %d, want 1 (good only; self-minted excluded)", m.TotalSlots)
			}
			return
		}
	}
	t.Fatalf("model-a not in response; body=%s", rr.Body.String())
}

func TestModelsExcludesPendingReceiptCandidateFromCapacity(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "pending", EndpointURL: "https://pending.example"}})
	registerPendingReceiptCandidate(t, registry, "pending", "session-pending", "model-a")

	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("json: %v", err)
	}
	for _, m := range resp.Data {
		if m.ID == "model-a" {
			t.Fatalf("pending receipt candidate must not be advertised as model capacity; body=%s", rr.Body.String())
		}
	}
}

// Round-1 audit H2: receipt header MUST be capped at 4096 ASCII bytes
// and contain no CR/LF/NUL. A misbehaving provider that emits a 1 MB
// header would otherwise punch through nginx's 8 KiB upstream limit and
// turn into a 502 at the gateway. The coordinator now strips oversize
// or non-ASCII values before forwarding.
func TestHTTPForwardingStripsOversizedReceiptHeader(t *testing.T) {
	oversized := strings.Repeat("A", 4097) + "." + strings.Repeat("B", 32)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-MacProvider-Receipt", oversized)
		_, _ = w.Write([]byte(`{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpointReceiptPubkey(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20, bytes.Repeat([]byte{0x63}, 32))
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`), nil)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("receipt header = %q, want stripped for oversized value", got)
	}
}

func TestHTTPForwardingStripsReceiptHeaderWithNonPrintableBytes(t *testing.T) {
	// Note: Go's net/http normalizes CR/LF to spaces on the upstream
	// response before we see it, so smuggling-style CRLF injection is
	// already defended at the transport layer. The cases below cover
	// the bytes that DO reach the coordinator unchanged: NUL and
	// non-ASCII bytes (multi-byte UTF-8). normalizeReceiptHeaderValue
	// must strip both.
	cases := []struct {
		name string
		body string
	}{
		{"nul", "good\x00bad"},
		{"non_ascii", "good\xc3\xa9bad"},
		{"del", "good\x7fbad"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := tc.body
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("X-MacProvider-Receipt", body)
				_, _ = w.Write([]byte(`{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
			}))
			defer upstream.Close()

			registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
			registerWithEndpointReceiptPubkey(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20, bytes.Repeat([]byte{0x64}, 32))
			server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":false}`), nil)

			if got := rr.Header().Get("X-MacProvider-Receipt"); got != "" {
				t.Fatalf("receipt header = %q, want stripped for non-printable bytes (%s)", got, tc.name)
			}
		})
	}
}
