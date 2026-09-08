package buyer_test

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestSettlementInternalRequestHeaderIsCoordinatorOwnedBeforeStreamEOF(t *testing.T) {
	const header = "X-MacProvider-Internal-Request-ID"
	for _, idempotency := range []string{"", "binding-idempotency-key"} {
		name := "fresh"
		if idempotency != "" {
			name = "idempotency"
		}
		t.Run(name, func(t *testing.T) {
			release := make(chan struct{})
			var releaseOnce sync.Once
			releaseProvider := func() { releaseOnce.Do(func() { close(release) }) }
			defer releaseProvider()
			providerRequestID := make(chan string, 1)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				providerRequestID <- r.Header.Get("X-Request-ID")
				w.Header().Set(header, "provider-forged-id")
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")
				w.(http.Flusher).Flush()
				select {
				case <-release:
				case <-r.Context().Done():
					return
				}
				_, _ = io.WriteString(w, "data: [DONE]\n\n")
			}))
			defer upstream.Close()
			reqLog, _ := openBuyerRequestLog(t)
			defer reqLog.Close()
			registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
			registerWithEndpoint(registry, "p1", "session-1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
			server := buyer.NewServer(registry, zerolog.Nop(), time.Now(), buyer.WithRequestLog(reqLog), buyer.WithGatewayServiceToken("gateway-secret"))
			coordinator := httptest.NewServer(server.Handler())
			defer coordinator.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, coordinator.URL+"/v1/chat/completions", strings.NewReader(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`))
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("X-Request-ID", "gateway-external-id")
			req.Header.Set("Authorization", "Bearer gateway-secret")
			req.Header.Set("X-MacProvider-Account", "acct_header_binding")
			req.Header.Set(header, "buyer-forged-id")
			if idempotency != "" {
				req.Header.Set("Idempotency-Key", idempotency)
			}
			resp, err := coordinator.Client().Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				body, _ := io.ReadAll(resp.Body)
				t.Fatalf("status=%d body=%s", resp.StatusCode, body)
			}
			internalID := resp.Header.Get(header)
			if internalID == "" || internalID == "gateway-external-id" || internalID == "buyer-forged-id" || internalID == "provider-forged-id" {
				t.Fatalf("initial header is not coordinator-owned: %q", internalID)
			}
			if got := <-providerRequestID; got != internalID {
				t.Fatalf("initial internal ID=%q, provider dispatch ID=%q", internalID, got)
			}
			var rows int
			if err := reqLog.DB().QueryRow(`SELECT COUNT(*) FROM request_log WHERE request_id = ?`, internalID).Scan(&rows); err != nil {
				t.Fatal(err)
			}
			if rows != 0 {
				t.Fatalf("request log exists before held stream finished: %d", rows)
			}
			releaseProvider()
			if _, err := io.Copy(io.Discard, resp.Body); err != nil {
				t.Fatal(err)
			}
			if err := reqLog.DB().QueryRow(`SELECT COUNT(*) FROM request_log WHERE request_id = ? AND external_request_id = 'gateway-external-id' AND account_id = 'acct_header_binding'`, internalID).Scan(&rows); err != nil {
				t.Fatal(err)
			}
			if rows != 1 {
				t.Fatalf("terminal mapping does not match initial internal ID: rows=%d", rows)
			}
		})
	}
}

func TestSettlementFinalityRequiredInternalRequestQueryFailsClosed(t *testing.T) {
	reqLog, _ := openBuyerRequestLog(t)
	defer reqLog.Close()
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatal(err)
	}
	server := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now(),
		buyer.WithBilling(store, config.RewardsConfig{}), buyer.WithGatewayServiceToken("gateway-secret"))
	for _, tc := range []struct {
		name, query, authorization string
		status                     int
	}{
		{"unknown_current", "&required_internal_request_id=current&reservation_created_at_unix_ms=1", "Bearer gateway-secret", http.StatusNotFound},
		{"missing_generation", "&required_internal_request_id=current", "Bearer gateway-secret", http.StatusBadRequest},
		{"zero_generation", "&required_internal_request_id=current&reservation_created_at_unix_ms=0", "Bearer gateway-secret", http.StatusBadRequest},
		{"empty_binding", "&required_internal_request_id=&reservation_created_at_unix_ms=1", "Bearer gateway-secret", http.StatusBadRequest},
		{"duplicate_binding", "&required_internal_request_id=a&required_internal_request_id=b&reservation_created_at_unix_ms=1", "Bearer gateway-secret", http.StatusBadRequest},
		{"invalid_binding", "&required_internal_request_id=%00&reservation_created_at_unix_ms=1", "Bearer gateway-secret", http.StatusBadRequest},
		{"overlong_binding", "&required_internal_request_id=" + strings.Repeat("x", 129) + "&reservation_created_at_unix_ms=1", "Bearer gateway-secret", http.StatusBadRequest},
		{"unauthorized", "&required_internal_request_id=current&reservation_created_at_unix_ms=1", "", http.StatusUnauthorized},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/internal/settlement/finality?account_id=acct_test&request_id=external"+tc.query, nil)
			req.Header.Set("Authorization", tc.authorization)
			rr := httptest.NewRecorder()
			server.InternalHandler().ServeHTTP(rr, req)
			if rr.Code != tc.status {
				t.Fatalf("status=%d want=%d body=%s", rr.Code, tc.status, rr.Body.String())
			}
			if strings.Contains(rr.Body.String(), `"required_internal_request_id":`) {
				t.Fatalf("unconfirmed membership echoed: %s", rr.Body.String())
			}
		})
	}
}
