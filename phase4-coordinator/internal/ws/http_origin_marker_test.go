package ws

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/rs/zerolog"
)

// Canary probes and warmup gates are coordinator traffic: the provider must
// never classify them as local use (SPEC-001-R011), so both HTTP-direct
// dispatches carry the coordinator origin marker.
func TestHTTPCanaryAndWarmupCarryCoordinatorOriginMarker(t *testing.T) {
	origins := make(chan string, 2)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origins <- r.Header.Get(providerhttp.OriginHeader)
		http.Error(w, "stop", http.StatusInternalServerError)
	}))
	defer upstream.Close()
	s := NewServer(config.Config{}, pool.NewRegistry(nil), zerolog.Nop())
	provider := pool.Provider{ProviderID: "p", EndpointURL: upstream.URL}
	s.runHTTPWarmupGateAttempt(context.Background(), provider, []byte(`{}`))
	s.runHTTPCanaryProbeAttempt(context.Background(), provider, canaryBuiltProbe{Body: []byte(`{}`)})
	for _, name := range []string{"warmup", "canary"} {
		if got := <-origins; got != providerhttp.OriginCoordinatorValue {
			t.Fatalf("%s origin=%q, want %q", name, got, providerhttp.OriginCoordinatorValue)
		}
	}
}
