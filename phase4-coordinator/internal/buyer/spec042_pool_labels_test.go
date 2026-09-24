package buyer_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	"github.com/rs/zerolog"
)

type spec042LabelHarness struct {
	server        *buyer.Server
	dbPath        string
	providerCalls *atomic.Int64
	poolID        string
	body          []byte
}

func newSpec042LabelHarness(t *testing.T, launchEnvironment string, productionCoordinator bool) spec042LabelHarness {
	t.Helper()
	configureRouteSnapshotCatalog(t, "trusted-pool-labels-catalog")
	reqLog, dbPath := openBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
	rewards := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), rewards, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}
	calls := &atomic.Int64{}
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		writeProviderOK(w)
	}))
	t.Cleanup(provider.Close)
	const (
		buyerAccountID = "acct_gateway"
		providerID     = "provider-member"
	)
	poolID := trustedPoolLayer2CandidateManifest(t).PoolID
	providerRegistry := pool.NewRegistry(nil)
	registerTrustedPoolLayer2Provider(providerRegistry, providerID, "session-member", provider.URL, []byte(strings.Repeat("r", 32)))
	trustPools := trustpool.NewRegistry()
	loadTrustedPoolLayer2Snapshot(t, trustPools, 1, trustpool.RouteableSnapshot{
		PoolID:             poolID,
		Members:            []string{providerID},
		BuyerAccounts:      []string{buyerAccountID},
		SettlementMode:     billing.RouteSnapshotModeObserve,
		Routeable:          true,
		Generation:         7,
		RouteableUntilUTC:  time.Now().UTC().Add(time.Hour),
		ManifestVersion:    5,
		ManifestCoreDigest: strings.Repeat("d", 64),
		LaunchEnvironment:  launchEnvironment,
	})
	if productionCoordinator {
		trustPools.RejectCandidateLaunchEnvironment()
	}
	server := buyer.NewServer(
		providerRegistry,
		zerolog.Nop(),
		time.Unix(1716768000, 0).UTC(),
		buyer.WithGatewayServiceToken("gateway-secret"),
		buyer.WithRequireGatewayContext(true),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithPoolMembership(trustPools),
		buyer.WithTrustPoolStatusStore(openBuyerTrustPoolStore(t)),
		buyer.WithRoutingConfig(config.RoutingConfig{MaxRetries: 0}),
	)
	return spec042LabelHarness{
		server:        server,
		dbPath:        dbPath,
		providerCalls: calls,
		poolID:        poolID,
		body:          []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`),
	}
}

func TestSPEC042RouteSnapshotCarriesRoutingTimeManifestLabels(t *testing.T) {
	h := newSpec042LabelHarness(t, "production", false)
	rec := postChat(t, h.server, h.body, trustedPoolLayer2Headers("acct_gateway", h.poolID))
	if rec.Code != http.StatusOK {
		t.Fatalf("pooled request status=%d body=%s", rec.Code, rec.Body.String())
	}
	db, err := sql.Open("sqlite", h.dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var raw, digest string
	if err := db.QueryRow(`SELECT route_snapshot_json, route_snapshot_digest FROM settlement_route_snapshots`).Scan(&raw, &digest); err != nil {
		t.Fatalf("query route snapshot: %v", err)
	}
	var got struct {
		PoolID             string `json:"pool_id"`
		ManifestVersion    uint64 `json:"manifest_version"`
		ManifestCoreDigest string `json:"manifest_core_digest"`
	}
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("decode route snapshot json: %v", err)
	}
	if got.PoolID != h.poolID || got.ManifestVersion != 5 || got.ManifestCoreDigest != strings.Repeat("d", 64) || len(digest) != 64 {
		t.Fatalf("route snapshot labels=%+v digest=%q, want pool %s manifest 5/%s", got, digest, h.poolID, strings.Repeat("d", 64))
	}
}

func TestSPEC042CandidateRootFailsClosedOnProductionCoordinator(t *testing.T) {
	h := newSpec042LabelHarness(t, "candidate", true)
	rec := postChat(t, h.server, h.body, trustedPoolLayer2Headers("acct_gateway", h.poolID))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("candidate pool status=%d body=%s, want 503", rec.Code, rec.Body.String())
	}
	if code := trustedPoolLayer2ErrorCode(t, rec.Body.String()); code != "pool_unavailable" {
		t.Fatalf("candidate pool code=%q, want pool_unavailable", code)
	}
	if h.providerCalls.Load() != 0 {
		t.Fatalf("provider calls=%d, want 0", h.providerCalls.Load())
	}
}

func TestSPEC042CandidateRootStillRoutesOffProductionCoordinator(t *testing.T) {
	h := newSpec042LabelHarness(t, "candidate", false)
	rec := postChat(t, h.server, h.body, trustedPoolLayer2Headers("acct_gateway", h.poolID))
	if rec.Code != http.StatusOK {
		t.Fatalf("candidate pool on non-production coordinator status=%d body=%s, want 200", rec.Code, rec.Body.String())
	}
}
