package router

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

type anthropicMessagesAdapterContextKey struct{}

type anthropicMessagesTranslationError struct {
	typ     string
	code    string
	message string
}

func (e anthropicMessagesTranslationError) Error() string { return e.message }

type anthropicMessagesAdapter struct {
	dst       http.ResponseWriter
	requestID string
	now       func() time.Time

	model  string
	stream bool

	status      int
	wroteHeader bool
	wroteBody   bool
	body        bytes.Buffer
	lineBuf     bytes.Buffer
	prepared    []byte

	messageID          string
	contentIndex       int
	textOpen           bool
	toolCalls          map[int]*anthropicStreamToolCall
	toolOrder          []int
	finishReason       string
	streamUsage        *anthropicUsage
	startUsage         anthropicUsage
	streamDone         bool
	streamInvalid      *anthropicMessagesTranslationError
	streamOutcome      string
	terminalStopReason string
	stopSequence       *string
	stopSequences      []string
	maxStopSequenceLen int
	streamTextTail     string
	streamRefusal      bool
	finished           bool
	replayBody         bool
	writeErr           error
	dedupeCapture      []byte
	thinkPending       string
	thinkInBlock       bool
}

type anthropicStreamToolCall struct {
	ID              string
	Name            string
	Opened          bool
	Closed          bool
	Index           int
	PendingArgument string
	Arguments       string
	ProviderID      bool
}

type anthropicUsage struct {
	InputTokens  int64 `json:"input_tokens"`
	OutputTokens int64 `json:"output_tokens"`
}

func (s *Server) handleAnthropicMessages(w http.ResponseWriter, r *http.Request) {
	if strings.TrimSpace(r.Header.Get("X-Demo-Token")) != "" {
		setNoStoreHeaders(w.Header())
		w.Header().Add("Vary", "Authorization")
		w.Header().Add("Vary", "X-Api-Key")
		w.Header().Add("Vary", "X-Demo-Token")
		writeAnthropicMessagesError(w, http.StatusUnauthorized, "authentication_error", "invalid_demo_token", "X-Demo-Token is not supported for /v1/messages")
		return
	}
	if strings.TrimSpace(r.Header.Get("Authorization")) == "" {
		if key := strings.TrimSpace(r.Header.Get("X-Api-Key")); key != "" {
			r = r.Clone(r.Context())
			r.Header.Set("Authorization", "Bearer "+key)
		}
	}
	adapter := newAnthropicMessagesAdapter(w, requestID(r), s.now)
	ctx := context.WithValue(r.Context(), anthropicMessagesAdapterContextKey{}, adapter)
	s.handleChatCompletions(adapter, r.WithContext(ctx))
	adapter.finish()
}

func newAnthropicMessagesAdapter(dst http.ResponseWriter, requestID string, now func() time.Time) *anthropicMessagesAdapter {
	if now == nil {
		now = func() time.Time { return time.Now().UTC() }
	}
	return &anthropicMessagesAdapter{
		dst:       dst,
		requestID: requestID,
		now:       now,
		toolCalls: make(map[int]*anthropicStreamToolCall),
	}
}

func anthropicMessagesAdapterFromContext(ctx context.Context) *anthropicMessagesAdapter {
	adapter, _ := ctx.Value(anthropicMessagesAdapterContextKey{}).(*anthropicMessagesAdapter)
	return adapter
}

func writeAnthropicMessagesError(w http.ResponseWriter, status int, typ, code, message string, retryableOverride ...bool) {
	if typ == "" {
		typ = "invalid_request_error"
	}
	if code == "" {
		code = "invalid_request"
	}
	retryable := gatewayRetryable(code)
	if len(retryableOverride) > 0 {
		retryable = retryableOverride[0]
	}
	setGatewayRetryAfter(w, status, code, retryable)
	writeJSON(w, status, map[string]any{
		"type": "error",
		"error": map[string]any{
			"type":      typ,
			"message":   message,
			"code":      code,
			"retryable": retryable,
		},
	})
}

func (a *anthropicMessagesAdapter) Header() http.Header {
	return a.dst.Header()
}

func (a *anthropicMessagesAdapter) WriteHeader(code int) {
	if a.wroteHeader {
		return
	}
	a.status = code
	a.wroteHeader = true
	if a.replayBody {
		a.dst.WriteHeader(code)
		return
	}
	if a.stream && code == http.StatusOK {
		h := a.dst.Header()
		h.Del("Content-Length")
		h.Set("Content-Type", "text/event-stream; charset=utf-8")
		h.Set("Cache-Control", "no-store, no-cache, no-transform")
		h.Set("X-Accel-Buffering", "no")
		a.dst.WriteHeader(code)
		a.emitSSE("message_start", map[string]any{
			"type": "message_start",
			"message": map[string]any{
				"id":            a.effectiveMessageID(),
				"type":          "message",
				"role":          "assistant",
				"content":       []any{},
				"model":         a.model,
				"stop_reason":   nil,
				"stop_sequence": nil,
				"usage":         a.startUsage,
			},
		})
		a.flush()
	}
}

func (a *anthropicMessagesAdapter) Write(p []byte) (int, error) {
	if !a.wroteHeader {
		a.WriteHeader(http.StatusOK)
	}
	if a.replayBody {
		return a.dst.Write(p)
	}
	if a.status != http.StatusOK {
		_, _ = a.body.Write(p)
		return len(p), nil
	}
	if !a.stream {
		body := a.prepared
		if body == nil {
			body = p
		}
		a.dst.Header().Set("Content-Type", "application/json")
		a.writeBytes(body)
		a.wroteBody = true
		return len(p), a.writeErr
	}
	a.lineBuf.Write(p)
	for {
		line, err := a.lineBuf.ReadString('\n')
		if err != nil {
			a.lineBuf.WriteString(line)
			return len(p), a.writeErr
		}
		a.handleChatStreamLine(line)
		if a.writeErr != nil {
			return 0, a.writeErr
		}
	}
}

func (a *anthropicMessagesAdapter) Flush() {
	if a.stream {
		a.flush()
	}
}

func (a *anthropicMessagesAdapter) drainDedupeCapture() []byte {
	out := a.dedupeCapture
	a.dedupeCapture = nil
	return out
}

func (a *anthropicMessagesAdapter) dedupeCleanSSEError(code string) bool {
	return a.stream && gatewayCleanLengthTruncationTerminalCode(code)
}

func (a *anthropicMessagesAdapter) finish() {
	if a.replayBody {
		return
	}
	if a.stream {
		if a.status != 0 && a.status != http.StatusOK {
			a.writeBufferedAnthropicError(a.status)
			return
		}
		if a.lineBuf.Len() > 0 && a.status == http.StatusOK {
			a.handleChatStreamLine(a.lineBuf.String())
			a.lineBuf.Reset()
		}
		return
	}
	status := a.status
	if status == 0 {
		status = http.StatusOK
	}
	if status != http.StatusOK {
		a.writeBufferedAnthropicError(status)
		return
	}
	if a.wroteBody {
		return
	}
	if a.writeErr == nil && a.prepared == nil {
		body, err := a.translateNonStreamingResponse(a.body.Bytes())
		if err != nil {
			writeAnthropicMessagesError(a.dst, http.StatusBadGateway, "api_error", "invalid_provider_response", "Upstream provider returned invalid response")
			return
		}
		a.dst.Header().Set("Content-Type", "application/json")
		a.dst.WriteHeader(http.StatusOK)
		a.writeBytes(body)
	}
}

func (a *anthropicMessagesAdapter) writeBufferedAnthropicError(status int) {
	typ, code, msg, retryable := anthropicErrorFromOpenAIError(a.body.Bytes())
	writeAnthropicMessagesError(a.dst, status, typ, code, msg, retryable)
}

func (a *anthropicMessagesAdapter) prepareNonStreamingResponse(body []byte) error {
	translated, err := a.translateNonStreamingResponse(body)
	if err != nil {
		return err
	}
	a.prepared = translated
	return nil
}

func (a *anthropicMessagesAdapter) setPromptEstimate(promptTokens int64) {
	if promptTokens < 0 {
		promptTokens = 0
	}
	a.startUsage.InputTokens = promptTokens
}

func (a *anthropicMessagesAdapter) setFallbackStreamUsage(promptTokens, completionTokens int64) {
	if promptTokens < 0 {
		promptTokens = 0
	}
	if completionTokens < 0 {
		completionTokens = 0
	}
	if a.streamUsage == nil {
		a.streamUsage = &anthropicUsage{InputTokens: promptTokens, OutputTokens: completionTokens}
	}
}

func (a *anthropicMessagesAdapter) translateRequest(header http.Header, body []byte) ([]byte, *anthropicMessagesTranslationError) {
	if strings.TrimSpace(header.Get("Anthropic-Beta")) != "" {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "unsupported_content_shape", message: "Anthropic beta features are not supported"}
	}
	if anthropicRawHasDuplicateKeys(body) {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "invalid_request", message: "request body contains duplicate keys"}
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "invalid_request_body", message: "Malformed JSON"}
	}
	for key, value := range raw {
		switch key {
		case "model", "max_tokens", "system", "messages", "tools", "tool_choice", "stream", "stop_sequences", "temperature", "top_p", "metadata", "service_tier":
		case "top_k":
			return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "unsupported_content_shape", message: "top_k is not supported"}
		case "thinking", "anthropic_beta":
			return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "unsupported_content_shape", message: "Anthropic beta features are not supported"}
		default:
			return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "unsupported_content_shape", message: fmt.Sprintf("%s is not supported", key)}
		}
		if anthropicRawHasDuplicateKeys(value) {
			return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "invalid_request", message: fmt.Sprintf("%s contains duplicate keys", key)}
		}
	}
	if err := anthropicValidateRequestRawTypes(raw); err != nil {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "unsupported_content_shape", message: err.Error()}
	}
	if err := anthropicValidateNestedRequest(raw); err != nil {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "unsupported_content_shape", message: err.Error()}
	}
	var req struct {
		Model         string                  `json:"model"`
		MaxTokens     *int64                  `json:"max_tokens"`
		System        json.RawMessage         `json:"system"`
		Messages      []anthropicInputMessage `json:"messages"`
		Tools         []map[string]any        `json:"tools"`
		ToolChoice    any                     `json:"tool_choice"`
		Stream        bool                    `json:"stream"`
		StopSequences []string                `json:"stop_sequences"`
		Temperature   any                     `json:"temperature"`
		TopP          any                     `json:"top_p"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "invalid_request_body", message: "Malformed JSON"}
	}
	if strings.TrimSpace(req.Model) == "" {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "invalid_request", message: "model is required"}
	}
	if req.MaxTokens == nil || *req.MaxTokens < 0 {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "invalid_request", message: "max_tokens is required"}
	}
	if len(req.Messages) == 0 {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "invalid_request", message: "messages is required"}
	}
	systemMessages, err := anthropicSystemToChatMessages(req.System)
	if err != nil {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "unsupported_content_shape", message: err.Error()}
	}
	messages, err := anthropicMessagesToChatMessages(req.Messages)
	if err != nil {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "unsupported_content_shape", message: err.Error()}
	}
	chatMessages := append(systemMessages, messages...)
	chat := map[string]any{
		"model":      req.Model,
		"max_tokens": *req.MaxTokens,
		"messages":   chatMessages,
		"stream":     req.Stream,
	}
	if req.Temperature != nil {
		chat["temperature"] = req.Temperature
	}
	if req.TopP != nil {
		chat["top_p"] = req.TopP
	}
	if len(req.StopSequences) > 0 {
		chat["stop"] = req.StopSequences
	}
	if len(req.Tools) > 0 {
		tools, err := anthropicToolsToChatTools(req.Tools)
		if err != nil {
			return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "unsupported_content_shape", message: err.Error()}
		}
		chat["tools"] = tools
	}
	if req.ToolChoice != nil {
		toolChoice, parallelToolCalls, err := anthropicToolChoiceToChatToolChoice(req.ToolChoice)
		if err != nil {
			return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "unsupported_content_shape", message: err.Error()}
		}
		chat["tool_choice"] = toolChoice
		if parallelToolCalls != nil {
			chat["parallel_tool_calls"] = *parallelToolCalls
		}
	}
	translated, err := json.Marshal(chat)
	if err != nil {
		return nil, &anthropicMessagesTranslationError{typ: "invalid_request_error", code: "invalid_request", message: "Could not encode translated request"}
	}
	a.model = req.Model
	a.stream = req.Stream
	a.stopSequences = anthropicNonEmptyStopSequences(req.StopSequences)
	a.maxStopSequenceLen = anthropicMaxStopSequenceLen(a.stopSequences)
	return translated, nil
}

type anthropicInputMessage struct {
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
}

func anthropicValidateRequestRawTypes(raw map[string]json.RawMessage) error {
	if v, ok := raw["model"]; ok {
		if err := anthropicValidateRawString(v, "model"); err != nil {
			return err
		}
	}
	if v, ok := raw["max_tokens"]; ok {
		if err := anthropicValidateRawInteger(v, "max_tokens"); err != nil {
			return err
		}
	}
	if v, ok := raw["stream"]; ok {
		if err := anthropicValidateRawBool(v, "stream"); err != nil {
			return err
		}
	}
	if v, ok := raw["temperature"]; ok {
		if err := anthropicValidateRawNumber(v, "temperature"); err != nil {
			return err
		}
	}
	if v, ok := raw["top_p"]; ok {
		if err := anthropicValidateRawNumber(v, "top_p"); err != nil {
			return err
		}
	}
	if v, ok := raw["stop_sequences"]; ok {
		if err := anthropicValidateRawStringArray(v, "stop_sequences"); err != nil {
			return err
		}
	}
	if v, ok := raw["metadata"]; ok && !anthropicRawIsNull(v) {
		if _, err := anthropicRawObject(v); err != nil {
			return fmt.Errorf("metadata must be an object")
		}
	}
	if v, ok := raw["service_tier"]; ok && !anthropicRawIsNull(v) {
		if err := anthropicValidateRawString(v, "service_tier"); err != nil {
			return err
		}
	}
	return nil
}

func anthropicValidateNestedRequest(raw map[string]json.RawMessage) error {
	if system := raw["system"]; len(bytes.TrimSpace(system)) > 0 && !anthropicRawIsNull(system) {
		if err := anthropicValidateContentRaw("system", system, "system"); err != nil {
			return err
		}
	}
	if messagesRaw := raw["messages"]; len(bytes.TrimSpace(messagesRaw)) > 0 {
		var messages []json.RawMessage
		if err := json.Unmarshal(messagesRaw, &messages); err != nil {
			return fmt.Errorf("messages must be an array")
		}
		for i, msgRaw := range messages {
			m, err := anthropicRawObject(msgRaw)
			if err != nil {
				return fmt.Errorf("messages[%d] must be an object", i)
			}
			if err := anthropicRejectUnknownKeys(m, fmt.Sprintf("messages[%d]", i), "role", "content"); err != nil {
				return err
			}
			var role string
			if rawRole, ok := m["role"]; ok {
				var err error
				role, err = anthropicRawString(rawRole, fmt.Sprintf("messages[%d].role", i))
				if err != nil {
					return err
				}
			}
			if content, ok := m["content"]; ok {
				if err := anthropicValidateContentRaw(fmt.Sprintf("messages[%d].content", i), content, role); err != nil {
					return err
				}
			}
		}
	}
	if toolsRaw := raw["tools"]; len(bytes.TrimSpace(toolsRaw)) > 0 {
		var tools []json.RawMessage
		if err := json.Unmarshal(toolsRaw, &tools); err != nil {
			return fmt.Errorf("tools must be an array")
		}
		for i, toolRaw := range tools {
			m, err := anthropicRawObject(toolRaw)
			if err != nil {
				return fmt.Errorf("tools[%d] must be an object", i)
			}
			if err := anthropicRejectUnknownKeys(m, fmt.Sprintf("tools[%d]", i), "type", "name", "description", "input_schema", "cache_control"); err != nil {
				return err
			}
			if v, ok := m["type"]; ok {
				if err := anthropicValidateRawString(v, fmt.Sprintf("tools[%d].type", i)); err != nil {
					return err
				}
			}
			if v, ok := m["name"]; ok {
				if err := anthropicValidateRawString(v, fmt.Sprintf("tools[%d].name", i)); err != nil {
					return err
				}
			}
			if v, ok := m["description"]; ok {
				if err := anthropicValidateRawString(v, fmt.Sprintf("tools[%d].description", i)); err != nil {
					return err
				}
			}
			if v, ok := m["input_schema"]; ok && !anthropicRawIsNull(v) {
				if _, err := anthropicRawObject(v); err != nil {
					return fmt.Errorf("tools[%d].input_schema must be an object", i)
				}
			}
		}
	}
	if choiceRaw := raw["tool_choice"]; len(bytes.TrimSpace(choiceRaw)) > 0 && !anthropicRawIsNull(choiceRaw) {
		m, err := anthropicRawObject(choiceRaw)
		if err != nil {
			return fmt.Errorf("tool_choice must be an object")
		}
		if err := anthropicRejectUnknownKeys(m, "tool_choice", "type", "name", "disable_parallel_tool_use"); err != nil {
			return err
		}
		if v, ok := m["type"]; ok {
			if err := anthropicValidateRawString(v, "tool_choice.type"); err != nil {
				return err
			}
		}
		if v, ok := m["name"]; ok {
			if err := anthropicValidateRawString(v, "tool_choice.name"); err != nil {
				return err
			}
		}
		if v, ok := m["disable_parallel_tool_use"]; ok {
			if err := anthropicValidateRawBool(v, "tool_choice.disable_parallel_tool_use"); err != nil {
				return err
			}
		}
	}
	return nil
}

func anthropicValidateContentRaw(path string, raw json.RawMessage, role string) error {
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return nil
	}
	var blocks []json.RawMessage
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return fmt.Errorf("%s must be a string or content block array", path)
	}
	for i, blockRaw := range blocks {
		m, err := anthropicRawObject(blockRaw)
		if err != nil {
			return fmt.Errorf("%s[%d] must be an object", path, i)
		}
		var typ string
		if rawType, ok := m["type"]; ok {
			var err error
			typ, err = anthropicRawString(rawType, fmt.Sprintf("%s[%d].type", path, i))
			if err != nil {
				return err
			}
		}
		blockPath := fmt.Sprintf("%s[%d]", path, i)
		switch typ {
		case "text":
			if err := anthropicRejectUnknownKeys(m, blockPath, "type", "text", "cache_control"); err != nil {
				return err
			}
			if v, ok := m["text"]; ok {
				if err := anthropicValidateRawString(v, blockPath+".text"); err != nil {
					return err
				}
			}
		case "tool_use":
			if role != "assistant" {
				return fmt.Errorf("%s.type %q is not supported", blockPath, typ)
			}
			if err := anthropicRejectUnknownKeys(m, blockPath, "type", "id", "name", "input"); err != nil {
				return err
			}
			if v, ok := m["id"]; ok {
				if err := anthropicValidateRawString(v, blockPath+".id"); err != nil {
					return err
				}
			}
			if v, ok := m["name"]; ok {
				if err := anthropicValidateRawString(v, blockPath+".name"); err != nil {
					return err
				}
			}
			if v, ok := m["input"]; ok && !anthropicRawIsNull(v) {
				if _, err := anthropicRawObject(v); err != nil {
					return fmt.Errorf("%s.input must be an object", blockPath)
				}
			}
		case "tool_result":
			if role == "assistant" || role == "system" {
				return fmt.Errorf("%s.type %q is not supported", blockPath, typ)
			}
			if err := anthropicRejectUnknownKeys(m, blockPath, "type", "tool_use_id", "content", "is_error"); err != nil {
				return err
			}
			if v, ok := m["tool_use_id"]; ok {
				if err := anthropicValidateRawString(v, blockPath+".tool_use_id"); err != nil {
					return err
				}
			}
			if v, ok := m["is_error"]; ok {
				if err := anthropicValidateRawBool(v, blockPath+".is_error"); err != nil {
					return err
				}
			}
			if content, ok := m["content"]; ok {
				if err := anthropicValidateToolResultContentRaw(blockPath+".content", content); err != nil {
					return err
				}
			}
		case "image", "document", "file":
			return fmt.Errorf("%s content is not supported", typ)
		default:
			return fmt.Errorf("%s.type %q is not supported", blockPath, typ)
		}
	}
	return nil
}

func anthropicValidateToolResultContentRaw(path string, raw json.RawMessage) error {
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return nil
	}
	var blocks []json.RawMessage
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return fmt.Errorf("%s must be a string or text block array", path)
	}
	for i, blockRaw := range blocks {
		m, err := anthropicRawObject(blockRaw)
		if err != nil {
			return fmt.Errorf("%s[%d] must be an object", path, i)
		}
		if err := anthropicRejectUnknownKeys(m, fmt.Sprintf("%s[%d]", path, i), "type", "text", "cache_control"); err != nil {
			return err
		}
		if v, ok := m["type"]; ok {
			if err := anthropicValidateRawString(v, fmt.Sprintf("%s[%d].type", path, i)); err != nil {
				return err
			}
		}
		if v, ok := m["text"]; ok {
			if err := anthropicValidateRawString(v, fmt.Sprintf("%s[%d].text", path, i)); err != nil {
				return err
			}
		}
	}
	return nil
}

func anthropicSystemToChatMessages(raw json.RawMessage) ([]map[string]any, error) {
	if len(bytes.TrimSpace(raw)) == 0 || anthropicRawIsNull(raw) {
		return nil, nil
	}
	text, err := anthropicContentToText(raw, true)
	if err != nil {
		return nil, fmt.Errorf("system: %w", err)
	}
	if strings.TrimSpace(text) == "" {
		return nil, nil
	}
	return []map[string]any{{"role": "system", "content": text}}, nil
}

func anthropicMessagesToChatMessages(messages []anthropicInputMessage) ([]map[string]any, error) {
	out := make([]map[string]any, 0, len(messages))
	for i, msg := range messages {
		role := strings.TrimSpace(msg.Role)
		if role != "user" && role != "assistant" {
			return nil, fmt.Errorf("messages[%d].role must be user or assistant", i)
		}
		converted, err := anthropicMessageToChatMessages(role, msg.Content)
		if err != nil {
			return nil, fmt.Errorf("messages[%d]: %w", i, err)
		}
		out = append(out, converted...)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("messages produced no chat messages")
	}
	return out, nil
}

func anthropicMessageToChatMessages(role string, raw json.RawMessage) ([]map[string]any, error) {
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return []map[string]any{{"role": role, "content": text}}, nil
	}
	var blocks []map[string]any
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return nil, fmt.Errorf("content must be a string or content block array")
	}
	if role == "assistant" {
		return anthropicAssistantBlocksToChat(blocks)
	}
	return anthropicUserBlocksToChat(blocks)
}

func anthropicUserBlocksToChat(blocks []map[string]any) ([]map[string]any, error) {
	out := []map[string]any{}
	textParts := []string{}
	flushText := func() {
		if len(textParts) == 0 {
			return
		}
		out = append(out, map[string]any{"role": "user", "content": strings.Join(textParts, "")})
		textParts = nil
	}
	for i, block := range blocks {
		typ, _ := block["type"].(string)
		switch typ {
		case "text":
			s, ok := block["text"].(string)
			if !ok {
				return nil, fmt.Errorf("content[%d].text must be a string", i)
			}
			if s != "" {
				textParts = append(textParts, s)
			}
		case "tool_result":
			flushText()
			isError, _ := block["is_error"].(bool)
			toolUseID, _ := block["tool_use_id"].(string)
			if strings.TrimSpace(toolUseID) == "" {
				return nil, fmt.Errorf("content[%d].tool_use_id is required", i)
			}
			text, err := anthropicToolResultContentToChatText(block["content"], isError)
			if err != nil {
				return nil, fmt.Errorf("content[%d]: %w", i, err)
			}
			out = append(out, map[string]any{"role": "tool", "tool_call_id": toolUseID, "content": text})
		case "image", "document", "file":
			return nil, fmt.Errorf("%s content is not supported", typ)
		default:
			return nil, fmt.Errorf("content[%d].type %q is not supported", i, typ)
		}
	}
	flushText()
	if len(out) == 0 {
		return nil, fmt.Errorf("user content produced no chat messages")
	}
	return out, nil
}

func anthropicAssistantBlocksToChat(blocks []map[string]any) ([]map[string]any, error) {
	textParts := []string{}
	toolCalls := []map[string]any{}
	for i, block := range blocks {
		typ, _ := block["type"].(string)
		switch typ {
		case "text":
			s, ok := block["text"].(string)
			if !ok {
				return nil, fmt.Errorf("content[%d].text must be a string", i)
			}
			if s != "" {
				textParts = append(textParts, s)
			}
		case "tool_use":
			id, _ := block["id"].(string)
			name, _ := block["name"].(string)
			if strings.TrimSpace(id) == "" || strings.TrimSpace(name) == "" {
				return nil, fmt.Errorf("content[%d] tool_use id and name are required", i)
			}
			input, err := anthropicToolUseInput(block, i)
			if err != nil {
				return nil, err
			}
			args, err := json.Marshal(input)
			if err != nil {
				return nil, fmt.Errorf("content[%d].input could not be encoded", i)
			}
			toolCalls = append(toolCalls, map[string]any{
				"id":   id,
				"type": "function",
				"function": map[string]any{
					"name":      name,
					"arguments": string(args),
				},
			})
		default:
			return nil, fmt.Errorf("content[%d].type %q is not supported", i, typ)
		}
	}
	msg := map[string]any{"role": "assistant", "content": strings.Join(textParts, "")}
	if len(toolCalls) > 0 {
		if msg["content"] == "" {
			msg["content"] = nil
		}
		msg["tool_calls"] = toolCalls
	}
	return []map[string]any{msg}, nil
}

func anthropicContentToText(raw json.RawMessage, system bool) (string, error) {
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return text, nil
	}
	var blocks []map[string]any
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return "", fmt.Errorf("content must be a string or content block array")
	}
	parts := make([]string, 0, len(blocks))
	for i, block := range blocks {
		typ, _ := block["type"].(string)
		if typ != "text" {
			if system {
				return "", fmt.Errorf("content[%d].type %q is not supported", i, typ)
			}
			continue
		}
		s, ok := block["text"].(string)
		if !ok {
			return "", fmt.Errorf("content[%d].text must be a string", i)
		}
		if s != "" {
			parts = append(parts, s)
		}
	}
	return strings.Join(parts, ""), nil
}

func anthropicToolUseInput(block map[string]any, index int) (map[string]any, error) {
	input, ok := block["input"]
	if !ok || input == nil {
		return map[string]any{}, nil
	}
	m, ok := input.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("content[%d].input must be an object", index)
	}
	return m, nil
}

func anthropicToolResultContentToText(v any) (string, error) {
	switch typed := v.(type) {
	case nil:
		return "", nil
	case string:
		return typed, nil
	case []any:
		parts := make([]string, 0, len(typed))
		for i, part := range typed {
			m, ok := part.(map[string]any)
			if !ok {
				return "", fmt.Errorf("tool_result content[%d] must be an object", i)
			}
			typ, _ := m["type"].(string)
			if typ != "text" {
				return "", fmt.Errorf("tool_result content[%d].type %q is not supported", i, typ)
			}
			s, ok := m["text"].(string)
			if !ok {
				return "", fmt.Errorf("tool_result content[%d].text must be a string", i)
			}
			if s != "" {
				parts = append(parts, s)
			}
		}
		return strings.Join(parts, ""), nil
	default:
		return "", fmt.Errorf("tool_result content must be a string or text block array")
	}
}

func anthropicToolResultContentToChatText(v any, isError bool) (string, error) {
	text, err := anthropicToolResultContentToText(v)
	if err != nil {
		return "", err
	}
	if isError {
		return "Tool error: " + text, nil
	}
	return text, nil
}

func anthropicToolsToChatTools(tools []map[string]any) ([]map[string]any, error) {
	out := make([]map[string]any, 0, len(tools))
	for i, tool := range tools {
		if typ, _ := tool["type"].(string); typ != "" && typ != "custom" {
			return nil, fmt.Errorf("tools[%d].type %q is not supported", i, typ)
		}
		name, _ := tool["name"].(string)
		if strings.TrimSpace(name) == "" {
			return nil, fmt.Errorf("tools[%d].name is required", i)
		}
		fn := map[string]any{"name": name}
		if desc, ok := tool["description"]; ok {
			fn["description"] = desc
		}
		if schema, ok := tool["input_schema"]; ok {
			fn["parameters"] = schema
		} else {
			fn["parameters"] = map[string]any{"type": "object"}
		}
		out = append(out, map[string]any{"type": "function", "function": fn})
	}
	return out, nil
}

func anthropicToolChoiceToChatToolChoice(choice any) (any, *bool, error) {
	m, ok := choice.(map[string]any)
	if !ok {
		return nil, nil, fmt.Errorf("tool_choice must be an object")
	}
	var parallelToolCalls *bool
	if disableParallel, _ := m["disable_parallel_tool_use"].(bool); disableParallel {
		v := false
		parallelToolCalls = &v
	}
	typ, _ := m["type"].(string)
	switch typ {
	case "", "auto":
		return "auto", parallelToolCalls, nil
	case "any":
		return "required", parallelToolCalls, nil
	case "none":
		return "none", parallelToolCalls, nil
	case "tool":
		name, _ := m["name"].(string)
		if strings.TrimSpace(name) == "" {
			return nil, nil, fmt.Errorf("tool_choice.name is required")
		}
		return map[string]any{"type": "function", "function": map[string]any{"name": name}}, parallelToolCalls, nil
	default:
		return nil, nil, fmt.Errorf("tool_choice.type %q is not supported", typ)
	}
}

func (a *anthropicMessagesAdapter) translateNonStreamingResponse(body []byte) ([]byte, error) {
	if anthropicRawHasDuplicateKeys(body) {
		return nil, fmt.Errorf("provider response contains duplicate keys")
	}
	if err := anthropicValidateNonStreamingProviderRaw(body); err != nil {
		return nil, err
	}
	var chat struct {
		ID      string     `json:"id"`
		Model   string     `json:"model"`
		Usage   tokenUsage `json:"usage"`
		Error   any        `json:"error"`
		Choices []struct {
			Message struct {
				Content   any    `json:"content"`
				Refusal   string `json:"refusal"`
				ToolCalls []struct {
					ID       string `json:"id"`
					Type     string `json:"type"`
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"message"`
			FinishReason string  `json:"finish_reason"`
			StopSequence *string `json:"stop_sequence"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &chat); err != nil {
		return nil, err
	}
	if chat.Error != nil {
		return nil, fmt.Errorf("provider response contained error")
	}
	if len(chat.Choices) != 1 {
		return nil, fmt.Errorf("provider response must contain exactly one choice")
	}
	if chat.ID != "" {
		a.messageID = anthropicMessageIDFromChatID(chat.ID, a.requestID)
	}
	model := firstNonEmpty(chat.Model, a.model)
	content := []map[string]any{}
	choice := chat.Choices[0]
	hasToolCalls := len(choice.Message.ToolCalls) > 0
	if choice.FinishReason == "tool_calls" && !hasToolCalls {
		return nil, fmt.Errorf("finish_reason %q requires at least one tool call", choice.FinishReason)
	}
	finishReason := choice.FinishReason
	stopSequence := choice.StopSequence
	stopReason, err := anthropicStopReasonStrict(finishReason, hasToolCalls)
	if err != nil {
		return nil, err
	}
	if text, err := anthropicResponseContentToText(choice.Message.Content); err != nil {
		return nil, err
	} else {
		text = anthropicStripThinkBlocks(text)
		if finishReason == "stop_sequence" && stopSequence != nil {
			text, _ = anthropicTrimStopSequenceSuffix(text, *stopSequence)
		} else if finishReason == "stop" {
			if visible, matched := anthropicTextWithoutMatchedStopSequence(text, a.stopSequences); matched != nil {
				text = visible
				stopSequence = matched
				finishReason = "stop_sequence"
				stopReason = "stop_sequence"
			}
		}
		if text != "" {
			content = append(content, map[string]any{"type": "text", "text": text})
		}
	}
	if refusal := strings.TrimSpace(choice.Message.Refusal); refusal != "" {
		if len(content) == 0 {
			content = append(content, map[string]any{"type": "text", "text": choice.Message.Refusal})
		}
		stopReason = "refusal"
	}
	seenToolIDs := map[string]struct{}{}
	for _, tc := range choice.Message.ToolCalls {
		if tc.Type != "" && tc.Type != "function" {
			return nil, fmt.Errorf("tool call type %q is not supported", tc.Type)
		}
		if strings.TrimSpace(tc.Function.Name) == "" {
			return nil, fmt.Errorf("tool call function name is required")
		}
		input := map[string]any{}
		if strings.TrimSpace(tc.Function.Arguments) != "" {
			if anthropicRawHasDuplicateKeys([]byte(tc.Function.Arguments)) {
				return nil, fmt.Errorf("tool call arguments contain duplicate keys")
			}
			if err := json.Unmarshal([]byte(tc.Function.Arguments), &input); err != nil {
				return nil, err
			}
			if input == nil {
				input = map[string]any{}
			}
		}
		id := strings.TrimSpace(tc.ID)
		if id == "" {
			return nil, fmt.Errorf("tool call id is required")
		}
		if _, ok := seenToolIDs[id]; ok {
			return nil, fmt.Errorf("tool call id %q is duplicated", id)
		}
		seenToolIDs[id] = struct{}{}
		content = append(content, map[string]any{
			"type":  "tool_use",
			"id":    id,
			"name":  tc.Function.Name,
			"input": input,
		})
	}
	resp := map[string]any{
		"id":            a.effectiveMessageID(),
		"type":          "message",
		"role":          "assistant",
		"content":       content,
		"model":         model,
		"stop_reason":   stopReason,
		"stop_sequence": anthropicStopSequence(finishReason, stopSequence),
		"usage": anthropicUsage{
			InputTokens:  chat.Usage.PromptTokens,
			OutputTokens: chat.Usage.CompletionTokens,
		},
	}
	return json.Marshal(resp)
}

func (a *anthropicMessagesAdapter) handleChatStreamLine(line string) {
	trimmed := strings.TrimRight(line, "\r\n")
	if strings.TrimSpace(trimmed) == "" || a.streamInvalid != nil {
		return
	}
	data, ok := sseDataValue(trimmed)
	if !ok {
		return
	}
	if data == "[DONE]" {
		if err := a.validateStreamComplete(); err != nil {
			a.emitInvalidProviderResponse(err.Error())
			return
		}
		a.emitMessageStop()
		return
	}
	if a.streamDone {
		return
	}
	if typ, code, msg, retryable, ok := anthropicStandaloneStreamErrorFromOpenAIData(data); ok {
		if anthropicTerminalErrorCodeIsLengthTruncation(code) {
			a.finishReason = anthropicFinishReasonFromTerminalErrorCode(code)
			a.streamOutcome = anthropicStreamOutcomeFromTerminalErrorCode(code)
			a.terminalStopReason = anthropicStopReason(a.finishReason, false)
			a.emitTerminalMessageStop()
			return
		}
		a.emitSSE("error", map[string]any{"type": "error", "error": map[string]any{"type": typ, "message": msg, "code": code, "retryable": retryable}})
		a.finishReason = anthropicFinishReasonFromTerminalErrorCode(code)
		a.streamOutcome = anthropicStreamOutcomeFromTerminalErrorCode(code)
		a.terminalStopReason = anthropicStopReason(a.finishReason, false)
		a.emitTerminalMessageStop()
		return
	}
	if anthropicRawHasDuplicateKeys([]byte(data)) {
		a.emitInvalidProviderResponse("Upstream provider returned ambiguous stream data")
		return
	}
	if err := anthropicValidateStreamProviderRaw([]byte(data)); err != nil {
		a.emitInvalidProviderResponse(err.Error())
		return
	}
	var chunk struct {
		ID      any             `json:"id"`
		Model   any             `json:"model"`
		Usage   json.RawMessage `json:"usage"`
		Error   json.RawMessage `json:"error"`
		Choices []struct {
			Delta        map[string]any `json:"delta"`
			FinishReason any            `json:"finish_reason"`
			StopSequence *string        `json:"stop_sequence"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(data), &chunk); err != nil {
		a.emitInvalidProviderResponse("Upstream provider returned malformed stream data")
		return
	}
	if id := anthropicStringFromAny(chunk.ID); id != "" && a.messageID == "" {
		a.messageID = anthropicMessageIDFromChatID(id, a.requestID)
	}
	if model := anthropicStringFromAny(chunk.Model); model != "" {
		a.model = model
	}
	if len(bytes.TrimSpace(chunk.Error)) > 0 && !anthropicRawIsNull(chunk.Error) {
		a.emitInvalidProviderResponse("Upstream provider returned mixed stream error")
		return
	}
	if len(bytes.TrimSpace(chunk.Usage)) > 0 && !anthropicRawIsNull(chunk.Usage) {
		var usage tokenUsage
		if err := json.Unmarshal(chunk.Usage, &usage); err == nil {
			a.streamUsage = &anthropicUsage{InputTokens: usage.PromptTokens, OutputTokens: usage.CompletionTokens}
		}
	}
	if len(chunk.Choices) == 0 {
		if len(bytes.TrimSpace(chunk.Usage)) == 0 || anthropicRawIsNull(chunk.Usage) {
			a.emitInvalidProviderResponse("Upstream provider returned stream data without choices")
		}
		return
	}
	if len(chunk.Choices) != 1 {
		a.emitInvalidProviderResponse("Upstream provider returned multiple stream choices")
		return
	}
	delta := chunk.Choices[0].Delta
	if a.finished && len(delta) > 0 {
		a.emitInvalidProviderResponse("Upstream provider returned stream content after finish_reason")
		return
	}
	if _, ok := delta["function_call"]; ok {
		a.emitInvalidProviderResponse("Upstream provider returned unsupported stream tool-call shape")
		return
	}
	if text := a.filterThinkContent(anthropicStringFromAny(delta["content"])); text != "" {
		a.emitTextDelta(text)
	}
	if refusal := anthropicStringFromAny(delta["refusal"]); strings.TrimSpace(refusal) != "" {
		a.streamRefusal = true
		if text := a.filterThinkContent(refusal); text != "" {
			a.emitTextDelta(text)
		}
	}
	toolDeltas, err := anthropicToolCallDeltasFromAny(delta["tool_calls"])
	if err != nil {
		a.emitInvalidProviderResponse(err.Error())
		return
	}
	for _, tc := range toolDeltas {
		a.emitToolCallDelta(tc.index, tc.id, tc.name, tc.arguments)
	}
	if finish := anthropicStringFromAny(chunk.Choices[0].FinishReason); finish != "" {
		if _, err := anthropicStopReasonStrict(finish, a.hasStreamToolUse()); err != nil {
			a.emitInvalidProviderResponse(err.Error())
			return
		}
		if a.finished && finish != a.finishReason {
			a.emitInvalidProviderResponse("Upstream provider changed stream finish_reason")
			return
		}
		a.finishReason = finish
		if a.streamRefusal {
			a.terminalStopReason = "refusal"
		}
		if chunk.Choices[0].StopSequence != nil {
			a.stopSequence = chunk.Choices[0].StopSequence
		}
		a.finished = true
	}
	a.flush()
}

func (a *anthropicMessagesAdapter) hasStreamToolUse() bool {
	for _, tc := range a.toolCalls {
		if tc != nil {
			return true
		}
	}
	return false
}

func (a *anthropicMessagesAdapter) emitTextDelta(text string) {
	if text == "" || a.streamDone {
		return
	}
	if a.maxStopSequenceLen > 0 {
		a.streamTextTail += text
		a.flushStreamTextTail(false)
		return
	}
	a.emitRawTextDelta(text)
}

func (a *anthropicMessagesAdapter) emitRawTextDelta(text string) {
	if text == "" || a.streamDone {
		return
	}
	a.closeToolBlocks()
	if !a.textOpen {
		a.emitSSE("content_block_start", map[string]any{
			"type": "content_block_start", "index": a.contentIndex,
			"content_block": map[string]any{"type": "text", "text": ""},
		})
		a.textOpen = true
	}
	a.emitSSE("content_block_delta", map[string]any{
		"type": "content_block_delta", "index": a.contentIndex,
		"delta": map[string]any{"type": "text_delta", "text": text},
	})
}

func (a *anthropicMessagesAdapter) flushStreamTextTail(final bool) *string {
	if a.streamTextTail == "" {
		return nil
	}
	if final {
		text := a.streamTextTail
		a.streamTextTail = ""
		if a.finishReason == "stop_sequence" && a.stopSequence != nil && a.terminalStopReason == "" {
			visible, _ := anthropicTrimStopSequenceSuffix(text, *a.stopSequence)
			if visible != "" {
				a.emitRawTextDelta(visible)
			}
			return nil
		}
		if a.finishReason == "stop" && a.terminalStopReason == "" {
			visible, matched := anthropicTextWithoutMatchedStopSequence(text, a.stopSequences)
			if visible != "" {
				a.emitRawTextDelta(visible)
			}
			return matched
		}
		a.emitRawTextDelta(text)
		return nil
	}
	prefix, tail := anthropicSplitStopSequenceTail(a.streamTextTail, a.maxStopSequenceLen)
	if prefix != "" {
		a.emitRawTextDelta(prefix)
	}
	a.streamTextTail = tail
	return nil
}

func (a *anthropicMessagesAdapter) emitToolCallDelta(index int, id, name, arguments string) {
	if a.streamDone || a.streamInvalid != nil {
		return
	}
	a.flushStreamTextTail(true)
	if a.textOpen {
		a.closeTextBlock()
	}
	tc := a.toolCalls[index]
	if tc == nil {
		if id == "" {
			a.emitInvalidProviderResponse("Upstream provider returned tool call without id")
			return
		}
		tc = &anthropicStreamToolCall{ID: id, Name: name, Index: -1, ProviderID: true}
		a.toolCalls[index] = tc
		a.toolOrder = append(a.toolOrder, index)
	}
	if tc.Closed {
		a.emitInvalidProviderResponse("Upstream provider returned tool-call delta after content block stop")
		return
	}
	if id != "" && id != tc.ID {
		a.emitInvalidProviderResponse("Upstream provider changed tool-call id")
		return
	}
	if name != "" && tc.Opened && name != tc.Name {
		a.emitInvalidProviderResponse("Upstream provider changed tool-call name")
		return
	}
	if name != "" {
		tc.Name = name
	}
	if !tc.Opened && strings.TrimSpace(tc.Name) == "" {
		tc.PendingArgument += arguments
		return
	}
	if !tc.Opened {
		a.openToolCallBlock(tc)
		if tc.PendingArgument != "" {
			a.emitToolCallArguments(tc, tc.PendingArgument)
			tc.PendingArgument = ""
		}
	}
	if arguments != "" {
		a.emitToolCallArguments(tc, arguments)
	}
}

func (a *anthropicMessagesAdapter) openToolCallBlock(tc *anthropicStreamToolCall) {
	tc.Opened = true
	tc.Index = a.contentIndex
	a.contentIndex++
	a.emitSSE("content_block_start", map[string]any{
		"type": "content_block_start", "index": tc.Index,
		"content_block": map[string]any{
			"type":  "tool_use",
			"id":    tc.ID,
			"name":  tc.Name,
			"input": map[string]any{},
		},
	})
}

func (a *anthropicMessagesAdapter) emitToolCallArguments(tc *anthropicStreamToolCall, arguments string) {
	tc.Arguments += arguments
	a.emitSSE("content_block_delta", map[string]any{
		"type": "content_block_delta", "index": tc.Index,
		"delta": map[string]any{"type": "input_json_delta", "partial_json": arguments},
	})
}

func (a *anthropicMessagesAdapter) closeTextBlock() {
	a.emitSSE("content_block_stop", map[string]any{"type": "content_block_stop", "index": a.contentIndex})
	a.textOpen = false
	a.contentIndex++
}

func (a *anthropicMessagesAdapter) closeToolBlocks() {
	for _, index := range a.toolOrder {
		tc := a.toolCalls[index]
		if tc == nil || !tc.Opened || tc.Closed {
			continue
		}
		a.emitSSE("content_block_stop", map[string]any{"type": "content_block_stop", "index": tc.Index})
		tc.Closed = true
	}
}

func (a *anthropicMessagesAdapter) emitMessageStop() {
	if a.streamDone {
		return
	}
	if err := a.validateStreamComplete(); err != nil {
		a.emitInvalidProviderResponse(err.Error())
		return
	}
	a.emitTerminalMessageStop()
}

func (a *anthropicMessagesAdapter) emitTerminalMessageStop() {
	if a.streamDone {
		return
	}
	if a.lineBuf.Len() > 0 {
		a.handleChatStreamLine(a.lineBuf.String())
		a.lineBuf.Reset()
		if a.streamDone || a.writeErr != nil {
			return
		}
	}
	if remainder := a.flushThinkRemainder(); remainder != "" {
		a.emitTextDelta(remainder)
	}
	if matched := a.flushStreamTextTail(true); matched != nil {
		a.finishReason = "stop_sequence"
		a.stopSequence = matched
	}
	if a.textOpen {
		a.closeTextBlock()
	}
	a.closeToolBlocks()
	usage := anthropicUsage{}
	if a.streamUsage != nil {
		usage = *a.streamUsage
	}
	toolCallCount := 0
	for _, tc := range a.toolCalls {
		if tc.Opened {
			toolCallCount++
		}
	}
	stopReason := a.terminalStopReason
	if stopReason == "" {
		stopReason = anthropicStopReason(a.finishReason, toolCallCount > 0)
	}
	a.emitSSE("message_delta", map[string]any{
		"type": "message_delta",
		"delta": map[string]any{
			"stop_reason":   stopReason,
			"stop_sequence": anthropicStopSequence(a.finishReason, a.stopSequence),
		},
		"usage": usage,
	})
	a.emitSSE("message_stop", map[string]any{"type": "message_stop"})
	a.flush()
	a.streamDone = true
}

func (a *anthropicMessagesAdapter) validateStreamComplete() error {
	if a.streamInvalid != nil {
		return a.streamInvalid
	}
	if a.lineBuf.Len() > 0 {
		line := a.lineBuf.String()
		a.lineBuf.Reset()
		a.handleChatStreamLine(line)
		if a.streamInvalid != nil {
			return a.streamInvalid
		}
	}
	if strings.TrimSpace(a.finishReason) == "" {
		return fmt.Errorf("Upstream provider stream ended without finish_reason")
	}
	seenIDs := map[string]struct{}{}
	for _, index := range a.toolOrder {
		tc := a.toolCalls[index]
		if tc == nil {
			continue
		}
		if !tc.ProviderID || strings.TrimSpace(tc.ID) == "" {
			return fmt.Errorf("Upstream provider stream ended with tool call missing id")
		}
		if _, ok := seenIDs[tc.ID]; ok {
			return fmt.Errorf("Upstream provider stream returned duplicate tool call id")
		}
		seenIDs[tc.ID] = struct{}{}
		if strings.TrimSpace(tc.Name) == "" {
			return fmt.Errorf("Upstream provider stream ended with incomplete tool call")
		}
		if strings.TrimSpace(tc.Arguments) != "" && !anthropicRawIsSingleJSONObjectNoDuplicate([]byte(tc.Arguments)) {
			return fmt.Errorf("Upstream provider stream returned invalid tool arguments")
		}
	}
	return nil
}

func (a *anthropicMessagesAdapter) emitInvalidProviderResponse(message string) {
	if a.streamDone || a.streamInvalid != nil {
		return
	}
	if strings.TrimSpace(message) == "" {
		message = "Upstream provider returned invalid response"
	}
	a.streamInvalid = &anthropicMessagesTranslationError{typ: "api_error", code: "invalid_provider_response", message: message}
	a.finishReason = "stop"
	a.streamOutcome = "invalid_provider_response"
	a.terminalStopReason = "end_turn"
	a.emitSSE("error", map[string]any{"type": "error", "error": map[string]any{
		"type":      "api_error",
		"message":   message,
		"code":      "invalid_provider_response",
		"retryable": true,
	}})
	a.emitTerminalMessageStop()
}

func (a *anthropicMessagesAdapter) hasStreamInvalid() bool {
	return a.streamInvalid != nil
}

func (a *anthropicMessagesAdapter) invalidMessage() string {
	if a.streamInvalid == nil {
		return ""
	}
	return a.streamInvalid.message
}

func (a *anthropicMessagesAdapter) settlementOutcome(defaultOutcome string) string {
	if a.streamOutcome != "" {
		return a.streamOutcome
	}
	return defaultOutcome
}

func (a *anthropicMessagesAdapter) emitSSE(event string, payload map[string]any) {
	if a.writeErr != nil {
		return
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return
	}
	a.writeBytes([]byte("event: " + event + "\n"))
	a.writeBytes([]byte("data: "))
	a.writeBytes(b)
	a.writeBytes([]byte("\n\n"))
}

func (a *anthropicMessagesAdapter) flush() {
	if f, ok := a.dst.(http.Flusher); ok {
		f.Flush()
	}
}

func (a *anthropicMessagesAdapter) writeBytes(p []byte) {
	if a.writeErr != nil || len(p) == 0 {
		return
	}
	_, a.writeErr = a.dst.Write(p)
	if a.writeErr == nil {
		a.dedupeCapture = append(a.dedupeCapture, p...)
	}
}

func (a *anthropicMessagesAdapter) effectiveMessageID() string {
	if a.messageID == "" {
		a.messageID = anthropicMessageIDFromChatID("", a.requestID)
	}
	return a.messageID
}

func anthropicStopReason(reason string, hasToolUse bool) string {
	if reason == "length" {
		return "max_tokens"
	}
	if reason == "tool_calls" || hasToolUse {
		return "tool_use"
	}
	switch reason {
	case "stop_sequence":
		return "stop_sequence"
	case "content_filter":
		return "refusal"
	default:
		return "end_turn"
	}
}

func anthropicStopReasonStrict(reason string, hasToolUse bool) (string, error) {
	switch reason {
	case "stop", "length", "stop_sequence", "content_filter":
		return anthropicStopReason(reason, hasToolUse), nil
	case "tool_calls":
		if !hasToolUse {
			return "", fmt.Errorf("finish_reason %q requires at least one tool call", reason)
		}
		return anthropicStopReason(reason, hasToolUse), nil
	default:
		return "", fmt.Errorf("finish_reason %q is not supported", reason)
	}
}

func anthropicStopSequence(finishReason string, matched *string) any {
	if finishReason != "stop_sequence" || matched == nil {
		return nil
	}
	return *matched
}

func anthropicNonEmptyStopSequences(sequences []string) []string {
	if len(sequences) == 0 {
		return nil
	}
	out := make([]string, 0, len(sequences))
	for _, sequence := range sequences {
		if sequence != "" {
			out = append(out, sequence)
		}
	}
	return out
}

func anthropicMaxStopSequenceLen(sequences []string) int {
	maxLen := 0
	for _, sequence := range sequences {
		if len(sequence) > maxLen {
			maxLen = len(sequence)
		}
	}
	return maxLen
}

func anthropicTextWithoutMatchedStopSequence(text string, sequences []string) (string, *string) {
	best := ""
	for _, sequence := range sequences {
		if sequence == "" {
			continue
		}
		if strings.HasSuffix(text, sequence) && len(sequence) > len(best) {
			best = sequence
		}
	}
	if best == "" {
		return text, nil
	}
	matched := best
	return text[:len(text)-len(best)], &matched
}

func anthropicTrimStopSequenceSuffix(text, sequence string) (string, bool) {
	if sequence == "" || !strings.HasSuffix(text, sequence) {
		return text, false
	}
	return text[:len(text)-len(sequence)], true
}

func anthropicSplitStopSequenceTail(text string, maxTailBytes int) (string, string) {
	if maxTailBytes <= 0 {
		return text, ""
	}
	if len(text) <= maxTailBytes {
		return "", text
	}
	cut := len(text) - maxTailBytes
	for cut > 0 && cut < len(text) && !utf8.RuneStart(text[cut]) {
		cut--
	}
	return text[:cut], text[cut:]
}

func anthropicFinishReasonFromTerminalErrorCode(code string) string {
	if gatewayCleanLengthTruncationTerminalCode(code) {
		return "length"
	}
	return "stop"
}

func anthropicTerminalErrorCodeIsLengthTruncation(code string) bool {
	return gatewayCleanLengthTruncationTerminalCode(code)
}

func anthropicStreamOutcomeFromTerminalErrorCode(code string) string {
	if outcome := gatewayCleanLengthTruncationSettlementOutcome(code); outcome != "" {
		return outcome
	}
	switch code {
	case "stream_truncated":
		return code
	default:
		return "invalid_provider_response"
	}
}

func anthropicStripThinkBlocks(s string) string {
	if !strings.Contains(s, "<think>") {
		return s
	}
	s = thinkBlockRE.ReplaceAllString(s, "")
	if start := strings.LastIndex(s, "<think>"); start >= 0 {
		s = s[:start]
	}
	return s
}

func (a *anthropicMessagesAdapter) filterThinkContent(s string) string {
	input := a.thinkPending + s
	a.thinkPending = ""
	var out strings.Builder
	for input != "" {
		if a.thinkInBlock {
			if end := strings.Index(input, "</think>"); end >= 0 {
				input = input[end+len("</think>"):]
				a.thinkInBlock = false
				continue
			}
			a.thinkPending = longestSuffixThatPrefixes(input, "</think>")
			return out.String()
		}
		if start := strings.Index(input, "<think>"); start >= 0 {
			out.WriteString(input[:start])
			input = input[start+len("<think>"):]
			a.thinkInBlock = true
			continue
		}
		a.thinkPending = longestSuffixThatPrefixes(input, "<think>")
		out.WriteString(input[:len(input)-len(a.thinkPending)])
		return out.String()
	}
	return out.String()
}

func (a *anthropicMessagesAdapter) flushThinkRemainder() string {
	if a.thinkInBlock {
		a.thinkPending = ""
		return ""
	}
	remainder := a.thinkPending
	a.thinkPending = ""
	return remainder
}

func anthropicResponseContentToText(v any) (string, error) {
	switch typed := v.(type) {
	case nil:
		return "", nil
	case string:
		return typed, nil
	case []any:
		parts := make([]string, 0, len(typed))
		for i, part := range typed {
			if m, ok := part.(map[string]any); ok {
				if err := anthropicValidateProviderTextContentPart(m, i); err != nil {
					return "", err
				}
				s, ok := m["text"].(string)
				if !ok {
					return "", fmt.Errorf("content[%d].text must be a string", i)
				}
				parts = append(parts, s)
			} else if s, ok := part.(string); ok {
				parts = append(parts, s)
			} else {
				return "", fmt.Errorf("content[%d] is not supported", i)
			}
		}
		return strings.Join(parts, ""), nil
	default:
		return "", fmt.Errorf("message content shape is not supported")
	}
}

func anthropicValidateProviderTextContentPart(m map[string]any, index int) error {
	for key := range m {
		switch key {
		case "type", "text":
		default:
			return fmt.Errorf("content[%d].%s is not supported", index, key)
		}
	}
	typ, ok := m["type"].(string)
	if !ok || typ != "text" {
		if ok {
			return fmt.Errorf("content[%d].type %q is not supported", index, typ)
		}
		return fmt.Errorf("content[%d].type is required", index)
	}
	if _, ok := m["text"]; !ok {
		return fmt.Errorf("content[%d].text is required", index)
	}
	return nil
}

func anthropicStandaloneStreamErrorFromOpenAIData(data string) (string, string, string, bool, bool) {
	if terminalSSEErrorCode(data) == "" {
		return "", "", "", false, false
	}
	var frame struct {
		Error *struct {
			Message   string `json:"message"`
			Type      string `json:"type"`
			Code      string `json:"code"`
			Retryable *bool  `json:"retryable"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(data), &frame); err != nil || frame.Error == nil {
		return "", "", "", false, false
	}
	typ := anthropicErrorTypeFromOpenAI(frame.Error.Type, frame.Error.Code)
	msg := frame.Error.Message
	if msg == "" {
		msg = "Upstream provider failed"
	}
	retryable := gatewayRetryable(frame.Error.Code)
	if frame.Error.Retryable != nil {
		retryable = *frame.Error.Retryable
	}
	return typ, frame.Error.Code, msg, retryable, true
}

func anthropicErrorFromOpenAIError(body []byte) (string, string, string, bool) {
	var env struct {
		Error *struct {
			Message   string `json:"message"`
			Type      string `json:"type"`
			Code      string `json:"code"`
			Retryable *bool  `json:"retryable"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &env); err == nil && env.Error != nil {
		msg := env.Error.Message
		if msg == "" {
			msg = "Request failed"
		}
		code := env.Error.Code
		if code == "" {
			code = "invalid_request"
		}
		retryable := gatewayRetryable(code)
		if env.Error.Retryable != nil {
			retryable = *env.Error.Retryable
		}
		return anthropicErrorTypeFromOpenAI(env.Error.Type, code), code, msg, retryable
	}
	return "api_error", "invalid_request", "Request failed", false
}

func anthropicErrorTypeFromOpenAI(openAIType, code string) string {
	switch openAIType {
	case "authentication_error":
		return "authentication_error"
	case "permission_error":
		return "permission_error"
	case "invalid_request_error":
		return "invalid_request_error"
	case "rate_limit_exceeded":
		return "rate_limit_error"
	}
	switch code {
	case "quota_exhausted", "account_request_rate_exceeded", "account_concurrency_exceeded", "demo_concurrency_exceeded":
		return "rate_limit_error"
	default:
		return "api_error"
	}
}

func anthropicRawIsNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

func firstNonNilMapValue(m map[string]any, key string, fallback any) any {
	if v, ok := m[key]; ok && v != nil {
		return v
	}
	return fallback
}

type anthropicToolCallDelta struct {
	index     int
	id        string
	name      string
	arguments string
}

func anthropicToolCallDeltasFromAny(v any) ([]anthropicToolCallDelta, error) {
	if v == nil {
		return nil, nil
	}
	items, ok := v.([]any)
	if !ok {
		return nil, fmt.Errorf("Upstream provider returned malformed stream tool calls")
	}
	out := make([]anthropicToolCallDelta, 0, len(items))
	for _, item := range items {
		m, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("Upstream provider returned malformed stream tool call")
		}
		if typ := anthropicStringFromAny(m["type"]); typ != "" && typ != "function" {
			return nil, fmt.Errorf("Upstream provider returned unsupported stream tool-call type")
		}
		index, ok := anthropicIntFromAny(m["index"])
		if !ok {
			return nil, fmt.Errorf("Upstream provider returned stream tool call without index")
		}
		delta := anthropicToolCallDelta{index: index, id: anthropicStringFromAny(m["id"])}
		if rawFn, ok := m["function"]; ok && rawFn != nil {
			fn, ok := rawFn.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("Upstream provider returned malformed stream tool-call function")
			}
			delta.name = anthropicStringFromAny(fn["name"])
			delta.arguments = anthropicStringFromAny(fn["arguments"])
			if rawName, ok := fn["name"]; ok && rawName != nil && delta.name == "" {
				return nil, fmt.Errorf("Upstream provider returned malformed stream tool-call name")
			}
			if rawArgs, ok := fn["arguments"]; ok && rawArgs != nil {
				if _, ok := rawArgs.(string); !ok {
					return nil, fmt.Errorf("Upstream provider returned malformed stream tool-call arguments")
				}
			}
		}
		out = append(out, delta)
	}
	return out, nil
}

func anthropicStringFromAny(v any) string {
	s, _ := v.(string)
	return s
}

func anthropicIntFromAny(v any) (int, bool) {
	switch typed := v.(type) {
	case float64:
		i := int(typed)
		return i, typed == float64(i)
	case int:
		return typed, true
	default:
		return 0, false
	}
}

func anthropicRawHasDuplicateKeys(raw json.RawMessage) bool {
	if len(bytes.TrimSpace(raw)) == 0 || anthropicRawIsNull(raw) {
		return false
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	return anthropicValueHasDuplicateKeys(dec)
}

func anthropicRawIsSingleJSONObjectNoDuplicate(raw json.RawMessage) bool {
	if anthropicRawHasDuplicateKeys(raw) {
		return false
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	var v any
	if err := dec.Decode(&v); err != nil {
		return false
	}
	if _, ok := v.(map[string]any); !ok {
		return false
	}
	return dec.Decode(&v) == io.EOF
}

func anthropicValidateNonStreamingProviderRaw(raw json.RawMessage) error {
	root, err := anthropicRawObject(raw)
	if err != nil {
		return fmt.Errorf("provider response must be an object")
	}
	if choicesRaw, ok := root["choices"]; ok {
		var choices []json.RawMessage
		if err := json.Unmarshal(choicesRaw, &choices); err != nil {
			return fmt.Errorf("provider response choices must be an array")
		}
		if len(choices) != 1 {
			return fmt.Errorf("provider response must contain exactly one choice")
		}
		if err := anthropicValidateProviderChoiceRaw("provider response.choices[0]", choices[0], false); err != nil {
			return err
		}
	}
	return nil
}

func anthropicValidateStreamProviderRaw(raw json.RawMessage) error {
	root, err := anthropicRawObject(raw)
	if err != nil {
		return fmt.Errorf("Upstream provider returned malformed stream data")
	}
	if choicesRaw, ok := root["choices"]; ok {
		var choices []json.RawMessage
		if err := json.Unmarshal(choicesRaw, &choices); err != nil {
			return fmt.Errorf("Upstream provider returned malformed stream choices")
		}
		if len(choices) > 1 {
			return fmt.Errorf("Upstream provider returned multiple stream choices")
		}
		if len(choices) == 1 {
			if err := anthropicValidateProviderChoiceRaw("stream chunk.choices[0]", choices[0], true); err != nil {
				return err
			}
		}
	}
	return nil
}

func anthropicValidateProviderChoiceRaw(path string, raw json.RawMessage, streaming bool) error {
	choice, err := anthropicRawObject(raw)
	if err != nil {
		return fmt.Errorf("%s must be an object", path)
	}
	if streaming {
		if err := anthropicRejectUnknownKeys(choice, path, "index", "delta", "finish_reason", "stop_sequence", "logprobs"); err != nil {
			return err
		}
		if err := anthropicValidateProviderStopSequenceRaw(choice, path); err != nil {
			return err
		}
		if deltaRaw, ok := choice["delta"]; ok && !anthropicRawIsNull(deltaRaw) {
			delta, err := anthropicRawObject(deltaRaw)
			if err != nil {
				return fmt.Errorf("%s.delta must be an object", path)
			}
			if err := anthropicRejectUnknownKeys(delta, path+".delta", "role", "content", "refusal", "tool_calls"); err != nil {
				return err
			}
			if refusalRaw, ok := delta["refusal"]; ok && !anthropicRawIsNull(refusalRaw) {
				if err := anthropicValidateRawString(refusalRaw, path+".delta.refusal"); err != nil {
					return err
				}
			}
			if toolCallsRaw, ok := delta["tool_calls"]; ok {
				if err := anthropicValidateProviderToolCallsRaw(path+".delta.tool_calls", toolCallsRaw); err != nil {
					return err
				}
			}
		}
		return nil
	}
	if err := anthropicRejectUnknownKeys(choice, path, "index", "message", "finish_reason", "stop_sequence", "logprobs"); err != nil {
		return err
	}
	if err := anthropicValidateProviderStopSequenceRaw(choice, path); err != nil {
		return err
	}
	if messageRaw, ok := choice["message"]; ok && !anthropicRawIsNull(messageRaw) {
		message, err := anthropicRawObject(messageRaw)
		if err != nil {
			return fmt.Errorf("%s.message must be an object", path)
		}
		if err := anthropicRejectUnknownKeys(message, path+".message", "role", "content", "refusal", "tool_calls"); err != nil {
			return err
		}
		if refusalRaw, ok := message["refusal"]; ok && !anthropicRawIsNull(refusalRaw) {
			if err := anthropicValidateRawString(refusalRaw, path+".message.refusal"); err != nil {
				return err
			}
		}
		if toolCallsRaw, ok := message["tool_calls"]; ok {
			if err := anthropicValidateProviderToolCallsRaw(path+".message.tool_calls", toolCallsRaw); err != nil {
				return err
			}
		}
	}
	return nil
}

func anthropicValidateProviderStopSequenceRaw(choice map[string]json.RawMessage, path string) error {
	if raw, ok := choice["stop_sequence"]; ok && !anthropicRawIsNull(raw) {
		if err := anthropicValidateRawString(raw, path+".stop_sequence"); err != nil {
			return err
		}
	}
	return nil
}

func anthropicValidateProviderToolCallsRaw(path string, raw json.RawMessage) error {
	var calls []json.RawMessage
	if err := json.Unmarshal(raw, &calls); err != nil {
		return fmt.Errorf("%s must be an array", path)
	}
	for i, callRaw := range calls {
		callPath := fmt.Sprintf("%s[%d]", path, i)
		call, err := anthropicRawObject(callRaw)
		if err != nil {
			return fmt.Errorf("%s must be an object", callPath)
		}
		if err := anthropicRejectUnknownKeys(call, callPath, "index", "id", "type", "function"); err != nil {
			return err
		}
		if fnRaw, ok := call["function"]; ok && !anthropicRawIsNull(fnRaw) {
			fn, err := anthropicRawObject(fnRaw)
			if err != nil {
				return fmt.Errorf("%s.function must be an object", callPath)
			}
			if err := anthropicRejectUnknownKeys(fn, callPath+".function", "name", "arguments"); err != nil {
				return err
			}
		}
	}
	return nil
}

func anthropicRawString(raw json.RawMessage, path string) (string, error) {
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", fmt.Errorf("%s must be a string", path)
	}
	return value, nil
}

func anthropicValidateRawString(raw json.RawMessage, path string) error {
	_, err := anthropicRawString(raw, path)
	return err
}

func anthropicValidateRawBool(raw json.RawMessage, path string) error {
	var value bool
	if err := json.Unmarshal(raw, &value); err != nil {
		return fmt.Errorf("%s must be a boolean", path)
	}
	return nil
}

func anthropicValidateRawInteger(raw json.RawMessage, path string) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var value any
	if err := dec.Decode(&value); err != nil {
		return fmt.Errorf("%s must be an integer", path)
	}
	n, ok := value.(json.Number)
	if !ok {
		return fmt.Errorf("%s must be an integer", path)
	}
	if _, err := n.Int64(); err != nil {
		return fmt.Errorf("%s must be an integer", path)
	}
	return nil
}

func anthropicValidateRawNumber(raw json.RawMessage, path string) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var value any
	if err := dec.Decode(&value); err != nil {
		return fmt.Errorf("%s must be a number", path)
	}
	if _, ok := value.(json.Number); !ok {
		return fmt.Errorf("%s must be a number", path)
	}
	return nil
}

func anthropicValidateRawStringArray(raw json.RawMessage, path string) error {
	var items []json.RawMessage
	if err := json.Unmarshal(raw, &items); err != nil {
		return fmt.Errorf("%s must be an array of strings", path)
	}
	for i, item := range items {
		if err := anthropicValidateRawString(item, fmt.Sprintf("%s[%d]", path, i)); err != nil {
			return err
		}
	}
	return nil
}

func anthropicRawObject(raw json.RawMessage) (map[string]json.RawMessage, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil || m == nil {
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("not an object")
	}
	return m, nil
}

func anthropicRejectUnknownKeys(m map[string]json.RawMessage, path string, allowed ...string) error {
	allowedSet := make(map[string]struct{}, len(allowed))
	for _, key := range allowed {
		allowedSet[key] = struct{}{}
	}
	for key := range m {
		if _, ok := allowedSet[key]; !ok {
			return fmt.Errorf("%s.%s is not supported", path, key)
		}
	}
	return nil
}

func anthropicValueHasDuplicateKeys(dec *json.Decoder) bool {
	tok, err := dec.Token()
	if err != nil {
		return false
	}
	switch delim := tok.(type) {
	case json.Delim:
		switch delim {
		case '{':
			keys := map[string]struct{}{}
			for dec.More() {
				keyTok, err := dec.Token()
				if err != nil {
					return false
				}
				key, ok := keyTok.(string)
				if !ok {
					return false
				}
				if _, dup := keys[key]; dup {
					return true
				}
				keys[key] = struct{}{}
				if anthropicValueHasDuplicateKeys(dec) {
					return true
				}
			}
			_, _ = dec.Token()
		case '[':
			for dec.More() {
				if anthropicValueHasDuplicateKeys(dec) {
					return true
				}
			}
			_, _ = dec.Token()
		}
	}
	return false
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func anthropicMessageIDFromChatID(chatID, requestID string) string {
	source := firstNonEmpty(chatID, requestID)
	return "msg_" + anthropicIDSuffix(source)
}

func anthropicIDSuffix(id string) string {
	var b strings.Builder
	for _, r := range id {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	out := strings.Trim(b.String(), "_")
	if out == "" {
		return "generated"
	}
	if len(out) > 48 {
		return out[len(out)-48:]
	}
	return out
}
