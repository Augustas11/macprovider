import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import NIO
import NIOHTTP1
import XCTest
@testable import macprovider_cli

final class HTTPServerReceiptTests: XCTestCase {
    func testHTTPChatCompletionRejectsSimpleBrowserContentTypeBeforeInference() async throws {
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            contentType: "text/plain",
            receiptBuilder: nil,
            completionError: HTTPReceiptFixtureError.inferenceFailed
        )

        XCTAssertEqual(response.status, .unsupportedMediaType, response.body)
        XCTAssertTrue(response.body.contains(#""code":"request_content_type_unsupported""#), response.body)
    }

    func testHTTPChatCompletionRejectsCrossSiteBrowserOriginBeforeInference() async throws {
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            requestHeaders: [
                ("Origin", "https://evil.example"),
                ("Sec-Fetch-Site", "cross-site"),
            ],
            receiptBuilder: nil,
            completionError: HTTPReceiptFixtureError.inferenceFailed
        )

        XCTAssertEqual(response.status, .forbidden, response.body)
        XCTAssertTrue(response.body.contains(#""code":"browser_request_forbidden""#), response.body)
    }

    func testHTTPNonStreamingHandlerWritesReceiptHeaderOnSuccess() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(
                content: "answer",
                finishReason: "stop",
                promptTokens: 1,
                completionTokens: 2,
                ttftMilliseconds: 7
            )
        )

        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header)

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 2)
        XCTAssertEqual(parsed.tuple["ttft_ms"] as? Int, 7)
        XCTAssertTrue(response.body.contains(#""content":"answer""#), response.body)
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testHTTPReceiptTokensOutUsesGeneratedTokensNotVisibleUsage() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(
                content: "",
                finishReason: "tool_calls",
                promptTokens: 1,
                completionTokens: 0,
                generatedCompletionTokens: 7,
                ttftMilliseconds: 7,
                generationMilliseconds: 350,
                toolCalls: [
                    ToolCall(
                        id: "call_fixture",
                        functionName: "lookup",
                        arguments: #"{"query":"weather"}"#
                    ),
                ]
            )
        )

        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header)

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 7)
        XCTAssertTrue(response.body.contains(#""completion_tokens":0"#), response.body)
        // The `usage` object also exposes the honest total decode count
        // (all channels incl. suppressed reasoning) as an additive vendor
        // field, WITHOUT changing `completion_tokens`. The autotune
        // throughput probe reads this so reasoning models (whose visible
        // final count can be 0 on a probe prompt) measure non-zero tok/s.
        XCTAssertTrue(response.body.contains(#""macprovider_generated_completion_tokens":7"#), response.body)
        // The provider-measured warm-decode wall-time is surfaced in the same
        // `usage` object so the autotune probe can divide total decoded tokens
        // by it. Additive; does not change `completion_tokens`.
        XCTAssertTrue(response.body.contains(#""macprovider_generation_ms":350"#), response.body)
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testHTTPNonStreamingHandlerWritesV04SettlementReceiptWithWarmSwapDisabled() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let modelHash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let metadata = httpSettlementMetadataHeader(
            receiptKeyID: httpReceiptKeyID(key.publicKey.rawRepresentation),
            expectedModelHash: modelHash
        )
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            requestHeaders: [(RouterHandler.settlementMetadataHeaderName, metadata)],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(
                content: "answer",
                finishReason: "stop",
                promptTokens: 8,
                completionTokens: 3,
                ttftMilliseconds: 7
            ),
            warmSwapEnabled: false,
            modelHash: modelHash
        )

        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header, publicKey: key.publicKey)

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(parsed.tuple["receipt_version"] as? String, "4")
        XCTAssertEqual(parsed.tuple["request_id"] as? String, "req-http-receipt")
        XCTAssertEqual(parsed.tuple["provider_id"] as? String, "provider-a")
        XCTAssertEqual(parsed.tuple["model_hash"] as? String, modelHash)
        XCTAssertEqual(parsed.tuple["expected_catalog_model_hash"] as? String, modelHash)
        XCTAssertEqual(parsed.tuple["route_snapshot_digest"] as? String, String(repeating: "3", count: 64))
        XCTAssertEqual(parsed.tuple["terminal_state"] as? String, "normal_done")
        XCTAssertEqual(response.headers.first(name: RouterHandler.receiptPendingDeadlineHeaderName), "120")
        XCTAssertEqual(response.headers.first(name: RouterHandler.lateReceiptSettlementHeaderName), "not_settled")
        XCTAssertNotNil(response.headers.first(name: RouterHandler.receiptTerminalStateTSHeaderName))
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testHTTPStreamingHandlerWritesV04SettlementReceiptTrailerWithWarmSwapDisabled() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let modelHash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let metadata = httpSettlementMetadataHeader(
            receiptKeyID: httpReceiptKeyID(key.publicKey.rawRepresentation),
            expectedModelHash: modelHash
        )
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
                "stream": true,
            ],
            requestHeaders: [(RouterHandler.settlementMetadataHeaderName, metadata)],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(
                content: "streamed",
                finishReason: "stop",
                promptTokens: 8,
                completionTokens: 3,
                ttftMilliseconds: 7
            ),
            warmSwapEnabled: false,
            modelHash: modelHash,
            readStreamingBody: true
        )

        let receipt = try XCTUnwrap(httpTrailerValue(named: RouterHandler.receiptHeaderName, in: response.body))
        let parsed = try parseReceiptHeader(receipt, publicKey: key.publicKey)

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(response.headers.first(name: "trailer"), [
            RouterHandler.receiptHeaderName,
            RouterHandler.receiptTerminalStateTSHeaderName,
            RouterHandler.receiptPendingDeadlineHeaderName,
            RouterHandler.lateReceiptSettlementHeaderName,
        ].joined(separator: ", "))
        XCTAssertTrue(response.body.contains("data: [DONE]"), response.body)
        XCTAssertEqual(parsed.tuple["receipt_version"] as? String, "4")
        XCTAssertEqual(parsed.tuple["request_id"] as? String, "req-http-receipt")
        XCTAssertEqual(parsed.tuple["provider_id"] as? String, "provider-a")
        XCTAssertEqual(parsed.tuple["model_hash"] as? String, modelHash)
        XCTAssertEqual(parsed.tuple["expected_catalog_model_hash"] as? String, modelHash)
        XCTAssertEqual(parsed.tuple["terminal_state"] as? String, "normal_done")
        XCTAssertEqual(httpTrailerValue(named: RouterHandler.receiptPendingDeadlineHeaderName, in: response.body), "120")
        XCTAssertEqual(httpTrailerValue(named: RouterHandler.lateReceiptSettlementHeaderName, in: response.body), "not_settled")
        XCTAssertNotNil(httpTrailerValue(named: RouterHandler.receiptTerminalStateTSHeaderName, in: response.body))
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testHTTPNonStreamingWarmSwapDisabledV03ReceiptKeepsNullModelHashWithoutSettlementMetadata() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let servedModelHash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(
                content: "answer",
                finishReason: "stop",
                promptTokens: 8,
                completionTokens: 3,
                ttftMilliseconds: 7
            ),
            warmSwapEnabled: false,
            modelHash: servedModelHash
        )

        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header, publicKey: key.publicKey)

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(parsed.tuple["receipt_version"] as? String, "3")
        XCTAssertTrue(parsed.tuple["model_hash"] is NSNull)
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testHTTPV04SettlementReceiptRefusesMissingServedHashWithWarmSwapDisabled() async throws {
        let capture = ReceiptAuditCapture()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let modelHash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let metadata = httpSettlementMetadataHeader(
            receiptKeyID: httpReceiptKeyID(key.publicKey.rawRepresentation),
            expectedModelHash: modelHash
        )
        let response = try await ReceiptAudit.withSink({ record in capture.append(record) }) {
            try await roundTripChatCompletion(
                body: [
                    "model": "fixture-model",
                    "messages": [["role": "user", "content": "hello"]],
                ],
                requestHeaders: [(RouterHandler.settlementMetadataHeaderName, metadata)],
                receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
                completion: CompletionResult(
                    content: "answer",
                    finishReason: "stop",
                    promptTokens: 8,
                    completionTokens: 3,
                    ttftMilliseconds: 7
                ),
                warmSwapEnabled: false,
                modelHash: nil
            )
        }

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertNil(response.headers.first(name: RouterHandler.receiptHeaderName))
        let event = try capture.singleEvent()
        XCTAssertEqual(event["event"] as? String, "receipt_omitted")
        XCTAssertEqual(event["reason"] as? String, "construction_failed")
        XCTAssertEqual(event["request_id"] as? String, "req-http-receipt")
    }

    func testHTTPV04SettlementReceiptThrowsForInvalidServedHashWithWarmSwapDisabled() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let expectedModelHash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let metadata = try XCTUnwrap(SettlementReceiptMetadata(wire: httpSettlementMetadataWire(
            receiptKeyID: httpReceiptKeyID(key.publicKey.rawRepresentation),
            expectedModelHash: expectedModelHash
        )))
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [["role": "user", "content": "hello"]],
        ])

        XCTAssertThrowsError(try RouterHandler.receiptHeaderResult(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            request: request,
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            promptTokens: 8,
            ttftMs: 7,
            tokensOut: 3,
            unixTsSeconds: 1_800_000_000,
            modelHashSource: .captured("not-a-valid-sha256"),
            requestID: "req-http-receipt",
            settlementMetadata: metadata,
            terminalStateTSUnixMS: 1_800_000_000_000
        )) { error in
            XCTAssertEqual("\(error)", "settlementFieldMismatch(\"model_hash\")")
        }
    }

    func testHTTPPreKeypairOmissionDoesNotFailResponse() async throws {
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPEmptyReceiptKeyStore()),
            completion: CompletionResult(content: "answer", finishReason: "stop", promptTokens: 1, completionTokens: 1)
        )

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertNil(response.headers.first(name: RouterHandler.receiptHeaderName))
        XCTAssertTrue(response.body.contains(#""content":"answer""#), response.body)
    }

    func testHTTPResponseUsageIncludesKnownObservedModelHash() async throws {
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: nil,
            modelHash: hash
        )

        XCTAssertEqual(response.status, .ok, response.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        let usage = try XCTUnwrap(json["usage"] as? [String: Any])
        XCTAssertEqual(usage["cached_prompt_tokens"] as? Int, 0)
        XCTAssertEqual(usage["macprovider_model_hash_observed"] as? String, hash)
    }

    func testHTTPResponseUsageIncludesNullObservedModelHashWhenUnknown() async throws {
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: nil,
            modelHash: nil
        )

        XCTAssertEqual(response.status, .ok, response.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        let usage = try XCTUnwrap(json["usage"] as? [String: Any])
        XCTAssertEqual(usage["cached_prompt_tokens"] as? Int, 0)
        XCTAssertTrue(usage.keys.contains("macprovider_model_hash_observed"))
        XCTAssertTrue(usage["macprovider_model_hash_observed"] is NSNull)
    }

    func testHTTPNonStreamingHandlerEmitsOpenAIToolCallsShape() async throws {
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "What is the weather in Vilnius?"]],
                "tools": [[
                    "type": "function",
                    "function": [
                        "name": "get_weather",
                        "description": "Get the current weather for a city",
                        "parameters": [
                            "type": "object",
                            "properties": ["city": ["type": "string"]],
                            "required": ["city"],
                        ],
                    ],
                ]],
            ],
            receiptBuilder: nil,
            completion: CompletionResult(
                content: "",
                finishReason: "tool_calls",
                promptTokens: 10,
                completionTokens: 4,
                toolCalls: [ToolCall(id: "call_0123456789abcdef", functionName: "get_weather", arguments: #"{"city":"Vilnius"}"#)]
            )
        )

        XCTAssertEqual(response.status, .ok, response.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        let choices = try XCTUnwrap(json["choices"] as? [[String: Any]])
        let first = try XCTUnwrap(choices.first)
        XCTAssertEqual(first["finish_reason"] as? String, "tool_calls")
        let message = try XCTUnwrap(first["message"] as? [String: Any])
        XCTAssertTrue(message["content"] is NSNull)
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let call = try XCTUnwrap(toolCalls.first)
        XCTAssertEqual(call["id"] as? String, "call_0123456789abcdef")
        XCTAssertEqual(call["type"] as? String, "function")
        let function = try XCTUnwrap(call["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_weather")
        let arguments = try XCTUnwrap(function["arguments"] as? String)
        let argumentObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
        XCTAssertEqual(argumentObject["city"] as? String, "Vilnius")
    }

    func testHTTPRejectsUnsupportedToolChoiceForV1Slice() async throws {
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "What is the weather in Vilnius?"]],
                "tools": [[
                    "type": "function",
                    "function": [
                        "name": "get_weather",
                        "parameters": [
                            "type": "object",
                            "properties": ["city": ["type": "string"]],
                        ],
                    ],
                ]],
                "tool_choice": "none",
            ],
            receiptBuilder: nil,
            completion: CompletionResult(content: "should-not-run", finishReason: "stop", promptTokens: 1, completionTokens: 1)
        )

        XCTAssertEqual(response.status, .badRequest, response.body)
        XCTAssertTrue(response.body.contains(#""code":"unsupported_tool_choice""#), response.body)
    }

    func testHTTPAcceptsMultiTurnToolMessagesForV2Slice() async throws {
        let modelID = "mlx-community/Qwen3-32B-4bit"
        let response = try await roundTripChatCompletion(
            body: [
                "model": modelID,
                "messages": [
                    ["role": "user", "content": "What is the weather in Vilnius?"],
                    [
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [[
                            "id": "call_0123456789abcdef",
                            "type": "function",
                            "function": [
                                "name": "get_weather",
                                "arguments": #"{"city":"Vilnius"}"#,
                            ],
                        ]],
                    ],
                    [
                        "role": "tool",
                        "tool_call_id": "call_0123456789abcdef",
                        "content": #"{"temperature_c":21}"#,
                    ],
                ],
            ],
            routerModelID: modelID,
            receiptBuilder: nil,
            completion: CompletionResult(content: "It is 21 C.", finishReason: "stop", promptTokens: 1, completionTokens: 1),
            loadedModelID: modelID
        )

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertTrue(response.body.contains(#""content":"It is 21 C.""#), response.body)
    }

    func testHTTPGenericInferenceFailureGetsNullUsageReceipt() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completionError: HTTPReceiptFixtureError.inferenceFailed
        )
        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header)

        XCTAssertEqual(response.status, .serviceUnavailable, response.body)
        XCTAssertTrue(response.body.contains(#""code":"model_not_loaded""#), response.body)
        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(parsed.tuple["ttft_ms"] as? Int), 0)
        XCTAssertEqual(
            parsed.tuple["output_hash"] as? String,
            try OutputCanonicalizer.outputHash(content: "", toolCalls: nil, finishReason: "error")
        )
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testHTTPEarlyModelNotLoadedValidationGetsNullUsageReceipt() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            routerModelID: nil,
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(content: "answer", finishReason: "stop", promptTokens: 1, completionTokens: 1)
        )
        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header)

        XCTAssertEqual(response.status, .serviceUnavailable, response.body)
        XCTAssertTrue(response.body.contains(#""code":"model_not_loaded""#), response.body)
        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 0)
        XCTAssertEqual(
            parsed.tuple["output_hash"] as? String,
            try OutputCanonicalizer.outputHash(content: "", toolCalls: nil, finishReason: "error")
        )
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testHTTPStreamingHandlerWritesNoMacProviderHeaders() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
                "stream": true,
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(content: "chunk", finishReason: "stop", promptTokens: 1, completionTokens: 1),
            modelHash: hash,
            readStreamingBody: true
        )

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(response.headers.first(name: "content-type"), "text/event-stream; charset=utf-8")
        XCTAssertFalse(response.headers.contains(name: RouterHandler.receiptHeaderName))
        XCTAssertFalse(response.headers.containsMacProviderHeader)
        XCTAssertTrue(response.body.contains(#""macprovider_model_hash_observed":"\#(hash)""#), response.body)
    }

    func testHTTPStreamingToolCallE2EEmitsDeltaWithoutRawDelimiters() async throws {
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "Use get_weather for Vilnius."]],
                "stream": true,
                "tools": [[
                    "type": "function",
                    "function": [
                        "name": "get_weather",
                        "description": "Get the current weather for a city",
                        "parameters": [
                            "type": "object",
                            "properties": ["city": ["type": "string"]],
                            "required": ["city"],
                        ],
                    ],
                ]],
            ],
            receiptBuilder: nil,
            completion: CompletionResult(
                content: "",
                finishReason: "tool_calls",
                promptTokens: 10,
                completionTokens: 4,
                toolCalls: [ToolCall(id: "call_0123456789abcdef", functionName: "get_weather", arguments: #"{"city":"Vilnius"}"#)]
            ),
            readStreamingBody: true
        )

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(response.headers.first(name: "content-type"), "text/event-stream; charset=utf-8")
        XCTAssertFalse(response.body.contains("<tool_call>"), response.body)
        XCTAssertFalse(response.body.contains("</tool_call>"), response.body)
        XCTAssertTrue(response.body.contains(#""tool_calls""#), response.body)
        XCTAssertTrue(response.body.contains(#""name":"get_weather""#), response.body)
        XCTAssertTrue(response.body.contains(#""arguments":"{\"city\":\"Vilnius\"}""#), response.body)
        XCTAssertTrue(response.body.contains(#""finish_reason":"tool_calls""#), response.body)
        XCTAssertTrue(response.body.contains("data: [DONE]"), response.body)
    }


    func testHTTPHandlerEmitsReceiptIssuedAuditOnSuccess() async throws {
        let capture = ReceiptAuditCapture()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let response = try await ReceiptAudit.withSink({ record in capture.append(record) }) {
            try await roundTripChatCompletion(
                body: [
                    "model": "fixture-model",
                    "messages": [["role": "user", "content": "hello"]],
                ],
                requestID: "req-issued",
                receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
                completion: CompletionResult(content: "answer", finishReason: "stop", promptTokens: 1, completionTokens: 2, ttftMilliseconds: 7)
            )
        }
        let event = try capture.singleEvent()

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(event["event"] as? String, "receipt_issued")
        XCTAssertEqual(event["provider_id"] as? String, "provider-a")
        XCTAssertEqual(event["request_id"] as? String, "req-issued")
        XCTAssertEqual(event["model_id"] as? String, "fixture-model")
        XCTAssertEqual(event["tokens_out"] as? Int, 2)
        XCTAssertEqual(event["ttft_ms"] as? Int, 7)
        XCTAssertNotNil(event["unix_ts"] as? Int)
        XCTAssertEqual(Set(event.keys), Set(["event", "provider_id", "request_id", "model_id", "tokens_out", "ttft_ms", "unix_ts"]))
        for forbidden in ["provider_pubkey", "prompt_hash", "output_hash", "signature", "receipt"] {
            XCTAssertNil(event[forbidden], "receipt_issued leaked forbidden field \(forbidden)")
        }
    }

    func testHTTPHandlerEmitsStreamingOmissionAudit() async throws {
        let capture = ReceiptAuditCapture()
        let response = try await ReceiptAudit.withSink({ record in capture.append(record) }) {
            try await roundTripChatCompletion(
                body: [
                    "model": "fixture-model",
                    "messages": [["role": "user", "content": "hello"]],
                    "stream": true,
                ],
                requestID: "req-streaming",
                receiptBuilder: nil,
                completion: CompletionResult(content: "chunk", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            )
        }
        let event = try capture.singleEvent()

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(event["event"] as? String, "receipt_omitted")
        XCTAssertEqual(event["request_id"] as? String, "req-streaming")
        XCTAssertEqual(event["reason"] as? String, "streaming_request")
    }

    func testHTTPHandlerEmitsNoKeypairOmissionAudit() async throws {
        let capture = ReceiptAuditCapture()
        let response = try await ReceiptAudit.withSink({ record in capture.append(record) }) {
            try await roundTripChatCompletion(
                body: [
                    "model": "fixture-model",
                    "messages": [["role": "user", "content": "hello"]],
                ],
                requestID: "req-no-key",
                receiptBuilder: ReceiptBuilder(keyStore: HTTPEmptyReceiptKeyStore()),
                completion: CompletionResult(content: "answer", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            )
        }
        let event = try capture.singleEvent()

        XCTAssertEqual(response.status, .ok, response.body)
        XCTAssertEqual(event["event"] as? String, "receipt_omitted")
        XCTAssertEqual(event["request_id"] as? String, "req-no-key")
        XCTAssertEqual(event["reason"] as? String, "no_keypair")
    }

    func testHTTPHandlerEmitsModelSwapOmissionAudit() async throws {
        let capture = ReceiptAuditCapture()
        let response = try await ReceiptAudit.withSink({ record in capture.append(record) }) {
            try await roundTripChatCompletion(
                body: [
                    "model": "fixture-model",
                    "messages": [["role": "user", "content": "hello"]],
                ],
                requestID: "req-swap",
                receiptBuilder: nil,
                completionError: DrainCancelledError()
            )
        }
        let event = try capture.singleEvent()

        XCTAssertEqual(response.status, .serviceUnavailable, response.body)
        XCTAssertEqual(event["event"] as? String, "receipt_omitted")
        XCTAssertEqual(event["request_id"] as? String, "req-swap")
        XCTAssertEqual(event["reason"] as? String, "model_swap_violation")
    }

    func testHTTPHandlerEmitsPreTokenCancelOmissionOnlyForBuyerCancel() async throws {
        let capture = ReceiptAuditCapture()
        let response = try await ReceiptAudit.withSink({ record in capture.append(record) }) {
            try await roundTripChatCompletion(
                body: [
                    "model": "fixture-model",
                    "messages": [["role": "user", "content": "hello"]],
                ],
                requestID: "req-cancel",
                receiptBuilder: nil,
                completionError: APIError(status: 499, message: "buyer disconnected", type: "server_error", code: "buyer_cancelled")
            )
        }
        let event = try capture.singleEvent()

        XCTAssertEqual(response.status.code, 499, response.body)
        XCTAssertEqual(event["event"] as? String, "receipt_omitted")
        XCTAssertEqual(event["request_id"] as? String, "req-cancel")
        XCTAssertEqual(event["reason"] as? String, "pre_token_cancel")
    }

    func testHTTPHandlerDoesNotAuditUnrelatedNonNullUsageErrorAsOmission() async throws {
        let capture = ReceiptAuditCapture()
        let response = try await ReceiptAudit.withSink({ record in capture.append(record) }) {
            try await roundTripChatCompletion(
                body: [
                    "model": "fixture-model",
                    "messages": [["role": "user", "content": "hello"]],
                ],
                requestID: "req-loading",
                receiptBuilder: nil,
                completionError: APIError(status: 503, message: "loading", type: "server_error", code: "provider_loading")
            )
        }

        XCTAssertEqual(response.status, .serviceUnavailable, response.body)
        XCTAssertEqual(try capture.events().count, 0)
    }

    func testNonStreamingReceiptHeaderParsesAndSelfVerifies() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
            "temperature": 0,
        ])
        let header = try XCTUnwrap(RouterHandler.receiptHeader(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            request: request,
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 12,
            tokensOut: 2,
            unixTsSeconds: 1_800_000_000,
            modelHashSource: .warmSwapDisabled
        ))
        let parsed = try parseReceiptHeader(header)

        XCTAssertLessThanOrEqual(header.utf8.count, RouterHandler.maxReceiptHeaderBytes)
        XCTAssertEqual(parsed.tuple["model_id"] as? String, "fixture-model")
        XCTAssertTrue(parsed.tuple["model_hash"] is NSNull)
        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 2)
        XCTAssertEqual(parsed.tuple["ttft_ms"] as? Int, 12)
        XCTAssertEqual(parsed.tuple["unix_ts"] as? Int, 1_800_000_000)
        XCTAssertEqual(
            parsed.tuple["prompt_hash"] as? String,
            try PromptCanonicalizer.promptHash(for: request)
        )
        XCTAssertEqual(
            parsed.tuple["output_hash"] as? String,
            try OutputCanonicalizer.outputHash(content: "answer", toolCalls: nil, finishReason: "stop")
        )
        XCTAssertEqual(parsed.signature.count, 64)
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testPreKeypairReceiptHeaderIsOmittedWithout500() throws {
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])

        let header = try RouterHandler.receiptHeader(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPEmptyReceiptKeyStore()),
            request: request,
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 1,
            tokensOut: 1,
            unixTsSeconds: 1,
            modelHashSource: .warmSwapDisabled
        )

        XCTAssertNil(header)
    }

    func testUnexpectedInferenceStaysOnEstablishedTaxonomy() {
        // The #718 NSNull mislabel is fixed at the source (native Jinja null in
        // ModelRuntime.jsonAnyForTemplate), so no new buyer-facing error code is
        // introduced here. This residual catch keeps the PRE-EXISTING taxonomy:
        // a pre-SSE failure stays `model_not_loaded` (503) so the SPEC-015 §M.5
        // (AC-31) null-usage error receipt is still issued; a post-SSE failure
        // uses `internal_error` (500). Whether internal defects should keep
        // sharing `model_not_loaded` is a separate governed SPEC decision, not
        // part of the #718 fix.
        struct FakeJinjaError: Error, LocalizedError {
            var errorDescription: String? {
                "Cannot convert value of type NSNull to Jinja Value"
            }
        }
        let preSSE = RouterHandler.unexpectedInferenceAPIError(error: FakeJinjaError())
        XCTAssertEqual(preSSE.status, 503)
        XCTAssertEqual(preSSE.code, "model_not_loaded")

        struct GenericFailure: Error {}
        let generic = RouterHandler.unexpectedInferenceAPIError(error: GenericFailure())
        XCTAssertEqual(generic.status, 503)
        XCTAssertEqual(generic.code, "model_not_loaded")

        let postSSE = RouterHandler.unexpectedInferenceAPIError(error: GenericFailure(), sseStarted: true)
        XCTAssertEqual(postSSE.status, 500)
        XCTAssertEqual(postSSE.code, "internal_error")
    }

    func testNullUsageModelNotLoadedErrorGetsReceiptHeader() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])
        let error = APIError(
            status: 503,
            message: "Model not loaded",
            type: "server_error",
            code: "model_not_loaded"
        )

        let header = try XCTUnwrap(RouterHandler.errorReceiptHeader(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            request: request,
            error: error,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            modelHashSource: .warmSwapDisabled
        ))
        let parsed = try parseReceiptHeader(header)

        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 0)
        XCTAssertEqual(
            parsed.tuple["output_hash"] as? String,
            try OutputCanonicalizer.outputHash(content: "", toolCalls: nil, finishReason: "error")
        )
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    func testNonNullUsageErrorsDoNotGetReceiptHeader() throws {
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])
        let error = APIError(
            status: 503,
            message: "Provider loading",
            type: "service_unavailable",
            code: "provider_loading"
        )

        let header = try RouterHandler.errorReceiptHeader(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(
                key: Curve25519.Signing.PrivateKey()
            )),
            request: request,
            error: error,
            startedAt: Date(),
            modelHashSource: .warmSwapDisabled
        )

        XCTAssertNil(header)
    }

    func testWorstCaseModelIDHeaderStaysUnder4096Bytes() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let modelID = String(repeating: "m", count: 512)
        let request = try parseRequest([
            "model": modelID,
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ],
            ],
        ])

        let header = try XCTUnwrap(RouterHandler.receiptHeader(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            request: request,
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 1,
            tokensOut: 1,
            unixTsSeconds: 1,
            modelHashSource: .warmSwapDisabled
        ))

        XCTAssertLessThanOrEqual(header.utf8.count, RouterHandler.maxReceiptHeaderBytes)
    }

    func testJSONHeadersCanCarryReceiptBeforeBodyWrite() {
        let headers = makeJSONResponseHeaders(
            dataLength: 2,
            extraHeaders: [(RouterHandler.receiptHeaderName, "tuple.signature")]
        )

        XCTAssertEqual(headers.first(name: "content-type"), "application/json")
        XCTAssertEqual(headers.first(name: "content-length"), "2")
        XCTAssertEqual(headers.first(name: "connection"), "close")
        XCTAssertEqual(headers.first(name: RouterHandler.receiptHeaderName), "tuple.signature")
    }

    func testStreamingHeadersStayReceiptFreeAndByteStable() {
        let headers = makeSSEResponseHeaders()

        XCTAssertEqual(headers.first(name: "content-type"), "text/event-stream; charset=utf-8")
        XCTAssertEqual(headers.first(name: "cache-control"), "no-cache")
        XCTAssertEqual(headers.first(name: "connection"), "close")
        XCTAssertEqual(headers.first(name: "transfer-encoding"), "chunked")
        XCTAssertFalse(headers.contains(name: RouterHandler.receiptHeaderName))
        XCTAssertFalse(headers.containsMacProviderHeader)
        XCTAssertEqual(headers.canonicalPairs, [
            "content-type: text/event-stream; charset=utf-8",
            "cache-control: no-cache",
            "connection: close",
            "transfer-encoding: chunked",
        ])
    }

    // SPEC-015 §M.5 AC-29 — warm-swap-on success path binds the
    // runtime hash captured at request-start.
    func testHTTPSuccessReceiptCarriesWarmSwapHash() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completion: CompletionResult(
                content: "answer",
                finishReason: "stop",
                promptTokens: 1,
                completionTokens: 2,
                ttftMilliseconds: 5
            ),
            warmSwapEnabled: true,
            modelHash: hash
        )

        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header)
        XCTAssertEqual(parsed.tuple["model_hash"] as? String, hash)
        XCTAssertEqual(parsed.tuple["receipt_version"] as? String, "3")
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    // SPEC-015 §M.5 AC-31 — error receipt inherits request-start hash.
    func testHTTPErrorReceiptInheritsWarmSwapHash() async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let hash = "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
        let response = try await roundTripChatCompletion(
            body: [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hello"]],
            ],
            receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
            completionError: HTTPReceiptFixtureError.inferenceFailed,
            warmSwapEnabled: true,
            modelHash: hash
        )

        let header = try XCTUnwrap(response.headers.first(name: RouterHandler.receiptHeaderName))
        let parsed = try parseReceiptHeader(header)
        XCTAssertEqual(parsed.tuple["model_hash"] as? String, hash,
                       "AC-31: warm-swap-on error receipts MUST carry the request-start hash")
        XCTAssertEqual(parsed.tuple["tokens_out"] as? Int, 0)
        XCTAssertEqual(parsed.tuple["receipt_version"] as? String, "3")
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed.tupleData))
    }

    // SPEC-015 §M.5 AC-42 — defence-in-depth refusal also emits the
    // `receipt_omitted: model_swap_violation` audit row end-to-end
    // through the HTTP success path (closing the CODE-R2-HIGH-1 +
    // SECURITY-R2-HIGH-1 gap that the helper-only test left).
    func testHTTPAmbiguousProvenanceEmitsReceiptOmittedAudit() async throws {
        let capture = ReceiptAuditCapture()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let response = try await ReceiptAudit.withSink({ record in capture.append(record) }) {
            try await roundTripChatCompletion(
                body: [
                    "model": "fixture-model",
                    "messages": [["role": "user", "content": "hello"]],
                ],
                requestID: "req-ambiguous",
                receiptBuilder: ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key)),
                completion: CompletionResult(content: "answer", finishReason: "stop", promptTokens: 1, completionTokens: 1),
                warmSwapEnabled: true,
                modelHash: nil  // warm-swap on + no hash → .ambiguous
            )
        }
        XCTAssertEqual(response.status, .ok)
        XCTAssertNil(response.headers.first(name: RouterHandler.receiptHeaderName))
        let event = try capture.singleEvent()
        XCTAssertEqual(event["event"] as? String, "receipt_omitted",
                       "AC-42 audit row missing")
        XCTAssertEqual(event["reason"] as? String, "model_swap_violation",
                       "AC-42: reason MUST be model_swap_violation")
        XCTAssertEqual(event["provider_id"] as? String, "provider-a")
        XCTAssertEqual(event["request_id"] as? String, "req-ambiguous")
        for forbidden in ["model_hash", "prompt_hash", "output_hash", "signature", "provider_pubkey"] {
            XCTAssertNil(event[forbidden], "receipt_omitted leaked \(forbidden)")
        }
    }

    // SPEC-015 §M.5 AC-42 — defence-in-depth refusal: warm-swap on
    // AND no hash on the request-start snapshot → no receipt header,
    // model_swap_violation audit row.
    func testHTTPReceiptRefusedOnAmbiguousProvenance() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key))
        let request = try PromptCanonicalizerTests.fixtureRequest()

        // resolveModelHashSource maps warm-swap=on + snapshot.modelHash=nil
        // → .ambiguous → §M.2.2 defence-in-depth refusal.
        let ambiguousSnapshot = RuntimeSnapshot(state: .ready, container: nil, modelID: "fixture-model", modelHash: nil)
        let source = RouterHandler.resolveModelHashSource(warmSwapEnabled: true, snapshot: ambiguousSnapshot)
        XCTAssertEqual(source, .ambiguous, "warm-swap on + nil snapshot.modelHash MUST resolve to .ambiguous")

        let header = try RouterHandler.receiptHeader(
            providerID: "provider-a",
            receiptBuilder: builder,
            request: request,
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 5,
            tokensOut: 1,
            unixTsSeconds: 1,
            modelHashSource: source
        )
        XCTAssertNil(header, "§M.2.2: ambiguous provenance MUST refuse the receipt")
    }

    // SPEC-015 §M.5 AC-42 — §M.2.2 normal in-flight request through
    // a swap MUST still emit a receipt (the construction proof case,
    // distinct from the defence-in-depth refusal above).
    func testHTTPReceiptEmittedForNormalInFlightSwap() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: HTTPFixedReceiptKeyStore(key: key))
        let request = try PromptCanonicalizerTests.fixtureRequest()
        let hash = "00010203040506070809a0b0c0d0e0f00102030405060708090a0b0c0d0e0f01"
        let snapshot = RuntimeSnapshot(state: .draining, container: nil, modelID: "fixture-model", modelHash: hash)
        let source = RouterHandler.resolveModelHashSource(warmSwapEnabled: true, snapshot: snapshot)
        XCTAssertEqual(source, .captured(hash))

        let header = try XCTUnwrap(RouterHandler.receiptHeader(
            providerID: "provider-a",
            receiptBuilder: builder,
            request: request,
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 5,
            tokensOut: 1,
            unixTsSeconds: 1,
            modelHashSource: source
        ))
        let parsed = try parseReceiptHeader(header)
        XCTAssertEqual(parsed.tuple["model_hash"] as? String, hash)
    }
}

private struct ParsedReceipt {
    let tupleData: Data
    let tuple: [String: Any]
    let signature: Data
    let publicKey: Curve25519.Signing.PublicKey
}

private struct HTTPReceiptResponse {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let body: String
}

private final class ReceiptAuditCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Data] = []

    func append(_ record: Data) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    func events() throws -> [[String: Any]] {
        lock.lock()
        let snapshot = records
        lock.unlock()
        return try snapshot.map { record in
            let line = String(decoding: record, as: UTF8.self).trimmingCharacters(in: .newlines)
            let data = Data(line.utf8)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    func singleEvent() throws -> [String: Any] {
        let events = try events()
        XCTAssertEqual(events.count, 1)
        return try XCTUnwrap(events.first)
    }
}

private enum HTTPReceiptFixtureError: Error {
    case inferenceFailed
}

private func roundTripChatCompletion(
    body: [String: Any],
    routerModelID: String? = "fixture-model",
    providerID: String? = "provider-a",
    requestID: String = "req-http-receipt",
    contentType: String? = "application/json",
    requestHeaders: [(String, String)] = [],
    receiptBuilder: ReceiptBuilder?,
    completion: CompletionResult? = nil,
    completionError: Error? = nil,
    warmSwapEnabled: Bool = false,
    modelHash: String? = nil,
    loadedModelID: String = "fixture-model",
    readStreamingBody: Bool = false
) async throws -> HTTPReceiptResponse {
    let runtime = ModelRuntime(
        modelID: loadedModelID,
        modelHash: modelHash,
        warmSwapEnabled: warmSwapEnabled,
        loader: { _ in throw HTTPReceiptFixtureError.inferenceFailed },
        testCompletion: { _, _ in
            if let completionError {
                throw completionError
            }
            return completion ?? CompletionResult(
                content: "answer",
                finishReason: "stop",
                promptTokens: 1,
                completionTokens: 1
            )
        }
    )
    let status = ProviderStatus(
        modelID: loadedModelID,
        modelLoaded: true,
        capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
    )
    return try await withReceiptHTTPServer(
        runtime: runtime,
        providerStatus: status,
        providerID: providerID,
        routerModelID: routerModelID,
        receiptBuilder: receiptBuilder,
        warmSwapEnabled: warmSwapEnabled
    ) { port in
        let isStreaming = body["stream"] as? Bool == true
        return try rawChatCompletionRoundTrip(
            port: port,
            body: body,
            headerOnly: isStreaming && !readStreamingBody,
            requestID: requestID,
            contentType: contentType,
            requestHeaders: requestHeaders
        )
    }
}

private func withReceiptHTTPServer<T>(
    runtime: ModelRuntime,
    providerStatus: ProviderStatus,
    providerID: String?,
    routerModelID: String? = "fixture-model",
    receiptBuilder: ReceiptBuilder?,
    warmSwapEnabled: Bool = false,
    operation: (Int) throws -> T
) async throws -> T {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(RouterHandler(
                    modelID: routerModelID,
                    providerID: providerID,
                    coordinatorURL: nil,
                    modelRuntime: runtime,
                    providerStatus: providerStatus,
                    warmSwapEnabled: warmSwapEnabled,
                    maxBodyBytes: 1_000_000,
                    receiptBuilder: receiptBuilder
                ))
            }
        }
        .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    do {
        let port = try XCTUnwrap(channel.localAddress?.port)
        let result = try operation(port)
        try await channel.close().get()
        try await group.shutdownGracefully()
        return result
    } catch {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        throw error
    }
}

private func rawChatCompletionRoundTrip(
    port: Int,
    body: [String: Any],
    headerOnly: Bool,
    requestID: String,
    contentType: String? = "application/json",
    requestHeaders: [(String, String)] = []
) throws -> HTTPReceiptResponse {
    let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    var requestHead = "POST /v1/chat/completions HTTP/1.1\r\n"
        + "Host: 127.0.0.1:\(port)\r\n"
        + "Content-Length: \(bodyData.count)\r\n"
        + "X-Request-ID: \(requestID)\r\n"
    if let contentType {
        requestHead += "Content-Type: \(contentType)\r\n"
    }
    for (name, value) in requestHeaders {
        requestHead += "\(name): \(value)\r\n"
    }
    requestHead += "Connection: close\r\n"
        + "\r\n"
    var requestData = Data(requestHead.utf8)
    requestData.append(bodyData)

    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    XCTAssertEqual(connectResult, 0)

    try requestData.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < requestData.count {
            let count = Darwin.send(descriptor, base.advanced(by: sent), requestData.count - sent, 0)
            if count <= 0 {
                throw POSIXError(.EIO)
            }
            sent += count
        }
    }

    var response = Data()
    var scratch = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.recv(descriptor, &scratch, scratch.count, 0)
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw POSIXError(.ETIMEDOUT)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if count == 0 {
            break
        }
        response.append(scratch, count: count)
        if let range = String(decoding: response, as: UTF8.self).range(of: "\r\n\r\n") {
            if headerOnly {
                break
            }
            let raw = String(decoding: response, as: UTF8.self)
            let headers = String(raw[..<range.lowerBound])
            let expectedLength = contentLength(from: headers)
            let body = raw[range.upperBound...]
            if let expectedLength, body.utf8.count >= expectedLength {
                break
            }
        }
    }

    return try parseRawHTTPResponse(response)
}

private func contentLength(from headerText: String) -> Int? {
    for line in headerText.split(separator: "\r\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.lowercased() == "content-length" else { continue }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(value)
    }
    return nil
}

private func parseRawHTTPResponse(_ data: Data) throws -> HTTPReceiptResponse {
    let raw = String(decoding: data, as: UTF8.self)
    let separator = try XCTUnwrap(raw.range(of: "\r\n\r\n"))
    let headerText = String(raw[..<separator.lowerBound])
    let body = String(raw[separator.upperBound...])
    let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
    let statusLine = try XCTUnwrap(lines.first)
    let statusParts = statusLine.split(separator: " ")
    let code = try XCTUnwrap(Int(statusParts[1]))
    var headers = HTTPHeaders()
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<colon])
        let valueStart = line.index(after: colon)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        headers.add(name: name, value: value)
    }
    return HTTPReceiptResponse(
        status: HTTPResponseStatus(statusCode: code),
        headers: headers,
        body: body
    )
}

private func parseReceiptHeader(_ header: String, publicKey suppliedPublicKey: Curve25519.Signing.PublicKey? = nil) throws -> ParsedReceipt {
    let pieces = header.split(separator: ".")
    XCTAssertEqual(pieces.count, 2)
    let tupleData = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
    let signature = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
    let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleData) as? [String: Any])
    let publicKey: Curve25519.Signing.PublicKey
    if let suppliedPublicKey {
        publicKey = suppliedPublicKey
    } else {
        let pubkey = try XCTUnwrap(tuple["provider_pubkey"] as? String)
        let pubkeyData = try XCTUnwrap(Data(base64Encoded: pubkey))
        publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubkeyData)
    }
    return ParsedReceipt(
        tupleData: tupleData,
        tuple: tuple,
        signature: signature,
        publicKey: publicKey
    )
}

private func httpSettlementMetadataHeader(receiptKeyID: String, expectedModelHash: String) -> String {
    let metadata = httpSettlementMetadataWire(receiptKeyID: receiptKeyID, expectedModelHash: expectedModelHash)
    let data = try! JSONSerialization.data(withJSONObject: metadata, options: [.withoutEscapingSlashes])
    return data.base64URLUnpadded()
}

private func httpSettlementMetadataWire(receiptKeyID: String, expectedModelHash: String) -> [String: Any] {
    [
        "account_scope": "acct_sha256:" + String(repeating: "1", count: 64),
        "request_id": "req-http-receipt",
        "attempt_n": 0,
        "provider_id": "provider-a",
        "provider_receipt_key_id": receiptKeyID,
        "model_id": "fixture-model",
        "expected_catalog_model_hash": expectedModelHash,
        "catalog_id": "catalog-a",
        "catalog_body_digest": String(repeating: "2", count: 64),
        "route_snapshot_digest": String(repeating: "3", count: 64),
        "route_snapshot_policy_version": "spec022-prereq-v0",
        "route_snapshot_mode": "observe",
        "prompt_hash": String(repeating: "4", count: 64),
        "output_prefix_start_byte": 5,
        "pending_deadline_seconds": 120,
    ]
}

private func httpReceiptKeyID(_ pubkey: Data) -> String {
    let digest = SHA256.hash(data: pubkey)
    return "ed25519-sha256:" + digest.map { String(format: "%02x", $0) }.joined()
}

private func httpTrailerValue(named name: String, in body: String) -> String? {
    let expected = name.lowercased()
    for line in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let actual = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard actual == expected else { continue }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
}

private final class HTTPFixedReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey

    init(key: Curve25519.Signing.PrivateKey) {
        self.key = key
    }

    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        key
    }

    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        key
    }

    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}

    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}

private final class HTTPEmptyReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }

    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        nil
    }

    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}

    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}

private extension HTTPHeaders {
    /// v0.1 invariant: response headers MUST NOT carry receipt-bearing MacProvider data.
    /// v0.2 §10d.4 + AC-44 adds NORMATIVE diagnostic headers (Streaming-Mode, timing
    /// instrumentation) that are explicitly allowed. This predicate excludes the
    /// known v0.2-normative headers from the "no MacProvider headers" check.
    var containsMacProviderHeader: Bool {
        let v02NormativeSuffixes: Set<String> = [
            "streaming-mode",
            "provider-toolcallopen-unix-ms",
            "provider-unix-ms",
            "coordinator-firstforward-unix-ms",
            "gateway-firstbyte-unix-ms",
            "ntp-skew-ms",
        ]
        return contains { name, _ in
            let lower = name.lowercased()
            guard lower.hasPrefix("x-macprovider-") else { return false }
            let suffix = String(lower.dropFirst("x-macprovider-".count))
            return !v02NormativeSuffixes.contains(suffix)
        }
    }

    var canonicalPairs: [String] {
        map { "\($0.name.lowercased()): \($0.value)" }
    }
}
