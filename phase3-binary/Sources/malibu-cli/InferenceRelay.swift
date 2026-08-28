import Foundation
import MacProviderCore

/// Normalizes an optional catalog-alias string into the `aliases:` array shape
/// expected by `ChatCompletionRequest.validateModelMatches`. Trims whitespace
/// and newlines to match the normalization applied to
/// `catalogModelIDForCoordinator` in CoordinatorClient (see lines 324-327);
/// returns `[]` for nil/empty so the default no-alias behavior is preserved.
func modelIDAliasList(_ value: String?) -> [String] {
    guard let value else { return [] }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? [] : [trimmed]
}

actor InferenceRelay {
    typealias SendFrame = @Sendable (sending [String: Any]) async throws -> Void
    typealias TrustDemotion = @Sendable (_ reason: String) async -> Void

    private struct ActiveRequest {
        let task: Task<Void, Never>
        let state: RelayRequestState
    }

    private let modelRuntime: any ModelRuntimeServing
    private let providerStatus: ProviderStatus
    private let loadedModelID: String?
    private let catalogModelIDAlias: String?
    private let warmSwapEnabled: Bool
    private let maxActiveRequests: Int
    private let maxBodyBytes: Int
    private let sendFrame: SendFrame
    private let tier2Session: Tier2ProviderSession?
    private let receiptBuilder: ReceiptBuilder?
    private let receiptProviderID: String?
    private let demoteAutoupdateTrust: TrustDemotion?
    // T3-01: number of content-token deltas to accumulate per WS frame.
    // 1 = one frame per token (default, current behaviour).
    nonisolated let streamInterval: Int
    private var active: [String: ActiveRequest] = [:]

    init(
        modelRuntime: any ModelRuntimeServing,
        providerStatus: ProviderStatus,
        loadedModelID: String?,
        catalogModelIDAlias: String? = nil,
        warmSwapEnabled: Bool = false,
        maxActiveRequests: Int,
        maxBodyBytes: Int,
        tier2Session: Tier2ProviderSession? = nil,
        receiptBuilder: ReceiptBuilder? = nil,
        receiptProviderID: String? = nil,
        streamInterval: Int = 1,
        demoteAutoupdateTrust: TrustDemotion? = nil,
        sendFrame: @escaping SendFrame
    ) {
        self.modelRuntime = modelRuntime
        self.providerStatus = providerStatus
        self.loadedModelID = loadedModelID
        self.catalogModelIDAlias = catalogModelIDAlias
        self.warmSwapEnabled = warmSwapEnabled
        self.maxActiveRequests = max(1, maxActiveRequests)
        self.maxBodyBytes = max(1, maxBodyBytes)
        self.tier2Session = tier2Session
        self.receiptBuilder = receiptBuilder
        self.receiptProviderID = receiptProviderID
        self.streamInterval = max(1, streamInterval)
        self.demoteAutoupdateTrust = demoteAutoupdateTrust
        self.sendFrame = sendFrame
    }

    func handleInferenceRequest(_ message: [String: Any]) async throws {
        guard let requestID = message["request_id"] as? String, !requestID.isEmpty,
              let stream = message["stream"] as? Bool
        else {
            try await sendNAK(inReplyTo: "inference_request", code: "invalid_message", message: "inference_request requires request_id, stream, and body")
            return
        }
        let body: String
        let decryptedConversationKey: String?
        if let tier2Session {
            guard message["encrypted"] as? Bool == true else {
                try await sendNAK(inReplyTo: requestID, code: "tier2_encrypted_frame_required", message: "Tier-2 session requires encrypted inference_request frames")
                return
            }
            do {
                let payload = try tier2Session.openRequestPayload(message: message, requestID: requestID, stream: stream)
                body = payload.body
                decryptedConversationKey = payload.conversationKey
            } catch {
                await demoteAutoupdateTrust?("encrypted_leg_invalidated")
                try await sendNAK(inReplyTo: requestID, code: "tier2_aead_decrypt_failed", message: "Encrypted inference_request failed authentication")
                return
            }
        } else if let cleartextBody = message["body"] as? String {
            body = cleartextBody
            decryptedConversationKey = nil
        } else {
            try await sendNAK(inReplyTo: "inference_request", code: "invalid_message", message: "inference_request requires request_id, stream, and body")
            return
        }

        guard active[requestID] == nil else {
            try await sendNAK(inReplyTo: "inference_request", code: "duplicate_request_id", message: "Duplicate active request_id: \(requestID)")
            return
        }

        guard active.count < maxActiveRequests else {
            try await Self.sendEndFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "error_queue_full",
                "chunks_sent": 0,
                "error": "Provider request queue is full",
            ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            return
        }

        let settlementMetadata: SettlementReceiptMetadata?
        if let settlementWire = message["settlement"] as? [String: Any] {
            guard let parsed = SettlementReceiptMetadata(wire: settlementWire) else {
                try await sendNAK(inReplyTo: requestID, code: "invalid_settlement_metadata", message: "inference_request settlement metadata is malformed")
                return
            }
            guard parsed.requestID == requestID,
                  receiptProviderID == nil || parsed.providerID == receiptProviderID else {
                try await sendNAK(inReplyTo: requestID, code: "invalid_settlement_metadata", message: "inference_request settlement metadata does not match this request")
                return
            }
            settlementMetadata = parsed
        } else {
            settlementMetadata = nil
        }
        let conversationKey: String?
        if tier2Session != nil {
            conversationKey = decryptedConversationKey
        } else {
            conversationKey = (message["conversation_key"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard body.utf8.count <= maxBodyBytes else {
            try await Self.sendEndFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "error_context_exceeded",
                "chunks_sent": 0,
                "error": "Request body exceeds provider limit",
            ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            return
        }

        guard let startedAt = await providerStatus.beginRequestIfAccepting(requestID: requestID) else {
            try await Self.sendEndFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "error_provider_paused",
                "chunks_sent": 0,
                "error": "Provider is paused or draining",
            ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            return
        }

        let state = RelayRequestState()
        let receiptBuilder = receiptBuilder
        let receiptProviderID = receiptProviderID
        let task = Task { [weak self, modelRuntime, providerStatus, loadedModelID, catalogModelIDAlias, warmSwapEnabled, sendFrame, tier2Session, state, settlementMetadata, streamInterval] in
            await Self.process(
                requestID: requestID,
                body: body,
                stream: stream,
                state: state,
                modelRuntime: modelRuntime,
                providerStatus: providerStatus,
                loadedModelID: loadedModelID,
                catalogModelIDAlias: catalogModelIDAlias,
                warmSwapEnabled: warmSwapEnabled,
                tier2Session: tier2Session,
                receiptBuilder: receiptBuilder,
                receiptProviderID: receiptProviderID,
                settlementMetadata: settlementMetadata,
                conversationKey: conversationKey?.isEmpty == false ? conversationKey : nil,
                startedAt: startedAt,
                streamInterval: streamInterval,
                sendFrame: sendFrame
            )
            await self?.removeActive(requestID)
        }
        active[requestID] = ActiveRequest(task: task, state: state)
    }

    func handleCancelRequest(_ message: [String: Any]) async throws {
        guard let requestID = message["request_id"] as? String, !requestID.isEmpty else {
            try await sendNAK(inReplyTo: "cancel_request", code: "invalid_message", message: "cancel_request requires request_id")
            return
        }

        guard let request = active[requestID] else {
            if tier2Session != nil {
                return
            }
            try await sendFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "cancelled",
                "chunks_sent": 0,
                "usage": Self.zeroUsage(),
            ])
            return
        }

        request.state.cancel()
    }

    func cancelAll() {
        for request in active.values {
            request.state.cancel()
            request.task.cancel()
        }
    }

    func cancelAllAndClear() {
        cancelAll()
        active.removeAll()
    }

    func waitUntilIdle(timeoutSeconds: Int) async -> Bool {
        let seconds = UInt64(max(0, timeoutSeconds))
        let (product, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let timeoutNanoseconds = overflow ? UInt64.max : product
        let start = DispatchTime.now().uptimeNanoseconds
        while !active.isEmpty {
            if Task.isCancelled || DispatchTime.now().uptimeNanoseconds &- start >= timeoutNanoseconds {
                return false
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false
            }
        }
        return true
    }

    private func removeActive(_ requestID: String) {
        active.removeValue(forKey: requestID)
    }

    private func sendNAK(inReplyTo: String, code: String, message: String) async throws {
        try await sendFrame([
            "type": "nak",
            "in_reply_to": inReplyTo,
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    private static func process(
        requestID: String,
        body: String,
        stream: Bool,
        state: RelayRequestState,
        modelRuntime: any ModelRuntimeServing,
        providerStatus: ProviderStatus,
        loadedModelID: String?,
        catalogModelIDAlias: String?,
        warmSwapEnabled: Bool,
        tier2Session: Tier2ProviderSession?,
        receiptBuilder: ReceiptBuilder?,
        receiptProviderID: String?,
        settlementMetadata: SettlementReceiptMetadata?,
        conversationKey: String?,
        startedAt: Date,
        streamInterval: Int = 1,
        sendFrame: @escaping SendFrame
    ) async {
        var completionResult: CompletionResult?
        var failed = false
        var telemetryModelID = loadedModelID ?? ""

        do {
            let requestData = Data(body.utf8)
            // SPEC-037 FR-KVP11: stamp ingest provenance. Neither relay nor
            // Tier-2 traffic is ever persisted by the disk tier (only the
            // direct-HTTP operator path is), independent of key shape.
            let ingestProvenance: KVIngestProvenance = tier2Session != nil ? .tier2 : .relay
            let request = try ChatCompletionRequest.parse(data: requestData)
                .withConversationKey(conversationKey)
                .withIngestProvenance(ingestProvenance)
            telemetryModelID = request.model
            let validationModelID = warmSwapEnabled
                ? await modelRuntime.currentSnapshot().modelID
                : loadedModelID
            // Accept the coordinator-advertised catalog id as an alias only while
            // the configured model is the one currently served — the exact predicate
            // coordinatorWireModelID uses to decide whether to advertise it
            // (servedModelID == loadedModelID). This holds even when warm-swap is
            // enabled but the configured model is still loaded; after a swap to a
            // different model the alias no longer applies.
            let relayAliases = (validationModelID != nil && validationModelID == loadedModelID)
                ? modelIDAliasList(catalogModelIDAlias)
                : []
            try request.validateModelMatches(validationModelID, aliases: relayAliases)
        if stream {
            let trace = EgressPerfTrace()
            completionResult = try await EgressPerfTraceKey.$current.withValue(trace) {
                try await processStreaming(
                    requestID: requestID,
                    request: request,
                    state: state,
                    modelRuntime: modelRuntime,
                    warmSwapEnabled: warmSwapEnabled,
                    tier2Session: tier2Session,
                    receiptBuilder: receiptBuilder,
                    receiptProviderID: receiptProviderID,
                    settlementMetadata: settlementMetadata,
                    streamInterval: streamInterval,
                    sendFrame: sendFrame
                )
            }
            trace.printSummary(requestID: requestID, completionTokens: completionResult?.completionTokens ?? 0)
        } else {
                completionResult = try await processNonStreaming(
                    requestID: requestID,
                    request: request,
                    state: state,
                    modelRuntime: modelRuntime,
                    tier2Session: tier2Session,
                    receiptBuilder: receiptBuilder,
                    receiptProviderID: receiptProviderID,
                    settlementMetadata: settlementMetadata,
                    startedAt: startedAt,
                    warmSwapEnabled: warmSwapEnabled,
                    sendFrame: sendFrame
                )
            }
        } catch is RelayCancellationAcknowledged {
        } catch is CancellationError {
            if state.markTerminalSent() {
                var endFrame: [String: Any] = [
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "cancelled",
                    "chunks_sent": state.chunksSent,
                    "usage": state.usage ?? zeroUsage(),
                ]
                addSettlementTerminalMetadata(&endFrame, settlementMetadata: settlementMetadata)
                try? await sendEndFrame(endFrame, requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            }
        } catch let error as APIError {
            failed = true
            if state.markTerminalSent() {
                var endFrame = errorEndFrame(requestID: requestID, error: error, chunksSent: state.chunksSent)
                addSettlementTerminalMetadata(&endFrame, settlementMetadata: settlementMetadata)
                try? await sendEndFrame(endFrame, requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            }
        } catch {
            failed = true
            if state.markTerminalSent() {
                var endFrame: [String: Any] = [
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "error_internal",
                    "chunks_sent": state.chunksSent,
                    "error": String(describing: error),
                ]
                addSettlementTerminalMetadata(&endFrame, settlementMetadata: settlementMetadata)
                try? await sendEndFrame(endFrame, requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            }
        }
        await providerStatus.finishRequest(
            startedAt: startedAt,
            completion: completionResult,
            failed: failed,
            requestID: requestID
        )
        if !failed, !state.isCancelled, let completionResult {
            KVCacheTelemetry.emitRequestCompleted(
                providerID: receiptProviderID,
                requestID: requestID,
                modelID: telemetryModelID,
                stream: stream,
                completion: completionResult
            )
        }
    }

    private static func processNonStreaming(
        requestID: String,
        request: ChatCompletionRequest,
        state: RelayRequestState,
        modelRuntime: any ModelRuntimeServing,
        tier2Session: Tier2ProviderSession?,
        receiptBuilder: ReceiptBuilder?,
        receiptProviderID: String?,
        settlementMetadata: SettlementReceiptMetadata?,
        startedAt: Date,
        warmSwapEnabled: Bool,
        sendFrame: @escaping SendFrame
    ) async throws -> CompletionResult {
        // SPEC-015 §M.2.2 atomic-read invariant — bind the receipt
        // to the snapshot the runtime ACTUALLY used to drive
        // generation, not to a separately-sampled `currentSnapshot()`
        // which can drift across an actor interleaving / warm-swap.
        let (completion, servedSnapshot) = try await modelRuntime.completeWithServedSnapshot(request, shouldCancel: { state.isCancelled })
        let modelHashSource = RouterHandler.resolveModelHashSource(
            warmSwapEnabled: warmSwapEnabled,
            snapshot: servedSnapshot,
            settlementMetadata: settlementMetadata
        )
        let unixTsSeconds = Int64(Date().timeIntervalSince1970)
        state.setUsage(completion)
        if state.isCancelled {
            if state.markTerminalSent() {
                let terminalStateTSUnixMS = Int64(Date().timeIntervalSince1970 * 1000)
                let receiptHeader = Self.buildReceiptHeader(
                    receiptBuilder: receiptBuilder,
                    providerID: receiptProviderID,
                    request: request,
                    completion: completion,
                    ttftMs: completion.ttftMilliseconds ?? Self.elapsedMilliseconds(since: startedAt),
                    unixTsSeconds: unixTsSeconds,
                    requestID: requestID,
                    modelHashSource: modelHashSource,
                    settlementMetadata: settlementMetadata,
                    terminalState: "buyer_cancel",
                    terminalStateTSUnixMS: terminalStateTSUnixMS
                )
                var endFrame: [String: Any] = [
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "cancelled",
                    "chunks_sent": state.chunksSent,
                    "usage": usage(completion),
                    "terminal_state_ts_unix_ms": terminalStateTSUnixMS,
                ]
                if let receiptHeader {
                    endFrame["receipt"] = receiptHeader
                }
                if let settlementMetadata {
                    endFrame["receipt_pending_deadline_seconds"] = settlementMetadata.pendingDeadlineSeconds
                    endFrame["late_receipt_settlement"] = "not_settled"
                }
                try await sendEndFrame(endFrame, requestID: requestID, stream: false, tier2Session: tier2Session, sendFrame: sendFrame)
            }
            return completion
        }
        guard !state.terminalSent else {
            return completion
        }
        let response = try jsonString(chatCompletionResponse(request: request, completion: completion))
        let seq = state.nextSeq()
        try await sendChunk(requestID: requestID, stream: false, seq: seq, data: response, tier2Session: tier2Session, sendFrame: sendFrame)
        let ttftMs = completion.ttftMilliseconds ?? Self.elapsedMilliseconds(since: startedAt)
        let terminalStateTSUnixMS = Int64(Date().timeIntervalSince1970 * 1000)
        let receiptHeader = Self.buildReceiptHeader(
            receiptBuilder: receiptBuilder,
            providerID: receiptProviderID,
            request: request,
            completion: completion,
            ttftMs: ttftMs,
            unixTsSeconds: unixTsSeconds,
            requestID: requestID,
            modelHashSource: modelHashSource,
            settlementMetadata: settlementMetadata,
            terminalStateTSUnixMS: terminalStateTSUnixMS
        )
        if state.markTerminalSent() {
            var endFrame: [String: Any] = [
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "complete",
                "chunks_sent": state.chunksSent,
                "usage": usage(completion),
                "terminal_state_ts_unix_ms": terminalStateTSUnixMS,
            ]
            if let receiptHeader {
                endFrame["receipt"] = receiptHeader
            }
            if let settlementMetadata {
                endFrame["receipt_pending_deadline_seconds"] = settlementMetadata.pendingDeadlineSeconds
                endFrame["late_receipt_settlement"] = "not_settled"
            }
            try await sendEndFrame(endFrame, requestID: requestID, stream: false, tier2Session: tier2Session, sendFrame: sendFrame)
        }
        return completion
    }

    private static func buildReceiptHeader(
        receiptBuilder: ReceiptBuilder?,
        providerID: String?,
        request: ChatCompletionRequest,
        completion: CompletionResult,
        ttftMs: Int64,
        unixTsSeconds: Int64,
        requestID: String,
        modelHashSource: ReceiptModelHashSource,
        settlementMetadata: SettlementReceiptMetadata? = nil,
        terminalState: String = "normal_done",
        terminalStateTSUnixMS: Int64? = nil
    ) -> String? {
        guard let receiptBuilder, let providerID, !providerID.isEmpty else {
            return nil
        }
        // SPEC-015 §M.2.2 — refuse receipt construction when the
        // request-start container cannot be identified.
        let resolvedModelHash: String?
        switch modelHashSource {
        case .captured(let hash):
            resolvedModelHash = hash
        case .warmSwapDisabled:
            resolvedModelHash = nil
        case .ambiguous:
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .modelSwapViolation)
            return nil
        }
        do {
            if let settlementMetadata {
                guard settlementMetadata.providerID == providerID,
                      settlementMetadata.modelID == request.model else {
                    ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .constructionFailed)
                    return nil
                }
                guard let modelHash = resolvedModelHash else {
                    ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .constructionFailed)
                    return nil
                }
                let issuedAt = Int64(Date().timeIntervalSince1970 * 1000)
                return try receiptBuilder.buildSettlement(
                    providerId: providerID,
                    input: SettlementReceiptInput(
                        metadata: settlementMetadata,
                        modelHash: modelHash,
                        content: completion.content,
                        toolCalls: completion.toolCalls,
                        finishReason: completion.finishReason,
                        promptTokens: Int64(completion.promptTokens),
                        completionTokens: Int64(completion.generatedCompletionTokens),
                        terminalState: terminalState,
                        terminalStateUnixMS: terminalStateTSUnixMS ?? issuedAt,
                        issuedAtUnixMS: issuedAt
                    )
                )
            }
            return try receiptBuilder.build(
                providerId: providerID,
                input: ReceiptInput(
                    modelId: request.model,
                    request: request,
                    outputContent: completion.content,
                    outputToolCalls: completion.toolCalls,
                    finishReason: completion.finishReason,
                    ttftMs: ttftMs,
                    tokensOut: Int64(completion.generatedCompletionTokens),
                    unixTsSeconds: unixTsSeconds,
                    modelHash: resolvedModelHash
                )
            )
        } catch {
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .constructionFailed)
            return nil
        }
    }

    private static func elapsedMilliseconds(since start: Date, now: Date = Date()) -> Int64 {
        max(0, Int64(now.timeIntervalSince(start) * 1000))
    }

    private static func addSettlementTerminalMetadata(
        _ frame: inout [String: Any],
        settlementMetadata: SettlementReceiptMetadata?
    ) {
        guard let settlementMetadata else {
            return
        }
        if frame["terminal_state_ts_unix_ms"] == nil {
            frame["terminal_state_ts_unix_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
        }
        frame["receipt_pending_deadline_seconds"] = settlementMetadata.pendingDeadlineSeconds
        frame["late_receipt_settlement"] = "not_settled"
    }

    private static func processStreaming(
        requestID: String,
        request: ChatCompletionRequest,
        state: RelayRequestState,
        modelRuntime: any ModelRuntimeServing,
        warmSwapEnabled: Bool,
        tier2Session: Tier2ProviderSession?,
        receiptBuilder: ReceiptBuilder?,
        receiptProviderID: String?,
        settlementMetadata: SettlementReceiptMetadata?,
        streamInterval: Int = 1,
        sendFrame: @escaping SendFrame
    ) async throws -> CompletionResult {
        let created = Int(Date().timeIntervalSince1970)
        let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let buffer = BlockingChunkBuffer(capacity: 256, resumeAt: 128)
        state.setBuffer(buffer)

        let consumer = Task<Int, Error> {
            while let data = buffer.next() {
                try Task.checkCancellation()
                guard !state.terminalSent else {
                    continue
                }
                let seq = state.nextSeq()
                try await sendChunk(requestID: requestID, stream: true, seq: seq, data: data, tier2Session: tier2Session, sendFrame: sendFrame)
            }
            return state.chunksSent
        }

        do {
            let handle = try await modelRuntime.acquireRequestHandle(request)
            defer {
                Task { await modelRuntime.unregisterInFlight(handle.registrationID) }
            }
            try await modelRuntime.pagedKVPreflight(request, with: handle)
            _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                id: id,
                created: created,
                model: request.model,
                delta: ["role": "assistant", "content": ""],
                finishReason: NSNull()
            )))

            let streamedAnyToolCallDelta = StreamedFlag()
            // T3-01: accumulate content-token deltas until streamInterval tokens,
            // then emit one combined SSE frame. Tool-call deltas flush any pending
            // content immediately and are never batched.
            var pendingContent = ""
            var pendingCount = 0

            let completion = try await modelRuntime.stream(request, with: handle, shouldCancel: { state.isCancelled }) { chunk in
                switch chunk {
                case .content(let text):
                    pendingContent += text
                    pendingCount += 1
                    if pendingCount >= streamInterval {
                        _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                            id: id,
                            created: created,
                            model: request.model,
                            delta: ["content": pendingContent],
                            finishReason: NSNull()
                        )))
                        pendingContent = ""
                        pendingCount = 0
                    }
                case .toolCallDelta(let toolDelta):
                    if !pendingContent.isEmpty {
                        _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                            id: id,
                            created: created,
                            model: request.model,
                            delta: ["content": pendingContent],
                            finishReason: NSNull()
                        )))
                        pendingContent = ""
                        pendingCount = 0
                    }
                    streamedAnyToolCallDelta.set()
                    _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                        id: id,
                        created: created,
                        model: request.model,
                        delta: ["tool_calls": [toolDelta.openAIDeltaDict()]],
                        finishReason: NSNull()
                    )))
                }
            }

            // Flush any remaining batched content before the finish frame.
            if !pendingContent.isEmpty {
                _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                    id: id,
                    created: created,
                    model: request.model,
                    delta: ["content": pendingContent],
                    finishReason: NSNull()
                )))
            }

            state.setUsage(completion)
            if state.isCancelled {
                buffer.cancel()
                consumer.cancel()
                let chunksSent = (try? await consumer.value) ?? state.chunksSent
                if state.markTerminalSent() {
                    let terminalStateTSUnixMS = Int64(Date().timeIntervalSince1970 * 1000)
                    let modelHashSource = RouterHandler.resolveModelHashSource(
                        warmSwapEnabled: warmSwapEnabled,
                        snapshot: handle.snapshot,
                        settlementMetadata: settlementMetadata
                    )
                    let receiptHeader = Self.buildReceiptHeader(
                        receiptBuilder: receiptBuilder,
                        providerID: receiptProviderID,
                        request: request,
                        completion: completion,
                        ttftMs: 0,
                        unixTsSeconds: Int64(Date().timeIntervalSince1970),
                        requestID: requestID,
                        modelHashSource: modelHashSource,
                        settlementMetadata: settlementMetadata,
                        terminalState: "buyer_cancel",
                        terminalStateTSUnixMS: terminalStateTSUnixMS
                    )
                    var endFrame: [String: Any] = [
                        "type": "inference_response_end",
                        "request_id": requestID,
                        "status": "cancelled",
                        "chunks_sent": chunksSent,
                        "usage": usage(completion),
                        "terminal_state_ts_unix_ms": terminalStateTSUnixMS,
                    ]
                    if let receiptHeader {
                        endFrame["receipt"] = receiptHeader
                    }
                    if let settlementMetadata {
                        endFrame["receipt_pending_deadline_seconds"] = settlementMetadata.pendingDeadlineSeconds
                        endFrame["late_receipt_settlement"] = "not_settled"
                    }
                    try await sendEndFrame(endFrame, requestID: requestID, stream: true, tier2Session: tier2Session, sendFrame: sendFrame)
                }
                return completion
            }

            // Fallback for non-streaming-incremental path: if tool calls landed only
            // in the final CompletionResult and were never streamed via .toolCallDelta
            // chunks, emit them now.
            if !streamedAnyToolCallDelta.get(), let toolCalls = completion.toolCalls, !toolCalls.isEmpty {
                for delta in toolCallDeltaChunks(toolCalls) {
                    _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                        id: id,
                        created: created,
                        model: request.model,
                        delta: ["tool_calls": delta],
                        finishReason: NSNull()
                    )))
                }
            }

            _ = buffer.enqueue(sseEvent(chatCompletionChunk(
                id: id,
                created: created,
                model: request.model,
                delta: [:],
                finishReason: completion.finishReason
            )))
            _ = buffer.enqueue(sseEvent([
                "id": id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": request.model,
                "choices": [],
                "usage": usage(completion),
            ]))
            _ = buffer.enqueue("data: [DONE]\n\n")
            buffer.finish()

            let chunksSent = try await consumer.value
            if state.markTerminalSent() {
                let terminalStateTSUnixMS = Int64(Date().timeIntervalSince1970 * 1000)
                var endFrame: [String: Any] = [
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "complete",
                    "chunks_sent": chunksSent,
                    "usage": usage(completion),
                    "terminal_state_ts_unix_ms": terminalStateTSUnixMS,
                ]
                let modelHashSource = RouterHandler.resolveModelHashSource(
                    warmSwapEnabled: warmSwapEnabled,
                    snapshot: handle.snapshot,
                    settlementMetadata: settlementMetadata
                )
                let receiptHeader = Self.buildReceiptHeader(
                    receiptBuilder: receiptBuilder,
                    providerID: receiptProviderID,
                    request: request,
                    completion: completion,
                    ttftMs: 0,
                    unixTsSeconds: Int64(Date().timeIntervalSince1970),
                    requestID: requestID,
                    modelHashSource: modelHashSource,
                    settlementMetadata: settlementMetadata,
                    terminalStateTSUnixMS: terminalStateTSUnixMS
                )
                if let receiptHeader {
                    endFrame["receipt"] = receiptHeader
                }
                if let settlementMetadata {
                    endFrame["receipt_pending_deadline_seconds"] = settlementMetadata.pendingDeadlineSeconds
                    endFrame["late_receipt_settlement"] = "not_settled"
                }
                try await sendEndFrame(endFrame, requestID: requestID, stream: true, tier2Session: tier2Session, sendFrame: sendFrame)
            }
            return completion
        } catch {
            buffer.cancel()
            consumer.cancel()
            if error is CancellationError {
                let chunksSent = (try? await consumer.value) ?? state.chunksSent
                if state.markTerminalSent() {
                    var endFrame: [String: Any] = [
                        "type": "inference_response_end",
                        "request_id": requestID,
                        "status": "cancelled",
                        "chunks_sent": chunksSent,
                        "usage": state.usage ?? zeroUsage(),
                    ]
                    addSettlementTerminalMetadata(&endFrame, settlementMetadata: settlementMetadata)
                    try? await sendEndFrame(endFrame, requestID: requestID, stream: true, tier2Session: tier2Session, sendFrame: sendFrame)
                }
                throw RelayCancellationAcknowledged()
            }
            throw error
        }
    }

    static func errorEndFrame(requestID: String, error: APIError, chunksSent: Int) -> [String: Any] {
        let status: String
        switch error.code {
        case "model_not_loaded", "model_not_found":
            status = "error_model_not_loaded"
        case "context_length_exceeded":
            status = "error_context_exceeded"
        case "queue_full":
            status = "error_queue_full"
        // AC-V2-3a + AC-V2-9 + AC-V2-9b (SPEC-019 v0.2.4 §5): these
        // four terminal structured-output codes are the canonical table.
        // Asymmetry across provider WS, coordinator SSE, and gateway SSE
        // allow-lists is a money-path violation.
        case "malformed_json_response", "json_schema_validation_failed", "response_byte_cap_exceeded", "provider_timeout":
            status = error.code
        default:
            status = "error_internal"
        }
        var frame: [String: Any] = [
            "type": "inference_response_end",
            "request_id": requestID,
            "status": status,
            "chunks_sent": chunksSent,
            "error": error.message,
        ]
        if error.code == "malformed_json_response" ||
            error.code == "json_schema_validation_failed" ||
            error.code == "response_byte_cap_exceeded" ||
            error.code == "provider_timeout" {
            frame["retryable"] = (error.envelope["error"] as? [String: Any])?["retryable"] as? Bool
        }
        return frame
    }

    private static func sendChunk(
        requestID: String,
        stream: Bool,
        seq: Int,
        data: String,
        tier2Session: Tier2ProviderSession?,
        sendFrame: @escaping SendFrame
    ) async throws {
        if let tier2Session {
            let sealStart = clockMonotonicMicros()
            let sealed = try tier2Session.sealResponseChunk(requestID: requestID, stream: stream, seq: seq, plaintext: data)
            EgressPerfTraceKey.current?.recordSeal(durationMicros: clockMonotonicMicros() &- sealStart)
            try await sendFrame(sealed)
            return
        }
        try await sendFrame([
            "type": "inference_response_chunk",
            "request_id": requestID,
            "seq": seq,
            "data": data,
        ])
    }

    private static func sendEndFrame(
        _ frame: sending [String: Any],
        requestID: String,
        stream: Bool,
        tier2Session: Tier2ProviderSession?,
        sendFrame: @escaping SendFrame
    ) async throws {
        if let tier2Session {
            try await sendFrame(tier2Session.sealResponseEnd(requestID: requestID, stream: stream, payload: frame))
            return
        }
        try await sendFrame(frame)
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
                    "message": chatCompletionMessage(completion),
                    "finish_reason": completion.finishReason,
                ]
            ],
            "usage": usage(completion),
        ]
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

    private static func zeroUsage() -> [String: Any] {
        [
            "prompt_tokens": 0,
            "cached_prompt_tokens": 0,
            "completion_tokens": 0,
            "total_tokens": 0,
            "macprovider_model_hash_observed": NSNull(),
        ]
    }

    private static func sseEvent(_ body: Any) -> String {
        do {
            return "data: \(try jsonString(body))\n\n"
        } catch {
            return #"data: {"error":{"message":"Inference engine error","type":"server_error","code":"internal_error"}}"# + "\n\n"
        }
    }

    private static func jsonString(_ body: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

private struct RelayCancellationAcknowledged: Error {}

private final class RelayRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: BlockingChunkBuffer?
    private var terminal = false
    private var sentChunks = 0
    private var cancelled = false
    private var currentUsage: [String: Any]?

    var terminalSent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }

    var chunksSent: Int {
        lock.lock()
        defer { lock.unlock() }
        return sentChunks
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var usage: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return currentUsage
    }

    func setUsage(_ completion: CompletionResult) {
        lock.lock()
        currentUsage = [
            "prompt_tokens": completion.promptTokens,
            "cached_prompt_tokens": completion.cachedPromptTokens,
            "completion_tokens": completion.completionTokens,
            "total_tokens": completion.promptTokens + completion.completionTokens,
        ]
        lock.unlock()
    }

    func setBuffer(_ buffer: BlockingChunkBuffer) {
        lock.lock()
        self.buffer = buffer
        let shouldCancel = terminal
        lock.unlock()
        if shouldCancel {
            buffer.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let buffer = buffer
        lock.unlock()
        buffer?.cancel()
    }

    func nextSeq() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let seq = sentChunks
        sentChunks += 1
        return seq
    }

    func markTerminalSent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else {
            return false
        }
        terminal = true
        return true
    }
}

private final class BlockingChunkBuffer: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private let resumeAt: Int
    private var queue: [String] = []
    private var closed = false
    private var cancelled = false

    init(capacity: Int, resumeAt: Int) {
        self.capacity = max(1, capacity)
        self.resumeAt = max(0, min(resumeAt, capacity))
    }

    func enqueue(_ value: String) -> Bool {
        condition.lock()
        defer {
            condition.unlock()
        }

        while queue.count >= capacity && !closed && !cancelled {
            condition.wait()
        }
        guard !closed, !cancelled else {
            return false
        }
        queue.append(value)
        condition.signal()
        return true
    }

    func next() -> String? {
        condition.lock()
        defer {
            condition.unlock()
        }

        while queue.isEmpty && !closed && !cancelled {
            condition.wait()
        }
        guard !queue.isEmpty else {
            return nil
        }
        let value = queue.removeFirst()
        if queue.count <= resumeAt {
            condition.broadcast()
        } else {
            condition.signal()
        }
        return value
    }

    func finish() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}
