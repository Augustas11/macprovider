import CryptoKit
import Foundation
import MacProviderCore
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import macprovider_cli

/// SPEC-001-R016 request routing through the warm-set table, over the relay
/// and HTTP, with two fake runtimes: no model is loaded.
final class WarmModelRoutingTests: XCTestCase {
    private final class Harness: @unchecked Sendable {
        let table = WarmModelTable<WarmFakeRuntime>()
        let primary = WarmFakeRuntime(memberID: 7_101, modelID: "model-a", hash: String(repeating: "a", count: 64))
        // The member reports a different usage, so a receipt shows whose it binds.
        let member = WarmFakeRuntime(memberID: 7_102, modelID: "model-b", hash: String(repeating: "b", count: 64), completionTokens: 2)
        let status = ProviderStatus(
            modelID: "model-a",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 4)
        )
        let recorder = WarmFrameRecorder()

        init(memberState: WarmModelState? = .warm) throws {
            try table.insertPrimary(modelID: "model-a", runtime: primary)
            switch memberState {
            case .warm?:
                let token = try table.beginLoading(modelID: "model-b", pinned: false)
                try table.finishLoading(token: token, runtime: member)
            case .loading?:
                _ = try table.beginLoading(modelID: "model-b", pinned: false)
            case .evicting?:
                let token = try table.beginLoading(modelID: "model-b", pinned: false)
                try table.finishLoading(token: token, runtime: member)
                _ = try table.beginEvicting(modelID: "model-b", allowPinned: false)
            case nil:
                break
            }
        }

        func relay(receiptBuilder: ReceiptBuilder? = nil) -> InferenceRelay {
            InferenceRelay(
                modelRuntime: primary,
                warmModels: table,
                providerStatus: status,
                loadedModelID: "model-a",
                warmSwapEnabled: receiptBuilder != nil,
                maxActiveRequests: 4,
                maxBodyBytes: 4096,
                receiptBuilder: receiptBuilder,
                receiptProviderID: receiptBuilder == nil ? nil : "provider-warm-test",
                sendFrame: { [recorder] frame in await recorder.append(frame) }
            )
        }

        func leases(_ modelID: String) -> Int { table.entry(modelID: modelID)?.leases ?? -1 }
    }

    private func inference(
        _ requestID: String,
        model: String,
        content: String = "hello",
        stream: Bool = false,
        served: Any? = nil
    ) -> [String: Any] {
        var message: [String: Any] = [
            "type": "inference_request",
            "request_id": requestID,
            "stream": stream,
            "body": #"{"model":"\#(model)","messages":[{"role":"user","content":"\#(content)"}]}"#,
        ]
        if let served { message["served_model_id"] = served }
        return message
    }

    private func endFrame(_ harness: Harness, _ requestID: String) async throws -> [String: Any] {
        try await warmEventually { await harness.recorder.end(requestID) != nil }
        return try await XCTUnwrapAsync(await harness.recorder.end(requestID))
    }

    // MARK: Relay

    func testRelayServesTheNamedMemberOnItsOwnRuntime() async throws {
        let harness = try Harness()
        try await harness.relay().handleInferenceRequest(inference("r1", model: "model-b", served: "model-b"))
        let end = try await endFrame(harness, "r1")
        XCTAssertEqual(end["status"] as? String, "complete")
        let memberCalls = await harness.member.calls
        let primaryCalls = await harness.primary.calls
        XCTAssertEqual(memberCalls, 1)
        XCTAssertEqual(primaryCalls, 0)
        try await warmEventually { harness.leases("model-b") == 0 }
    }

    func testRelayWithoutServedModelServesThePrimary() async throws {
        let harness = try Harness()
        for (index, served) in [nil, NSNull(), "MODEL-A"].enumerated() {
            try await harness.relay().handleInferenceRequest(inference("p\(index)", model: "model-a", served: served))
            let end = try await endFrame(harness, "p\(index)")
            XCTAssertEqual(end["status"] as? String, "complete", "served=\(String(describing: served))")
        }
        let memberCalls = await harness.member.calls
        let primaryCalls = await harness.primary.calls
        XCTAssertEqual(primaryCalls, 3)
        XCTAssertEqual(memberCalls, 0)
        try await warmEventually { harness.leases("model-a") == 0 }
    }

    func testRelayRefusesAModelWithNoWarmMemberBeforeAnyRuntimeCall() async throws {
        for state in [nil, WarmModelState.loading, .evicting] {
            let harness = try Harness(memberState: state)
            for (index, served) in ["model-b", "model-z", 42 as Any].enumerated() {
                let id = "n\(index)-\(String(describing: state))"
                try await harness.relay().handleInferenceRequest(inference(id, model: "model-b", served: served))
                let end = try await endFrame(harness, id)
                XCTAssertEqual(end["status"] as? String, "error_model_not_loaded", id)
                XCTAssertEqual(end["chunks_sent"] as? Int, 0, id)
                XCTAssertNil(end["receipt"], id)
            }
            let memberCalls = await harness.member.calls + harness.member.handles
            let primaryCalls = await harness.primary.calls + harness.primary.handles
            XCTAssertEqual(memberCalls + primaryCalls, 0)
            let inFlight = await harness.status.requestsInFlightCount()
            XCTAssertEqual(inFlight, 0)
        }
    }

    func testRelayReleasesTheLeaseOnErrorCancelAndStreamEnd() async throws {
        let harness = try Harness()
        let relay = harness.relay()

        try await relay.handleInferenceRequest(inference("e1", model: "model-b", content: "fail", served: "model-b"))
        let failed = try await endFrame(harness, "e1")
        XCTAssertEqual(failed["status"] as? String, "error_internal")
        try await warmEventually { harness.leases("model-b") == 0 }

        try await relay.handleInferenceRequest(inference("s1", model: "model-b", stream: true, served: "model-b"))
        let streamed = try await endFrame(harness, "s1")
        XCTAssertEqual(streamed["status"] as? String, "complete")
        try await warmEventually { harness.leases("model-b") == 0 }

        try await relay.handleInferenceRequest(inference("c1", model: "model-b", content: "hold", stream: true, served: "model-b"))
        try await warmEventually { harness.leases("model-b") == 1 }
        try await relay.handleCancelRequest(["type": "cancel_request", "request_id": "c1"])
        let cancelled = try await endFrame(harness, "c1")
        XCTAssertEqual(cancelled["status"] as? String, "cancelled")
        try await warmEventually { harness.leases("model-b") == 0 }
    }

    func testAMemberServingARequestCannotBeEvicted() async throws {
        let harness = try Harness()
        let loader = WarmModelLoader(
            table: harness.table, budget: SharedModelMemoryBudget(), limitBytes: { nil }, idlePollNanoseconds: 1_000_000
        ) { _ in throw APIError(status: 500, message: "no load in this test", code: "internal_error") }
        try await harness.relay().handleInferenceRequest(inference("h1", model: "model-b", content: "hold", served: "model-b"))
        try await warmEventually { await harness.member.entered }

        do {
            try await loader.evict("model-b")
            XCTFail("a member serving a request was evicted")
        } catch let error as WarmModelTableError {
            XCTAssertEqual(error.reason, "busy")
        }
        XCTAssertEqual(harness.table.entry(modelID: "model-b")?.state, .warm)

        await harness.member.releaseHold()
        _ = try await endFrame(harness, "h1")
        try await warmEventually { harness.leases("model-b") == 0 }
        try await loader.evict("model-b")
        XCTAssertNil(harness.table.entry(modelID: "model-b"))
        let unloaded = await harness.member.unloaded
        XCTAssertTrue(unloaded)
    }

    func testRelayReceiptBindsTheServingMembersModelHash() async throws {
        let harness = try Harness()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let relay = harness.relay(receiptBuilder: ReceiptBuilder(keyStore: WarmFixedReceiptKeyStore(key: key)))
        for (model, hash, tokens) in [("model-b", String(repeating: "b", count: 64), 2), ("model-a", String(repeating: "a", count: 64), 1)] {
            try await relay.handleInferenceRequest(inference("h-\(model)", model: model, served: model))
            let end = try await endFrame(harness, "h-\(model)")
            let tuple = try receiptTuple(end["receipt"] as? String)
            XCTAssertEqual(tuple["model_hash"] as? String, hash, model)
            XCTAssertEqual(tuple["model_id"] as? String, model, model)
            XCTAssertEqual(tuple["tokens_out"] as? Int, tokens, model)
            XCTAssertEqual((end["usage"] as? [String: Any])?["completion_tokens"] as? Int, tokens, model)
        }
    }

    /// SPEC-001-R019: a request routed before a promotion settles against
    /// the member that served it, whichever member is primary when it ends.
    func testRelayRequestInFlightAcrossAPromotionSettlesAgainstItsMember() async throws {
        for (model, runtime) in [("model-b", \Harness.member), ("model-a", \Harness.primary)] {
            let harness = try Harness()
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
            let relay = harness.relay(receiptBuilder: ReceiptBuilder(keyStore: WarmFixedReceiptKeyStore(key: key)))
            let serving = harness[keyPath: runtime]
            try await relay.handleInferenceRequest(inference("p-\(model)", model: model, content: "hold", served: model))
            try await warmEventually { await serving.entered }
            _ = try harness.table.promote(modelID: "model-b")
            XCTAssertEqual(harness.table.entry(modelID: "model-b")?.primary, true)
            await serving.releaseHold()
            let end = try await endFrame(harness, "p-\(model)")
            XCTAssertEqual(end["status"] as? String, "complete", model)
            let tuple = try receiptTuple(end["receipt"] as? String)
            XCTAssertEqual(tuple["model_id"] as? String, model, model)
            XCTAssertEqual(tuple["model_hash"] as? String, String(repeating: model == "model-b" ? "b" : "a", count: 64), model)
            XCTAssertEqual(tuple["tokens_out"] as? Int, model == "model-b" ? 2 : 1, model)
            try await warmEventually { harness.leases(model) == 0 }
        }
    }

    // MARK: HTTP

    func testHTTPForwardedHeaderRoutesToTheMemberAndRefusesAnUnknownOne() async throws {
        let harness = try Harness()
        try await withWarmHTTPServer(harness) { port in
            let routed = try await warmPost(port: port, model: "model-b", headers: [WarmModelRoute.servedModelHeaderName: "model-b"])
            XCTAssertEqual(routed.status, 200, routed.body)
            let primary = try await warmPost(port: port, model: "model-a")
            XCTAssertEqual(primary.status, 200, primary.body)
            let unknown = try await warmPost(port: port, model: "model-z", headers: [WarmModelRoute.servedModelHeaderName: "model-z"])
            XCTAssertEqual(unknown.status, 503)
            XCTAssertEqual(unknown.errorCode, "model_not_loaded")
            XCTAssertEqual(unknown.retryable, true)
            XCTAssertNil(unknown.receipt)
        }
        let memberCalls = await harness.member.calls
        let primaryCalls = await harness.primary.calls
        let handles = await harness.member.handles + harness.primary.handles
        XCTAssertEqual(memberCalls, 1)
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(handles, 2)
        try await warmEventually { harness.leases("model-b") == 0 && harness.leases("model-a") == 0 }
    }

    func testHTTPLocalRequestRoutesByBodyModelElseThePrimary() async throws {
        let harness = try Harness()
        try await withWarmHTTPServer(harness) { port in
            let member = try await warmPost(port: port, model: "MODEL-B", local: true, stream: true)
            XCTAssertEqual(member.status, 200, member.body)
            // An unknown body model falls back to the primary, which refuses
            // the model mismatch exactly as without a warm set.
            let unknown = try await warmPost(port: port, model: "model-z", local: true)
            XCTAssertEqual(unknown.status, 404, unknown.body)
            XCTAssertEqual(unknown.errorCode, "model_not_found")
        }
        let memberCalls = await harness.member.calls
        let primaryCalls = await harness.primary.calls
        XCTAssertEqual(memberCalls, 1)
        XCTAssertEqual(primaryCalls, 0)
        try await warmEventually { harness.leases("model-b") == 0 && harness.leases("model-a") == 0 }
    }

    func testHTTPReleasesTheLeaseWhenTheMemberThrows() async throws {
        let harness = try Harness()
        try await withWarmHTTPServer(harness) { port in
            let failed = try await warmPost(port: port, model: "model-b", content: "fail", headers: [WarmModelRoute.servedModelHeaderName: "model-b"])
            XCTAssertEqual(failed.status, 500, failed.body)
            let streamFailed = try await warmPost(port: port, model: "model-b", content: "fail", stream: true, headers: [WarmModelRoute.servedModelHeaderName: "model-b"])
            XCTAssertNotEqual(streamFailed.status, 0)
        }
        try await warmEventually { harness.leases("model-b") == 0 }
    }

    func testHTTPReceiptBindsTheServingMembersModelHash() async throws {
        let harness = try Harness()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: WarmFixedReceiptKeyStore(key: key))
        try await withWarmHTTPServer(harness, receiptBuilder: builder) { port in
            for (model, hash) in [("model-b", String(repeating: "b", count: 64)), ("model-a", String(repeating: "a", count: 64))] {
                let response = try await warmPost(port: port, model: model, headers: [WarmModelRoute.servedModelHeaderName: model])
                XCTAssertEqual(response.status, 200, response.body)
                let tuple = try receiptTuple(response.receipt)
                XCTAssertEqual(tuple["model_hash"] as? String, hash, model)
                XCTAssertEqual(tuple["model_id"] as? String, model, model)
                XCTAssertEqual(tuple["tokens_out"] as? Int, model == "model-b" ? 2 : 1, model)
                let usage = (try? JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])?["usage"]
                XCTAssertEqual((usage as? [String: Any])?["completion_tokens"] as? Int, model == "model-b" ? 2 : 1, model)
            }
        }
    }

    /// SPEC-001-R019 over HTTP: a request in flight across a promotion
    /// settles against the member that served it.
    func testHTTPRequestInFlightAcrossAPromotionSettlesAgainstItsMember() async throws {
        for (model, runtime) in [("model-b", \Harness.member), ("model-a", \Harness.primary)] {
            let harness = try Harness()
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
            let builder = ReceiptBuilder(keyStore: WarmFixedReceiptKeyStore(key: key))
            let serving = harness[keyPath: runtime]
            try await withWarmHTTPServer(harness, receiptBuilder: builder) { port in
                let pending = Task {
                    try await warmPost(port: port, model: model, content: "hold", headers: [WarmModelRoute.servedModelHeaderName: model])
                }
                try await warmEventually { await serving.entered }
                _ = try harness.table.promote(modelID: "model-b")
                await serving.releaseHold()
                let response = try await pending.value
                XCTAssertEqual(response.status, 200, response.body)
                let tuple = try receiptTuple(response.receipt)
                XCTAssertEqual(tuple["model_id"] as? String, model, model)
                XCTAssertEqual(tuple["model_hash"] as? String, String(repeating: model == "model-b" ? "b" : "a", count: 64), model)
                XCTAssertEqual(tuple["tokens_out"] as? Int, model == "model-b" ? 2 : 1, model)
            }
            try await warmEventually { harness.leases(model) == 0 }
        }
    }

    private func receiptTuple(_ receipt: String?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let envelope = try XCTUnwrap(receipt, file: file, line: line)
        let tupleBytes = try XCTUnwrap(Data(base64Encoded: String(envelope.split(separator: ".")[0])), file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: tupleBytes) as? [String: Any], file: file, line: line)
    }

    private func withWarmHTTPServer(
        _ harness: Harness, receiptBuilder: ReceiptBuilder? = nil, operation: (Int) async throws -> Void
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(RouterHandler(
                        modelID: "model-a",
                        providerID: "provider-warm-test",
                        coordinatorURL: nil,
                        modelRuntime: harness.primary,
                        warmModels: harness.table,
                        providerStatus: harness.status,
                        // Receipts carry a model hash only with warm swap on.
                        warmSwapEnabled: receiptBuilder != nil,
                        maxBodyBytes: 1_000_000,
                        receiptBuilder: receiptBuilder
                    ))
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        do {
            try await operation(try XCTUnwrap(channel.localAddress?.port))
            try await channel.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

/// A warm-set member that records its calls. Content `fail` throws, `hold`
/// waits for `releaseHold()` or the caller's cancel.
actor WarmFakeRuntime: ModelRuntimeServing, WarmModelRuntime {
    nonisolated let memoryBudgetMemberID: Int
    let modelID: String
    let hash: String
    /// Generations run (complete or stream).
    private(set) var calls = 0
    /// Request handles taken.
    private(set) var handles = 0
    private(set) var entered = false
    private(set) var unloaded = false
    private var holdReleased = false
    private let completionTokens: Int

    init(memberID: Int, modelID: String, hash: String, completionTokens: Int = 1) {
        self.memoryBudgetMemberID = memberID
        self.modelID = modelID
        self.hash = hash
        self.completionTokens = completionTokens
    }

    var loadedModelHash: String? { hash }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { true }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}
    func unregisterInFlight(_ id: Int) {}
    func warmSetRowReservation() -> WarmModelRowReservation { .init(rows: 0, tokensPerRow: 0) }
    func unloadForWarmSet() { unloaded = true }
    func releaseHold() { holdReleased = true }

    private var snapshot: RuntimeSnapshot {
        RuntimeSnapshot(state: .ready, container: nil, modelID: modelID, modelHash: hash)
    }

    func currentSnapshot() -> RuntimeSnapshot { snapshot }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        handles += 1
        return RequestHandle(snapshot: snapshot, registrationID: 0, drainCancelled: DrainCancelToken())
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {}

    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult {
        try await run(request, shouldCancel: shouldCancel)
    }

    func completeWithServedSnapshot(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> (CompletionResult, RuntimeSnapshot) {
        (try await run(request, shouldCancel: shouldCancel), snapshot)
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        onChunk(.content("answer"))
        return try await run(request, shouldCancel: shouldCancel)
    }

    private func run(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult {
        calls += 1
        entered = true
        switch request.messages.last?.content ?? "" {
        case "fail":
            throw APIError(status: 500, message: "member failed", type: "server_error", code: "internal_error")
        case "hold":
            while !holdReleased {
                if shouldCancel() || Task.isCancelled { throw CancellationError() }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        default:
            break
        }
        return CompletionResult(
            content: "answer", finishReason: "stop", promptTokens: 3, completionTokens: completionTokens,
            settlementDisposition: .eligibleOwner)
    }
}

private actor WarmFrameRecorder {
    private(set) var frames: [[String: Any]] = []
    func append(_ frame: [String: Any]) { frames.append(frame) }
    func end(_ requestID: String) -> [String: Any]? {
        frames.last { $0["type"] as? String == "inference_response_end" && $0["request_id"] as? String == requestID }
    }
}

private final class WarmFixedReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey
    init(key: Curve25519.Signing.PrivateKey) { self.key = key }
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey { key }
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? { key }
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}

private struct WarmHTTPResponse: Sendable {
    let status: Int
    let body: String
    let receipt: String?

    private var error: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? [String: Any]
    }

    var errorCode: String? { error?["code"] as? String }
    var retryable: Bool? { error?["retryable"] as? Bool }
}

private func warmPost(
    port: Int,
    model: String,
    content: String = "hello",
    local: Bool = false,
    stream: Bool = false,
    headers: [String: String] = [:]
) async throws -> WarmHTTPResponse {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(local ? RouterHandler.localAppOriginValue : RouterHandler.coordinatorOriginValue,
                     forHTTPHeaderField: RouterHandler.requestOriginHeaderName)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model,
        "messages": [["role": "user", "content": content]],
        "stream": stream,
    ])
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    let http = response as? HTTPURLResponse
    return WarmHTTPResponse(
        status: http?.statusCode ?? 0,
        body: String(decoding: data, as: UTF8.self),
        receipt: http?.value(forHTTPHeaderField: RouterHandler.receiptHeaderName)
    )
}

func warmEventually(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    _ condition: @escaping () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("condition never became true")
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
