import Foundation
import MacProviderCore
import NIO
import NIOHTTP1
import XCTest
@testable import macprovider_cli

/// Real loopback HTTP requests exercise the route guard and shared inference
/// pipeline without loading weights or entering a hardware inference path.
final class HTTPServerLocalResponsesTests: XCTestCase {
    func testMessagesUseSharedRuntimeAndAnthropicResponseShape() async throws {
        let runtime = LocalResponsesRuntime()
        try await withServer(runtime: runtime) { port in
            let response = try await self.post(port: port, path: "/v1/messages", body: self.messagesBody())
            XCTAssertEqual(response.statusCode, 200)
            let object = try self.object(response.data)
            XCTAssertEqual(object["type"] as? String, "message")
            XCTAssertEqual(object["role"] as? String, "assistant")
            XCTAssertEqual(object["model"] as? String, "fixture-model")
            XCTAssertEqual(object["stop_reason"] as? String, "end_turn")
            let content = try XCTUnwrap(object["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["type"] as? String, "text")
            XCTAssertEqual(content.first?["text"] as? String, "answer")
            let usage = try XCTUnwrap(object["usage"] as? [String: Any])
            XCTAssertEqual(usage["input_tokens"] as? Int, 2)
            XCTAssertEqual(usage["output_tokens"] as? Int, 1)
        }
        let calls = await runtime.calls
        XCTAssertEqual(calls, 1)
    }

    func testMessagesStreamUsesAnthropicEventsWithoutChatDoneSentinel() async throws {
        try await withServer(runtime: LocalResponsesRuntime()) { port in
            let response = try await self.post(port: port, path: "/v1/messages", body: self.messagesBody(stream: true))
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertTrue(response.contentType.hasPrefix("text/event-stream"))
            let text = String(decoding: response.data, as: UTF8.self)
            let frames = try self.events(response.data)
            XCTAssertEqual(frames.first?["type"] as? String, "message_start")
            XCTAssertEqual(frames.last?["type"] as? String, "message_stop")
            XCTAssertEqual(frames.filter { $0["type"] as? String == "message_stop" }.count, 1)
            XCTAssertEqual(frames.filter { $0["type"] as? String == "content_block_delta" }
                .compactMap { ($0["delta"] as? [String: Any])?["text"] as? String }.joined(), "answer")
            XCTAssertTrue(text.contains("event: message_start\n"), text)
            XCTAssertTrue(text.contains("event: content_block_stop\n"), text)
            XCTAssertFalse(text.contains("data: [DONE]"), text)
            XCTAssertFalse(text.contains("chat.completion.chunk"), text)
        }
    }

    func testMessagesPreserveNativeStopMetadata() async throws {
        for stream in [false, true] {
            try await withServer(runtime: LocalResponsesRuntime(stopSequence: "END")) { port in
                var body = self.messagesBody(stream: stream)
                body["stop_sequences"] = ["END"]
                let response = try await self.post(port: port, path: "/v1/messages", body: body)
                XCTAssertEqual(response.statusCode, 200)
                let stop: [String: Any]
                if stream {
                    let terminal = try XCTUnwrap(self.events(response.data).first { $0["type"] as? String == "message_delta" })
                    stop = try XCTUnwrap(terminal["delta"] as? [String: Any])
                } else { stop = try self.object(response.data) }
                XCTAssertEqual(stop["stop_reason"] as? String, "stop_sequence")
                XCTAssertEqual(stop["stop_sequence"] as? String, "END")
            }
        }
    }
    func testMessagesGuardFailuresAndMethodsAreAnthropicErrors() async throws {
        let runtime = LocalResponsesRuntime()
        try await withServer(runtime: runtime) { port in
            for (headers, expectedStatus, expectedCode) in [
                (["Origin": "https://evil.example"], 403, "browser_request_forbidden"),
                (["Sec-Fetch-Site": "cross-site"], 403, "browser_request_forbidden"),
                (["Content-Type": "text/plain"], 415, "request_content_type_unsupported"),
                (["Content-Encoding": "gzip"], 415, "request_content_encoding_unsupported"),
                (["X-MacProvider-Privacy-Class": "private"], 400, PrivacyClassConstants.downgradeRejected),
            ] {
                let response = try await self.post(port: port, path: "/v1/messages", headers: headers, body: self.messagesBody())
                XCTAssertEqual(response.statusCode, expectedStatus)
                let object = try self.object(response.data)
                XCTAssertEqual(object["type"] as? String, "error")
                let error = try XCTUnwrap(object["error"] as? [String: Any])
                XCTAssertEqual(error["code"] as? String, expectedCode)
                XCTAssertNotNil(error["message"] as? String)
            }
            for value: Any in ["private", NSNull()] {
                var markedBody = self.messagesBody()
                markedBody["privacy_class"] = value
                let marked = try await self.post(port: port, path: "/v1/messages", body: markedBody)
                XCTAssertEqual(marked.statusCode, 400)
                let error = try XCTUnwrap(self.object(marked.data)["error"] as? [String: Any])
                XCTAssertEqual(error["code"] as? String, PrivacyClassConstants.downgradeRejected)
            }
            let malformed = try await self.post(port: port, path: "/v1/messages", body: ["model": "fixture-model"])
            XCTAssertEqual(malformed.statusCode, 400)
            XCTAssertEqual(try self.object(malformed.data)["type"] as? String, "error")
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/messages")))
            request.httpMethod = "GET"
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 405)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Allow"), "POST")
            XCTAssertEqual(try self.object(data)["type"] as? String, "error")
        }
        let calls = await runtime.calls
        XCTAssertEqual(calls, 0)
    }

    func testMessagesRuntimeFailuresRemainAnthropicErrors() async throws {
        for stream in [false, true] {
            try await withServer(runtime: LocalResponsesRuntime(failAfterChunk: true)) { port in
                let response = try await self.post(port: port, path: "/v1/messages", body: self.messagesBody(stream: stream))
                XCTAssertEqual(response.statusCode, stream ? 200 : 500)
                if stream {
                    let frames = try self.events(response.data)
                    let errors = frames.filter { $0["type"] as? String == "error" }
                    XCTAssertEqual(errors.count, 1)
                    XCTAssertEqual((errors.first?["error"] as? [String: Any])?["code"] as? String, "fixture_failure")
                    XCTAssertFalse(frames.contains { $0["type"] as? String == "message_stop" })
                } else {
                    let object = try self.object(response.data)
                    XCTAssertEqual(object["type"] as? String, "error")
                    XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "fixture_failure")
                }
            }
        }
    }

    func testBuyerPreemptsLocalMessagesWithoutFailingBuyer() async throws {
        for stream in [false, true] {
            let runtime = LocalResponsesRuntime(awaitDisconnect: true, holdFirstRequestOnly: true)
            let status = ProviderStatus(modelID: "fixture-model", modelLoaded: true, capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1))
            try await withServer(runtime: runtime, providerStatus: status) { port in
                let local = Task {
                    try await self.post(port: port, path: "/v1/messages", headers: [
                        RouterHandler.requestOriginHeaderName: RouterHandler.localAppOriginValue,
                    ], body: self.messagesBody(stream: stream))
                }
                do {
                    try await self.waitUntil { await runtime.entered }
                    let active = await status.snapshot()
                    XCTAssertEqual(active.localUsage.requestsInFlight, 1)
                    XCTAssertEqual(active.requestsInFlight, 0)
                    let buyer = try await self.post(port: port, path: "/v1/chat/completions", body: [
                        "model": "fixture-model", "messages": [["role": "user", "content": "buyer"]],
                    ])
                    XCTAssertEqual(buyer.statusCode, 200)
                    let response = try await local.value
                    if stream {
                        XCTAssertEqual(response.statusCode, 200)
                        let frames = try self.events(response.data)
                        let errors = frames.filter { $0["type"] as? String == "error" }
                        XCTAssertEqual(errors.count, 1)
                        XCTAssertEqual((errors.first?["error"] as? [String: Any])?["code"] as? String, "local_preempted")
                        XCTAssertFalse(frames.contains { $0["type"] as? String == "message_stop" })
                    } else {
                        XCTAssertEqual(response.statusCode, 503)
                        let object = try self.object(response.data)
                        XCTAssertEqual(object["type"] as? String, "error")
                        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "local_preempted")
                    }
                    let finished = await status.snapshot(resetWindow: true)
                    XCTAssertEqual(finished.localUsage.requestsPreempted, 1)
                    XCTAssertEqual(finished.requestsServedSinceLast, 1)
                } catch {
                    local.cancel()
                    _ = await local.result
                    throw error
                }
            }
        }
    }

    private func messagesBody(stream: Bool = false) -> [String: Any] {
        ["model": "fixture-model", "max_tokens": 64, "stream": stream,
         "messages": [["role": "user", "content": "hello"]]]
    }

    func testResponsesAndChatUseTheSameRuntime() async throws {
        let runtime = LocalResponsesRuntime()
        try await withServer(runtime: runtime) { port in
            let response = try await self.post(port: port, body: ["model": "fixture-model", "input": "hello"])
            XCTAssertEqual(response.statusCode, 200)
            let object = try self.object(response.data)
            XCTAssertEqual(object["object"] as? String, "response")
            XCTAssertEqual(object["status"] as? String, "completed")
            let output = try XCTUnwrap(object["output"] as? [[String: Any]])
            let content = try XCTUnwrap(output.first?["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["type"] as? String, "output_text")
            XCTAssertEqual(content.first?["text"] as? String, "answer")
            let usage = try XCTUnwrap(object["usage"] as? [String: Any])
            XCTAssertEqual(usage["input_tokens"] as? Int, 2)
            XCTAssertEqual(usage["output_tokens"] as? Int, 1)

            let chat = try await self.post(port: port, path: "/v1/chat/completions", body: [
                "model": "fixture-model", "messages": [["role": "user", "content": "hello"]],
            ])
            XCTAssertEqual(chat.statusCode, 200)
            XCTAssertEqual(try self.object(chat.data)["object"] as? String, "chat.completion")
        }
        let calls = await runtime.calls
        XCTAssertEqual(calls, 2)
    }

    func testResponsesRejectBrowserAndUnsupportedContentBeforeInference() async throws {
        let runtime = LocalResponsesRuntime()
        try await withServer(runtime: runtime) { port in
            for (headers, expectedStatus, expectedCode) in [
                (["Origin": "https://evil.example"], 403, "browser_request_forbidden"),
                (["Sec-Fetch-Site": "cross-site"], 403, "browser_request_forbidden"),
                (["Content-Type": "text/plain"], 415, "request_content_type_unsupported"),
                (["Content-Encoding": "gzip"], 415, "request_content_encoding_unsupported"),
            ] {
                let response = try await self.post(port: port, headers: headers, body: ["model": "fixture-model", "input": "hello"])
                XCTAssertEqual(response.statusCode, expectedStatus)
                let error = try XCTUnwrap(self.object(response.data)["error"] as? [String: Any])
                XCTAssertEqual(error["code"] as? String, expectedCode)
            }
        }
        let calls = await runtime.calls
        XCTAssertEqual(calls, 0)
    }

    func testUnsupportedResponsesFieldsFailBeforeInference() async throws {
        let runtime = LocalResponsesRuntime()
        try await withServer(runtime: runtime) { port in
            for (field, value) in [
                ("previous_response_id", "resp_old" as Any),
                ("background", true as Any),
                ("store", true as Any),
            ] {
                let response = try await self.post(port: port, body: ["model": "fixture-model", "input": "hello", field: value])
                XCTAssertEqual(response.statusCode, 400, field)
                let error = try XCTUnwrap(self.object(response.data)["error"] as? [String: Any])
                XCTAssertEqual(error["param"] as? String, field)
            }
        }
        let calls = await runtime.calls
        XCTAssertEqual(calls, 0)
    }

    func testStreamingResponsesUseNamedEventsAndOneCompletedTerminal() async throws {
        try await withServer(runtime: LocalResponsesRuntime()) { port in
            let response = try await self.post(port: port, body: ["model": "fixture-model", "input": "hello", "stream": true])
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertTrue(response.contentType.hasPrefix("text/event-stream"))
            let text = String(decoding: response.data, as: UTF8.self)
            XCTAssertTrue(text.contains("event: response.created\n"), text)
            let frames = try self.events(response.data)
            XCTAssertEqual(frames.first?["type"] as? String, "response.created")
            XCTAssertEqual(frames.last?["type"] as? String, "response.completed")
            XCTAssertEqual(frames.filter { $0["type"] as? String == "response.completed" }.count, 1)
            XCTAssertEqual(frames.filter { $0["type"] as? String == "response.output_text.delta" }.compactMap { $0["delta"] as? String }.joined(), "answer")
            XCTAssertEqual(text.components(separatedBy: "data: [DONE]").count - 1, 1, text)
            XCTAssertFalse(text.contains("chat.completion.chunk"), text)
        }
    }

    func testNonStreamingFailureRemainsAnHTTPError() async throws {
        try await withServer(runtime: LocalResponsesRuntime(failAfterChunk: true)) { port in
            let response = try await self.post(port: port, body: ["model": "fixture-model", "input": "hello"])
            XCTAssertEqual(response.statusCode, 500)
            let error = try XCTUnwrap(self.object(response.data)["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "fixture_failure")
        }
    }

    func testStreamingFailureAfterTextHasOneFailedTerminalAndNoSuccess() async throws {
        try await withServer(runtime: LocalResponsesRuntime(failAfterChunk: true)) { port in
            let response = try await self.post(port: port, body: ["model": "fixture-model", "input": "hello", "stream": true])
            XCTAssertEqual(response.statusCode, 200)
            let frames = try self.events(response.data)
            XCTAssertTrue(frames.contains { $0["type"] as? String == "response.output_text.delta" })
            XCTAssertEqual(frames.filter { $0["type"] as? String == "response.failed" }.count, 1)
            XCTAssertEqual(frames.last?["type"] as? String, "response.failed")
            XCTAssertFalse(frames.contains { $0["type"] as? String == "response.completed" })
        }
    }

    func testCapabilitiesDescribeExactRuntimeSupportAndUtilityRoutes() async throws {
        for supported in [true, false] {
            let runtime = LocalResponsesRuntime(tokenUtilitiesSupported: supported)
            try await withServer(runtime: runtime) { port in
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                let (data, _) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!)
                let capabilities = try self.object(data)
                XCTAssertEqual(capabilities["model"] as? String, "fixture-model")
                let messages = try XCTUnwrap(capabilities["messages"] as? [String: Any])
                XCTAssertEqual(messages["endpoint"] as? String, "/v1/messages")
                XCTAssertEqual(messages["stateless"] as? Bool, true)
                XCTAssertEqual(messages["available"] as? Bool, true)
                XCTAssertEqual(messages["model"] as? String, "fixture-model")
                XCTAssertEqual(messages["stream"] as? Bool, true)
                let (statusData, _) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/v1/status")!)
                let contract = try XCTUnwrap(self.object(statusData)["local_status_contract"] as? [String: Any])
                XCTAssertTrue((contract["capabilities"] as? [String] ?? []).contains("local_anthropic_messages_v1"))
                let responses = try XCTUnwrap(capabilities["responses"] as? [String: Any])
                XCTAssertEqual(responses["available"] as? Bool, true)
                XCTAssertEqual(responses["model"] as? String, "fixture-model")
                XCTAssertEqual(responses["model_hash"] as? String, "fixture-hash")
                XCTAssertEqual(responses["generation"] as? Int, 7)
                XCTAssertEqual(responses["tool_choice_modes"] as? [String], supported ? ["auto", "none"] : ["auto"])
                XCTAssertEqual(responses["text_formats"] as? [String], supported ? ["text", "json_object", "json_schema"] : ["text"])
                XCTAssertEqual(responses["upstream_text_formats"] as? [String], supported ? [] : ["json_object", "json_schema"])
                XCTAssertEqual(responses["structured_output_enforcement"] as? String,
                    supported ? "json_object_and_strict_json_schema_validated" : "upstream_dependent")
                let utilities = try XCTUnwrap(capabilities["token_utilities"] as? [String: Any])
                XCTAssertEqual(utilities["supported"] as? Bool, supported)
                XCTAssertEqual(utilities["endpoints"] as? [String], supported ? ["/v1/tokenize", "/v1/detokenize", "/v1/apply-template"] : [])
                for (path, payload) in [
                    ("tokenize", ["text": "hello"] as [String: Any]),
                    ("detokenize", ["tokens": [11, 12]] as [String: Any]),
                    ("apply-template", ["messages": [["role": "user", "content": "hello"]]] as [String: Any]),
                ] {
                    var body = payload
                    body["model"] = "fixture-model"
                    let response = try await self.post(port: port, path: "/v1/" + path, body: body)
                    XCTAssertEqual(response.statusCode, supported ? 200 : 501)
                    let object = try self.object(response.data)
                    if supported {
                        XCTAssertEqual(object["model"] as? String, "fixture-model")
                        XCTAssertEqual(object["generation"] as? Int, 7)
                        if path == "detokenize" { XCTAssertEqual(object["text"] as? String, "hello") }
                        else { XCTAssertEqual(object["tokens"] as? [Int], [11, 12]) }
                    } else {
                        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "token_utilities_unsupported")
                    }
                }
            }
            let calls = await runtime.calls
            XCTAssertEqual(calls, 0, "Utilities must not enter generation")
        }
    }

    func testClientDisconnectCancelsResponsesAndTokenUtilities() async throws {
        for path in ["/v1/responses", "/v1/messages", "/v1/tokenize"] {
            let runtime = LocalResponsesRuntime(awaitDisconnect: true)
            let status = ProviderStatus(modelID: "fixture-model", modelLoaded: true, capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1))
            try await withServer(runtime: runtime, providerStatus: status) { port in
                let task = Task {
                    // A Responses client marks itself local (SPEC-001-R011);
                    // token utilities are always local.
                    try await self.post(port: port, path: path, headers: [
                        RouterHandler.requestOriginHeaderName: RouterHandler.localAppOriginValue,
                    ], body: path == "/v1/messages" ? self.messagesBody() : (path == "/v1/responses"
                        ? ["model": "fixture-model", "input": "hello"]
                        : ["model": "fixture-model", "text": "hello"]))
                }
                do {
                    try await self.waitUntil { await runtime.entered }
                    // SPEC-001-R011: local work is counted apart from buyer
                    // work and never consumes a published buyer slot.
                    let active = await status.snapshot()
                    XCTAssertEqual(active.localUsage.requestsInFlight, 1)
                    XCTAssertEqual(active.requestsInFlight, 0)
                    XCTAssertEqual(active.slotsFree, 1)
                    task.cancel()
                    _ = await task.result
                    try await self.waitUntil { await runtime.cancelled }
                    try await self.waitUntil { await status.snapshot().localUsage.requestsInFlight == 0 }
                    let drained = await status.snapshot()
                    XCTAssertEqual(drained.slotsFree, 1)
                    XCTAssertEqual(drained.requestsTotal, 0)
                } catch {
                    task.cancel()
                    _ = await task.result
                    throw error
                }
            }
            let cancelled = await runtime.cancelled
            XCTAssertTrue(cancelled, path)
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "LocalResponsesTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for runtime"])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func events(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            .filter { $0.hasPrefix("data: ") && $0 != "data: [DONE]" }
            .map { try object(Data($0.dropFirst(6).utf8)) }
    }

    private func post(port: Int, path: String = "/v1/responses", headers: [String: String] = [:], body: [String: Any]) async throws -> (statusCode: Int, contentType: String, data: Data) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type") ?? "", data)
    }

    private func withServer<T>(runtime: LocalResponsesRuntime, providerStatus: ProviderStatus? = nil, operation: (Int) async throws -> T) async throws -> T {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let status = providerStatus ?? ProviderStatus(modelID: "fixture-model", modelLoaded: true, capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1))
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(RouterHandler(
                        modelID: "fixture-model", providerID: "fixture-provider", coordinatorURL: nil,
                        modelRuntime: runtime, providerStatus: status, warmSwapEnabled: false,
                        maxBodyBytes: 1_000_000, receiptBuilder: nil
                    ))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        do {
            let result = try await operation(try XCTUnwrap(channel.localAddress?.port))
            try await channel.close().get()
            try await group.shutdownGracefully()
            return result
        } catch {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private actor LocalResponsesRuntime: ModelRuntimeServing {
    private(set) var calls = 0
    let failAfterChunk: Bool
    let stopSequence: String?
    let tokenUtilitiesSupported: Bool
    let awaitDisconnect: Bool
    let holdFirstRequestOnly: Bool
    private(set) var entered = false
    private(set) var cancelled = false
    init(failAfterChunk: Bool = false, tokenUtilitiesSupported: Bool = true, awaitDisconnect: Bool = false, holdFirstRequestOnly: Bool = false, stopSequence: String? = nil) {
        self.failAfterChunk = failAfterChunk
        self.stopSequence = stopSequence
        self.tokenUtilitiesSupported = tokenUtilitiesSupported
        self.awaitDisconnect = awaitDisconnect
        self.holdFirstRequestOnly = holdFirstRequestOnly
    }
    func localResponsesCapabilities() async -> LocalResponsesCapabilities {
        .loaded(model: "fixture-model", modelHash: "fixture-hash", generation: 7,
                runtime: tokenUtilitiesSupported ? "mlx_cache" : "external_openai_loopback")
    }
    func localTokenUtilityCapabilities() async -> LocalTokenUtilityCapabilities {
        LocalTokenUtilityCapabilities(model: "fixture-model", modelHash: nil, generation: 7,
            operations: tokenUtilitiesSupported ? ["tokenize", "detokenize", "apply-template"] : [])
    }
    func localTokenUtility(_ request: LocalTokenUtilityRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> LocalTokenUtilityResult {
        guard tokenUtilitiesSupported else { throw APIError(status: 501, message: "Unsupported", code: "token_utilities_unsupported") }
        try await waitForDisconnectIfNeeded(shouldCancel)
        return LocalTokenUtilityResult(model: request.model, modelHash: nil, generation: 7,
            tokens: request.operation == .detokenize ? nil : [11, 12], text: request.operation == .detokenize ? "hello" : nil)
    }
    private func waitForDisconnectIfNeeded(_ shouldCancel: @escaping @Sendable () -> Bool) async throws {
        guard awaitDisconnect, !holdFirstRequestOnly || calls == 1 else { return }
        entered = true
        do {
            while !shouldCancel() { try await Task.sleep(nanoseconds: 5_000_000) }
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
        cancelled = true
        throw CancellationError()
    }
    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { true }
    nonisolated var isSettlementReceiptEligible: Bool { false }
    nonisolated var settlementRuntimeSource: String? { nil }
    func setProviderStatus(_ providerStatus: ProviderStatus) {}
    func unregisterInFlight(_ id: Int) {}
    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        RequestHandle(snapshot: RuntimeSnapshot(state: .ready, container: nil, modelID: request.model, modelHash: nil), registrationID: 0, drainCancelled: DrainCancelToken())
    }
    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {}
    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult {
        calls += 1
        try await waitForDisconnectIfNeeded(shouldCancel)
        if failAfterChunk { throw APIError(status: 500, message: "Fixture failure", code: "fixture_failure") }
        return result()
    }
    func stream(_ request: ChatCompletionRequest, with handle: RequestHandle, shouldCancel: @escaping @Sendable () -> Bool, onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> CompletionResult {
        calls += 1
        if holdFirstRequestOnly { onChunk(.content("answer")) }
        try await waitForDisconnectIfNeeded(shouldCancel)
        if !holdFirstRequestOnly { onChunk(.content("answer")) }
        if failAfterChunk { throw APIError(status: 500, message: "Fixture failure", code: "fixture_failure") }
        return result()
    }
    private func result() -> CompletionResult {
        CompletionResult(content: "answer", finishReason: "stop", promptTokens: 2, completionTokens: 1, settlementDisposition: .eligibleOwner, stopSequence: stopSequence)
    }
}
