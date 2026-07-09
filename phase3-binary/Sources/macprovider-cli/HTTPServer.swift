import Foundation
import MacProviderCore
@preconcurrency import NIO
@preconcurrency import NIOHTTP1

struct HTTPServer: Sendable {
    let config: AppConfig
    let modelRuntime: ModelRuntime
    let providerStatus: ProviderStatus
    let receiptBuilder: ReceiptBuilder?
    let idlePrewarmer: IdlePrewarmer?
    let catalogModelIDAlias: String?

    init(
        config: AppConfig,
        modelRuntime: ModelRuntime,
        providerStatus: ProviderStatus,
        receiptBuilder: ReceiptBuilder?,
        idlePrewarmer: IdlePrewarmer? = nil,
        catalogModelIDAlias: String? = nil
    ) {
        self.config = config
        self.modelRuntime = modelRuntime
        self.providerStatus = providerStatus
        self.receiptBuilder = receiptBuilder
        self.idlePrewarmer = idlePrewarmer
        self.catalogModelIDAlias = catalogModelIDAlias
    }

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
                            providerID: config.providerID,
                            coordinatorURL: config.coordinatorURL,
                            modelRuntime: modelRuntime,
                            providerStatus: providerStatus,
                            warmSwapEnabled: config.enableWarmSwap,
                            maxBodyBytes: config.maxRequestBodyBytes,
                            receiptBuilder: receiptBuilder,
                            idlePrewarmer: idlePrewarmer,
                            catalogModelIDAlias: catalogModelIDAlias
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

final class RouterHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let modelID: String?
    private let providerID: String?
    private let coordinatorURL: String?
    private let modelRuntime: ModelRuntime
    private let providerStatus: ProviderStatus
    private let warmSwapEnabled: Bool
    private let maxBodyBytes: Int
    private let receiptBuilder: ReceiptBuilder?
    private let idlePrewarmer: IdlePrewarmer?
    private let catalogModelIDAlias: String?
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var bodyTooLarge = false

    init(
        modelID: String?,
        providerID: String?,
        coordinatorURL: String?,
        modelRuntime: ModelRuntime,
        providerStatus: ProviderStatus,
        warmSwapEnabled: Bool,
        maxBodyBytes: Int,
        receiptBuilder: ReceiptBuilder? = nil,
        idlePrewarmer: IdlePrewarmer? = nil,
        catalogModelIDAlias: String? = nil
    ) {
        self.modelID = modelID
        self.providerID = providerID
        self.coordinatorURL = coordinatorURL
        self.modelRuntime = modelRuntime
        self.providerStatus = providerStatus
        self.warmSwapEnabled = warmSwapEnabled
        self.maxBodyBytes = maxBodyBytes
        self.receiptBuilder = receiptBuilder
        self.idlePrewarmer = idlePrewarmer
        self.catalogModelIDAlias = catalogModelIDAlias
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
        let modelRuntime = modelRuntime
        let warmSwapEnabled = warmSwapEnabled
        let providerID = providerID
        let coordinatorURL = coordinatorURL
        Task.detached { @Sendable [providerStatus, modelRuntime, warmSwapEnabled, writer, providerID, coordinatorURL] in
            let snapshot = await providerStatus.snapshot()
            let runtimeSnapshot = warmSwapEnabled ? await modelRuntime.currentSnapshot() : nil
            let telemetryMatchesRuntime = runtimeSnapshot.map { $0.specDecodeGeneration == snapshot.specDecodeGeneration } ?? true
            let telemetryRuntimeEligible = runtimeSnapshot.map { $0.state == .ready && $0.hasTargetCompatibleDraft } ?? true
            writer.writeJSON(
                status: .ok,
                body: Self.statusResponse(
	                    snapshot,
	                    providerID: providerID,
	                    coordinatorURL: coordinatorURL,
	                    runtimeSnapshot: runtimeSnapshot,
	                    specDecodeTelemetryMatchesRuntime: telemetryMatchesRuntime,
	                    specDecodeTelemetryRuntimeEligible: telemetryRuntimeEligible
	                )
            )
        }
    }

    private func handleChatCompletions(context: ChannelHandlerContext) {
        do {
            try Self.validateBrowserRequestHeaders(requestHead?.headers ?? HTTPHeaders())
            try Self.validateJSONContentType(requestHead?.headers.first(name: "Content-Type"))
        } catch let apiErr as APIError {
            writeAPIError(context: context, apiErr)
            return
        } catch {
            writeAPIError(
                context: context,
                APIError(status: 400, message: "Invalid request", code: "invalid_request")
            )
            return
        }

        var body = bodyBuffer ?? context.channel.allocator.buffer(capacity: 0)
        let data = Data(body.readBytes(length: body.readableBytes) ?? [])
        let writer = ResponseWriter(context: context)
        let modelRuntime = modelRuntime
        let warmSwapEnabled = warmSwapEnabled
        let receiptBuilder = receiptBuilder
        let providerID = providerID
        let requestAcceptedAt = Date()
        let auditRequestID = requestHead?.headers.first(name: "X-Request-ID") ?? UUID().uuidString
        let settlementMetadata = Self.settlementMetadata(from: requestHead?.headers.first(name: Self.settlementMetadataHeaderName))
        var parsedRequest: ChatCompletionRequest?

        do {
            try Self.validateContentEncoding(requestHead?.headers["Content-Encoding"] ?? [])
            let request = try ChatCompletionRequest.parse(data: data)
                .withConversationKey(requestHead?.headers.first(name: "X-MacProvider-Provider-Conversation"))
            parsedRequest = request
            if !warmSwapEnabled {
                try request.validateModelMatches(modelID, aliases: modelIDAliasList(catalogModelIDAlias))
            }

            if request.stream {
                if settlementMetadata == nil {
                    ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .streamingRequest)
                }
                handleStreamingChatCompletions(
                    request: request,
                    writer: writer,
                    modelRuntime: modelRuntime,
                    warmSwapEnabled: warmSwapEnabled,
                    receiptBuilder: receiptBuilder,
                    providerID: providerID,
                    requestID: auditRequestID,
                    settlementMetadata: settlementMetadata,
                    idlePrewarmer: idlePrewarmer
                )
                return
            }

            let providerStatus = providerStatus
            let idlePrewarmer = idlePrewarmer
            Task.detached { @Sendable [modelRuntime, providerStatus, request, writer, warmSwapEnabled, receiptBuilder, providerID, auditRequestID, settlementMetadata, idlePrewarmer, requestAcceptedAt] in
                var startedAt = requestAcceptedAt
                var providerRequestStarted = false
                // SPEC-015 §M.2.2 atomic-read invariant — capture
                // the pre-snapshot for warm-swap validation, then
                // call `completeWithServedSnapshot` which returns
                // the actor-isolated snapshot the runtime used to
                // drive generation. Binding `model_hash` to the
                // SERVED snapshot (not the pre-snapshot) closes the
                // interleaving gap a separately-sampled
                // `currentSnapshot()` would leave open. Error /
                // catch paths fall back to the pre-snapshot for the
                // §7.6 / AC-31 error-receipt hash inheritance
                // (no served snapshot exists when complete() throws).
                let preSnapshot = await modelRuntime.currentSnapshot()
                let fallbackHashSource = Self.resolveModelHashSource(
                    warmSwapEnabled: warmSwapEnabled,
                    snapshot: preSnapshot
                )
                do {
                    let handle = try await modelRuntime.acquireRequestHandle(request)
                    defer {
                        Task { await modelRuntime.unregisterInFlight(handle.registrationID) }
                    }
                    startedAt = await providerStatus.beginRequest()
                    providerRequestStarted = true
                    await idlePrewarmer?.cancelInflightPrewarm()
                    let (completion, servedSnapshot) = try await modelRuntime.completeWithServedSnapshot(request, with: handle, shouldCancel: { false })
                    let modelHashSource = Self.resolveModelHashSource(
                        warmSwapEnabled: warmSwapEnabled,
                        snapshot: servedSnapshot
                    )
                    let unixTsSeconds = Int64(Date().timeIntervalSince1970)
                    await providerStatus.finishRequest(startedAt: startedAt, completion: completion, failed: false)
                    KVCacheTelemetry.emitRequestCompleted(
                        providerID: providerID,
                        requestID: auditRequestID,
                        modelID: request.model,
                        stream: false,
                        completion: completion
                    )
                    let response = Self.chatCompletionResponse(request: request, completion: completion)
                    let ttftMs = completion.ttftMilliseconds ?? Self.elapsedMilliseconds(since: startedAt)
                    let terminalStateTSUnixMS = Int64(Date().timeIntervalSince1970 * 1000)
                    // SPEC-015 §M.2.2 — bind the receipt's
                    // `model_hash` to the runtime-served snapshot
                    // returned above by
                    // `completeWithServedSnapshot`. That snapshot
                    // was captured atomically inside the actor turn
                    // that drove generation (validation, in-flight
                    // registration, container.perform), closing the
                    // interleaving gap a separately-sampled
                    // `currentSnapshot()` would leave open.
                    let receipt = try Self.receiptHeaderResult(
                        providerID: providerID,
                        receiptBuilder: receiptBuilder,
                        request: request,
                        outputContent: completion.content,
                        outputToolCalls: completion.toolCalls,
                        finishReason: completion.finishReason,
                        promptTokens: Int64(completion.promptTokens),
                        ttftMs: ttftMs,
                        tokensOut: Int64(completion.completionTokens),
                        unixTsSeconds: unixTsSeconds,
                        modelHashSource: modelHashSource,
                        requestID: auditRequestID,
                        settlementMetadata: settlementMetadata,
                        terminalStateTSUnixMS: terminalStateTSUnixMS
                    )
                    switch receipt {
                    case .issued(let header):
                        let tokensOut = Int64(completion.completionTokens)
                        writer.writeJSON(status: .ok, body: response, extraHeaders: Self.receiptExtraHeaders(header: header, settlementMetadata: settlementMetadata, terminalStateTSUnixMS: terminalStateTSUnixMS)) { delivered in
                            if delivered {
                                ReceiptAudit.emitIssued(providerID: providerID, requestID: auditRequestID, modelID: request.model, tokensOut: tokensOut, ttftMs: ttftMs, unixTs: unixTsSeconds)
                            } else {
                                ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .writeFailed)
                            }
                        }
                    case .omitted(let reason):
                        ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: reason)
                        writer.writeJSON(status: .ok, body: response)
                    }
	                } catch is DrainCancelledError {
	                    if providerRequestStarted {
	                        await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
	                    }
	                    ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .modelSwapViolation)
	                    writer.writeJSON(status: .serviceUnavailable, body: Self.swapDrainTimeoutEnvelope())
	                } catch let apiErr as APIError {
	                    if providerRequestStarted {
	                        await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
	                    }
	                    do {
                        let receipt = try Self.errorReceiptHeaderResult(
                            providerID: providerID,
                            receiptBuilder: receiptBuilder,
                            request: request,
                            error: apiErr,
                            startedAt: startedAt,
                            modelHashSource: fallbackHashSource
                        )
                        switch receipt {
                        case .issued(let header, let ttftMs, let unixTs):
                            writer.writeAPIError(apiErr, extraHeaders: [(Self.receiptHeaderName, header)]) { delivered in
                                if delivered {
                                    ReceiptAudit.emitIssued(providerID: providerID, requestID: auditRequestID, modelID: request.model, tokensOut: 0, ttftMs: ttftMs, unixTs: unixTs)
                                } else {
                                    ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .writeFailed)
                                }
                            }
                        case .omitted(let reason):
                            ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: reason)
                            writer.writeAPIError(apiErr)
                        case .notReceiptEligible:
                            writer.writeAPIError(apiErr)
                        }
                    } catch {
                        ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .constructionFailed)
                        writer.writeAPIError(apiErr)
                    }
	                } catch {
	                    if providerRequestStarted {
	                        await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
	                    }
	                    let apiError =
                        APIError(status: 503, message: "Model inference failed", type: "server_error", code: "model_not_loaded")
                    do {
                        let receipt = try Self.errorReceiptHeaderResult(
                            providerID: providerID,
                            receiptBuilder: receiptBuilder,
                            request: request,
                            error: apiError,
                            startedAt: startedAt,
                            modelHashSource: fallbackHashSource
                        )
                        switch receipt {
                        case .issued(let header, let ttftMs, let unixTs):
                            writer.writeAPIError(apiError, extraHeaders: [(Self.receiptHeaderName, header)]) { delivered in
                                if delivered {
                                    ReceiptAudit.emitIssued(providerID: providerID, requestID: auditRequestID, modelID: request.model, tokensOut: 0, ttftMs: ttftMs, unixTs: unixTs)
                                } else {
                                    ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .writeFailed)
                                }
                            }
                        case .omitted(let reason):
                            ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: reason)
                            writer.writeAPIError(apiError)
                        case .notReceiptEligible:
                            writer.writeAPIError(apiError)
                        }
                    } catch {
                        ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .constructionFailed)
                        writer.writeAPIError(apiError)
                    }
                }
            }
        } catch let parseError as APIError {
            Task { [providerStatus] in
                await providerStatus.recordError()
            }
            if let request = parsedRequest, !request.stream {
                let writer = ResponseWriter(context: context)
                do {
                    // Parse-error path: the request failed to validate
                    // before any runtime snapshot was taken, so no
                    // request-start container was selected.
                    // §M.2.2 construction proof: every receipt commits
                    // to the hash that started generation — no
                    // generation started here, so emit JSON null
                    // (§M.2.3 semantics) for the receipt's
                    // `model_hash` field.
                    // Parse-error path: the request failed validation
                    // before any model selection. The receipt commits
                    // to `model_hash: null` semantically — no
                    // generation ran, no container served. §M.2.3
                    // null encoding is the right wire shape (NOT
                    // .ambiguous, which is reserved for SPEC-011
                    // R-3.4.1 regressions on requests that DID reach
                    // inference).
                    let receipt = try Self.errorReceiptHeaderResult(
                        providerID: providerID,
                        receiptBuilder: receiptBuilder,
                        request: request,
                        error: parseError,
                        startedAt: requestAcceptedAt,
                        modelHashSource: .warmSwapDisabled
                    )
                    switch receipt {
                    case .issued(let header, let ttftMs, let unixTs):
                        writer.writeAPIError(parseError, extraHeaders: [(Self.receiptHeaderName, header)]) { delivered in
                            if delivered {
                                ReceiptAudit.emitIssued(providerID: providerID, requestID: auditRequestID, modelID: request.model, tokensOut: 0, ttftMs: ttftMs, unixTs: unixTs)
                            } else {
                                ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .writeFailed)
                            }
                        }
                    case .omitted(let reason):
                        ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: reason)
                        writer.writeAPIError(parseError)
                    case .notReceiptEligible:
                        writer.writeAPIError(parseError)
                    }
                } catch {
                    ReceiptAudit.emitOmitted(providerID: providerID, requestID: auditRequestID, reason: .constructionFailed)
                    writer.writeAPIError(parseError)
                }
            } else {
                writeAPIError(context: context, parseError)
            }
        } catch {
            Task { [providerStatus] in
                await providerStatus.recordError()
            }
            writeAPIError(
                context: context,
                APIError(status: 400, message: "Invalid request", code: "invalid_request")
            )
        }
    }

    static func validateContentEncoding(_ values: [String]) throws {
        guard !values.isEmpty else { return }
        let normalized = values.joined(separator: ",")
            .filter { !Self.isASCIIContentEncodingWhitespace($0) }
            .lowercased()
        guard normalized == "identity" else {
            throw APIError(
                status: 415,
                message: "v0.1.0 accepts `Content-Encoding: identity` or no `Content-Encoding` header; compressed request bodies are deferred to v0.2 per §10.",
                code: "request_content_encoding_unsupported",
                param: "Content-Encoding"
            )
        }
    }

    static func validateJSONContentType(_ value: String?) throws {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError(
                status: 415,
                message: "v0.1.0 accepts only `Content-Type: application/json` request bodies.",
                code: "request_content_type_unsupported",
                param: "Content-Type"
            )
        }
        let mediaType = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "application/json" else {
            throw APIError(
                status: 415,
                message: "v0.1.0 accepts only `Content-Type: application/json` request bodies.",
                code: "request_content_type_unsupported",
                param: "Content-Type"
            )
        }
    }

    static func validateBrowserRequestHeaders(_ headers: HTTPHeaders) throws {
        let fetchSite = headers.first(name: "Sec-Fetch-Site")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if fetchSite == "cross-site" {
            throw APIError(
                status: 403,
                message: "Browser-originated cross-site requests are not accepted by the local inference endpoint.",
                code: "browser_request_forbidden",
                param: "Sec-Fetch-Site"
            )
        }
        guard let origin = headers.first(name: "Origin")?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty else {
            return
        }
        guard let url = URL(string: origin), let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw APIError(
                status: 403,
                message: "Browser-originated requests must use a trusted local origin.",
                code: "browser_request_forbidden",
                param: "Origin"
            )
        }
        guard host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            throw APIError(
                status: 403,
                message: "Browser-originated requests must use a trusted local origin.",
                code: "browser_request_forbidden",
                param: "Origin"
            )
        }
    }

    private static func isASCIIContentEncodingWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
    }

    private func handleStreamingChatCompletions(
        request: ChatCompletionRequest,
        writer: ResponseWriter,
        modelRuntime: ModelRuntime,
        warmSwapEnabled: Bool,
        receiptBuilder: ReceiptBuilder?,
        providerID: String?,
        requestID: String,
        settlementMetadata: SettlementReceiptMetadata?,
        idlePrewarmer: IdlePrewarmer?
    ) {
        let created = Int(Date().timeIntervalSince1970)
        let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"

        let providerStatus = providerStatus
        Task.detached { @Sendable [modelRuntime, providerStatus, request, writer, warmSwapEnabled, receiptBuilder, providerID, requestID, settlementMetadata, idlePrewarmer] in
            var startedAt = Date()
            var providerRequestStarted = false
            var sseStarted = false
            do {
                let handle = try await modelRuntime.acquireRequestHandle(request)
                defer {
                    Task { await modelRuntime.unregisterInFlight(handle.registrationID) }
                }
                startedAt = await providerStatus.beginRequest()
                providerRequestStarted = true
                await idlePrewarmer?.cancelInflightPrewarm()
                try await modelRuntime.preflight(request, with: handle)

                writer.startSSE(extraHeaders: Self.streamingSettlementHeadHeaders(settlementMetadata: settlementMetadata) + [
                    ("X-MacProvider-Provider-Unix-Ms", "\(Int64(Date().timeIntervalSince1970 * 1000))"),
                ])
                sseStarted = true
                writer.writeSSEJSON(
                    Self.chatCompletionChunk(
                        id: id,
                        created: created,
                        model: request.model,
                        delta: ["role": "assistant", "content": ""],
                        finishReason: NSNull()
                    )
                )

                let toolCallOpenEmitted = StreamedFlag()
                let streamedAnyToolCallDelta = StreamedFlag()
                let completion = try await modelRuntime.stream(request, with: handle) { chunk in
                    switch chunk {
                    case .content(let text):
                        writer.writeSSEJSON(
                            Self.chatCompletionChunk(
                                id: id,
                                created: created,
                                model: request.model,
                                delta: ["content": text],
                                finishReason: NSNull()
                            )
                        )
                    case .toolCallDelta(let toolDelta):
                        if toolCallOpenEmitted.setIfUnset() {
                            let unixMs = Int64(Date().timeIntervalSince1970 * 1000)
                            writer.writeRawSSE(": macprovider_tool_call_open unix_ms=\(unixMs)\n\n")
                        }
                        streamedAnyToolCallDelta.set()
                        writer.writeSSEJSON(
                            Self.chatCompletionChunk(
                                id: id,
                                created: created,
                                model: request.model,
                                delta: ["tool_calls": [toolDelta.openAIDeltaDict()]],
                                finishReason: NSNull()
                            )
                        )
                    }
                }
                await providerStatus.finishRequest(startedAt: startedAt, completion: completion, failed: false)
                KVCacheTelemetry.emitRequestCompleted(
                    providerID: providerID,
                    requestID: requestID,
                    modelID: request.model,
                    stream: true,
                    completion: completion
                )

                // Fallback for non-streaming-incremental path: if tool calls landed only
                // in the final CompletionResult (e.g. buffered/downgrade/test paths) and
                // were never streamed via .toolCallDelta chunks, emit them now.
                if !streamedAnyToolCallDelta.get(), let toolCalls = completion.toolCalls, !toolCalls.isEmpty {
                    for delta in Self.toolCallDeltaChunks(toolCalls) {
                        writer.writeSSEJSON(
                            Self.chatCompletionChunk(
                                id: id,
                                created: created,
                                model: request.model,
                                delta: ["tool_calls": delta],
                                finishReason: NSNull()
                            )
                        )
                    }
                }

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
                        "usage": Self.usage(completion),
                    ]
                )
                let terminalStateTSUnixMS = Int64(Date().timeIntervalSince1970 * 1000)
                let unixTsSeconds = Int64(Date().timeIntervalSince1970)
                var trailers: [(String, String)] = []
                if settlementMetadata != nil {
                    let modelHashSource = Self.resolveModelHashSource(
                        warmSwapEnabled: warmSwapEnabled,
                        snapshot: handle.snapshot
                    )
                    let ttftMs = completion.ttftMilliseconds ?? Self.elapsedMilliseconds(since: startedAt)
                    let receipt = try Self.receiptHeaderResult(
                        providerID: providerID,
                        receiptBuilder: receiptBuilder,
                        request: request,
                        outputContent: completion.content,
                        outputToolCalls: completion.toolCalls,
                        finishReason: completion.finishReason,
                        promptTokens: Int64(completion.promptTokens),
                        ttftMs: ttftMs,
                        tokensOut: Int64(completion.completionTokens),
                        unixTsSeconds: unixTsSeconds,
                        modelHashSource: modelHashSource,
                        requestID: requestID,
                        settlementMetadata: settlementMetadata,
                        terminalStateTSUnixMS: terminalStateTSUnixMS
                    )
                    switch receipt {
                    case .issued(let header):
                        trailers = Self.receiptExtraHeaders(header: header, settlementMetadata: settlementMetadata, terminalStateTSUnixMS: terminalStateTSUnixMS)
                        ReceiptAudit.emitIssued(providerID: providerID, requestID: requestID, modelID: request.model, tokensOut: Int64(completion.completionTokens), ttftMs: ttftMs, unixTs: unixTsSeconds)
                    case .omitted(let reason):
                        ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: reason)
                    }
                }
                writer.writeSSEDone(trailers: trailers)
            } catch let error as APIError {
                if providerRequestStarted {
                    await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                }
                if sseStarted {
                    writer.writeSSEJSON(error.envelope)
                    writer.writeSSEDone()
                } else {
                    writer.writeAPIError(error)
                }
            } catch is DrainCancelledError {
                if providerRequestStarted {
                    await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                }
                if sseStarted {
                    writer.writeSSEJSON(Self.swapDrainTimeoutEnvelope())
                    writer.writeSSEDone()
                } else {
                    writer.writeJSON(status: .serviceUnavailable, body: Self.swapDrainTimeoutEnvelope())
                }
            } catch {
                if providerRequestStarted {
                    await providerStatus.finishRequest(startedAt: startedAt, completion: nil, failed: true)
                }
                if sseStarted {
                    writer.writeSSEJSON(
                        APIError(
                            status: 500,
                            message: "Inference engine error",
                            type: "server_error",
                            code: "internal_error"
                        ).envelope
                    )
                    writer.writeSSEDone()
                } else {
                    writer.writeAPIError(
                        APIError(status: 503, message: "Model inference failed", type: "server_error", code: "model_not_loaded")
                    )
                }
            }
        }
    }

    static func modelIDForValidation(warmSwapEnabled: Bool, bootModelID: String?, runtimeSnapshot: RuntimeSnapshot) -> String? {
        warmSwapEnabled ? runtimeSnapshot.modelID : bootModelID
    }

    static func swapDrainTimeoutEnvelope() -> [String: Any] {
        [
            "error": [
                "type": "service_unavailable",
                "code": "swap_drain_timeout",
            ]
        ]
    }

    static let receiptHeaderName = "X-MacProvider-Receipt"
    static let settlementMetadataHeaderName = "X-MacProvider-Settlement-Metadata"
    static let receiptTerminalStateTSHeaderName = "X-MacProvider-Receipt-Terminal-State-TS-Unix-MS"
    static let receiptPendingDeadlineHeaderName = "X-MacProvider-Receipt-Pending-Deadline-Seconds"
    static let lateReceiptSettlementHeaderName = "X-MacProvider-Late-Receipt-Settlement"
    static let maxReceiptHeaderBytes = 4096

    private static func settlementMetadata(from encoded: String?) -> SettlementReceiptMetadata? {
        guard let encoded, !encoded.isEmpty,
              let data = try? Data(base64URLUnpadded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return SettlementReceiptMetadata(wire: object)
    }

    private static func receiptExtraHeaders(
        header: String,
        settlementMetadata: SettlementReceiptMetadata?,
        terminalStateTSUnixMS: Int64
    ) -> [(String, String)] {
        var headers = [(Self.receiptHeaderName, header)]
        if let settlementMetadata {
            headers.append((Self.receiptTerminalStateTSHeaderName, String(terminalStateTSUnixMS)))
            headers.append((Self.receiptPendingDeadlineHeaderName, String(settlementMetadata.pendingDeadlineSeconds)))
            headers.append((Self.lateReceiptSettlementHeaderName, "not_settled"))
        }
        return headers
    }

    private static func streamingSettlementHeadHeaders(settlementMetadata: SettlementReceiptMetadata?) -> [(String, String)] {
        guard settlementMetadata != nil else {
            return []
        }
        return [(
            "Trailer",
            [
                Self.receiptHeaderName,
                Self.receiptTerminalStateTSHeaderName,
                Self.receiptPendingDeadlineHeaderName,
                Self.lateReceiptSettlementHeaderName,
            ].joined(separator: ", ")
        )]
    }

    enum ReceiptHeaderResult: Equatable {
        case issued(String)
        case omitted(ReceiptOmissionReason)
    }

    enum ErrorReceiptHeaderResult: Equatable {
        case issued(String, ttftMs: Int64, unixTs: Int64)
        case omitted(ReceiptOmissionReason)
        case notReceiptEligible
    }

    static func receiptHeader(
        providerID: String?,
        receiptBuilder: ReceiptBuilder?,
        request: ChatCompletionRequest,
        outputContent: String,
        outputToolCalls: [ToolCall]?,
        finishReason: String,
        promptTokens: Int64? = nil,
        ttftMs: Int64,
        tokensOut: Int64,
        unixTsSeconds: Int64,
        modelHashSource: ReceiptModelHashSource
    ) throws -> String? {
        switch try receiptHeaderResult(
            providerID: providerID,
            receiptBuilder: receiptBuilder,
            request: request,
            outputContent: outputContent,
            outputToolCalls: outputToolCalls,
            finishReason: finishReason,
            promptTokens: promptTokens,
            ttftMs: ttftMs,
            tokensOut: tokensOut,
            unixTsSeconds: unixTsSeconds,
            modelHashSource: modelHashSource,
            requestID: nil,
            settlementMetadata: nil,
            terminalStateTSUnixMS: nil
        ) {
        case .issued(let header):
            return header
        case .omitted:
            return nil
        }
    }

    /// SPEC-015 §M.2 — map (warmSwapEnabled, request-start snapshot)
    /// to the receipt's `model_hash` provenance. §M.2.2 defence-in-
    /// depth: if warm-swap is ON but the snapshot didn't carry a
    /// hash (SPEC-011 R-3.4.1 in-flight tracking regression), the
    /// runtime cannot disambiguate which container served and the
    /// receipt-emission MUST refuse.
    static func resolveModelHashSource(
        warmSwapEnabled: Bool,
        snapshot: RuntimeSnapshot
    ) -> ReceiptModelHashSource {
        if warmSwapEnabled {
            if let hash = snapshot.modelHash {
                return .captured(hash)
            }
            // Warm-swap is on; SPEC-011 R-3.4.1 should have produced
            // a hash at request-start capture time. Absence is a
            // regression — §M.2.2 defence-in-depth refusal.
            return .ambiguous
        }
        // Warm-swap is off; SPEC-011 R-3.3.0 suppresses hash
        // reporting. §M.2.3 null-hash semantics apply.
        return .warmSwapDisabled
    }

    static func receiptHeaderResult(
        providerID: String?,
        receiptBuilder: ReceiptBuilder?,
        request: ChatCompletionRequest,
        outputContent: String,
        outputToolCalls: [ToolCall]?,
        finishReason: String,
        promptTokens: Int64? = nil,
        ttftMs: Int64,
        tokensOut: Int64,
        unixTsSeconds: Int64,
        modelHashSource: ReceiptModelHashSource,
        requestID: String? = nil,
        settlementMetadata: SettlementReceiptMetadata? = nil,
        terminalState: String = "normal_done",
        terminalStateTSUnixMS: Int64? = nil
    ) throws -> ReceiptHeaderResult {
        guard let providerID, !providerID.isEmpty else {
            return .omitted(.noKeypair)
        }
        guard let receiptBuilder else {
            return .omitted(.preV16Binary)
        }
        // SPEC-015 §M.2.2 — fail-closed refusal BEFORE construction.
        // The .ambiguous provenance can only arise from a SPEC-011
        // R-3.4.1 in-flight-tracking regression; v0.3 normatively
        // refuses to sign a receipt that cannot identify which
        // container served. Audit row + no header. The HTTP 200
        // response itself still goes out (the buyer got their
        // tokens; the §M.2.2 normal construction proof allows the
        // un-receipted 200 case).
        let resolvedModelHash: String?
        switch modelHashSource {
        case .captured(let hash):
            resolvedModelHash = hash
        case .warmSwapDisabled:
            resolvedModelHash = nil
        case .ambiguous:
            return .omitted(.modelSwapViolation)
        }
        do {
            if let settlementMetadata {
                guard let requestID, settlementMetadata.requestID == requestID,
                      settlementMetadata.providerID == providerID,
                      settlementMetadata.modelID == request.model,
                      case .captured(let modelHash) = modelHashSource else {
                    return .omitted(.constructionFailed)
                }
                let issuedAt = Int64(Date().timeIntervalSince1970 * 1000)
                let header = try receiptBuilder.buildSettlement(
                    providerId: providerID,
                    input: SettlementReceiptInput(
                        metadata: settlementMetadata,
                        modelHash: modelHash,
                        content: outputContent,
                        toolCalls: outputToolCalls,
                        finishReason: finishReason,
                        promptTokens: promptTokens ?? 0,
                        completionTokens: tokensOut,
                        terminalState: terminalState,
                        terminalStateUnixMS: terminalStateTSUnixMS ?? issuedAt,
                        issuedAtUnixMS: issuedAt
                    )
                )
                guard header.utf8.count <= maxReceiptHeaderBytes else {
                    throw ReceiptEmissionError.headerTooLarge(byteCount: header.utf8.count)
                }
                return .issued(header)
            }
            let header = try receiptBuilder.build(
                providerId: providerID,
                input: ReceiptInput(
                    modelId: request.model,
                    request: request,
                    outputContent: outputContent,
                    outputToolCalls: outputToolCalls,
                    finishReason: finishReason,
                    ttftMs: ttftMs,
                    tokensOut: tokensOut,
                    unixTsSeconds: unixTsSeconds,
                    modelHash: resolvedModelHash
                )
            )
            guard header.utf8.count <= maxReceiptHeaderBytes else {
                throw ReceiptEmissionError.headerTooLarge(byteCount: header.utf8.count)
            }
            return .issued(header)
        } catch ReceiptBuilder.Error.missingCurrentReceiptKey {
            return .omitted(.noKeypair)
        }
    }

    static func errorReceiptHeader(
        providerID: String?,
        receiptBuilder: ReceiptBuilder?,
        request: ChatCompletionRequest,
        error: APIError,
        startedAt: Date,
        modelHashSource: ReceiptModelHashSource
    ) throws -> String? {
        switch try errorReceiptHeaderResult(providerID: providerID, receiptBuilder: receiptBuilder, request: request, error: error, startedAt: startedAt, modelHashSource: modelHashSource) {
        case .issued(let header, _, _):
            return header
        case .omitted, .notReceiptEligible:
            return nil
        }
    }

    static func errorReceiptHeaderResult(
        providerID: String?,
        receiptBuilder: ReceiptBuilder?,
        request: ChatCompletionRequest,
        error: APIError,
        startedAt: Date,
        modelHashSource: ReceiptModelHashSource
    ) throws -> ErrorReceiptHeaderResult {
        guard error.code == "model_not_loaded" else {
            if error.code == "swap_drain_timeout" {
                return .omitted(.modelSwapViolation)
            }
            if error.code == "buyer_cancelled" {
                return .omitted(.preTokenCancel)
            }
            return .notReceiptEligible
        }
        let ttftMs = elapsedMilliseconds(since: startedAt)
        let unixTs = Int64(Date().timeIntervalSince1970)
        // SPEC-015 §M.2 / §7.6 — error receipts inherit the same
        // request-start `modelHashSource` a successful receipt would
        // carry. The error did not change the loaded weights; the
        // buyer is still entitled to know which weights the provider
        // had warm at the moment the error fired. An `.ambiguous`
        // source still refuses here (§M.2.2 defence-in-depth).
        switch try receiptHeaderResult(
            providerID: providerID,
            receiptBuilder: receiptBuilder,
            request: request,
            outputContent: "",
            outputToolCalls: nil,
            finishReason: "error",
            ttftMs: ttftMs,
            tokensOut: 0,
            unixTsSeconds: unixTs,
            modelHashSource: modelHashSource
        ) {
        case .issued(let header):
            return .issued(header, ttftMs: ttftMs, unixTs: unixTs)
        case .omitted(let reason):
            return .omitted(reason)
        }
    }

    static func elapsedMilliseconds(since start: Date, now: Date = Date()) -> Int64 {
        max(0, Int64(now.timeIntervalSince(start) * 1000))
    }

    static func receiptConstructionError() -> APIError {
        APIError(
            status: 500,
            message: "Receipt construction failed",
            type: "server_error",
            code: "internal_error"
        )
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
                    "message": Self.chatCompletionMessage(completion),
                    "finish_reason": completion.finishReason,
                ]
            ],
            "usage": Self.usage(completion),
        ]
    }

    private static func healthResponse(_ snapshot: ProviderSnapshot) -> [String: Any] {
        [
            "status": snapshot.status.rawValue,
            "model": snapshot.modelID ?? NSNull(),
            "model_loaded": snapshot.modelLoaded,
            "uptime_s": snapshot.uptimeSeconds,
            "requests_total": snapshot.requestsTotal,
            "requests_today": snapshot.requestsToday,
            "input_tokens_today": snapshot.inputTokensToday,
            "output_tokens_today": snapshot.outputTokensToday,
            "input_tokens_all_time": snapshot.inputTokensAllTime,
            "output_tokens_all_time": snapshot.outputTokensAllTime,
            "requests_in_flight": snapshot.requestsInFlight,
            "requests_queued": snapshot.requestsQueued,
            "errors_total": snapshot.errorsTotal,
            "restart_count": snapshot.restartCount,
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

    private static func chatCompletionMessage(_ completion: CompletionResult) -> [String: Any] {
        let toolCalls = completion.toolCalls?.isEmpty == false ? completion.toolCalls : nil
        var message: [String: Any] = [
            "role": "assistant",
            "content": toolCalls == nil ? completion.content : NSNull(),
        ]
        if let toolCalls {
            message["tool_calls"] = toolCalls.map(\.openAIObject)
        }
        return message
    }

    private static func toolCallDeltaChunks(_ toolCalls: [ToolCall]) -> [[[String: Any]]] {
        var chunks: [[[String: Any]]] = []
        for (index, call) in toolCalls.enumerated() {
            chunks.append([call.openAIInitialDelta(index: index)])
            for fragment in splitArguments(call.arguments) {
                chunks.append([call.openAIArgumentsDelta(index: index, fragment: fragment)])
            }
        }
        return chunks
    }

    private static func splitArguments(_ arguments: String, chunkBytes: Int = 2048) -> [String] {
        guard !arguments.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var currentBytes = 0
        for scalar in arguments.unicodeScalars {
            let scalarString = String(scalar)
            let scalarBytes = scalarString.utf8.count
            if currentBytes > 0, currentBytes + scalarBytes > chunkBytes {
                result.append(current)
                current = ""
                currentBytes = 0
            }
            current += scalarString
            currentBytes += scalarBytes
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func usage(_ completion: CompletionResult) -> [String: Any] {
        [
            "prompt_tokens": completion.promptTokens,
            "cached_prompt_tokens": completion.cachedPromptTokens,
            "completion_tokens": completion.completionTokens,
            "total_tokens": completion.promptTokens + completion.completionTokens,
            "macprovider_model_hash_observed": completion.modelHashObserved ?? NSNull(),
        ]
    }

    static func statusResponse(
        _ snapshot: ProviderSnapshot,
        providerID: String?,
        coordinatorURL: String?,
        runtimeSnapshot: RuntimeSnapshot? = nil,
        specDecodeTelemetryMatchesRuntime: Bool = true,
        specDecodeTelemetryRuntimeEligible: Bool = true
    ) -> [String: Any] {
        let effectiveModelID = runtimeSnapshot?.modelID ?? snapshot.modelID
        let effectiveModelLoaded = runtimeSnapshot.map { $0.container != nil || $0.modelID != nil } ?? snapshot.modelLoaded
        var body: [String: Any] = [
            "binary_version": CoordinatorClient.binaryVersion,
            "provider_id": jsonNullable(providerID),
            "status": snapshot.status.rawValue,
            "model": effectiveModelID ?? NSNull(),
            "model_loaded": effectiveModelLoaded,
            "uptime_s": snapshot.uptimeSeconds,
            "requests_total": snapshot.requestsTotal,
            "requests_today": snapshot.requestsToday,
            "input_tokens_today": snapshot.inputTokensToday,
            "output_tokens_today": snapshot.outputTokensToday,
            "input_tokens_all_time": snapshot.inputTokensAllTime,
            "output_tokens_all_time": snapshot.outputTokensAllTime,
            "requests_in_flight": snapshot.requestsInFlight,
            "active_request_id_count": snapshot.activeRequestIDCount,
            "errors_total": snapshot.errorsTotal,
            "restart_count": snapshot.restartCount,
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
        body.merge(specDecodeTelemetryFields(
            snapshot,
            matchesRuntime: specDecodeTelemetryMatchesRuntime,
            runtimeEligible: specDecodeTelemetryRuntimeEligible
        )) { _, new in new }
        return body
    }

    static func specDecodeTelemetryFields(
        _ snapshot: ProviderSnapshot,
        matchesRuntime: Bool = true,
        runtimeEligible: Bool = true
    ) -> [String: Any] {
        guard matchesRuntime, runtimeEligible else {
            return [
                "spec_decode_enabled": false,
                "spec_decode_draft_model_id": NSNull(),
                "spec_decode_num_draft_tokens": NSNull(),
                "spec_decode_drafted_tokens_since_last": 0,
                "spec_decode_accepted_tokens_since_last": 0,
                "spec_decode_acceptance_rate": NSNull(),
            ]
        }
        return [
            "spec_decode_enabled": snapshot.specDecodeEnabled,
            "spec_decode_draft_model_id": snapshot.specDecodeDraftModelID ?? NSNull(),
            "spec_decode_num_draft_tokens": snapshot.specDecodeNumDraftTokens ?? NSNull(),
            "spec_decode_drafted_tokens_since_last": snapshot.specDecodeDraftedTokensSinceLast,
            "spec_decode_accepted_tokens_since_last": snapshot.specDecodeAcceptedTokensSinceLast,
            "spec_decode_acceptance_rate": nullableNumber(snapshot.specDecodeAcceptanceRate),
        ]
    }

    private static func jsonNullable(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func nullableNumber(_ value: Double?) -> Any {
        guard let value, value.isFinite else {
            return NSNull()
        }
        return value
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

    func writeJSON(
        status: HTTPResponseStatus,
        body: Any,
        extraHeaders: [(String, String)] = [],
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        do {
            let data = try encodeJSONObject(body)
            context.eventLoop.execute {
                writeRawJSON(context: context, status: status, data: data, extraHeaders: extraHeaders, completion: completion)
            }
        } catch {
            context.eventLoop.execute {
                context.close(promise: nil)
            }
            completion?(false)
        }
    }

    func writeAPIError(
        _ error: APIError,
        extraHeaders: [(String, String)] = [],
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        writeJSON(
            status: HTTPResponseStatus(statusCode: error.status),
            body: error.envelope,
            extraHeaders: extraHeaders,
            completion: completion
        )
    }

    func startSSE(extraHeaders: [(String, String)] = []) {
        context.eventLoop.execute {
            writeRawSSEHead(context: context, extraHeaders: extraHeaders)
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

    func writeSSEDone(trailers: [(String, String)] = []) {
        writeSSEData("[DONE]")
        context.eventLoop.execute {
            var headers: HTTPHeaders?
            if !trailers.isEmpty {
                var trailerHeaders = HTTPHeaders()
                for (name, value) in trailers {
                    trailerHeaders.add(name: name, value: value)
                }
                headers = trailerHeaders
            }
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(headers))).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }

    private func writeSSEData(_ payload: String) {
        context.eventLoop.execute {
            writeRawSSEData(context: context, payload: payload)
        }
    }

    func writeRawSSE(_ payload: String) {
        context.eventLoop.execute {
            writeRawSSEPayload(context: context, payload: payload)
        }
    }
}

private func writeRawJSON(
    context: ChannelHandlerContext,
    status: HTTPResponseStatus,
    data: Data,
    extraHeaders: [(String, String)] = [],
    completion: (@Sendable (Bool) -> Void)? = nil
) {
    let headers = makeJSONResponseHeaders(dataLength: data.count, extraHeaders: extraHeaders)
    let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
    context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)

    var buffer = context.channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
    let endPromise = context.eventLoop.makePromise(of: Void.self)
    context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: endPromise)
    endPromise.futureResult.whenComplete { result in
        switch result {
        case .success:
            completion?(true)
        case .failure:
            completion?(false)
        }
        context.close(promise: nil)
    }
}

private func writeRawSSEHead(context: ChannelHandlerContext, extraHeaders: [(String, String)] = []) {
    let headers = makeSSEResponseHeaders(extraHeaders: extraHeaders)
    let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
    context.writeAndFlush(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
}

private func writeRawSSEData(context: ChannelHandlerContext, payload: String) {
    let line = "data: \(payload)\n\n"
    writeRawSSEPayload(context: context, payload: line)
}

private func writeRawSSEPayload(context: ChannelHandlerContext, payload: String) {
    let line = payload
    var buffer = context.channel.allocator.buffer(capacity: line.utf8.count)
    buffer.writeString(line)
    context.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
}

private func encodeJSONObject(_ body: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
}

func makeJSONResponseHeaders(
    dataLength: Int,
    extraHeaders: [(String, String)] = []
) -> HTTPHeaders {
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "application/json")
    headers.add(name: "content-length", value: "\(dataLength)")
    headers.add(name: "connection", value: "close")
    for (name, value) in extraHeaders {
        headers.add(name: name, value: value)
    }
    return headers
}

func makeSSEResponseHeaders(extraHeaders: [(String, String)] = []) -> HTTPHeaders {
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "text/event-stream; charset=utf-8")
    headers.add(name: "cache-control", value: "no-cache")
    headers.add(name: "connection", value: "close")
    headers.add(name: "transfer-encoding", value: "chunked")
    for (name, value) in extraHeaders {
        headers.add(name: name, value: value)
    }
    return headers
}

private extension Optional where Wrapped == String {
    var httpHeaders: [(String, String)] {
        guard let self else { return [] }
        return [(RouterHandler.receiptHeaderName, self)]
    }
}

enum ReceiptEmissionError: Error, Equatable {
    case headerTooLarge(byteCount: Int)
}
