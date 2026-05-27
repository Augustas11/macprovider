import Foundation
import MacProviderCore
import NIO
import NIOHTTP1

struct HTTPServer {
    let config: AppConfig

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
                    channel.pipeline.addHandler(ModelListHandler(modelID: config.model))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: "127.0.0.1", port: config.port).wait()
        print("Listening on http://127.0.0.1:\(config.port)")
        try channel.closeFuture.wait()
    }
}

private final class ModelListHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let modelID: String?
    private var requestHead: HTTPRequestHead?

    init(modelID: String?) {
        self.modelID = modelID
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
        case .body:
            break
        case .end:
            handleRequest(context: context)
            requestHead = nil
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let requestHead else {
            writeJSON(
                context: context,
                status: .badRequest,
                body: ["error": ["message": "missing request head"]]
            )
            return
        }

        guard path(from: requestHead.uri) == "/v1/models" else {
            writeJSON(
                context: context,
                status: .notFound,
                body: ["error": ["message": "not found"]]
            )
            return
        }

        guard requestHead.method == .GET else {
            writeJSON(
                context: context,
                status: .methodNotAllowed,
                body: ["error": ["message": "method not allowed"]]
            )
            return
        }

        guard let modelID else {
            writeJSON(
                context: context,
                status: .serviceUnavailable,
                body: ["error": ["message": "model is not configured"]]
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
