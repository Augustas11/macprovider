import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import MacProviderCore
@testable import macprovider_cli

/// SPEC-038 AC-25 (`:620-621`) — direct-HTTP client cancellation.
///
/// Two halves are asserted separately because they fail differently:
/// the *detection* half (a closed connection actually reaches the inference
/// task's `shouldCancel`) needs a real socket, and the *terminal-outcome*
/// half (exactly one outcome, no late tokens) needs the connection to stay
/// open long enough to read the bytes the provider wrote.
final class HTTPServerClientDisconnectTests: XCTestCase {

    // MARK: - Detection: a closed connection reaches `shouldCancel`

    func testNonStreamingDirectHTTPDisconnectReachesShouldCancel() async throws {
        let probe = DisconnectProbe()
        let runtime = DisconnectProbeRuntime(mode: .awaitDisconnect, probe: probe)

        try await withDisconnectHTTPServer(runtime: runtime) { port in
            try sendChatCompletionAndClose(port: port, stream: false)
            try await eventuallyTrue { probe.observedDisconnect }
        }
        XCTAssertTrue(probe.observedDisconnect, "closing the connection must flip shouldCancel")
    }

    func testStreamingDirectHTTPDisconnectReachesShouldCancel() async throws {
        let probe = DisconnectProbe()
        let runtime = DisconnectProbeRuntime(mode: .awaitDisconnect, probe: probe)

        try await withDisconnectHTTPServer(runtime: runtime) { port in
            try sendChatCompletionAndClose(port: port, stream: true)
            try await eventuallyTrue { probe.observedDisconnect }
        }
        XCTAssertTrue(probe.observedDisconnect, "closing the connection must flip shouldCancel")
    }

    // MARK: - Terminal outcome, before the first buyer-visible token

    func testNonStreamingCancelBeforeFirstTokenIsOneNonSettlingOutcome() async throws {
        let probe = DisconnectProbe()
        let runtime = DisconnectProbeRuntime(mode: .cancelBeforeFirstToken, probe: probe)
        let capture = ReceiptAuditCaptureSink()

        let response = try await ReceiptAudit.withSink({ capture.append($0) }) {
            try await withDisconnectHTTPServer(runtime: runtime) { port in
                try sendChatCompletionAndRead(port: port, stream: false)
            }
        }

        XCTAssertEqual(response.statusCode, 499, response.body)
        let error = try errorObject(fromJSONBody: response.body)
        XCTAssertEqual(error["code"] as? String, "buyer_cancelled")
        XCTAssertEqual(error["inference_ran"] as? Bool, false)
        XCTAssertEqual(error["settlement_ran"] as? Bool, false)

        let events = try capture.events()
        XCTAssertEqual(events.count, 1, "\(events)")
        XCTAssertEqual(events.first?["reason"] as? String, "pre_token_cancel")
    }

    func testStreamingCancelBeforeSSEHeadIsOneNonSettlingOutcome() async throws {
        let probe = DisconnectProbe()
        // Preflight throws, so the SSE head is never written: the buyer gets a
        // plain JSON terminal rather than an SSE frame.
        let runtime = DisconnectProbeRuntime(mode: .cancelInPreflight, probe: probe)
        let capture = ReceiptAuditCaptureSink()

        let response = try await ReceiptAudit.withSink({ capture.append($0) }) {
            try await withDisconnectHTTPServer(runtime: runtime) { port in
                try sendChatCompletionAndRead(port: port, stream: true)
            }
        }

        XCTAssertEqual(response.statusCode, 499, response.body)
        let error = try errorObject(fromJSONBody: response.body)
        XCTAssertEqual(error["code"] as? String, "buyer_cancelled")
        XCTAssertEqual(error["inference_ran"] as? Bool, false)
        XCTAssertEqual(error["settlement_ran"] as? Bool, false)

        let reasons = try capture.events().compactMap { $0["reason"] as? String }
        XCTAssertTrue(reasons.contains("pre_token_cancel"), "\(reasons)")
    }

    // MARK: - Terminal outcome, after the first buyer-visible token

    func testStreamingCancelAfterFirstTokenEmitsExactlyOneTerminalAndNoLateTokens() async throws {
        let probe = DisconnectProbe()
        let runtime = DisconnectProbeRuntime(mode: .cancelAfterTokens(2), probe: probe)

        let response = try await withDisconnectHTTPServer(runtime: runtime) { port in
            try sendChatCompletionAndRead(port: port, stream: true)
        }

        let frames = sseDataPayloads(response.body)
        XCTAssertEqual(frames.last, "[DONE]", response.body)

        let contentDeltas = frames.compactMap { contentDelta(in: $0) }.filter { !$0.isEmpty }
        XCTAssertEqual(contentDeltas, ["t0", "t1"], response.body)

        // Exactly one terminal outcome...
        let terminals = frames.filter { $0.contains("\"buyer_cancelled\"") }
        XCTAssertEqual(terminals.count, 1, response.body)
        let terminal = try errorObject(fromJSONBody: try XCTUnwrap(terminals.first))
        XCTAssertEqual(terminal["code"] as? String, "buyer_cancelled")
        XCTAssertEqual(terminal["inference_ran"] as? Bool, true)
        XCTAssertEqual(terminal["settlement_ran"] as? Bool, false)

        // ...and nothing buyer-visible after it except the stream close.
        let terminalIndex = try XCTUnwrap(frames.firstIndex(of: try XCTUnwrap(terminals.first)))
        XCTAssertEqual(Array(frames[(terminalIndex + 1)...]), ["[DONE]"], response.body)

        // No success terminal was emitted alongside the cancel.
        XCTAssertFalse(response.body.contains("\"finish_reason\": \"stop\""), response.body)
        XCTAssertFalse(response.body.contains("\"usage\""), response.body)
    }
}

// MARK: - Fixtures

private final class DisconnectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var disconnected = false

    var observedDisconnect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disconnected
    }

    func noteDisconnect() {
        lock.lock()
        disconnected = true
        lock.unlock()
    }
}

private enum DisconnectProbeMode: Sendable {
    /// Poll `shouldCancel` until the buyer goes away, then unwind the way a
    /// real engine does.
    case awaitDisconnect
    case cancelInPreflight
    case cancelBeforeFirstToken
    case cancelAfterTokens(Int)
}

private actor DisconnectProbeRuntime: ModelRuntimeServing {
    private let mode: DisconnectProbeMode
    private let probe: DisconnectProbe

    init(mode: DisconnectProbeMode, probe: DisconnectProbe) {
        self.mode = mode
        self.probe = probe
    }

    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}
    func unregisterInFlight(_ id: Int) {}

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(
            snapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: request.model, modelHash: nil),
            registrationID: 0,
            drainCancelled: DrainCancelToken()
        )
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        if case .cancelInPreflight = mode {
            throw CancellationError()
        }
    }

    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        switch mode {
        case .awaitDisconnect:
            try await waitForCancel(shouldCancel)
        case .cancelInPreflight, .cancelBeforeFirstToken, .cancelAfterTokens:
            throw CancellationError()
        }
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        switch mode {
        case .awaitDisconnect:
            return try await waitForCancel(shouldCancel)
        case .cancelAfterTokens(let count):
            for index in 0..<count {
                onChunk(.content("t\(index)"))
            }
            throw CancellationError()
        case .cancelInPreflight, .cancelBeforeFirstToken:
            throw CancellationError()
        }
    }

    /// Polls the way `ModelRuntime.withDrainAndClientCancellation` does, so
    /// the fixture exercises the same contract the real engine relies on.
    private func waitForCancel(
        _ shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if shouldCancel() {
                probe.noteDisconnect()
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return CompletionResult(content: "never", finishReason: "stop", promptTokens: 1, completionTokens: 1)
    }
}

private final class ReceiptAuditCaptureSink: @unchecked Sendable {
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
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }
}

// MARK: - Helpers

private struct RawHTTPResponse {
    let statusCode: Int
    let body: String
}

private func withDisconnectHTTPServer<T>(
    runtime: any ModelRuntimeServing,
    operation: (Int) async throws -> T
) async throws -> T {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let providerStatus = ProviderStatus(
        modelID: "fixture-model",
        modelLoaded: true,
        capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
    )
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(RouterHandler(
                    modelID: "fixture-model",
                    providerID: "provider-a",
                    coordinatorURL: nil,
                    modelRuntime: runtime,
                    providerStatus: providerStatus,
                    warmSwapEnabled: false,
                    maxBodyBytes: 1_000_000,
                    receiptBuilder: nil
                ))
            }
        }
        .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    do {
        let port = try XCTUnwrap(channel.localAddress?.port)
        let result = try await operation(port)
        try await channel.close().get()
        try await group.shutdownGracefully()
        return result
    } catch {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        throw error
    }
}

private func chatCompletionRequestBytes(port: Int, stream: Bool) throws -> Data {
    let body: [String: Any] = [
        "model": "fixture-model",
        "messages": [["role": "user", "content": "hello"]],
        "stream": stream,
    ]
    let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
    let head = "POST /v1/chat/completions HTTP/1.1\r\n"
        + "Host: 127.0.0.1:\(port)\r\n"
        + "Content-Type: application/json\r\n"
        + "Content-Length: \(bodyData.count)\r\n"
        + "X-Request-ID: req-disconnect\r\n"
        + "Connection: close\r\n"
        + "\r\n"
    var request = Data(head.utf8)
    request.append(bodyData)
    return request
}

private func connectAndSend(port: Int, stream: Bool) throws -> Int32 {
    let request = try chatCompletionRequestBytes(port: port, stream: stream)
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    XCTAssertEqual(connected, 0)

    try request.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < request.count {
            let count = Darwin.send(descriptor, base.advanced(by: sent), request.count - sent, 0)
            if count <= 0 { throw POSIXError(.EIO) }
            sent += count
        }
    }
    return descriptor
}

private func sendChatCompletionAndClose(port: Int, stream: Bool) throws {
    let descriptor = try connectAndSend(port: port, stream: stream)
    close(descriptor)
}

private func sendChatCompletionAndRead(port: Int, stream: Bool) throws -> RawHTTPResponse {
    let descriptor = try connectAndSend(port: port, stream: stream)
    defer { close(descriptor) }

    var raw = Data()
    var scratch = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.recv(descriptor, &scratch, scratch.count, 0)
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { throw POSIXError(.ETIMEDOUT) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if count == 0 { break }
        raw.append(scratch, count: count)
    }

    let text = String(decoding: raw, as: UTF8.self)
    let statusLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
    let statusCode = Int(statusLine.split(separator: " ").dropFirst().first.map(String.init) ?? "") ?? 0
    let body: String
    if let range = text.range(of: "\r\n\r\n") {
        body = String(text[range.upperBound...])
    } else {
        body = ""
    }
    return RawHTTPResponse(statusCode: statusCode, body: body)
}

private func eventuallyTrue(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    _ condition: @escaping () -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("condition never became true")
}

private func errorObject(fromJSONBody body: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    return try XCTUnwrap(object?["error"] as? [String: Any])
}

private func sseDataPayloads(_ body: String) -> [String] {
    // The response is chunk-framed, so lines are separated by a mix of "\n"
    // (inside an SSE frame) and "\r\n" (chunk boundaries). Swift treats CRLF
    // as one Character, so splitting on a literal "\n" would glue the line
    // after every chunk boundary onto its size prefix.
    body
        .split(whereSeparator: { $0.isNewline })
        .map(String.init)
        .filter { $0.hasPrefix("data: ") }
        .map { String($0.dropFirst("data: ".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
}

private func contentDelta(in payload: String) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
          let choices = object["choices"] as? [[String: Any]],
          let delta = choices.first?["delta"] as? [String: Any]
    else { return nil }
    return delta["content"] as? String
}
