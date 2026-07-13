package buyer_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// TestInternalRoutingAcceptsServiceTokenOnly locks the M3-2 / SECU-4
// post-cutover contract for `/internal/routing` and `/internal/sticky`
// (the paths the gateway actually calls upstream): the gateway_service_token
// is the SOLE accepted credential. PR #87 item 3 removes the legacy
// operator_key fallback after the tracked 30-day clean-cutover gate.
// An operator-key-shaped
// bearer hitting this path post-cutover MUST 401 — that's the
// security gain the removal locked in.
func TestInternalRoutingAcceptsServiceTokenOnly(t *testing.T) {
	tests := []struct {
		name       string
		bearer     string
		wantStatus int
		wantLogKey string // "" means no audit-log line expected
	}{
		{name: "service_token accepted", bearer: "service-secret", wantStatus: http.StatusOK, wantLogKey: "service_token"},
		{name: "operator-key-shaped bearer rejected post-cutover", bearer: "operator-secret", wantStatus: http.StatusUnauthorized, wantLogKey: ""},
		{name: "unknown bearer rejected", bearer: "wrong", wantStatus: http.StatusUnauthorized, wantLogKey: ""},
		{name: "no bearer rejected", bearer: "", wantStatus: http.StatusUnauthorized, wantLogKey: ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var buf bytes.Buffer
			logger := zerolog.New(&buf)

			registry := pool.NewRegistry(nil)
			server := buyer.NewServer(
				registry,
				logger,
				time.Unix(1716768000, 0),
				buyer.WithGatewayServiceToken("service-secret"),
			)

			req := httptest.NewRequest(http.MethodGet, "/internal/routing", nil)
			if tc.bearer != "" {
				req.Header.Set("Authorization", "Bearer "+tc.bearer)
			}
			rr := httptest.NewRecorder()
			server.InternalHandler().ServeHTTP(rr, req)

			if rr.Code != tc.wantStatus {
				t.Fatalf("status=%d want=%d body=%s log=%s", rr.Code, tc.wantStatus, rr.Body.String(), buf.String())
			}

			logs := buf.String()
			if tc.wantLogKey == "" {
				if strings.Contains(logs, `"event":"internal_bearer_accepted"`) {
					t.Fatalf("did not expect audit-log line on reject, got: %s", logs)
				}
				return
			}
			wantKey := `"key":"` + tc.wantLogKey + `"`
			if !strings.Contains(logs, `"event":"internal_bearer_accepted"`) || !strings.Contains(logs, wantKey) {
				t.Fatalf("audit log missing %q; got: %s", wantKey, logs)
			}
			// Post-cutover the operator_key class can never appear on /internal/*.
			if strings.Contains(logs, `"key":"operator_key"`) {
				t.Fatalf("audit log contained key=operator_key post-cutover; got: %s", logs)
			}
		})
	}
}

// TestInternalStickyDeleteAcceptsServiceTokenOnly covers the second
// gateway-internal path (DELETE /internal/sticky). Same post-cutover
// service_token-only contract as /internal/routing.
func TestInternalStickyDeleteAcceptsServiceTokenOnly(t *testing.T) {
	cases := []struct {
		name       string
		bearer     string
		wantStatus int
	}{
		{name: "service_token accepted", bearer: "service-secret", wantStatus: http.StatusOK},
		{name: "operator-key-shaped bearer rejected post-cutover", bearer: "operator-secret", wantStatus: http.StatusUnauthorized},
		{name: "rejected unknown", bearer: "nope", wantStatus: http.StatusUnauthorized},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			server := buyer.NewServer(
				registry,
				zerolog.Nop(),
				time.Unix(1716768000, 0),
				buyer.WithGatewayServiceToken("service-secret"),
			)
			req := httptest.NewRequest(http.MethodDelete, "/internal/sticky?account_id=acct-1", nil)
			req.Header.Set("Authorization", "Bearer "+tc.bearer)
			rr := httptest.NewRecorder()
			server.InternalHandler().ServeHTTP(rr, req)
			if rr.Code != tc.wantStatus {
				t.Fatalf("status=%d want=%d body=%s", rr.Code, tc.wantStatus, rr.Body.String())
			}
		})
	}
}
