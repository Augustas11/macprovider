package ws_test

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

func TestProviderHelloReceivesAck(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	assertHelloAck(t, conn)
}

func TestProviderHelloAcceptsAuthorizationHeaderInStep2(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	dialer := gobwas.Dialer{
		Header: gobwas.HandshakeHeaderHTTP(http.Header{
			"Authorization": []string{"Bearer test-token"},
		}),
	}
	conn, _, _, err := dialer.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	assertHelloAck(t, conn)
}

func TestHeartbeatUpdatesPoolz(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)

	hb := heartbeat()
	hb["slots_free"] = 0
	hb["status"] = "busy"
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}

	var got struct {
		Pool []struct {
			ProviderID string `json:"provider_id"`
			State      string `json:"state"`
			SlotsFree  int    `json:"slots_free"`
			SlotsTotal int    `json:"slots_total"`
			Endpoint   string `json:"endpoint_url"`
		} `json:"pool"`
		Summary struct {
			TotalProviders int `json:"total_providers"`
			Ready          int `json:"ready"`
			FreeSlots      int `json:"free_slots"`
		} `json:"summary"`
	}
	eventually(t, func() bool {
		req, err := http.NewRequest(http.MethodGet, ts.URL+"/poolz", nil)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		req.Header.Set("Authorization", "Bearer test-operator-key")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("poolz: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(resp.Body)
			t.Fatalf("poolz status=%d body=%s", resp.StatusCode, body)
		}
		got = struct {
			Pool []struct {
				ProviderID string `json:"provider_id"`
				State      string `json:"state"`
				SlotsFree  int    `json:"slots_free"`
				SlotsTotal int    `json:"slots_total"`
				Endpoint   string `json:"endpoint_url"`
			} `json:"pool"`
			Summary struct {
				TotalProviders int `json:"total_providers"`
				Ready          int `json:"ready"`
				FreeSlots      int `json:"free_slots"`
			} `json:"summary"`
		}{}
		if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
			t.Fatalf("poolz json: %v", err)
		}
		return len(got.Pool) == 1 && got.Pool[0].State == "busy" && got.Pool[0].SlotsFree == 0
	})
	if got.Pool[0].ProviderID != "m4-anon" {
		t.Fatalf("provider_id = %q", got.Pool[0].ProviderID)
	}
	if got.Pool[0].Endpoint != "https://m4.streamvc.live" {
		t.Fatalf("endpoint = %q", got.Pool[0].Endpoint)
	}
	if got.Summary.TotalProviders != 1 || got.Summary.Ready != 0 || got.Summary.FreeSlots != 0 {
		t.Fatalf("summary = %+v", got.Summary)
	}
}

func TestStateUpdateCyclesProviderState(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)

	states := []string{"ready", "busy", "degraded", "draining", "unavailable"}
	for _, state := range states {
		msg := map[string]any{
			"type":   "state_update",
			"state":  state,
			"reason": "test transition",
			"since":  "2026-05-27T14:30:00Z",
			"metrics_snapshot": map[string]any{
				"slots_free":  0,
				"slots_total": 1,
			},
		}
		if state == "ready" {
			msg["metrics_snapshot"].(map[string]any)["slots_free"] = 1
		}
		if err := wsutil.WriteClientText(conn, mustJSON(msg)); err != nil {
			t.Fatalf("write state_update %s: %v", state, err)
		}
		eventually(t, func() bool {
			got := fetchPoolz(t, ts.URL)
			return len(got.Pool) == 1 && got.Pool[0].State == state
		})
	}
}

func TestWakeGapSendsWarmUpAndMarksDegraded(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.Pool.WakeGapThresholdS = 1
	})
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)

	if err := wsutil.WriteClientText(conn, mustJSON(heartbeat())); err != nil {
		t.Fatalf("write first heartbeat: %v", err)
	}
	time.Sleep(1100 * time.Millisecond)
	if err := wsutil.WriteClientText(conn, mustJSON(heartbeat())); err != nil {
		t.Fatalf("write resume heartbeat: %v", err)
	}

	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read warm_up: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var msg map[string]string
	if err := json.Unmarshal(payload, &msg); err != nil {
		t.Fatalf("warm_up json: %v", err)
	}
	if msg["type"] != "warm_up" {
		t.Fatalf("message type = %q, want warm_up", msg["type"])
	}

	eventually(t, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 1 && got.Pool[0].State == "degraded"
	})
}

func TestDisconnectMarksUnavailableThenRemovesAfterGrace(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.Pool.DisconnectGracePeriodS = 1
	})
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	assertHelloAck(t, conn)
	if err := conn.Close(); err != nil {
		t.Fatalf("close provider conn: %v", err)
	}

	eventually(t, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 1 && got.Pool[0].State == "unavailable"
	})
	eventually(t, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 0
	})
}

func TestPoolzRequiresOperatorKey(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/poolz")
	if err != nil {
		t.Fatalf("poolz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}
}

func assertHelloAck(t *testing.T, conn net.Conn) {
	t.Helper()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("m4-anon"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}

	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.Type != "hello_ack" {
		t.Fatalf("ack type = %q", ack.Type)
	}
	if ack.CoordinatorVersion != 1 {
		t.Fatalf("coordinator_version = %d", ack.CoordinatorVersion)
	}
	if ack.AssignedID == "" {
		t.Fatal("assigned_id is empty")
	}
	if ack.HeartbeatIntervalS != 30 {
		t.Fatalf("heartbeat_interval_s = %d", ack.HeartbeatIntervalS)
	}
}

func TestProviderHelloRejectsUnknownProvider(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	code, reason := sendHelloExpectClose(t, ts.URL, validHello("unknown"))
	if code != providerws.CloseUnknownProviderID {
		t.Fatalf("code = %d, want %d", code, providerws.CloseUnknownProviderID)
	}
	if reason != "unknown_provider_id: unknown" {
		t.Fatalf("reason = %q", reason)
	}
}

func TestProviderHelloRejectsMalformedHello(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	h := validHello("m4-anon")
	delete(h, "model_id")
	code, reason := sendHelloExpectClose(t, ts.URL, h)
	if code != providerws.CloseInvalidHello {
		t.Fatalf("code = %d, want %d", code, providerws.CloseInvalidHello)
	}
	if reason != "invalid_hello: missing model_id" {
		t.Fatalf("reason = %q", reason)
	}
}

func TestProviderHelloRejectsUnsupportedVersionAndTier(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	versionHello := validHello("m4-anon")
	versionHello["version"] = 2
	code, reason := sendHelloExpectClose(t, ts.URL, versionHello)
	if code != providerws.CloseVersionUnsupported {
		t.Fatalf("version code = %d, want %d", code, providerws.CloseVersionUnsupported)
	}
	if reason != "version_unsupported: protocol version 2" {
		t.Fatalf("version reason = %q", reason)
	}

	tierHello := validHello("m4-anon")
	tierHello["tier"] = 2
	code, reason = sendHelloExpectClose(t, ts.URL, tierHello)
	if code != providerws.CloseTierUnsupported {
		t.Fatalf("tier code = %d, want %d", code, providerws.CloseTierUnsupported)
	}
	if reason != "tier_unsupported: tier 2 not supported" {
		t.Fatalf("tier reason = %q", reason)
	}
}

type poolzResponse struct {
	Pool []struct {
		ProviderID string `json:"provider_id"`
		State      string `json:"state"`
		SlotsFree  int    `json:"slots_free"`
		SlotsTotal int    `json:"slots_total"`
		Endpoint   string `json:"endpoint_url"`
	} `json:"pool"`
	Summary struct {
		TotalProviders int `json:"total_providers"`
		Ready          int `json:"ready"`
		FreeSlots      int `json:"free_slots"`
	} `json:"summary"`
}

func fetchPoolz(t *testing.T, serverURL string) poolzResponse {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, serverURL+"/poolz", nil)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("poolz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("poolz status=%d body=%s", resp.StatusCode, body)
	}
	var got poolzResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("poolz json: %v", err)
	}
	return got
}

func newProviderServer(t *testing.T, opts ...func(*config.Config)) *httptest.Server {
	t.Helper()
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.Providers = []config.ProviderConfig{
		{
			ProviderID:  "m4-anon",
			EndpointURL: "https://m4.streamvc.live",
			DisplayName: "M4 test provider",
		},
	}
	for _, opt := range opts {
		opt(&cfg)
	}
	registry := pool.NewRegistry(cfg.Providers)
	server := providerws.NewServer(cfg, registry, zerolog.Nop())
	return httptest.NewServer(server.Handler())
}

func sendHelloExpectClose(t *testing.T, serverURL string, hello map[string]any) (gobwas.StatusCode, string) {
	t.Helper()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(serverURL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close", frame.Header.OpCode)
	}
	return gobwas.ParseCloseFrameData(frame.Payload)
}

func validHello(providerID string) map[string]any {
	return map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             providerID,
		"hostname":                "provider.local",
		"model_id":                "mlx-community/Qwen2.5-7B-Instruct-4bit",
		"model_params_b":          7.0,
		"ram_gb":                  16,
		"max_context_tokens":      50000,
		"max_concurrency":         1,
		"throughput_tps_estimate": 19.8,
		"binary_version":          "0.1.0",
		"attestation":             nil,
	}
}

func heartbeat() map[string]any {
	return map[string]any{
		"type":                       "heartbeat",
		"status":                     "ready",
		"model_id":                   "mlx-community/Qwen2.5-7B-Instruct-4bit",
		"model_params_b":             7.0,
		"ram_gb":                     16,
		"max_context_tokens":         50000,
		"max_concurrency":            1,
		"slots_free":                 1,
		"slots_total":                1,
		"throughput_tps_estimate":    19.8,
		"requests_served_since_last": 1,
		"avg_latency_ms_since_last":  450.0,
		"throughput_tps_since_last":  18.5,
	}
}

func eventually(t *testing.T, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if f() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("condition did not become true before deadline")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

func wsURL(httpURL string) string {
	return "ws" + strings.TrimPrefix(httpURL, "http") + "/ws/provider"
}
