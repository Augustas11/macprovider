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

    /// #1690: the realistic case. The buyer closes after the request has
    /// been read and inference is running, with the shipping
    /// `HTTPServerPipelineHandler` withholding reads. NIO on Darwin delivers
    /// no early EOF without a read, so only `PeerCloseMonitor`'s read pump
    /// lets `channelInactive` see this close.
    func testStreamingDisconnectDuringInferenceReachesShouldCancel() async throws {
        let probe = DisconnectProbe()
        let runtime = DisconnectProbeRuntime(mode: .awaitDisconnect, probe: probe)

        try await withDisconnectHTTPServer(runtime: runtime) { port in
            let descriptor = try connectAndSend(port: port, stream: true)
            try await eventuallyTrue { probe.observedInference }
            close(descriptor)
            try await eventuallyTrue { probe.observedDisconnect }
        }
        XCTAssertTrue(probe.observedDisconnect, "a close during inference must flip shouldCancel")
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

    // MARK: - Pipelining cannot orphan an in-flight request's disconnect state

    /// A client that pipelines a second request must not be able to orphan the
    /// first request's cancellation state. The handler keeps every armed
    /// state, not just the newest, so a close still reaches the inference that
    /// is actually running.
    ///
    /// Note for the reader: NIO's `HTTPServerPipelineHandler`, which
    /// `configureHTTPServerPipeline()` installs by default, buffers the second
    /// request until the first response's `.end` is written — so in the
    /// shipping configuration `RouterHandler` never sees two overlapping
    /// `.head`s at all. This test therefore turns that assistance off, which
    /// is the only way to produce the overlap, and pins the handler's own
    /// behaviour so the guarantee does not rest on an upstream default.
    func testPipelinedRequestsEachKeepTheirOwnDisconnectState() async throws {
        let probe = DisconnectProbe()
        let runtime = DisconnectProbeRuntime(mode: .awaitDisconnect, probe: probe)

        try await withDisconnectHTTPServer(
            runtime: runtime,
            pipeliningAssistance: false,
            maxConcurrency: 2
        ) { port in
            let descriptor = try connectAndSend(port: port, stream: false, keepAlive: true)
            // Pipelined before the first response is written: two inferences
            // are now in flight on one channel.
            try sendRequestBytes(descriptor: descriptor, port: port, stream: false, keepAlive: true)
            try await eventuallyTrue { probe.observedInferenceCount == 2 }
            close(descriptor)
            // Both must be cancelled. Keeping only the newest state leaves the
            // first running against a socket that is already gone.
            try await eventuallyTrue { probe.observedDisconnectCount == 2 }
        }
        XCTAssertEqual(probe.observedDisconnectCount, 2)
    }

    // MARK: - SPEC-038 `:614` bounded retry guidance

    /// A `retryable: true` 503 with no bound invites a client to hot-loop on a
    /// provider that is already saturated. The direct-HTTP JSON error path
    /// carries `Retry-After`, derived from the configured admission wait.
    func testQueuePressureErrorCarriesRetryAfterDerivedFromTheConfiguredWait() async throws {
        let probe = DisconnectProbe()
        let runtime = DisconnectProbeRuntime(mode: .schedulerBackpressure, probe: probe)

        let response = try await withDisconnectHTTPServer(
            runtime: runtime,
            continuousBatchQueueWaitTimeoutMS: 4_500
        ) { port in
            try sendChatCompletionAndRead(port: port, stream: false)
        }

        XCTAssertEqual(response.statusCode, 503, response.body)
        let error = try errorObject(fromJSONBody: response.body)
        XCTAssertEqual(error["code"] as? String, "continuous_batching_stream_backpressure")
        XCTAssertEqual(error["retryable"] as? Bool, true)
        // 4500 ms of admission wait rounds up to a 5 second bound.
        XCTAssertEqual(response.headers["retry-after"], "5", response.headers.description)
    }

    /// On a streaming request the scheduler rejects after the SSE head is
    /// already committed, so the bound cannot ride a response header.
    ///
    /// A trailer alone is not enough: many SSE/EventSource clients never
    /// expose trailers, the coordinator reads provider trailers only for
    /// receipt metadata, and the gateway strips upstream `Trailer` /
    /// `Retry-After`. So the assertion that matters is on the **SSE error
    /// payload a normal client parses**. The trailer and its `Trailer:`
    /// declaration are asserted too, for raw readers.
    func testStreamingQueuePressureErrorCarriesRetryAfterInTheSSEErrorBody() async throws {
        let probe = DisconnectProbe()
        let runtime = DisconnectProbeRuntime(mode: .schedulerBackpressure, probe: probe)

        let response = try await withDisconnectHTTPServer(
            runtime: runtime,
            continuousBatchQueueWaitTimeoutMS: 4_500
        ) { port in
            try sendChatCompletionAndRead(port: port, stream: true)
        }

        XCTAssertEqual(response.statusCode, 200, response.body)
        let frames = sseDataPayloads(response.body)
        let errorFrames = frames.filter { $0.contains("continuous_batching_stream_backpressure") }
        XCTAssertEqual(errorFrames.count, 1, response.body)
        let error = try errorObject(fromJSONBody: try XCTUnwrap(errorFrames.first))
        XCTAssertEqual(error["code"] as? String, "continuous_batching_stream_backpressure")
        XCTAssertEqual(error["retryable"] as? Bool, true)
        // 4500 ms of admission wait rounds up to a 5 second bound, and it is
        // readable without touching a trailer.
        XCTAssertEqual((error["retry_after"] as? NSNumber)?.intValue, 5, response.body)

        // Belt and braces for raw readers: declared on the head, sent at the end.
        XCTAssertEqual(response.headers["trailer"], "Retry-After", response.headers.description)
        XCTAssertTrue(response.body.contains("Retry-After: 5"), response.body)
    }

    /// The post-token half of `.backpressure` must not advertise retry.
    /// Inference ran, the buyer already holds partial output, and a retry
    /// would re-request work that partly happened — so: a distinct code,
    /// `inference_ran: true`, `retryable: false`, and no bound in either the
    /// body or a trailer.
    func testStreamingDeliveryBackpressureIsPostTokenAndAdvertisesNoRetry() async throws {
        let probe = DisconnectProbe()
        let runtime = DisconnectProbeRuntime(mode: .schedulerDeliveryBackpressure(2), probe: probe)

        let response = try await withDisconnectHTTPServer(
            runtime: runtime,
            continuousBatchQueueWaitTimeoutMS: 4_500
        ) { port in
            try sendChatCompletionAndRead(port: port, stream: true)
        }

        let frames = sseDataPayloads(response.body)
        // Tokens really did reach the buyer before the failure.
        XCTAssertEqual(frames.compactMap { contentDelta(in: $0) }.filter { !$0.isEmpty }, ["t0", "t1"], response.body)

        let errorFrames = frames.filter { $0.contains("continuous_batching_stream_delivery_backpressure") }
        XCTAssertEqual(errorFrames.count, 1, response.body)
        let error = try errorObject(fromJSONBody: try XCTUnwrap(errorFrames.first))
        XCTAssertEqual(error["code"] as? String, "continuous_batching_stream_delivery_backpressure")
        XCTAssertEqual(error["inference_ran"] as? Bool, true)
        XCTAssertEqual(error["settlement_ran"] as? Bool, false)
        XCTAssertEqual(error["retryable"] as? Bool, false)
        XCTAssertNil(error["retry_after"], response.body)
        XCTAssertFalse(response.body.contains("Retry-After:"), response.body)
    }

    /// The pre-admission and post-token classifications are two different
    /// buyer-visible outcomes and must never collapse back into one.
    func testAC25BackpressureClassificationsAreDistinct() throws {
        let preAdmission = try XCTUnwrap(ContinuousBatchSchedulerError.backpressure.asAPIError())
        let postToken = try XCTUnwrap(ContinuousBatchSchedulerError.deliveryBackpressure.asAPIError())

        XCTAssertNotEqual(preAdmission.code, postToken.code)
        XCTAssertEqual(preAdmission.code, "continuous_batching_stream_backpressure")
        XCTAssertEqual(postToken.code, ContinuousBatchSchedulerError.deliveryBackpressureCode)

        XCTAssertFalse(preAdmission.inferenceRan)
        XCTAssertTrue(postToken.inferenceRan)
        XCTAssertFalse(preAdmission.settlementRan)
        XCTAssertFalse(postToken.settlementRan)

        let preEnvelope = preAdmission.envelope["error"] as? [String: Any]
        let postEnvelope = postToken.envelope["error"] as? [String: Any]
        XCTAssertEqual(preEnvelope?["retryable"] as? Bool, true)
        XCTAssertEqual(postEnvelope?["retryable"] as? Bool, false)

        // Only the pre-admission code gets a bound, in either channel.
        XCTAssertEqual(
            RouterHandler.retryGuidanceHeaders(code: preAdmission.code, seconds: 5).map(\.0),
            ["Retry-After"]
        )
        XCTAssertTrue(RouterHandler.retryGuidanceHeaders(code: postToken.code, seconds: 5).isEmpty)
        let postBody = RouterHandler.sseErrorEnvelope(postToken, retryAfterSeconds: 5)["error"] as? [String: Any]
        XCTAssertNil(postBody?["retry_after"])
        let preBody = RouterHandler.sseErrorEnvelope(preAdmission, retryAfterSeconds: 5)["error"] as? [String: Any]
        XCTAssertEqual((preBody?["retry_after"] as? NSNumber)?.intValue, 5)
    }

    /// Only the queue-pressure codes get the header: a 409 duplicate is not
    /// something a client should re-send on a timer.
    func testNonQueuePressureErrorCarriesNoRetryAfter() async throws {
        let probe = DisconnectProbe()
        let runtime = DisconnectProbeRuntime(mode: .schedulerDuplicateMismatch, probe: probe)

        let response = try await withDisconnectHTTPServer(runtime: runtime) { port in
            try sendChatCompletionAndRead(port: port, stream: false)
        }

        XCTAssertEqual(response.statusCode, 409, response.body)
        XCTAssertNil(response.headers["retry-after"], response.headers.description)
    }

    func testRetryAfterSecondsResolutionMatchesTheSchedulerDefault() {
        // Unset and non-positive both mean the scheduler default, not
        // "unbounded" — the same rule `ModelRuntime` applies.
        XCTAssertEqual(RouterHandler.queueWaitRetryAfterSeconds(nil), 30)
        XCTAssertEqual(RouterHandler.queueWaitRetryAfterSeconds(0), 30)
        XCTAssertEqual(RouterHandler.queueWaitRetryAfterSeconds(-1), 30)
        XCTAssertEqual(RouterHandler.queueWaitRetryAfterSeconds(1), 1)
        XCTAssertEqual(RouterHandler.queueWaitRetryAfterSeconds(1_000), 1)
        XCTAssertEqual(RouterHandler.queueWaitRetryAfterSeconds(1_001), 2)
        XCTAssertEqual(
            RouterHandler.queueWaitRetryAfterSeconds(nil),
            Int(ContinuousBatchSchedulerConfiguration.defaultQueueWaitTimeoutNanoseconds / 1_000_000_000)
        )
        XCTAssertEqual(
            RouterHandler.retryGuidanceHeaders(code: "continuous_batching_queue_wait_timeout", seconds: 7).map(\.0),
            ["Retry-After"]
        )
        XCTAssertTrue(RouterHandler.retryGuidanceHeaders(code: "model_not_loaded", seconds: 7).isEmpty)
        // The header set and the retryable set must stay the same two codes.
        for code in RouterHandler.queueWaitRetryGuidanceCodes {
            let envelope = APIError(status: 503, message: "m", type: "server_error", code: code)
                .envelope["error"] as? [String: Any]
            XCTAssertEqual(envelope?["retryable"] as? Bool, true, code)
        }
    }
}

// MARK: - Fixtures

private final class DisconnectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var disconnected = false
    private var disconnectCount = 0
    private var inferenceCount = 0
    private var inferenceEntered = false

    var observedDisconnect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disconnected
    }

    /// How many in-flight requests saw the close. One per request, so a
    /// dropped cancellation state shows up as a missing count.
    var observedDisconnectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return disconnectCount
    }

    var observedInferenceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inferenceCount
    }

    /// True once the fixture engine is inside the request, so a test can close
    /// the socket at a point where cancellation is meaningful.
    var observedInference: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inferenceEntered
    }

    func noteInference() {
        lock.lock()
        inferenceEntered = true
        inferenceCount += 1
        lock.unlock()
    }

    func noteDisconnect() {
        lock.lock()
        disconnected = true
        disconnectCount += 1
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
    /// Rejects the way a saturated scheduler does, through the shared AC-25
    /// error map, so the response the buyer sees is the real one.
    case schedulerBackpressure
    /// Emits N buyer-visible tokens and *then* fails the way an active row
    /// does when its delivery buffer refuses an event — the post-token half
    /// of `.backpressure`, which is a different outcome.
    case schedulerDeliveryBackpressure(Int)
    case schedulerDuplicateMismatch
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
    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }
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
        case .schedulerBackpressure:
            throw try XCTUnwrap(ContinuousBatchSchedulerError.backpressure.asAPIError())
        case .schedulerDeliveryBackpressure:
            throw try XCTUnwrap(ContinuousBatchSchedulerError.deliveryBackpressure.asAPIError())
        case .schedulerDuplicateMismatch:
            throw try XCTUnwrap(ContinuousBatchSchedulerError.duplicateRequestMismatch.asAPIError())
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
        case .schedulerBackpressure:
            throw try XCTUnwrap(ContinuousBatchSchedulerError.backpressure.asAPIError())
        case .schedulerDeliveryBackpressure(let count):
            for index in 0..<count {
                onChunk(.content("t\(index)"))
            }
            throw try XCTUnwrap(ContinuousBatchSchedulerError.deliveryBackpressure.asAPIError())
        case .schedulerDuplicateMismatch:
            throw try XCTUnwrap(ContinuousBatchSchedulerError.duplicateRequestMismatch.asAPIError())
        case .cancelInPreflight, .cancelBeforeFirstToken:
            throw CancellationError()
        }
    }

    /// Polls the way `ModelRuntime.withDrainAndClientCancellation` does, so
    /// the fixture exercises the same contract the real engine relies on.
    private func waitForCancel(
        _ shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        probe.noteInference()
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if shouldCancel() {
                probe.noteDisconnect()
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return CompletionResult(content: "never", finishReason: "stop", promptTokens: 1, completionTokens: 1, settlementDisposition: .eligibleOwner)
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
    /// Response header names lowercased, so a test asserts on the value and
    /// not on NIO's casing.
    let headers: [String: String]
    let body: String
}

private func withDisconnectHTTPServer<T>(
    runtime: any ModelRuntimeServing,
    continuousBatchQueueWaitTimeoutMS: Int? = nil,
    pipeliningAssistance: Bool = true,
    maxConcurrency: Int? = nil,
    operation: (Int) async throws -> T
) async throws -> T {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let providerStatus = ProviderStatus(
        modelID: "fixture-model",
        modelLoaded: true,
        capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: maxConcurrency)
    )
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline(
                withPipeliningAssistance: pipeliningAssistance
            ).flatMap {
                channel.pipeline.addHandler(RouterHandler(
                    modelID: "fixture-model",
                    providerID: "provider-a",
                    coordinatorURL: nil,
                    modelRuntime: runtime,
                    providerStatus: providerStatus,
                    warmSwapEnabled: false,
                    maxBodyBytes: 1_000_000,
                    receiptBuilder: nil,
                    continuousBatchQueueWaitTimeoutMS: continuousBatchQueueWaitTimeoutMS
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

private func chatCompletionRequestBytes(port: Int, stream: Bool, keepAlive: Bool = false) throws -> Data {
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
        // A pipelining test must not announce `close`: the decoder stops
        // parsing further requests on this connection once it sees it.
        + (keepAlive ? "" : "Connection: close\r\n")
        + "\r\n"
    var request = Data(head.utf8)
    request.append(bodyData)
    return request
}

/// Writes one more complete request onto an already-open connection, without
/// reading the previous response first — HTTP/1.1 pipelining.
private func sendRequestBytes(descriptor: Int32, port: Int, stream: Bool, keepAlive: Bool = false) throws {
    try sendAll(
        descriptor: descriptor,
        data: try chatCompletionRequestBytes(port: port, stream: stream, keepAlive: keepAlive)
    )
}

private func sendAll(descriptor: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let count = Darwin.send(descriptor, base.advanced(by: sent), data.count - sent, 0)
            if count <= 0 { throw POSIXError(.EIO) }
            sent += count
        }
    }
}

private func connectAndSend(port: Int, stream: Bool, keepAlive: Bool = false) throws -> Int32 {
    let request = try chatCompletionRequestBytes(port: port, stream: stream, keepAlive: keepAlive)
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

    try sendAll(descriptor: descriptor, data: request)
    return descriptor
}

private func sendChatCompletionAndClose(port: Int, stream: Bool) throws {
    let descriptor = try connectAndSend(port: port, stream: stream)
    close(descriptor)
}

private func sendChatCompletionAndRead(port: Int, stream: Bool) throws -> RawHTTPResponse {
    let descriptor = try connectAndSend(port: port, stream: stream)
    defer { close(descriptor) }
    return try readRawResponse(descriptor: descriptor)
}

private func readRawResponse(descriptor: Int32) throws -> RawHTTPResponse {
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
    var headers: [String: String] = [:]
    if let range = text.range(of: "\r\n\r\n") {
        body = String(text[range.upperBound...])
        for line in text[..<range.lowerBound].components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[line[..<separator].lowercased()] =
                line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
    } else {
        body = ""
    }
    return RawHTTPResponse(statusCode: statusCode, headers: headers, body: body)
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
