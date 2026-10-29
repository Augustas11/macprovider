package router

import (
	"bytes"
	"encoding/json"
	"errors"
)

// streamOrdering holds only the terminal choice, leaving generated deltas
// incremental. Some providers materialize tools after their stop snapshot.
// Delay that snapshot until DONE/EOF so clients never stop before the tools.
type streamOrdering struct {
	finish                  map[string]any
	tools                   bool
	done                    bool
	preserveIncompleteTools bool
}

func (s *streamOrdering) observe(line []byte) ([][]byte, error) {
	data, ok := sseDataValue(string(bytes.TrimSpace(line)))
	if !ok {
		return [][]byte{line}, nil
	}
	if s.done {
		return nil, errors.New("provider data after stream terminal")
	}
	if data == "[DONE]" {
		out, err := s.flush()
		if err != nil {
			return nil, err
		}
		s.done = true
		return append(out, line), nil
	}
	if anthropicRawHasDuplicateKeys([]byte(data)) {
		return nil, errors.New("duplicate streaming JSON keys")
	}
	var event map[string]any
	if json.Unmarshal([]byte(data), &event) != nil {
		return [][]byte{line}, nil
	}
	if event["error"] != nil {
		s.finish = nil
		return [][]byte{line}, nil
	}
	choices, _ := event["choices"].([]any)
	if len(choices) == 0 {
		return [][]byte{line}, nil
	}
	if len(choices) != 1 {
		return nil, errors.New("multiple streaming choices are unsupported")
	}
	choice, ok := choices[0].(map[string]any)
	if !ok {
		return nil, errors.New("invalid streaming choice")
	}
	delta, _ := choice["delta"].(map[string]any)
	if calls, ok := delta["tool_calls"].([]any); ok && len(calls) > 0 {
		s.tools = true
	}
	if delta["function_call"] != nil {
		s.tools = true
	}
	reason, validReason := choice["finish_reason"].(string)
	if raw := choice["finish_reason"]; raw != nil && (!validReason || reason == "") {
		return nil, errors.New("invalid streaming finish reason")
	}
	if reason == "" {
		return [][]byte{line}, nil
	}
	if s.finish != nil {
		return nil, errors.New("duplicate streaming finish")
	}
	terminal := make(map[string]any, len(event))
	for k, v := range event {
		terminal[k] = v
	}
	index := choice["index"]
	if index == nil {
		index = 0
	}
	terminal["choices"] = []any{map[string]any{"index": index, "delta": map[string]any{}, "finish_reason": reason}}
	// Usage belongs to the original frame and must not be counted twice.
	delete(terminal, "usage")
	s.finish = terminal
	choice["finish_reason"] = nil
	encoded, err := json.Marshal(event)
	if err != nil {
		return nil, err
	}
	return [][]byte{append(append([]byte("data: "), encoded...), '\n')}, nil
}

func (s *streamOrdering) flush() ([][]byte, error) {
	if s.finish == nil {
		return nil, nil
	}
	choice := s.finish["choices"].([]any)[0].(map[string]any)
	reason, _ := choice["finish_reason"].(string)
	switch reason {
	case "stop", "tool_calls", "function_call":
		if s.tools {
			choice["finish_reason"] = "tool_calls"
		}
	case "length", "content_filter":
		// Messages retains its max_tokens/content-filter terminal mapping.
		if s.tools && !s.preserveIncompleteTools {
			return nil, errors.New("incomplete streaming tool call")
		}
	default:
		return nil, errors.New("unsupported streaming finish reason")
	}
	encoded, err := json.Marshal(s.finish)
	if err != nil {
		return nil, err
	}
	s.finish = nil
	return [][]byte{append(append([]byte("data: "), encoded...), '\n', '\n')}, nil
}
