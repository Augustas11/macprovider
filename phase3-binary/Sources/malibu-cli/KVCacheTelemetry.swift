import Foundation

private final class KVCacheTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (Data) -> Void = { record in
        FileHandle.standardError.write(record)
    }

    func emit(_ record: Data) {
        let current: @Sendable (Data) -> Void
        lock.lock()
        current = handler
        lock.unlock()
        current(record)
    }

    func replaceHandler(_ replacement: @escaping @Sendable (Data) -> Void) -> @Sendable (Data) -> Void {
        let previous: @Sendable (Data) -> Void
        lock.lock()
        previous = handler
        handler = replacement
        lock.unlock()
        return previous
    }

    func restoreHandler(_ previous: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        handler = previous
        lock.unlock()
    }
}

enum KVCacheTelemetry {
    private static let sink = KVCacheTelemetrySink()

    static func withSink<T>(_ replacement: @escaping @Sendable (Data) -> Void, operation: () async throws -> T) async rethrows -> T {
        let previous = sink.replaceHandler(replacement)
        defer { sink.restoreHandler(previous) }
        return try await operation()
    }

    static func requestCompletedPayload(
        providerID: String?,
        requestID: String,
        modelID: String,
        stream: Bool,
        completion: CompletionResult
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "event": "kv_cache_request_completed",
                "provider_id": providerID ?? "",
                "request_id": requestID,
                "model_id": modelID,
                "stream": stream,
                "finish_reason": completion.finishReason,
                "prompt_tokens": completion.promptTokens,
                "cached_prompt_tokens": completion.cachedPromptTokens,
                "completion_tokens": completion.completionTokens,
                "kv_cache_reuse_ratio": completion.kvCacheReuseRatio,
                "kv_cache_bytes_reused": completion.kvCacheBytesReused,
            ],
            options: [.sortedKeys]
        )
    }

    static func emitRequestCompleted(
        providerID: String?,
        requestID: String,
        modelID: String,
        stream: Bool,
        completion: CompletionResult
    ) {
        emit(try? requestCompletedPayload(
            providerID: providerID,
            requestID: requestID,
            modelID: modelID,
            stream: stream,
            completion: completion
        ))
    }

    private static func emit(_ payload: Data?) {
        guard var payload else { return }
        payload.append(Data("\n".utf8))
        sink.emit(payload)
    }
}
