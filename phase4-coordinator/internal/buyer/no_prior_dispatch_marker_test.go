package buyer_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// noPriorDispatchMarkerHeader is the literal item-18 POSITIVE no-charge marker
// (unexported settlementNoPriorDispatchHeader in package buyer). Duplicated here
// because this is the external buyer_test package.
const noPriorDispatchMarkerHeader = "X-MacProvider-Settlement-No-Prior-Dispatch"

// TestNoPriorDispatchMarkerReflectsRealDispatch is the real-server counterpart
// to the fabricated-header gateway tests: it drives the actual coordinator so
// the marker is stamped by the live billingRecorder + noPriorDispatchResponseWriter
// rather than a hand-set header. It pins the two dispatch outcomes over the HTTP
// transport (registerWithEndpoint selects HTTP forwarding, which bills its
// terminal row before the write):
//
//   - a dispatched provider that terminates 502 (provider_failed) leaves the
//     response UNMARKED (dispatchedThisAttempt set before the relay), so a
//     retried route_snapshot_failed does not refund away a real provider credit.
//   - a pre-dispatch routing failure (no provider available) never dispatches,
//     so the response IS marked and the gateway refunds correctly.
//
// NOTE: this does not exercise the WS-tunneled write-before-bill ordering (where
// the billing row is recorded after the terminal write); that path's marker
// behavior is pinned by the unit-level TestNoPriorDispatchResponseWriterMarks,
// and the outward-wire-status vs ledger-status divergence on the streaming/WS
// write-before-bill paths is a documented carried limitation (SPEC-006 §17.7).
func TestNoPriorDispatchMarkerReflectsRealDispatch(t *testing.T) {
	t.Run("dispatched_provider_502_is_unmarked", func(t *testing.T) {
		var calls int
		failing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls++
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte(`{"error":{"message":"boom","type":"upstream_provider_error"}}`))
		}))
		defer failing.Close()

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
		registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "fail", EndpointURL: failing.URL}})
		registerWithEndpoint(registry, "fail", "s1", "model-a", pool.StateReady, 20000, 1, failing.URL, 10)
		server := buyer.NewServer(
			registry,
			zerolog.Nop(),
			time.Unix(1716768000, 0),
			buyer.WithRequestLog(reqLog),
			buyer.WithBilling(billingStore, rewards),
			buyer.WithRoutingConfig(config.RoutingConfig{MaxRetries: 0, StickyTTLS: 1800, StickyMaxEntries: 10000}),
		)

		rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
			"X-MacProvider-Provider": []string{"fail"},
		})

		if rr.Code != http.StatusBadGateway {
			t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
		}
		if calls != 1 {
			t.Fatalf("provider calls=%d, want 1 (provider was dispatched)", calls)
		}
		// The dispatched provider was billed (a request_log row exists), so the
		// terminal 502 MUST NOT carry the no-charge marker.
		rows := queryAllRequestLogRows(t, dbPath)
		if len(rows) != 1 {
			t.Fatalf("request_log rows=%d want 1 (provider dispatched+recorded): %#v", len(rows), rows)
		}
		if got := rr.Header().Get(noPriorDispatchMarkerHeader); got != "" {
			t.Fatalf("dispatched-provider 502 carried the no-charge marker %q; a retried route_snapshot_failed would refund away real provider credit", got)
		}
	})

	t.Run("pre_dispatch_no_provider_is_marked", func(t *testing.T) {
		reqLog, _ := openBuyerRequestLog(t)
		defer reqLog.Close()
		billingStore, err := billing.NewStore(reqLog.DB())
		if err != nil {
			t.Fatalf("billing.NewStore: %v", err)
		}
		setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
		rewards := config.RewardsConfig{
			GlobalMultiplier: 1.0,
			ProviderShare:    0.90,
			RateCard:         map[string]config.RateCardEntry{"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000}},
		}
		// No provider registered for model-a → routing fails before any dispatch.
		registry := pool.NewRegistry(nil)
		server := buyer.NewServer(
			registry,
			zerolog.Nop(),
			time.Unix(1716768000, 0),
			buyer.WithRequestLog(reqLog),
			buyer.WithBilling(billingStore, rewards),
			buyer.WithRoutingConfig(config.RoutingConfig{MaxRetries: 0}),
		)

		rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{})

		if rr.Code == http.StatusOK {
			t.Fatalf("expected a routing failure, got 200: %s", rr.Body.String())
		}
		if got := rr.Header().Get(noPriorDispatchMarkerHeader); got == "" {
			t.Fatalf("pre-dispatch routing failure (status=%d) must carry the no-charge marker so the gateway refunds", rr.Code)
		}
	})
}
