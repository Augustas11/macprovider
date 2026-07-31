package router

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"
)

type responsesAdapterContextKey struct{}

type responsesTranslationError struct {
	code    string
	param   string
	message string
}

func (e responsesTranslationError) Error() string { return e.message }

type responsesAdapter struct {
	dst       http.ResponseWriter
	requestID string
	now       func() time.Time

	model             string
	instructions      *string
	maxOutputTokens   *int64
	stream            bool
	tools             []map[string]any
	toolChoice        any
	textFormat        any
	parallelToolCalls bool

	status      int
	wroteHeader bool
	body        bytes.Buffer
	lineBuf     bytes.Buffer
	prepared    []byte
	finished    bool
	passthrough bool

	responseID     string
	messageID      string
	messageOut     int
	nextOut        int
	streamUsage    map[string]any
	finishReason   string
	streamTerminal bool
	text           strings.Builder
	textOpen       bool
	thinkPending   string
	thinkInBlock   bool
	seq            int64
	toolCalls      map[int]*responsesStreamToolCall
	writeErr       error

	captureArmed bool
	captureCap   int
	capture      []byte
	overflowed   bool
}

type responsesStreamToolCall struct {
	ID        string
	CallID    string
	Name      string
	Output    int
	Arguments strings.Builder
	Opened    bool
}

func (s *Server) handleResponses(w http.ResponseWriter, r *http.Request) {
	adapter := newResponsesAdapter(w, requestID(r), s.now)
	ctx := context.WithValue(r.Context(), responsesAdapterContextKey{}, adapter)
	s.handleChatCompletions(adapter, r.WithContext(ctx))
	adapter.finish()
}

func newResponsesAdapter(dst http.ResponseWriter, requestID string, now func() time.Time) *responsesAdapter {
	if now == nil {
		now = func() time.Time { return time.Now().UTC() }
	}
	return &responsesAdapter{
		dst:               dst,
		requestID:         requestID,
		now:               now,
		messageOut:        -1,
		toolCalls:         make(map[int]*responsesStreamToolCall),
		parallelToolCalls: true,
	}
}

func responsesAdapterFromContext(ctx context.Context) *responsesAdapter {
	adapter, _ := ctx.Value(responsesAdapterContextKey{}).(*responsesAdapter)
	return adapter
}

func writeResponsesTranslationError(w http.ResponseWriter, status int, err *responsesTranslationError) {
	retryable := gatewayRetryable(err.code)
	setGatewayRetryAfter(w, status, err.code, retryable)
	param := any(nil)
	if err.param != "" {
		param = err.param
	}
	writeJSON(w, status, map[string]any{
		"error": map[string]any{
			"message":   err.message,
			"type":      "invalid_request_error",
			"param":     param,
			"code":      err.code,
			"retryable": retryable,
		},
	})
}

func (a *responsesAdapter) Header() http.Header {
	return a.dst.Header()
}

func (a *responsesAdapter) WriteHeader(code int) {
	if a.wroteHeader {
		return
	}
	a.status = code
	a.wroteHeader = true
	if a.passthrough {
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
		a.emitResponsesSSE("response.created", map[string]any{
			"type":            "response.created",
			"response":        a.responseObject("in_progress", nil),
			"sequence_number": a.nextSeq(),
		})
		a.flush()
	}
}

func (a *responsesAdapter) Write(p []byte) (int, error) {
	if !a.wroteHeader {
		a.WriteHeader(http.StatusOK)
	}
	if a.passthrough {
		return a.dst.Write(p)
	}
	if !a.stream || a.status != http.StatusOK {
		_, _ = a.body.Write(p)
		return len(p), nil
	}
	a.lineBuf.Write(p)
	for {
		line, err := a.lineBuf.ReadString('\n')
		if err != nil {
			a.lineBuf.WriteString(line)
			return len(p), nil
		}
		a.handleChatStreamLine(line)
		if a.writeErr != nil {
			return 0, a.writeErr
		}
	}
}

func (a *responsesAdapter) Flush() {
	if a.stream || a.passthrough {
		a.flush()
	}
}

func (a *responsesAdapter) beginReplayPassthrough() {
	a.passthrough = true
	a.finished = true
}

func (a *responsesAdapter) endReplayPassthrough() {
	a.passthrough = false
	a.finished = false
}

func (a *responsesAdapter) finish() {
	if a.finished {
		return
	}
	a.finished = true
	if a.stream {
		if a.status != 0 && a.status != http.StatusOK {
			a.dst.WriteHeader(a.status)
			_, _ = a.writeFinalBytes(a.body.Bytes())
			return
		}
		if a.lineBuf.Len() > 0 && a.status == http.StatusOK {
			a.handleChatStreamLine(a.lineBuf.String())
			a.lineBuf.Reset()
		}
		if a.status == http.StatusOK && !a.streamTerminal {
			a.emitStreamDone()
		}
		return
	}
	status := a.status
	if status == 0 {
		status = http.StatusOK
	}
	if status == http.StatusOK {
		body := a.prepared
		var err error
		if body == nil {
			body, err = a.translateNonStreamingResponse(a.body.Bytes())
		}
		if err != nil {
			writeError(a.dst, http.StatusBadGateway, "api_error", "invalid_provider_response", "Upstream provider returned invalid response")
			return
		}
		a.dst.Header().Set("Content-Type", "application/json")
		a.dst.WriteHeader(http.StatusOK)
		_, _ = a.writeFinalBytes(body)
		return
	}
	a.dst.WriteHeader(status)
	_, _ = a.writeFinalBytes(a.body.Bytes())
}

func (a *responsesAdapter) prepareNonStreamingResponse(body []byte) error {
	translated, err := a.translateNonStreamingResponse(body)
	if err != nil {
		return err
	}
	a.prepared = translated
	return nil
}

func (a *responsesAdapter) translateRequest(body []byte) ([]byte, *responsesTranslationError) {
	var req struct {
		Model              string           `json:"model"`
		Input              json.RawMessage  `json:"input"`
		Instructions       *string          `json:"instructions"`
		Tools              []map[string]any `json:"tools"`
		ToolChoice         any              `json:"tool_choice"`
		MaxOutputTokens    *int64           `json:"max_output_tokens"`
		Stream             bool             `json:"stream"`
		PreviousResponseID *string          `json:"previous_response_id"`
		Store              *bool            `json:"store"`
		Temperature        any              `json:"temperature"`
		TopP               any              `json:"top_p"`
		ResponseFormat     json.RawMessage  `json:"response_format"`
		Text               json.RawMessage  `json:"text"`
		Metadata           any              `json:"metadata"`
		User               any              `json:"user"`
		Reasoning          any              `json:"reasoning"`
		ParallelToolCalls  any              `json:"parallel_tool_calls"`
		Conversation       json.RawMessage  `json:"conversation"`
		Include            json.RawMessage  `json:"include"`
		Truncation         *string          `json:"truncation"`
		Background         *bool            `json:"background"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return nil, &responsesTranslationError{code: "invalid_request", message: "Malformed JSON"}
	}
	if strings.TrimSpace(req.Model) == "" {
		return nil, &responsesTranslationError{code: "invalid_request", message: "model is required"}
	}
	if len(bytes.TrimSpace(req.Input)) == 0 || bytes.Equal(bytes.TrimSpace(req.Input), []byte("null")) {
		return nil, &responsesTranslationError{code: "invalid_request", message: "input is required"}
	}
	if req.PreviousResponseID != nil && strings.TrimSpace(*req.PreviousResponseID) != "" {
		return nil, &responsesTranslationError{code: "unsupported_parameter", param: "previous_response_id", message: "previous_response_id is not supported; send the full input with store:false"}
	}
	if req.Store != nil && *req.Store {
		return nil, &responsesTranslationError{code: "unsupported_parameter", param: "store", message: "store:true is not supported; send the full input with store:false"}
	}
	if err := validateResponsesTools(req.Tools); err != nil {
		return nil, err
	}
	if err := validateResponsesControls(req.Conversation, req.Truncation, req.Background, req.ResponseFormat); err != nil {
		return nil, err
	}
	textFormat, chatResponseFormat, textErr := responsesTextConfigToChatResponseFormat(req.Text)
	if textErr != nil {
		return nil, textErr
	}
	messages, inputErr := responsesInputToChatMessages(req.Instructions, req.Input)
	if inputErr != nil {
		return nil, &responsesTranslationError{code: "invalid_request", message: inputErr.Error()}
	}
	chat := map[string]any{
		"model":    req.Model,
		"messages": messages,
		"stream":   req.Stream,
	}
	if req.MaxOutputTokens != nil {
		chat["max_tokens"] = *req.MaxOutputTokens
	}
	chatTools, toolsErr := responsesToolsToChatTools(req.Tools)
	if toolsErr != nil {
		return nil, toolsErr
	}
	if len(chatTools) > 0 {
		chat["tools"] = chatTools
	}
	if req.ToolChoice != nil {
		toolChoice, choiceErr := responsesToolChoiceToChatToolChoice(req.ToolChoice, chatTools)
		if choiceErr != nil {
			return nil, choiceErr
		}
		if toolChoice != nil {
			chat["tool_choice"] = toolChoice
		}
	}
	if len(chatResponseFormat) > 0 {
		chat["response_format"] = json.RawMessage(chatResponseFormat)
	}
	if parallelToolCalls, ok := req.ParallelToolCalls.(bool); ok {
		chat["parallel_tool_calls"] = parallelToolCalls
		a.parallelToolCalls = parallelToolCalls
	}
	if req.Temperature != nil {
		chat["temperature"] = req.Temperature
	}
	if req.TopP != nil {
		chat["top_p"] = req.TopP
	}
	if req.User != nil {
		chat["user"] = req.User
	}
	body, marshalErr := json.Marshal(chat)
	if marshalErr != nil {
		return nil, &responsesTranslationError{code: "invalid_request", message: "Could not encode translated request"}
	}
	a.model = req.Model
	a.instructions = req.Instructions
	a.maxOutputTokens = req.MaxOutputTokens
	a.stream = req.Stream
	a.tools = responsesToolsEchoFromChatTools(chatTools)
	a.toolChoice = req.ToolChoice
	a.textFormat = textFormat
	return body, nil
}

func responsesInputToChatMessages(instructions *string, input json.RawMessage) ([]map[string]any, error) {
	messages := make([]map[string]any, 0, 4)
	if instructions != nil && strings.TrimSpace(*instructions) != "" {
		messages = append(messages, map[string]any{"role": "system", "content": *instructions})
	}
	var text string
	if err := json.Unmarshal(input, &text); err == nil {
		if strings.TrimSpace(text) == "" {
			return nil, fmt.Errorf("input is required")
		}
		messages = append(messages, map[string]any{"role": "user", "content": text})
		return messages, nil
	}
	var items []map[string]any
	if err := json.Unmarshal(input, &items); err != nil {
		return nil, fmt.Errorf("input must be a string or array")
	}
	for _, item := range items {
		converted, ok, err := responsesInputItemToChatMessage(item)
		if err != nil {
			return nil, err
		}
		if ok {
			messages = append(messages, converted)
		}
	}
	if len(messages) == 0 || (len(messages) == 1 && messages[0]["role"] == "system") {
		return nil, fmt.Errorf("input produced no chat messages")
	}
	return messages, nil
}

func responsesInputItemToChatMessage(item map[string]any) (map[string]any, bool, error) {
	itemType, _ := item["type"].(string)
	switch itemType {
	case "input_image", "input_file", "input_audio", "image_generation_call", "file_search_call", "web_search_call", "computer_call", "code_interpreter_call", "mcp_call":
		return nil, false, fmt.Errorf("%s input is not supported", itemType)
	case "function_call_output":
		callID, _ := item["call_id"].(string)
		output := responsesContentToText(item["output"])
		if callID == "" {
			callID, _ = item["id"].(string)
		}
		return map[string]any{"role": "tool", "tool_call_id": callID, "content": output}, true, nil
	case "function_call":
		name, _ := item["name"].(string)
		args := responsesContentToText(item["arguments"])
		callID, _ := item["call_id"].(string)
		id, _ := item["id"].(string)
		toolCallID := callID
		if toolCallID == "" {
			toolCallID = id
		}
		return map[string]any{
			"role":    "assistant",
			"content": nil,
			"tool_calls": []map[string]any{{
				"id":   toolCallID,
				"type": "function",
				"function": map[string]any{
					"name":      name,
					"arguments": args,
				},
			}},
		}, true, nil
	}
	role, _ := item["role"].(string)
	if role == "" {
		if itemType == "message" {
			role = "user"
		} else {
			return nil, false, nil
		}
	}
	if role == "developer" {
		role = "system"
	}
	if !responsesContentSupported(item["content"]) {
		return nil, false, fmt.Errorf("non-text content is not supported")
	}
	content := responsesContentToText(item["content"])
	if content == "" && itemType != "message" {
		return nil, false, nil
	}
	return map[string]any{"role": role, "content": content}, true, nil
}

func responsesContentSupported(v any) bool {
	parts, ok := v.([]any)
	if !ok {
		return true
	}
	for _, part := range parts {
		m, ok := part.(map[string]any)
		if !ok {
			continue
		}
		if typ, _ := m["type"].(string); typ != "" && typ != "input_text" && typ != "output_text" && typ != "text" {
			return false
		}
	}
	return true
}

func responsesContentToText(v any) string {
	switch typed := v.(type) {
	case nil:
		return ""
	case string:
		return typed
	case []any:
		parts := make([]string, 0, len(typed))
		for _, part := range typed {
			if m, ok := part.(map[string]any); ok {
				for _, key := range []string{"text", "input_text", "output_text"} {
					if s, ok := m[key].(string); ok {
						parts = append(parts, s)
						break
					}
				}
			} else if s, ok := part.(string); ok {
				parts = append(parts, s)
			}
		}
		return strings.Join(parts, "")
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return ""
		}
		return string(b)
	}
}

func validateResponsesTools(tools []map[string]any) *responsesTranslationError {
	// Responses clients may send hosted or namespace tool declarations that this
	// local Chat Completions provider cannot execute. Translation flattens usable
	// function tools and drops the rest instead of rejecting the whole turn.
	return nil
}

func validateResponsesControls(conversation json.RawMessage, truncation *string, background *bool, responseFormat json.RawMessage) *responsesTranslationError {
	if len(bytes.TrimSpace(responseFormat)) > 0 && !jsonRawIsNull(responseFormat) {
		return &responsesTranslationError{code: "unsupported_parameter", param: "response_format", message: "response_format is not supported on /v1/responses; use text.format"}
	}
	if len(bytes.TrimSpace(conversation)) > 0 && !jsonRawIsEmptyValue(conversation) {
		return &responsesTranslationError{code: "unsupported_parameter", param: "conversation", message: "conversation is not supported; send the full input with store:false"}
	}
	if background != nil && *background {
		return &responsesTranslationError{code: "unsupported_parameter", param: "background", message: "background:true is not supported"}
	}
	if truncation != nil && *truncation != "" && *truncation != "disabled" {
		return &responsesTranslationError{code: "unsupported_parameter", param: "truncation", message: "Only truncation:\"disabled\" is supported"}
	}
	return nil
}

func jsonRawIsNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

func jsonRawIsEmptyValue(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return true
	}
	var v any
	if err := json.Unmarshal(trimmed, &v); err != nil {
		return false
	}
	return jsonLikeEmpty(v)
}

func jsonLikeEmpty(v any) bool {
	if v == nil {
		return true
	}
	switch typed := v.(type) {
	case map[string]any:
		return len(typed) == 0
	case []any:
		return len(typed) == 0
	default:
		return false
	}
}

func responsesTextConfigToChatResponseFormat(raw json.RawMessage) (any, json.RawMessage, *responsesTranslationError) {
	format := map[string]any{"type": "text"}
	if len(bytes.TrimSpace(raw)) == 0 || jsonRawIsNull(raw) {
		return format, nil, nil
	}
	var text struct {
		Format map[string]any `json:"format"`
	}
	if err := json.Unmarshal(raw, &text); err != nil {
		return nil, nil, &responsesTranslationError{code: "invalid_request", param: "text", message: "text must be an object"}
	}
	if text.Format == nil {
		return format, nil, nil
	}
	typ, _ := text.Format["type"].(string)
	switch typ {
	case "", "text":
		return map[string]any{"type": "text"}, nil, nil
	case "json_object":
		chat, err := json.Marshal(map[string]any{"type": "json_object"})
		if err != nil {
			return nil, nil, &responsesTranslationError{code: "invalid_request", param: "text.format", message: "Could not encode text.format"}
		}
		return cloneMap(text.Format), chat, nil
	case "json_schema":
		jsonSchema := map[string]any{}
		for _, key := range []string{"name", "description", "schema", "strict"} {
			if value, ok := text.Format[key]; ok {
				jsonSchema[key] = value
			}
		}
		if _, ok := jsonSchema["name"]; !ok {
			return nil, nil, &responsesTranslationError{code: "invalid_request", param: "text.format.name", message: "text.format.name is required for json_schema"}
		}
		if _, ok := jsonSchema["schema"]; !ok {
			return nil, nil, &responsesTranslationError{code: "invalid_request", param: "text.format.schema", message: "text.format.schema is required for json_schema"}
		}
		chat, err := json.Marshal(map[string]any{"type": "json_schema", "json_schema": jsonSchema})
		if err != nil {
			return nil, nil, &responsesTranslationError{code: "invalid_request", param: "text.format", message: "Could not encode text.format"}
		}
		return cloneMap(text.Format), chat, nil
	default:
		return nil, nil, &responsesTranslationError{code: "unsupported_parameter", param: "text.format.type", message: fmt.Sprintf("text.format.type %q is not supported", typ)}
	}
}

func cloneMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func responsesToolsToChatTools(tools []map[string]any) ([]map[string]any, *responsesTranslationError) {
	out := make([]map[string]any, 0, len(tools))
	usedNames := make(map[string]struct{}, len(tools))
	var addFunction func(tool map[string]any) *responsesTranslationError
	addFunction = func(tool map[string]any) *responsesTranslationError {
		fn := map[string]any{}
		for _, key := range []string{"name", "description", "parameters", "strict"} {
			if value, ok := tool[key]; ok {
				fn[key] = value
			}
		}
		name, _ := fn["name"].(string)
		if name != "" {
			if _, exists := usedNames[name]; exists {
				return &responsesTranslationError{code: "unsupported_parameter", param: "tools", message: fmt.Sprintf("tools contains multiple functions named %q after flattening", name)}
			}
			usedNames[name] = struct{}{}
		}
		out = append(out, map[string]any{"type": "function", "function": fn})
		return nil
	}
	for _, tool := range tools {
		switch typ, _ := tool["type"].(string); typ {
		case "function":
			if err := addFunction(tool); err != nil {
				return nil, err
			}
		case "namespace":
			for _, nested := range responsesNestedTools(tool["tools"]) {
				if nestedType, _ := nested["type"].(string); nestedType == "function" {
					if err := addFunction(nested); err != nil {
						return nil, err
					}
				}
			}
		}
	}
	return out, nil
}

func responsesToolsEchoFromChatTools(tools []map[string]any) []map[string]any {
	if len(tools) == 0 {
		return nil
	}
	out := make([]map[string]any, 0, len(tools))
	for _, tool := range tools {
		fn, _ := tool["function"].(map[string]any)
		if fn == nil {
			continue
		}
		echo := map[string]any{"type": "function"}
		for _, key := range []string{"name", "description", "parameters", "strict"} {
			if value, ok := fn[key]; ok {
				echo[key] = value
			}
		}
		out = append(out, echo)
	}
	return out
}

func responsesNestedTools(v any) []map[string]any {
	switch typed := v.(type) {
	case []map[string]any:
		return typed
	case []any:
		out := make([]map[string]any, 0, len(typed))
		for _, item := range typed {
			if tool, ok := item.(map[string]any); ok {
				out = append(out, tool)
			}
		}
		return out
	default:
		return nil
	}
}

func responsesToolChoiceToChatToolChoice(choice any, tools []map[string]any) (any, *responsesTranslationError) {
	if s, ok := choice.(string); ok {
		switch s {
		case "auto", "none":
			return choice, nil
		case "required":
			if len(tools) == 0 {
				return nil, &responsesTranslationError{code: "unsupported_parameter", param: "tool_choice", message: "tool_choice requires at least one supported function tool"}
			}
			return choice, nil
		default:
			return nil, &responsesTranslationError{code: "unsupported_parameter", param: "tool_choice", message: fmt.Sprintf("tool_choice %q is not supported", s)}
		}
	}
	m, ok := choice.(map[string]any)
	if !ok {
		return choice, nil
	}
	if typ, _ := m["type"].(string); typ == "function" {
		if name, _ := m["name"].(string); name != "" {
			if !responsesChatToolsContainName(tools, name) {
				return nil, &responsesTranslationError{code: "unsupported_parameter", param: "tool_choice", message: fmt.Sprintf("tool_choice references unavailable function tool %q", name)}
			}
			return map[string]any{"type": "function", "function": map[string]any{"name": name}}, nil
		}
	}
	return nil, &responsesTranslationError{code: "unsupported_parameter", param: "tool_choice", message: "tool_choice is not supported by the Responses facade"}
}

func responsesChatToolsContainName(tools []map[string]any, name string) bool {
	for _, tool := range tools {
		fn, _ := tool["function"].(map[string]any)
		if got, _ := fn["name"].(string); got == name {
			return true
		}
	}
	return false
}

func (a *responsesAdapter) translateNonStreamingResponse(body []byte) ([]byte, error) {
	var chat struct {
		ID      string `json:"id"`
		Created int64  `json:"created"`
		Model   string `json:"model"`
		Usage   struct {
			PromptTokens       int64 `json:"prompt_tokens"`
			CachedPromptTokens int64 `json:"cached_prompt_tokens"`
			CompletionTokens   int64 `json:"completion_tokens"`
			TotalTokens        int64 `json:"total_tokens"`
		} `json:"usage"`
		Choices []struct {
			Message      json.RawMessage `json:"message"`
			FinishReason string          `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &chat); err != nil {
		return nil, err
	}
	id := responsesIDFromChatID(chat.ID, a.requestID)
	created := chat.Created
	if created == 0 {
		created = a.now().Unix()
	}
	model := chat.Model
	if model == "" {
		model = a.model
	}
	output := []map[string]any{}
	if len(chat.Choices) == 0 {
		return nil, fmt.Errorf("missing choices")
	}
	if len(bytes.TrimSpace(chat.Choices[0].Message)) == 0 || jsonRawIsNull(chat.Choices[0].Message) {
		return nil, fmt.Errorf("missing assistant message")
	}
	var msg struct {
		Role         string  `json:"role"`
		Content      any     `json:"content"`
		Refusal      *string `json:"refusal"`
		FunctionCall *struct {
			Name      string `json:"name"`
			Arguments string `json:"arguments"`
		} `json:"function_call"`
		ToolCalls []struct {
			ID       string `json:"id"`
			Type     string `json:"type"`
			Function struct {
				Name      string `json:"name"`
				Arguments string `json:"arguments"`
			} `json:"function"`
		} `json:"tool_calls"`
	}
	if err := json.Unmarshal(chat.Choices[0].Message, &msg); err != nil {
		return nil, err
	}
	text := stripThinkBlocks(responsesContentToText(msg.Content))
	if msg.Refusal != nil {
		text = strings.TrimSpace(text + *msg.Refusal)
	}
	if text != "" {
		output = append(output, map[string]any{
			"id":      "msg_" + idSuffix(id),
			"type":    "message",
			"role":    "assistant",
			"status":  "completed",
			"content": []map[string]any{{"type": "output_text", "text": text, "annotations": []any{}}},
		})
	}
	for _, tc := range msg.ToolCalls {
		if tc.Type != "" && tc.Type != "function" {
			continue
		}
		callID := tc.ID
		if callID == "" {
			callID = "call_" + idSuffix(id)
		}
		output = append(output, map[string]any{
			"id":        "fc_" + idSuffix(callID),
			"type":      "function_call",
			"call_id":   callID,
			"name":      tc.Function.Name,
			"arguments": tc.Function.Arguments,
			"status":    "completed",
		})
	}
	if msg.FunctionCall != nil {
		callID := "call_" + idSuffix(id)
		output = append(output, map[string]any{
			"id":        "fc_" + idSuffix(callID),
			"type":      "function_call",
			"call_id":   callID,
			"name":      msg.FunctionCall.Name,
			"arguments": msg.FunctionCall.Arguments,
			"status":    "completed",
		})
	}
	status := "completed"
	incompleteDetails := any(nil)
	_, status, incompleteDetails = responsesTerminalFromFinishReason(chat.Choices[0].FinishReason)
	resp := a.responseObjectWith(id, created, status, output, responsesUsageMap(
		chat.Usage.PromptTokens,
		chat.Usage.CachedPromptTokens,
		chat.Usage.CompletionTokens,
		chat.Usage.TotalTokens,
	))
	resp["incomplete_details"] = incompleteDetails
	return json.Marshal(resp)
}

func (a *responsesAdapter) handleChatStreamLine(line string) {
	trimmed := strings.TrimRight(line, "\r\n")
	if strings.TrimSpace(trimmed) == "" {
		return
	}
	data, ok := sseDataValue(trimmed)
	if !ok {
		return
	}
	if data == "[DONE]" {
		a.emitStreamDone()
		return
	}
	var errorFrame struct {
		Error *responsesStreamError `json:"error"`
	}
	if err := json.Unmarshal([]byte(data), &errorFrame); err == nil && errorFrame.Error != nil {
		a.emitStreamFailed(errorFrame.Error)
		return
	}
	var chunk struct {
		ID      string `json:"id"`
		Created int64  `json:"created"`
		Model   string `json:"model"`
		Usage   *struct {
			PromptTokens       int64 `json:"prompt_tokens"`
			CachedPromptTokens int64 `json:"cached_prompt_tokens"`
			CompletionTokens   int64 `json:"completion_tokens"`
			TotalTokens        int64 `json:"total_tokens"`
		} `json:"usage"`
		Choices []struct {
			Delta struct {
				Content          *string `json:"content"`
				ReasoningContent *string `json:"reasoning_content"`
				Refusal          *string `json:"refusal"`
				FunctionCall     *struct {
					Name      string `json:"name"`
					Arguments string `json:"arguments"`
				} `json:"function_call"`
				ToolCalls []struct {
					Index    int    `json:"index"`
					ID       string `json:"id"`
					Type     string `json:"type"`
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"delta"`
			FinishReason *string `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(data), &chunk); err != nil {
		a.emitStreamFailed(&responsesStreamError{Message: "Upstream stream returned malformed data", Type: "api_error", Code: "stream_malformed"})
		return
	}
	if chunk.ID != "" && a.responseID == "" {
		a.responseID = responsesIDFromChatID(chunk.ID, a.requestID)
	}
	if chunk.Model != "" {
		a.model = chunk.Model
	}
	if chunk.Usage != nil {
		a.streamUsage = responsesUsageMap(chunk.Usage.PromptTokens, chunk.Usage.CachedPromptTokens, chunk.Usage.CompletionTokens, chunk.Usage.TotalTokens)
	}
	if len(chunk.Choices) == 0 {
		return
	}
	delta := chunk.Choices[0].Delta
	if delta.Content != nil {
		a.emitTextDelta(a.filterThinkContent(*delta.Content))
	}
	if delta.Refusal != nil {
		a.emitTextDelta(*delta.Refusal)
	}
	for _, tc := range delta.ToolCalls {
		a.emitToolCallDelta(tc.Index, tc.ID, tc.Function.Name, tc.Function.Arguments)
	}
	if delta.FunctionCall != nil {
		a.emitToolCallDelta(0, "", delta.FunctionCall.Name, delta.FunctionCall.Arguments)
	}
	if chunk.Choices[0].FinishReason != nil {
		a.finishReason = *chunk.Choices[0].FinishReason
	}
	a.flush()
}

func (a *responsesAdapter) emitTextDelta(delta string) {
	if delta == "" {
		return
	}
	if a.messageID == "" {
		a.messageID = "msg_" + idSuffix(a.effectiveResponseID())
	}
	if !a.textOpen {
		a.messageOut = a.nextOutputIndex()
		a.emitResponsesSSE("response.output_item.added", map[string]any{
			"type": "response.output_item.added", "output_index": a.messageOut,
			"item":            map[string]any{"id": a.messageID, "type": "message", "role": "assistant", "status": "in_progress", "content": []any{}},
			"sequence_number": a.nextSeq(),
		})
		a.emitResponsesSSE("response.content_part.added", map[string]any{
			"type": "response.content_part.added", "item_id": a.messageID, "output_index": a.messageOut, "content_index": 0,
			"part":            map[string]any{"type": "output_text", "text": "", "annotations": []any{}},
			"sequence_number": a.nextSeq(),
		})
		a.textOpen = true
	}
	a.text.WriteString(delta)
	a.emitResponsesSSE("response.output_text.delta", map[string]any{
		"type": "response.output_text.delta", "item_id": a.messageID, "output_index": a.messageOut, "content_index": 0,
		"delta": delta, "sequence_number": a.nextSeq(),
	})
}

func (a *responsesAdapter) emitToolCallDelta(index int, id, name, arguments string) {
	tc := a.toolCalls[index]
	if tc == nil {
		callID := id
		if callID == "" {
			callID = fmt.Sprintf("call_%s_%d", idSuffix(a.effectiveResponseID()), index)
		}
		tc = &responsesStreamToolCall{ID: "fc_" + idSuffix(callID), CallID: callID, Name: name}
		a.toolCalls[index] = tc
	}
	if name != "" {
		tc.Name = name
	}
	if !tc.Opened {
		tc.Output = a.nextOutputIndex()
		a.emitResponsesSSE("response.output_item.added", map[string]any{
			"type": "response.output_item.added", "output_index": tc.Output,
			"item":            map[string]any{"id": tc.ID, "type": "function_call", "call_id": tc.CallID, "name": tc.Name, "arguments": "", "status": "in_progress"},
			"sequence_number": a.nextSeq(),
		})
		tc.Opened = true
	}
	if arguments != "" {
		tc.Arguments.WriteString(arguments)
		a.emitResponsesSSE("response.function_call_arguments.delta", map[string]any{
			"type": "response.function_call_arguments.delta", "item_id": tc.ID, "output_index": tc.Output,
			"delta": arguments, "sequence_number": a.nextSeq(),
		})
	}
}

func (a *responsesAdapter) emitStreamDone() {
	if a.streamTerminal {
		return
	}
	if remainder := a.flushThinkRemainder(); remainder != "" {
		a.emitTextDelta(remainder)
	}
	output := []map[string]any{}
	if a.textOpen {
		text := a.text.String()
		a.emitResponsesSSE("response.output_text.done", map[string]any{
			"type": "response.output_text.done", "item_id": a.messageID, "output_index": a.messageOut, "content_index": 0,
			"text": text, "sequence_number": a.nextSeq(),
		})
		part := map[string]any{"type": "output_text", "text": text, "annotations": []any{}}
		a.emitResponsesSSE("response.content_part.done", map[string]any{
			"type": "response.content_part.done", "item_id": a.messageID, "output_index": a.messageOut, "content_index": 0,
			"part": part, "sequence_number": a.nextSeq(),
		})
		item := map[string]any{"id": a.messageID, "type": "message", "role": "assistant", "status": "completed", "content": []map[string]any{part}}
		a.emitResponsesSSE("response.output_item.done", map[string]any{
			"type": "response.output_item.done", "output_index": a.messageOut, "item": item, "sequence_number": a.nextSeq(),
		})
		output = append(output, item)
	}
	toolCalls := make([]*responsesStreamToolCall, 0, len(a.toolCalls))
	for _, tc := range a.toolCalls {
		toolCalls = append(toolCalls, tc)
	}
	sort.Slice(toolCalls, func(i, j int) bool {
		return toolCalls[i].Output < toolCalls[j].Output
	})
	for _, tc := range toolCalls {
		args := tc.Arguments.String()
		a.emitResponsesSSE("response.function_call_arguments.done", map[string]any{
			"type": "response.function_call_arguments.done", "item_id": tc.ID, "output_index": tc.Output,
			"name": tc.Name, "arguments": args, "sequence_number": a.nextSeq(),
		})
		item := map[string]any{"id": tc.ID, "type": "function_call", "call_id": tc.CallID, "name": tc.Name, "arguments": args, "status": "completed"}
		a.emitResponsesSSE("response.output_item.done", map[string]any{
			"type": "response.output_item.done", "output_index": tc.Output, "item": item, "sequence_number": a.nextSeq(),
		})
		output = append(output, item)
	}
	event, status, incompleteDetails := responsesTerminalFromFinishReason(a.finishReason)
	response := a.responseObjectWith(a.effectiveResponseID(), a.now().Unix(), status, output, a.streamUsage)
	response["incomplete_details"] = incompleteDetails
	a.emitResponsesSSE(event, map[string]any{
		"type": event, "response": response, "sequence_number": a.nextSeq(),
	})
	a.writeBytes([]byte("data: [DONE]\n\n"))
	a.flush()
	a.streamTerminal = true
}

type responsesStreamError struct {
	Message   string `json:"message"`
	Type      string `json:"type"`
	Code      string `json:"code"`
	Param     any    `json:"param"`
	Retryable any    `json:"retryable"`
}

func (a *responsesAdapter) emitStreamFailed(errFrame *responsesStreamError) {
	if a.streamTerminal {
		return
	}
	code := errFrame.Code
	if code == "" {
		code = "provider_error"
	}
	message := errFrame.Message
	if message == "" {
		message = "Upstream provider failed"
	}
	errType := errFrame.Type
	if errType == "" {
		errType = "api_error"
	}
	errorObject := map[string]any{"code": code, "message": message, "type": errType}
	if errFrame.Param != nil {
		errorObject["param"] = errFrame.Param
	}
	if errFrame.Retryable != nil {
		errorObject["retryable"] = errFrame.Retryable
	}
	response := a.responseObjectWith(a.effectiveResponseID(), a.now().Unix(), "failed", nil, a.streamUsage)
	response["error"] = errorObject
	a.emitResponsesSSE("response.failed", map[string]any{
		"type": "response.failed", "response": response, "sequence_number": a.nextSeq(),
	})
	a.writeBytes([]byte("data: [DONE]\n\n"))
	a.flush()
	a.streamTerminal = true
}

func (a *responsesAdapter) emitResponsesSSE(event string, payload map[string]any) {
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

func (a *responsesAdapter) flush() {
	if f, ok := a.dst.(http.Flusher); ok {
		f.Flush()
	}
}

func (a *responsesAdapter) writeBytes(p []byte) {
	if a.writeErr != nil {
		return
	}
	n, err := a.dst.Write(p)
	a.captureDedupeBytes(p[:n], err)
	if err != nil {
		a.writeErr = err
		return
	}
	if n != len(p) {
		a.writeErr = io.ErrShortWrite
	}
}

func (a *responsesAdapter) writeFinalBytes(p []byte) (int, error) {
	n, err := a.dst.Write(p)
	a.captureDedupeBytes(p[:n], err)
	if err == nil && n != len(p) {
		err = io.ErrShortWrite
	}
	if err != nil {
		a.writeErr = err
	}
	return n, err
}

func (a *responsesAdapter) armDedupeCapture(limit int) {
	a.captureArmed = true
	a.captureCap = limit
}

func (a *responsesAdapter) captureDedupeBytes(p []byte, err error) {
	if !a.captureArmed || a.overflowed {
		return
	}
	if err != nil {
		a.capture = nil
		return
	}
	if len(a.capture)+len(p) > a.captureCap {
		a.overflowed = true
		a.capture = nil
		return
	}
	a.capture = append(a.capture, p...)
}

func (a *responsesAdapter) dedupeCapture() []byte {
	if !a.captureArmed || a.overflowed || a.writeErr != nil {
		return nil
	}
	return a.capture
}

func (a *responsesAdapter) dedupeDeliveredButUncacheable() bool {
	return a.captureArmed && a.overflowed && a.writeErr == nil
}

func (a *responsesAdapter) nextSeq() int64 {
	a.seq++
	return a.seq
}

func (a *responsesAdapter) nextOutputIndex() int {
	out := a.nextOut
	a.nextOut++
	return out
}

func (a *responsesAdapter) effectiveResponseID() string {
	if a.responseID == "" {
		a.responseID = "resp_" + idSuffix(a.requestID)
	}
	return a.responseID
}

func (a *responsesAdapter) responseObject(status string, output []map[string]any) map[string]any {
	return a.responseObjectWith(a.effectiveResponseID(), a.now().Unix(), status, output, nil)
}

func (a *responsesAdapter) responseObjectWith(id string, created int64, status string, output []map[string]any, usage map[string]any) map[string]any {
	if output == nil {
		output = []map[string]any{}
	}
	return map[string]any{
		"id":                   id,
		"object":               "response",
		"created_at":           created,
		"status":               status,
		"error":                nil,
		"incomplete_details":   nil,
		"instructions":         a.instructions,
		"max_output_tokens":    a.maxOutputTokens,
		"model":                a.model,
		"output":               output,
		"parallel_tool_calls":  a.parallelToolCalls,
		"previous_response_id": nil,
		"reasoning":            map[string]any{"effort": nil, "summary": nil},
		"store":                false,
		"temperature":          nil,
		"text":                 map[string]any{"format": firstNonNil(a.textFormat, map[string]any{"type": "text"})},
		"tool_choice":          firstNonNil(a.toolChoice, "auto"),
		"tools":                a.tools,
		"top_p":                nil,
		"truncation":           "disabled",
		"usage":                usage,
		"user":                 nil,
		"metadata":             map[string]any{},
	}
}

func responsesTerminalFromFinishReason(reason string) (event, status string, incompleteDetails any) {
	switch reason {
	case "length":
		return "response.incomplete", "incomplete", map[string]any{"reason": "max_output_tokens"}
	case "content_filter":
		return "response.incomplete", "incomplete", map[string]any{"reason": "content_filter"}
	}
	return "response.completed", "completed", nil
}

func responsesUsageMap(prompt, cached, completion, total int64) map[string]any {
	return map[string]any{
		"input_tokens":         prompt,
		"output_tokens":        completion,
		"total_tokens":         total,
		"input_tokens_details": map[string]any{"cached_tokens": cached, "cache_write_tokens": 0},
		"output_tokens_details": map[string]any{
			"reasoning_tokens": 0,
		},
	}
}

func firstNonNil(v any, fallback any) any {
	if v != nil {
		return v
	}
	return fallback
}

func responsesIDFromChatID(chatID, requestID string) string {
	source := chatID
	if source == "" {
		source = requestID
	}
	return "resp_" + idSuffix(source)
}

var nonIDChar = regexp.MustCompile(`[^A-Za-z0-9_-]+`)

func idSuffix(id string) string {
	id = strings.Trim(nonIDChar.ReplaceAllString(id, "_"), "_")
	if id == "" {
		return "generated"
	}
	if len(id) > 48 {
		return id[len(id)-48:]
	}
	return id
}

var thinkBlockRE = regexp.MustCompile(`(?s)<think>.*?</think>`)

func stripThinkBlocks(s string) string {
	s = thinkBlockRE.ReplaceAllString(s, "")
	if start := strings.LastIndex(s, "<think>"); start >= 0 {
		s = s[:start]
	}
	return strings.TrimSpace(s)
}

func (a *responsesAdapter) filterThinkContent(s string) string {
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

func (a *responsesAdapter) flushThinkRemainder() string {
	if a.thinkInBlock {
		a.thinkPending = ""
		return ""
	}
	remainder := a.thinkPending
	a.thinkPending = ""
	return remainder
}

func longestSuffixThatPrefixes(s, prefix string) string {
	max := len(prefix) - 1
	if len(s) < max {
		max = len(s)
	}
	for n := max; n > 0; n-- {
		suffix := s[len(s)-n:]
		if strings.HasPrefix(prefix, suffix) {
			return suffix
		}
	}
	return ""
}
