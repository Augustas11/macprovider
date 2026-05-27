import Foundation
import MacProviderCore
@preconcurrency import NIO
@preconcurrency import NIOHTTP1

struct HTTPServer {
    let config: AppConfig
    let modelRuntime: ModelRuntime

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
                            modelRuntime: modelRuntime,
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
    private let modelRuntime: ModelRuntime
    private let maxBodyBytes: Int
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var bodyTooLarge = false

    init(modelID: String?, modelRuntime: ModelRuntime, maxBodyBytes: Int) {
        self.modelID = modelID
        self.modelRuntime = modelRuntime
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
                APIError(status: 413, message: "Request body too large", code: "context_length_exceeded")
            )
            return
        }

        switch (requestHead.method, path(from: requestHead.uri)) {
        case (.GET, "/v1/models"):
            handleModelList(context: context)
        case (_, "/v1/models"):
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

    private func handleChatCompletions(context: ChannelHandlerContext) {
        var body = bodyBuffer ?? context.channel.allocator.buffer(capacity: 0)
        let data = Data(body.readBytes(length: body.readableBytes) ?? [])
        let writer = ResponseWriter(context: context)
        let modelRuntime = modelRuntime

        do {
            let request = try ChatCompletionRequest.parse(data: data)
            try request.validateModelMatches(modelID)

            Task.detached { @Sendable [modelRuntime, request, writer] in
                do {
                    let completion = try await modelRuntime.complete(request)
                    let response = Self.chatCompletionResponse(request: request, completion: completion)
                    writer.writeJSON(status: .ok, body: response)
                } catch let error as APIError {
                    writer.writeAPIError(error)
                } catch {
                    writer.writeAPIError(
                        APIError(status: 503, message: "Model inference failed", type: "server_error", code: "model_not_loaded")
                    )
                }
            }
        } catch let error as APIError {
            writeAPIError(context: context, error)
        } catch {
            writeAPIError(
                context: context,
                APIError(status: 400, message: "Invalid request", code: "invalid_request")
            )
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
            let data = try JSONSerialization.data(withJSONObject: body)
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
            let data = try JSONSerialization.data(withJSONObject: body)
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
