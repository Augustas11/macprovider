package buyer_test

import (
	"net/http"
	"strings"
	"testing"
)

// routeSnapshotV2CapabilityHeader is the request header a gateway sends when
// it settles SPEC-015 §N.2 route_snapshot_v2 finality
// (settlement_trailers.go).
const routeSnapshotV2CapabilityHeader = "X-MacProvider-Internal-Settlement-Route-Snapshot-V2"

// #1816 VM A-1: a pool-model attempt is pinned to route_snapshot_v2, which a
// pre-#1816 gateway does not know: it delivered the 200, held the buyer with
// invalid_settlement_policy_version and never debited, while the provider
// credit was payable. A gateway that did not negotiate v2 is refused before
// dispatch: 503, no route snapshot, no provider call, no ledger row.
func TestSPEC1816PoolModelRefusesGatewayWithoutRouteSnapshotV2(t *testing.T) {
	for name, fx := range map[string]poolModelFixture{
		"native mlx_cache entry":         {},
		"creator-owned llama.cpp entry":  {runtime: "llamacpp_loopback"},
		"R016-attested delegated member": {runtime: "llamacpp_loopback", delegated: true, attested: true},
	} {
		t.Run(name, func(t *testing.T) {
			h := newPoolModelHarness(t, fx)
			headers := externalRuntimePoolHeaders(h.poolID)
			headers.Del(routeSnapshotV2CapabilityHeader)
			rec := postChat(t, h.server, h.body(), headers)
			if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "pool_model_requires_gateway_upgrade") {
				t.Fatalf("pre-v2 gateway: status=%d body=%s", rec.Code, rec.Body.String())
			}
			if rows := queryRouteSnapshotBYOMBindings(t, h.dbPath); len(rows) != 0 {
				t.Fatalf("route snapshot recorded: %v", rows)
			}
			if got := ledgerCreditCount(t, h.dbPath); got != 0 {
				t.Fatalf("ledger credits=%d want 0", got)
			}
		})
	}
}
