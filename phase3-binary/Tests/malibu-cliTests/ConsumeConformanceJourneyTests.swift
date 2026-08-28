import Foundation
import NIO
import NIOHTTP1
import XCTest
@testable import malibu_cli

final class ConsumeConformanceJourneyTests: XCTestCase {
    func testPhase4FakeGatewayHarnessServesOpenAIAndPricingFixtures() async throws {
        let gateway = try Phase4FakeGateway()
        defer { gateway.stop() }

        let models = try await gateway.request(method: "GET", path: "/v1/models")
        XCTAssertEqual(models.status, 200)
        XCTAssertEqual(models.headers["Content-Type"] as? String, "application/json")
        let modelsObject = try XCTUnwrap(JSONSerialization.jsonObject(with: models.body) as? [String: Any])
        let modelData = try XCTUnwrap(modelsObject["data"] as? [[String: Any]])
        XCTAssertEqual(modelData.compactMap { $0["id"] as? String }, ["llama-test"])

        let rateCard = try await gateway.request(method: "GET", path: "/v1/rate-card")
        XCTAssertEqual(rateCard.status, 200)
        let rateCardObject = try XCTUnwrap(JSONSerialization.jsonObject(with: rateCard.body) as? [String: Any])
        XCTAssertEqual(rateCardObject["schema_version"] as? String, "spec006.rate_card.test.v1")
        XCTAssertEqual(rateCardObject["policy_version"] as? String, "spec045-phase4-fixture")

        let signature = try await gateway.request(method: "GET", path: "/v1/rate-card.sig")
        XCTAssertEqual(signature.status, 200)
        XCTAssertEqual(String(decoding: signature.body, as: UTF8.self), "spec023-test-signature\n")

        let nonStreaming = try await gateway.request(
            method: "POST",
            path: "/v1/chat/completions",
            body: #"{"model":"llama-test","messages":[{"role":"user","content":"ping"}]}"#
        )
        XCTAssertEqual(nonStreaming.status, 200)
        let chatObject = try XCTUnwrap(JSONSerialization.jsonObject(with: nonStreaming.body) as? [String: Any])
        XCTAssertEqual(chatObject["object"] as? String, "chat.completion")
        let usage = try XCTUnwrap(chatObject["usage"] as? [String: Any])
        XCTAssertEqual(usage["total_tokens"] as? Int, 4)

        let streaming = try await gateway.request(
            method: "POST",
            path: "/v1/chat/completions",
            body: #"{"model":"llama-test","stream":true,"messages":[{"role":"user","content":"ping"}]}"#
        )
        XCTAssertEqual(streaming.status, 200)
        XCTAssertEqual(streaming.headers["Content-Type"] as? String, "text/event-stream")
        let streamBody = String(decoding: streaming.body, as: UTF8.self)
        XCTAssertTrue(streamBody.contains(#""object":"chat.completion.chunk""#), streamBody)
        XCTAssertTrue(streamBody.contains(#""usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}"#), streamBody)
        XCTAssertTrue(streamBody.contains("data: [DONE]"), streamBody)

        let upstreamError = try await gateway.request(
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["X-Phase4-Mode": "error"],
            body: #"{"model":"llama-test","messages":[]}"#
        )
        XCTAssertEqual(upstreamError.status, 429)
        let errorObject = try XCTUnwrap(JSONSerialization.jsonObject(with: upstreamError.body) as? [String: Any])
        let error = try XCTUnwrap(errorObject["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "rate_limit_exceeded")

        let redirect = try await gateway.request(
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["X-Phase4-Mode": "redirect"],
            body: #"{"model":"llama-test","messages":[]}"#
        )
        XCTAssertEqual(redirect.status, 307)
        XCTAssertEqual(redirect.headers["Location"] as? String, "https://example.invalid/should-not-follow")

        let truncated = try await gateway.request(
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["X-Phase4-Mode": "truncated-stream"],
            body: #"{"model":"llama-test","stream":true,"messages":[]}"#
        )
        XCTAssertEqual(truncated.status, 200)
        XCTAssertFalse(String(decoding: truncated.body, as: UTF8.self).contains("data: [DONE]"))

        XCTAssertEqual(gateway.requests.map(\.path), [
            "/v1/models",
            "/v1/rate-card",
            "/v1/rate-card.sig",
            "/v1/chat/completions",
            "/v1/chat/completions",
            "/v1/chat/completions",
            "/v1/chat/completions",
            "/v1/chat/completions",
        ])
    }

    func testPhase4CurrentLocalEndpointDoesNotForwardChargeableRequestsBeforeTrustedProxySlice() throws {
        let gateway = try Phase4FakeGateway()
        defer { gateway.stop() }
        let token = try ConsumeLocalToken.generate()
        let runtime = ConsumeEndpointRuntime(
            launchID: "launch-phase4-local-boundary",
            boundURL: "http://127.0.0.1:11435",
            upstreamOrigin: gateway.origin,
            credentialSourceClass: "environment",
            credentialStatus: .environmentLoaded,
            modelAllowlist: ["llama-test"],
            tokenVerifier: token.verifier,
            budget: ConsumeBudgetConfig(
                mode: .noBudget,
                maxRequestMicroUSD: nil,
                allowUnpriced: true,
                ledger: nil,
                ledgerPathClass: nil
            )
        )
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(token.value)")
        headers.add(name: "Content-Type", value: "application/json")

        let response = try localResponse(
            from: runtime,
            head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/chat/completions", headers: headers),
            body: Data(#"{"model":"llama-test","messages":[{"role":"user","content":"do-not-forward"}]}"#.utf8)
        )

        XCTAssertEqual(response.status, .serviceUnavailable)
        XCTAssertEqual(try localErrorCode(from: response.body), "local_pricing_unavailable")
        XCTAssertEqual(try localForwardedFlag(from: response.body), false)
        XCTAssertEqual(response.headers.first(name: "x-macprovider-warning"), "no_budget,unpriced_override")
        XCTAssertEqual(gateway.requests.count, 0)
    }
}

private final class Phase4FakeGateway {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let recorder = Phase4GatewayRecorder()
    private var channel: Channel?
    let origin: String

    init() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [recorder] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(Phase4FakeGatewayHandler(recorder: recorder))
                }
            }
        let bound = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        guard let port = bound.localAddress?.port else {
            try? bound.close().wait()
            throw POSIXError(.EIO)
        }
        channel = bound
        origin = "http://127.0.0.1:\(port)"
    }

    var requests: [Phase4RecordedRequest] {
        recorder.snapshot()
    }

    func request(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: String? = nil
    ) async throws -> Phase4HTTPResponse {
        let url = try XCTUnwrap(URL(string: origin + path))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.httpShouldSetCookies = false
        let delegate = Phase4NoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return Phase4HTTPResponse(status: http.statusCode, headers: http.allHeaderFields, body: data)
    }

    func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private struct Phase4HTTPResponse {
    let status: Int
    let headers: [AnyHashable: Any]
    let body: Data
}

private final class Phase4NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

private struct Phase4RecordedRequest: Equatable {
    let method: String
    let path: String
    let mode: String?
}

private final class Phase4GatewayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Phase4RecordedRequest] = []

    func append(_ request: Phase4RecordedRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func snapshot() -> [Phase4RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class Phase4FakeGatewayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let recorder: Phase4GatewayRecorder
    private var head: HTTPRequestHead?
    private var body = Data()

    init(recorder: Phase4GatewayRecorder) {
        self.recorder = recorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            respond(context: context)
        }
    }

    private func respond(context: ChannelHandlerContext) {
        guard let head else {
            write(context: context, status: .badRequest, contentType: "application/json", body: #"{"error":{"code":"bad_request"}}"#)
            return
        }
        let mode = head.headers.first(name: "x-phase4-mode")
        recorder.append(Phase4RecordedRequest(method: head.method.rawValue, path: head.uri, mode: mode))
        switch (head.method, head.uri, mode) {
        case (.GET, "/v1/models", _):
            write(context: context, status: .ok, contentType: "application/json", body: Self.modelsFixture)
        case (.GET, "/v1/rate-card", _):
            write(context: context, status: .ok, contentType: "application/json", body: Self.rateCardFixture)
        case (.GET, "/v1/rate-card.sig", _):
            write(context: context, status: .ok, contentType: "text/plain", body: "spec023-test-signature\n")
        case (.POST, "/v1/chat/completions", "error"):
            write(context: context, status: HTTPResponseStatus(statusCode: 429), contentType: "application/json", body: Self.errorFixture)
        case (.POST, "/v1/chat/completions", "redirect"):
            write(
                context: context,
                status: HTTPResponseStatus(statusCode: 307),
                contentType: "application/json",
                body: "{}",
                extraHeaders: [("Location", "https://example.invalid/should-not-follow")]
            )
        case (.POST, "/v1/chat/completions", "truncated-stream"):
            write(context: context, status: .ok, contentType: "text/event-stream", body: Self.truncatedStreamFixture)
        case (.POST, "/v1/chat/completions", _):
            let isStreaming = requestWantsStream()
            write(
                context: context,
                status: .ok,
                contentType: isStreaming ? "text/event-stream" : "application/json",
                body: isStreaming ? Self.streamFixture : Self.chatFixture
            )
        default:
            write(context: context, status: .notFound, contentType: "application/json", body: #"{"error":{"code":"not_found"}}"#)
        }
    }

    private func requestWantsStream() -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return object["stream"] as? Bool == true
    }

    private func write(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        contentType: String,
        body: String,
        extraHeaders: [(String, String)] = []
    ) {
        let bytes = Array(body.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(bytes.count)")
        headers.add(name: "Cache-Control", value: "no-store")
        for (name, value) in extraHeaders {
            headers.add(name: name, value: value)
        }
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private static let modelsFixture = """
    {"object":"list","data":[{"id":"llama-test","object":"model","created":0,"owned_by":"macprovider-test"}]}
    """

    private static let rateCardFixture = """
    {"schema_version":"spec006.rate_card.test.v1","policy_version":"spec045-phase4-fixture","generated_at":"2026-08-23T00:00:00Z","models":{"llama-test":{"input_micro_usd_per_token":"10","output_micro_usd_per_token":"20","max_output_tokens":16}}}
    """

    private static let chatFixture = """
    {"id":"chatcmpl-phase4-test","object":"chat.completion","created":0,"model":"llama-test","choices":[{"index":0,"message":{"role":"assistant","content":"pong"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}
    """

    private static let streamFixture = """
    data: {"id":"chatcmpl-phase4-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"pong"},"finish_reason":null}]}

    data: {"id":"chatcmpl-phase4-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}

    data: [DONE]

    """

    private static let truncatedStreamFixture = """
    data: {"id":"chatcmpl-phase4-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}

    """

    private static let errorFixture = """
    {"error":{"message":"rate limited","type":"rate_limit_error","param":null,"code":"rate_limit_exceeded"}}
    """
}

private func localResponse(
    from runtime: ConsumeEndpointRuntime,
    head: HTTPRequestHead,
    body requestBody: Data = Data()
) throws -> (status: HTTPResponseStatus, headers: HTTPHeaders, body: String) {
    let channel = EmbeddedChannel()
    try channel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime)).wait()
    var responseHead: HTTPResponseHead?
    var responseBody = Data()

    try channel.writeInbound(HTTPServerRequestPart.head(head))
    if !requestBody.isEmpty {
        var buffer = channel.allocator.buffer(capacity: requestBody.count)
        buffer.writeBytes(requestBody)
        try channel.writeInbound(HTTPServerRequestPart.body(buffer))
    }
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
        switch part {
        case .head(let head):
            responseHead = head
        case .body(.byteBuffer(var buffer)):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                responseBody.append(contentsOf: bytes)
            }
        case .end:
            guard let responseHead else {
                XCTFail("response head was not emitted")
                return (.internalServerError, HTTPHeaders(), "")
            }
            return (responseHead.status, responseHead.headers, String(decoding: responseBody, as: UTF8.self))
        default:
            break
        }
    }

    XCTFail("response end was not emitted")
    return (.internalServerError, HTTPHeaders(), String(decoding: responseBody, as: UTF8.self))
}

private func localErrorCode(from body: String) throws -> String {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    let error = try XCTUnwrap(object["error"] as? [String: Any])
    return try XCTUnwrap(error["code"] as? String)
}

private func localForwardedFlag(from body: String) throws -> Bool {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    let error = try XCTUnwrap(object["error"] as? [String: Any])
    let macprovider = try XCTUnwrap(error["macprovider"] as? [String: Any])
    return try XCTUnwrap(macprovider["forwarded_upstream"] as? Bool)
}
