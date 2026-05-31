// mockprovider: a standalone in-process mock of a Phase 3 provider binary.
// Connects to the coordinator over WS, behaves like a Tier-1 provider, and
// also serves a local OpenAI-compatible HTTP endpoint that the coordinator's
// buyer server can proxy to.
//
// Used by phase4-coordinator/scripts/run-local-pool.sh and the AC-2/3/6 tests.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

// hello mirrors internal/ws/messages.go Hello — kept in lock-step manually
// because tools/ cannot import internal/.
type hello struct {
	Type                  string          `json:"type"`
	Version               int             `json:"version"`
	Tier                  int             `json:"tier"`
	ProviderID            string          `json:"provider_id"`
	Hostname              string          `json:"hostname"`
	ModelID               string          `json:"model_id"`
	ModelParamsB          float64         `json:"model_params_b"`
	RAMGB                 int             `json:"ram_gb"`
	MaxContextTokens      int             `json:"max_context_tokens"`
	MaxConcurrency        int             `json:"max_concurrency"`
	ThroughputTPSEstimate float64         `json:"throughput_tps_estimate"`
	BinaryVersion         string          `json:"binary_version"`
	Attestation           json.RawMessage `json:"attestation"`
	EndpointURL           *string         `json:"endpoint_url,omitempty"`
}

type helloAck struct {
	Type               string `json:"type"`
	CoordinatorVersion int    `json:"coordinator_version"`
	AssignedID         string `json:"assigned_id"`
	HeartbeatIntervalS int    `json:"heartbeat_interval_s"`
	Tier               string `json:"tier"`
}

type heartbeat struct {
	Type                    string  `json:"type"`
	Status                  string  `json:"status"`
	ModelID                 string  `json:"model_id"`
	ModelParamsB            float64 `json:"model_params_b"`
	RAMGB                   int     `json:"ram_gb"`
	MaxContextTokens        int     `json:"max_context_tokens"`
	MaxConcurrency          int     `json:"max_concurrency"`
	SlotsFree               int     `json:"slots_free"`
	SlotsTotal              int     `json:"slots_total"`
	ThroughputTPSEstimate   float64 `json:"throughput_tps_estimate"`
	RequestsServedSinceLast int     `json:"requests_served_since_last"`
	AvgLatencyMSSinceLast   float64 `json:"avg_latency_ms_since_last"`
	ThroughputTPSSinceLast  float64 `json:"throughput_tps_since_last"`
}

type stateUpdate struct {
	Type            string          `json:"type"`
	State           string          `json:"state"`
	Reason          string          `json:"reason"`
	Since           string          `json:"since"`
	MetricsSnapshot metricsSnapshot `json:"metrics_snapshot"`
}

type metricsSnapshot struct {
	SlotsFree  *int `json:"slots_free"`
	SlotsTotal *int `json:"slots_total"`
}

type preflightAck struct {
	Type             string `json:"type"`
	RequestID        string `json:"request_id"`
	Accepted         bool   `json:"accepted"`
	EstimatedWaitMS  int    `json:"estimated_wait_ms"`
	Reason           string `json:"reason"`
	MaxContextTokens int    `json:"max_context_tokens"`
}

type drainStatus struct {
	Type                  string `json:"type"`
	Phase                 string `json:"phase"`
	InflightRequests      int    `json:"inflight_requests"`
	EstimatedDrainSeconds int    `json:"estimated_drain_seconds"`
}

type inferenceRequest struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Stream    bool   `json:"stream"`
	Body      string `json:"body"`
}

type inferenceResponseChunk struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Seq       int    `json:"seq"`
	Data      string `json:"data"`
}

type inferenceResponseEnd struct {
	Type       string          `json:"type"`
	RequestID  string          `json:"request_id"`
	Status     string          `json:"status"`
	ChunksSent int             `json:"chunks_sent"`
	Error      string          `json:"error,omitempty"`
	Usage      json.RawMessage `json:"usage,omitempty"` // required by Phase 7 warmup gate
}

type cancelRequest struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Reason    string `json:"reason"`
}

type config struct {
	coordURL        string
	providerID      string
	model           string
	ramGB           int
	maxContext      int
	maxConcurrency  int
	slots           int
	httpPort        int
	streamDelayMS   int
	rejectPreflight string
	rejectNAK       bool
	omitEndpointURL bool
	endpointURL     string
	drainDelayS     int
	hbOverride      int
}

func parseFlags() config {
	var c config
	flag.StringVar(&c.coordURL, "coord-url", "ws://127.0.0.1:8444/ws/provider", "coordinator websocket URL")
	flag.StringVar(&c.providerID, "provider-id", "mock-A", "provider_id reported on hello")
	flag.StringVar(&c.model, "model", "mlx-community/Qwen2.5-7B-Instruct-4bit", "advertised model_id")
	flag.IntVar(&c.ramGB, "ram-gb", 16, "ram_gb")
	flag.IntVar(&c.maxContext, "max-context", 8192, "max_context_tokens")
	flag.IntVar(&c.maxConcurrency, "max-concurrency", 1, "max_concurrency")
	flag.IntVar(&c.slots, "slots", 1, "slots_free/slots_total reported in heartbeats")
	flag.IntVar(&c.httpPort, "http-port", 9001, "HTTP port for the OpenAI-compatible endpoint")
	flag.IntVar(&c.streamDelayMS, "stream-delay-ms", 100, "delay between SSE tokens in ms")
	flag.StringVar(&c.rejectPreflight, "reject-preflight", "", "if non-empty, reply preflight_ack accepted=false reason=<flag>")
	flag.BoolVar(&c.rejectNAK, "reject-nak", false, "reply nak unknown_message_type to inference_request")
	flag.BoolVar(&c.omitEndpointURL, "omit-endpoint-url", false, "omit endpoint_url from hello to request WS-tunneled mode")
	flag.StringVar(&c.endpointURL, "endpoint-url", "", "endpoint_url to advertise in hello; default uses http-port unless omitted")
	flag.IntVar(&c.drainDelayS, "drain-delay-s", 2, "delay between drain phases in seconds")
	flag.IntVar(&c.hbOverride, "hb", 0, "heartbeat interval override (seconds); 0 = use coordinator value")
	flag.Parse()
	return c
}

// drainController shares drain state between the WS goroutine and the HTTP
// handlers so we can refuse new streams once drain has started.
type drainController struct {
	mu       sync.Mutex
	draining bool
	inflight int32
}

func (d *drainController) startDraining() {
	d.mu.Lock()
	d.draining = true
	d.mu.Unlock()
}

func (d *drainController) isDraining() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.draining
}

func (d *drainController) incInflight() { atomic.AddInt32(&d.inflight, 1) }
func (d *drainController) decInflight() { atomic.AddInt32(&d.inflight, -1) }
func (d *drainController) inflightCount() int {
	return int(atomic.LoadInt32(&d.inflight))
}

func main() {
	cfg := parseFlags()
	logger := log.New(os.Stdout, fmt.Sprintf("[mock %s] ", cfg.providerID), log.LstdFlags|log.Lmicroseconds)

	drainer := &drainController{}

	// Start local HTTP server (the coordinator buyer-side proxies here).
	httpSrv := startHTTPServer(cfg, logger, drainer)

	// Connect to coordinator WS. If it fails, exit non-zero so the bootstrap
	// script surfaces the problem.
	if err := runWS(cfg, logger, drainer); err != nil {
		logger.Printf("ws loop exited: %v", err)
	}

	// On WS exit (drain complete or coordinator gone), tear down HTTP too.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(ctx)
	logger.Printf("mockprovider exiting cleanly")
}

func runWS(cfg config, logger *log.Logger, drainer *drainController) error {
	ctx := context.Background()
	conn, _, _, err := gobwas.Dial(ctx, cfg.coordURL)
	if err != nil {
		return fmt.Errorf("dial %s: %w", cfg.coordURL, err)
	}
	defer conn.Close()

	hostname, _ := os.Hostname()
	h := hello{
		Type:                  "hello",
		Version:               1,
		Tier:                  1,
		ProviderID:            cfg.providerID,
		Hostname:              hostname,
		ModelID:               cfg.model,
		ModelParamsB:          7.0,
		RAMGB:                 cfg.ramGB,
		MaxContextTokens:      cfg.maxContext,
		MaxConcurrency:        cfg.maxConcurrency,
		ThroughputTPSEstimate: 30.0,
		BinaryVersion:         "mockprovider-0.1.0",
		Attestation:           json.RawMessage(`{}`),
	}
	if !cfg.omitEndpointURL {
		endpoint := cfg.endpointURL
		if endpoint == "" {
			endpoint = fmt.Sprintf("http://127.0.0.1:%d", cfg.httpPort)
		}
		h.EndpointURL = &endpoint
	}
	helloBytes, _ := json.Marshal(h)
	if err := wsutil.WriteClientText(conn, helloBytes); err != nil {
		return fmt.Errorf("write hello: %w", err)
	}

	// Read hello_ack.
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		return fmt.Errorf("read hello_ack: %w", err)
	}
	if op != gobwas.OpText {
		return fmt.Errorf("expected text hello_ack, got op=%d", op)
	}
	var ack helloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		return fmt.Errorf("parse hello_ack: %w", err)
	}
	if ack.Type != "hello_ack" {
		return fmt.Errorf("expected hello_ack, got %q", ack.Type)
	}
	logger.Printf("hello_ack received assigned_id=%s hb=%ds", ack.AssignedID, ack.HeartbeatIntervalS)

	// Send an explicit state_update so the coordinator marks us ready/routable
	// independent of the initial heartbeat cadence.
	slots := cfg.slots
	su := stateUpdate{
		Type:   "state_update",
		State:  "ready",
		Reason: "mock_provider_online",
		Since:  time.Now().UTC().Format(time.RFC3339),
		MetricsSnapshot: metricsSnapshot{
			SlotsFree:  &slots,
			SlotsTotal: &slots,
		},
	}
	suBytes, _ := json.Marshal(su)
	if err := wsutil.WriteClientText(conn, suBytes); err != nil {
		return fmt.Errorf("write state_update: %w", err)
	}

	// Heartbeat goroutine.
	hbInterval := time.Duration(ack.HeartbeatIntervalS) * time.Second
	if cfg.hbOverride > 0 {
		hbInterval = time.Duration(cfg.hbOverride) * time.Second
	}
	if hbInterval <= 0 {
		hbInterval = 30 * time.Second
	}
	// Use a noticeably-shorter cadence than the coordinator's default 30s so
	// the pool registers slot counts quickly during scripted tests. The
	// coordinator only warns on stale (>1.5x) gaps; faster is fine.
	if hbInterval > 5*time.Second {
		hbInterval = 5 * time.Second
	}

	stopHB := make(chan struct{})
	var writeMu sync.Mutex
	writeText := func(b []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return wsutil.WriteClientText(conn, b)
	}
	var active sync.Map
	go func() {
		t := time.NewTicker(hbInterval)
		defer t.Stop()
		for {
			select {
			case <-stopHB:
				return
			case <-t.C:
				hb := heartbeat{
					Type:                  "heartbeat",
					Status:                "ready",
					ModelID:               cfg.model,
					ModelParamsB:          7.0,
					RAMGB:                 cfg.ramGB,
					MaxContextTokens:      cfg.maxContext,
					MaxConcurrency:        cfg.maxConcurrency,
					SlotsFree:             cfg.slots,
					SlotsTotal:            cfg.slots,
					ThroughputTPSEstimate: 30.0,
				}
				if drainer.isDraining() {
					hb.Status = "draining"
					hb.SlotsFree = 0
				}
				b, _ := json.Marshal(hb)
				if err := writeText(b); err != nil {
					logger.Printf("heartbeat write failed: %v", err)
					return
				}
			}
		}
	}()

	// Initial immediate heartbeat (don't wait for first tick).
	hb0 := heartbeat{
		Type:                  "heartbeat",
		Status:                "ready",
		ModelID:               cfg.model,
		ModelParamsB:          7.0,
		RAMGB:                 cfg.ramGB,
		MaxContextTokens:      cfg.maxContext,
		MaxConcurrency:        cfg.maxConcurrency,
		SlotsFree:             cfg.slots,
		SlotsTotal:            cfg.slots,
		ThroughputTPSEstimate: 30.0,
	}
	hb0Bytes, _ := json.Marshal(hb0)
	_ = writeText(hb0Bytes)

	// SIGINT/SIGTERM: send drain_status complete then exit cleanly.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		logger.Printf("signal received; emitting drain_status sequence")
		runDrain(cfg, logger, drainer, writeText)
		close(stopHB)
		_ = conn.Close()
	}()

	// Read loop.
	for {
		payload, op, err := wsutil.ReadServerData(conn)
		if err != nil {
			close(stopHB)
			return fmt.Errorf("ws read: %w", err)
		}
		if op != gobwas.OpText {
			continue
		}
		handleInbound(cfg, logger, drainer, writeText, &active, payload, func() {
			close(stopHB)
			_ = conn.Close()
		})
	}
}

func handleInbound(cfg config, logger *log.Logger, drainer *drainController,
	writeText func([]byte) error, active *sync.Map, payload []byte, shutdown func()) {

	var envelope struct {
		Type      string `json:"type"`
		RequestID string `json:"request_id"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		logger.Printf("invalid inbound json: %v", err)
		return
	}
	switch envelope.Type {
	case "preflight":
		ack := preflightAck{
			Type:             "preflight_ack",
			RequestID:        envelope.RequestID,
			Accepted:         true,
			EstimatedWaitMS:  0,
			MaxContextTokens: cfg.maxContext,
		}
		if cfg.rejectPreflight != "" {
			ack.Accepted = false
			ack.Reason = cfg.rejectPreflight
		}
		b, _ := json.Marshal(ack)
		if err := writeText(b); err != nil {
			logger.Printf("preflight_ack write failed: %v", err)
		} else {
			logger.Printf("preflight_ack request_id=%s accepted=%v", envelope.RequestID, ack.Accepted)
		}
	case "warm_up":
		logger.Printf("warm_up received; sending fresh heartbeat")
		hb := heartbeat{
			Type:                  "heartbeat",
			Status:                "ready",
			ModelID:               cfg.model,
			ModelParamsB:          7.0,
			RAMGB:                 cfg.ramGB,
			MaxContextTokens:      cfg.maxContext,
			MaxConcurrency:        cfg.maxConcurrency,
			SlotsFree:             cfg.slots,
			SlotsTotal:            cfg.slots,
			ThroughputTPSEstimate: 30.0,
		}
		b, _ := json.Marshal(hb)
		_ = writeText(b)
	case "drain":
		logger.Printf("drain received from coordinator")
		go func() {
			runDrain(cfg, logger, drainer, writeText)
			shutdown()
		}()
	case "inference_request":
		if cfg.rejectNAK {
			b, _ := json.Marshal(map[string]any{
				"type":        "nak",
				"in_reply_to": envelope.RequestID,
				"error": map[string]any{
					"code":    "unknown_message_type",
					"message": "mock reject-nak",
				},
			})
			_ = writeText(b)
			return
		}
		var req inferenceRequest
		if err := json.Unmarshal(payload, &req); err != nil {
			logger.Printf("invalid inference_request: %v", err)
			return
		}
		cancel := make(chan struct{})
		active.Store(req.RequestID, cancel)
		go func() {
			defer active.Delete(req.RequestID)
			runWSInference(cfg, logger, drainer, writeText, req, cancel)
		}()
	case "cancel_request":
		var req cancelRequest
		if err := json.Unmarshal(payload, &req); err != nil {
			logger.Printf("invalid cancel_request: %v", err)
			return
		}
		if v, ok := active.Load(req.RequestID); ok {
			close(v.(chan struct{}))
			active.Delete(req.RequestID)
		}
	default:
		logger.Printf("unknown inbound type=%q", envelope.Type)
	}
}

func runWSInference(cfg config, logger *log.Logger, drainer *drainController, writeText func([]byte) error, req inferenceRequest, cancel <-chan struct{}) {
	drainer.incInflight()
	defer drainer.decInflight()
	if req.Stream {
		chunks := []string{"hello", " from", " ", cfg.providerID, " ", "with", " ws", " streaming", "."}
		for i, chunk := range chunks {
			select {
			case <-cancel:
				sendInferenceEnd(writeText, req.RequestID, "cancelled", i, "", nil)
				return
			default:
			}
			event := map[string]any{
				"id":      fmt.Sprintf("chatcmpl-%s-%d", cfg.providerID, time.Now().UnixNano()),
				"object":  "chat.completion.chunk",
				"created": time.Now().Unix(),
				"model":   cfg.model,
				"choices": []map[string]any{{"index": 0, "delta": map[string]any{"content": chunk}, "finish_reason": nil}},
			}
			b, _ := json.Marshal(event)
			frame, _ := json.Marshal(inferenceResponseChunk{Type: "inference_response_chunk", RequestID: req.RequestID, Seq: i, Data: "data: " + string(b) + "\n\n"})
			if err := writeText(frame); err != nil {
				logger.Printf("inference chunk write failed: %v", err)
				return
			}
			time.Sleep(time.Duration(cfg.streamDelayMS) * time.Millisecond)
		}
		done, _ := json.Marshal(inferenceResponseChunk{Type: "inference_response_chunk", RequestID: req.RequestID, Seq: len(chunks), Data: "data: [DONE]\n\n"})
		_ = writeText(done)
		sendInferenceEnd(writeText, req.RequestID, "complete", len(chunks)+1, "", mockUsage)
		return
	}
	var chat struct {
		Model string `json:"model"`
	}
	_ = json.Unmarshal([]byte(req.Body), &chat)
	resp := map[string]any{
		"id":      fmt.Sprintf("chatcmpl-%s-%d", cfg.providerID, time.Now().UnixNano()),
		"object":  "chat.completion",
		"created": time.Now().Unix(),
		"model":   chat.Model,
		"choices": []map[string]any{{"index": 0, "message": map[string]any{"role": "assistant", "content": "hello from " + cfg.providerID}, "finish_reason": "stop"}},
		"usage":   map[string]any{"prompt_tokens": len(req.Body) / 4, "completion_tokens": 4, "total_tokens": len(req.Body)/4 + 4},
	}
	b, _ := json.Marshal(resp)
	chunk, _ := json.Marshal(inferenceResponseChunk{Type: "inference_response_chunk", RequestID: req.RequestID, Seq: 0, Data: string(b)})
	if err := writeText(chunk); err != nil {
		logger.Printf("inference response write failed: %v", err)
		return
	}
	sendInferenceEnd(writeText, req.RequestID, "complete", 1, "", mockUsage)
}

func sendInferenceEnd(writeText func([]byte) error, requestID, status string, chunks int, msg string, usage json.RawMessage) {
	end := inferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: status, ChunksSent: chunks, Error: msg, Usage: usage}
	b, _ := json.Marshal(end)
	_ = writeText(b)
}

var mockUsage = json.RawMessage(`{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}`)

func runDrain(cfg config, logger *log.Logger, drainer *drainController,
	writeText func([]byte) error) {

	drainer.startDraining()
	delay := time.Duration(cfg.drainDelayS) * time.Second
	if delay <= 0 {
		delay = 1 * time.Second
	}

	send := func(phase string) {
		ds := drainStatus{
			Type:                  "drain_status",
			Phase:                 phase,
			InflightRequests:      drainer.inflightCount(),
			EstimatedDrainSeconds: cfg.drainDelayS,
		}
		b, _ := json.Marshal(ds)
		if err := writeText(b); err != nil {
			logger.Printf("drain_status %s write failed: %v", phase, err)
			return
		}
		logger.Printf("drain_status phase=%s inflight=%d", phase, ds.InflightRequests)
	}

	send("starting")
	time.Sleep(delay / 2)
	send("in_progress")

	// Wait for inflight requests to finish (capped at drain delay).
	deadline := time.Now().Add(delay + 2*time.Second)
	for time.Now().Before(deadline) && drainer.inflightCount() > 0 {
		time.Sleep(100 * time.Millisecond)
	}
	send("complete")
	// Give the coordinator a beat to register the close.
	time.Sleep(200 * time.Millisecond)
}

// -----------------------------------------------------------------------------
// HTTP side: OpenAI-compatible /v1/models and /v1/chat/completions.
// -----------------------------------------------------------------------------

func startHTTPServer(cfg config, logger *log.Logger, drainer *drainController) *http.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		resp := map[string]any{
			"object": "list",
			"data": []map[string]any{
				{
					"id":       cfg.model,
					"object":   "model",
					"owned_by": "macprovider",
				},
			},
		}
		_ = json.NewEncoder(w).Encode(resp)
	})
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		handleChat(cfg, logger, drainer, w, r)
	})

	addr := fmt.Sprintf("127.0.0.1:%d", cfg.httpPort)
	srv := &http.Server{Addr: addr, Handler: mux}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		logger.Fatalf("listen %s: %v", addr, err)
	}
	go func() {
		logger.Printf("HTTP listening on %s", addr)
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			logger.Printf("http serve: %v", err)
		}
	}()
	return srv
}

func handleChat(cfg config, logger *log.Logger, drainer *drainController,
	w http.ResponseWriter, r *http.Request) {

	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	var req struct {
		Model     string `json:"model"`
		Messages  []any  `json:"messages"`
		Stream    bool   `json:"stream"`
		MaxTokens int    `json:"max_tokens"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	drainer.incInflight()
	defer drainer.decInflight()

	promptTokens := len(body) / 4
	if promptTokens < 1 {
		promptTokens = 1
	}
	content := fmt.Sprintf("hello from %s", cfg.providerID)

	if req.Stream {
		streamChat(cfg, logger, w, content, promptTokens)
		return
	}

	resp := map[string]any{
		"id":      fmt.Sprintf("chatcmpl-%s-%d", cfg.providerID, time.Now().UnixNano()),
		"object":  "chat.completion",
		"created": time.Now().Unix(),
		"model":   req.Model,
		"choices": []map[string]any{
			{
				"index": 0,
				"message": map[string]any{
					"role":    "assistant",
					"content": content,
				},
				"finish_reason": "stop",
			},
		},
		"usage": map[string]any{
			"prompt_tokens":     promptTokens,
			"completion_tokens": 10,
			"total_tokens":      promptTokens + 10,
		},
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func streamChat(cfg config, logger *log.Logger, w http.ResponseWriter, content string, promptTokens int) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)

	chunks := []string{"hello", " from", " ", cfg.providerID, " ", "with", " streaming", " ", "tokens", "."}
	createdAt := time.Now().Unix()
	id := fmt.Sprintf("chatcmpl-%s-%d", cfg.providerID, time.Now().UnixNano())
	delay := time.Duration(cfg.streamDelayMS) * time.Millisecond

	for i, chunk := range chunks {
		event := map[string]any{
			"id":      id,
			"object":  "chat.completion.chunk",
			"created": createdAt,
			"model":   cfg.model,
			"choices": []map[string]any{
				{
					"index": 0,
					"delta": map[string]any{
						"role":    "assistant",
						"content": chunk,
					},
					"finish_reason": nil,
				},
			},
		}
		b, _ := json.Marshal(event)
		if _, err := fmt.Fprintf(w, "data: %s\n\n", b); err != nil {
			logger.Printf("stream write failed at chunk %d: %v", i, err)
			return
		}
		if flusher != nil {
			flusher.Flush()
		}
		if delay > 0 {
			time.Sleep(delay)
		}
	}

	final := map[string]any{
		"id":      id,
		"object":  "chat.completion.chunk",
		"created": createdAt,
		"model":   cfg.model,
		"choices": []map[string]any{
			{
				"index":         0,
				"delta":         map[string]any{},
				"finish_reason": "stop",
			},
		},
		"usage": map[string]any{
			"prompt_tokens":     promptTokens,
			"completion_tokens": len(chunks),
			"total_tokens":      promptTokens + len(chunks),
		},
	}
	b, _ := json.Marshal(final)
	_, _ = fmt.Fprintf(w, "data: %s\n\n", b)
	_, _ = fmt.Fprintf(w, "data: [DONE]\n\n")
	if flusher != nil {
		flusher.Flush()
	}
}
