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

// TestPoolzAcceptsServiceTokenAndAuditLogs locks in the M3-2 / SECU-4
// bridge: when gateway_service_token is configured, /poolz accepts
// EITHER credential and emits an audit-log line tagged with which one
// matched. The operator watches the journal for
// event=internal_bearer_accepted lines and rotates operator_key once
// every gateway-origin call reports key=service_token.
func TestPoolzAcceptsServiceTokenAndAuditLogs(t *testing.T) {
	tests := []struct {
		name        string
		bearer      string
		wantStatus  int
		wantLogKey  string // "" means no audit-log line expected
	}{
		{name: "operator_key accepted", bearer: "operator-secret", wantStatus: http.StatusOK, wantLogKey: "operator_key"},
		{name: "service_token accepted", bearer: "service-secret", wantStatus: http.StatusOK, wantLogKey: "service_token"},
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
			// Negative: the OTHER kind must NOT show up.
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
