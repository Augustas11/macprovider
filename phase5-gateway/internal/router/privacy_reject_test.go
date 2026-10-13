package router

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

// captureSlog routes the default slog logger to a buffer for one test.
func captureSlog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return &buf
}

func privacyRouteEvents(t *testing.T, logs *bytes.Buffer) []map[string]any {
	t.Helper()
	var events []map[string]any
	for _, line := range bytes.Split(logs.Bytes(), []byte("\n")) {
		var event map[string]any
		if len(line) == 0 || json.Unmarshal(line, &event) != nil || event["event"] != "privacy_route_rejected" {
			continue
		}
		events = append(events, event)
	}
	return events
}

// SPEC-049-R030: the gateway records the coordinator's closed reason for a
// refused privacy request, counts it, and never forwards the internal header
// or the reason to the buyer.
func TestPrivacyGatewayRecordsUpstreamRejectReason(t *testing.T) {
	for _, tc := range []struct {
		name, header, want string
		headers            []string
	}{
		{name: "closed reason", headers: []string{relayblind.PrivacyRejectPostureExpired}, want: relayblind.PrivacyRejectPostureExpired},
		{name: "unknown reason", headers: []string{"provider-123-is-quarantined"}, want: relayblind.PrivacyRejectOther},
		{name: "repeated header", headers: []string{relayblind.PrivacyRejectPostureExpired, relayblind.PrivacyRejectSlotUnavailable}, want: relayblind.PrivacyRejectOther},
		{name: "missing header", want: relayblind.PrivacyRejectOther},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res, _ := pilotReservationFixture(t, false)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				for _, value := range tc.headers {
					w.Header().Add(relayblind.PrivacyRejectReasonHeader, value)
				}
				w.WriteHeader(http.StatusServiceUnavailable)
				io.WriteString(w, `{"error":{"code":"privacy_class_unavailable","message":"Privacy class is unavailable"}}`)
			}))
			defer upstream.Close()
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				enablePrivacy(c)
				c.Coordinator.BuyerURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, "privacy-reject-reason")
			logs := captureSlog(t)
			body := privacyReservationBody(t, relayblind.ReservationResponse{Model: res.Model, Stream: res.Stream, MaxOutputTokens: res.MaxOutputTokens, InputTokenUpperBound: res.InputTokenUpperBound})
			resp := postPrivacy(h, key, "/v1/relay-blind/route-reservations", body, map[string]string{privacyClassHeader: privacyClassV1})
			if resp.Code != http.StatusServiceUnavailable {
				t.Fatalf("status %d %s", resp.Code, resp.Body.String())
			}
			assertPrivacyError(t, resp.Body.String(), resp.Code, privacyClassUnavailable, "none", "")
			if got := resp.Header().Values(relayblind.PrivacyRejectReasonHeader); len(got) != 0 {
				t.Fatalf("reason header forwarded to the buyer: %v", got)
			}
			for _, leaked := range []string{relayblind.PrivacyRejectPostureExpired, "provider-123"} {
				if strings.Contains(resp.Body.String(), leaked) {
					t.Fatalf("buyer body carries %q: %s", leaked, resp.Body.String())
				}
			}
			events := privacyRouteEvents(t, logs)
			if len(events) != 1 || events[0]["phase"] != relayblind.PrivacyRejectPhaseReservation || events[0]["reason"] != tc.want || events[0]["code"] != privacyClassUnavailable {
				t.Fatalf("events=%v", events)
			}
			if strings.Contains(logs.String(), "provider-123") || strings.Contains(logs.String(), key) {
				t.Fatalf("log carries an unvetted value: %s", logs.String())
			}
			metrics := httptest.NewRecorder()
			h.ServeHTTP(metrics, httptest.NewRequest(http.MethodGet, "/metrics", nil))
			line := `gateway_privacy_route_rejections_total{phase="reservation",reason="` + tc.want + `"} 1`
			if !strings.Contains(metrics.Body.String(), line) {
				t.Fatalf("metric %q missing from %s", line, metrics.Body.String())
			}
		})
	}
}

// A plain relay-blind refusal is not a privacy event.
func TestRelayBlindGatewayRefusalIsNotPrivacyEvent(t *testing.T) {
	res, _ := pilotReservationFixture(t, false)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(relayblind.PrivacyRejectReasonHeader, relayblind.PrivacyRejectSlotUnavailable)
		w.WriteHeader(http.StatusServiceUnavailable)
		io.WriteString(w, `{"error":{"code":"relay_blind_provider_unsupported"}}`)
	}))
	defer upstream.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "relay-blind-reject")
	logs := captureSlog(t)
	body := privacyReservationBody(t, relayblind.ReservationResponse{Model: res.Model, Stream: res.Stream, MaxOutputTokens: res.MaxOutputTokens, InputTokenUpperBound: res.InputTokenUpperBound})
	resp := postPrivacy(h, key, "/v1/relay-blind/route-reservations", body, nil)
	if resp.Code != http.StatusServiceUnavailable || len(resp.Header().Values(relayblind.PrivacyRejectReasonHeader)) != 0 {
		t.Fatalf("status %d headers %v", resp.Code, resp.Header())
	}
	if events := privacyRouteEvents(t, logs); len(events) != 0 {
		t.Fatalf("relay-blind refusal logged as privacy: %v", events)
	}
}

// A refusal at consume is recorded at the consume phase.
func TestPrivacyGatewayRecordsConsumePhase(t *testing.T) {
	res := privacyReservationFixture(t, false)
	raw := pilotEnvelopeFixture(t, res)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(relayblind.PrivacyRejectReasonHeader, relayblind.PrivacyRejectPostureExpired)
		w.WriteHeader(http.StatusServiceUnavailable)
		io.WriteString(w, `{"error":{"code":"privacy_class_posture_stale"}}`)
	}))
	defer upstream.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-reject-consume")
	logs := captureSlog(t)
	resp := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
	if resp.Code != http.StatusServiceUnavailable || len(resp.Header().Values(relayblind.PrivacyRejectReasonHeader)) != 0 {
		t.Fatalf("status %d headers %v", resp.Code, resp.Header())
	}
	events := privacyRouteEvents(t, logs)
	if len(events) != 1 || events[0]["phase"] != relayblind.PrivacyRejectPhaseConsume || events[0]["reason"] != relayblind.PrivacyRejectPostureExpired {
		t.Fatalf("events=%v", events)
	}
}
