package buyer

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

type Server struct {
	pool      *pool.Registry
	log       zerolog.Logger
	createdAt int64
}

func NewServer(registry *pool.Registry, logger zerolog.Logger, startedAt time.Time) *Server {
	return &Server{
		pool:      registry,
		log:       logger,
		createdAt: startedAt.Unix(),
	}
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

	provider, routeErr := selectProvider(s.pool.Snapshot(), req, r.Header)
	if routeErr != nil {
		writeError(w, routeErr.status, routeErr.code, routeErr.message)
		return
	}
	if req.Stream {
		s.forwardStreaming(w, r, requestID, body, provider)
		return
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

func selectProvider(providers []pool.Provider, req chatRequest, headers http.Header) (pool.Provider, *routeError) {
	estimatedTokens := estimateTokens(req.raw)
	if session := headers.Get("X-MacProvider-Session"); session != "" {
		for _, p := range providers {
			if p.AssignedID == session {
				return validatePinnedProvider(p, req.Model, estimatedTokens, "Pinned session not available")
			}
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "session_ended", message: "Pinned session has ended"}
	}
	if providerID := headers.Get("X-MacProvider-Provider"); providerID != "" {
		for _, p := range providers {
			if p.ProviderID == providerID {
				return validatePinnedProvider(p, req.Model, estimatedTokens, "Pinned provider not available")
			}
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: "Pinned provider not in pool"}
	}

	candidates := make([]pool.Provider, 0, len(providers))
	for _, p := range providers {
		if p.ModelID != req.Model || !p.RoutingEligible() || p.MaxContextTokens < estimatedTokens {
			continue
		}
		candidates = append(candidates, p)
	}
	if len(candidates) == 0 {
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: "No provider available for model " + req.Model}
	}
	switch headers.Get("X-MacProvider-Pref") {
	case "fast":
		sort.SliceStable(candidates, func(i, j int) bool {
			if candidates[i].ThroughputTPSEstimate == candidates[j].ThroughputTPSEstimate {
				return candidates[i].SlotsFree < candidates[j].SlotsFree
			}
			return candidates[i].ThroughputTPSEstimate > candidates[j].ThroughputTPSEstimate
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
				return candidates[i].ThroughputTPSEstimate > candidates[j].ThroughputTPSEstimate
			}
			return candidates[i].SlotsFree < candidates[j].SlotsFree
		})
	}
	return candidates[0], nil
}

func validatePinnedProvider(p pool.Provider, model string, estimatedTokens int, unavailableMessage string) (pool.Provider, *routeError) {
	if p.ModelID != model {
		return pool.Provider{}, &routeError{status: http.StatusNotFound, code: "model_not_found", message: "Pinned provider serves different model"}
	}
	if !p.RoutingEligible() || p.MaxContextTokens < estimatedTokens {
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: unavailableMessage}
	}
	return p, nil
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
