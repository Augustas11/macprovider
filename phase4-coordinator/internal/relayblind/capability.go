package relayblind

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
)

// CapabilityJSONSchemaNonStrict is the one SPEC-041-R003 capability name: the
// inner request's response_format runs in SPEC-019 §1a non-strict mode.
const CapabilityJSONSchemaNonStrict = "json_schema_non_strict"

const requiresField = "requires"

// Mirrors of the coordinator's SPEC-019 §3 strict-subset limits.
const strictSchemaMaxDepth = 32

// ValidRequires reports a valid requires member: nil (absent), or a nonempty,
// sorted, duplicate-free list of known capability names.
func ValidRequires(values []string) bool {
	if values == nil {
		return true
	}
	if len(values) == 0 || !sort.StringsAreSorted(values) {
		return false
	}
	for i, value := range values {
		if value != CapabilityJSONSchemaNonStrict || (i > 0 && value == values[i-1]) {
			return false
		}
	}
	return true
}

// RequiresNonStrictJSONSchema reports whether a requires member declares
// SPEC-019 §1a non-strict json_schema mode.
func RequiresNonStrictJSONSchema(requires []string) bool {
	return contains(requires, CapabilityJSONSchemaNonStrict)
}

// RequiredCapabilities derives the SPEC-041-R003 requires member from an
// inner chat request body. It returns nil unless response_format runs in
// SPEC-019 §1a non-strict mode: json_schema with strict false, or with strict
// absent or null and a schema outside the §3 strict subset. A malformed
// response_format declares nothing; the provider rejects that body itself.
func RequiredCapabilities(body []byte) []string {
	var request struct {
		ResponseFormat json.RawMessage `json:"response_format"`
	}
	if json.Unmarshal(body, &request) != nil || len(request.ResponseFormat) == 0 {
		return nil
	}
	var format struct {
		Type       string                     `json:"type"`
		JSONSchema map[string]json.RawMessage `json:"json_schema"`
	}
	if json.Unmarshal(request.ResponseFormat, &format) != nil || format.Type != "json_schema" || format.JSONSchema == nil {
		return nil
	}
	if rawStrict, ok := format.JSONSchema["strict"]; ok && !isJSONNull(rawStrict) {
		var strict bool
		if json.Unmarshal(rawStrict, &strict) != nil || strict {
			return nil
		}
		return []string{CapabilityJSONSchemaNonStrict}
	}
	schema, ok := format.JSONSchema["schema"]
	if !ok || len(bytes.TrimSpace(schema)) == 0 || isJSONNull(schema) {
		return nil
	}
	if strictSubsetSchema(schema, true, 1) {
		return nil
	}
	return []string{CapabilityJSONSchemaNonStrict}
}

func isJSONNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

// strictSubsetSchema reports whether a schema fits the SPEC-019 §3 strict
// subset. It mirrors the coordinator's validateJSONSchemaRaw as a predicate,
// a coordinator test keeps the two in agreement, and it is never more
// permissive than the provider: where the two differ it reports false, so
// the client declares rather than omits.
func strictSubsetSchema(raw json.RawMessage, root bool, depth int) bool {
	if depth > strictSchemaMaxDepth {
		return false
	}
	var node map[string]json.RawMessage
	if json.Unmarshal(raw, &node) != nil || node == nil {
		return false
	}
	allowed := map[string]bool{"type": true, "properties": true, "required": true, "items": true, "enum": true, "const": true, "additionalProperties": true, "title": true, "description": true, "minimum": true, "maximum": true, "multipleOf": true}
	for key, value := range node {
		if !allowed[key] && !(root && key == "$schema") {
			return false
		}
		// The provider (Swift) rejects an explicit null structural keyword
		// in strict mode and so runs the schema non-strict, while the
		// coordinator's parser reads it as absent. Declaring here keeps the
		// client a superset of both; over-declaring only narrows routing.
		if key != "const" && isJSONNull(value) {
			return false
		}
	}
	var typ string
	if rawType, ok := node["type"]; !ok || json.Unmarshal(rawType, &typ) != nil || !strictSchemaType(typ) {
		return false
	}
	if rawConst, ok := node["const"]; ok && !strictScalarConforms(rawConst, typ) {
		return false
	}
	if rawEnum, ok := node["enum"]; ok {
		var values []json.RawMessage
		if json.Unmarshal(rawEnum, &values) != nil {
			return false
		}
		for _, value := range values {
			if !strictScalarConforms(value, typ) {
				return false
			}
		}
	}
	if !strictNumericBounds(node, typ) {
		return false
	}
	switch typ {
	case "object":
		var addl bool
		if rawAddl, ok := node["additionalProperties"]; !ok || json.Unmarshal(rawAddl, &addl) != nil || addl {
			return false
		}
		if _, ok := node["items"]; ok {
			return false
		}
		properties := map[string]json.RawMessage{}
		if rawProps, ok := node["properties"]; ok && json.Unmarshal(rawProps, &properties) != nil {
			return false
		}
		required := map[string]bool{}
		if rawRequired, ok := node["required"]; ok {
			var names []string
			if json.Unmarshal(rawRequired, &names) != nil {
				return false
			}
			for _, name := range names {
				if _, ok := properties[name]; !ok || required[name] {
					return false
				}
				required[name] = true
			}
		}
		for name, child := range properties {
			if !required[name] || !strictSubsetSchema(child, false, depth+1) {
				return false
			}
		}
	case "array":
		child, ok := node["items"]
		if !ok {
			return false
		}
		for _, keyword := range []string{"properties", "required", "additionalProperties"} {
			if _, ok := node[keyword]; ok {
				return false
			}
		}
		return strictSubsetSchema(child, false, depth+1)
	default:
		for _, keyword := range []string{"properties", "required", "items", "additionalProperties"} {
			if _, ok := node[keyword]; ok {
				return false
			}
		}
	}
	return true
}

func strictSchemaType(typ string) bool {
	switch typ {
	case "object", "array", "string", "number", "integer", "boolean", "null":
		return true
	}
	return false
}

func strictScalarConforms(raw json.RawMessage, typ string) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] == '{' || trimmed[0] == '[' {
		return false
	}
	var value any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if dec.Decode(&value) != nil {
		return false
	}
	switch typ {
	case "string":
		_, ok := value.(string)
		return ok
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "null":
		return value == nil
	case "number":
		_, ok := value.(json.Number)
		return ok
	case "integer":
		n, ok := value.(json.Number)
		if !ok {
			return false
		}
		_, err := strconv.ParseInt(n.String(), 10, 64)
		return err == nil && !strings.ContainsAny(n.String(), ".eE")
	}
	return false
}

func strictNumericBounds(node map[string]json.RawMessage, typ string) bool {
	present := false
	for _, keyword := range []string{"minimum", "maximum", "multipleOf"} {
		if _, ok := node[keyword]; ok {
			present = true
		}
	}
	if !present {
		return true
	}
	if typ != "number" && typ != "integer" {
		return false
	}
	minimum, hasMinimum, ok := strictNumberOperand(node, "minimum")
	if !ok {
		return false
	}
	maximum, hasMaximum, ok := strictNumberOperand(node, "maximum")
	if !ok {
		return false
	}
	multipleOf, hasMultipleOf, ok := strictNumberOperand(node, "multipleOf")
	if !ok {
		return false
	}
	const leastNormalFloat64 = 2.2250738585072014e-308
	const minimumSupportedMultipleOf = 1e-300
	if hasMultipleOf && (multipleOf <= 0 || math.IsInf(multipleOf, 0) || math.IsNaN(multipleOf) || multipleOf <= minimumSupportedMultipleOf || multipleOf < leastNormalFloat64) {
		return false
	}
	return !(hasMinimum && hasMaximum && minimum > maximum)
}

// strictNumberOperand returns the operand, whether it is present, and whether
// it is a finite JSON number when present.
func strictNumberOperand(node map[string]json.RawMessage, keyword string) (float64, bool, bool) {
	raw, ok := node[keyword]
	if !ok {
		return 0, false, true
	}
	var value any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if dec.Decode(&value) != nil {
		return 0, true, false
	}
	var extra json.RawMessage
	if dec.Decode(&extra) != io.EOF {
		return 0, true, false
	}
	number, ok := value.(json.Number)
	if !ok {
		return 0, true, false
	}
	parsed, err := number.Float64()
	if err != nil || math.IsInf(parsed, 0) || math.IsNaN(parsed) {
		return 0, true, false
	}
	return parsed, true, true
}
