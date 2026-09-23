package buyer

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// SPEC-022-R002 R-2.7 (#1689): the operator /poolz.routing_eligible
// projection agrees with buyer routing because the coordinator wires the
// buyer server's enforce-mode catalog-material verdict into the provider WS
// server (cmd/coordinator/main.go does the same wiring).
func TestPoolzRoutingEligibleAgreesWithCatalogMaterialGate(t *testing.T) {
	for _, tc := range []struct {
		name     string
		enforce  bool
		material bool
		want     bool
	}{
		{name: "enforce material missing", enforce: true, material: false, want: false},
		{name: "observe material missing", enforce: false, material: false, want: true},
		{name: "enforce material present", enforce: true, material: true, want: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.material {
				withModelACatalogMaterial(t)
			} else {
				withoutCatalogMaterial(t)
			}
			var s *Server
			var registry *pool.Registry
			if tc.enforce {
				s, registry = enforceReceiptServer(t)
			} else {
				registry = pool.NewRegistry(nil)
				s = NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
			}
			cfg := config.Default()
			cfg.Auth.OperatorKey = "operator-secret"
			ws := providerws.NewServer(cfg, registry, zerolog.Nop())
			ws.SetCatalogMaterialRoutingGate(s.CatalogMaterialMissingUnderEnforce)

			p := receiptGateProvider("cm", nil)
			registry.Register(&p, nil)

			req := httptest.NewRequest(http.MethodGet, "/poolz", nil)
			req.Header.Set("Authorization", "Bearer operator-secret")
			rr := httptest.NewRecorder()
			ws.Handler().ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				t.Fatalf("/poolz status = %d body=%s", rr.Code, rr.Body.String())
			}
			var body struct {
				Pool []struct {
					ProviderID      string `json:"provider_id"`
					RoutingEligible bool   `json:"routing_eligible"`
				} `json:"pool"`
			}
			if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
				t.Fatalf("decode: %v", err)
			}
			if len(body.Pool) != 1 {
				t.Fatalf("pool = %+v, want one provider", body.Pool)
			}
			if body.Pool[0].RoutingEligible != tc.want {
				t.Fatalf("routing_eligible = %v, want %v", body.Pool[0].RoutingEligible, tc.want)
			}
			if got := s.CatalogMaterialMissingUnderEnforce(p); got == tc.want {
				t.Fatalf("buyer verdict %v disagrees with routing_eligible %v", got, tc.want)
			}
		})
	}
}
