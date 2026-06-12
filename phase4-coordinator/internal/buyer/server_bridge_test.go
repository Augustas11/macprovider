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

// TestInternalRoutingAcceptsBothCredentials locks in the codex PR #73
// HIGH-1 fix for the gateway-internal class: `/internal/routing` and
// `/internal/sticky` (the paths the gateway actually calls upstream)
// accept EITHER operator_key OR gateway_service_token. The audit-log
// line names which credential matched so the operator can watch the
// M3-2 cutover for gateway-origin calls still landing on operator_key.
//
// The implementation also evaluates BOTH credentials before branching
// (closing the codex MEDIUM short-circuit timing oracle). This test
// pins the visible behavior; the timing-oracle invariant is asserted at
// the helper level in internal/auth.
func TestInternalRoutingAcceptsBothCredentials(t *testing.T) {
	tests := []struct {
		name       string
		bearer     string
		wantStatus int
		wantLogKey string // "" means no audit-log line expected
	}{
		{name: "operator_key accepted (legacy)", bearer: "operator-secret", wantStatus: http.StatusOK, wantLogKey: "operator_key"},
		{name: "service_token accepted (post-cutover)", bearer: "service-secret", wantStatus: http.StatusOK, wantLogKey: "service_token"},
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
				buyer.WithInternalAuthKey("operator-secret"),
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

// TestInternalStickyDeleteAcceptsBothCredentials covers the second
// gateway-internal path (DELETE /internal/sticky). Same dual-credential
// contract as /internal/routing.
func TestInternalStickyDeleteAcceptsBothCredentials(t *testing.T) {
	cases := []struct {
		name       string
		bearer     string
		wantStatus int
	}{
		{name: "operator_key accepted", bearer: "operator-secret", wantStatus: http.StatusOK},
		{name: "service_token accepted", bearer: "service-secret", wantStatus: http.StatusOK},
		{name: "rejected unknown", bearer: "nope", wantStatus: http.StatusUnauthorized},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			server := buyer.NewServer(
				registry,
				zerolog.Nop(),
				time.Unix(1716768000, 0),
				buyer.WithInternalAuthKey("operator-secret"),
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
