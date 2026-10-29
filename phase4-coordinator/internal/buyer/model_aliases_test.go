package buyer_test

import (
	"encoding/json"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestModelsAdvertisesExistingRoutingAliases(t *testing.T) {
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: "https://p1.example"}})
	register(registry, "p1", "session-1", "Jundot/GLM-5.3-Flash-oQ4e-mtp", pool.StateReady, 20000, 1)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rr.Code, rr.Body.String())
	}
	var body struct {
		Data []struct {
			Aliases []string `json:"aliases"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Data) != 1 || len(body.Data[0].Aliases) != 3 || body.Data[0].Aliases[0] != "glm-5.3-flash" {
		t.Fatalf("aliases missing: %s", rr.Body.String())
	}
}
