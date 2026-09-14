package ws_test

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

type buyerFailureRecordingConn struct {
	net.Conn
	atClose func()
	calls   atomic.Int32
}

func (c *buyerFailureRecordingConn) Close() error {
	c.calls.Add(1)
	c.atClose()
	return c.Conn.Close()
}

func TestBuyerHTTPFailurePublishesRealWSClosing(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		reason string
	}{
		{"http_530", 530, "http_530_observed"},
		{"http_302", http.StatusFound, "provider_redirect_observed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var upstreamHits, targetHits atomic.Int32
			target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { targetHits.Add(1); w.WriteHeader(http.StatusOK) }))
			defer target.Close()
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				upstreamHits.Add(1)
				if r.Method != http.MethodPost || r.URL.Path != "/v1/chat/completions" {
					t.Errorf("unexpected upstream request %s %s", r.Method, r.URL.Path)
				}
				if tc.status == http.StatusFound {
					w.Header().Set("Location", target.URL+"/v1/chat/completions")
				}
				w.WriteHeader(tc.status)
			}))
			defer upstream.Close()
			raw, peer := net.Pipe()
			defer raw.Close()
			defer peer.Close()
			conn := &buyerFailureRecordingConn{Conn: raw}
			wsServer, registry, p, assertUnpinned := providerws.NewHTTPAdmissionTransportFixtureForTest(t, upstream.URL, conn)
			var closeCalls atomic.Int32
			conn.atClose = func() {
				if err := assertUnpinned(); err != nil {
					t.Error(err)
				}
				live, ok := registry.Resolve(p.ProviderID, p.AssignedID)
				if !ok || live.State != pool.StateReady {
					t.Error("socket closed after registry cleanup or without ready revival")
				}
				if wsServer.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
					t.Error("socket Close preceded monotonic ineligibility")
				}
			}
			closeTransport := func(id, assigned, reason string) error {
				closeCalls.Add(1)
				if id != p.ProviderID || assigned != p.AssignedID || reason != tc.reason {
					t.Errorf("close tuple/reason = %q %q %q", id, assigned, reason)
				}
				live, ok := registry.Resolve(p.ProviderID, p.AssignedID)
				if !ok || live.State != pool.StateUnavailable {
					t.Error("real buyer failure did not first mark unavailable")
				}
				// Direct unavailable-to-ready is intentionally fenced. Exercise
				// the existing real busy/state-update path before ready.
				registry.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateBusy})
				revived, ok := registry.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady})
				if !ok || revived.State != pool.StateReady {
					t.Error("ready revival failed")
				}
				if !wsServer.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
					t.Error("exact session unavailable before real WS close")
				}
				return wsServer.CloseModelAdmissionTransport(id, assigned, reason)
			}
			server := buyer.NewServer(registry, zerolog.Nop(), time.Now(), buyer.WithModelAdmissionTransport(wsServer.ModelAdmissionSessionAvailable, closeTransport))
			if !server.ModelAdmissionAuthorityReady() {
				t.Fatal("complete constructor transport wiring rejected")
			}
			for _, missing := range []struct {
				name  string
				read  func(string, string) bool
				close func(string, string, string) error
			}{
				{"read", nil, closeTransport}, {"close", wsServer.ModelAdmissionSessionAvailable, nil},
			} {
				incomplete := buyer.NewServer(registry, zerolog.Nop(), time.Now(), buyer.WithModelAdmissionTransport(missing.read, missing.close))
				if incomplete.ModelAdmissionAuthorityReady() {
					t.Errorf("missing %s capability accepted", missing.name)
				}
			}
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"model-a","messages":[{"role":"user","content":"fixture"}],"max_tokens":32}`))
			req.Header.Set("Content-Type", "application/json")
			response := httptest.NewRecorder()
			server.Handler().ServeHTTP(response, req)
			if response.Code != http.StatusBadGateway {
				t.Fatalf("buyer result=%d %s", response.Code, response.Body.String())
			}
			if upstreamHits.Load() != 1 || targetHits.Load() != 0 {
				t.Fatalf("upstream hits=%d redirect target=%d", upstreamHits.Load(), targetHits.Load())
			}
			if closeCalls.Load() != 1 || conn.calls.Load() != 1 {
				t.Fatalf("close callback=%d socket=%d", closeCalls.Load(), conn.calls.Load())
			}
			if strings.Contains(response.Body.String(), `"choices"`) || response.Header().Get("X-MacProvider-Receipt") != "" {
				t.Fatal("terminal HTTP failure claimed successful inference/receipt")
			}
			for _, header := range []string{"X-MacProvider-Settlement-Outcome", "X-MacProvider-Settlement-Receipt-Result"} {
				if response.Header().Get(header) != "" {
					t.Fatalf("legacy failure unexpectedly claimed %s=%s", header, response.Header().Get(header))
				}
			}
			registry.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateBusy})
			revived, ok := registry.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady})
			if !ok || revived.State != pool.StateReady {
				t.Fatal("post-close ready update failed")
			}
			if wsServer.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
				t.Fatal("later ready update revived closing session")
			}
			if err := assertUnpinned(); err != nil {
				t.Fatal(err)
			}
			live, ok := registry.Resolve(p.ProviderID, p.AssignedID)
			if !ok || live.State != pool.StateReady {
				t.Fatal("eventual disconnect cleanup substituted for closing proof")
			}
		})
	}
}
