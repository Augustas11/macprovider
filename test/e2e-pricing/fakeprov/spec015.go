package main

// SPEC-015 canonical hashing / JCS helpers, ported verbatim from
// test/integration/harness_test.go (spec015CanonicalPromptHash ..
// escapeSpec015JCSString). The coordinator's own canonicalizer is
// phase4-coordinator/internal/jcs/jcs.go; keep these byte-identical to the
// harness copy so receipts verify the same way.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"

	"golang.org/x/text/unicode/norm"
)

func spec015CanonicalPromptHash(requestBody []byte) (string, error) {
	var raw map[string]any
	if err := json.Unmarshal(requestBody, &raw); err != nil {
		return "", err
	}
	messages, err := canonicalPromptMessages(raw["messages"])
	if err != nil {
		return "", err
	}
	object := map[string]any{
		"model":             raw["model"],
		"messages":          messages,
		"tools":             canonicalPromptTools(raw["tools"]),
		"temperature":       valueOrNil(raw, "temperature"),
		"top_p":             valueOrNil(raw, "top_p"),
		"max_tokens":        valueOrNil(raw, "max_tokens"),
		"stop":              valueOrNil(raw, "stop"),
		"seed":              valueOrNil(raw, "seed"),
		"response_format":   valueOrNil(raw, "response_format"),
		"tool_choice":       valueOrNil(raw, "tool_choice"),
		"presence_penalty":  valueOrNil(raw, "presence_penalty"),
		"frequency_penalty": valueOrNil(raw, "frequency_penalty"),
		"logit_bias":        valueOrNil(raw, "logit_bias"),
		"logprobs":          valueOrNil(raw, "logprobs"),
		"top_logprobs":      valueOrNil(raw, "top_logprobs"),
		"n":                 valueOrNil(raw, "n"),
	}
	return spec015JCSHash(object)
}

func canonicalPromptMessages(value any) ([]any, error) {
	rawMessages, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("messages has type %T, want array", value)
	}
	messages := make([]any, 0, len(rawMessages))
	for _, item := range rawMessages {
		message, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("message has type %T, want object", item)
		}
		content, err := canonicalPromptContent(message["content"])
		if err != nil {
			return nil, err
		}
		messages = append(messages, map[string]any{
			"role":         valueOrNil(message, "role"),
			"content":      content,
			"name":         valueOrNil(message, "name"),
			"tool_call_id": valueOrNil(message, "tool_call_id"),
			"tool_calls":   canonicalPromptToolCalls(message["tool_calls"]),
		})
	}
	return messages, nil
}

func canonicalPromptContent(value any) (any, error) {
	switch typed := value.(type) {
	case nil:
		return nil, nil
	case string:
		return normalizeSpec015LineEndings(typed), nil
	case []any:
		parts := make([]any, 0, len(typed))
		for _, item := range typed {
			object, ok := item.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("content part has type %T, want object", item)
			}
			kind, _ := object["type"].(string)
			switch kind {
			case "text":
				text, _ := object["text"].(string)
				parts = append(parts, map[string]any{"type": "text", "text": normalizeSpec015LineEndings(text)})
			case "image_url":
				parts = append(parts, map[string]any{"type": "image_url", "image_url": object["image_url"]})
			case "input_audio":
				parts = append(parts, map[string]any{"type": "input_audio", "input_audio": object["input_audio"]})
			default:
				return nil, fmt.Errorf("unsupported content part type %q", kind)
			}
		}
		return parts, nil
	default:
		return nil, fmt.Errorf("content has type %T, want string, array, or null", value)
	}
}

func canonicalPromptTools(value any) any {
	if value == nil {
		return nil
	}
	return value
}

func canonicalPromptToolCalls(value any) any {
	if value == nil {
		return nil
	}
	return value
}

func spec015CanonicalOutputHash(responseBody []byte) (string, error) {
	var response struct {
		Choices []struct {
			Message struct {
				Content   string `json:"content"`
				ToolCalls any    `json:"tool_calls"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(responseBody, &response); err != nil {
		return "", err
	}
	if len(response.Choices) == 0 {
		return "", errors.New("response has no choices")
	}
	choice := response.Choices[0]
	object := map[string]any{
		"content":       normalizeSpec015LineEndings(choice.Message.Content),
		"tool_calls":    choice.Message.ToolCalls,
		"finish_reason": choice.FinishReason,
	}
	return spec015JCSHash(object)
}

func valueOrNil(values map[string]any, key string) any {
	if value, ok := values[key]; ok {
		return value
	}
	return nil
}

func normalizeSpec015LineEndings(value string) string {
	return strings.ReplaceAll(strings.ReplaceAll(value, "\r\n", "\n"), "\r", "\n")
}

func spec015JCSHash(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

func spec015CanonicalSHA256Hex(value any) (string, []byte, error) {
	canonical, err := spec015CanonicalJSON(value)
	if err != nil {
		return "", nil, err
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), canonical, nil
}

func spec015CanonicalJSON(v any) ([]byte, error) {
	var b bytes.Buffer
	if err := writeSpec015JCS(&b, v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func writeSpec015JCS(b *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case string:
		b.WriteString(escapeSpec015JCSString(norm.NFC.String(x)))
	case bool:
		if x {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case int:
		b.WriteString(strconv.Itoa(x))
	case int64:
		b.WriteString(strconv.FormatInt(x, 10))
	case json.Number:
		formatted, err := canonicalSpec015JSONNumber(x.String())
		if err != nil {
			return err
		}
		b.WriteString(formatted)
	case float64:
		formatted, err := canonicalSpec015Double(x)
		if err != nil {
			return err
		}
		b.WriteString(formatted)
	case []any:
		b.WriteByte('[')
		for i, item := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeSpec015JCS(b, item); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(x))
		for key := range x {
			keys = append(keys, key)
		}
		sort.Slice(keys, func(i, j int) bool {
			return spec015UTF16Less(keys[i], keys[j])
		})
		b.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(escapeSpec015JCSString(key))
			b.WriteByte(':')
			if err := writeSpec015JCS(b, x[key]); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	default:
		return fmt.Errorf("unsupported JCS value %T", v)
	}
	return nil
}

var integerNumberPattern = regexp.MustCompile(`^-?(0|[1-9][0-9]*)$`)

func canonicalSpec015JSONNumber(raw string) (string, error) {
	if integerNumberPattern.MatchString(raw) {
		n, err := strconv.ParseInt(raw, 10, 64)
		if err == nil {
			return strconv.FormatInt(n, 10), nil
		}
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
		return "", fmt.Errorf("invalid JSON number %q", raw)
	}
	if f == math.Trunc(f) && f >= math.MinInt64 && f <= math.MaxInt64 {
		return strconv.FormatInt(int64(f), 10), nil
	}
	return canonicalSpec015Double(f)
}

func canonicalSpec015Double(f float64) (string, error) {
	if math.IsInf(f, 0) || math.IsNaN(f) {
		return "", fmt.Errorf("non-finite number")
	}
	if f == 0 {
		return "0", nil
	}
	sign := ""
	if f < 0 {
		sign = "-"
		f = -f
	}
	digits, e, err := decimalDigitsAndExponent(strconv.FormatFloat(f, 'g', -1, 64))
	if err != nil {
		return "", err
	}
	return sign + renderSpec015ECMAScriptNumber(digits, e), nil
}

func decimalDigitsAndExponent(s string) (string, int, error) {
	if split := strings.IndexAny(s, "eE"); split >= 0 {
		mantissa := s[:split]
		exp, err := strconv.Atoi(s[split+1:])
		if err != nil {
			return "", 0, fmt.Errorf("parse float exponent %q: %w", s, err)
		}
		point := strings.IndexByte(mantissa, '.')
		integerDigits := len(mantissa)
		if point >= 0 {
			integerDigits = point
			mantissa = mantissa[:point] + mantissa[point+1:]
		}
		digits := strings.TrimLeft(mantissa, "0")
		if digits == "" {
			return "0", 1, nil
		}
		return digits, exp + integerDigits, nil
	}
	point := strings.IndexByte(s, '.')
	if point < 0 {
		point = len(s)
	} else {
		s = s[:point] + s[point+1:]
	}
	leadingZeroes := len(s) - len(strings.TrimLeft(s, "0"))
	digits := strings.TrimLeft(s, "0")
	if digits == "" {
		return "0", 1, nil
	}
	return digits, point - leadingZeroes, nil
}

func renderSpec015ECMAScriptNumber(digits string, e int) string {
	k := len(digits)
	switch {
	case k <= e && e <= 21:
		return digits + strings.Repeat("0", e-k)
	case 0 < e && e <= 21:
		return digits[:e] + "." + digits[e:]
	case -6 < e && e <= 0:
		return "0." + strings.Repeat("0", -e) + digits
	default:
		exponent := e - 1
		mantissa := digits[:1]
		if k > 1 {
			mantissa += "." + digits[1:]
		}
		if exponent >= 0 {
			return mantissa + "e+" + strconv.Itoa(exponent)
		}
		return mantissa + "e-" + strconv.Itoa(-exponent)
	}
}

func spec015UTF16Less(a, b string) bool {
	aa := utf16.Encode([]rune(a))
	bb := utf16.Encode([]rune(b))
	for i := 0; i < len(aa) && i < len(bb); i++ {
		if aa[i] != bb[i] {
			return aa[i] < bb[i]
		}
	}
	return len(aa) < len(bb)
}

func escapeSpec015JCSString(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\t':
			b.WriteString(`\t`)
		case '\n':
			b.WriteString(`\n`)
		case '\f':
			b.WriteString(`\f`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if r >= 0 && r <= 0x1f {
				b.WriteString(`\u00`)
				b.WriteString(hex.EncodeToString([]byte{byte(r)}))
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
