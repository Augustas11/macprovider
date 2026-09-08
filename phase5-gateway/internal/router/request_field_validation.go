package router

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

// Validate before struct decoding or translation can merge duplicate members or
// case-fold names that downstream exact-key parsers interpret differently.
// Only schema-owned fields are constrained; extension and user-defined keys are
// not a closed schema. The HTTP body limit and encoding/json depth limit bound
// work, and nested values are consumed without a recursive custom parser.
func validateRequestFieldNames(body []byte, names ...string) (map[string]json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	start, err := dec.Token()
	if err != nil || start != json.Delim('{') {
		return nil, fmt.Errorf("request must be a JSON object")
	}
	fields := make(map[string]json.RawMessage, len(names))
	for dec.More() {
		token, err := dec.Token()
		if err != nil {
			return nil, fmt.Errorf("Malformed JSON")
		}
		name, ok := token.(string)
		if !ok {
			return nil, fmt.Errorf("Malformed JSON")
		}
		canonical := ""
		for _, candidate := range names {
			if strings.EqualFold(name, candidate) {
				canonical = candidate
				break
			}
		}
		if canonical != "" {
			if name != canonical {
				return nil, fmt.Errorf("%s must use its canonical field name", canonical)
			}
			if _, exists := fields[canonical]; exists {
				return nil, fmt.Errorf("%s must not be repeated", canonical)
			}
		}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return nil, fmt.Errorf("Malformed JSON")
		}
		if canonical != "" {
			fields[canonical] = value
		}
	}
	if end, err := dec.Token(); err != nil || end != json.Delim('}') {
		return nil, fmt.Errorf("Malformed JSON")
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("Malformed JSON")
	}
	return fields, nil
}

func validateChatRequestFieldNames(body []byte) error {
	fields, err := validateRequestFieldNames(body,
		"model", "messages", "max_tokens", "n", "stream", "response_format")
	if err != nil {
		return err
	}
	// response_format.type selects the structured-stream deadline. Do not
	// inspect arbitrary property names inside the buyer's JSON schema.
	format := bytes.TrimSpace(fields["response_format"])
	if len(format) > 0 && format[0] == '{' {
		if _, err := validateRequestFieldNames(format, "type"); err != nil {
			return fmt.Errorf("response_format: %w", err)
		}
	}
	return nil
}

func validateResponsesRequestFieldNames(body []byte) error {
	fields, err := validateRequestFieldNames(body,
		"model", "input", "instructions", "tools", "tool_choice",
		"max_output_tokens", "stream", "previous_response_id", "store",
		"temperature", "top_p", "response_format", "text", "metadata", "user",
		"reasoning", "parallel_tool_calls", "conversation", "include", "truncation", "background")
	if err != nil {
		return err
	}
	text := bytes.TrimSpace(fields["text"])
	if len(text) > 0 && text[0] == '{' {
		textFields, err := validateRequestFieldNames(text, "format")
		if err != nil {
			return fmt.Errorf("text: %w", err)
		}
		format := bytes.TrimSpace(textFields["format"])
		if len(format) > 0 && format[0] == '{' {
			if _, err := validateRequestFieldNames(format, "type"); err != nil {
				return fmt.Errorf("text.format: %w", err)
			}
		}
	}
	return nil
}
