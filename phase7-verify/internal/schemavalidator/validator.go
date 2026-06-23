// Package schemavalidator implements the narrow Draft-07 subset used by the
// macprovider-verify JSON output schema tests.
package schemavalidator

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
)

// Validate validates doc against schema.
//
// This intentionally supports only the Draft-07 keywords used by
// schemas/output.schema.json. It is not a general JSON Schema implementation.
func Validate(schema []byte, doc []byte) error {
	var schemaRoot any
	if err := json.Unmarshal(schema, &schemaRoot); err != nil {
		return fmt.Errorf("decode schema: %w", err)
	}

	var instance any
	decoder := json.NewDecoder(bytes.NewReader(doc))
	decoder.UseNumber()
	if err := decoder.Decode(&instance); err != nil {
		return fmt.Errorf("decode document: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != nil {
		if !errors.Is(err, io.EOF) {
			return fmt.Errorf("decode trailing document data: %w", err)
		}
	} else {
		return errors.New("document contains trailing JSON value")
	}
	return validateSchema(schemaRoot, instance, "$")
}

func validateSchema(schema any, instance any, path string) error {
	switch typedSchema := schema.(type) {
	case bool:
		if typedSchema {
			return nil
		}
		return fmt.Errorf("%s rejected by false schema", path)
	case map[string]any:
		return validateSchemaObject(typedSchema, instance, path)
	default:
		return fmt.Errorf("%s invalid schema node %T", path, schema)
	}
}

func validateSchemaObject(schema map[string]any, instance any, path string) error {
	if variants, ok := schema["oneOf"].([]any); ok {
		matches := 0
		var lastErr error
		for _, variant := range variants {
			if err := validateSchema(variant, instance, path); err == nil {
				matches++
			} else {
				lastErr = err
			}
		}
		if matches != 1 {
			if lastErr == nil {
				lastErr = errors.New("no branch detail")
			}
			return fmt.Errorf("%s matched %d oneOf branches: %w", path, matches, lastErr)
		}
	}
	if allVariants, ok := schema["allOf"].([]any); ok {
		for _, variant := range allVariants {
			if err := validateSchema(variant, instance, path); err != nil {
				return err
			}
		}
	}
	if notSchema, ok := schema["not"]; ok {
		if err := validateSchema(notSchema, instance, path); err == nil {
			return fmt.Errorf("%s matched forbidden not schema", path)
		}
	}
	if typeSpec, ok := schema["type"]; ok && !schemaTypeMatches(typeSpec, instance) {
		return fmt.Errorf("%s has type %T, does not match %v", path, instance, typeSpec)
	}
	if constValue, ok := schema["const"]; ok && !jsonScalarEqual(instance, constValue) {
		return fmt.Errorf("%s=%v does not equal const %v", path, instance, constValue)
	}
	if enumValues, ok := schema["enum"].([]any); ok {
		matched := false
		for _, enumValue := range enumValues {
			if jsonScalarEqual(instance, enumValue) {
				matched = true
				break
			}
		}
		if !matched {
			return fmt.Errorf("%s=%v not in enum %v", path, instance, enumValues)
		}
	}
	object, isObject := instance.(map[string]any)
	if required, ok := schema["required"].([]any); ok {
		if !isObject {
			return fmt.Errorf("%s required applied to non-object", path)
		}
		for _, field := range required {
			name, _ := field.(string)
			if _, ok := object[name]; !ok {
				return fmt.Errorf("%s missing required field %q", path, name)
			}
		}
	}
	properties, hasProperties := schema["properties"].(map[string]any)
	if hasProperties && isObject {
		for key, value := range object {
			if propertySchema, ok := properties[key]; ok {
				if err := validateSchema(propertySchema, value, path+"."+key); err != nil {
					return err
				}
			}
		}
		if additional, ok := schema["additionalProperties"].(bool); ok && !additional {
			for key := range object {
				if _, ok := properties[key]; !ok {
					return fmt.Errorf("%s has additional property %q", path, key)
				}
			}
		}
	}
	if itemSchema, ok := schema["items"]; ok {
		items, ok := instance.([]any)
		if !ok {
			return fmt.Errorf("%s items applied to non-array", path)
		}
		for i, item := range items {
			if err := validateSchema(itemSchema, item, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
	}
	if ifSchema, ok := schema["if"]; ok {
		ifErr := validateSchema(ifSchema, instance, path)
		if ifErr == nil {
			if thenSchema, ok := schema["then"]; ok {
				if err := validateSchema(thenSchema, instance, path); err != nil {
					return err
				}
			}
		} else if elseSchema, ok := schema["else"]; ok {
			if err := validateSchema(elseSchema, instance, path); err != nil {
				return err
			}
		}
	}
	return nil
}

func schemaTypeMatches(typeSpec any, value any) bool {
	switch typed := typeSpec.(type) {
	case string:
		return singleSchemaTypeMatches(typed, value)
	case []any:
		for _, candidate := range typed {
			if name, ok := candidate.(string); ok && singleSchemaTypeMatches(name, value) {
				return true
			}
		}
		return false
	default:
		return false
	}
}

func singleSchemaTypeMatches(name string, value any) bool {
	switch name {
	case "null":
		return value == nil
	case "string":
		_, ok := value.(string)
		return ok
	case "integer":
		switch n := value.(type) {
		case json.Number:
			_, err := n.Int64()
			return err == nil
		case float64:
			return n == float64(int64(n))
		default:
			return false
		}
	case "object":
		_, ok := value.(map[string]any)
		return ok
	case "array":
		_, ok := value.([]any)
		return ok
	default:
		return false
	}
}

func jsonScalarEqual(a any, b any) bool {
	if reflect.DeepEqual(a, b) {
		return true
	}
	an, aok := a.(json.Number)
	bn, bok := b.(json.Number)
	if aok && bok {
		return an.String() == bn.String()
	}
	return false
}
