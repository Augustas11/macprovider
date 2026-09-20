package buyer

import (
	"bytes"
	"encoding/json"
	"errors"
	"sort"
	"strings"
)

// concatSafeToolStream rewrites streaming tool-call SSE so a concatenating
// buyer (Pi) sees one complete JSON object for function.arguments.
//
// Fleet 1.8.123 emits "{}" on tool-call open, then a later non-prefix object.
// Concatenating those is malformed (`{}{"command":...}`), and JSON.parse("{}")
// is treated as a finished empty bash call. Concat-safe CLI already holds XML
// arguments until </function>. This sanitizer:
//   - role / name-open flush immediately (opening arguments "{}" become "")
//   - "{}" stays held until finish_reason so Pi never dispatches empty bash
//   - concat-safe prefixes and a complete non-empty object flush as they arrive
//   - [DONE] / EOF / WS complete do not flush held "{}" by themselves
type concatSafeToolStream struct {
	calls     map[int]*concatSafeCall
	lastMeta  concatSafeMeta
	totalHeld int
	finished  bool
}

type concatSafeCall struct {
	index   int
	id      string
	typ     string
	name    string
	held    string
	emitted string
	opened  bool
	flushed bool
}

type concatSafeMeta struct {
	id      string
	object  string
	model   string
	created any
}

func newConcatSafeToolStream() *concatSafeToolStream {
	return &concatSafeToolStream{calls: map[int]*concatSafeCall{}}
}

func (s *concatSafeToolStream) observeBlock(block []byte) ([]byte, error) {
	if len(block) == 0 {
		return nil, nil
	}
	var out bytes.Buffer
	for _, line := range bytes.SplitAfter(block, []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		forwarded, err := s.observeLine(line)
		if err != nil {
			return nil, err
		}
		out.Write(forwarded)
	}
	return out.Bytes(), nil
}

func (s *concatSafeToolStream) observeLine(line []byte) ([]byte, error) {
	trimmed := bytes.TrimRight(line, "\r\n")
	newline := line[len(trimmed):]
	trimmed = bytes.TrimPrefix(trimmed, []byte{0xEF, 0xBB, 0xBF})
	if !bytes.HasPrefix(trimmed, []byte("data:")) {
		return line, nil
	}
	payload := bytes.TrimSpace(trimmed[len("data:"):])
	if len(payload) == 0 {
		return line, nil
	}
	if bytes.Equal(payload, []byte("[DONE]")) {
		flushed, err := s.flushHeld(newline)
		if err != nil {
			return nil, err
		}
		return append(flushed, line...), nil
	}
	var event map[string]any
	if err := json.Unmarshal(payload, &event); err != nil {
		return line, nil
	}
	s.noteMeta(event)
	choices, _ := event["choices"].([]any)
	if len(choices) == 0 {
		return line, nil
	}

	var (
		out          bytes.Buffer
		rewritten    bool
		holdEvent    bool
		sawFinish    bool
		finishReason any
		choiceIndex  int
		forwardCalls []any
		passthrough  = true
	)
	for _, rawChoice := range choices {
		choice, ok := rawChoice.(map[string]any)
		if !ok {
			continue
		}
		if v, ok := choice["index"].(float64); ok {
			choiceIndex = int(v)
		}
		if reason, has := choice["finish_reason"]; has && reason != nil {
			if text, ok := reason.(string); ok && text != "" {
				sawFinish = true
				finishReason = reason
			}
		}
		delta, _ := choice["delta"].(map[string]any)
		if delta == nil {
			continue
		}
		rawCalls, hasCalls := delta["tool_calls"]
		if !hasCalls {
			continue
		}
		passthrough = false
		rewritten = true
		calls, _ := rawCalls.([]any)
		for _, rawCall := range calls {
			call, ok := rawCall.(map[string]any)
			if !ok {
				return nil, errors.New("malformed tool_calls delta")
			}
			forward, hold, err := s.observeCall(call)
			if err != nil {
				return nil, err
			}
			if hold {
				holdEvent = true
			}
			if forward != nil {
				forwardCalls = append(forwardCalls, forward)
			}
		}
	}

	if passthrough && (!sawFinish || len(s.calls) == 0) {
		return line, nil
	}

	if len(forwardCalls) > 0 {
		openEvent := cloneStringAnyMap(event)
		delta := map[string]any{}
		if choice, ok := choices[0].(map[string]any); ok {
			if originalDelta, ok := choice["delta"].(map[string]any); ok {
				for k, v := range originalDelta {
					if k != "tool_calls" {
						delta[k] = v
					}
				}
			}
		}
		delta["tool_calls"] = forwardCalls
		openChoices := []any{map[string]any{
			"index":         choiceIndex,
			"delta":         delta,
			"finish_reason": nil,
		}}
		openEvent["choices"] = openChoices
		encoded, err := json.Marshal(openEvent)
		if err != nil {
			return nil, err
		}
		out.Write(encodeSSEDataLine(encoded, newline))
		rewritten = true
		holdEvent = false
	}

	if sawFinish {
		s.finished = true
		flushed, err := s.flushHeld(newline)
		if err != nil {
			return nil, err
		}
		out.Write(flushed)
		finishEvent := cloneStringAnyMap(event)
		delta := map[string]any{}
		if choice, ok := choices[0].(map[string]any); ok {
			if originalDelta, ok := choice["delta"].(map[string]any); ok {
				for k, v := range originalDelta {
					if k != "tool_calls" {
						delta[k] = v
					}
				}
			}
		}
		finishEvent["choices"] = []any{map[string]any{
			"index":         choiceIndex,
			"delta":         delta,
			"finish_reason": finishReason,
		}}
		encoded, err := json.Marshal(finishEvent)
		if err != nil {
			return nil, err
		}
		out.Write(encodeSSEDataLine(encoded, newline))
		rewritten = true
	}

	if rewritten {
		return out.Bytes(), nil
	}
	if holdEvent {
		return nil, nil
	}
	return line, nil
}

func (s *concatSafeToolStream) observeCall(call map[string]any) (forward map[string]any, hold bool, err error) {
	index := 0
	if raw, ok := call["index"].(float64); ok {
		index = int(raw)
	}
	if index < 0 {
		return nil, false, errors.New("malformed tool_calls delta")
	}
	state := s.calls[index]
	if state == nil {
		if len(s.calls) >= maxAssistantToolCalls {
			return nil, false, errors.New("too_many_tool_calls")
		}
		state = &concatSafeCall{index: index}
		s.calls[index] = state
	}
	if id, ok := call["id"].(string); ok && id != "" {
		state.id = id
	}
	if typ, ok := call["type"].(string); ok && typ != "" {
		state.typ = typ
	}
	fn, _ := call["function"].(map[string]any)
	if fn != nil {
		if name, ok := fn["name"].(string); ok && name != "" {
			state.name = name
		}
	}
	args, hasArgs := toolCallArguments(fn)
	if !state.opened {
		if state.id == "" || state.name == "" {
			return nil, false, errors.New("malformed tool-call opening delta")
		}
		if state.typ == "" {
			state.typ = "function"
		}
		state.opened = true
		if hasArgs && args != "" {
			if err := s.holdArguments(state, args); err != nil {
				return nil, false, err
			}
		}
		open := map[string]any{
			"index": state.index,
			"id":    state.id,
			"type":  state.typ,
			"function": map[string]any{
				"name":      state.name,
				"arguments": "",
			},
		}
		return open, false, nil
	}
	if !hasArgs {
		return nil, false, nil
	}
	if err := s.holdArguments(state, args); err != nil {
		return nil, false, err
	}
	delta := state.flushableArgumentDelta()
	if delta == "" {
		return nil, true, nil
	}
	return map[string]any{
		"index": state.index,
		"function": map[string]any{
			"arguments": delta,
		},
	}, false, nil
}

func (s *concatSafeToolStream) holdArguments(state *concatSafeCall, fragment string) error {
	if fragment == "" {
		return nil
	}
	next := coalesceToolArguments(state.held, fragment)
	if len(next) > maxToolCallArgumentsBytes {
		return errors.New("byte_cap_exceeded")
	}
	nextTotal := s.totalHeld - len(state.held) + len(next)
	if nextTotal > maxToolCallArgumentsResponseBytes {
		return errors.New("response_byte_cap_exceeded")
	}
	s.totalHeld = nextTotal
	state.held = next
	return nil
}

func (c *concatSafeCall) flushableArgumentDelta() string {
	if c.held == "" || c.held == "{}" {
		return ""
	}
	if !concatSafeArgumentSnapshot(c.held) {
		return ""
	}
	var delta string
	switch {
	case c.emitted == "":
		delta = c.held
	case strings.HasPrefix(c.held, c.emitted):
		delta = c.held[len(c.emitted):]
	default:
		return ""
	}
	if delta == "" {
		return ""
	}
	c.emitted += delta
	return delta
}

func concatSafeArgumentSnapshot(s string) bool {
	if validToolCallArgumentsObject(s) {
		return s != "{}"
	}
	return isTruncatedJSONObject(s)
}

func isTruncatedJSONObject(s string) bool {
	trimmed := strings.TrimSpace(s)
	if !strings.HasPrefix(trimmed, "{") {
		return false
	}
	err := json.Unmarshal([]byte(s), new(json.RawMessage))
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "unexpected end of JSON input")
}

func (s *concatSafeToolStream) heldBytes() int {
	return s.totalHeld
}

func (s *concatSafeToolStream) flush() ([]byte, error) {
	return s.flushHeld([]byte("\n"))
}

func (s *concatSafeToolStream) flushHeld(newline []byte) ([]byte, error) {
	if !s.finished {
		return nil, nil
	}
	indexes := make([]int, 0, len(s.calls))
	for index, call := range s.calls {
		if call.flushed || call.held == "" {
			continue
		}
		indexes = append(indexes, index)
	}
	if len(indexes) == 0 {
		return nil, nil
	}
	sort.Ints(indexes)
	toolCalls := make([]any, 0, len(indexes))
	for _, index := range indexes {
		call := s.calls[index]
		remainder := call.held
		if call.emitted != "" {
			if call.emitted == call.held {
				call.flushed = true
				continue
			}
			if strings.HasPrefix(call.held, call.emitted) {
				remainder = call.held[len(call.emitted):]
			}
		}
		if remainder == "" {
			call.flushed = true
			continue
		}
		toolCalls = append(toolCalls, map[string]any{
			"index": call.index,
			"function": map[string]any{
				"arguments": remainder,
			},
		})
		call.emitted = call.held
		call.flushed = true
	}
	if len(toolCalls) == 0 {
		return nil, nil
	}
	event := map[string]any{
		"choices": []any{map[string]any{
			"index": 0,
			"delta": map[string]any{
				"tool_calls": toolCalls,
			},
			"finish_reason": nil,
		}},
	}
	if s.lastMeta.object != "" {
		event["object"] = s.lastMeta.object
	}
	if s.lastMeta.id != "" {
		event["id"] = s.lastMeta.id
	}
	if s.lastMeta.model != "" {
		event["model"] = s.lastMeta.model
	}
	if s.lastMeta.created != nil {
		event["created"] = s.lastMeta.created
	}
	encoded, err := json.Marshal(event)
	if err != nil {
		return nil, err
	}
	out := encodeSSEDataLine(encoded, newline)
	if !bytes.HasSuffix(out, []byte("\n\n")) && !bytes.HasSuffix(out, []byte("\r\n\r\n")) {
		out = append(out, '\n')
	}
	return out, nil
}

func (s *concatSafeToolStream) noteMeta(event map[string]any) {
	if id, ok := event["id"].(string); ok && id != "" {
		s.lastMeta.id = id
	}
	if object, ok := event["object"].(string); ok && object != "" {
		s.lastMeta.object = object
	}
	if model, ok := event["model"].(string); ok && model != "" {
		s.lastMeta.model = model
	}
	if created, ok := event["created"]; ok && created != nil {
		s.lastMeta.created = created
	}
}

func toolCallArguments(fn map[string]any) (string, bool) {
	if fn == nil {
		return "", false
	}
	raw, ok := fn["arguments"]
	if !ok || raw == nil {
		return "", false
	}
	switch v := raw.(type) {
	case string:
		return v, true
	default:
		encoded, err := json.Marshal(v)
		if err != nil {
			return "", false
		}
		return string(encoded), true
	}
}

func coalesceToolArguments(held, fragment string) string {
	if fragment == "" {
		return held
	}
	if held == "" {
		return fragment
	}
	concat := held + fragment
	if validToolCallArgumentsObject(concat) {
		return concat
	}
	// Fleet 1.8.123 emits a complete "{}" then a later non-prefix object.
	// Only that empty object may be replaced; other held garbage stays
	// concatenated so final-close can fail closed.
	if held == "{}" && validToolCallArgumentsObject(fragment) {
		return fragment
	}
	if strings.HasPrefix(fragment, held) {
		return fragment
	}
	return concat
}

func encodeSSEDataLine(payload, newline []byte) []byte {
	if len(newline) == 0 {
		newline = []byte("\n")
	}
	out := make([]byte, 0, 6+len(payload)+len(newline))
	out = append(out, []byte("data: ")...)
	out = append(out, payload...)
	out = append(out, newline...)
	return out
}

func cloneStringAnyMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
