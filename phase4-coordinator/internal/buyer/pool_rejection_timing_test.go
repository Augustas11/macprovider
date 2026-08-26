package buyer_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	"github.com/rs/zerolog"
)

func TestPoolRejectionTimingFloor_Enforced(t *testing.T) {
	const floor = 50 * time.Millisecond
	registry := pool.NewRegistry(nil)
	trustPools := trustpool.NewRegistry()
	trustPools.AddPool("pool-a")
	trustPools.AuthorizeBuyer("pool-a", "acct_allowed")
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("gateway-secret"),
		buyer.WithRequireGatewayContext(true),
		buyer.WithPoolMembership(trustPools),
		buyer.WithPoolRejectionTimingFloor(floor),
	)
	body := `{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`
	start := time.Now()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer gateway-secret")
	req.Header.Set("X-MacProvider-Account", "acct_denied")
	req.Header.Set("X-MacProvider-Pool", "pool-a")
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	elapsed := time.Since(start)
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s, want 503", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), "pool_unavailable") {
		t.Fatalf("body=%s, want pool_unavailable", rr.Body.String())
	}
	if elapsed+5*time.Millisecond < floor {
		t.Fatalf("elapsed=%s below floor=%s", elapsed, floor)
	}
}

func TestPoolRejectionTimingFloor_ClampsSub50(t *testing.T) {
	registry := pool.NewRegistry(nil)
	trustPools := trustpool.NewRegistry()
	trustPools.AddPool("pool-a")
	trustPools.AuthorizeBuyer("pool-a", "acct_allowed")
	server := buyer.NewServer(
		registry,
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithGatewayServiceToken("gateway-secret"),
		buyer.WithRequireGatewayContext(true),
		buyer.WithPoolMembership(trustPools),
		buyer.WithPoolRejectionTimingFloor(10*time.Millisecond),
	)
	body := `{"model":"model-a","messages":[{"role":"user","content":"hi"}]}`
	start := time.Now()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer gateway-secret")
	req.Header.Set("X-MacProvider-Account", "acct_denied")
	req.Header.Set("X-MacProvider-Pool", "pool-a")
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	elapsed := time.Since(start)
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s, want 503", rr.Code, rr.Body.String())
	}
	if elapsed+5*time.Millisecond < 50*time.Millisecond {
		t.Fatalf("elapsed=%s below clamped 50ms floor", elapsed)
	}
}
