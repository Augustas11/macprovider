package buyer_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// #1248 old-client compatibility, buyer side. A pre-BYOM provider carries no
// SPEC-047 admission fields (registerSettlementProvider is exactly that shape).
// With the admission store wired into the buyer server, such a provider must
// still be listed in /v1/models and routed by default paid routing exactly as
// before, and must still settle: BYOM gating may not capture non-BYOM supply.
func TestPreBYOMProviderStaysListedAndRoutableWithModelAdmissionStoreWired(t *testing.T) {
	tier2.ResetForTest()
	t.Cleanup(tier2.ResetForTest)
	raw, pubkey := routeSnapshotCatalogFixture(t, "pre-byom-compat-catalog", time.Now().UTC().Add(time.Hour))
	if err := tier2.Configure(config.Tier2Config{
		ObserveEnabled:      true,
		CatalogPath:         writeRouteSnapshotCatalog(t, raw),
		CatalogPublicKey:    pubkey,
		RequireHashVerified: true,
	}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}

	reqLog, dbPath := openBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeEnforce)
	cfg := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), cfg, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	var reachedProvider bool
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reachedProvider = true
		writeProviderOK(w)
	}))
	defer upstream.Close()

	registry := pool.NewRegistry(nil)
	registerSettlementProvider(registry, "p1", "session-1", upstream.URL, 30, bytes.Repeat([]byte{0x78}, 32))
	provider := registry.Snapshot()[0]
	if provider.ModelAdmissionCandidateID != "" || provider.ModelAdmissionServedModelRef != "" {
		t.Fatalf("fixture is not a pre-BYOM provider: %+v", provider)
	}

	// The admission store is wired and empty, exactly as a coordinator that
	// has been upgraded to BYOM but whose fleet has not.
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, cfg),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithModelAdmissionStore(providerws.NewMemoryModelAdmissionStore()),
	)

	modelsRR := httptest.NewRecorder()
	server.Handler().ServeHTTP(modelsRR, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	if modelsRR.Code != http.StatusOK {
		t.Fatalf("models status=%d body=%s", modelsRR.Code, modelsRR.Body.String())
	}
	var models struct {
		Data []map[string]any `json:"data"`
	}
	if err := json.Unmarshal(modelsRR.Body.Bytes(), &models); err != nil {
		t.Fatalf("models json: %v", err)
	}
	var listed bool
	for _, row := range models.Data {
		if row["id"] == "model-a" {
			listed = true
		}
	}
	if !listed {
		t.Fatalf("pre-BYOM provider vanished from /v1/models: %s", modelsRR.Body.String())
	}

	rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s, want the pre-BYOM provider to serve", rr.Code, rr.Body.String())
	}
	if !reachedProvider {
		t.Fatal("pre-BYOM provider was not reached by default paid routing")
	}
	if got := routeSnapshotCount(t, dbPath); got == 0 {
		t.Fatal("pre-BYOM provider produced no route snapshot; BYOM gating captured non-BYOM supply")
	}
}
