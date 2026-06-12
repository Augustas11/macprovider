package ws_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// TestPoolzAdminEndpointIsOperatorOnly locks in the codex PR #73 HIGH-1
// fix: `/poolz` is human-admin and must NOT accept the gateway service
// token. Accepting it would silently grant the gateway human-admin
// power once the operator rotates the legacy operator_key — the exact
// inverted-scope failure the audit identified.
//
// Pre-fix (M3-2 dual-credential bridge applied uniformly): /poolz
// accepted both operator_key AND gateway_service_token.
// Post-fix:
//
//   - operator_key   → 200, audit-log key=operator_key
//   - service_token  → 401, no audit-log line
//   - bogus bearer   → 401, no audit-log line
func TestPoolzAdminEndpointIsOperatorOnly(t *testing.T) {
	tests := []struct {
		name       string
		bearer     string
		wantStatus int
		wantLogKey string // "" means no audit-log line expected
	}{
		{name: "operator_key accepted", bearer: "operator-secret", wantStatus: http.StatusOK, wantLogKey: "operator_key"},
		{name: "service_token rejected on admin path", bearer: "service-secret", wantStatus: http.StatusUnauthorized, wantLogKey: ""},
		{name: "unknown bearer rejected", bearer: "wrong", wantStatus: http.StatusUnauthorized, wantLogKey: ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var buf bytes.Buffer
			logger := zerolog.New(&buf)

			cfg := config.Default()
			cfg.Auth.OperatorKey = "operator-secret"
			cfg.Auth.GatewayServiceToken = "service-secret"
			cfg.Auth.RequireProviderTokens = false
			cfg.Pool.WarmupGateEnabled = false

			registry := pool.NewRegistry(nil)
			server := providerws.NewServer(cfg, registry, logger)
			ts := httptest.NewServer(server.Handler())
			defer ts.Close()

			req, err := http.NewRequest(http.MethodGet, ts.URL+"/poolz", nil)
			if err != nil {
				t.Fatalf("new req: %v", err)
			}
			req.Header.Set("Authorization", "Bearer "+tc.bearer)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("do: %v", err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != tc.wantStatus {
				t.Fatalf("status=%d want=%d (log=%s)", resp.StatusCode, tc.wantStatus, buf.String())
			}

			logs := buf.String()
			if tc.wantLogKey == "" {
				if strings.Contains(logs, `"event":"internal_bearer_accepted"`) {
					t.Fatalf("did not expect audit-log line, got: %s", logs)
				}
				return
			}
			wantKey := `"key":"` + tc.wantLogKey + `"`
			if !strings.Contains(logs, `"event":"internal_bearer_accepted"`) || !strings.Contains(logs, wantKey) {
				t.Fatalf("audit log missing %q or wrong key; got: %s", wantKey, logs)
			}
			// Negative: the OTHER kind must NOT show up. /poolz never
			// audits service_token because it never accepts service_token.
			otherKey := "operator_key"
			if tc.wantLogKey == "operator_key" {
				otherKey = "service_token"
			}
			if strings.Contains(logs, `"key":"`+otherKey+`"`) {
				t.Fatalf("audit log should not contain key=%s; got: %s", otherKey, logs)
			}
		})
	}
}
