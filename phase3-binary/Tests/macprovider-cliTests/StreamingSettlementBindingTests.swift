import CryptoKit
import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class StreamingSettlementBindingTests: XCTestCase {
    func testCleanupRewriteSerialAndContinuousBatchBindDeliveredGoldenBytes() throws {
        let fixture = try Self.loadFixture()

        let serial = try serialStream(
            request: makeRequest(),
            snapshots: fixture.decodedSnapshots,
            finalText: fixture.nonStreamContent
        )
        XCTAssertEqual(serial.deltas, fixture.deliveredDeltas)
        XCTAssertEqual(serial.completion.content, fixture.deliveredContent)
        XCTAssertEqual(serial.completion.content, fixture.nonStreamContent)
        try assertSettlementBinding(serial.completion, fixture: fixture)

        let batched = try continuousBatchStream(
            request: makeRequest(withTools: true),
            pieces: fixture.tokenPieces,
            finalText: fixture.nonStreamContent
        )
        XCTAssertEqual(batched.deltas.joined(), fixture.deliveredContent)
        XCTAssertEqual(batched.completion.content, fixture.deliveredContent)
        try assertSettlementBinding(batched.completion, fixture: fixture)
    }

    func testStopHoldbackBindsOnlyDeliveredContent() throws {
        let result = try serialStream(
            request: makeRequest(stops: ["</stop>"]),
            snapshots: ["answer<", "answer</", "answer</stop>ignored"],
            finalText: "answer"
        )
        XCTAssertEqual(result.deltas.joined(), "answer")
        try assertSettlementBinding(result.completion)
    }

    func testStructuredJSONValidationAndSettlementUseDeliveredContent() throws {
        let request = try makeRequest(responseFormat: ["type": "json_object"])
        let result = try serialStream(
            request: request,
            snapshots: [#"{"value":"It "#, #"{"value":"It 's"#, #"{"value":"It's fine"}"#],
            finalText: #"{"value":"It's fine"}"#
        )
        let validated = try ModelRuntime.validateStructuredStreamingCompletion(
            result.completion,
            request: request,
            buyerVisibleContent: result.deltas.joined()
        )
        XCTAssertEqual(validated.content, result.deltas.joined())
        try assertSettlementBinding(validated)
    }

    func testToolCallRowSuppressesContentAndBindsToolCall() throws {
        let request = try makeRequest(withTools: true)
        let call = macprovider_cli.ToolCall(
            id: "call_0123456789abcdef0123456789abcdef",
            functionName: "lookup",
            arguments: #"{"query":"weather"}"#
        )
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var emitter = SerialStreamingTextEmitter(request: request)
        var contentDeltas: [String] = []
        var toolDeltaCount = 0
        let generated = #"<tool_call>{"name":"lookup","arguments":{"query":"weather"}}</tool_call>"#
        _ = emitter.step(
            candidate: (text: generated, hitStop: false),
            structuredAccumulator: accumulator,
            idleState: idle,
            onChunk: {
                switch $0 {
                case .content(let text): contentDeltas.append(text)
                case .toolCallDelta: toolDeltaCount += 1
                }
            }
        )
        try emitter.finish(
            finalText: generated,
            parsed: ModelRuntime.ParsedGeneratedOutput(
                content: "",
                toolCalls: [call],
                completionTokens: 1,
                generatedCompletionTokens: 1,
                hitStop: false,
                isTerminal: true
            ),
            structuredAccumulator: accumulator,
            idleState: idle,
            onChunk: {
                switch $0 {
                case .content(let text): contentDeltas.append(text)
                case .toolCallDelta: toolDeltaCount += 1
                }
            }
        )
        let completion = CompletionResult(
            content: emitter.emittedContent,
            finishReason: "tool_calls",
            promptTokens: 1,
            completionTokens: 1,
            toolCalls: [call],
            settlementDisposition: .eligibleOwner
        )
        XCTAssertTrue(contentDeltas.isEmpty)
        XCTAssertGreaterThan(toolDeltaCount, 0)
        XCTAssertEqual(completion.content, "")
        try assertSettlementBinding(completion)
    }

    func testCleanupSensitiveToolArgumentsMatchFinalBytesForSerialAndContinuousBatch() throws {
        let request = try makeRequest(withTools: true)
        let finalArguments = #"{"query":"It's fine"}"#
        let finalText = #"<tool_call>{"name":"lookup","arguments":{"query":"It's fine"}}</tool_call>"#
        let call = macprovider_cli.ToolCall(
            id: "call_0123456789abcdef0123456789abcdef",
            functionName: "lookup",
            arguments: finalArguments
        )

        let serial = try toolArgumentStream(
            request: request,
            snapshots: [
                #"<tool_call>{"name":"lookup","arguments":{"query":"It "#,
                #"<tool_call>{"name":"lookup","arguments":{"query":"It's"#,
                finalText,
            ],
            finalText: finalText,
            call: call
        )
        XCTAssertEqual(Data(serial.arguments.utf8), Data(finalArguments.utf8))
        XCTAssertEqual(serial.deliveredID, serial.finalCall.id)
        XCTAssertEqual(serial.deliveredName, serial.finalCall.functionName)
        try assertSettlementBinding(CompletionResult(
            content: "",
            finishReason: "tool_calls",
            promptTokens: 1,
            completionTokens: 1,
            toolCalls: [serial.finalCall],
            settlementDisposition: .eligibleOwner
        ))

        let pieces = [
            #"<tool_call>{"name":"lookup","arguments":{"query":"It"#,
            "Ġ", "'", "s", "Ġfine", #""}}</tool_call>"#,
        ]
        let batched = try continuousBatchToolArgumentStream(
            request: request,
            pieces: pieces,
            finalText: finalText,
            call: call
        )
        XCTAssertEqual(Data(batched.arguments.utf8), Data(finalArguments.utf8))
        XCTAssertEqual(batched.completion.toolCalls?.first?.arguments, finalArguments)
        XCTAssertEqual(batched.deliveredID, batched.completion.toolCalls?.first?.id)
        XCTAssertEqual(batched.deliveredName, batched.completion.toolCalls?.first?.functionName)
        try assertSettlementBinding(batched.completion)
    }

    func testCleanupHoldbackBypassFailsClosedBeforeFinalToolArgumentsCanBeSigned() throws {
        let request = try makeRequest(withTools: true)
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var emitter = SerialStreamingTextEmitter(
            request: request,
            holdsCleanupPatternPrefixes: false
        )
        let provisional = #"<tool_call>{"name":"lookup","arguments":{"query":"It 's fine"}}</tool_call>"#
        _ = emitter.step(
            candidate: (text: provisional, hitStop: false),
            structuredAccumulator: accumulator,
            idleState: idle,
            onChunk: { _ in }
        )
        let call = macprovider_cli.ToolCall(
            id: "call_0123456789abcdef0123456789abcdef",
            functionName: "lookup",
            arguments: #"{"query":"It's fine"}"#
        )

        XCTAssertThrowsError(try emitter.finish(
            finalText: #"<tool_call>{"name":"lookup","arguments":{"query":"It's fine"}}</tool_call>"#,
            parsed: ModelRuntime.ParsedGeneratedOutput(
                content: "",
                toolCalls: [call],
                completionTokens: 1,
                generatedCompletionTokens: 1,
                hitStop: false,
                isTerminal: true
            ),
            structuredAccumulator: accumulator,
            idleState: idle,
            onChunk: { _ in }
        )) { error in
            XCTAssertEqual((error as? APIError)?.code, "malformed_tool_call_final_json")
        }
    }

    func testFinalCloseRejectsNonPrefixToolArgumentFallback() {
        let streamed = StreamedToolCallArgs()
        streamed.note(StreamToolCallDelta(
            index: 0,
            id: "call_0123456789abcdef0123456789abcdef",
            type: "function",
            functionName: "lookup",
            arguments: #"{"query":"It 's"#
        ))
        let call = macprovider_cli.ToolCall(
            id: "call_0123456789abcdef0123456789abcdef",
            functionName: "lookup",
            arguments: #"{"query":"It's fine"}"#
        )

        XCTAssertThrowsError(try streamed.finalDeltas(for: [call])) { error in
            XCTAssertEqual((error as? APIError)?.code, "malformed_tool_call_final_json")
        }
    }

    func testFinalCloseRejectsToolCallIdentityMismatch() {
        let streamed = StreamedToolCallArgs()
        streamed.note(StreamToolCallDelta(
            index: 0,
            id: "call_delivered",
            type: "function",
            functionName: "lookup",
            arguments: #"{"query":"It's fine"}"#
        ))
        let finalized = macprovider_cli.ToolCall(
            id: "call_finalized",
            functionName: "lookup",
            arguments: #"{"query":"It's fine"}"#
        )

        XCTAssertThrowsError(try streamed.finalDeltas(for: [finalized])) { error in
            XCTAssertEqual((error as? APIError)?.code, "malformed_tool_call_final_json")
        }

        let invalidType = StreamedToolCallArgs()
        invalidType.note(StreamToolCallDelta(
            index: 0,
            id: finalized.id,
            type: "evil",
            functionName: finalized.functionName,
            arguments: finalized.arguments
        ))
        XCTAssertThrowsError(try invalidType.finalDeltas(for: [finalized])) { error in
            XCTAssertEqual((error as? APIError)?.code, "malformed_tool_call_final_json")
        }

        let fragmentedName = StreamedToolCallArgs()
        fragmentedName.note(StreamToolCallDelta(
            index: 0,
            id: finalized.id,
            type: "function",
            functionName: "look",
            arguments: ""
        ))
        fragmentedName.note(StreamToolCallDelta(
            index: 0,
            id: nil,
            type: nil,
            functionName: "up",
            arguments: finalized.arguments
        ))
        XCTAssertNoThrow(try fragmentedName.finalDeltas(for: [finalized]))
    }

    func testNoRewriteContentEqualsParsedContentAndSettlement() throws {
        let parsed = "café 🙂"
        let result = try serialStream(
            request: makeRequest(),
            snapshots: ["caf", "café ", parsed],
            finalText: parsed
        )
        XCTAssertEqual(Data(result.completion.content.utf8), Data(parsed.utf8))
        try assertSettlementBinding(result.completion)
    }

    private func serialStream(
        request: ChatCompletionRequest,
        snapshots: [String],
        finalText: String
    ) throws -> (deltas: [String], completion: CompletionResult) {
        let accumulator = StructuredStreamingContentAccumulator(
            enabled: ModelRuntime.requiresStructuredValidation(request.responseFormat)
        )
        let idle = StructuredStreamingIdleState(enabled: false)
        var emitter = SerialStreamingTextEmitter(request: request)
        var deltas: [String] = []
        for snapshot in snapshots {
            let candidate = ModelRuntime.streamingSafePrefix(
                snapshot,
                stopTokenFilter: StopTokenFilter(tokens: []),
                requestStops: request.stop
            )
            _ = emitter.step(
                candidate: candidate,
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: { if case .content(let text) = $0 { deltas.append(text) } }
            )
        }
        let parsed = ModelRuntime.ParsedGeneratedOutput(
            content: finalText,
            toolCalls: [],
            completionTokens: snapshots.count,
            generatedCompletionTokens: snapshots.count,
            hitStop: false,
            isTerminal: true
        )
        try emitter.finish(
            finalText: finalText,
            parsed: parsed,
            structuredAccumulator: accumulator,
            idleState: idle,
            onChunk: { if case .content(let text) = $0 { deltas.append(text) } }
        )
        return (
            deltas,
            CompletionResult(
                content: emitter.emittedContent,
                finishReason: "stop",
                promptTokens: 1,
                completionTokens: snapshots.count,
                settlementDisposition: .eligibleOwner
            )
        )
    }

    private func continuousBatchStream(
        request: ChatCompletionRequest,
        pieces: [String],
        finalText: String
    ) throws -> (deltas: [String], completion: CompletionResult) {
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        let state = ModelRuntime.AttachedPagedKVStreamState(
            request: request,
            detokenizer: ModelRuntime.StreamingDetokenizer(
                decode: { ids in ids.map { pieces[$0] }.joined() },
                tokenPiece: { pieces[$0] },
                cleanUpTokenizationSpaces: true
            )
        )
        var deltas: [String] = []
        for token in pieces.indices {
            _ = state.step(
                eventTokens: [token],
                stopTokenFilter: StopTokenFilter(tokens: []),
                requestStops: request.stop,
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: { if case .content(let text) = $0 { deltas.append(text) } }
            )
        }
        let parsed = ModelRuntime.ParsedGeneratedOutput(
            content: finalText,
            toolCalls: [],
            completionTokens: pieces.count,
            generatedCompletionTokens: pieces.count,
            hitStop: false,
            isTerminal: true
        )
        let finalized = ModelRuntime.ContinuousBatchFinalizedRow(
            completion: CompletionResult(
                content: parsed.content,
                finishReason: "stop",
                promptTokens: 1,
                completionTokens: pieces.count,
                settlementDisposition: .eligibleOwner
            ),
            filteredText: finalText,
            parsed: parsed,
            generatedTokens: Array(pieces.indices),
            truncatedAtSerialStop: false
        )
        let completion = try ModelRuntime.finishContinuousBatchStream(
            finalized,
            state: state,
            request: request,
            structuredAccumulator: accumulator,
            idleState: idle,
            onChunk: { if case .content(let text) = $0 { deltas.append(text) } }
        )
        return (deltas, completion)
    }

    private func toolArgumentStream(
        request: ChatCompletionRequest,
        snapshots: [String],
        finalText: String,
        call: macprovider_cli.ToolCall
    ) throws -> (arguments: String, deliveredID: String?, deliveredName: String?, finalCall: macprovider_cli.ToolCall) {
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        var emitter = SerialStreamingTextEmitter(request: request)
        var arguments = ""
        var deliveredID: String?
        var deliveredName: String?
        let sink: (StreamChunk) -> Void = { chunk in
            if case .toolCallDelta(let delta) = chunk {
                if let id = delta.id { deliveredID = id }
                if let functionName = delta.functionName { deliveredName = functionName }
                arguments += delta.arguments ?? ""
                XCTAssertTrue(
                    call.arguments.hasPrefix(arguments),
                    "every delivered argument concatenation must prefix the finalized arguments"
                )
            }
        }
        for snapshot in snapshots {
            _ = emitter.step(
                candidate: (text: snapshot, hitStop: false),
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: sink
            )
        }
        try emitter.finish(
            finalText: finalText,
            parsed: ModelRuntime.ParsedGeneratedOutput(
                content: "",
                toolCalls: [call],
                completionTokens: snapshots.count,
                generatedCompletionTokens: snapshots.count,
                hitStop: false,
                isTerminal: true
            ),
            structuredAccumulator: accumulator,
            idleState: idle,
            onChunk: sink
        )
        XCTAssertEqual(emitter.cleanupRewriteFallbackCount, 0)
        return (
            arguments,
            deliveredID,
            deliveredName,
            try XCTUnwrap(emitter.reconciledToolCalls.first)
        )
    }

    private func continuousBatchToolArgumentStream(
        request: ChatCompletionRequest,
        pieces: [String],
        finalText: String,
        call: macprovider_cli.ToolCall
    ) throws -> (arguments: String, deliveredID: String?, deliveredName: String?, completion: CompletionResult) {
        let accumulator = StructuredStreamingContentAccumulator(enabled: false)
        let idle = StructuredStreamingIdleState(enabled: false)
        let state = ModelRuntime.AttachedPagedKVStreamState(
            request: request,
            detokenizer: ModelRuntime.StreamingDetokenizer(
                decode: { _ in finalText },
                tokenPiece: { pieces[$0] },
                cleanUpTokenizationSpaces: true
            )
        )
        var arguments = ""
        var deliveredID: String?
        var deliveredName: String?
        let sink: (StreamChunk) -> Void = { chunk in
            if case .toolCallDelta(let delta) = chunk {
                if let id = delta.id { deliveredID = id }
                if let functionName = delta.functionName { deliveredName = functionName }
                arguments += delta.arguments ?? ""
                XCTAssertTrue(
                    call.arguments.hasPrefix(arguments),
                    "every batched argument concatenation must prefix the finalized arguments"
                )
            }
        }
        for token in pieces.indices {
            _ = state.step(
                eventTokens: [token],
                stopTokenFilter: StopTokenFilter(tokens: []),
                requestStops: [],
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: sink
            )
        }
        let parsed = ModelRuntime.ParsedGeneratedOutput(
            content: "",
            toolCalls: [call],
            completionTokens: pieces.count,
            generatedCompletionTokens: pieces.count,
            hitStop: false,
            isTerminal: true
        )
        let finalized = ModelRuntime.ContinuousBatchFinalizedRow(
            completion: CompletionResult(
                content: "",
                finishReason: "tool_calls",
                promptTokens: 1,
                completionTokens: pieces.count,
                toolCalls: [call],
                settlementDisposition: .eligibleOwner
            ),
            filteredText: finalText,
            parsed: parsed,
            generatedTokens: Array(pieces.indices),
            truncatedAtSerialStop: false
        )
        let completion = try ModelRuntime.finishContinuousBatchStream(
            finalized,
            state: state,
            request: request,
            structuredAccumulator: accumulator,
            idleState: idle,
            onChunk: sink
        )
        return (arguments, deliveredID, deliveredName, completion)
    }

    private func assertSettlementBinding(
        _ completion: CompletionResult,
        fixture: Fixture? = nil
    ) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let modelHash = String(repeating: "a", count: 64)
        let metadata = try XCTUnwrap(SettlementReceiptMetadata(wire: [
            "account_scope": "acct_sha256:" + String(repeating: "1", count: 64),
            "request_id": "req-stream-binding",
            "attempt_n": 0,
            "provider_id": "provider-a",
            "provider_receipt_key_id": Self.receiptKeyID(key.publicKey.rawRepresentation),
            "model_id": "fixture-model",
            "expected_catalog_model_hash": modelHash,
            "catalog_id": "catalog-a",
            "catalog_body_digest": String(repeating: "2", count: 64),
            "route_snapshot_digest": String(repeating: "3", count: 64),
            "route_snapshot_policy_version": "fixture",
            "route_snapshot_mode": "observe",
            "prompt_hash": String(repeating: "4", count: 64),
            "output_prefix_start_byte": 0,
            "pending_deadline_seconds": 120,
        ]))
        let receipt = try ReceiptBuilder(keyStore: StreamingBindingKeyStore(key: key)).buildSettlement(
            providerId: "provider-a",
            input: SettlementReceiptInput(
                metadata: metadata,
                modelHash: modelHash,
                content: completion.content,
                toolCalls: completion.toolCalls,
                finishReason: completion.finishReason,
                promptTokens: Int64(completion.promptTokens),
                completionTokens: Int64(completion.completionTokens),
                terminalState: "normal_done",
                terminalStateUnixMS: 1_800_000_000_000,
                issuedAtUnixMS: 1_800_000_000_001
            )
        )
        let tupleData = try XCTUnwrap(Data(base64Encoded: String(receipt.split(separator: ".")[0])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleData) as? [String: Any])
        let end = completion.content.precomposedStringWithCanonicalMapping.utf8.count
        let expected = try RFC8785JCS.sha256Hex(of: .object([
            "content": .string(completion.content.precomposedStringWithCanonicalMapping),
            "finish_reason": .string(completion.finishReason),
            "output_prefix_end_byte": .int(end),
            "output_prefix_start_byte": .int(0),
            "terminal_state": .string("normal_done"),
            "tool_calls": try Self.toolCallsValue(completion.toolCalls),
        ]))
        XCTAssertEqual(tuple["output_hash"] as? String, expected)
        XCTAssertEqual((tuple["output_prefix_end_byte"] as? NSNumber)?.intValue, end)
        if let fixture {
            XCTAssertEqual(expected, fixture.expectedOutputHash)
            XCTAssertEqual(completion.content, fixture.settlementContent)
        }
    }

    private static func toolCallsValue(_ calls: [macprovider_cli.ToolCall]?) throws -> RFC8785JCS.Value {
        guard let calls, !calls.isEmpty else { return .null }
        return .array(calls.map { call in
            RFC8785JCS.Value.object([
                "function": RFC8785JCS.Value.object([
                    "arguments": RFC8785JCS.Value.rawString(call.arguments),
                    "name": RFC8785JCS.Value.string(call.functionName),
                ]),
                "id": RFC8785JCS.Value.string(call.id),
                "type": RFC8785JCS.Value.string("function"),
            ])
        })
    }

    private func makeRequest(
        stops: [String] = [],
        responseFormat: [String: Any]? = nil,
        withTools: Bool = false
    ) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": "mlx-community/test-model",
            "messages": [["role": "user", "content": "test"]],
        ]
        if !stops.isEmpty { body["stop"] = stops }
        if let responseFormat { body["response_format"] = responseFormat }
        if withTools {
            body["model"] = "mlx-community/Qwen3-8B-4bit"
            body["tools"] = [[
                "type": "function",
                "function": [
                    "name": "lookup",
                    "parameters": ["type": "object"],
                ],
            ]]
        }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    private struct Fixture: Decodable {
        let decodedSnapshots: [String]
        let tokenPieces: [String]
        let deliveredDeltas: [String]
        let deliveredContent: String
        let nonStreamContent: String
        let settlementOutputV1: SettlementOutput
        let expectedCanonical: String
        let expectedOutputHash: String

        struct SettlementOutput: Decodable { let content: String }
        var settlementContent: String { settlementOutputV1.content }
    }

    private static func loadFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("testdata/spec015/stream_cleanup_settlement.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }

    private static func receiptKeyID(_ publicKey: Data) -> String {
        "ed25519-sha256:" + SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }
}

private final class StreamingBindingKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey
    init(key: Curve25519.Signing.PrivateKey) { self.key = key }
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey { key }
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? { key }
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}
