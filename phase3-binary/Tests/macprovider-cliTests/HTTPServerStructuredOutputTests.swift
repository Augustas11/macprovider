import MacProviderCore
import XCTest
@testable import macprovider_cli

final class HTTPServerStructuredOutputTests: XCTestCase {
    func testStreamingStructuredOutputAcceptedByRequestParser() throws {
        XCTAssertNoThrow(try Self.request(responseFormat: ["type": "json_object"], stream: true))
        XCTAssertNoThrow(try Self.request(responseFormat: Self.jsonSchemaResponseFormat(), stream: true))
    }

    func testContentEncodingGate() throws {
        XCTAssertNoThrow(try RouterHandler.validateContentEncoding([]))
        XCTAssertNoThrow(try RouterHandler.validateContentEncoding(["identity"]))
        XCTAssertNoThrow(try RouterHandler.validateContentEncoding([" Identity "]))
        XCTAssertNoThrow(try RouterHandler.validateContentEncoding(["\tidentity "]))
        XCTAssertNoThrow(try RouterHandler.validateContentEncoding(["IDENTITY"]))

        for rejected in [["gzip"], ["deflate"], ["br"], ["identity, gzip"], ["   "], ["\u{00a0}identity"]] {
            XCTAssertAPIError(try RouterHandler.validateContentEncoding(rejected), status: 415, code: "request_content_encoding_unsupported", param: "Content-Encoding")
        }
    }

    func testPromptHashChangesWhenSchemaBytesChange() throws {
        let base = try Self.request(responseFormat: Self.jsonSchemaResponseFormat())
        var changedFormat = Self.jsonSchemaResponseFormat()
        var jsonSchema = changedFormat["json_schema"] as! [String: Any]
        var schema = jsonSchema["schema"] as! [String: Any]
        var properties = schema["properties"] as! [String: Any]
        properties["age"] = ["type": "integer"]
        schema["properties"] = properties
        jsonSchema["schema"] = schema
        changedFormat["json_schema"] = jsonSchema
        let changed = try Self.request(responseFormat: changedFormat)

        XCTAssertNotEqual(try PromptCanonicalizer.promptHash(for: base), try PromptCanonicalizer.promptHash(for: changed))
    }

    private static func request(responseFormat: [String: Any], stream: Bool = false) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": "fixture-model",
            "messages": [["role": "user", "content": "Return a person"]],
            "response_format": responseFormat,
        ]
        if stream {
            body["stream"] = true
        }
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
    }

    private static func jsonSchemaResponseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "person-v1",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "age": ["type": "number"],
                    ],
                    "required": ["name", "age"],
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    private func XCTAssertAPIError(
        _ expression: @autoclosure () throws -> Void,
        status: Int,
        code: String,
        param: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, status, file: file, line: line)
            XCTAssertEqual(apiError?.code, code, file: file, line: line)
            XCTAssertEqual(apiError?.param, param, file: file, line: line)
        }
    }
}
