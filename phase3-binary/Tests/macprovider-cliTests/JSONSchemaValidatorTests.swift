import MacProviderCore
import XCTest

final class JSONSchemaValidatorTests: XCTestCase {
    func testValidStrictObjectSchemaIsAccepted() throws {
        XCTAssertNoThrow(try JSONSchemaValidator.validateSchemaShape(schema: Self.personSchema()))
    }

    func testUnsupportedKeywordsAreRejected() throws {
        let keywords = ["oneOf", "anyOf", "allOf", "not", "$ref", "$defs", "pattern", "format", "minItems", "maxItems", "uniqueItems"]
        for keyword in keywords {
            var schema = Self.personSchemaObject()
            schema[keyword] = .array([])
            XCTAssertAPIError(try JSONSchemaValidator.validateSchemaShape(schema: .object(schema)), status: 400, code: "json_schema_unsupported_keyword", keyword)
        }
    }

    func testTopLevelSchemaKeywordAcceptedButNestedRejected() throws {
        var schema = Self.personSchemaObject()
        schema["$schema"] = .string("https://json-schema.org/draft/2020-12/schema")
        XCTAssertNoThrow(try JSONSchemaValidator.validateSchemaShape(schema: .object(schema)))

        var child = Self.personSchemaObject()
        child["properties"] = .object(["age": .object(["type": .string("integer"), "$schema": .string("nested")])])
        child["required"] = .array([.string("age")])
        XCTAssertAPIError(try JSONSchemaValidator.validateSchemaShape(schema: .object(child)), status: 400, code: "json_schema_unsupported_keyword")
    }

    func testNumericBoundsAcceptedAndEnforcedOnNumericTypes() throws {
        let schema: JSONValue = .object([
            "type": .string("integer"),
            "minimum": .int(2),
            "maximum": .int(10),
            "multipleOf": .int(2),
        ])
        XCTAssertNoThrow(try JSONSchemaValidator.validateSchemaShape(schema: schema))
        XCTAssertNoThrow(try JSONSchemaValidator.validateInstance(.int(8), against: schema))
        XCTAssertAPIError(try JSONSchemaValidator.validateInstance(.int(11), against: schema), status: 502, code: "json_schema_validation_failed")
        XCTAssertAPIError(try JSONSchemaValidator.validateInstance(.int(3), against: schema), status: 502, code: "json_schema_validation_failed")
    }

    func testNumericBoundsRejectNonNumericTypesAndInvalidOperands() throws {
        for typ in ["string", "boolean", "null", "array", "object"] {
            var schema: [String: JSONValue] = ["type": .string(typ), "minimum": .int(0)]
            if typ == "array" {
                schema["items"] = .object(["type": .string("string")])
            }
            if typ == "object" {
                schema["properties"] = .object([:])
                schema["required"] = .array([])
                schema["additionalProperties"] = .bool(false)
            }
            XCTAssertAPIError(try JSONSchemaValidator.validateSchemaShape(schema: .object(schema)), status: 400, code: "json_schema_unsupported_keyword", typ)
        }
        XCTAssertAPIError(try JSONSchemaValidator.validateSchemaShape(schema: .object(["type": .string("number"), "multipleOf": .int(0)])), status: 400, code: "json_schema_unsupported_keyword")
        XCTAssertAPIError(try JSONSchemaValidator.validateSchemaShape(schema: .object(["type": .string("number"), "maximum": .string("10")])), status: 400, code: "json_schema_unsupported_keyword")
        XCTAssertAPIError(try JSONSchemaValidator.validateSchemaShape(schema: .object(["type": .string("number"), "minimum": .int(5), "maximum": .int(4)])), status: 400, code: "json_schema_unsupported_keyword")
    }

    func testStrictObjectRequiresAdditionalPropertiesFalseAtEachObject() throws {
        var nested: [String: JSONValue] = [
            "type": .object([
                "type": .string("object"),
                "properties": .object(["child": .object(Self.personSchemaObject())]),
                "required": .array([.string("child")]),
                "additionalProperties": .bool(false),
            ])
        ]
        var child = Self.personSchemaObject()
        child.removeValue(forKey: "additionalProperties")
        nested["type"] = .object([
            "type": .string("object"),
            "properties": .object(["child": .object(child)]),
            "required": .array([.string("child")]),
            "additionalProperties": .bool(false),
        ])
        XCTAssertAPIError(try JSONSchemaValidator.validateSchemaShape(schema: nested["type"]!), status: 400, code: "json_schema_strict_requires_additional_properties_false")
    }

    func testStrictObjectRequiresEveryPropertyRequired() throws {
        var schema = Self.personSchemaObject()
        schema["required"] = .array([.string("name")])
        XCTAssertAPIError(try JSONSchemaValidator.validateSchemaShape(schema: .object(schema)), status: 400, code: "json_schema_strict_requires_all_properties_required")
    }

    func testConstAndEnumMustMatchType() throws {
        XCTAssertAPIError(
            try JSONSchemaValidator.validateSchemaShape(schema: .object([
                "type": .string("string"),
                "const": .int(42),
            ])),
            status: 400,
            code: "json_schema_invalid_const_or_enum_type"
        )
        XCTAssertAPIError(
            try JSONSchemaValidator.validateSchemaShape(schema: .object([
                "type": .string("integer"),
                "enum": .array([.int(1), .double(2.5)]),
            ])),
            status: 400,
            code: "json_schema_invalid_const_or_enum_type"
        )
    }

    func testIntegerSchemaRejectsDoubleDriftForConstAndEnum() throws {
        let constSchema: JSONValue = .object([
            "type": .string("integer"),
            "const": .int(1),
        ])
        XCTAssertAPIError(try JSONSchemaValidator.validateInstance(.double(1.0), against: constSchema), status: 502, code: "json_schema_validation_failed")

        let enumSchema: JSONValue = .object([
            "type": .string("integer"),
            "enum": .array([.int(1)]),
        ])
        XCTAssertAPIError(try JSONSchemaValidator.validateInstance(.double(1.0), against: enumSchema), status: 502, code: "json_schema_validation_failed")
    }

    func testSchemaDepthBoundary() throws {
        XCTAssertNoThrow(try JSONSchemaValidator.validateSchemaShape(schema: Self.nestedArraySchema(depth: 32)))
        XCTAssertAPIError(try JSONSchemaValidator.validateSchemaShape(schema: Self.nestedArraySchema(depth: 33)), status: 400, code: "json_schema_too_deep")
    }

    func testNFCAndNFDPropertyNamesRemainDistinctAtValidation() throws {
        let nfc = String(decoding: [0x63, 0x61, 0x66, 0xc3, 0xa9], as: UTF8.self)
        let nfd = String(decoding: [0x63, 0x61, 0x66, 0x65, 0xcc, 0x81], as: UTF8.self)
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([nfc: .object(["type": .string("string")])]),
            "required": .array([.string(nfc)]),
            "additionalProperties": .bool(false),
        ])
        let output: JSONValue = .object([nfd: .string("x")])

        XCTAssertAPIError(try JSONSchemaValidator.validateInstance(output, against: schema), status: 502, code: "json_schema_validation_failed")
    }

    func testDuplicateKeysAreRejectedByStrictParser() throws {
        XCTAssertThrowsError(try StrictJSONParser.parse(#"{"a":1,"a":2}"#))
    }

    private static func personSchema() -> JSONValue {
        .object(personSchemaObject())
    }

    private static func personSchemaObject() -> [String: JSONValue] {
        [
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string")]),
                "age": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("name"), .string("age")]),
            "additionalProperties": .bool(false),
        ]
    }

    private static func nestedArraySchema(depth: Int) -> JSONValue {
        if depth == 1 {
            return .object(["type": .string("string")])
        }
        return .object([
            "type": .string("array"),
            "items": nestedArraySchema(depth: depth - 1),
        ])
    }

    private func XCTAssertAPIError(
        _ expression: @autoclosure () throws -> Void,
        status: Int,
        code: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, status, file: file, line: line)
            XCTAssertEqual(apiError?.code, code, file: file, line: line)
        }
    }
}
