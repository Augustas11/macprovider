import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class PromptCanonicalizerTests: XCTestCase {
    func testKnownGoodPromptVectorUsesSixteenCommittedKeys() throws {
        let request = try Self.fixtureRequest()

        let canonical = try RFC8785JCS.canonicalString(PromptCanonicalizer.canonicalPromptObject(for: request))
        let hash = try PromptCanonicalizer.promptHash(for: request)

        XCTAssertTrue(canonical.hasPrefix(#"{"frequency_penalty":"#))
        XCTAssertTrue(canonical.contains(#""logprobs":true"#))
        XCTAssertTrue(canonical.contains(#""messages":["#))
        XCTAssertTrue(canonical.contains(#""top_logprobs":2"#))
        XCTAssertEqual(hash, "a762aef8cf64fd65f05096e7f98010804a1c4e8fb07f0a1ea7616f1cde2663cd")
    }

    func testAbsentCommittedFieldsCanonicalizeAsNull() throws {
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])

        let canonical = try RFC8785JCS.canonicalString(PromptCanonicalizer.canonicalPromptObject(for: request))

        XCTAssertTrue(canonical.contains(#""tools":null"#))
        XCTAssertTrue(canonical.contains(#""temperature":null"#))
        XCTAssertTrue(canonical.contains(#""logit_bias":null"#))
        XCTAssertEqual(
            try PromptCanonicalizer.promptHash(for: request),
            "f3847a19a490e8d60bcab1109efb66cb8b2c2ef9c38c3a7397705d585dd2b65a"
        )
    }

    func testMessageContentNormalizesCRLFAndNFCBeforeHashing() throws {
        let decomposed = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "Cafe\u{0301}\r\nline\r",
                ],
            ],
        ])
        let precomposed = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "Caf\u{00e9}\nline\n",
                ],
            ],
        ])

        XCTAssertEqual(
            try PromptCanonicalizer.promptHash(for: decomposed),
            try PromptCanonicalizer.promptHash(for: precomposed)
        )
    }

    func testPromptToolCallArgumentsDoNotNormalizeUnicode() throws {
        let decomposed = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [
                        [
                            "id": "call_1",
                            "type": "function",
                            "function": [
                                "name": "lookup",
                                "arguments": "{\"q\":\"Cafe\u{0301}\"}",
                            ],
                        ],
                    ],
                ],
            ],
        ])
        let precomposed = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [
                        [
                            "id": "call_1",
                            "type": "function",
                            "function": [
                                "name": "lookup",
                                "arguments": "{\"q\":\"Caf\u{00e9}\"}",
                            ],
                        ],
                    ],
                ],
            ],
        ])

        XCTAssertNotEqual(
            try PromptCanonicalizer.promptHash(for: decomposed),
            try PromptCanonicalizer.promptHash(for: precomposed)
        )
    }

    static func fixtureRequest() throws -> ChatCompletionRequest {
        try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "system",
                    "content": "Use Cafe\u{0301}\r\nrules",
                    "name": "sys",
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "Hello\rworld",
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/png;base64,AAAA",
                                "detail": "low",
                            ],
                        ],
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": "QUJD",
                                "format": "wav",
                            ],
                        ],
                    ],
                ],
                [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [
                        [
                            "id": "call_1",
                            "type": "function",
                            "function": [
                                "name": "lookup",
                                "arguments": #"{"city":"Vilnius"}"#,
                            ],
                        ],
                    ],
                ],
                [
                    "role": "tool",
                    "tool_call_id": "call_1",
                    "content": "15 C",
                ],
            ],
            "tools": [
                [
                    "type": "function",
                    "function": [
                        "name": "lookup",
                        "description": "Weather lookup",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "city": [
                                    "type": "string",
                                ],
                            ],
                            "required": ["city"],
                        ],
                    ],
                ],
            ],
            "temperature": 0.25,
            "top_p": 0.9,
            "max_tokens": 64,
            "stop": ["END"],
            "seed": 42,
            "response_format": [
                "type": "json_object",
            ],
            "tool_choice": [
                "type": "function",
                "function": [
                    "name": "lookup",
                ],
            ],
            "presence_penalty": 0.1,
            "frequency_penalty": -0.2,
            "logit_bias": [
                "123": -1,
            ],
            "logprobs": true,
            "top_logprobs": 2,
            "n": 1,
        ])
    }
}
