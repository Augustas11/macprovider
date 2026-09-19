package buyer

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"
	"unicode"
)

// maybeRecoverQwenXMLToolCalls rewrites a provider chat.completion JSON body
// that leaked native Qwen function-XML into message.content instead of
// tool_calls. Current CLI 1.8.123 throws on a missing </tool_call> even when
// the inner <function=…></function> is complete, so Pi prints XML and never
// runs the tool. Recovery is fail-closed: undeclared names stay content.
func maybeRecoverQwenXMLToolCalls(raw []byte, state *forwardState) []byte {
	if state == nil || len(state.declaredFunctionNames) == 0 {
		return raw
	}
	recovered, ok := recoverQwenFunctionXMLCompletion(raw, state.declaredFunctionNames)
	if !ok {
		return raw
	}
	return recovered
}

// buyerSSEFromProviderJSONCompletion converts a non-stream chat.completion JSON
// chunk into concat-safe buyer SSE. Fleet 1.8.123 still returns this shape when
// the CLI parser leaks function-XML into message.content; live Pi now keeps
// provider stream=true, so the WS path must recover those JSON completions.
func buyerSSEFromProviderJSONCompletion(raw []byte, state *forwardState) ([]byte, bool) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] != '{' || bytes.HasPrefix(trimmed, []byte("data:")) {
		return nil, false
	}
	recovered := maybeRecoverQwenXMLToolCalls(trimmed, state)
	sse, err := chatCompletionJSONToSSE(recovered)
	if err != nil {
		return nil, false
	}
	return sse, true
}

func recoverQwenFunctionXMLCompletion(raw []byte, allowed map[string]struct{}) ([]byte, bool) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.HasPrefix(trimmed, []byte("data:")) {
		return nil, false
	}
	var root map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &root); err != nil {
		return nil, false
	}
	if !qwenModelID(root["model"]) {
		return nil, false
	}
	choicesRaw, ok := root["choices"]
	if !ok {
		return nil, false
	}
	var choices []map[string]json.RawMessage
	if err := json.Unmarshal(choicesRaw, &choices); err != nil || len(choices) == 0 {
		return nil, false
	}
	choice := choices[0]
	if hasNonEmptyToolCalls(choice["tool_calls"]) {
		return nil, false
	}
	content, ok := jsonStringContent(choice["message"])
	if !ok || !strings.Contains(content, "<function=") || !strings.Contains(content, "</function>") {
		return nil, false
	}
	calls := parseBareQwenFunctionXML(content, allowed)
	if len(calls) == 0 {
		return nil, false
	}
	message, err := rewriteAssistantMessage(choice["message"], content, calls)
	if err != nil {
		return nil, false
	}
	choice["message"] = message
	choice["finish_reason"] = json.RawMessage(`"tool_calls"`)
	choices[0] = choice
	encodedChoices, err := json.Marshal(choices)
	if err != nil {
		return nil, false
	}
	root["choices"] = encodedChoices
	out, err := json.Marshal(root)
	if err != nil {
		return nil, false
	}
	return out, true
}

func qwenModelID(raw json.RawMessage) bool {
	var model string
	if err := json.Unmarshal(bytes.TrimSpace(raw), &model); err != nil {
		return false
	}
	lower := strings.ToLower(model)
	return strings.Contains(lower, "qwen2.5") || strings.Contains(lower, "qwen3")
}

func hasNonEmptyToolCalls(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return false
	}
	var calls []json.RawMessage
	if err := json.Unmarshal(trimmed, &calls); err != nil {
		return true
	}
	return len(calls) > 0
}

func jsonStringContent(message json.RawMessage) (string, bool) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(message, &obj); err != nil {
		return "", false
	}
	raw, ok := obj["content"]
	if !ok {
		return "", false
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return "", false
	}
	var content string
	if err := json.Unmarshal(trimmed, &content); err != nil {
		return "", false
	}
	return content, content != ""
}

func rewriteAssistantMessage(message json.RawMessage, originalContent string, calls []recoveredToolCall) (json.RawMessage, error) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(message, &obj); err != nil {
		return nil, err
	}
	encodedCalls, err := json.Marshal(calls)
	if err != nil {
		return nil, err
	}
	obj["tool_calls"] = encodedCalls
	cleaned := stripToolCallWrappers(bareFunctionXMLPreamble(originalContent))
	if cleaned == "" {
		obj["content"] = json.RawMessage("null")
	} else {
		encoded, err := json.Marshal(cleaned)
		if err != nil {
			return nil, err
		}
		obj["content"] = encoded
	}
	if _, ok := obj["role"]; !ok {
		obj["role"] = json.RawMessage(`"assistant"`)
	}
	return json.Marshal(obj)
}

type recoveredToolCall struct {
	ID       string                    `json:"id"`
	Type     string                    `json:"type"`
	Function recoveredToolCallFunction `json:"function"`
}

type recoveredToolCallFunction struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

func parseBareQwenFunctionXML(raw string, allowed map[string]struct{}) []recoveredToolCall {
	var calls []recoveredToolCall
	search := raw
	for {
		open := strings.Index(search, "<function=")
		if open < 0 {
			break
		}
		rest := search[open:]
		closeIdx := strings.Index(rest, "</function>")
		if closeIdx < 0 {
			break
		}
		block := rest[:closeIdx+len("</function>")]
		call, ok := parseQwenFunctionXMLBlock(block, allowed)
		if !ok {
			return nil
		}
		calls = append(calls, call)
		search = rest[closeIdx+len("</function>"):]
	}
	return calls
}

func parseQwenFunctionXMLBlock(block string, allowed map[string]struct{}) (recoveredToolCall, bool) {
	name, ok := qwenFunctionName(block)
	if !ok {
		return recoveredToolCall{}, false
	}
	if _, declared := allowed[name]; !declared {
		return recoveredToolCall{}, false
	}
	params, ok := qwenFunctionParameters(block)
	if !ok {
		return recoveredToolCall{}, false
	}
	args, err := marshalSortedStringMap(params)
	if err != nil {
		return recoveredToolCall{}, false
	}
	id, err := newProviderToolCallID()
	if err != nil {
		return recoveredToolCall{}, false
	}
	return recoveredToolCall{
		ID:   id,
		Type: "function",
		Function: recoveredToolCallFunction{
			Name:      name,
			Arguments: string(args),
		},
	}, true
}

func qwenFunctionName(block string) (string, bool) {
	const prefix = "<function="
	start := strings.Index(block, prefix)
	if start < 0 {
		return "", false
	}
	nameStart := start + len(prefix)
	end := strings.Index(block[nameStart:], ">")
	if end < 0 {
		return "", false
	}
	name := strings.TrimSpace(block[nameStart : nameStart+end])
	if !validToolFunctionName(name) {
		return "", false
	}
	return name, true
}

func qwenFunctionParameters(block string) (map[string]string, bool) {
	params := map[string]string{}
	search := block
	for {
		open := strings.Index(search, "<parameter=")
		if open < 0 {
			break
		}
		rest := search[open+len("<parameter="):]
		nameEnd := strings.Index(rest, ">")
		if nameEnd < 0 {
			return nil, false
		}
		name := strings.TrimSpace(rest[:nameEnd])
		if !validToolParameterName(name) {
			return nil, false
		}
		if _, dup := params[name]; dup {
			return nil, false
		}
		valueStart := rest[nameEnd+1:]
		closeTag := strings.Index(valueStart, "</parameter>")
		if closeTag < 0 {
			return nil, false
		}
		params[name] = normalizeQwenParameterValue(valueStart[:closeTag])
		search = valueStart[closeTag+len("</parameter>"):]
	}
	return params, true
}

func normalizeQwenParameterValue(raw string) string {
	trimmed := raw
	if strings.HasPrefix(trimmed, "\n") {
		trimmed = trimmed[1:]
	}
	if strings.HasSuffix(trimmed, "\n") {
		trimmed = trimmed[:len(trimmed)-1]
	}
	return strings.TrimSpace(trimmed)
}

func validToolFunctionName(name string) bool {
	if len(name) < 1 || len(name) > 64 {
		return false
	}
	return toolNameCharset(name)
}

func validToolParameterName(name string) bool {
	if len(name) < 1 || len(name) > 128 {
		return false
	}
	return toolNameCharset(name)
}

func toolNameCharset(name string) bool {
	for _, r := range name {
		if r > unicode.MaxASCII {
			return false
		}
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || r == '-' {
			continue
		}
		return false
	}
	return true
}

func marshalSortedStringMap(m map[string]string) ([]byte, error) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b bytes.Buffer
	b.WriteByte('{')
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		if err := enc.Encode(k); err != nil {
			return nil, err
		}
		// Encode adds a trailing newline.
		b.Truncate(b.Len() - 1)
		b.WriteByte(':')
		if err := enc.Encode(m[k]); err != nil {
			return nil, err
		}
		b.Truncate(b.Len() - 1)
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

func newProviderToolCallID() (string, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return "call_" + hex.EncodeToString(buf[:]), nil
}

func bareFunctionXMLPreamble(raw string) string {
	idx := strings.Index(raw, "<function=")
	if idx < 0 {
		return raw
	}
	return raw[:idx]
}

func stripToolCallWrappers(text string) string {
	text = strings.ReplaceAll(text, "<tool_call>", "")
	text = strings.ReplaceAll(text, "</tool_call>", "")
	return strings.TrimSpace(text)
}

func declaredFunctionNames(raw json.RawMessage) map[string]struct{} {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil
	}
	toolsRaw, ok := obj["tools"]
	if !ok {
		return nil
	}
	var tools []struct {
		Function struct {
			Name string `json:"name"`
		} `json:"function"`
	}
	if err := json.Unmarshal(toolsRaw, &tools); err != nil {
		return nil
	}
	names := make(map[string]struct{}, len(tools))
	for _, tool := range tools {
		name := strings.TrimSpace(tool.Function.Name)
		if name == "" {
			continue
		}
		names[name] = struct{}{}
	}
	if len(names) == 0 {
		return nil
	}
	return names
}
