package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"sync"
	"testing"
	"time"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

// keyedServeProvider is a WS-tunneled provider that reproduces CLI
// 1.8.238-1.8.240 (#1998): a clear inference_request carrying a
// conversation_key fails with the mlx-swift-lm incompatibleCapacity error,
// and a keyless one completes.
type keyedServeProvider struct {
	mu   sync.Mutex
	keys []string
}

func (p *keyedServeProvider) dispatchedKeys() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.keys...)
}

func connectKeyedServeProvider(t *testing.T, ctx context.Context, s *scenario, modelID, binaryVersion string) *keyedServeProvider {
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
		t.Fatalf("connect keyed-serve provider: %v", err)
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
		"hostname": "keyed-serve-fixture", "model_id": modelID, "model_params_b": 3.0,
		"ram_gb": 16, "max_context_tokens": 8192, "max_concurrency": 1,
		"throughput_tps_estimate": 20.0, "binary_version": binaryVersion, "attestation": nil,
	}); err != nil {
		t.Fatalf("send hello: %v", err)
	}
	readSwiftProviderHello(t, conn, false)
	if err := send(readyStateUpdate(modelID, "")); err != nil {
		t.Fatalf("send ready: %v", err)
	}

	p := &keyedServeProvider{}
	go func() {
		for {
			raw, _, err := wsutil.ReadServerData(conn)
			if err != nil {
				return
			}
			var req struct {
				Type            string `json:"type"`
				RequestID       string `json:"request_id"`
				ConversationKey string `json:"conversation_key"`
			}
			if json.Unmarshal(raw, &req) != nil || req.Type != "inference_request" {
				continue
			}
			p.mu.Lock()
			p.keys = append(p.keys, req.ConversationKey)
			p.mu.Unlock()
			if req.ConversationKey != "" && binaryVersion == "1.8.240" {
				_ = send(map[string]any{
					"type": "inference_response_end", "request_id": req.RequestID, "status": "error",
					"chunks_sent": 0, "error": "error_internal: incompatibleCapacity(expected: 8192, count: 28)",
				})
				continue
			}
			_ = send(map[string]any{
				"type": "inference_response_chunk", "request_id": req.RequestID, "seq": 0,
				"data": fmt.Sprintf(`{"id":"chatcmpl-keyed","object":"chat.completion","model":%q,"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}`, modelID),
			})
			_ = send(map[string]any{
				"type": "inference_response_end", "request_id": req.RequestID, "status": "complete", "chunks_sent": 1,
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
				if send(map[string]any{
					"type": "heartbeat", "status": "ready", "model_id": modelID,
					"model_params_b": 3.0, "ram_gb": 16, "max_context_tokens": 8192,
					"max_concurrency": 1, "slots_free": 1, "slots_total": 1,
					"throughput_tps_estimate": 20.0, "requests_served_since_last": 0,
					"avg_latency_ms_since_last": 0.0, "throughput_tps_since_last": 0.0,
				}) != nil {
					return
				}
			}
		}
	}()
	return p
}

// TestPlainCanonicalModelRequestServedByKeyedServeIncompatibleCLI is the
// #1998 journey: an authenticated plain gateway request names the canonical
// model id, the gateway derives a SPEC-006-R012 auto-prefix conversation key,
// and the coordinator dispatches to a provider running CLI 1.8.240. That CLI
// fails every keyed request, so the coordinator must dispatch it keyless and
// the buyer gets 200. A newer CLI still receives the key, which proves the
// gateway derived one for this request shape.
func TestPlainCanonicalModelRequestServedByKeyedServeIncompatibleCLI(t *testing.T) {
	requireBins(t)
	for _, tc := range []struct {
		binary  string
		wantKey bool
	}{
		{"1.8.240", false},
		{"1.8.241", true},
	} {
		t.Run(tc.binary, func(t *testing.T) {
			providerID := "prov-keyed-" + randHex(t, 4)
			s := newScenario(t, scenarioOpts{
				seedAccount:               true,
				providerID:                providerID,
				externalWebSocketProvider: true,
			})
			defer s.shutdown()
			provider := connectKeyedServeProvider(t, s.rootCtx, s, settlementFixtureModelID, tc.binary)
			s.waitForProviderReady(providerID)

			status, _, body := s.chatRequest(nil, fmt.Sprintf(
				`{"model":%q,"max_tokens":16,"messages":[{"role":"system","content":"be brief"},{"role":"user","content":"hello"}]}`,
				staticLlama32CandidateKey))
			if status != http.StatusOK {
				t.Fatalf("plain canonical request status %d body %s", status, body)
			}
			keys := provider.dispatchedKeys()
			if len(keys) != 1 {
				t.Fatalf("dispatches=%d keys=%q, want exactly one dispatch", len(keys), keys)
			}
			if gotKey := keys[0] != ""; gotKey != tc.wantKey {
				t.Fatalf("conversation_key forwarded=%v, want %v", gotKey, tc.wantKey)
			}
			if row, ok := s.readLatestRequestLog(); !ok || row.Status != http.StatusOK {
				t.Fatalf("request_log=%+v found=%v, want 200", row, ok)
			}
		})
	}
}
