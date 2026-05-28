import Foundation
import MacProviderCore
@preconcurrency import NIO
@preconcurrency import NIOHTTP1

struct HTTPServer {
    let config: AppConfig
    let modelRuntime: ModelRuntime
    let providerStatus: ProviderStatus

    func run() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        defer {
            try? group.syncShutdownGracefully()
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        RouterHandler(
                            modelID: config.model,
                            coordinatorURL: config.coordinatorURL,
                            modelRuntime: modelRuntime,
                            providerStatus: providerStatus,
                            maxBodyBytes: config.maxRequestBodyBytes
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: "127.0.0.1", port: config.port).wait()
        print("Listening on http://127.0.0.1:\(config.port)")
        try channel.closeFuture.wait()
    }
}

private final class RouterHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let modelID: String?
    private let coordinatorURL: String?
    private let modelRuntime: ModelRuntime
    private let providerStatus: ProviderStatus
    private let maxBodyBytes: Int
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var bodyTooLarge = false

    init(modelID: String?, coordinatorURL: String?, modelRuntime: ModelRuntime, providerStatus: ProviderStatus, maxBodyBytes: Int) {
        self.modelID = modelID
        self.coordinatorURL = coordinatorURL
        self.modelRuntime = modelRuntime
        self.providerStatus = providerStatus
        self.maxBodyBytes = maxBodyBytes
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)
            bodyTooLarge = false
        case .body(var chunk):
            guard !bodyTooLarge else { return }
            let currentBytes = bodyBuffer?.readableBytes ?? 0
            if currentBytes + chunk.readableBytes > maxBodyBytes {
                bodyTooLarge = true
                bodyBuffer = nil
                return
            }
            bodyBuffer?.writeBuffer(&chunk)
        case .end:
            handleRequest(context: context)
            requestHead = nil
            bodyBuffer = nil
            bodyTooLarge = false
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let requestHead else {
            writeError(context: context, status: .badRequest, message: "missing request head", code: "invalid_request")
            return
        }

        if bodyTooLarge {
            writeAPIError(
                context: context,
                APIError(
                    status: 413,
                    message: "Request body too large",
                    type: "context_length_exceeded",
                    code: "context_length_exceeded"
                )
            )
            return
        }

        switch (requestHead.method, path(from: requestHead.uri)) {
        case (.GET, "/v1/models"):
            handleModelList(context: context)
        case (_, "/v1/models"):
            writeError(context: context, status: .methodNotAllowed, message: "method not allowed", code: "invalid_request")
        case (.GET, "/v1/health"):
            handleHealth(context: context)
        case (_, "/v1/health"):
            writeError(context: context, status: .methodNotAllowed, message: "method not allowed", code: "invalid_request")
        case (.GET, "/v1/status"):
            handleStatus(context: context)
        case (_, "/v1/status"):
            writeError(context: context, status: .methodNotAllowed, message: "method not allowed", code: "invalid_request")
        case (.POST, "/v1/chat/completions"):
            handleChatCompletions(context: context)
        case (_, "/v1/chat/completions"):
            writeError(context: context, status: .methodNotAllowed, message: "method not allowed", code: "invalid_request")
        default:
            writeError(context: context, status: .notFound, message: "not found", code: "invalid_request")
        }
    }

    private func handleModelList(context: ChannelHandlerContext) {
        guard let modelID else {
            writeAPIError(
                context: context,
                APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
            )
            return
        }

        writeJSON(
            context: context,
            status: .ok,
            body: [
                "object": "list",
                "data": [
                    [
                        "id": modelID,
                        "object": "model",
                        "created": 0,
                        "owned_by": "macprovider",
                    ]
                ],
            ]
        )
    }

    private func handleHealth(context: ChannelHandlerContext) {
        let writer = ResponseWriter(context: context)
        let providerStatus = providerStatus
        Task.detached { @Sendable [providerStatus, writer] in
            let snapshot = await providerStatus.snapshot()
            let status: HTTPResponseStatus
            switch snapshot.status {
            case .ready, .busy:
                status = .ok
            case .degraded, .draining, .unavailable:
                status = .serviceUnavailable
            }
            writer.writeJSON(status: status, body: Self.healthResponse(snapshot))
        }
    }

    private func handleStatus(context: ChannelHandlerContext) {
        let writer = ResponseWriter(context: context)
        let providerStatus = providerStatus
        let coordinatorURL = coordinatorURL
        Task.detached { @Sendable [providerStatus, writer, coordinatorURL] in
            let snapshot = await providerStatus.snapshot()
            writer.writeJSON(status: .ok, body: Self.statusResponse(snapshot, coordinatorURL: coordinatorURL))
        }
    }

    private func handleChatCompletions(context: ChannelHandlerContext) {
        var body = bodyBuffer ?? context.channel.allocator.buffer(capacity: 0)
        let data = Data(body.readBytes(length: body.readableBytes) ?? [])
        let writer = ResponseWriter(context: context)
        let modelRuntime = modelRuntime

        do {
            let request = try ChatCompletionRequest.parse(data: data)
            try request.validateModelMatches(modelID)

            if request.stream {
                handleStreamingChatCompletions(request: request, writer: writer, modelRuntime: modelRuntime)
                return
            }

            let providerStatus = providerStatus
            Task.detached { @Sendable [modelRuntime, providerStatus, request, writer] in
                let startedAt = await providerStatus.beginRequest()
                do {
                    let completion = try await modelRuntime.complete(request)
                    await providerStatus.finishRequest(startedAt: startedAt, completion: completion, failed: false)
                    let response = Self.chatCompletionResponse(request: request, completion: completion)
                    writer.writeJSON(status: .ok, body: response)
                } catch let error as APIError {
                    await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                    writer.writeAPIError(error)
                } catch {
                    await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                    writer.writeAPIError(
                        APIError(status: 503, message: "Model inference failed", type: "server_error", code: "model_not_loaded")
                    )
                }
            }
        } catch let error as APIError {
            Task {
                await providerStatus.recordError()
            }
            writeAPIError(context: context, error)
        } catch {
            Task {
                await providerStatus.recordError()
            }
            writeAPIError(
                context: context,
                APIError(status: 400, message: "Invalid request", code: "invalid_request")
            )
        }
    }

    private func handleStreamingChatCompletions(
        request: ChatCompletionRequest,
        writer: ResponseWriter,
        modelRuntime: ModelRuntime
    ) {
        let created = Int(Date().timeIntervalSince1970)
        let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"

        let providerStatus = providerStatus
        Task.detached { @Sendable [modelRuntime, providerStatus, request, writer] in
            let startedAt = await providerStatus.beginRequest()
            do {
                try await modelRuntime.preflight(request)
            } catch let error as APIError {
                await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                writer.writeAPIError(error)
                return
            } catch {
                await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                writer.writeAPIError(
                    APIError(status: 503, message: "Model inference failed", type: "server_error", code: "model_not_loaded")
                )
                return
            }

            writer.startSSE()
            writer.writeSSEJSON(
                Self.chatCompletionChunk(
                    id: id,
                    created: created,
                    model: request.model,
                    delta: ["role": "assistant", "content": ""],
                    finishReason: NSNull()
                )
            )

            do {
                let completion = try await modelRuntime.stream(request) { chunk in
                    writer.writeSSEJSON(
                        Self.chatCompletionChunk(
                            id: id,
                            created: created,
                            model: request.model,
                            delta: ["content": chunk],
                            finishReason: NSNull()
                        )
                    )
                }
                await providerStatus.finishRequest(startedAt: startedAt, completion: completion, failed: false)

                writer.writeSSEJSON(
                    Self.chatCompletionChunk(
                        id: id,
                        created: created,
                        model: request.model,
                        delta: [:],
                        finishReason: completion.finishReason
                    )
                )
                writer.writeSSEJSON(
                    [
                        "id": id,
                        "object": "chat.completion.chunk",
                        "created": created,
                        "model": request.model,
                        "choices": [],
                        "usage": [
                            "prompt_tokens": completion.promptTokens,
                            "completion_tokens": completion.completionTokens,
                            "total_tokens": completion.promptTokens + completion.completionTokens,
                        ],
                    ]
                )
                writer.writeSSEDone()
            } catch let error as APIError {
                await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                writer.writeSSEJSON(error.envelope)
                writer.writeSSEDone()
            } catch {
                await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                writer.writeSSEJSON(
                    APIError(
                        status: 500,
                        message: "Inference engine error",
                        type: "server_error",
                        code: "internal_error"
                    ).envelope
                )
                writer.writeSSEDone()
            }
        }
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
            "usage": [
                "prompt_tokens": completion.promptTokens,
                "completion_tokens": completion.completionTokens,
                "total_tokens": completion.promptTokens + completion.completionTokens,
            ],
        ]
    }

    private static func healthResponse(_ snapshot: ProviderSnapshot) -> [String: Any] {
        [
            "status": snapshot.status.rawValue,
            "model": snapshot.modelID ?? NSNull(),
            "model_loaded": snapshot.modelLoaded,
            "uptime_s": snapshot.uptimeSeconds,
            "requests_total": snapshot.requestsTotal,
            "requests_in_flight": snapshot.requestsInFlight,
            "requests_queued": snapshot.requestsQueued,
            "errors_total": snapshot.errorsTotal,
            "memory_rss_mb": snapshot.memoryRSSMB,
            "capacity": [
                "ram_gb": snapshot.capacity.ramGB,
                "ram_tier": snapshot.capacity.ramTier,
                "max_context_tokens": snapshot.capacity.maxContextTokens,
                "max_concurrency": snapshot.capacity.maxConcurrency,
                "throughput_tps_estimate": snapshot.capacity.throughputTPSEstimate,
            ],
        ]
    }

    private static func statusResponse(_ snapshot: ProviderSnapshot, coordinatorURL: String?) -> [String: Any] {
        [
            "binary_version": CoordinatorClient.binaryVersion,
            "status": snapshot.status.rawValue,
            "model": snapshot.modelID ?? NSNull(),
            "model_loaded": snapshot.modelLoaded,
            "uptime_s": snapshot.uptimeSeconds,
            "requests_total": snapshot.requestsTotal,
            "requests_in_flight": snapshot.requestsInFlight,
            "active_request_id_count": snapshot.activeRequestIDCount,
            "errors_total": snapshot.errorsTotal,
            "memory_rss_mb": snapshot.memoryRSSMB,
            "capacity": [
                "ram_gb": snapshot.capacity.ramGB,
                "ram_tier": snapshot.capacity.ramTier,
                "max_context_tokens": snapshot.capacity.maxContextTokens,
                "max_concurrency": snapshot.capacity.maxConcurrency,
                "throughput_tps_estimate": snapshot.capacity.throughputTPSEstimate,
            ],
            "coordinator": [
                "url": jsonNullable(coordinatorURL),
                "connected": snapshot.coordinatorConnected,
                "session": jsonNullable(snapshot.coordinatorAssignedID),
                "tier": jsonNullable(snapshot.coordinatorTier),
                "recommended_binary_version": jsonNullable(snapshot.recommendedBinaryVersion),
            ],
        ]
    }

    private static func jsonNullable(_ value: String?) -> Any {
        value ?? NSNull()
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

    private func writeError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String, code: String) {
        writeAPIError(
            context: context,
            APIError(status: Int(status.code), message: message, code: code)
        )
    }

    private func writeAPIError(context: ChannelHandlerContext, _ error: APIError) {
        writeJSON(
            context: context,
            status: HTTPResponseStatus(statusCode: error.status),
            body: error.envelope
        )
    }

    private func writeJSON(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Any) {
        do {
            let data = try encodeJSONObject(body)
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: "\(data.count)")
            headers.add(name: "connection", value: "close")

            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)

            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            context.close(promise: nil)
        } catch {
            context.close(promise: nil)
        }
    }

    private func path(from uri: String) -> String {
        String(uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }
}

private struct ResponseWriter: @unchecked Sendable {
    let context: ChannelHandlerContext

    func writeJSON(status: HTTPResponseStatus, body: Any) {
        do {
            let data = try encodeJSONObject(body)
            context.eventLoop.execute {
                writeRawJSON(context: context, status: status, data: data)
            }
        } catch {
            context.eventLoop.execute {
                context.close(promise: nil)
            }
        }
    }

    func writeAPIError(_ error: APIError) {
        writeJSON(status: HTTPResponseStatus(statusCode: error.status), body: error.envelope)
    }

    func startSSE() {
        context.eventLoop.execute {
            writeRawSSEHead(context: context)
        }
    }

    func writeSSEJSON(_ body: Any) {
        do {
            let data = try encodeJSONObject(body)
            let payload = String(decoding: data, as: UTF8.self)
            writeSSEData(payload)
        } catch {
            writeSSEData(#"{"error":{"message":"Inference engine error","type":"server_error","code":"internal_error"}}"#)
        }
    }

    func writeSSEDone() {
        writeSSEData("[DONE]")
        context.eventLoop.execute {
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }

    private func writeSSEData(_ payload: String) {
        context.eventLoop.execute {
            writeRawSSEData(context: context, payload: payload)
        }
    }
}

private func writeRawJSON(context: ChannelHandlerContext, status: HTTPResponseStatus, data: Data) {
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "application/json")
    headers.add(name: "content-length", value: "\(data.count)")
    headers.add(name: "connection", value: "close")

    let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
    context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)

    var buffer = context.channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
    context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
    context.close(promise: nil)
}

private func writeRawSSEHead(context: ChannelHandlerContext) {
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "text/event-stream; charset=utf-8")
    headers.add(name: "cache-control", value: "no-cache")
    headers.add(name: "connection", value: "close")
    headers.add(name: "transfer-encoding", value: "chunked")

    let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
    context.writeAndFlush(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
}

private func writeRawSSEData(context: ChannelHandlerContext, payload: String) {
    let line = "data: \(payload)\n\n"
    var buffer = context.channel.allocator.buffer(capacity: line.utf8.count)
    buffer.writeString(line)
    context.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
}

private func encodeJSONObject(_ body: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
}
