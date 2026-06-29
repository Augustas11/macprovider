import Foundation
import MacProviderCore

actor InferenceRelay {
    typealias SendFrame = @Sendable (sending [String: Any]) async throws -> Void

    private struct ActiveRequest {
        let task: Task<Void, Never>
        let state: RelayRequestState
    }

    private let modelRuntime: any ModelRuntimeServing
    private let providerStatus: ProviderStatus
    private let loadedModelID: String?
    private let warmSwapEnabled: Bool
    private let maxActiveRequests: Int
    private let maxBodyBytes: Int
    private let sendFrame: SendFrame
    private let tier2Session: Tier2ProviderSession?
    private let receiptBuilder: ReceiptBuilder?
    private let receiptProviderID: String?
    private var active: [String: ActiveRequest] = [:]

    init(
        modelRuntime: any ModelRuntimeServing,
        providerStatus: ProviderStatus,
        loadedModelID: String?,
        warmSwapEnabled: Bool = false,
        maxActiveRequests: Int,
        maxBodyBytes: Int,
        tier2Session: Tier2ProviderSession? = nil,
        receiptBuilder: ReceiptBuilder? = nil,
        receiptProviderID: String? = nil,
        sendFrame: @escaping SendFrame
    ) {
        self.modelRuntime = modelRuntime
        self.providerStatus = providerStatus
        self.loadedModelID = loadedModelID
        self.warmSwapEnabled = warmSwapEnabled
        self.maxActiveRequests = max(1, maxActiveRequests)
        self.maxBodyBytes = max(1, maxBodyBytes)
        self.tier2Session = tier2Session
        self.receiptBuilder = receiptBuilder
        self.receiptProviderID = receiptProviderID
        self.sendFrame = sendFrame
    }

    func handleInferenceRequest(_ message: [String: Any]) async throws {
        guard let requestID = message["request_id"] as? String, !requestID.isEmpty,
              let stream = message["stream"] as? Bool
        else {
            try await sendNAK(inReplyTo: "inference_request", code: "invalid_message", message: "inference_request requires request_id, stream, and body")
            return
        }
        let body: String
        if let tier2Session {
            guard message["encrypted"] as? Bool == true else {
                try await sendNAK(inReplyTo: requestID, code: "tier2_encrypted_frame_required", message: "Tier-2 session requires encrypted inference_request frames")
                return
            }
            do {
                body = try tier2Session.openRequestBody(message: message, requestID: requestID, stream: stream)
            } catch {
                try await sendNAK(inReplyTo: requestID, code: "tier2_aead_decrypt_failed", message: "Encrypted inference_request failed authentication")
                return
            }
        } else if let cleartextBody = message["body"] as? String {
            body = cleartextBody
        } else {
            try await sendNAK(inReplyTo: "inference_request", code: "invalid_message", message: "inference_request requires request_id, stream, and body")
            return
        }

        guard active[requestID] == nil else {
            try await sendNAK(inReplyTo: "inference_request", code: "duplicate_request_id", message: "Duplicate active request_id: \(requestID)")
            return
        }

        guard active.count < maxActiveRequests else {
            try await Self.sendEndFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "error_queue_full",
                "chunks_sent": 0,
                "error": "Provider request queue is full",
            ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            return
        }

        guard body.utf8.count <= maxBodyBytes else {
            try await Self.sendEndFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "error_context_exceeded",
                "chunks_sent": 0,
                "error": "Request body exceeds provider limit",
            ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            return
        }

        let state = RelayRequestState()
        let receiptBuilder = receiptBuilder
        let receiptProviderID = receiptProviderID
        let task = Task { [weak self, modelRuntime, providerStatus, loadedModelID, warmSwapEnabled, sendFrame, tier2Session, state] in
            await Self.process(
                requestID: requestID,
                body: body,
                stream: stream,
                state: state,
                modelRuntime: modelRuntime,
                providerStatus: providerStatus,
                loadedModelID: loadedModelID,
                warmSwapEnabled: warmSwapEnabled,
                tier2Session: tier2Session,
                receiptBuilder: receiptBuilder,
                receiptProviderID: receiptProviderID,
                sendFrame: sendFrame
            )
            await self?.removeActive(requestID)
        }
        active[requestID] = ActiveRequest(task: task, state: state)
    }

    func handleCancelRequest(_ message: [String: Any]) async throws {
        guard let requestID = message["request_id"] as? String, !requestID.isEmpty else {
            try await sendNAK(inReplyTo: "cancel_request", code: "invalid_message", message: "cancel_request requires request_id")
            return
        }

        guard let request = active[requestID] else {
            if tier2Session != nil {
                return
            }
            try await sendFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "cancelled",
                "chunks_sent": 0,
                "usage": Self.zeroUsage(),
            ])
            return
        }

        request.state.cancel()
    }

    func cancelAll() {
        for request in active.values {
            request.state.cancel()
            request.task.cancel()
        }
    }

    func cancelAllAndClear() {
        cancelAll()
        active.removeAll()
    }

    func waitUntilIdle(timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, timeoutSeconds)))
        while !active.isEmpty {
            if Date() >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    private func removeActive(_ requestID: String) {
        active.removeValue(forKey: requestID)
    }

    private func sendNAK(inReplyTo: String, code: String, message: String) async throws {
        try await sendFrame([
            "type": "nak",
            "in_reply_to": inReplyTo,
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    private static func process(
        requestID: String,
        body: String,
        stream: Bool,
        state: RelayRequestState,
        modelRuntime: any ModelRuntimeServing,
        providerStatus: ProviderStatus,
        loadedModelID: String?,
        warmSwapEnabled: Bool,
        tier2Session: Tier2ProviderSession?,
        receiptBuilder: ReceiptBuilder?,
        receiptProviderID: String?,
        sendFrame: @escaping SendFrame
    ) async {
        let startedAt = await providerStatus.beginRequest(requestID: requestID)
        var completionResult: CompletionResult?
        var failed = false

        do {
            let requestData = Data(body.utf8)
            let request = try ChatCompletionRequest.parse(data: requestData)
            let validationModelID = warmSwapEnabled
                ? await modelRuntime.currentSnapshot().modelID
                : loadedModelID
            try request.validateModelMatches(validationModelID)
            if stream {
                completionResult = try await processStreaming(
                    requestID: requestID,
                    request: request,
                    state: state,
                    modelRuntime: modelRuntime,
                    tier2Session: tier2Session,
                    sendFrame: sendFrame
                )
            } else {
                completionResult = try await processNonStreaming(
                    requestID: requestID,
                    request: request,
                    state: state,
                    modelRuntime: modelRuntime,
                    tier2Session: tier2Session,
                    receiptBuilder: receiptBuilder,
                    receiptProviderID: receiptProviderID,
                    startedAt: startedAt,
                    warmSwapEnabled: warmSwapEnabled,
                    sendFrame: sendFrame
                )
            }
        } catch is RelayCancellationAcknowledged {
        } catch is CancellationError {
            if state.markTerminalSent() {
                try? await sendEndFrame([
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "cancelled",
                    "chunks_sent": state.chunksSent,
                    "usage": state.usage ?? zeroUsage(),
                ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            }
        } catch let error as APIError {
            failed = true
            if state.markTerminalSent() {
                try? await sendEndFrame(errorEndFrame(requestID: requestID, error: error, chunksSent: state.chunksSent), requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            }
        } catch {
            failed = true
            if state.markTerminalSent() {
                try? await sendEndFrame([
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "error_internal",
                    "chunks_sent": state.chunksSent,
                    "error": String(describing: error),
                ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            }
        }
        await providerStatus.finishRequest(
            startedAt: startedAt,
            completion: completionResult,
            failed: failed,
            requestID: requestID
        )
    }

    private static func processNonStreaming(
        requestID: String,
        request: ChatCompletionRequest,
        state: RelayRequestState,
        modelRuntime: any ModelRuntimeServing,
        tier2Session: Tier2ProviderSession?,
        receiptBuilder: ReceiptBuilder?,
        receiptProviderID: String?,
        startedAt: Date,
        warmSwapEnabled: Bool,
        sendFrame: @escaping SendFrame
    ) async throws -> CompletionResult {
        // SPEC-015 §M.2.2 atomic-read invariant — bind the receipt
        // to the snapshot the runtime ACTUALLY used to drive
        // generation, not to a separately-sampled `currentSnapshot()`
        // which can drift across an actor interleaving / warm-swap.
        let (completion, servedSnapshot) = try await modelRuntime.completeWithServedSnapshot(request, shouldCancel: { state.isCancelled })
        let modelHashSource = RouterHandler.resolveModelHashSource(
            warmSwapEnabled: warmSwapEnabled,
            snapshot: servedSnapshot
        )
        let unixTsSeconds = Int64(Date().timeIntervalSince1970)
        state.setUsage(completion)
        if state.isCancelled {
            if state.markTerminalSent() {
                try await sendEndFrame([
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "cancelled",
                    "chunks_sent": state.chunksSent,
                    "usage": usage(completion),
                ], requestID: requestID, stream: false, tier2Session: tier2Session, sendFrame: sendFrame)
            }
            return completion
        }
        guard !state.terminalSent else {
            return completion
        }
        let response = try jsonString(chatCompletionResponse(request: request, completion: completion))
        let seq = state.nextSeq()
        try await sendChunk(requestID: requestID, stream: false, seq: seq, data: response, tier2Session: tier2Session, sendFrame: sendFrame)
        let ttftMs = completion.ttftMilliseconds ?? Self.elapsedMilliseconds(since: startedAt)
        let receiptHeader = Self.buildReceiptHeader(
            receiptBuilder: receiptBuilder,
            providerID: receiptProviderID,
            request: request,
            completion: completion,
            ttftMs: ttftMs,
            unixTsSeconds: unixTsSeconds,
            requestID: requestID,
            modelHashSource: modelHashSource
        )
        if state.markTerminalSent() {
            var endFrame: [String: Any] = [
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "complete",
                "chunks_sent": state.chunksSent,
                "usage": usage(completion),
            ]
            if let receiptHeader {
                endFrame["receipt"] = receiptHeader
            }
            try await sendEndFrame(endFrame, requestID: requestID, stream: false, tier2Session: tier2Session, sendFrame: sendFrame)
        }
        return completion
    }

    private static func buildReceiptHeader(
        receiptBuilder: ReceiptBuilder?,
        providerID: String?,
        request: ChatCompletionRequest,
        completion: CompletionResult,
        ttftMs: Int64,
        unixTsSeconds: Int64,
        requestID: String,
        modelHashSource: ReceiptModelHashSource
    ) -> String? {
        guard let receiptBuilder, let providerID, !providerID.isEmpty else {
            return nil
        }
        // SPEC-015 §M.2.2 — refuse receipt construction when the
        // request-start container cannot be identified.
        let resolvedModelHash: String?
        switch modelHashSource {
        case .captured(let hash):
            resolvedModelHash = hash
        case .warmSwapDisabled:
            resolvedModelHash = nil
        case .ambiguous:
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .modelSwapViolation)
            return nil
        }
        do {
            return try receiptBuilder.build(
                providerId: providerID,
                input: ReceiptInput(
                    modelId: request.model,
                    request: request,
                    outputContent: completion.content,
                    outputToolCalls: completion.toolCalls,
                    finishReason: completion.finishReason,
                    ttftMs: ttftMs,
                    tokensOut: Int64(completion.completionTokens),
                    unixTsSeconds: unixTsSeconds,
                    modelHash: resolvedModelHash
                )
            )
        } catch {
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .constructionFailed)
            return nil
        }
    }

    private static func elapsedMilliseconds(since start: Date, now: Date = Date()) -> Int64 {
        max(0, Int64(now.timeIntervalSince(start) * 1000))
    }

    private static func processStreaming(
        requestID: String,
        request: ChatCompletionRequest,
        state: RelayRequestState,
        modelRuntime: any ModelRuntimeServing,
        tier2Session: Tier2ProviderSession?,
        sendFrame: @escaping SendFrame
    ) async throws -> CompletionResult {
        let created = Int(Date().timeIntervalSince1970)
        let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let buffer = BlockingChunkBuffer(capacity: 256, resumeAt: 128)
        state.setBuffer(buffer)

        let consumer = Task<Int, Error> {
            while let data = buffer.next() {
                try Task.checkCancellation()
                guard !state.terminalSent else {
                    continue
                }
                let seq = state.nextSeq()
                try await sendChunk(requestID: requestID, stream: true, seq: seq, data: data, tier2Session: tier2Session, sendFrame: sendFrame)
            }
            return state.chunksSent
        }

        do {
            let handle = try await modelRuntime.acquireRequestHandle(request)
            defer {
                Task { await modelRuntime.unregisterInFlight(handle.registrationID) }
            }
            _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                id: id,
                created: created,
                model: request.model,
                delta: ["role": "assistant", "content": ""],
                finishReason: NSNull()
            )))

            let streamedAnyToolCallDelta = StreamedFlag()
            let completion = try await modelRuntime.stream(request, with: handle, shouldCancel: { state.isCancelled }) { chunk in
                switch chunk {
                case .content(let text):
                    _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                        id: id,
                        created: created,
                        model: request.model,
                        delta: ["content": text],
                        finishReason: NSNull()
                    )))
                case .toolCallDelta(let toolDelta):
                    streamedAnyToolCallDelta.set()
                    _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                        id: id,
                        created: created,
                        model: request.model,
                        delta: ["tool_calls": [toolDelta.openAIDeltaDict()]],
                        finishReason: NSNull()
                    )))
                }
            }

            state.setUsage(completion)
            if state.isCancelled {
                buffer.cancel()
                consumer.cancel()
                let chunksSent = (try? await consumer.value) ?? state.chunksSent
                if state.markTerminalSent() {
                    try await sendEndFrame([
                        "type": "inference_response_end",
                        "request_id": requestID,
                        "status": "cancelled",
                        "chunks_sent": chunksSent,
                        "usage": usage(completion),
                    ], requestID: requestID, stream: true, tier2Session: tier2Session, sendFrame: sendFrame)
                }
                return completion
            }

            // Fallback for non-streaming-incremental path: if tool calls landed only
            // in the final CompletionResult and were never streamed via .toolCallDelta
            // chunks, emit them now.
            if !streamedAnyToolCallDelta.get(), let toolCalls = completion.toolCalls, !toolCalls.isEmpty {
                for delta in toolCallDeltaChunks(toolCalls) {
                    _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                        id: id,
                        created: created,
                        model: request.model,
                        delta: ["tool_calls": delta],
                        finishReason: NSNull()
                    )))
                }
            }

            _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                id: id,
                created: created,
                model: request.model,
                delta: [:],
                finishReason: completion.finishReason
            )))
            _ = buffer.enqueue(sseEvent([
                "id": id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": request.model,
                "choices": [],
                "usage": usage(completion),
            ]))
            _ = buffer.enqueue("data: [DONE]\n\n")
            buffer.finish()

            let chunksSent = try await consumer.value
            if state.markTerminalSent() {
                try await sendEndFrame([
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "complete",
                    "chunks_sent": chunksSent,
                    "usage": usage(completion),
                ], requestID: requestID, stream: true, tier2Session: tier2Session, sendFrame: sendFrame)
            }
            return completion
        } catch {
            buffer.cancel()
            consumer.cancel()
            if error is CancellationError {
                let chunksSent = (try? await consumer.value) ?? state.chunksSent
                if state.markTerminalSent() {
                    try? await sendEndFrame([
                        "type": "inference_response_end",
                        "request_id": requestID,
                        "status": "cancelled",
                        "chunks_sent": chunksSent,
                        "usage": state.usage ?? zeroUsage(),
                    ], requestID: requestID, stream: true, tier2Session: tier2Session, sendFrame: sendFrame)
                }
                throw RelayCancellationAcknowledged()
            }
            throw error
        }
    }

    static func errorEndFrame(requestID: String, error: APIError, chunksSent: Int) -> [String: Any] {
        let status: String
        switch error.code {
        case "model_not_loaded", "model_not_found":
            status = "error_model_not_loaded"
        case "context_length_exceeded":
            status = "error_context_exceeded"
        case "queue_full":
            status = "error_queue_full"
        case "malformed_json_response", "json_schema_validation_failed":
            status = error.code
        default:
            status = "error_internal"
        }
        var frame: [String: Any] = [
            "type": "inference_response_end",
            "request_id": requestID,
            "status": status,
            "chunks_sent": chunksSent,
            "error": error.message,
        ]
        if error.code == "malformed_json_response" || error.code == "json_schema_validation_failed" {
            frame["retryable"] = (error.envelope["error"] as? [String: Any])?["retryable"] as? Bool
        }
        return frame
    }

    private static func sendChunk(
        requestID: String,
        stream: Bool,
        seq: Int,
        data: String,
        tier2Session: Tier2ProviderSession?,
        sendFrame: @escaping SendFrame
    ) async throws {
        if let tier2Session {
            try await sendFrame(tier2Session.sealResponseChunk(requestID: requestID, stream: stream, plaintext: data))
            return
        }
        try await sendFrame([
            "type": "inference_response_chunk",
            "request_id": requestID,
            "seq": seq,
            "data": data,
        ])
    }

    private static func sendEndFrame(
        _ frame: sending [String: Any],
        requestID: String,
        stream: Bool,
        tier2Session: Tier2ProviderSession?,
        sendFrame: @escaping SendFrame
    ) async throws {
        if let tier2Session {
            try await sendFrame(tier2Session.sealResponseEnd(requestID: requestID, stream: stream, payload: frame))
            return
        }
        try await sendFrame(frame)
    }

    private static func chatCompletionResponse(request: ChatCompletionRequest, completion: CompletionResult) -> [String: Any] {
        let created = Int(Date().timeIntervalSince1970)
        return [
            "id": "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
            "object": "chat.completion",
            "created": created,
            "model": request.model,
            "choices": [
                [
                    "index": 0,
                    "message": chatCompletionMessage(completion),
                    "finish_reason": completion.finishReason,
                ]
            ],
            "usage": usage(completion),
        ]
    }

    private static func chatCompletionChunk(
        id: String,
        created: Int,
        model: String,
        delta: [String: Any],
        finishReason: Any
    ) -> [String: Any] {
        [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [
                [
                    "index": 0,
                    "delta": delta,
                    "finish_reason": finishReason,
                ]
            ],
        ]
    }

    private static func chatCompletionMessage(_ completion: CompletionResult) -> [String: Any] {
        let toolCalls = completion.toolCalls?.isEmpty == false ? completion.toolCalls : nil
        var message: [String: Any] = [
            "role": "assistant",
            "content": toolCalls == nil ? completion.content : NSNull(),
        ]
        if let toolCalls {
            message["tool_calls"] = toolCalls.map(\.openAIObject)
        }
        return message
    }

    private static func toolCallDeltaChunks(_ toolCalls: [ToolCall]) -> [[[String: Any]]] {
        var chunks: [[[String: Any]]] = []
        for (index, call) in toolCalls.enumerated() {
            chunks.append([call.openAIInitialDelta(index: index)])
            for fragment in splitArguments(call.arguments) {
                chunks.append([call.openAIArgumentsDelta(index: index, fragment: fragment)])
            }
        }
        return chunks
    }

    private static func splitArguments(_ arguments: String, chunkBytes: Int = 2048) -> [String] {
        guard !arguments.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var currentBytes = 0
        for scalar in arguments.unicodeScalars {
            let scalarString = String(scalar)
            let scalarBytes = scalarString.utf8.count
            if currentBytes > 0, currentBytes + scalarBytes > chunkBytes {
                result.append(current)
                current = ""
                currentBytes = 0
            }
            current += scalarString
            currentBytes += scalarBytes
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func usage(_ completion: CompletionResult) -> [String: Any] {
        [
            "prompt_tokens": completion.promptTokens,
            "completion_tokens": completion.completionTokens,
            "total_tokens": completion.promptTokens + completion.completionTokens,
            "macprovider_model_hash_observed": completion.modelHashObserved ?? NSNull(),
        ]
    }

    private static func zeroUsage() -> [String: Any] {
        [
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "total_tokens": 0,
            "macprovider_model_hash_observed": NSNull(),
        ]
    }

    private static func sseEvent(_ body: Any) -> String {
        do {
            return "data: \(try jsonString(body))\n\n"
        } catch {
            return #"data: {"error":{"message":"Inference engine error","type":"server_error","code":"internal_error"}}"# + "\n\n"
        }
    }

    private static func jsonString(_ body: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

private struct RelayCancellationAcknowledged: Error {}

private final class RelayRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: BlockingChunkBuffer?
    private var terminal = false
    private var sentChunks = 0
    private var cancelled = false
    private var currentUsage: [String: Any]?

    var terminalSent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }

    var chunksSent: Int {
        lock.lock()
        defer { lock.unlock() }
        return sentChunks
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var usage: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return currentUsage
    }

    func setUsage(_ completion: CompletionResult) {
        lock.lock()
        currentUsage = [
            "prompt_tokens": completion.promptTokens,
            "completion_tokens": completion.completionTokens,
            "total_tokens": completion.promptTokens + completion.completionTokens,
        ]
        lock.unlock()
    }

    func setBuffer(_ buffer: BlockingChunkBuffer) {
        lock.lock()
        self.buffer = buffer
        let shouldCancel = terminal
        lock.unlock()
        if shouldCancel {
            buffer.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let buffer = buffer
        lock.unlock()
        buffer?.cancel()
    }

    func nextSeq() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let seq = sentChunks
        sentChunks += 1
        return seq
    }

    func markTerminalSent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else {
            return false
        }
        terminal = true
        return true
    }
}

private final class BlockingChunkBuffer: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private let resumeAt: Int
    private var queue: [String] = []
    private var closed = false
    private var cancelled = false

    init(capacity: Int, resumeAt: Int) {
        self.capacity = max(1, capacity)
        self.resumeAt = max(0, min(resumeAt, capacity))
    }

    func enqueue(_ value: String) -> Bool {
        condition.lock()
        defer {
            condition.unlock()
        }

        while queue.count >= capacity && !closed && !cancelled {
            condition.wait()
        }
        guard !closed, !cancelled else {
            return false
        }
        queue.append(value)
        condition.signal()
        return true
    }

    func next() -> String? {
        condition.lock()
        defer {
            condition.unlock()
        }

        while queue.isEmpty && !closed && !cancelled {
            condition.wait()
        }
        guard !queue.isEmpty else {
            return nil
        }
        let value = queue.removeFirst()
        if queue.count <= resumeAt {
            condition.broadcast()
        } else {
            condition.signal()
        }
        return value
    }

    func finish() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}
