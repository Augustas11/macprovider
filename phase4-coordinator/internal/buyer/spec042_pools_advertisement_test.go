package buyer_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	"github.com/rs/zerolog"
)

// SPEC-042-R010: the coordinator's /internal/routing metadata MUST positively
// advertise pool support so a new gateway can refuse pool dispatch to an old
// coordinator (fail-closed, no pool->global spill). The advertisement is true
// iff the pool feature (WithPoolMembership) is armed.
func TestInternalRoutingAdvertisesPoolCapability(t *testing.T) {
	fetch := func(t *testing.T, server *buyer.Server) bool {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/internal/routing", nil)
		req.Header.Set("Authorization", "Bearer operator-key")
		rr := httptest.NewRecorder()
		server.InternalHandler().ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
		}
		var got struct {
			Pools struct {
				Enabled bool `json:"enabled"`
			} `json:"pools"`
		}
		if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
			t.Fatalf("json: %v body=%s", err, rr.Body.String())
		}
		return got.Pools.Enabled
	}

	t.Run("feature off advertises false", func(t *testing.T) {
		server := buyer.NewServer(
			pool.NewRegistry(nil),
			zerolog.Nop(),
			time.Unix(1716768000, 0),
			buyer.WithGatewayServiceToken("operator-key"),
		)
		if fetch(t, server) {
			t.Fatal("pools.enabled=true with no pool membership armed; want false")
		}
	})

	t.Run("feature on advertises true", func(t *testing.T) {
		server := buyer.NewServer(
			pool.NewRegistry(nil),
			zerolog.Nop(),
			time.Unix(1716768000, 0),
			buyer.WithGatewayServiceToken("operator-key"),
			buyer.WithPoolMembership(trustpool.NewRegistry()),
		)
		if !fetch(t, server) {
			t.Fatal("pools.enabled=false with pool membership armed; want true")
		}
	})
}
