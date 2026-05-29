import Foundation
import MacProviderCore

actor InferenceRelay {
    typealias SendFrame = ([String: Any]) async throws -> Void

    private struct ActiveRequest {
        let task: Task<Void, Never>
        let state: RelayRequestState
    }

    private let modelRuntime: any ModelRuntimeServing
    private let providerStatus: ProviderStatus
    private let loadedModelID: String?
    private let maxActiveRequests: Int
    private let maxBodyBytes: Int
    private let sendFrame: SendFrame
    private var active: [String: ActiveRequest] = [:]

    init(
        modelRuntime: any ModelRuntimeServing,
        providerStatus: ProviderStatus,
        loadedModelID: String?,
        maxActiveRequests: Int,
        maxBodyBytes: Int,
        sendFrame: @escaping SendFrame
    ) {
        self.modelRuntime = modelRuntime
        self.providerStatus = providerStatus
        self.loadedModelID = loadedModelID
        self.maxActiveRequests = max(1, maxActiveRequests)
        self.maxBodyBytes = max(1, maxBodyBytes)
        self.sendFrame = sendFrame
    }

    func handleInferenceRequest(_ message: [String: Any]) async throws {
        guard let requestID = message["request_id"] as? String, !requestID.isEmpty,
              let stream = message["stream"] as? Bool,
              let body = message["body"] as? String
        else {
            try await sendNAK(inReplyTo: "inference_request", code: "invalid_message", message: "inference_request requires request_id, stream, and body")
            return
        }

        guard active[requestID] == nil else {
            try await sendNAK(inReplyTo: "inference_request", code: "duplicate_request_id", message: "Duplicate active request_id: \(requestID)")
            return
        }

        guard active.count < maxActiveRequests else {
            try await sendFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "error_queue_full",
                "chunks_sent": 0,
                "error": "Provider request queue is full",
            ])
            return
        }

        guard body.utf8.count <= maxBodyBytes else {
            try await sendFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "error_context_exceeded",
                "chunks_sent": 0,
                "error": "Request body exceeds provider limit",
            ])
            return
        }

        let state = RelayRequestState()
        let task = Task { [modelRuntime, providerStatus, loadedModelID, sendFrame, state] in
            await Self.process(
                requestID: requestID,
                body: body,
                stream: stream,
                state: state,
                modelRuntime: modelRuntime,
                providerStatus: providerStatus,
                loadedModelID: loadedModelID,
                sendFrame: sendFrame
            )
            await self.removeActive(requestID)
        }
        active[requestID] = ActiveRequest(task: task, state: state)
    }

    func handleCancelRequest(_ message: [String: Any]) async throws {
        guard let requestID = message["request_id"] as? String, !requestID.isEmpty else {
            try await sendNAK(inReplyTo: "cancel_request", code: "invalid_message", message: "cancel_request requires request_id")
            return
        }

        guard let request = active[requestID] else {
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
        sendFrame: @escaping SendFrame
    ) async {
        let startedAt = await providerStatus.beginRequest(requestID: requestID)
        var completionResult: CompletionResult?
        var failed = false

        do {
            let requestData = Data(body.utf8)
            let request = try ChatCompletionRequest.parse(data: requestData)
            try request.validateModelMatches(loadedModelID)
            if stream {
                completionResult = try await processStreaming(
                    requestID: requestID,
                    request: request,
                    state: state,
                    modelRuntime: modelRuntime,
                    sendFrame: sendFrame
                )
            } else {
                completionResult = try await processNonStreaming(
                    requestID: requestID,
                    request: request,
                    state: state,
                    modelRuntime: modelRuntime,
                    sendFrame: sendFrame
                )
            }
        } catch is RelayCancellationAcknowledged {
        } catch is CancellationError {
            if state.markTerminalSent() {
                try? await sendFrame([
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "cancelled",
                    "chunks_sent": state.chunksSent,
                    "usage": state.usage ?? zeroUsage(),
                ])
            }
        } catch let error as APIError {
            failed = true
            if state.markTerminalSent() {
                try? await sendFrame(errorEndFrame(requestID: requestID, error: error, chunksSent: state.chunksSent))
            }
        } catch {
            failed = true
            if state.markTerminalSent() {
                try? await sendFrame([
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "error_internal",
                    "chunks_sent": state.chunksSent,
                    "error": String(describing: error),
                ])
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
        sendFrame: @escaping SendFrame
    ) async throws -> CompletionResult {
        let completion = try await modelRuntime.complete(request, shouldCancel: { state.isCancelled })
        state.setUsage(completion)
        if state.isCancelled {
            if state.markTerminalSent() {
                try await sendFrame([
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "cancelled",
                    "chunks_sent": state.chunksSent,
                    "usage": usage(completion),
                ])
            }
            return completion
        }
        guard !state.terminalSent else {
            return completion
        }
        let response = try jsonString(chatCompletionResponse(request: request, completion: completion))
        _ = state.nextSeq()
        try await sendFrame([
            "type": "inference_response_chunk",
            "request_id": requestID,
            "seq": 0,
            "data": response,
        ])
        if state.markTerminalSent() {
            try await sendFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "complete",
                "chunks_sent": state.chunksSent,
                "usage": usage(completion),
            ])
        }
        return completion
    }

    private static func processStreaming(
        requestID: String,
        request: ChatCompletionRequest,
        state: RelayRequestState,
        modelRuntime: any ModelRuntimeServing,
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
                try await sendFrame([
                    "type": "inference_response_chunk",
                    "request_id": requestID,
                    "seq": seq,
                    "data": data,
                ])
            }
            return state.chunksSent
        }

        do {
            _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                id: id,
                created: created,
                model: request.model,
                delta: ["role": "assistant", "content": ""],
                finishReason: NSNull()
            )))

            let completion = try await modelRuntime.stream(request, shouldCancel: { state.isCancelled }) { chunk in
                _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                    id: id,
                    created: created,
                    model: request.model,
                    delta: ["content": chunk],
                    finishReason: NSNull()
                )))
            }

            state.setUsage(completion)
            if state.isCancelled {
                buffer.cancel()
                consumer.cancel()
                let chunksSent = (try? await consumer.value) ?? state.chunksSent
                if state.markTerminalSent() {
                    try await sendFrame([
                        "type": "inference_response_end",
                        "request_id": requestID,
                        "status": "cancelled",
                        "chunks_sent": chunksSent,
                        "usage": usage(completion),
                    ])
                }
                return completion
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
                try await sendFrame([
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "complete",
                    "chunks_sent": chunksSent,
                    "usage": usage(completion),
                ])
            }
            return completion
        } catch {
            buffer.cancel()
            consumer.cancel()
            if error is CancellationError {
                let chunksSent = (try? await consumer.value) ?? state.chunksSent
                if state.markTerminalSent() {
                    try? await sendFrame([
                        "type": "inference_response_end",
                        "request_id": requestID,
                        "status": "cancelled",
                        "chunks_sent": chunksSent,
                        "usage": state.usage ?? zeroUsage(),
                    ])
                }
                throw RelayCancellationAcknowledged()
            }
            throw error
        }
    }

    private static func errorEndFrame(requestID: String, error: APIError, chunksSent: Int) -> [String: Any] {
        let status: String
        switch error.code {
        case "model_not_loaded", "model_not_found":
            status = "error_model_not_loaded"
        case "context_length_exceeded":
            status = "error_context_exceeded"
        case "queue_full":
            status = "error_queue_full"
        default:
            status = "error_internal"
        }
        return [
            "type": "inference_response_end",
            "request_id": requestID,
            "status": status,
            "chunks_sent": chunksSent,
            "error": error.message,
        ]
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
                    "message": [
                        "role": "assistant",
                        "content": completion.content,
                    ],
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

    private static func usage(_ completion: CompletionResult) -> [String: Any] {
        [
            "prompt_tokens": completion.promptTokens,
            "completion_tokens": completion.completionTokens,
            "total_tokens": completion.promptTokens + completion.completionTokens,
        ]
    }

    private static func zeroUsage() -> [String: Any] {
        [
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "total_tokens": 0,
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
