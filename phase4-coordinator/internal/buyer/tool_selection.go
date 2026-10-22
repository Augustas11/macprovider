package buyer

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"reflect"
	"strconv"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const streamingModeToolSelectionHoldback = "buffered_tool_selection"

type toolSelectionPolicy struct {
	mode     string
	name     string
	parallel bool
	schemas  map[string]json.RawMessage
	// strict marks schemas in the strict validator subset. Others are ordinary
	// OpenAI parameters objects (SPEC-018 §3.11 v0.3.1): their output is checked
	// for an arguments object holding every root required property.
	strict map[string]bool
}

type toolSelectionRequestError struct{ code, message string }

func unsupportedToolChoiceRouteError() *routeError {
	return &routeError{status: http.StatusBadRequest, code: "unsupported_tool_choice", message: "No compatible provider supports the requested tool selection"}
}

func providerSupportsToolSelection(p pool.Provider, policy *toolSelectionPolicy) bool {
	if policy == nil {
		return true
	}
	// SPEC-018 §3.11: guaranteed selection follows the native provider's
	// declared capability for its exact loaded model; the coordinator still
	// validates every guaranteed output (schema holdback). Legacy and external
	// adapters cannot gain authority by declaring a mode.
	if p.RuntimeSource != "" && p.RuntimeSource != engineClassNative {
		return false
	}
	for _, cap := range p.ToolSelectionCapabilities {
		if cap.ModelID != p.ModelID || cap.Runtime != engineClassNative || cap.Validation != "schema-holdback-v1" {
			continue
		}
		for _, mode := range cap.Modes {
			if mode == policy.mode {
				return true
			}
		}
	}
	return false
}

func validateToolSelection(body []byte, raw map[string]json.RawMessage) (*toolSelectionPolicy, *toolSelectionRequestError) {
	fail := func(code, msg string) (*toolSelectionPolicy, *toolSelectionRequestError) {
		return nil, &toolSelectionRequestError{code, msg}
	}
	for _, field := range []string{"tool_choice", "tools", "parallel_tool_calls", "max_tokens", "max_completion_tokens"} {
		count, noncanonical, err := countTopLevelField(body, field)
		if err != nil || count > 1 || noncanonical {
			return fail("invalid_tool_choice", "Duplicate or non-canonical tool selection field")
		}
	}
	parallel := false
	if v, ok := raw["parallel_tool_calls"]; ok {
		if bytes.Equal(bytes.TrimSpace(v), []byte("null")) || json.Unmarshal(v, &parallel) != nil {
			return fail("invalid_tool_choice", "parallel_tool_calls must be a boolean")
		}
	}
	value, ok := raw["tool_choice"]
	if !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
		return nil, nil
	}
	var mode string
	var name string
	if json.Unmarshal(value, &mode) != nil {
		var choice struct {
			Type     string `json:"type"`
			Function struct {
				Name string `json:"name"`
			} `json:"function"`
		}
		var named map[string]json.RawMessage
		var function map[string]json.RawMessage
		_ = json.Unmarshal(value, &named)
		_ = json.Unmarshal(named["function"], &function)
		if len(named) != 2 || len(function) != 1 || !canonicalToolObject(value, "type", "function") || !canonicalNestedToolObject(value, "function", "name") || json.Unmarshal(value, &choice) != nil || choice.Type != "function" || !validJSONSchemaName(choice.Function.Name) {
			return fail("invalid_tool_choice", "tool_choice must select a supported mode or named function")
		}
		mode = "named"
		name = choice.Function.Name
	}
	if mode != "auto" && mode != "none" && mode != "required" && mode != "named" {
		return fail("invalid_tool_choice", "tool_choice must be auto, none, required, or a named function")
	}
	if mode == "auto" {
		return nil, nil
	}
	policy := &toolSelectionPolicy{mode: mode, name: name, parallel: parallel, schemas: map[string]json.RawMessage{}, strict: map[string]bool{}}
	if mode == "none" {
		return policy, nil
	}
	if v, ok := raw["response_format"]; ok && !bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
		var format struct {
			Type string `json:"type"`
		}
		if !canonicalToolObject(v, "type") || json.Unmarshal(v, &format) != nil || format.Type != "text" {
			return fail("unsupported_tool_choice", "Guaranteed tool selection cannot be combined with structured response_format")
		}
	}
	if stop, ok := raw["stop"]; ok && !bytes.Equal(bytes.TrimSpace(stop), []byte("null")) && !bytes.Equal(bytes.TrimSpace(stop), []byte("[]")) {
		return fail("unsupported_tool_choice", "Custom stop sequences are unsupported for guaranteed tool selection")
	}
	budget, exists := raw["max_tokens"]
	if !exists || bytes.Equal(bytes.TrimSpace(budget), []byte("null")) {
		budget = raw["max_completion_tokens"]
	}
	var maxTokens int
	if json.Unmarshal(budget, &maxTokens) != nil || maxTokens < 1 || maxTokens > 16384 {
		return fail("unsupported_tool_choice", "Guaranteed tool selection requires explicit max_tokens or max_completion_tokens in 1...16384")
	}
	var tools []struct {
		Type     string `json:"type"`
		Function struct {
			Name       string          `json:"name"`
			Parameters json.RawMessage `json:"parameters"`
		} `json:"function"`
	}
	if json.Unmarshal(raw["tools"], &tools) != nil || len(tools) == 0 || len(tools) > maxAssistantToolCalls {
		return fail("invalid_tool_choice", "Guaranteed tool selection requires declared functions")
	}
	var rawTools []json.RawMessage
	_ = json.Unmarshal(raw["tools"], &rawTools)
	for i, tool := range tools {
		if !canonicalToolObject(rawTools[i], "type", "function") || !canonicalNestedToolObject(rawTools[i], "function", "name", "parameters", "strict", "description") {
			return fail("invalid_tool_choice", "Duplicate or non-canonical function declaration field")
		}
		if tool.Type != "function" || !validJSONSchemaName(tool.Function.Name) {
			return fail("invalid_tools", "Invalid function declaration")
		}
		if _, exists := policy.schemas[tool.Function.Name]; exists {
			return fail("invalid_tools", "Duplicate function name")
		}
		if !uniqueJSONKeys(tool.Function.Parameters, maxJSONSchemaDepth) {
			return fail("unsupported_tool_schema", "Tool schema contains duplicate keys or exceeds depth cap")
		}
		if !toolSchemaNumbersSupported(tool.Function.Parameters) {
			return fail("unsupported_tool_schema", "Tool schema numbers exceed the supported finite numeric range")
		}
		if len(tool.Function.Parameters) > maxJSONSchemaBytes {
			return fail("unsupported_tool_schema", "Tool argument schema exceeds 16 KiB")
		}
		var schema map[string]json.RawMessage
		if json.Unmarshal(tool.Function.Parameters, &schema) != nil || string(bytes.TrimSpace(schema["type"])) != `"object"` {
			return fail("unsupported_tool_schema", "Guaranteed tool selection requires an object parameters schema")
		}
		policy.schemas[tool.Function.Name] = tool.Function.Parameters
		policy.strict[tool.Function.Name] = toolSchemaShapesSupported(tool.Function.Parameters, 1) && validateJSONSchemaRaw(tool.Function.Parameters, "", 1) == nil
	}
	if mode == "named" {
		if _, ok := policy.schemas[name]; !ok {
			return fail("invalid_tool_choice", "Selected function is not declared in tools")
		}
	}
	return policy, nil
}

// Check only known envelope keys; arbitrary schema property names remain case-sensitive.
func canonicalToolObject(raw []byte, fields ...string) bool {
	var object map[string]json.RawMessage
	if json.Unmarshal(raw, &object) != nil || object == nil {
		return false
	}
	for _, field := range fields {
		count, alias, err := countTopLevelField(raw, field)
		if err != nil || count > 1 || alias {
			return false
		}
	}
	return true
}

func canonicalNestedToolObject(raw []byte, field string, fields ...string) bool {
	var object map[string]json.RawMessage
	if json.Unmarshal(raw, &object) != nil {
		return false
	}
	return canonicalToolObject(object[field], fields...)
}

// The generic response-format validator predates strict null handling. Keep the
// guaranteed tool subset strict without changing that separate API contract.
func toolSchemaShapesSupported(raw []byte, depth int) bool {
	if depth > maxJSONSchemaDepth {
		return false
	}
	var node map[string]json.RawMessage
	if json.Unmarshal(raw, &node) != nil || node == nil {
		return false
	}
	for key, value := range node {
		trimmed := bytes.TrimSpace(value)
		if key != "const" && bytes.Equal(trimmed, []byte("null")) {
			return false
		}
		switch key {
		case "properties":
			var properties map[string]json.RawMessage
			if json.Unmarshal(value, &properties) != nil || properties == nil {
				return false
			}
			for _, child := range properties {
				if !toolSchemaShapesSupported(child, depth+1) {
					return false
				}
			}
		case "items":
			if !toolSchemaShapesSupported(value, depth+1) {
				return false
			}
		case "enum", "required":
			if len(trimmed) == 0 || trimmed[0] != '[' {
				return false
			}
			if key == "required" {
				var entries []json.RawMessage
				if json.Unmarshal(value, &entries) != nil {
					return false
				}
				for _, entry := range entries {
					if entry = bytes.TrimSpace(entry); len(entry) == 0 || entry[0] != '"' {
						return false
					}
				}
			}
		case "additionalProperties":
			if !bytes.Equal(trimmed, []byte("false")) {
				return false
			}
		}
	}
	return true
}

var errUnsupportedToolSelectionSession = errors.New("provider tool selection capability changed before dispatch")

var errToolSelectionOutput = errors.New("Provider output violated the requested tool selection")

// validateToolSelectionOutput runs before any successful body, stream byte or
// settlement record is exposed. Provider capability advertisements are not proof
// that generated output obeys the request.
func validateToolSelectionOutput(policy *toolSelectionPolicy, body []byte, stream bool) error {
	if policy == nil {
		return nil
	}
	var calls []bufferedToolCall
	var finish string
	if stream {
		var err error
		calls, err = strictToolSelectionCalls(body)
		if err != nil {
			return errToolSelectionOutput
		}
		for _, line := range bytes.Split(body, []byte("\n")) {
			if !bytes.HasPrefix(line, []byte("data:")) {
				continue
			}
			data := bytes.TrimSpace(bytes.TrimPrefix(line, []byte("data:")))
			if bytes.Equal(data, []byte("[DONE]")) {
				continue
			}
			var frame struct {
				Choices []struct {
					Index  int     `json:"index"`
					Finish *string `json:"finish_reason"`
				} `json:"choices"`
			}
			if json.Unmarshal(data, &frame) != nil {
				return errToolSelectionOutput
			}
			for _, choice := range frame.Choices {
				if choice.Index != 0 {
					return errToolSelectionOutput
				}
				if choice.Finish != nil {
					finish = *choice.Finish
				}
			}
		}
	} else {
		var completion struct {
			Choices []struct {
				Finish  string `json:"finish_reason"`
				Message struct {
					ToolCalls []struct {
						ID       string `json:"id"`
						Type     string `json:"type"`
						Function struct {
							Name      string `json:"name"`
							Arguments string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"message"`
			} `json:"choices"`
		}
		if !validToolSelectionOutputKeys(body) || json.Unmarshal(body, &completion) != nil || len(completion.Choices) != 1 {
			return errToolSelectionOutput
		}
		finish = completion.Choices[0].Finish
		for _, call := range completion.Choices[0].Message.ToolCalls {
			calls = append(calls, bufferedToolCall{ID: call.ID, Type: call.Type, Name: call.Function.Name, Arguments: call.Function.Arguments})
		}
	}
	if policy.mode == "none" {
		if len(calls) != 0 || (finish != "stop" && finish != "length") {
			return errToolSelectionOutput
		}
		return nil
	}
	if finish != "tool_calls" || len(calls) == 0 || len(calls) > maxAssistantToolCalls || (!policy.parallel && len(calls) != 1) {
		return errToolSelectionOutput
	}
	total := 0
	ids := map[string]bool{}
	for _, call := range calls {
		schema, ok := policy.schemas[call.Name]
		total += len(call.Arguments)
		if !ok || (policy.mode == "named" && call.Name != policy.name) || call.ID == "" || ids[call.ID] || call.Type != "function" || len(call.Arguments) > maxToolCallArgumentsBytes || total > maxToolCallArgumentsResponseBytes || !validToolCallArgumentsObject(call.Arguments) || !uniqueJSONKeys([]byte(call.Arguments), 32) || !toolArgumentsMatchSchema(schema, policy.strict[call.Name], []byte(call.Arguments)) {
			return errToolSelectionOutput
		}
		ids[call.ID] = true
	}
	return nil
}

// toolArgumentsMatchSchema validates a strict-subset schema in full, and any
// other admitted schema for its root required properties (mirrors Swift
// ToolSelectionPolicy.validateOutput).
func toolArgumentsMatchSchema(schema json.RawMessage, strict bool, raw json.RawMessage) bool {
	// Every generated number stays in the finite safe domain (SPEC-018 §3.11),
	// whichever validation the schema gets; Swift checks it before both.
	if !toolSchemaNumbersSupported(raw) {
		return false
	}
	if strict {
		return toolArgumentsConform(schema, raw)
	}
	var value map[string]json.RawMessage
	if json.Unmarshal(raw, &value) != nil || value == nil {
		return false
	}
	// Exact-key lookup, as Swift does: struct decoding would also match a
	// differently cased "required" member.
	var node map[string]json.RawMessage
	var required []json.RawMessage
	_ = json.Unmarshal(schema, &node)
	_ = json.Unmarshal(node["required"], &required)
	for _, entry := range required {
		var key string
		if json.Unmarshal(entry, &key) != nil {
			continue
		}
		if _, ok := value[key]; !ok {
			return false
		}
	}
	return true
}

func toolArgumentsConform(schema, raw json.RawMessage) bool {
	var node map[string]json.RawMessage
	if json.Unmarshal(schema, &node) != nil {
		return false
	}
	var typ string
	_ = json.Unmarshal(node["type"], &typ)
	if typ != "object" && typ != "array" && !jsonSchemaScalarConforms(raw, typ) {
		return false
	}
	if typ == "object" && (len(bytes.TrimSpace(raw)) == 0 || bytes.TrimSpace(raw)[0] != '{') {
		return false
	}
	if typ == "array" && (len(bytes.TrimSpace(raw)) == 0 || bytes.TrimSpace(raw)[0] != '[') {
		return false
	}
	decode := func(raw json.RawMessage) any {
		var v any
		d := json.NewDecoder(bytes.NewReader(raw))
		d.UseNumber()
		_ = d.Decode(&v)
		return v
	}
	if constant, ok := node["const"]; ok && !toolSchemaValuesEqual(decode(raw), decode(constant)) {
		return false
	}
	if enum, ok := node["enum"]; ok {
		var values []json.RawMessage
		_ = json.Unmarshal(enum, &values)
		matched := false
		for _, v := range values {
			matched = matched || toolSchemaValuesEqual(decode(raw), decode(v))
		}
		if !matched {
			return false
		}
	}
	switch typ {
	case "object":
		var value map[string]json.RawMessage
		var props map[string]json.RawMessage
		var required []string
		_ = json.Unmarshal(raw, &value)
		_ = json.Unmarshal(node["properties"], &props)
		_ = json.Unmarshal(node["required"], &required)
		for _, key := range required {
			if _, ok := value[key]; !ok {
				return false
			}
		}
		for key, v := range value {
			s, ok := props[key]
			if !ok || !toolArgumentsConform(s, v) {
				return false
			}
		}
	case "array":
		var values []json.RawMessage
		_ = json.Unmarshal(raw, &values)
		for _, v := range values {
			if !toolArgumentsConform(node["items"], v) {
				return false
			}
		}
	case "integer", "number":
		var value float64
		if !boundedToolNumber(string(bytes.TrimSpace(raw))) || json.Unmarshal(raw, &value) != nil {
			return false
		}
		for _, bound := range []string{"minimum", "maximum", "multipleOf"} {
			if b, ok := node[bound]; ok {
				var n float64
				_ = json.Unmarshal(b, &n)
				if bound == "minimum" && value < n || bound == "maximum" && value > n {
					return false
				}
				if bound == "multipleOf" {
					// Swift validates an exact Int64 instance with integer modulo
					// before falling back to its bounded floating-point quotient.
					integer, integerErr := strconv.ParseInt(string(bytes.TrimSpace(raw)), 10, 64)
					if integerErr != nil && value >= -9223372036854775808.0 && value < 9223372036854775808.0 && value == math.Trunc(value) {
						integer = int64(value)
						integerErr = nil
					}
					if integerErr == nil && n >= 1 && n < 9223372036854775808.0 && n == math.Trunc(n) {
						if integer%int64(n) != 0 {
							return false
						}
						continue
					}
					ratio := value / n
					if math.IsInf(ratio, 0) || math.IsNaN(ratio) || math.Abs(ratio) > 1e15 || math.Abs(ratio-math.Round(ratio)) > math.Max(1e-12, math.Abs(ratio)*1e-12) {
						return false
					}
				}
			}
		}
	}
	return true
}

func toolSelectionFailureAttempt() requestLogAttempt {
	return requestLogAttempt{Status: http.StatusBadGateway, Error: errToolSelectionOutput.Error(), ErrorCode: "tool_selection_validation_failed", FaultFlag: billing.FaultBreakerQualifying, SettlementOutput: settlementOutputUnavailableFor(billing.TerminalStateProviderError)}
}

// Guaranteed streams concatenate arguments literally. The ordinary auto path's
// compatibility coalescer can repair legacy fragments and is intentionally not
// used as evidence that a guaranteed call was valid.
func strictToolSelectionCalls(body []byte) ([]bufferedToolCall, error) {
	if !bytes.HasSuffix(body, []byte("\n\n")) && !bytes.HasSuffix(body, []byte("\r\n\r\n")) {
		return nil, errToolSelectionOutput
	}
	byIndex := map[int]*bufferedToolCall{}
	done := false
	finished := false
	for _, line := range bytes.Split(body, []byte("\n")) {
		line = bytes.TrimSpace(line)
		if !bytes.HasPrefix(line, []byte("data:")) {
			continue
		}
		data := bytes.TrimSpace(line[len("data:"):])
		if bytes.Equal(data, []byte("[DONE]")) {
			if done {
				return nil, errToolSelectionOutput
			}
			done = true
			continue
		}
		if !validToolSelectionOutputKeys(data) {
			return nil, errToolSelectionOutput
		}
		var frame struct {
			Error   any `json:"error"`
			Choices []struct {
				Index  int     `json:"index"`
				Finish *string `json:"finish_reason"`
				Delta  struct {
					Calls []struct {
						Index    *int   `json:"index"`
						ID       string `json:"id"`
						Type     string `json:"type"`
						Function struct {
							Name      string `json:"name"`
							Arguments string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if done || json.Unmarshal(data, &frame) != nil || frame.Error != nil || len(frame.Choices) > 1 || (finished && len(frame.Choices) > 0) {
			return nil, errToolSelectionOutput
		}
		for _, choice := range frame.Choices {
			if choice.Index != 0 {
				return nil, errToolSelectionOutput
			}
			if choice.Finish != nil {
				if finished {
					return nil, errToolSelectionOutput
				}
				finished = true
			}
			for _, delta := range choice.Delta.Calls {
				if delta.Index == nil || *delta.Index < 0 || *delta.Index >= maxAssistantToolCalls {
					return nil, errToolSelectionOutput
				}
				call := byIndex[*delta.Index]
				if call == nil {
					call = &bufferedToolCall{Index: *delta.Index}
					byIndex[*delta.Index] = call
				}
				if delta.ID != "" {
					if call.ID != "" && call.ID != delta.ID {
						return nil, errToolSelectionOutput
					}
					call.ID = delta.ID
				}
				if delta.Type != "" {
					if call.Type != "" && call.Type != delta.Type {
						return nil, errToolSelectionOutput
					}
					call.Type = delta.Type
				}
				if delta.Function.Name != "" {
					if call.Name != "" && call.Name != delta.Function.Name {
						return nil, errToolSelectionOutput
					}
					call.Name = delta.Function.Name
				}
				call.Arguments += delta.Function.Arguments
				if len(call.Arguments) > maxToolCallArgumentsBytes {
					return nil, errToolSelectionOutput
				}
			}
		}
	}
	if !done || !finished {
		return nil, errToolSelectionOutput
	}
	calls := make([]bufferedToolCall, 0, len(byIndex))
	for i := 0; i < len(byIndex); i++ {
		call := byIndex[i]
		if call == nil {
			return nil, errToolSelectionOutput
		}
		calls = append(calls, *call)
	}
	return calls, nil
}

func uniqueJSONKeys(raw []byte, maxDepth int) bool { return validJSONKeys(raw, maxDepth, false) }

func validToolSelectionOutputKeys(raw []byte) bool { return validJSONKeys(raw, 64, true) }

func validJSONKeys(raw []byte, maxDepth int, canonicalOutput bool) bool {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var visit func(int) bool
	visit = func(depth int) bool {
		if depth > maxDepth {
			return false
		}
		token, err := decoder.Token()
		if err != nil {
			return false
		}
		delimiter, ok := token.(json.Delim)
		if !ok {
			return true
		}
		if delimiter == '{' {
			seen := map[string]bool{}
			for decoder.More() {
				key, err := decoder.Token()
				if err != nil {
					return false
				}
				name, ok := key.(string)
				if !ok || seen[name] {
					return false
				}
				if canonicalOutput {
					for _, reserved := range []string{"choices", "message", "delta", "tool_calls", "function", "name", "arguments", "id", "type", "finish_reason", "index", "error", "content"} {
						if name != reserved && strings.EqualFold(name, reserved) {
							return false
						}
					}
				}
				seen[name] = true
				if !visit(depth + 1) {
					return false
				}
			}
		} else if delimiter == '[' {
			for decoder.More() {
				if !visit(depth + 1) {
					return false
				}
			}
		} else {
			return false
		}
		_, err = decoder.Token()
		return err == nil
	}
	if !visit(0) {
		return false
	}
	_, err := decoder.Token()
	return err == io.EOF
}

// Numeric schema equality follows JSONValue's exact Int64 equality when both
// operands are integers, otherwise finite Double equality. Bound tokens before
// parsing so an attacker-controlled exponent can never allocate a huge integer.
func toolSchemaValuesEqual(a, b any) bool {
	an, aok := a.(json.Number)
	bn, bok := b.(json.Number)
	if aok && bok {
		left, right := an.String(), bn.String()
		if !boundedToolNumber(left) || !boundedToolNumber(right) {
			return false
		}
		ai, ae := strconv.ParseInt(left, 10, 64)
		bi, be := strconv.ParseInt(right, 10, 64)
		if ae == nil && be == nil {
			return ai == bi
		}
		af, _ := strconv.ParseFloat(left, 64)
		bf, _ := strconv.ParseFloat(right, 64)
		return af == bf
	}
	return reflect.DeepEqual(a, b)
}

// This explicit lexical envelope also rejects extreme negative exponents:
// ParseFloat can underflow them to zero without reporting a range error.
func boundedToolNumber(token string) bool {
	if len(token) == 0 || len(token) > 128 {
		return false
	}
	significand := token
	if at := strings.IndexAny(token, "eE"); at >= 0 {
		exponent, err := strconv.ParseInt(token[at+1:], 10, 32)
		if err != nil || exponent < -324 || exponent > 324 {
			return false
		}
		significand = token[:at]
	}
	value, err := strconv.ParseFloat(token, 64)
	if err != nil || math.IsInf(value, 0) || math.IsNaN(value) || math.Abs(value) > 9007199254740991 {
		return false
	}
	if value == 0 {
		for _, digit := range significand {
			if digit >= '1' && digit <= '9' {
				return false
			}
		}
	}
	return true
}

func toolSchemaNumbersSupported(raw []byte) bool {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			return true
		}
		if err != nil {
			return false
		}
		if number, ok := token.(json.Number); ok && !boundedToolNumber(number.String()) {
			return false
		}
	}
}

func writeToolSelectionError(w http.ResponseWriter) {
	retry := false
	writeProviderStructuredOutputError(w, http.StatusBadGateway, "tool_selection_validation_failed", errToolSelectionOutput.Error(), &retry)
}
