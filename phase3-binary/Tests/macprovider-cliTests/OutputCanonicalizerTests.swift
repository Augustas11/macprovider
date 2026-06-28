import XCTest
@testable import macprovider_cli

final class OutputCanonicalizerTests: XCTestCase {
    func testKnownGoodOutputVectorUsesThreeCommittedKeys() throws {
        let toolCalls = [
            ToolCall(id: "call_0123456789abcdef", functionName: "lookup", arguments: #"{"b":2, "a":1}"#),
        ]

        let canonical = try RFC8785JCS.canonicalString(OutputCanonicalizer.canonicalOutputObject(
            content: "Line 1\r\nCafe\u{0301}\rLine 3",
            toolCalls: toolCalls,
            finishReason: "tool_calls"
        ))
        let hash = try OutputCanonicalizer.outputHash(
            content: "Line 1\r\nCafe\u{0301}\rLine 3",
            toolCalls: toolCalls,
            finishReason: "tool_calls"
        )

        XCTAssertTrue(canonical.hasPrefix(#"{"content":"#))
        XCTAssertTrue(canonical.contains(#""finish_reason":"tool_calls""#))
        XCTAssertTrue(canonical.contains(#""tool_calls":["#))
        XCTAssertEqual(hash, "5aa0f9c2133f088db86f48543d9e61aaa554f730c5095231be2e0d428d2254b9")
    }

    func testToolCallArgumentsAreCommittedByteForByteAsAString() throws {
        let compact = try OutputCanonicalizer.outputHash(
            content: "",
            toolCalls: [ToolCall(id: "call_0123456789abcdef", functionName: "lookup", arguments: #"{"b":2,"a":1}"#)],
            finishReason: "tool_calls"
        )
        let spaced = try OutputCanonicalizer.outputHash(
            content: "",
            toolCalls: [ToolCall(id: "call_0123456789abcdef", functionName: "lookup", arguments: #"{"b":2, "a":1}"#)],
            finishReason: "tool_calls"
        )

        XCTAssertNotEqual(compact, spaced)
    }

    func testToolCallArgumentsDoNotNormalizeUnicode() throws {
        let decomposed = try OutputCanonicalizer.outputHash(
            content: "",
            toolCalls: [ToolCall(id: "call_0123456789abcdef", functionName: "lookup", arguments: "{\"q\":\"Cafe\u{0301}\"}")],
            finishReason: "tool_calls"
        )
        let precomposed = try OutputCanonicalizer.outputHash(
            content: "",
            toolCalls: [ToolCall(id: "call_0123456789abcdef", functionName: "lookup", arguments: "{\"q\":\"Caf\u{00e9}\"}")],
            finishReason: "tool_calls"
        )

        XCTAssertNotEqual(decomposed, precomposed)
    }

    func testNullUsageErrorReceiptOutputHashFixture() throws {
        XCTAssertEqual(
            try OutputCanonicalizer.outputHash(content: "", toolCalls: nil, finishReason: "error"),
            "1bc371f568ecc23722dd522a5d00854589c78fcc9a2bebdb3523c5d8b9010b76"
        )
    }

    func testInvalidFinishReasonIsRejected() {
        XCTAssertThrowsError(try OutputCanonicalizer.outputHash(
            content: "",
            toolCalls: nil,
            finishReason: "unknown"
        )) { error in
            XCTAssertEqual(error as? OutputCanonicalizer.Error, .invalidFinishReason("unknown"))
        }
    }
}
