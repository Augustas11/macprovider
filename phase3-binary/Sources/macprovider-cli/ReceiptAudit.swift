import Foundation

enum ReceiptOmissionReason: String, CaseIterable {
    case preV16Binary = "pre_v1_6_binary"
    case noKeypair = "no_keypair"
    case modelSwapViolation = "model_swap_violation"
    case preTokenCancel = "pre_token_cancel"
    case streamingRequest = "streaming_request"
}

private final class ReceiptAuditSink: @unchecked Sendable {
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

enum ReceiptAudit {
    private static let sink = ReceiptAuditSink()

    static func withSink<T>(_ replacement: @escaping @Sendable (Data) -> Void, operation: () async throws -> T) async rethrows -> T {
        let previous = sink.replaceHandler(replacement)
        defer { sink.restoreHandler(previous) }
        return try await operation()
    }

    static func issuedPayload(
        providerID: String?,
        requestID: String,
        modelID: String,
        tokensOut: Int64,
        ttftMs: Int64,
        unixTs: Int64
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "event": "receipt_issued",
                "provider_id": providerID ?? "",
                "request_id": requestID,
                "model_id": modelID,
                "tokens_out": tokensOut,
                "ttft_ms": ttftMs,
                "unix_ts": unixTs,
            ],
            options: [.sortedKeys]
        )
    }

    static func omittedPayload(providerID: String?, requestID: String, reason: ReceiptOmissionReason) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "event": "receipt_omitted",
                "provider_id": providerID ?? "",
                "request_id": requestID,
                "reason": reason.rawValue,
            ],
            options: [.sortedKeys]
        )
    }

    static func emitIssued(
        providerID: String?,
        requestID: String,
        modelID: String,
        tokensOut: Int64,
        ttftMs: Int64,
        unixTs: Int64
    ) {
        emit(try? issuedPayload(providerID: providerID, requestID: requestID, modelID: modelID, tokensOut: tokensOut, ttftMs: ttftMs, unixTs: unixTs))
    }

    static func emitOmitted(providerID: String?, requestID: String, reason: ReceiptOmissionReason) {
        emit(try? omittedPayload(providerID: providerID, requestID: requestID, reason: reason))
    }

    private static func emit(_ payload: Data?) {
        guard var payload else { return }
        payload.append(Data("\n".utf8))
        sink.emit(payload)
    }
}
