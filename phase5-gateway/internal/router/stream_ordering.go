package router

import (
	"bytes"
	"encoding/json"
	"errors"
)

// streamOrdering holds one terminal frame, leaving earlier generated deltas
// incremental. Some providers materialize tools after their stop snapshot.
// Delay that snapshot until DONE/EOF so clients never stop before the tools.
type streamOrdering struct {
	finish                  map[string]any
	tools                   bool
	done                    bool
	preserveIncompleteTools bool
	rawFinish               []byte
	split                   bool
	finishFrameOpen         bool
}

func (s *streamOrdering) observe(line []byte) ([][]byte, error) {
	data, ok := sseDataValue(string(bytes.TrimSpace(line)))
	if !ok {
		if s.finish != nil && !s.split && s.finishFrameOpen {
			if len(s.rawFinish)+len(line) > maxStreamingLineBytes+4 {
				return nil, errors.New("terminal frame buffer exceeded")
			}
			s.rawFinish = append(s.rawFinish, line...)
			if len(bytes.TrimSpace(line)) == 0 {
				s.finishFrameOpen = false
			}
			return nil, nil
		}
		return [][]byte{line}, nil
	}
	s.finishFrameOpen = false
	if s.done {
		return nil, errors.New("provider data after stream terminal")
	}
	if data == "[DONE]" {
		out, err := s.flush()
		if err != nil {
			return nil, err
		}
		s.done = true
		// The read loop stops at DONE, so emit its event separator too.
		newline := []byte("\n")
		if bytes.HasSuffix(line, []byte("\r\n")) {
			newline = []byte("\r\n")
		}
		doneLine := append(append([]byte(nil), line...), newline...)
		return append(out, doneLine), nil
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
		if s.finish != nil && !s.split && len(delta) > 0 {
			prior, err := s.splitFinish()
			if err != nil {
				return nil, err
			}
			return append(prior, line), nil
		}
		return [][]byte{line}, nil
	}
	if s.finish != nil {
		return nil, errors.New("duplicate streaming finish")
	}
	s.finish = event
	s.rawFinish = append([]byte(nil), line...)
	s.finishFrameOpen = true
	return nil, nil
}

func (s *streamOrdering) splitFinish() ([][]byte, error) {
	event := s.finish
	choice := event["choices"].([]any)[0].(map[string]any)
	reason := choice["finish_reason"]
	choice["finish_reason"] = nil
	encoded, err := json.Marshal(event)
	if err != nil {
		return nil, err
	}
	// Keep only terminal metadata; delta and usage have crossed the wire once.
	terminal := make(map[string]any, len(event))
	for k, v := range event {
		terminal[k] = v
	}
	terminal["choices"] = []any{map[string]any{"index": choice["index"], "delta": map[string]any{}, "finish_reason": reason}}
	delete(terminal, "usage")
	s.finish = terminal
	s.split = true
	delta, _ := choice["delta"].(map[string]any)
	if len(delta) == 0 && event["usage"] == nil {
		return nil, nil
	}
	return [][]byte{append(append([]byte("data: "), encoded...), '\n', '\n')}, nil
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
	if !s.split && choice["finish_reason"] == reason {
		raw := s.rawFinish
		s.finish = nil
		s.rawFinish = nil
		return [][]byte{raw}, nil
	}
	encoded, err := json.Marshal(s.finish)
	if err != nil {
		return nil, err
	}
	s.finish = nil
	return [][]byte{append(append([]byte("data: "), encoded...), '\n', '\n')}, nil
}
