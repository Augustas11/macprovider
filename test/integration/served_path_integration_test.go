package integration

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

// connectServedPathProvider is a WS-tunneled continuous-batching provider
// whose completed inference_response_end carries the SPEC-002-R007
// served_path report.
func connectServedPathProvider(t *testing.T, ctx context.Context, s *scenario, modelID, servedPath string) {
	t.Helper()
	u, err := url.Parse(s.coordProvURL)
	if err != nil {
		t.Fatal(err)
	}
	header := http.Header{}
	header.Set("Authorization", "Bearer "+s.providerToken)
	dialer := gobwas.Dialer{Timeout: 5 * time.Second, Header: gobwas.HandshakeHeaderHTTP(header)}
	var conn net.Conn
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		if conn, _, _, err = dialer.Dial(ctx, "ws://"+u.Host+"/ws/provider"); err == nil {
			break
		}
	}
	if conn == nil {
		t.Fatalf("connect served-path provider: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	var writeMu sync.Mutex
	send := func(v any) error {
		raw, err := json.Marshal(v)
		if err != nil {
			return err
		}
		writeMu.Lock()
		defer writeMu.Unlock()
		return wsutil.WriteClientText(conn, raw)
	}
	if err := send(map[string]any{
		"type": "hello", "version": 1, "tier": 1, "provider_id": s.providerID,
		"hostname": "served-path-fixture", "model_id": modelID, "model_params_b": 3.0,
		"ram_gb": 16, "max_context_tokens": 8192, "max_concurrency": 4,
		"throughput_tps_estimate": 20.0, "binary_version": "1.8.241", "attestation": nil,
	}); err != nil {
		t.Fatalf("send hello: %v", err)
	}
	readSwiftProviderHello(t, conn, false)
	if err := send(readyStateUpdate(modelID, "")); err != nil {
		t.Fatalf("send ready: %v", err)
	}
	heartbeat := func() error {
		return send(map[string]any{
			"type": "heartbeat", "status": "ready", "model_id": modelID,
			"model_params_b": 3.0, "ram_gb": 16, "max_context_tokens": 8192,
			"max_concurrency": 4, "slots_free": 4, "slots_total": 4,
			"throughput_tps_estimate": 20.0, "requests_served_since_last": 0,
			"avg_latency_ms_since_last": 0.0, "throughput_tps_since_last": 0.0,
			"engine_profile": map[string]any{
				"version": "engine-profile-v1", "engine_family": "continuous_batching", "cb_granted_slots": 4,
				"native_mtp_active": false, "chip_class": "m4_max", "ram_class_gb": 16, "max_stable_context_tokens": 8192,
			},
		})
	}
	if err := heartbeat(); err != nil {
		t.Fatalf("send heartbeat: %v", err)
	}
	go func() {
		for {
			raw, _, err := wsutil.ReadServerData(conn)
			if err != nil {
				return
			}
			var req struct {
				Type      string `json:"type"`
				RequestID string `json:"request_id"`
			}
			if json.Unmarshal(raw, &req) != nil || req.Type != "inference_request" {
				continue
			}
			_ = send(map[string]any{
				"type": "inference_response_chunk", "request_id": req.RequestID, "seq": 0,
				"data": fmt.Sprintf(`{"id":"chatcmpl-served","object":"chat.completion","model":%q,"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}`, modelID),
			})
			_ = send(map[string]any{
				"type": "inference_response_end", "request_id": req.RequestID, "status": "complete", "chunks_sent": 1,
				"served_path": json.RawMessage(servedPath),
			})
		}
	}()
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if heartbeat() != nil {
					return
				}
			}
		}
	}()
}

// TestServedPathLabelReachesDemandRowNotBuyer is the SPEC-002-R007 /
// SPEC-006-R028 journey: a provider's served_path report crosses the real
// coordinator and gateway, lands on the gateway demand row, and never
// reaches the buyer.
func TestServedPathLabelReachesDemandRowNotBuyer(t *testing.T) {
	requireBins(t)
	providerID := "prov-served-" + randHex(t, 4)
	s := newScenario(t, scenarioOpts{seedAccount: true, providerID: providerID, externalWebSocketProvider: true})
	defer s.shutdown()
	connectServedPathProvider(t, s.rootCtx, s, settlementFixtureModelID, `{"path":"continuous_batching","rows":3}`)
	s.waitForProviderReady(providerID)
	// The engine profile rides the heartbeat; wait for one after readiness.
	time.Sleep(1500 * time.Millisecond)

	status, headers, body := s.chatRequest(nil, fmt.Sprintf(`{"model":%q,"max_tokens":16,"messages":[{"role":"user","content":"hello"}]}`, staticLlama32CandidateKey))
	if status != http.StatusOK {
		t.Fatalf("status %d body %s", status, body)
	}
	for name := range headers {
		if strings.Contains(strings.ToLower(name), "served") {
			t.Fatalf("buyer response carries %s", name)
		}
	}
	if strings.Contains(string(body), "rows") {
		t.Fatalf("buyer body carries the label: %s", body)
	}
	db, err := sql.Open("sqlite", s.gatewayDB)
	if err != nil {
		t.Fatalf("open gateway db: %v", err)
	}
	defer db.Close()
	var path sql.NullString
	var rows sql.NullInt64
	deadline := time.Now().Add(5 * time.Second)
	for {
		err = db.QueryRow(`SELECT served_path, served_rows FROM demand_events ORDER BY event_id DESC LIMIT 1`).Scan(&path, &rows)
		if err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("demand row: %v", err)
	}
	if path.String != "continuous_batching" || rows.Int64 != 3 {
		t.Fatalf("demand row served_path=%v served_rows=%v, want continuous_batching 3", path, rows)
	}
}
