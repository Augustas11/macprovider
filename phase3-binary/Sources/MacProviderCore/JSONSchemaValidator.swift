import Foundation

public enum JSONSchemaValidator {
    public static let maxSchemaBytes = 16_384
    public static let maxDepth = 32

    private static let allowedKeywords: Set<String> = [
        "type",
        "properties",
        "required",
        "items",
        "enum",
        "const",
        "additionalProperties",
        "title",
        "description",
    ]

    public static func validateSchemaShape(schema: JSONValue) throws {
        try validateSchemaNode(schema, pointer: "", depth: 1)
    }

    public static func validateInstance(_ instance: JSONValue, against schema: JSONValue) throws {
        guard jsonDepth(instance) <= maxDepth else {
            throw validationError("Structured output JSON exceeds maximum depth", pointer: "")
        }
        try validateInstanceNode(instance, schema: schema, pointer: "")
    }

    public static func validateJSONObjectOrArray(_ instance: JSONValue) throws {
        guard jsonDepth(instance) <= maxDepth else {
            throw APIError(
                status: 502,
                message: "Structured output JSON exceeds maximum depth",
                type: "upstream_provider_error",
                code: "json_schema_validation_failed",
                param: "",
                inferenceRan: true,
                settlementRan: true
            )
        }
        switch instance {
        case .object, .array:
            return
        default:
            throw APIError(
                status: 502,
                message: "response_format json_object requires a top-level object or array",
                type: "upstream_provider_error",
                code: "malformed_json_response",
                param: "",
                inferenceRan: true,
                settlementRan: true
            )
        }
    }

    private static func validateSchemaNode(_ schema: JSONValue, pointer: String, depth: Int) throws {
        guard depth <= maxDepth else {
            throw APIError(status: 400, message: "response_format.json_schema.schema exceeds maximum depth", code: "json_schema_too_deep", param: pointer)
        }
        guard case .object(let object) = schema else {
            throw APIError(status: 400, message: "Schema node must be an object", code: "json_schema_unsupported_keyword", param: pointer)
        }
        for key in object.keys where !allowedKeywords.contains(key) {
            throw APIError(status: 400, message: "Unsupported JSON Schema keyword '\(key)' at \(pointerOrRoot(pointer))", code: "json_schema_unsupported_keyword", param: append(pointer, key))
        }
        guard case .string(let type)? = object["type"],
              ["object", "array", "string", "number", "integer", "boolean", "null"].contains(type)
        else {
            throw APIError(status: 400, message: "Schema node must declare an allowed type", code: "json_schema_unsupported_keyword", param: append(pointer, "type"))
        }

        try validateConstAndEnum(in: object, type: type, pointer: pointer)

        switch type {
        case "object":
            guard case .bool(false)? = object["additionalProperties"] else {
                throw APIError(
                    status: 400,
                    message: "Strict object schemas require additionalProperties:false",
                    code: "json_schema_strict_requires_additional_properties_false",
                    param: pointer
                )
            }
            guard object["items"] == nil else {
                throw unsupportedKeyword("items", pointer: pointer)
            }
            let properties: [String: JSONValue]
            if let rawProperties = object["properties"] {
                guard case .object(let parsed) = rawProperties else {
                    throw unsupportedKeyword("properties", pointer: pointer)
                }
                properties = parsed
            } else {
                properties = [:]
            }
            var requiredBytes: Set<[UInt8]> = []
            if let rawRequired = object["required"] {
                guard case .array(let requiredValues) = rawRequired else {
                    throw unsupportedKeyword("required", pointer: pointer)
                }
                for value in requiredValues {
                    guard case .string(let name) = value,
                          rawKey(in: properties, matching: name) != nil,
                          requiredBytes.insert(Array(name.utf8)).inserted else {
                        throw APIError(
                            status: 400,
                            message: "Strict object required entries must uniquely name properties",
                            code: "json_schema_strict_requires_all_properties_required",
                            param: pointer
                        )
                    }
                }
            }
            guard properties.keys.allSatisfy({ requiredBytes.contains(Array($0.utf8)) }) else {
                throw APIError(
                    status: 400,
                    message: "Strict object schemas require every property to be listed in required",
                    code: "json_schema_strict_requires_all_properties_required",
                    param: pointer
                )
            }
            for (name, child) in properties {
                try validateSchemaNode(child, pointer: append(append(pointer, "properties"), name), depth: depth + 1)
            }
        case "array":
            guard case .object? = object["items"] else {
                throw APIError(status: 400, message: "Array schemas require items schema", code: "json_schema_unsupported_keyword", param: append(pointer, "items"))
            }
            guard object["properties"] == nil, object["required"] == nil, object["additionalProperties"] == nil else {
                throw APIError(status: 400, message: "Object-only schema keyword used on array schema", code: "json_schema_unsupported_keyword", param: pointer)
            }
            try validateSchemaNode(object["items"]!, pointer: append(pointer, "items"), depth: depth + 1)
        default:
            for keyword in ["properties", "required", "items", "additionalProperties"] where object[keyword] != nil {
                throw unsupportedKeyword(keyword, pointer: pointer)
            }
        }
    }

    private static func validateConstAndEnum(in object: [String: JSONValue], type: String, pointer: String) throws {
        if let const = object["const"], !isScalar(const) || !value(const, conformsTo: type) {
            throw APIError(status: 400, message: "const value does not conform to schema type", code: "json_schema_invalid_const_or_enum_type", param: append(pointer, "const"))
        }
        if let rawEnum = object["enum"] {
            guard case .array(let values) = rawEnum else {
                throw APIError(status: 400, message: "enum must be an array", code: "json_schema_invalid_const_or_enum_type", param: append(pointer, "enum"))
            }
            for (index, enumValue) in values.enumerated() where !isScalar(enumValue) || !value(enumValue, conformsTo: type) {
                throw APIError(status: 400, message: "enum value does not conform to schema type", code: "json_schema_invalid_const_or_enum_type", param: append(append(pointer, "enum"), String(index)))
            }
        }
    }

    private static func validateInstanceNode(_ instance: JSONValue, schema: JSONValue, pointer: String) throws {
        guard case .object(let schemaObject) = schema,
              case .string(let type)? = schemaObject["type"]
        else {
            throw validationError("Schema validation aborted before completion", pointer: "")
        }
        guard value(instance, conformsTo: type) else {
            throw validationError("Structured output type mismatch at \(pointerOrRoot(pointer))", pointer: pointer)
        }
        if let const = schemaObject["const"], !jsonValueEqualsRaw(instance, const) {
            throw validationError("Structured output const mismatch at \(pointerOrRoot(pointer))", pointer: pointer)
        }
        if let rawEnum = schemaObject["enum"], case .array(let allowed) = rawEnum, !allowed.contains(where: { jsonValueEqualsRaw(instance, $0) }) {
            throw validationError("Structured output enum mismatch at \(pointerOrRoot(pointer))", pointer: pointer)
        }

        switch (type, instance) {
        case ("object", .object(let object)):
            let properties: [String: JSONValue]
            if case .object(let parsed)? = schemaObject["properties"] {
                properties = parsed
            } else {
                properties = [:]
            }
            if case .array(let requiredValues)? = schemaObject["required"] {
                for required in requiredValues {
                    guard case .string(let key) = required, rawKey(in: object, matching: key) != nil else {
                        let key = (try? required.diagnosticString()) ?? ""
                        throw validationError("Structured output missing required property \(key)", pointer: pointer)
                    }
                }
            }
            for key in object.keys where rawKey(in: properties, matching: key) == nil {
                throw validationError("Structured output contains unsupported property \(escapeForMessage(key))", pointer: append(pointer, key))
            }
            for (key, childSchema) in properties {
                if let objectKey = rawKey(in: object, matching: key), let child = object[objectKey] {
                    try validateInstanceNode(child, schema: childSchema, pointer: append(pointer, key))
                }
            }
        case ("array", .array(let array)):
            guard let items = schemaObject["items"] else { return }
            for (index, item) in array.enumerated() {
                try validateInstanceNode(item, schema: items, pointer: append(pointer, String(index)))
            }
        default:
            return
        }
    }

    private static func jsonDepth(_ value: JSONValue) -> Int {
        switch value {
        case .object(let object):
            return 1 + (object.values.map(jsonDepth).max() ?? 0)
        case .array(let array):
            return 1 + (array.map(jsonDepth).max() ?? 0)
        default:
            return 1
        }
    }

    private static func value(_ value: JSONValue, conformsTo type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("integer", .int), ("boolean", .bool), ("null", .null):
            return true
        case ("number", .int), ("number", .double):
            return true
        default:
            return false
        }
    }

    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .object, .array:
            return false
        case .string, .int, .double, .bool, .null:
            return true
        }
    }

    private static func rawKey(in object: [String: JSONValue], matching wanted: String) -> String? {
        let wantedBytes = Array(wanted.utf8)
        return object.keys.first { Array($0.utf8) == wantedBytes }
    }

    private static func jsonValueEqualsRaw(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let left), .string(let right)):
            return Array(left.utf8) == Array(right.utf8)
        case (.int(let left), .int(let right)):
            return left == right
        case (.double(let left), .double(let right)):
            return left == right
        case (.int(let left), .double(let right)):
            return Double(left) == right
        case (.double(let left), .int(let right)):
            return left == Double(right)
        case (.bool(let left), .bool(let right)):
            return left == right
        case (.null, .null):
            return true
        case (.array(let left), .array(let right)):
            return left.count == right.count && zip(left, right).allSatisfy { jsonValueEqualsRaw($0, $1) }
        case (.object(let left), .object(let right)):
            guard left.count == right.count else { return false }
            return left.allSatisfy { key, leftValue in
                guard let rightKey = rawKey(in: right, matching: key), let rightValue = right[rightKey] else {
                    return false
                }
                return jsonValueEqualsRaw(leftValue, rightValue)
            }
        default:
            return false
        }
    }

    private static func unsupportedKeyword(_ keyword: String, pointer: String) -> APIError {
        APIError(status: 400, message: "Unsupported JSON Schema keyword '\(keyword)' at \(pointerOrRoot(pointer))", code: "json_schema_unsupported_keyword", param: append(pointer, keyword))
    }

    private static func validationError(_ message: String, pointer: String) -> APIError {
        APIError(
            status: 502,
            message: message,
            type: "upstream_provider_error",
            code: "json_schema_validation_failed",
            param: pointer,
            inferenceRan: true,
            settlementRan: true
        )
    }

    private static func pointerOrRoot(_ pointer: String) -> String {
        pointer.isEmpty ? "/" : pointer
    }

    private static func append(_ pointer: String, _ token: String) -> String {
        let escaped = token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        return pointer + "/" + escaped
    }

    private static func escapeForMessage(_ string: String) -> String {
        (try? JSONValue.string(string).deterministicJSONString()) ?? string
    }
}

private extension JSONValue {
    func diagnosticString() throws -> String {
        try deterministicJSONString()
    }
}
