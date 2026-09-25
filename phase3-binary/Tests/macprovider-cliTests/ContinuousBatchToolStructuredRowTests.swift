import XCTest
import MacProviderCore
@testable import macprovider_cli

/// SPEC-038 AC-6c: given identical generated text, a batched row's finalize
/// and stream produce exactly the serial path's `tool_calls`, SSE chunks and
/// structured-validation verdicts. The "serial" side of each test drives the
/// functions the serial `complete`/`stream` paths call, token by token, the
/// way their generate callbacks do.
final class ContinuousBatchToolStructuredRowTests: XCTestCase {
    private static let qwen = "mlx-community/Qwen3-8B-4bit"
    private static let stopTokenFilter = StopTokenFilter(tokens: ["<|im_end|>"])
    private static let weatherTool: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": "get_weather",
            "parameters": ["type": "object", "properties": ["city": ["type": "string"]]],
        ],
    ]]
    private static let schema: [String: Any] = [
        "type": "json_schema",
        "json_schema": [
            "name": "answer",
            "schema": [
                "type": "object",
                "properties": ["a": ["type": "integer"]],
                "required": ["a"],
                "additionalProperties": false,
            ],
        ],
    ]

    /// Two complete tool calls, one token per piece, then trailing text.
    private static let twoCallPieces: [String] = [
        "<tool_call>", "\n{\"name\": ", "\"get_weather\"", ", \"arguments\": ",
        "{\"city\": ", "\"Paris\"}", "}", "\n</tool_call>",
        "\n<tool_call>", "\n{\"name\": \"get_weather\", ", "\"arguments\": {\"city\": \"Rome\"}}",
        "\n</tool_call>", " trailing",
    ]

    // MARK: - fixtures

    private struct Vocab {
        let pieces: [String]
        var ids: [Int] { Array(pieces.indices) }
        func decode(_ ids: [Int]) -> String { ids.map { pieces[$0] }.joined() }
    }

    private func request(_ body: [String: Any]) throws -> ChatCompletionRequest {
        var dict = body
        dict["model"] = dict["model"] ?? Self.qwen
        dict["messages"] = dict["messages"] ?? [["role": "user", "content": "hi"]]
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: dict))
    }

    private func schedulerResult(
        _ ids: [Int],
        status: ContinuousBatchSchedulerTerminalStatus = .stop
    ) -> ContinuousBatchSchedulerResult {
        ContinuousBatchSchedulerResult(
            requestID: "r",
            conversationKey: "",
            generatedTokens: ids,
            outputTokens: ids,
            promptTokens: 3,
            completionTokens: ids.count,
            emittedTokens: ids.count,
            cachedPromptTokens: 0,
            terminalStatus: status,
            errorCode: nil,
            snapshot: nil,
            settlementDisposition: .eligibleOwner,
            retainedCache: nil
        )
    }

    private func finalizeBatched(
        _ request: ChatCompletionRequest,
        vocab: Vocab,
        ids: [Int],
        serialStopTokenCount: Int?,
        status: ContinuousBatchSchedulerTerminalStatus = .stop
    ) throws -> ModelRuntime.ContinuousBatchFinalizedRow {
        try ModelRuntime.finalizeContinuousBatchRow(
            request: request,
            result: schedulerResult(ids, status: status),
            modelStopTokenIDs: [],
            serialStopTokenCount: serialStopTokenCount,
            promptTokenIDs: [1, 2, 3],
            decode: vocab.decode,
            stopTokenFilter: Self.stopTokenFilter,
            generationMilliseconds: 0,
            modelHash: nil
        )
    }

    /// The serial non-streaming path: its generate callback stops a serial
    /// tool turn at the first complete valid tool call, then it parses and
    /// validates the text of the tokens it generated.
    private func serialComplete(
        _ request: ChatCompletionRequest,
        vocab: Vocab
    ) throws -> (completion: CompletionResult, tokenCount: Int) {
        var generated: [Int] = []
        var observer = NativeToolCallStreamEmitter(
            modelID: request.model,
            allowedFunctionNames: ModelRuntime.toolFunctionNames(from: request.promptSource.tools)
        )
        for id in vocab.ids {
            generated.append(id)
            if ModelRuntime.serialToolStopApplies(request),
               ModelRuntime.observeSerialToolStop(
                   &observer,
                   decoded: vocab.decode(generated),
                   stopTokenFilter: Self.stopTokenFilter,
                   requestStops: request.stop
               ) {
                break
            }
        }
        let filtered = ModelRuntime.applyOutputFilters(
            vocab.decode(generated),
            stopTokenFilter: Self.stopTokenFilter,
            requestStops: request.stop
        )
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: filtered.text,
            generatedTokenIDs: generated,
            decode: vocab.decode,
            request: request,
            mode: .complete(finishReason: filtered.hitStop ? "request_stop" : "stop"),
            defaultCompletionTokens: generated.count,
            stopTokenFilter: Self.stopTokenFilter,
            requestStops: request.stop,
            globalHitStop: filtered.hitStop
        )
        let completion = try ModelRuntime.validateStructuredCompletion(CompletionResult(
            content: parsed.content,
            finishReason: parsed.toolCalls.isEmpty ? "stop" : "tool_calls",
            promptTokens: 3,
            completionTokens: parsed.completionTokens,
            toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
            settlementDisposition: .eligibleOwner
        ), request: request)
        return (completion, generated.count)
    }

    /// The serial streaming path over the same tokens: one emitter step per
    /// token until it would stop generating, then its finish and the
    /// structured verdict on buyer-visible content.
    private func serialStream(
        _ request: ChatCompletionRequest,
        vocab: Vocab
    ) -> (chunks: [String], result: Result<CompletionResult, APIError>) {
        let accumulator = StructuredStreamingContentAccumulator(
            enabled: ModelRuntime.requiresStructuredValidation(request.responseFormat)
        )
        let idle = StructuredStreamingIdleState(enabled: false)
        let sink = ChunkSink()
        var emitter = SerialStreamingTextEmitter(request: request)
        var generated: [Int] = []
        loop: for id in vocab.ids {
            generated.append(id)
            let candidate = ModelRuntime.streamingSafePrefix(
                vocab.decode(generated),
                stopTokenFilter: Self.stopTokenFilter,
                requestStops: request.stop
            )
            switch emitter.step(
                candidate: candidate,
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: sink.append
            ) {
            case .more:
                continue
            case .requestStop, .toolCallComplete, .structuredError:
                break loop
            }
        }
        let final = ModelRuntime.applyOutputFilters(
            vocab.decode(generated),
            stopTokenFilter: Self.stopTokenFilter,
            requestStops: request.stop
        )
        do {
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: final.text,
                generatedTokenIDs: generated,
                decode: vocab.decode,
                request: request,
                mode: .complete(finishReason: "stop"),
                defaultCompletionTokens: generated.count,
                stopTokenFilter: Self.stopTokenFilter,
                requestStops: request.stop,
                globalHitStop: final.hitStop
            )
            try emitter.finish(
                finalText: final.text,
                parsed: parsed,
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: sink.append
            )
            let completion = try ModelRuntime.validateStructuredStreamingCompletion(
                CompletionResult(
                    content: parsed.content,
                    finishReason: parsed.toolCalls.isEmpty ? "stop" : "tool_calls",
                    promptTokens: 3,
                    completionTokens: parsed.completionTokens,
                    toolCalls: parsed.toolCalls.isEmpty ? nil : parsed.toolCalls,
                    settlementDisposition: .eligibleOwner
                ),
                request: request,
                buyerVisibleContent: accumulator.content
            )
            return (sink.normalized(), .success(completion))
        } catch {
            return (sink.normalized(), .failure(error as! APIError))
        }
    }

    /// The batched stream: every delivered token goes through the row's
    /// stream state (tokens past the serial stop point included, as a row
    /// may decode on before `stopEarly` lands), then the batched finalize.
    private func batchedStream(
        _ request: ChatCompletionRequest,
        vocab: Vocab,
        deliveredIDs: [Int]? = nil
    ) -> (chunks: [String], result: Result<CompletionResult, APIError>, stopRequests: Int, finalized: ModelRuntime.ContinuousBatchFinalizedRow?) {
        let accumulator = StructuredStreamingContentAccumulator(
            enabled: ModelRuntime.requiresStructuredValidation(request.responseFormat)
        )
        let idle = StructuredStreamingIdleState(enabled: false)
        let sink = ChunkSink()
        let state = ModelRuntime.AttachedPagedKVStreamState(request: request)
        let ids = deliveredIDs ?? vocab.ids
        var stopRequests = 0
        for id in ids where state.step(
            eventTokens: [id],
            decode: vocab.decode,
            stopTokenFilter: Self.stopTokenFilter,
            requestStops: request.stop,
            structuredAccumulator: accumulator,
            idleState: idle,
            onChunk: sink.append
        ) {
            stopRequests += 1
        }
        if let error = state.error() {
            return (sink.normalized(), .failure(error), stopRequests, nil)
        }
        do {
            let finalized = try finalizeBatched(
                request,
                vocab: vocab,
                ids: ids,
                serialStopTokenCount: state.serialStopTokenCount
            )
            let completion = try ModelRuntime.finishContinuousBatchStream(
                finalized,
                state: state,
                request: request,
                structuredAccumulator: accumulator,
                idleState: idle,
                onChunk: sink.append
            )
            return (sink.normalized(), .success(completion), stopRequests, finalized)
        } catch {
            return (sink.normalized(), .failure(error as! APIError), stopRequests, nil)
        }
    }

    private func calls(_ toolCalls: [macprovider_cli.ToolCall]?) -> [String] {
        (toolCalls ?? []).map { "\($0.functionName) \($0.arguments)" }
    }

    // MARK: - non-streaming tool calls

    func testSerialToolTurnTruncatesToSerialStopAndMatchesSerialToolCalls() throws {
        let request = try request(["tools": Self.weatherTool])
        let vocab = Vocab(pieces: Self.twoCallPieces)
        let serial = try serialComplete(request, vocab: vocab)
        XCTAssertLessThan(serial.tokenCount, vocab.pieces.count, "serial stops at the first complete call")

        // The batched row's sink runs the serial stop test on each token.
        let stop = ModelRuntime.ContinuousBatchSerialToolStopState(request: request)
        var stopRequests = 0
        for id in vocab.ids where stop.observe(
            eventTokens: [id],
            decode: vocab.decode,
            stopTokenFilter: Self.stopTokenFilter,
            requestStops: request.stop
        ) {
            stopRequests += 1
        }
        XCTAssertEqual(stopRequests, 1)
        XCTAssertEqual(stop.stopTokenCount, serial.tokenCount)

        // The row decoded every token before stopping; the finalize truncates.
        let batched = try finalizeBatched(
            request,
            vocab: vocab,
            ids: vocab.ids,
            serialStopTokenCount: stop.stopTokenCount,
            status: .length
        )
        let completion = try ModelRuntime.validateStructuredCompletion(batched.completion, request: request)
        XCTAssertEqual(calls(completion.toolCalls), calls(serial.completion.toolCalls))
        XCTAssertEqual(calls(completion.toolCalls), [#"get_weather {"city":"Paris"}"#])
        XCTAssertEqual(completion.finishReason, "tool_calls")
        XCTAssertEqual(completion.content, serial.completion.content)
        XCTAssertEqual(completion.completionTokens, serial.completion.completionTokens)
        XCTAssertEqual(completion.completionTokens, serial.tokenCount)
        XCTAssertEqual(batched.generatedTokens, Array(vocab.ids.prefix(serial.tokenCount)))
        XCTAssertTrue(batched.truncatedAtSerialStop, "a row past the stop point must not commit its cache")
    }

    func testParallelToolTurnKeepsEveryCallLikeSerial() throws {
        let request = try request(["tools": Self.weatherTool, "parallel_tool_calls": true])
        let vocab = Vocab(pieces: Self.twoCallPieces)
        let serial = try serialComplete(request, vocab: vocab)
        XCTAssertEqual(serial.tokenCount, vocab.pieces.count)
        XCTAssertFalse(ModelRuntime.serialToolStopApplies(request))

        let batched = try finalizeBatched(request, vocab: vocab, ids: vocab.ids, serialStopTokenCount: nil)
        let completion = try ModelRuntime.validateStructuredCompletion(batched.completion, request: request)
        XCTAssertEqual(calls(completion.toolCalls), calls(serial.completion.toolCalls))
        XCTAssertEqual(completion.toolCalls?.count, 2)
        XCTAssertEqual(completion.finishReason, "tool_calls")
        XCTAssertFalse(batched.truncatedAtSerialStop)
    }

    func testResponseByteCapMatchesSerialNonStreamingGuard() throws {
        let request = try request(["tools": Self.weatherTool])
        let vocab = Vocab(pieces: [String(repeating: "a", count: ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP + 1)])
        XCTAssertThrowsError(try finalizeBatched(request, vocab: vocab, ids: vocab.ids, serialStopTokenCount: nil)) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 502)
            XCTAssertEqual(apiError?.code, "response_byte_cap_exceeded")
            XCTAssertEqual(apiError?.message, "Model response exceeded 2097152 bytes")
        }
        let atCap = Vocab(pieces: [String(repeating: "a", count: ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP)])
        XCTAssertNoThrow(try finalizeBatched(request, vocab: atCap, ids: atCap.ids, serialStopTokenCount: nil))
    }

    // MARK: - non-streaming structured output

    func testStructuredVerdictsMatchSerialNonStreaming() throws {
        let request = try request(["response_format": Self.schema])
        let cases: [(pieces: [String], expectedCode: String?)] = [
            (["{\"a\"", ": 1}"], nil),
            (["{\"a\"", ": 1"], "malformed_json_response"),
            (["{\"a\"", ": \"x\"}"], "json_schema_validation_failed"),
        ]
        for testCase in cases {
            let vocab = Vocab(pieces: testCase.pieces)
            let serialCode = Self.apiCode { _ = try self.serialComplete(request, vocab: vocab) }
            let batchedCode = Self.apiCode {
                let row = try self.finalizeBatched(request, vocab: vocab, ids: vocab.ids, serialStopTokenCount: nil)
                _ = try ModelRuntime.validateStructuredCompletion(row.completion, request: request)
            }
            XCTAssertEqual(batchedCode, serialCode, "\(testCase.pieces)")
            XCTAssertEqual(serialCode, testCase.expectedCode, "\(testCase.pieces)")
        }
    }

    // MARK: - streaming

    func testStreamingToolTurnEmitsSerialToolDeltasAndStopsAtSerialToken() throws {
        let request = try request(["tools": Self.weatherTool])
        let vocab = Vocab(pieces: ["Checking. "] + Self.twoCallPieces)
        let serial = serialStream(request, vocab: vocab)
        let batched = batchedStream(request, vocab: vocab)

        XCTAssertEqual(batched.chunks, serial.chunks)
        XCTAssertTrue(batched.chunks.contains("tool:get_weather:"), "\(batched.chunks)")
        XCTAssertFalse(batched.chunks.contains { $0.hasPrefix("content:") && $0.contains("<tool_call>") })
        XCTAssertEqual(batched.chunks.first, "content:Checking. ")
        XCTAssertEqual(batched.stopRequests, 1)
        let serialCompletion = try serial.result.get()
        let batchedCompletion = try batched.result.get()
        XCTAssertEqual(calls(batchedCompletion.toolCalls), calls(serialCompletion.toolCalls))
        XCTAssertEqual(batchedCompletion.finishReason, "tool_calls")
        XCTAssertEqual(batchedCompletion.completionTokens, serialCompletion.completionTokens)
        XCTAssertEqual(batched.finalized?.truncatedAtSerialStop, true)
    }

    func testStreamingOversizedToolArgumentsStreamNothingLikeSerial() throws {
        let request = try request(["tools": Self.weatherTool])
        let big = String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP + 1)
        let vocab = Vocab(pieces: [
            "<tool_call>\n{\"name\": \"get_weather\", \"arguments\": {\"city\": \"", big, "\"}}\n</tool_call>",
        ])
        let serial = serialStream(request, vocab: vocab)
        let batched = batchedStream(request, vocab: vocab)
        XCTAssertEqual(batched.chunks, serial.chunks)
        // The serial emitter opens the call on the first piece and then
        // closes on the over-cap arguments: nothing past the cap, and no
        // tool markup as assistant content.
        XCTAssertEqual(batched.chunks, ["tool:get_weather:", "args:0:{\"city\": \""])
        XCTAssertFalse(batched.chunks.contains { $0.hasPrefix("content:") })
        XCTAssertNil(try batched.result.get().toolCalls)
        XCTAssertEqual(try batched.result.get().finishReason, try serial.result.get().finishReason)
    }

    func testStreamingInvalidJSONUnderJSONSchemaMatchesSerialChunksAndError() throws {
        let request = try request(["response_format": Self.schema])
        // The trailing "<" is held back as a possible stop-token prefix and
        // only sent by the stream's end, before the structured verdict.
        let vocab = Vocab(pieces: ["{\"a\"", ": 1}", "<"])
        let serial = serialStream(request, vocab: vocab)
        let batched = batchedStream(request, vocab: vocab)
        XCTAssertEqual(batched.chunks, serial.chunks)
        XCTAssertEqual(batched.chunks, ["content:{\"a\"", "content:: 1}", "content:<"])
        guard case .failure(let serialError) = serial.result,
              case .failure(let batchedError) = batched.result else {
            return XCTFail("both paths must reject invalid JSON: \(serial.result) \(batched.result)")
        }
        XCTAssertEqual(batchedError.code, serialError.code)
        XCTAssertEqual(batchedError.status, serialError.status)
    }

    func testStreamingSchemaMismatchAndValidJSONMatchSerial() throws {
        let request = try request(["response_format": Self.schema])
        for pieces in [["{\"a\"", ": \"x\"}"], ["{\"a\"", ": 1}"]] {
            let vocab = Vocab(pieces: pieces)
            let serial = serialStream(request, vocab: vocab)
            let batched = batchedStream(request, vocab: vocab)
            XCTAssertEqual(batched.chunks, serial.chunks)
            switch (serial.result, batched.result) {
            case (.success(let s), .success(let b)):
                XCTAssertEqual(b.content, s.content)
            case (.failure(let s), .failure(let b)):
                XCTAssertEqual(b.code, s.code)
            default:
                XCTFail("verdicts differ: \(serial.result) \(batched.result)")
            }
        }
    }

    func testStreamingStructuredByteCapStopsRowWithSerialError() throws {
        let request = try request(["response_format": ["type": "json_object"]])
        let over = String(repeating: "1", count: ModelRuntime.structuredStreamingValidationBufferByteCap)
        let vocab = Vocab(pieces: ["[", over, "]"])
        let serial = serialStream(request, vocab: vocab)
        let batched = batchedStream(request, vocab: vocab)
        XCTAssertEqual(batched.chunks, serial.chunks)
        XCTAssertEqual(batched.stopRequests, 1)
        guard case .failure(let serialError) = serial.result,
              case .failure(let batchedError) = batched.result else {
            return XCTFail("both paths must fail the structured stream cap")
        }
        XCTAssertEqual(batchedError.code, "response_byte_cap_exceeded")
        XCTAssertEqual(batchedError.code, serialError.code)
    }

    // MARK: - helpers

    private static func apiCode(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as APIError {
            return error.code
        } catch {
            return "non_api_error:\(error)"
        }
    }
}

/// Normalized SSE-relevant chunks: tool-call ids are random per emitter, so
/// the first delta records only its function name.
private final class ChunkSink: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [StreamChunk] = []

    func append(_ chunk: StreamChunk) {
        lock.lock()
        chunks.append(chunk)
        lock.unlock()
    }

    func normalized() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return chunks.map { chunk in
            switch chunk {
            case .content(let text):
                return "content:\(text)"
            case .toolCallDelta(let delta):
                if let name = delta.functionName {
                    return "tool:\(name):\(delta.arguments ?? "")"
                }
                return "args:\(delta.index):\(delta.arguments ?? "")"
            }
        }
    }
}
