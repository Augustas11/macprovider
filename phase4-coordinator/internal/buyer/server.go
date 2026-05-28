package buyer

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

type Server struct {
	pool               *pool.Registry
	log                zerolog.Logger
	createdAt          int64
	preflight          PreflightFunc
	preflightThreshold int
	preflightTimeout   time.Duration
	recoveryBackoff    time.Duration
	recoveryMaxRetries int
	recoveryProbe      bool
	relay              RelayFunc
	admission          *providerws.AdmissionManager
	requestTimeout     time.Duration
	provisionalWeight  float64
	recovering         sync.Map
}

type PreflightResult struct {
	Accepted bool
	Reason   string
}

type PreflightFunc func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (PreflightResult, bool, error)
type RelayFunc func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error)

type Option func(*Server)

type wsForwardResult string

const (
	wsForwardComplete    wsForwardResult = "complete"
	wsForwardFailed      wsForwardResult = "failed"
	wsForwardQueueFull   wsForwardResult = "queue_full"
	wsForwardTimedOut    wsForwardResult = "timed_out"
	wsForwardCancelled   wsForwardResult = "cancelled"
	wsForwardUnavailable wsForwardResult = "unavailable"
)

func WithPreflight(fn PreflightFunc) Option {
	return func(s *Server) {
		s.preflight = fn
	}
}

func WithPreflightConfig(thresholdTokens int, timeout time.Duration) Option {
	return func(s *Server) {
		if thresholdTokens > 0 {
			s.preflightThreshold = thresholdTokens
		}
		if timeout > 0 {
			s.preflightTimeout = timeout
		}
	}
}

func WithRecoveryConfig(backoff time.Duration, maxRetries int, enabled bool) Option {
	return func(s *Server) {
		if backoff > 0 {
			s.recoveryBackoff = backoff
		}
		if maxRetries > 0 {
			s.recoveryMaxRetries = maxRetries
		}
		s.recoveryProbe = enabled
	}
}

func WithRelay(fn RelayFunc, timeout time.Duration) Option {
	return func(s *Server) {
		s.relay = fn
		if timeout > 0 {
			s.requestTimeout = timeout
		}
	}
}

func WithAdmission(admission *providerws.AdmissionManager, provisionalWeight float64) Option {
	return func(s *Server) {
		s.admission = admission
		if provisionalWeight > 0 {
			s.provisionalWeight = provisionalWeight
		}
	}
}

func NewServer(registry *pool.Registry, logger zerolog.Logger, startedAt time.Time, opts ...Option) *Server {
	s := &Server{
		pool:               registry,
		log:                logger,
		createdAt:          startedAt.Unix(),
		preflightThreshold: 4096,
		preflightTimeout:   5 * time.Second,
		recoveryBackoff:    30 * time.Second,
		recoveryMaxRetries: 3,
		recoveryProbe:      true,
		requestTimeout:     300 * time.Second,
		provisionalWeight:  0.3,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

func (s *Server) Handler() http.Handler {
	r := chi.NewRouter()
	r.Get("/v1/models", s.handleModels)
	r.Post("/v1/chat/completions", s.handleChatCompletions)
	return r
}

type modelsResponse struct {
	Object string       `json:"object"`
	Data   []modelEntry `json:"data"`
}

type modelEntry struct {
	ID               string `json:"id"`
	Object           string `json:"object"`
	Created          int64  `json:"created"`
	OwnedBy          string `json:"owned_by"`
	ProviderCount    int    `json:"provider_count"`
	MaxContextTokens int    `json:"max_context_tokens"`
	TotalSlots       int    `json:"total_slots"`
}

func (s *Server) handleModels(w http.ResponseWriter, r *http.Request) {
	models := map[string]modelEntry{}
	for _, p := range s.pool.Snapshot() {
		if p.State != pool.StateReady {
			continue
		}
		entry := models[p.ModelID]
		if entry.ID == "" {
			entry = modelEntry{
				ID:      p.ModelID,
				Object:  "model",
				Created: s.createdAt,
				OwnedBy: "macprovider",
			}
		}
		entry.ProviderCount++
		if p.MaxContextTokens > entry.MaxContextTokens {
			entry.MaxContextTokens = p.MaxContextTokens
		}
		entry.TotalSlots += p.SlotsTotal
		models[p.ModelID] = entry
	}

	data := make([]modelEntry, 0, len(models))
	for _, entry := range models {
		data = append(data, entry)
	}
	sort.Slice(data, func(i, j int) bool {
		return data[i].ID < data[j].ID
	})

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(modelsResponse{Object: "list", Data: data}); err != nil {
		s.log.Warn().Err(err).Msg("write models response failed")
	}
}

type chatRequest struct {
	Model    string        `json:"model"`
	Messages []chatMessage `json:"messages"`
	Stream   bool          `json:"stream"`
	raw      json.RawMessage
}

type chatMessage struct {
	Role       string          `json:"role"`
	Content    json.RawMessage `json:"content"`
	ToolCallID string          `json:"tool_call_id"`
	ToolCalls  json.RawMessage `json:"tool_calls"`
}

func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	requestID := uuid.NewString()
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "Could not read request body")
		return
	}
	req, status, code, msg := validateChatRequest(body)
	if status != 0 {
		writeError(w, status, code, msg)
		return
	}
	if !s.pool.ModelKnown(req.Model) {
		writeError(w, http.StatusNotFound, "model_not_found", "No provider has advertised model "+req.Model)
		return
	}

	provider, routeErr := s.selectProvider(requestID, req, r.Header)
	if routeErr != nil {
		writeError(w, routeErr.status, routeErr.code, routeErr.message)
		return
	}
	if req.Stream {
		if provider.IsWSTunneled() {
			s.forwardWS(w, r, requestID, body, provider, true)
		} else {
			s.forwardStreaming(w, r, requestID, body, provider)
		}
		return
	}
	if provider.IsWSTunneled() {
		excluded := map[string]struct{}{}
		for {
			result := s.forwardWS(w, r, requestID, body, provider, false)
			if result != wsForwardQueueFull {
				return
			}
			s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateBusy)
			excluded[routeKey(provider)] = struct{}{}
			provider, routeErr = s.selectProviderExcluding(requestID, req, r.Header, excluded)
			if routeErr != nil {
				writeError(w, routeErr.status, routeErr.code, routeErr.message)
				return
			}
			if !provider.IsWSTunneled() {
				break
			}
		}
	}
	upstreamURL := provider.EndpointURL + "/v1/chat/completions"
	upReq, err := http.NewRequestWithContext(r.Context(), http.MethodPost, upstreamURL, bytes.NewReader(body))
	if err != nil {
		writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
		return
	}
	upReq.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(upReq)
	if err != nil {
		s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("provider request failed")
		writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		s.log.Warn().Int("status", resp.StatusCode).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("provider returned non-200")
		s.handleProviderFailure(provider, resp.StatusCode)
		writeError(w, http.StatusBadGateway, "provider_error", "Selected provider failed; buyer should retry")
		return
	}

	w.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
	if w.Header().Get("Content-Type") == "" {
		w.Header().Set("Content-Type", "application/json")
	}
	w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
	w.Header().Set("X-MacProvider-Route", provider.AssignedID)
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, resp.Body)
}

func (s *Server) forwardWS(w http.ResponseWriter, r *http.Request, requestID string, body []byte, provider pool.Provider, stream bool) wsForwardResult {
	if s.relay == nil {
		writeError(w, http.StatusServiceUnavailable, "provider_unavailable", "Selected provider is not reachable")
		return wsForwardUnavailable
	}
	reserved := false
	if s.admission != nil {
		if !s.admission.TryReserveRequest(provider) {
			writeError(w, http.StatusTooManyRequests, "provisional_quota_exceeded", "Selected provisional provider is over request quota")
			return wsForwardFailed
		}
		reserved = provider.Tier == pool.TierProvisional
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.requestTimeout)
	defer cancel()
	relay, err := s.relay(ctx, provider, requestID, body, stream)
	if err != nil {
		if reserved {
			s.admission.RefundRequest(provider)
		}
		if errors.Is(err, providerws.ErrRelayBackpressure) || errors.Is(err, providerws.ErrRelayNAKFallback) {
			writeError(w, http.StatusServiceUnavailable, "provider_unavailable", "Selected provider is not reachable")
			return wsForwardUnavailable
		}
		writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
		return wsForwardFailed
	}
	if stream {
		s.forwardWSStreaming(w, r, requestID, provider, relay)
		return wsForwardComplete
	}
	result := s.forwardWSNonStreaming(w, requestID, provider, relay)
	if reserved && result == wsForwardQueueFull {
		s.admission.RefundRequest(provider)
	}
	return result
}

func (s *Server) forwardWSNonStreaming(w http.ResponseWriter, requestID string, provider pool.Provider, relay *providerws.RelayStream) wsForwardResult {
	var body bytes.Buffer
	chunks := relay.Chunks
	for {
		select {
		case chunk, ok := <-chunks:
			if ok {
				body.WriteString(chunk.Data)
			} else {
				chunks = nil
			}
		case end := <-relay.Done:
			for chunks != nil {
				select {
				case chunk, ok := <-chunks:
					if !ok {
						chunks = nil
						continue
					}
					body.WriteString(chunk.Data)
				default:
					chunks = nil
				}
			}
			if end.Status != "complete" {
				if end.Status == "error_queue_full" {
					return wsForwardQueueFull
				}
				writeWSEndError(w, end)
				return wsForwardFailed
			}
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
			w.Header().Set("X-MacProvider-Route", provider.AssignedID)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(body.Bytes())
			return wsForwardComplete
		case err := <-relay.Errors:
			s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("ws relay failed")
			if errors.Is(err, providerws.ErrRelayTimeout) {
				writeError(w, http.StatusGatewayTimeout, "provider_timeout", "Selected provider timed out; buyer should retry")
				return wsForwardTimedOut
			} else if errors.Is(err, providerws.ErrRelayNAKFallback) {
				writeError(w, http.StatusServiceUnavailable, "provider_unavailable", "Selected provider is not reachable")
			} else {
				writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
			}
			return wsForwardFailed
		}
	}
}

func (s *Server) forwardWSStreaming(w http.ResponseWriter, r *http.Request, requestID string, provider pool.Provider, relay *providerws.RelayStream) {
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
	w.Header().Set("X-MacProvider-Route", provider.AssignedID)
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	chunks := relay.Chunks
	for {
		select {
		case <-r.Context().Done():
			relay.Cancel("buyer_disconnected")
			return
		case chunk, ok := <-chunks:
			if !ok {
				chunks = nil
				continue
			}
			if _, err := w.Write([]byte(chunk.Data)); err != nil {
				relay.Cancel("buyer_disconnected")
				s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("buyer ws stream write failed")
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		case end := <-relay.Done:
			if end.Status != "complete" && end.Status != "cancelled" {
				_, _ = w.Write([]byte("data: {\"error\":{\"message\":\"Provider failed during streaming\",\"type\":\"server_error\",\"code\":\"provider_error\"}}\n\n"))
				_, _ = w.Write([]byte("data: [DONE]\n\n"))
			}
			if flusher != nil {
				flusher.Flush()
			}
			return
		case err := <-relay.Errors:
			s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("ws streaming relay failed")
			_, _ = w.Write([]byte("data: {\"error\":{\"message\":\"Provider failed during streaming\",\"type\":\"server_error\",\"code\":\"provider_error\"}}\n\n"))
			_, _ = w.Write([]byte("data: [DONE]\n\n"))
			if flusher != nil {
				flusher.Flush()
			}
			return
		}
	}
}

func (s *Server) forwardStreaming(w http.ResponseWriter, r *http.Request, requestID string, body []byte, provider pool.Provider) {
	upstreamURL := provider.EndpointURL + "/v1/chat/completions"
	upReq, err := http.NewRequestWithContext(r.Context(), http.MethodPost, upstreamURL, bytes.NewReader(body))
	if err != nil {
		writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
		return
	}
	upReq.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(upReq)
	if err != nil {
		s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider request failed")
		writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		s.log.Warn().Int("status", resp.StatusCode).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider returned non-200")
		s.handleProviderFailure(provider, resp.StatusCode)
		writeError(w, http.StatusBadGateway, "provider_error", "Selected provider failed; buyer should retry")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
	w.Header().Set("X-MacProvider-Route", provider.AssignedID)
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)

	reader := bufio.NewReader(resp.Body)
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			if _, writeErr := w.Write(line); writeErr != nil {
				s.log.Warn().Err(writeErr).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("buyer streaming write failed")
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err == nil {
			continue
		}
		if err == io.EOF {
			return
		}
		s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("provider disconnected during streaming")
		_, _ = w.Write([]byte("data: {\"error\":{\"message\":\"Provider disconnected during streaming\",\"type\":\"server_error\",\"code\":\"provider_disconnect\"}}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
		if flusher != nil {
			flusher.Flush()
		}
		return
	}
}

func validateChatRequest(body []byte) (chatRequest, int, string, string) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return chatRequest{}, http.StatusBadRequest, "invalid_json", "Invalid JSON in request body"
	}
	var req chatRequest
	req.raw = append(req.raw, body...)
	modelRaw, ok := raw["model"]
	if !ok {
		return req, http.StatusBadRequest, "invalid_request", "Missing required field: model"
	}
	if err := json.Unmarshal(modelRaw, &req.Model); err != nil || req.Model == "" {
		return req, http.StatusBadRequest, "invalid_request", "Invalid model"
	}
	messagesRaw, ok := raw["messages"]
	if !ok {
		return req, http.StatusBadRequest, "invalid_request", "Missing required field: messages"
	}
	if err := json.Unmarshal(messagesRaw, &req.Messages); err != nil || len(req.Messages) == 0 {
		return req, http.StatusBadRequest, "invalid_request", "Invalid messages"
	}
	if status, code, msg := validateOptionalFields(raw); status != 0 {
		return req, status, code, msg
	}
	if status, code, msg := validateMessages(req.Messages); status != 0 {
		return req, status, code, msg
	}
	if status, code, msg := validateTools(raw, req.Messages); status != 0 {
		return req, status, code, msg
	}
	if v, ok := raw["stream"]; ok {
		if err := json.Unmarshal(v, &req.Stream); err != nil {
			return req, http.StatusBadRequest, "invalid_request", "Invalid stream"
		}
	}
	return req, 0, "", ""
}

func validateOptionalFields(raw map[string]json.RawMessage) (int, string, string) {
	if v, ok := raw["max_tokens"]; ok {
		var n int
		if err := json.Unmarshal(v, &n); err != nil || n <= 0 {
			return http.StatusBadRequest, "invalid_request", "max_tokens must be > 0"
		}
	}
	for _, field := range []string{"temperature", "top_p", "presence_penalty", "frequency_penalty"} {
		if v, ok := raw[field]; ok {
			var f float64
			if err := json.Unmarshal(v, &f); err != nil {
				return http.StatusBadRequest, "invalid_request", "Invalid " + field
			}
			if field == "temperature" && (f < 0 || f > 2) {
				return http.StatusBadRequest, "invalid_request", "temperature out of range"
			}
			if field == "top_p" && (f < 0 || f > 1) {
				return http.StatusBadRequest, "invalid_request", "top_p out of range"
			}
			if (field == "presence_penalty" || field == "frequency_penalty") && (f < -2 || f > 2) {
				return http.StatusBadRequest, "invalid_request", field + " out of range"
			}
		}
	}
	if v, ok := raw["n"]; ok {
		var n int
		if err := json.Unmarshal(v, &n); err != nil || n != 1 {
			return http.StatusBadRequest, "invalid_request", "n must be 1"
		}
	}
	if v, ok := raw["response_format"]; ok {
		var rf struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(v, &rf); err != nil || (rf.Type != "" && rf.Type != "text" && rf.Type != "json_object") {
			return http.StatusBadRequest, "invalid_request", "Invalid response_format"
		}
	}
	return 0, "", ""
}

func validateMessages(messages []chatMessage) (int, string, string) {
	for _, m := range messages {
		switch m.Role {
		case "system", "user":
			if !rawStringNonEmpty(m.Content) {
				return http.StatusBadRequest, "invalid_request", "Invalid message content"
			}
		case "assistant":
			hasContent := string(m.Content) != "" && string(m.Content) != "null"
			hasTools := len(m.ToolCalls) > 0 && string(m.ToolCalls) != "null"
			if hasContent && !rawString(m.Content) {
				return http.StatusBadRequest, "invalid_request", "Invalid assistant content"
			}
			if !hasContent && !hasTools {
				return http.StatusBadRequest, "invalid_request", "Assistant message requires content or tool_calls"
			}
		case "tool":
			if m.ToolCallID == "" || !rawString(m.Content) {
				return http.StatusBadRequest, "invalid_request", "Invalid tool message"
			}
		default:
			return http.StatusBadRequest, "invalid_request", "Invalid message role"
		}
	}
	return 0, "", ""
}

func validateTools(raw map[string]json.RawMessage, messages []chatMessage) (int, string, string) {
	if v, ok := raw["tools"]; ok && string(v) != "null" {
		var tools []struct {
			Type     string `json:"type"`
			Function struct {
				Name       string          `json:"name"`
				Parameters json.RawMessage `json:"parameters"`
			} `json:"function"`
		}
		if err := json.Unmarshal(v, &tools); err != nil {
			return http.StatusBadRequest, "invalid_tools", "Invalid tools"
		}
		for i, tool := range tools {
			if tool.Type != "function" || tool.Function.Name == "" || !json.Valid(tool.Function.Parameters) || string(tool.Function.Parameters) == "null" || len(tool.Function.Parameters) == 0 {
				return http.StatusBadRequest, "invalid_tools", "Invalid tools[" + itoa(i) + "]"
			}
		}
	}
	for _, msg := range messages {
		if len(msg.ToolCalls) == 0 || string(msg.ToolCalls) == "null" {
			continue
		}
		var calls []struct {
			ID       string `json:"id"`
			Type     string `json:"type"`
			Function struct {
				Name      string `json:"name"`
				Arguments string `json:"arguments"`
			} `json:"function"`
		}
		if err := json.Unmarshal(msg.ToolCalls, &calls); err != nil {
			return http.StatusBadRequest, "invalid_tools", "Invalid tool_calls"
		}
		for _, call := range calls {
			if call.ID == "" || call.Type != "function" || call.Function.Name == "" || !json.Valid([]byte(call.Function.Arguments)) {
				return http.StatusBadRequest, "invalid_tools", "Invalid tool_calls"
			}
		}
	}
	return 0, "", ""
}

func rawString(raw json.RawMessage) bool {
	var s string
	return json.Unmarshal(raw, &s) == nil
}

func rawStringNonEmpty(raw json.RawMessage) bool {
	var s string
	return json.Unmarshal(raw, &s) == nil && s != ""
}

type routeError struct {
	status  int
	code    string
	message string
}

func (s *Server) selectProvider(requestID string, req chatRequest, headers http.Header) (pool.Provider, *routeError) {
	return s.selectProviderExcluding(requestID, req, headers, nil)
}

func (s *Server) selectProviderExcluding(requestID string, req chatRequest, headers http.Header, excluded map[string]struct{}) (pool.Provider, *routeError) {
	providers := s.pool.Snapshot()
	estimatedTokens := estimateTokens(req.raw)
	if session := headers.Get("X-MacProvider-Session"); session != "" {
		for _, p := range providers {
			if p.AssignedID == session {
				provider, routeErr := validatePinnedProvider(p, req.Model, estimatedTokens, "Pinned session not available")
				if routeErr != nil {
					return provider, routeErr
				}
				if !s.checkQuota(provider) {
					return pool.Provider{}, &routeError{status: http.StatusTooManyRequests, code: "provisional_quota_exceeded", message: "Pinned provisional provider is over request quota"}
				}
				return s.preflightCandidate(provider, requestID, estimatedTokens)
			}
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "session_ended", message: "Pinned session has ended"}
	}
	if providerID := headers.Get("X-MacProvider-Provider"); providerID != "" {
		for _, p := range providers {
			if p.ProviderID == providerID {
				provider, routeErr := validatePinnedProvider(p, req.Model, estimatedTokens, "Pinned provider not available")
				if routeErr != nil {
					return provider, routeErr
				}
				if !s.checkQuota(provider) {
					return pool.Provider{}, &routeError{status: http.StatusTooManyRequests, code: "provisional_quota_exceeded", message: "Pinned provisional provider is over request quota"}
				}
				return s.preflightCandidate(provider, requestID, estimatedTokens)
			}
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: "Pinned provider not in pool"}
	}

	candidates := make([]pool.Provider, 0, len(providers))
	hasRoutableContextMiss := false
	for _, p := range providers {
		if _, skip := excluded[routeKey(p)]; skip {
			continue
		}
		if !modelIDEqual(p.ModelID, req.Model) || !p.RoutingEligible() {
			continue
		}
		if p.MaxContextTokens < estimatedTokens {
			hasRoutableContextMiss = true
			continue
		}
		candidates = append(candidates, p)
	}
	if len(candidates) == 0 {
		if hasRoutableContextMiss {
			return pool.Provider{}, &routeError{status: http.StatusRequestEntityTooLarge, code: "context_exceeds_capacity", message: "Request exceeds provider context capacity"}
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: "No provider available for model " + req.Model}
	}
	preQuotaCandidates := candidates
	candidates = candidates[:0]
	quotaBlocked := 0
	for _, candidate := range preQuotaCandidates {
		if s.checkQuota(candidate) {
			candidates = append(candidates, candidate)
		} else {
			quotaBlocked++
		}
	}
	if len(candidates) == 0 && quotaBlocked > 0 && quotaBlocked == len(preQuotaCandidates) {
		return pool.Provider{}, &routeError{status: http.StatusTooManyRequests, code: "provisional_quota_exceeded", message: "All otherwise eligible provisional providers are over request quota"}
	}
	switch headers.Get("X-MacProvider-Pref") {
	case "fast":
		sort.SliceStable(candidates, func(i, j int) bool {
			ti := s.effectiveThroughput(candidates[i])
			tj := s.effectiveThroughput(candidates[j])
			if ti == tj {
				return candidates[i].SlotsFree < candidates[j].SlotsFree
			}
			return ti > tj
		})
	case "accurate":
		sort.SliceStable(candidates, func(i, j int) bool {
			if candidates[i].ModelParamsB == candidates[j].ModelParamsB {
				return candidates[i].SlotsFree < candidates[j].SlotsFree
			}
			return candidates[i].ModelParamsB > candidates[j].ModelParamsB
		})
	default:
		sort.SliceStable(candidates, func(i, j int) bool {
			if candidates[i].SlotsFree == candidates[j].SlotsFree {
				return s.effectiveThroughput(candidates[i]) > s.effectiveThroughput(candidates[j])
			}
			return candidates[i].SlotsFree < candidates[j].SlotsFree
		})
	}
	for _, candidate := range candidates {
		provider, routeErr := s.preflightCandidate(candidate, requestID, estimatedTokens)
		if routeErr == nil {
			return provider, nil
		}
	}
	return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "preflight_rejected", message: "All providers rejected the request"}
}

func routeKey(provider pool.Provider) string {
	return provider.ProviderID + "/" + provider.AssignedID
}

func (s *Server) preflightCandidate(provider pool.Provider, requestID string, estimatedTokens int) (pool.Provider, *routeError) {
	if estimatedTokens <= s.preflightThreshold || s.preflight == nil {
		return provider, nil
	}
	result, ok, err := s.preflight(provider, requestID, estimatedTokens, s.preflightTimeout)
	if err != nil || !ok {
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "preflight_rejected", message: "Provider preflight timed out"}
	}
	if !result.Accepted {
		msg := "Provider rejected preflight"
		if result.Reason != "" {
			msg += ": " + result.Reason
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "preflight_rejected", message: msg}
	}
	return provider, nil
}

func validatePinnedProvider(p pool.Provider, model string, estimatedTokens int, unavailableMessage string) (pool.Provider, *routeError) {
	if !modelIDEqual(p.ModelID, model) {
		return pool.Provider{}, &routeError{status: http.StatusNotFound, code: "model_not_found", message: "Pinned provider serves different model"}
	}
	if p.MaxContextTokens < estimatedTokens {
		return pool.Provider{}, &routeError{status: http.StatusRequestEntityTooLarge, code: "context_exceeds_capacity", message: "Request exceeds pinned provider context capacity"}
	}
	if !p.RoutingEligible() {
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: unavailableMessage}
	}
	return p, nil
}

func (s *Server) checkQuota(provider pool.Provider) bool {
	return s.admission == nil || s.admission.CheckQuota(provider)
}

func (s *Server) effectiveThroughput(provider pool.Provider) float64 {
	weight := 1.0
	if provider.Tier == pool.TierProvisional {
		weight = s.provisionalWeight
	}
	return provider.ThroughputTPSEstimate * weight
}

func modelIDEqual(a, b string) bool {
	return strings.EqualFold(a, b)
}

func writeWSEndError(w http.ResponseWriter, end providerws.InferenceResponseEnd) {
	switch end.Status {
	case "error_context_exceeded":
		writeError(w, http.StatusRequestEntityTooLarge, "context_exceeds_capacity", "Request exceeds provider context capacity")
	case "error_model_not_loaded", "error_queue_full":
		writeError(w, http.StatusServiceUnavailable, "provider_unavailable", "Selected provider is not reachable")
	case "cancelled":
		return
	default:
		writeError(w, http.StatusBadGateway, "provider_error", "Selected provider failed; buyer should retry")
	}
}

func (s *Server) handleProviderFailure(provider pool.Provider, status int) {
	switch status {
	case http.StatusBadGateway, http.StatusGatewayTimeout:
		if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateDegraded) {
			s.log.Warn().Str("provider_id", provider.ProviderID).Int("status", status).Msg("provider marked degraded after upstream failure")
			s.startRecoveryProbe(provider)
		}
	case 530:
		if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateUnavailable) {
			s.log.Warn().Str("provider_id", provider.ProviderID).Int("status", status).Str("reason", "http_530_observed").Msg("provider marked unavailable after HTTP 530")
		}
	}
}

func (s *Server) startRecoveryProbe(provider pool.Provider) {
	if !s.recoveryProbe || s.preflight == nil || s.recoveryMaxRetries <= 0 {
		return
	}
	key := provider.ProviderID + "/" + provider.AssignedID
	if _, loaded := s.recovering.LoadOrStore(key, struct{}{}); loaded {
		return
	}
	go func() {
		defer s.recovering.Delete(key)
		delay := s.recoveryBackoff
		for attempt := 1; attempt <= s.recoveryMaxRetries; attempt++ {
			time.Sleep(delay)
			requestID := fmt.Sprintf("recovery-probe-%s-%d", provider.AssignedID, attempt)
			result, ok, err := s.preflight(provider, requestID, 128, s.preflightTimeout)
			if err == nil && ok && result.Accepted {
				if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateReady) {
					s.log.Info().Str("provider_id", provider.ProviderID).Str("request_id", requestID).Msg("provider recovery preflight accepted")
				}
				return
			}
			s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Str("request_id", requestID).Msg("provider recovery preflight failed")
			delay = s.recoveryBackoff * 2
		}
		if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateUnavailable) {
			s.log.Warn().Str("provider_id", provider.ProviderID).Msg("provider marked unavailable after recovery preflight failures")
		}
	}()
}

func estimateTokens(raw json.RawMessage) int {
	n := len(raw) / 4
	if n < 1 {
		return 1
	}
	return n
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{
			"message": message,
			"type":    errorType(status),
			"param":   nil,
			"code":    code,
		},
	})
}

func errorType(status int) string {
	switch status {
	case http.StatusBadRequest:
		return "invalid_request_error"
	case http.StatusNotFound:
		return "invalid_request_error"
	case http.StatusRequestEntityTooLarge:
		return "invalid_request_error"
	case http.StatusTooManyRequests:
		return "rate_limit_error"
	case http.StatusServiceUnavailable:
		return "service_unavailable"
	default:
		return "upstream_error"
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
