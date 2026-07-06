package localrig

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

// FakeProvider is one in-process fake provider. It listens on
// 127.0.0.1:<httpPort> for /v1/chat/completions and connects to the
// coordinator via WebSocket with the v1 hello handshake.
type FakeProvider struct {
	cfg           Provider
	httpPort      int
	coordProvURL  string
	providerToken string
	logger        func(string)

	server *http.Server
	// slots caps concurrent /v1/chat/completions handlers. Buffered
	// channel of size CapacitySlots — a full channel means every slot
	// is in use and we return 429 immediately.
	slots chan struct{}
	// inflight is the atomic-ish current-holder count used to compute
	// slots_free in the heartbeat frame. Protected by hitMu.
	hitMu    sync.Mutex
	inflight int
	hits     int

	stopOnce sync.Once
	stopped  chan struct{}
}

// fakeCompletionBody is the canned OpenAI-shaped body every fake
// provider returns. Copied from test/integration; the model_id is
// substituted per-provider at emit time.
const fakeCompletionBodyTemplate = `{
  "id":"chatcmpl-fake-localrig",
  "object":"chat.completion",
  "created":1780000000,
  "model":"%s",
  "usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20},
  "choices":[{"index":0,"message":{"role":"assistant","content":"hello from fake localrig provider"},"finish_reason":"stop"}]
}`

func newFakeProvider(cfg Provider, httpPort int, coordProvURL, providerToken string, logger func(string)) *FakeProvider {
	if logger == nil {
		logger = func(string) {}
	}
	slots := cfg.CapacitySlots
	if slots < 1 {
		slots = 1
	}
	return &FakeProvider{
		cfg:           cfg,
		httpPort:      httpPort,
		coordProvURL:  coordProvURL,
		providerToken: providerToken,
		logger:        logger,
		slots:         make(chan struct{}, slots),
		stopped:       make(chan struct{}),
	}
}

// start brings up the HTTP listener and WS half. Blocks only until the
// HTTP listener is bound; the WS half runs in a goroutine until ctx is
// cancelled or stop() is called.
func (p *FakeProvider) start(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", p.handleChat)
	mux.HandleFunc("/v1/models", p.handleModels)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	p.server = &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%d", p.httpPort),
		Handler: mux,
	}
	ln, err := net.Listen("tcp", p.server.Addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", p.server.Addr, err)
	}
	go func() {
		_ = p.server.Serve(ln)
	}()
	go p.runWS(ctx)
	return nil
}

func (p *FakeProvider) stop() {
	p.stopOnce.Do(func() {
		if p.server != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_ = p.server.Shutdown(ctx)
		}
		close(p.stopped)
	})
}

func (p *FakeProvider) handleChat(w http.ResponseWriter, r *http.Request) {
	// Try to acquire a slot without blocking.
	select {
	case p.slots <- struct{}{}:
	default:
		http.Error(w, "capacity exhausted", http.StatusTooManyRequests)
		return
	}
	defer func() { <-p.slots }()

	p.hitMu.Lock()
	p.inflight++
	p.hits++
	p.hitMu.Unlock()
	defer func() {
		p.hitMu.Lock()
		p.inflight--
		p.hitMu.Unlock()
	}()

	// Drain the request body so the client doesn't backpressure while
	// we sleep for TTFT.
	_, _ = io.Copy(io.Discard, r.Body)

	if p.cfg.TTFTMs > 0 {
		select {
		case <-time.After(time.Duration(p.cfg.TTFTMs) * time.Millisecond):
		case <-r.Context().Done():
			return
		}
	}

	body := fmt.Sprintf(fakeCompletionBodyTemplate, p.cfg.Model)

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Provider-Id", p.cfg.ID)
	w.Header().Set("X-MacProvider-Completion-Tokens", "12")

	// Pacing: if TokensPerSec > 0, spread the 12-token body's
	// completion_tokens payload over 12/TokensPerSec seconds by
	// writing the JSON body in whole then sleeping for the target
	// duration BEFORE returning. Since this is a non-streaming JSON
	// response, byte-splitting mid-body would break JSON parsers; the
	// caller-visible latency signal is still monotonic in TokensPerSec.
	// (Scenario 17 measures TTFT + total_ms, not per-token spacing.)
	if p.cfg.TokensPerSec > 0 {
		const tokens = 12.0
		dur := time.Duration(tokens / p.cfg.TokensPerSec * float64(time.Second))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(body))
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		select {
		case <-time.After(dur):
		case <-r.Context().Done():
		}
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(body))
}

func (p *FakeProvider) handleModels(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(fmt.Sprintf(`{"object":"list","data":[{"id":%q,"object":"model"}]}`, p.cfg.Model)))
}

// runWS dials the coordinator's /ws/provider endpoint, sends a v1 hello
// frame announcing endpoint_url mode, and heartbeats every 1s until
// ctx cancels. Any inbound frames are drained (coordinator can send
// state_update / drain_status but no inference frames in endpoint_url
// mode).
func (p *FakeProvider) runWS(ctx context.Context) {
	defer p.stop()

	u, err := url.Parse(p.coordProvURL)
	if err != nil {
		p.logger("ws parse coord url: " + err.Error())
		return
	}
	wsScheme := "ws"
	if u.Scheme == "https" {
		wsScheme = "wss"
	}
	wsURL := fmt.Sprintf("%s://%s/ws/provider", wsScheme, u.Host)

	header := http.Header{}
	if p.providerToken != "" {
		header.Set("Authorization", "Bearer "+p.providerToken)
	}
	dialer := gobwas.Dialer{
		Timeout: 5 * time.Second,
		Header:  gobwas.HandshakeHeaderHTTP(header),
	}

	var conn net.Conn
	dialDeadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(dialDeadline) {
		if ctx.Err() != nil {
			return
		}
		c, _, _, err := dialer.Dial(ctx, wsURL)
		if err == nil {
			conn = c
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if conn == nil {
		p.logger("ws dial failed within deadline")
		return
	}
	defer conn.Close()

	endpointURL := fmt.Sprintf("http://127.0.0.1:%d", p.httpPort)
	tps := p.cfg.TokensPerSec
	if tps == 0 {
		tps = 20.0
	}

	hello := map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             p.cfg.ID,
		"hostname":                "fake-localrig",
		"model_id":                p.cfg.Model,
		"model_params_b":          3.0,
		"ram_gb":                  16,
		"max_context_tokens":      8192,
		"max_concurrency":         p.cfg.CapacitySlots,
		"throughput_tps_estimate": tps,
		"binary_version":          "0.0.0-fake-localrig",
		"attestation":             nil,
		"endpoint_url":            endpointURL,
	}
	if err := writeJSONFrame(conn, hello); err != nil {
		p.logger("hello write: " + err.Error())
		return
	}
	// Read hello_ack — content doesn't matter; /poolz is the ready gate.
	if _, _, err := wsutil.ReadServerData(conn); err != nil {
		p.logger("read hello_ack: " + err.Error())
		return
	}

	// Inbound drain — the coordinator can push state_update / drain
	// frames; we ignore them but must consume or WS backpressures.
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		for {
			if _, _, err := wsutil.ReadServerData(conn); err != nil {
				return
			}
		}
	}()

	hbTick := time.NewTicker(1 * time.Second)
	defer hbTick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-readDone:
			return
		case <-hbTick.C:
			p.hitMu.Lock()
			slotsFree := p.cfg.CapacitySlots - p.inflight
			if slotsFree < 0 {
				slotsFree = 0
			}
			p.hitMu.Unlock()
			hb := map[string]any{
				"type":                       "heartbeat",
				"status":                     "ready",
				"model_id":                   p.cfg.Model,
				"model_params_b":             3.0,
				"ram_gb":                     16,
				"max_context_tokens":         8192,
				"max_concurrency":            p.cfg.CapacitySlots,
				"slots_free":                 slotsFree,
				"slots_total":                p.cfg.CapacitySlots,
				"throughput_tps_estimate":    tps,
				"requests_served_since_last": 0,
				"avg_latency_ms_since_last":  0.0,
				"throughput_tps_since_last":  0.0,
			}
			if err := writeJSONFrame(conn, hb); err != nil {
				return
			}
		}
	}
}

func writeJSONFrame(conn net.Conn, payload map[string]any) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	// Client side must mask outbound frames — wsutil.WriteClientText
	// does the right thing.
	return wsutil.WriteClientText(conn, b)
}

// Hits returns the number of /v1/chat/completions requests this fake
// has served. Convenience for tests that want to assert routing
// distribution.
func (p *FakeProvider) Hits() int {
	p.hitMu.Lock()
	defer p.hitMu.Unlock()
	return p.hits
}

