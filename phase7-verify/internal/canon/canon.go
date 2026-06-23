// Package canon canonicalizes SPEC-015 prompt and output hash inputs.
package canon

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"

	"github.com/augstar/macprovider/phase7-verify/internal/jcs"
)

var (
	ErrInvalidContent         = errors.New("message content must be null, string, or array of content parts")
	ErrInvalidContentPartType = errors.New("content part type not in {text, image_url, input_audio}")
	ErrInvalidTools           = errors.New("tools must be null or array")
	ErrInvalidToolCalls       = errors.New("tool_calls must be null or array")
	ErrExpectedObject         = errors.New("value must be a JSON object")
	ErrExpectedString         = errors.New("value must be a JSON string")
	ErrInvalidFinishReason    = errors.New("finish_reason not in {stop, length, tool_calls, content_filter, error}")
	ErrMissingChoices         = errors.New("response.choices is missing or not an array")
	ErrEmptyChoices           = errors.New("response.choices is empty")
)

// CanonicalPrompt builds the SPEC-015 §4 canonical prompt object from a raw
// OpenAI /v1/chat/completions request body and returns its canonical JCS bytes
// plus SHA-256 hash. Missing optional fields canonicalize as JSON null per
// SPEC-015 §4.2.
func CanonicalPrompt(request map[string]any) ([]byte, [32]byte, error) {
	model, err := stringValue(request["model"])
	if err != nil {
		return nil, [32]byte{}, fmt.Errorf("%w: model", err)
	}

	messagesRaw, ok := request["messages"].([]any)
	if !ok {
		return nil, [32]byte{}, fmt.Errorf("%w: messages", ErrExpectedObject)
	}
	messages := make([]jcs.Value, 0, len(messagesRaw))
	for i, message := range messagesRaw {
		canonical, err := canonicalMessage(message)
		if err != nil {
			return nil, [32]byte{}, fmt.Errorf("messages[%d]: %w", i, err)
		}
		messages = append(messages, canonical)
	}

	tools, err := canonicalTools(request["tools"])
	if err != nil {
		return nil, [32]byte{}, err
	}

	object := map[string]jcs.Value{
		"model":             {Kind: jcs.KindString, String: model},
		"messages":          {Kind: jcs.KindArray, Array: messages},
		"tools":             tools,
		"temperature":       jcsOrNull(request, "temperature"),
		"top_p":             jcsOrNull(request, "top_p"),
		"max_tokens":        jcsOrNull(request, "max_tokens"),
		"stop":              jcsOrNull(request, "stop"),
		"seed":              jcsOrNull(request, "seed"),
		"response_format":   jcsOrNull(request, "response_format"),
		"tool_choice":       jcsOrNull(request, "tool_choice"),
		"presence_penalty":  jcsOrNull(request, "presence_penalty"),
		"frequency_penalty": jcsOrNull(request, "frequency_penalty"),
		"logit_bias":        jcsOrNull(request, "logit_bias"),
		"logprobs":          jcsOrNull(request, "logprobs"),
		"top_logprobs":      jcsOrNull(request, "top_logprobs"),
		"n":                 jcsOrNull(request, "n"),
	}

	return canonicalBytesAndHash(jcs.Value{Kind: jcs.KindObject, Object: object})
}

// CanonicalOutput builds the SPEC-015 §5 canonical output object from a raw
// OpenAI completion response and returns canonical JCS bytes plus SHA-256 hash.
// The response.choices[0] is the source: content, tool_calls, finish_reason.
func CanonicalOutput(response map[string]any) ([]byte, [32]byte, error) {
	choices, ok := response["choices"].([]any)
	if !ok {
		return nil, [32]byte{}, ErrMissingChoices
	}
	if len(choices) == 0 {
		return nil, [32]byte{}, ErrEmptyChoices
	}
	choice, err := objectValue(choices[0])
	if err != nil {
		return nil, [32]byte{}, fmt.Errorf("choices[0]: %w", err)
	}
	message, err := objectValue(choice["message"])
	if err != nil {
		return nil, [32]byte{}, fmt.Errorf("choices[0].message: %w", err)
	}

	content := ""
	if value, ok := message["content"]; ok && value != nil {
		content, err = stringValue(value)
		if err != nil {
			return nil, [32]byte{}, fmt.Errorf("choices[0].message.content: %w", err)
		}
	}

	toolCalls := jcs.Value{Kind: jcs.KindNull}
	if value, ok := message["tool_calls"]; ok {
		toolCalls, err = canonicalToolCalls(value)
		if err != nil {
			return nil, [32]byte{}, err
		}
	}

	finishReason, err := stringValue(choice["finish_reason"])
	if err != nil {
		return nil, [32]byte{}, fmt.Errorf("choices[0].finish_reason: %w", err)
	}
	if !validFinishReason(finishReason) {
		return nil, [32]byte{}, ErrInvalidFinishReason
	}

	object := map[string]jcs.Value{
		"content":       {Kind: jcs.KindString, String: normalizeLineEndings(content)},
		"tool_calls":    toolCalls,
		"finish_reason": {Kind: jcs.KindString, String: finishReason},
	}
	return canonicalBytesAndHash(jcs.Value{Kind: jcs.KindObject, Object: object})
}

func canonicalMessage(value any) (jcs.Value, error) {
	object, err := objectValue(value)
	if err != nil {
		return jcs.Value{}, err
	}
	role, err := stringValue(object["role"])
	if err != nil {
		return jcs.Value{}, fmt.Errorf("role: %w", err)
	}
	content, err := canonicalContent(object["content"])
	if err != nil {
		return jcs.Value{}, err
	}
	toolCalls, err := canonicalToolCalls(object["tool_calls"])
	if err != nil {
		return jcs.Value{}, err
	}
	return jcs.Value{Kind: jcs.KindObject, Object: map[string]jcs.Value{
		"role":         {Kind: jcs.KindString, String: role},
		"content":      content,
		"name":         jcsOrNull(object, "name"),
		"tool_call_id": jcsOrNull(object, "tool_call_id"),
		"tool_calls":   toolCalls,
	}}, nil
}

func canonicalContent(value any) (jcs.Value, error) {
	switch typed := value.(type) {
	case nil:
		return jcs.Value{Kind: jcs.KindNull}, nil
	case string:
		return jcs.Value{Kind: jcs.KindString, String: normalizeLineEndings(typed)}, nil
	case []any:
		parts := make([]jcs.Value, 0, len(typed))
		for i, part := range typed {
			canonical, err := canonicalContentPart(part)
			if err != nil {
				return jcs.Value{}, fmt.Errorf("content[%d]: %w", i, err)
			}
			parts = append(parts, canonical)
		}
		return jcs.Value{Kind: jcs.KindArray, Array: parts}, nil
	default:
		return jcs.Value{}, ErrInvalidContent
	}
}

func canonicalContentPart(value any) (jcs.Value, error) {
	object, err := objectValue(value)
	if err != nil {
		return jcs.Value{}, err
	}
	kind, err := stringValue(object["type"])
	if err != nil {
		return jcs.Value{}, fmt.Errorf("type: %w", err)
	}

	switch kind {
	case "text":
		text, err := stringValue(object["text"])
		if err != nil {
			return jcs.Value{}, fmt.Errorf("text: %w", err)
		}
		return jcs.Value{Kind: jcs.KindObject, Object: map[string]jcs.Value{
			"type": {Kind: jcs.KindString, String: "text"},
			"text": {Kind: jcs.KindString, String: normalizeLineEndings(text)},
		}}, nil
	case "image_url":
		imageURL, err := objectValue(object["image_url"])
		if err != nil {
			return jcs.Value{}, fmt.Errorf("image_url: %w", err)
		}
		url, err := stringValue(imageURL["url"])
		if err != nil {
			return jcs.Value{}, fmt.Errorf("image_url.url: %w", err)
		}
		return jcs.Value{Kind: jcs.KindObject, Object: map[string]jcs.Value{
			"type": {Kind: jcs.KindString, String: "image_url"},
			"image_url": {Kind: jcs.KindObject, Object: map[string]jcs.Value{
				"url":    {Kind: jcs.KindString, String: url},
				"detail": jcsOrNull(imageURL, "detail"),
			}},
		}}, nil
	case "input_audio":
		inputAudio, err := objectValue(object["input_audio"])
		if err != nil {
			return jcs.Value{}, fmt.Errorf("input_audio: %w", err)
		}
		data, err := stringValue(inputAudio["data"])
		if err != nil {
			return jcs.Value{}, fmt.Errorf("input_audio.data: %w", err)
		}
		format, err := stringValue(inputAudio["format"])
		if err != nil {
			return jcs.Value{}, fmt.Errorf("input_audio.format: %w", err)
		}
		return jcs.Value{Kind: jcs.KindObject, Object: map[string]jcs.Value{
			"type": {Kind: jcs.KindString, String: "input_audio"},
			"input_audio": {Kind: jcs.KindObject, Object: map[string]jcs.Value{
				"data":   {Kind: jcs.KindString, String: data},
				"format": {Kind: jcs.KindString, String: format},
			}},
		}}, nil
	default:
		return jcs.Value{}, ErrInvalidContentPartType
	}
}

func canonicalTools(value any) (jcs.Value, error) {
	if value == nil {
		return jcs.Value{Kind: jcs.KindNull}, nil
	}
	tools, ok := value.([]any)
	if !ok {
		return jcs.Value{}, ErrInvalidTools
	}
	items := make([]jcs.Value, 0, len(tools))
	for i, tool := range tools {
		canonical, err := canonicalTool(tool)
		if err != nil {
			return jcs.Value{}, fmt.Errorf("tools[%d]: %w", i, err)
		}
		items = append(items, canonical)
	}
	return jcs.Value{Kind: jcs.KindArray, Array: items}, nil
}

func canonicalTool(value any) (jcs.Value, error) {
	object, err := objectValue(value)
	if err != nil {
		return jcs.Value{}, err
	}
	function, err := objectValue(object["function"])
	if err != nil {
		return jcs.Value{}, fmt.Errorf("function: %w", err)
	}
	name, err := stringValue(function["name"])
	if err != nil {
		return jcs.Value{}, fmt.Errorf("function.name: %w", err)
	}
	return jcs.Value{Kind: jcs.KindObject, Object: map[string]jcs.Value{
		"type": {Kind: jcs.KindString, String: "function"},
		"function": {Kind: jcs.KindObject, Object: map[string]jcs.Value{
			"name":        {Kind: jcs.KindString, String: name},
			"description": jcsOrNull(function, "description"),
			"parameters":  jcsOrNull(function, "parameters"),
		}},
	}}, nil
}

func canonicalToolCalls(value any) (jcs.Value, error) {
	if value == nil {
		return jcs.Value{Kind: jcs.KindNull}, nil
	}
	calls, ok := value.([]any)
	if !ok {
		return jcs.Value{}, ErrInvalidToolCalls
	}
	items := make([]jcs.Value, 0, len(calls))
	for i, call := range calls {
		canonical, err := canonicalToolCall(call)
		if err != nil {
			return jcs.Value{}, fmt.Errorf("tool_calls[%d]: %w", i, err)
		}
		items = append(items, canonical)
	}
	return jcs.Value{Kind: jcs.KindArray, Array: items}, nil
}

func canonicalToolCall(value any) (jcs.Value, error) {
	object, err := objectValue(value)
	if err != nil {
		return jcs.Value{}, err
	}
	id, err := stringValue(object["id"])
	if err != nil {
		return jcs.Value{}, fmt.Errorf("id: %w", err)
	}
	function, err := objectValue(object["function"])
	if err != nil {
		return jcs.Value{}, fmt.Errorf("function: %w", err)
	}
	name, err := stringValue(function["name"])
	if err != nil {
		return jcs.Value{}, fmt.Errorf("function.name: %w", err)
	}
	arguments, err := stringValue(function["arguments"])
	if err != nil {
		return jcs.Value{}, fmt.Errorf("function.arguments: %w", err)
	}
	return jcs.Value{Kind: jcs.KindObject, Object: map[string]jcs.Value{
		"id":   {Kind: jcs.KindString, String: id},
		"type": {Kind: jcs.KindString, String: "function"},
		"function": {Kind: jcs.KindObject, Object: map[string]jcs.Value{
			"name":      {Kind: jcs.KindString, String: name},
			"arguments": {Kind: jcs.KindRawString, RawString: arguments},
		}},
	}}, nil
}

func jcsOrNull(object map[string]any, key string) jcs.Value {
	value, ok := object[key]
	if !ok || value == nil {
		return jcs.Value{Kind: jcs.KindNull}
	}
	return jcsValue(value)
}

func jcsValue(value any) jcs.Value {
	switch typed := value.(type) {
	case map[string]any:
		object := make(map[string]jcs.Value, len(typed))
		for key, member := range typed {
			object[key] = jcsValue(member)
		}
		return jcs.Value{Kind: jcs.KindObject, Object: object}
	case []any:
		array := make([]jcs.Value, 0, len(typed))
		for _, item := range typed {
			array = append(array, jcsValue(item))
		}
		return jcs.Value{Kind: jcs.KindArray, Array: array}
	case string:
		return jcs.Value{Kind: jcs.KindString, String: typed}
	case json.Number:
		return jcsNumber(typed)
	case float64:
		return jcsFloat64(typed)
	case float32:
		return jcsFloat64(float64(typed))
	case int:
		return jcs.Value{Kind: jcs.KindInt, Int: int64(typed)}
	case int8:
		return jcs.Value{Kind: jcs.KindInt, Int: int64(typed)}
	case int16:
		return jcs.Value{Kind: jcs.KindInt, Int: int64(typed)}
	case int32:
		return jcs.Value{Kind: jcs.KindInt, Int: int64(typed)}
	case int64:
		return jcs.Value{Kind: jcs.KindInt, Int: typed}
	case uint:
		return jcsUint64(uint64(typed))
	case uint8:
		return jcs.Value{Kind: jcs.KindInt, Int: int64(typed)}
	case uint16:
		return jcs.Value{Kind: jcs.KindInt, Int: int64(typed)}
	case uint32:
		return jcs.Value{Kind: jcs.KindInt, Int: int64(typed)}
	case uint64:
		return jcsUint64(typed)
	case bool:
		return jcs.Value{Kind: jcs.KindBool, Bool: typed}
	case nil:
		return jcs.Value{Kind: jcs.KindNull}
	default:
		return jcs.Value{Kind: jcs.KindString, String: fmt.Sprint(typed)}
	}
}

func jcsNumber(number json.Number) jcs.Value {
	f, err := number.Float64()
	if err == nil && isIntegralFloat64(f) {
		return jcs.Value{Kind: jcs.KindInt, Int: int64(f)}
	}
	if i, err := number.Int64(); err == nil {
		return jcs.Value{Kind: jcs.KindInt, Int: i}
	}
	if err != nil {
		return jcs.Value{Kind: jcs.KindDouble, Double: math.NaN()}
	}
	return jcs.Value{Kind: jcs.KindDouble, Double: f}
}

func jcsFloat64(value float64) jcs.Value {
	if isIntegralFloat64(value) {
		return jcs.Value{Kind: jcs.KindInt, Int: int64(value)}
	}
	return jcs.Value{Kind: jcs.KindDouble, Double: value}
}

func jcsUint64(value uint64) jcs.Value {
	if value <= math.MaxInt64 {
		return jcs.Value{Kind: jcs.KindInt, Int: int64(value)}
	}
	return jcs.Value{Kind: jcs.KindDouble, Double: float64(value)}
}

func isIntegralFloat64(value float64) bool {
	return !math.IsNaN(value) &&
		!math.IsInf(value, 0) &&
		value >= float64(math.MinInt64) &&
		value <= float64(math.MaxInt64) &&
		math.Trunc(value) == value
}

func objectValue(value any) (map[string]any, error) {
	object, ok := value.(map[string]any)
	if !ok {
		return nil, ErrExpectedObject
	}
	return object, nil
}

func stringValue(value any) (string, error) {
	stringValue, ok := value.(string)
	if !ok {
		return "", ErrExpectedString
	}
	return stringValue, nil
}

func normalizeLineEndings(value string) string {
	return strings.ReplaceAll(strings.ReplaceAll(value, "\r\n", "\n"), "\r", "\n")
}

func validFinishReason(value string) bool {
	switch value {
	case "stop", "length", "tool_calls", "content_filter", "error":
		return true
	default:
		return false
	}
}

func canonicalBytesAndHash(value jcs.Value) ([]byte, [32]byte, error) {
	canonical, err := jcs.Canonicalize(value)
	if err != nil {
		return nil, [32]byte{}, err
	}
	return canonical, sha256.Sum256(canonical), nil
}
