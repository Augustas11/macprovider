import CryptoKit
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
    private let fallbackMaxActiveRequests: Int
    private let maxBodyBytes: Int
    private let sendFrame: SendFrame
    private let tier2Session: Tier2ProviderSession?
    private let receiptBuilder: ReceiptBuilder?
    private let receiptProviderID: String?
    private let demoteAutoupdateTrust: TrustDemotion?
    private let relayBlindRuntime: RelayBlindProviderRuntime?
    private let privacyClassBeta: Bool
    private let postureProbe: (any PrivacyPostureProbe)?
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
        relayBlindRuntime: RelayBlindProviderRuntime? = nil,
        demoteAutoupdateTrust: TrustDemotion? = nil,
        privacyClassBeta: Bool = false,
        postureProbe: (any PrivacyPostureProbe)? = nil,
        sendFrame: @escaping SendFrame
    ) {
        self.modelRuntime = modelRuntime
        self.providerStatus = providerStatus
        self.loadedModelID = loadedModelID
        self.catalogModelIDAlias = catalogModelIDAlias
        self.warmSwapEnabled = warmSwapEnabled
        self.fallbackMaxActiveRequests = max(1, maxActiveRequests)
        self.maxBodyBytes = max(1, maxBodyBytes)
        self.tier2Session = tier2Session
        self.receiptBuilder = receiptBuilder
        self.receiptProviderID = receiptProviderID
        self.streamInterval = max(1, streamInterval)
        self.relayBlindRuntime = relayBlindRuntime
        self.demoteAutoupdateTrust = demoteAutoupdateTrust
        self.privacyClassBeta = privacyClassBeta
        self.postureProbe = postureProbe
        self.sendFrame = sendFrame
    }

    func handleInferenceRequest(_ message: [String: Any]) async throws {
        guard let rawRequestID = message["request_id"] as? String,
              let requestID = ChatCompletionRequest.normalizedRequestID(rawRequestID) else {
            let reply = (message["request_id"] as? String).flatMap(ChatCompletionRequest.normalizedRequestID)
                ?? "inference_request"
            try await sendNAK(inReplyTo: reply, code: "invalid_request_id", message: "inference_request requires a non-empty request_id of at most 512 bytes with no control characters")
            return
        }
        guard let stream = message["stream"] as? Bool else {
            try await sendNAK(inReplyTo: "inference_request", code: "invalid_message", message: "inference_request requires request_id, stream, and body")
            return
        }
        let body: String
        let maxOutputTokens: Int?
        let decryptedConversationKey: String?
        let bodyEncoding: String?
        let relayBlindContextObject: [String: Any]?
        // SPEC-001-R005: the raw `relay_blind_settlement` member. Under SPEC-008
        // it travels only inside the protected payload, so an outer copy on an
        // encrypted frame is misplaced.
        let relayBlindSettlementWire: Any?
        let relayBlindSettlementMisplaced: Bool
        var requestPrivacyClass: String?
        var requestPrivacyMalformed = false
        if let tier2Session {
            guard message["encrypted"] as? Bool == true else {
                try await sendNAK(inReplyTo: requestID, code: "tier2_encrypted_frame_required", message: "Tier-2 session requires encrypted inference_request frames")
                return
            }
            do {
                let payload = try tier2Session.openRequestPayload(message: message, requestID: requestID, stream: stream)
                body = payload.body
                maxOutputTokens = payload.maxOutputTokens
                decryptedConversationKey = payload.conversationKey
                bodyEncoding = payload.bodyEncoding
                relayBlindContextObject = payload.relayBlindContext
                relayBlindSettlementWire = payload.relayBlindSettlement
                relayBlindSettlementMisplaced = message.keys.contains(RelayBlindSettlementMetadata.wireKey)
                requestPrivacyClass = payload.privacyClass
                requestPrivacyMalformed = payload.privacyClassMalformed
            } catch {
                await demoteAutoupdateTrust?("encrypted_leg_invalidated")
                try await sendNAK(inReplyTo: requestID, code: "tier2_aead_decrypt_failed", message: "Encrypted inference_request failed authentication")
                return
            }
        } else if let cleartextBody = message["body"] as? String {
            body = cleartextBody
            if let rawLimit = message["max_output_tokens"] {
                guard !(rawLimit is Bool), let limit = rawLimit as? Int, limit >= 0 else {
                    try await sendNAK(inReplyTo: requestID, code: "invalid_max_output_tokens", message: "inference_request max_output_tokens must be a non-negative integer")
                    return
                }
                maxOutputTokens = limit
            } else {
                maxOutputTokens = nil
            }
            decryptedConversationKey = nil
            bodyEncoding = message["body_encoding"] as? String
            relayBlindContextObject = message["relay_blind_context"] as? [String: Any]
            relayBlindSettlementWire = message[RelayBlindSettlementMetadata.wireKey]
            relayBlindSettlementMisplaced = false
        } else {
            try await sendNAK(inReplyTo: "inference_request", code: "invalid_message", message: "inference_request requires request_id, stream, and body")
            return
        }
        if tier2Session == nil {
            switch Self.privacyMarker(message["privacy_class"], present: message.keys.contains("privacy_class")) {
            case .absent:
                break
            case .value(let value):
                requestPrivacyClass = value
            case .invalid:
                requestPrivacyMalformed = true
            }
        } else if message.keys.contains("privacy_class") {
            // SPEC-049 §4.7 puts the field inside the protected payload. A clear
            // outer copy must agree with that inner value.
            switch Self.privacyMarker(message["privacy_class"], present: true) {
            case .value(let value) where value == requestPrivacyClass && !requestPrivacyMalformed:
                break
            default:
                requestPrivacyMalformed = true
                requestPrivacyClass = nil
            }
        }
        let requestMarker: PrivacyMarker = requestPrivacyMalformed
            ? .invalid
            : (requestPrivacyClass.map(PrivacyMarker.value) ?? .absent)
        let isRelayBlind = bodyEncoding == RelayBlindEnvelope.version
        let privacyPath = Self.privacyDispatchPath(
            mode: privacyClassBeta,
            request: requestMarker,
            context: Self.privacyMarker(
                relayBlindContextObject?["privacy_class"],
                present: relayBlindContextObject?.keys.contains("privacy_class") == true
            ),
            relayBlind: isRelayBlind
        )

        let relayBlindOpened: RelayBlindProviderRuntime.OpenedRequest?
        var relayBlindSettlement: RelayBlindSettlementMetadata?
        if isRelayBlind {
            guard let relayBlindRuntime else {
                try await sendRelayBlindFailure(requestID: requestID, stream: stream, code: RelayBlindProviderError.disabled.code)
                return
            }
            guard message["settlement"] == nil, let relayBlindContextObject else {
                try await sendRelayBlindFailure(requestID: requestID, stream: stream, code: RelayBlindProviderError.invalidEnvelope.code)
                return
            }
            // SPEC-001-R005: a malformed or mismatched `relay_blind_settlement`
            // is rejected like `settlement`, before decryption and the claim.
            // It binds by envelope digest, never by the plaintext request id.
            if relayBlindSettlementMisplaced {
                try await sendRelayBlindFailure(requestID: requestID, stream: stream, code: RelayBlindProviderError.invalidEnvelope.code)
                return
            }
            if let relayBlindSettlementWire {
                guard let parsed = RelayBlindSettlementMetadata(wire: relayBlindSettlementWire),
                      relayBlindSettlementBinds(parsed, envelopeBody: body, contextObject: relayBlindContextObject) else {
                    try await sendRelayBlindFailure(requestID: requestID, stream: stream, code: RelayBlindProviderError.invalidEnvelope.code)
                    return
                }
                relayBlindSettlement = parsed
            }
            if privacyPath == .downgrade {
                try await sendPrivacyBoundRejection(
                    contextObject: relayBlindContextObject,
                    requestID: requestID,
                    stream: stream,
                    code: PrivacyClassConstants.downgradeRejected
                )
                return
            }
            if privacyPath == .privacy {
                let fresh = postureProbe.map { PrivacyRuntimeHardening.recheckBeforeDecrypt(probe: $0) } ?? false
                if !fresh || PrivacyRuntimeHardening.decryptRecheckFailed {
                    PrivacyRuntimeHardening.noteDecryptRecheckFailed()
                    try await sendPrivacyBoundRejection(
                        contextObject: relayBlindContextObject,
                        requestID: requestID,
                        stream: stream,
                        code: PrivacyClassConstants.postureStale
                    )
                    return
                }
            }
            do {
                relayBlindOpened = try relayBlindRuntime.open(
                    envelopeBody: body,
                    outerRequestID: requestID,
                    outerStream: stream,
                    contextObject: relayBlindContextObject,
                    expectedAssignedSession: tier2Session?.assignedID,
                    privacyClass: privacyPath == .privacy
                )
            } catch let rejection as RelayBlindProviderRejection {
                try await sendRelayBlindRejection(
                    rejection.evidence,
                    requestID: requestID,
                    stream: stream,
                    error: rejection.error
                )
                return
            } catch let error as RelayBlindProviderError {
                try await sendRelayBlindFailure(requestID: requestID, stream: stream, code: error.code)
                return
            } catch {
                try await sendRelayBlindFailure(requestID: requestID, stream: stream, code: RelayBlindProviderError.decryptFailed.code)
                return
            }
        } else if privacyPath == .downgrade {
            // A marker on a non-envelope has no dispatch context to bind.
            try await sendRelayBlindFailure(
                requestID: requestID, stream: stream, code: PrivacyClassConstants.downgradeRejected
            )
            return
        } else if let bodyEncoding, bodyEncoding.hasPrefix("relay-blind-request-") {
            try await sendRelayBlindFailure(requestID: requestID, stream: stream, code: RelayBlindProviderError.invalidEnvelope.code)
            return
        } else {
            guard relayBlindContextObject == nil, relayBlindSettlementWire == nil, !relayBlindSettlementMisplaced else {
                try await sendRelayBlindFailure(requestID: requestID, stream: stream, code: RelayBlindProviderError.invalidEnvelope.code)
                return
            }
            relayBlindOpened = nil
        }

        guard active[requestID] == nil else {
            if let relayBlindOpened {
                try await terminateClaimedRelay(
                    relayBlindOpened, requestID: requestID, stream: stream, error: .providerUnsupported
                )
                return
            }
            try await sendNAK(inReplyTo: "inference_request", code: "duplicate_request_id", message: "Duplicate active request_id: \(requestID)")
            return
        }

        let admissionLimit = await currentAdmissionLimit()
        guard active.count < admissionLimit else {
            if let relayBlindOpened {
                try await terminateClaimedRelay(
                    relayBlindOpened, requestID: requestID, stream: stream, error: .providerUnsupported
                )
                return
            }
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
        if relayBlindOpened != nil {
            settlementMetadata = nil
        } else if let settlementWire = message["settlement"] as? [String: Any] {
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

        let effectiveBodyLimit = relayBlindOpened == nil
            ? maxBodyBytes
            : max(maxBodyBytes, RelayBlindEnvelope.maxSerializedBytes)
        guard body.utf8.count <= effectiveBodyLimit else {
            if let relayBlindOpened {
                try await terminateClaimedRelay(
                    relayBlindOpened, requestID: requestID, stream: stream, error: .ciphertextInvalid
                )
                return
            }
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
            if let relayBlindOpened {
                try await terminateClaimedRelay(
                    relayBlindOpened, requestID: requestID, stream: stream, error: .providerUnsupported
                )
                return
            }
            try await Self.sendEndFrame([
                "type": "inference_response_end",
                "request_id": requestID,
                "status": "error_provider_paused",
                "chunks_sent": 0,
                "error": "Provider is paused or draining",
            ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            return
        }

        var settlementAttempt: RelayBlindSettlementAttempt?
        if let opened = relayBlindOpened, let metadata = relayBlindSettlement, let builder = receiptBuilder {
            settlementAttempt = RelayBlindSettlementAttempt(
                metadata: metadata,
                context: opened.context,
                privacyClass: opened.responseSealer != nil,
                builder: builder
            )
        }
        let state = RelayRequestState(relayBlindSettlement: settlementAttempt)
        let receiptBuilder = receiptBuilder
        let receiptProviderID = receiptProviderID
        let task = Task { [weak self, modelRuntime, providerStatus, loadedModelID, catalogModelIDAlias, warmSwapEnabled, sendFrame, tier2Session, state, settlementMetadata, streamInterval, relayBlindRuntime] in
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
                maxOutputTokens: maxOutputTokens,
                conversationKey: conversationKey?.isEmpty == false ? conversationKey : nil,
                startedAt: startedAt,
                streamInterval: streamInterval,
                relayBlindOpened: relayBlindOpened,
                relayBlindRuntime: relayBlindRuntime,
                sendFrame: sendFrame
            )
            await self?.removeActive(requestID)
        }
        active[requestID] = ActiveRequest(task: task, state: state)
    }

    func currentAdmissionLimit() async -> Int {
        let snapshot = await providerStatus.snapshot()
        let current = snapshot.capacity.maxConcurrency
        guard current > 0 else { return fallbackMaxActiveRequests }
        return current
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

    /// SPEC-001-R005 binding: the metadata names this provider and its current
    /// receipt key, and its envelope digest equals both the dispatch context's
    /// and this provider's own SHA-256 over the exact envelope bytes.
    private func relayBlindSettlementBinds(
        _ metadata: RelayBlindSettlementMetadata,
        envelopeBody: String,
        contextObject: [String: Any]
    ) -> Bool {
        guard let receiptBuilder, let receiptProviderID, !receiptProviderID.isEmpty,
              metadata.providerID == receiptProviderID,
              let keyID = try? receiptBuilder.currentReceiptKeyID(providerId: receiptProviderID),
              metadata.providerReceiptKeyID == keyID,
              contextObject["envelope_digest"] as? String == metadata.relayBlindEnvelopeDigest else {
            return false
        }
        let computed = RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(envelopeBody.utf8))))
        return computed == metadata.relayBlindEnvelopeDigest
    }

    private func sendRelayBlindFailure(requestID: String, stream: Bool, code: String) async throws {
        try await Self.sendEndFrame([
            "type": "inference_response_end",
            "request_id": requestID,
            "status": code,
            "chunks_sent": 0,
            "error": code,
        ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
    }

    private func terminateClaimedRelay(
        _ opened: RelayBlindProviderRuntime.OpenedRequest,
        requestID: String,
        stream: Bool,
        error: RelayBlindProviderError
    ) async throws {
        try? relayBlindRuntime?.journal.markTerminal(opened.claim)
        try await sendRelayBlindRejection(
            .rejected(context: opened.context, error: error),
            requestID: requestID,
            stream: stream,
            error: error
        )
    }

    private func sendRelayBlindRejection(
        _ evidence: RelayBlindValidationEvidence,
        requestID: String,
        stream: Bool,
        error: RelayBlindProviderError
    ) async throws {
        try await Self.sendValidationFrame(
            evidence,
            requestID: requestID,
            stream: stream,
            tier2Session: tier2Session,
            sendFrame: sendFrame
        )
        try await Self.sendEndFrame([
            "type": "inference_response_end",
            "request_id": requestID,
            "status": error.code,
            "chunks_sent": 0,
            "error": error.code,
            "relay_blind_validation": evidence.wireObject,
        ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
    }

    /// SPEC-041-R005 bound rejection for a privacy code. Parsing the context
    /// does not decrypt. When the context itself cannot be bound, the same
    /// code is sent without evidence.
    private func sendPrivacyBoundRejection(
        contextObject: [String: Any],
        requestID: String,
        stream: Bool,
        code: String
    ) async throws {
        let context: RelayBlindDispatchContext
        do {
            context = try RelayBlindDispatchContext.parse(contextObject)
        } catch {
            try await sendRelayBlindFailure(requestID: requestID, stream: stream, code: code)
            return
        }
        let evidence = RelayBlindValidationEvidence(
            context: context, inputTokens: 0, state: "rejected", errorCode: code
        )
        try await Self.sendValidationFrame(
            evidence,
            requestID: requestID,
            stream: stream,
            tier2Session: tier2Session,
            sendFrame: sendFrame
        )
        try await Self.sendEndFrame([
            "type": "inference_response_end",
            "request_id": requestID,
            "status": code,
            "chunks_sent": 0,
            "error": code,
            "relay_blind_validation": evidence.wireObject,
        ], requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
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
        maxOutputTokens: Int?,
        conversationKey: String?,
        startedAt: Date,
        streamInterval: Int = 1,
        relayBlindOpened: RelayBlindProviderRuntime.OpenedRequest?,
        relayBlindRuntime: RelayBlindProviderRuntime?,
        sendFrame: @escaping SendFrame
    ) async {
        var completionResult: CompletionResult?
        var failed = false
        var telemetryModelID = loadedModelID ?? ""
        var relayBlindEvidence: RelayBlindValidationEvidence?
        var relayBlindPrepared: RelayBlindPreparedRequest?
        let privacySealer = relayBlindOpened?.responseSealer.map { PrivacyResponseSealerBox($0) }
        let privacyModel = relayBlindOpened?.request.model ?? loadedModelID ?? ""

        do {
            let requestData = Data(body.utf8)
            // SPEC-037 FR-KVP11: stamp ingest provenance. Neither relay nor
            // Tier-2 traffic is ever persisted by the disk tier (only the
            // direct-HTTP operator path is), independent of key shape.
            let ingestProvenance: KVIngestProvenance = tier2Session != nil ? .tier2 : .relay
            var request: ChatCompletionRequest
            if let relayBlindOpened {
                request = relayBlindOpened.request.withRequestID(requestID)
                if privacySealer != nil {
                    request = request.withConversationKey(nil)
                }
            } else {
                request = try ChatCompletionRequest.parse(data: requestData)
                    .withConversationKey(conversationKey)
                    .withRequestID(requestID)
                    .withIngestProvenance(ingestProvenance)
                if let maxOutputTokens {
                    request = request.withMaxTokensLimit(maxOutputTokens)
                }
            }
            telemetryModelID = request.model
            if let opened = relayBlindOpened, let relayBlindRuntime {
                let prepared: RelayBlindPreparedRequest
                do {
                    prepared = try await modelRuntime.relayBlindPrepare(request)
                } catch let error as APIError where error.code == "unsupported_sampling_penalty" {
                    throw RelayBlindProviderError.unsupportedSamplingPenalty
                } catch {
                    throw RelayBlindProviderError.providerUnsupported
                }
                relayBlindPrepared = prepared
                let preparedModelID = prepared.handle.snapshot.modelID
                let relayAliases = (preparedModelID != nil && preparedModelID == loadedModelID)
                    ? modelIDAliasList(catalogModelIDAlias)
                    : []
                // SPEC-015 §N.13: the receipt's model hash is the hash of this
                // pinned handle, and the snapshot model id must resolve to it.
                state.relayBlindSettlement?.pin(
                    modelHash: prepared.handle.snapshot.modelHash,
                    preparedModelID: preparedModelID,
                    aliases: relayAliases
                )
                do {
                    try request.validateModelMatches(preparedModelID, aliases: relayAliases)
                } catch {
                    throw RelayBlindProviderError.ciphertextInvalid
                }
                let providerWireModelID = relayAliases.first ?? preparedModelID
                guard opened.envelope.providerModel == providerWireModelID,
                      request.maxTokens == Int(exactly: opened.envelope.maxOutputTokens) else {
                    throw RelayBlindProviderError.ciphertextInvalid
                }
                let inputTokens = prepared.inputTokens
                guard inputTokens >= 0, UInt64(inputTokens) <= opened.envelope.inputTokenUpperBound else {
                    let rejection = RelayBlindValidationEvidence.rejected(
                        context: opened.context, error: .ciphertextInvalid
                    )
                    relayBlindEvidence = rejection
                    try await sendValidationFrame(
                        rejection,
                        requestID: requestID,
                        stream: stream,
                        tier2Session: tier2Session,
                        sendFrame: sendFrame
                    )
                    throw RelayBlindProviderError.ciphertextInvalid
                }
                try relayBlindRuntime.journal.markValidated(opened.claim, inputTokens: inputTokens)
                state.relayBlindSettlement?.validated(inputTokens: inputTokens)
                let evidence = RelayBlindValidationEvidence(context: opened.context, inputTokens: inputTokens, state: "validated")
                relayBlindEvidence = evidence
                try await sendValidationFrame(
                    evidence,
                    requestID: requestID,
                    stream: stream,
                    tier2Session: tier2Session,
                    sendFrame: sendFrame
                )
            } else {
                let validationModelID = warmSwapEnabled
                    ? await modelRuntime.currentSnapshot().modelID
                    : loadedModelID
                let relayAliases = (validationModelID != nil && validationModelID == loadedModelID)
                    ? modelIDAliasList(catalogModelIDAlias)
                    : []
                try request.validateModelMatches(validationModelID, aliases: relayAliases)
            }
        if stream {
            if privacySealer != nil {
                completionResult = try await processStreaming(
                    requestID: requestID,
                    request: request,
                    state: state,
                    modelRuntime: modelRuntime,
                    warmSwapEnabled: warmSwapEnabled,
                    tier2Session: tier2Session,
                    receiptBuilder: nil,
                    receiptProviderID: receiptProviderID,
                    settlementMetadata: settlementMetadata,
                    streamInterval: streamInterval,
                    relayBlindEvidence: relayBlindEvidence,
                    relayBlindRuntime: relayBlindRuntime,
                    relayBlindClaim: relayBlindOpened?.claim,
                    preparedHandle: relayBlindPrepared?.handle,
                    privacySealer: privacySealer,
                    sendFrame: sendFrame
                )
            } else {
                let trace = EgressPerfTrace()
                completionResult = try await EgressPerfTraceKey.$current.withValue(trace) {
                    try await processStreaming(
                        requestID: requestID,
                        request: request,
                        state: state,
                        modelRuntime: modelRuntime,
                        warmSwapEnabled: warmSwapEnabled,
                        tier2Session: tier2Session,
                        receiptBuilder: relayBlindOpened == nil ? receiptBuilder : nil,
                        receiptProviderID: receiptProviderID,
                        settlementMetadata: settlementMetadata,
                        streamInterval: streamInterval,
                        relayBlindEvidence: relayBlindEvidence,
                        relayBlindRuntime: relayBlindRuntime,
                        relayBlindClaim: relayBlindOpened?.claim,
                        preparedHandle: relayBlindPrepared?.handle,
                        privacySealer: nil,
                        sendFrame: sendFrame
                    )
                }
                trace.printSummary(requestID: requestID, completionTokens: completionResult?.completionTokens ?? 0)
            }
        } else {
            completionResult = try await processNonStreaming(
                requestID: requestID,
                request: request,
                state: state,
                modelRuntime: modelRuntime,
                tier2Session: tier2Session,
                receiptBuilder: relayBlindOpened == nil ? receiptBuilder : nil,
                receiptProviderID: receiptProviderID,
                settlementMetadata: settlementMetadata,
                startedAt: startedAt,
                warmSwapEnabled: warmSwapEnabled,
                relayBlindEvidence: relayBlindEvidence,
                relayBlindRuntime: relayBlindRuntime,
                relayBlindClaim: relayBlindOpened?.claim,
                preparedHandle: relayBlindPrepared?.handle,
                privacySealer: privacySealer,
                sendFrame: sendFrame
            )
        }
        } catch is RelayCancellationAcknowledged {
        } catch is CancellationError {
            if state.markTerminalSent() {
                await emitPrivacyClosing(
                    sealer: privacySealer,
                    stream: stream,
                    status: PrivacyClassConstants.finalStatusCancelled,
                    promptTokens: privacyTokenCount(state.usage, key: "prompt_tokens"),
                    completionTokens: privacyTokenCount(state.usage, key: "completion_tokens"),
                    model: privacyModel,
                    requestID: requestID,
                    state: state,
                    tier2Session: tier2Session,
                    sendFrame: sendFrame
                )
                var endFrame: [String: Any] = [
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "cancelled",
                    "chunks_sent": state.chunksSent,
                    "usage": state.usage ?? zeroUsage(),
                ]
                if let evidence = relayBlindEvidence { endFrame["relay_blind_validation"] = evidence.terminalWireObject() }
                if let opened = relayBlindOpened, let relayBlindRuntime {
                    try? relayBlindRuntime.journal.markTerminal(opened.claim, inputTokens: relayBlindEvidence?.inputTokens)
                }
                addSettlementTerminalMetadata(&endFrame, settlementMetadata: settlementMetadata)
                attachRelayBlindSettlementReceipt(&endFrame, state: state)
                try? await sendEndFrame(endFrame, requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            }
        } catch let error as RelayBlindProviderError {
            failed = true
            if relayBlindEvidence == nil, let opened = relayBlindOpened {
                let rejection = RelayBlindValidationEvidence.rejected(context: opened.context, error: error)
                relayBlindEvidence = rejection
                try? await sendValidationFrame(
                    rejection,
                    requestID: requestID,
                    stream: stream,
                    tier2Session: tier2Session,
                    sendFrame: sendFrame
                )
            }
            if let opened = relayBlindOpened, let relayBlindRuntime {
                try? relayBlindRuntime.journal.markTerminal(opened.claim)
            }
            if state.markTerminalSent() {
                await emitPrivacyClosing(
                    sealer: privacySealer,
                    stream: stream,
                    status: PrivacyClassConstants.finalStatusError,
                    promptTokens: privacyTokenCount(state.usage, key: "prompt_tokens"),
                    completionTokens: privacyTokenCount(state.usage, key: "completion_tokens"),
                    model: privacyModel,
                    requestID: requestID,
                    state: state,
                    tier2Session: tier2Session,
                    sendFrame: sendFrame
                )
                var endFrame: [String: Any] = [
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": error.code,
                    "chunks_sent": state.chunksSent,
                    "error": error.code,
                ]
                if let evidence = relayBlindEvidence { endFrame["relay_blind_validation"] = evidence.terminalWireObject() }
                attachRelayBlindSettlementReceipt(&endFrame, state: state)
                try? await sendEndFrame(endFrame, requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            }
        } catch let error as APIError {
            failed = true
            if state.markTerminalSent() {
                await emitPrivacyClosing(
                    sealer: privacySealer,
                    stream: stream,
                    status: PrivacyClassConstants.finalStatusError,
                    promptTokens: privacyTokenCount(state.usage, key: "prompt_tokens"),
                    completionTokens: privacyTokenCount(state.usage, key: "completion_tokens"),
                    model: privacyModel,
                    requestID: requestID,
                    state: state,
                    tier2Session: tier2Session,
                    sendFrame: sendFrame
                )
                var endFrame = relayBlindOpened == nil
                    ? errorEndFrame(requestID: requestID, error: error, chunksSent: state.chunksSent)
                    : [
                        "type": "inference_response_end",
                        "request_id": requestID,
                        "status": RelayBlindProviderError.committedFailed.code,
                        "chunks_sent": state.chunksSent,
                        "error": RelayBlindProviderError.committedFailed.code,
                    ]
                if let evidence = relayBlindEvidence { endFrame["relay_blind_validation"] = evidence.terminalWireObject() }
                if let opened = relayBlindOpened, let relayBlindRuntime { try? relayBlindRuntime.journal.markTerminal(opened.claim, inputTokens: relayBlindEvidence?.inputTokens) }
                addSettlementTerminalMetadata(&endFrame, settlementMetadata: settlementMetadata)
                attachRelayBlindSettlementReceipt(&endFrame, state: state)
                try? await sendEndFrame(endFrame, requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            }
        } catch {
            failed = true
            if state.markTerminalSent() {
                await emitPrivacyClosing(
                    sealer: privacySealer,
                    stream: stream,
                    status: PrivacyClassConstants.finalStatusError,
                    promptTokens: privacyTokenCount(state.usage, key: "prompt_tokens"),
                    completionTokens: privacyTokenCount(state.usage, key: "completion_tokens"),
                    model: privacyModel,
                    requestID: requestID,
                    state: state,
                    tier2Session: tier2Session,
                    sendFrame: sendFrame
                )
                var endFrame: [String: Any] = [
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "error_internal",
                    "chunks_sent": state.chunksSent,
                    "error": relayBlindOpened == nil ? String(describing: error) : RelayBlindProviderError.committedFailed.code,
                ]
                if relayBlindOpened != nil { endFrame["status"] = RelayBlindProviderError.committedFailed.code }
                if let evidence = relayBlindEvidence { endFrame["relay_blind_validation"] = evidence.terminalWireObject() }
                if let opened = relayBlindOpened, let relayBlindRuntime { try? relayBlindRuntime.journal.markTerminal(opened.claim, inputTokens: relayBlindEvidence?.inputTokens) }
                addSettlementTerminalMetadata(&endFrame, settlementMetadata: settlementMetadata)
                attachRelayBlindSettlementReceipt(&endFrame, state: state)
                try? await sendEndFrame(endFrame, requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
            }
        }
        if let relayBlindPrepared {
            await modelRuntime.unregisterInFlight(relayBlindPrepared.handle.registrationID)
        }
        await providerStatus.finishRequest(
            startedAt: startedAt,
            completion: completionResult,
            failed: failed,
            requestID: requestID
        )
        if relayBlindOpened == nil, !failed, !state.isCancelled, let completionResult {
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
        relayBlindEvidence: RelayBlindValidationEvidence?,
        relayBlindRuntime: RelayBlindProviderRuntime?,
        relayBlindClaim: RelayBlindExecutionJournal.Claim?,
        preparedHandle: RequestHandle?,
        privacySealer: PrivacyResponseSealerBox?,
        sendFrame: @escaping SendFrame
    ) async throws -> CompletionResult {
        // SPEC-015 §M.2.2 atomic-read invariant — bind the receipt
        // to the snapshot the runtime ACTUALLY used to drive
        // generation, not to a separately-sampled `currentSnapshot()`
        // which can drift across an actor interleaving / warm-swap.
        let (completion, servedSnapshot): (CompletionResult, RuntimeSnapshot)
        if let preparedHandle {
            (completion, servedSnapshot) = try await modelRuntime.completeWithServedSnapshot(
                request, with: preparedHandle, shouldCancel: { state.isCancelled }
            )
        } else {
            (completion, servedSnapshot) = try await modelRuntime.completeWithServedSnapshot(
                request, shouldCancel: { state.isCancelled }
            )
        }
        let modelHashSource = RouterHandler.resolveModelHashSource(
            warmSwapEnabled: warmSwapEnabled,
            snapshot: servedSnapshot,
            settlementMetadata: settlementMetadata
        )
        let unixTsSeconds = Int64(Date().timeIntervalSince1970)
        state.setUsage(completion)
        if state.isCancelled {
            if state.markTerminalSent() {
                let counts = privacyCounts(completion)
                await emitPrivacyClosing(
                    sealer: privacySealer,
                    stream: false,
                    status: PrivacyClassConstants.finalStatusCancelled,
                    promptTokens: counts.prompt,
                    completionTokens: counts.completion,
                    model: request.model,
                    requestID: requestID,
                    state: state,
                    tier2Session: tier2Session,
                    sendFrame: sendFrame
                )
                let terminalStateTSUnixMS = Int64(Date().timeIntervalSince1970 * 1000)
                // A cancelled non-streaming request delivered no output. The
                // buyer_cancel receipt binds the empty delivered prefix with
                // zero billable usage (SPEC-015 §N.5/§N.7), never the
                // generated result.
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
                    runtimeSettlementEligible: modelRuntime.isSettlementReceiptEligible,
                    settlementRuntimeSource: modelRuntime.settlementRuntimeSource,
                    relayBlindSuppressed: relayBlindClaim != nil,
                    terminalState: "buyer_cancel",
                    terminalStateTSUnixMS: terminalStateTSUnixMS,
                    deliveredOutput: .nothing
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
                try attachRelayBlindTerminal(
                    &endFrame, evidence: relayBlindEvidence, runtime: relayBlindRuntime, claim: relayBlindClaim
                )
                let issued = receiptHeader.map { _ in
                    ReceiptIssuedAudit(providerID: receiptProviderID, modelID: request.model, tokensOut: 0, ttftMs: completion.ttftMilliseconds ?? Self.elapsedMilliseconds(since: startedAt), unixTs: unixTsSeconds)
                }
                attachRelayBlindSettlementReceipt(&endFrame, state: state)
                try await sendReceiptEndFrame(endFrame, issued: issued, requestID: requestID, stream: false, tier2Session: tier2Session, sendFrame: sendFrame)
            }
            return completion
        }
        guard !state.terminalSent else {
            return completion
        }
        let ordinary = try jsonString(chatCompletionResponse(request: request, completion: completion))
        let response: String
        if let privacySealer {
            let counts = privacyCounts(completion)
            do {
                let bodyFrame = try privacySealer.seal(plaintext: ordinary, final: false)
                let finalFrame = try privacySealer.seal(
                    plaintext: privacyFinalPlaintext(
                        status: PrivacyClassConstants.finalStatusComplete,
                        prompt: counts.prompt,
                        completion: counts.completion
                    ),
                    final: true
                )
                response = try privacyResponseJSON(
                    frames: [bodyFrame, finalFrame], prompt: counts.prompt, completion: counts.completion
                )
            } catch {
                // The privacy response could not be built: the buyer never
                // receives the completion, so no receipt (R-13.6).
                state.relayBlindSettlement?.suppressReceiptAfterSendFailure()
                throw error
            }
        } else {
            response = ordinary
        }
        let seq = state.nextSeq()
        try await sendChunk(requestID: requestID, stream: false, seq: seq, data: response, state: state, tier2Session: tier2Session, sendFrame: sendFrame)
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
            runtimeSettlementEligible: modelRuntime.isSettlementReceiptEligible,
            settlementRuntimeSource: modelRuntime.settlementRuntimeSource,
            relayBlindSuppressed: relayBlindClaim != nil,
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
            try attachRelayBlindTerminal(
                &endFrame, evidence: relayBlindEvidence, runtime: relayBlindRuntime, claim: relayBlindClaim
            )
            let issued = receiptHeader.map { _ in
                ReceiptIssuedAudit(providerID: receiptProviderID, modelID: request.model, tokensOut: Int64(completion.generatedCompletionTokens), ttftMs: ttftMs, unixTs: unixTsSeconds)
            }
            attachRelayBlindSettlementReceipt(&endFrame, state: state)
            try await sendReceiptEndFrame(endFrame, issued: issued, requestID: requestID, stream: false, tier2Session: tier2Session, sendFrame: sendFrame)
        }
        return completion
    }

    /// SPEC-015 §11 audit for a relay receipt: it is issued only once the
    /// terminal frame that carries it was delivered.
    private struct ReceiptIssuedAudit {
        let providerID: String?
        let modelID: String
        let tokensOut: Int64
        let ttftMs: Int64
        let unixTs: Int64
    }

    private static func sendReceiptEndFrame(
        _ frame: sending [String: Any],
        issued: ReceiptIssuedAudit?,
        requestID: String,
        stream: Bool,
        tier2Session: Tier2ProviderSession?,
        sendFrame: @escaping SendFrame
    ) async throws {
        do {
            try await sendEndFrame(frame, requestID: requestID, stream: stream, tier2Session: tier2Session, sendFrame: sendFrame)
        } catch {
            if let issued {
                ReceiptAudit.emitOmitted(providerID: issued.providerID, requestID: requestID, reason: .writeFailed)
            }
            throw error
        }
        if let issued {
            ReceiptAudit.emitIssued(providerID: issued.providerID, requestID: requestID, modelID: issued.modelID, tokensOut: issued.tokensOut, ttftMs: issued.ttftMs, unixTs: issued.unixTs)
        }
    }

    /// What the buyer received of the generated output (SPEC-015 delivered-
    /// prefix rule). `.nothing`: no output, so a settlement receipt binds the empty
    /// prefix and a legacy receipt is omitted. `.prefix`: a cancelled stream's
    /// delivered content, with no finish reason or tool calls. `.completeSnapshot`:
    /// a normal completed stream whose accepted frames were all sent and matched
    /// the runtime's final accumulator. `.unknown`: some frames may not have
    /// reached the buyer, so no receipt is signed.
    enum DeliveredOutput: Equatable {
        case complete
        case completeSnapshot(content: String, toolCalls: [ToolCall]?, finishReason: String)
        case nothing
        case prefix(String)
        case unknown
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
        runtimeSettlementEligible: Bool,
        settlementRuntimeSource: String? = nil,
        relayBlindSuppressed: Bool,
        terminalState: String = "normal_done",
        terminalStateTSUnixMS: Int64? = nil,
        deliveredOutput: DeliveredOutput = .complete
    ) -> String? {
        // SPEC-015 v0.4.7: relay-blind execution evidence is not a SPEC-015
        // receipt, so there is no receipt omission to audit.
        if relayBlindSuppressed {
            return nil
        }
        // Mirror RouterHandler.receiptHeaderResult so every relay request
        // that yields no receipt leaves exactly one receipt_omitted row.
        guard let providerID, !providerID.isEmpty else {
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .noKeypair)
            return nil
        }
        guard let receiptBuilder else {
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .preV16Binary)
            return nil
        }
        // #1695: eligibility is explicit. A runtime that is not settlement
        // eligible (loopback, fixture) never signs, whatever its completions
        // say, unless this request's settlement metadata carries a matching
        // SPEC-015 §N.12 pool_runtime_authorization (#1690 M5).
        let poolAuthorized = !runtimeSettlementEligible && SettlementReceiptEligibility.poolAuthorizes(
            runtimeSource: settlementRuntimeSource,
            settlementMetadata: settlementMetadata,
            providerID: providerID
        )
        guard runtimeSettlementEligible || poolAuthorized else {
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .runtimeNotSettlementEligible)
            return nil
        }
        // Usage the upstream did not report is never signed (SPEC-015 §N.12).
        guard completion.settlementDisposition != .usageUnattested else {
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .runtimeNotSettlementEligible)
            return nil
        }
        // A pool-authorized loopback completion carries the runtime-level
        // `.notEligible` marker (#1695); only a replay waiter stays excluded.
        let dispositionSettles = poolAuthorized
            ? completion.settlementDisposition != .nonSettlingReplay
            : completion.settlementDisposition == .eligibleOwner
        guard dispositionSettles else {
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .nonSettlingReplay)
            return nil
        }
        // Delivery is checked after eligibility, so an ineligible runtime
        // keeps its #1695 omission reason on every cancel path.
        switch deliveredOutput {
        case .complete, .completeSnapshot, .prefix:
            break
        case .unknown:
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .constructionFailed)
            return nil
        case .nothing where settlementMetadata == nil:
            // A legacy receipt has no delivered-prefix binding.
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .preTokenCancel)
            return nil
        case .nothing:
            break
        }
        // A cancelled attempt binds only what the buyer received: no finish
        // reason and no tool calls were sent (SPEC-015 §N.5).
        let settlementContent: String
        let settlementComplete: Bool
        let settlementToolCalls: [ToolCall]?
        let settlementFinishReason: String
        switch deliveredOutput {
        case .complete:
            settlementContent = completion.content
            settlementComplete = true
            settlementToolCalls = completion.toolCalls
            settlementFinishReason = completion.finishReason
        case .completeSnapshot(let content, let toolCalls, let finishReason):
            settlementContent = content
            settlementComplete = true
            settlementToolCalls = toolCalls
            settlementFinishReason = finishReason
        case .prefix(let delivered):
            settlementContent = delivered
            settlementComplete = false
            settlementToolCalls = nil
            settlementFinishReason = ""
        case .nothing, .unknown:
            settlementContent = ""
            settlementComplete = false
            settlementToolCalls = nil
            settlementFinishReason = ""
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
                if poolAuthorized {
                    PoolLoopbackUsageGuard.schedule(
                        settlementMetadata: settlementMetadata,
                        providerID: providerID,
                        completionText: settlementContent,
                        reportedCompletionTokens: Int64(completion.generatedCompletionTokens)
                    )
                }
                let issuedAt = Int64(Date().timeIntervalSince1970 * 1000)
                return try receiptBuilder.buildSettlement(
                    providerId: providerID,
                    input: SettlementReceiptInput(
                        metadata: settlementMetadata,
                        modelHash: modelHash,
                        content: settlementContent,
                        toolCalls: settlementComplete ? settlementToolCalls : nil,
                        finishReason: settlementComplete ? settlementFinishReason : "",
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
                    outputContent: settlementContent,
                    outputToolCalls: settlementComplete ? settlementToolCalls : nil,
                    finishReason: settlementComplete ? settlementFinishReason : "",
                    ttftMs: ttftMs,
                    tokensOut: Int64(completion.generatedCompletionTokens),
                    unixTsSeconds: unixTsSeconds,
                    modelHash: resolvedModelHash
                )
            )
        } catch ReceiptBuilder.Error.missingCurrentReceiptKey {
            ReceiptAudit.emitOmitted(providerID: providerID, requestID: requestID, reason: .noKeypair)
            return nil
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

    /// SPEC-001-R005 item 3: exactly one `relay_blind_settlement_receipt` on
    /// the terminal frame of a dispatch that carried valid metadata, and never
    /// the v0.4 `receipt`. The usage signed is the usage this frame reports, so
    /// the coordinator's terminal evidence and the receipt agree. Construction
    /// failure withholds the receipt (SPEC-022 R-13.6 missing evidence).
    private static func attachRelayBlindSettlementReceipt(_ frame: inout [String: Any], state: RelayRequestState) {
        guard let attempt = state.relayBlindSettlement else { return }
        frame.removeValue(forKey: "receipt")
        let terminalState: String
        switch frame["status"] as? String {
        case "complete": terminalState = "normal_done"
        case "cancelled": terminalState = "buyer_cancel"
        default: terminalState = "provider_error"
        }
        let terminalStateUnixMS = (frame["terminal_state_ts_unix_ms"] as? Int64)
            ?? Int64(Date().timeIntervalSince1970 * 1000)
        let outputTokens = privacyTokenCount(frame["usage"] as? [String: Any], key: "completion_tokens")
        guard let receipt = attempt.receipt(
            terminalState: terminalState,
            terminalStateUnixMS: terminalStateUnixMS,
            outputTokens: Int64(outputTokens)
        ) else { return }
        frame["terminal_state_ts_unix_ms"] = terminalStateUnixMS
        frame["relay_blind_settlement_receipt"] = receipt
    }

    private static func attachRelayBlindTerminal(
        _ frame: inout [String: Any],
        evidence: RelayBlindValidationEvidence?,
        runtime: RelayBlindProviderRuntime?,
        claim: RelayBlindExecutionJournal.Claim?
    ) throws {
        guard let evidence, let runtime, let claim else { return }
        try runtime.journal.markTerminal(claim, inputTokens: evidence.inputTokens)
        frame["relay_blind_validation"] = evidence.terminalWireObject()
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
        relayBlindEvidence: RelayBlindValidationEvidence?,
        relayBlindRuntime: RelayBlindProviderRuntime?,
        relayBlindClaim: RelayBlindExecutionJournal.Claim?,
        preparedHandle: RequestHandle?,
        privacySealer: PrivacyResponseSealerBox?,
        sendFrame: @escaping SendFrame
    ) async throws -> CompletionResult {
        let created = Int(Date().timeIntervalSince1970)
        let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let buffer = BlockingChunkBuffer(capacity: 256, resumeAt: 128)
        state.setBuffer(buffer)
        let model = request.model
        let batcher = RelayStreamBatcher(
            streamInterval: streamInterval,
            deltaFrame: { delta in
                Self.sseEvent(Self.chatCompletionChunk(id: id, created: created, model: model, delta: delta, finishReason: NSNull()))
            },
            enqueueFrame: { buffer.enqueue($0) }
        )

        let consumer = Task<Int, Error> {
            while let data = buffer.next() {
                try Task.checkCancellation()
                guard !state.terminalSent else {
                    continue
                }
                let seq = state.nextSeq()
                try await sendChunk(
                    requestID: requestID,
                    stream: true,
                    seq: seq,
                    data: data,
                    state: state,
                    tier2Session: tier2Session,
                    privacySealer: privacySealer,
                    sendFrame: sendFrame
                )
            }
            return state.chunksSent
        }

        do {
            let handle: RequestHandle
            let ownsHandle: Bool
            if let preparedHandle {
                handle = preparedHandle
                ownsHandle = false
            } else {
                handle = try await modelRuntime.acquireRequestHandle(request)
                ownsHandle = true
            }
            defer {
                if ownsHandle {
                    Task { await modelRuntime.unregisterInFlight(handle.registrationID) }
                }
            }
            try await modelRuntime.pagedKVPreflight(request, with: handle)
            batcher.enqueueDelta(["role": "assistant", "content": ""])

            let streamedToolArgs = StreamedToolCallArgs()
            // T3-01: accumulate content-token deltas until streamInterval tokens,
            // then emit one combined SSE frame. Tool-call deltas flush any pending
            // content immediately and are never batched. The batcher serializes
            // the @Sendable callback's state and its enqueue order.
            let completion = try await modelRuntime.stream(request, with: handle, shouldCancel: { state.isCancelled }) { chunk in
                if case .toolCallDelta(let toolDelta) = chunk {
                    streamedToolArgs.note(toolDelta)
                }
                batcher.accept(chunk)
            }

            // Flush remaining batched content only if no tool call opened.
            // Post-open leftovers (</tool_call>, chatter) must not go on the wire.
            batcher.flushContent()

            state.setUsage(completion)
            if state.isCancelled {
                buffer.cancel()
                consumer.cancel()
                let consumerSent = try? await consumer.value
                let chunksSent = consumerSent ?? state.chunksSent
                // SPEC-015 delivered-prefix rule: the receipt may bind only
                // output the buyer received. It is issued only when every
                // frame carrying generated output was accepted and sent, and
                // it binds the content those frames carried.
                let deliveredContent = consumerSent.flatMap { batcher.deliveredContent(sent: $0) }
                // A loopback runtime reports usage for the delivered prefix
                // only (#1690 E2E-F3); native completions are unchanged.
                let cancelled = completion.cancelledPrefixUsage(deliveredContent: deliveredContent)
                if state.markTerminalSent() {
                    let counts = privacyCounts(cancelled)
                    await emitPrivacyClosing(
                        sealer: privacySealer,
                        stream: true,
                        status: PrivacyClassConstants.finalStatusCancelled,
                        promptTokens: counts.prompt,
                        completionTokens: counts.completion,
                        model: request.model,
                        requestID: requestID,
                        state: state,
                        tier2Session: tier2Session,
                        sendFrame: sendFrame
                    )
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
                        completion: cancelled,
                        ttftMs: 0,
                        unixTsSeconds: Int64(Date().timeIntervalSince1970),
                        requestID: requestID,
                        modelHashSource: modelHashSource,
                        settlementMetadata: settlementMetadata,
                        runtimeSettlementEligible: modelRuntime.isSettlementReceiptEligible,
                        settlementRuntimeSource: modelRuntime.settlementRuntimeSource,
                        relayBlindSuppressed: relayBlindClaim != nil,
                        terminalState: "buyer_cancel",
                        terminalStateTSUnixMS: terminalStateTSUnixMS,
                        deliveredOutput: deliveredContent.map { .prefix($0) } ?? .unknown
                    )
                    var endFrame: [String: Any] = [
                        "type": "inference_response_end",
                        "request_id": requestID,
                        "status": "cancelled",
                        "chunks_sent": privacySealer == nil ? chunksSent : state.chunksSent,
                        "usage": usage(cancelled),
                        "terminal_state_ts_unix_ms": terminalStateTSUnixMS,
                    ]
                    if let receiptHeader {
                        endFrame["receipt"] = receiptHeader
                    }
                    if let settlementMetadata {
                        endFrame["receipt_pending_deadline_seconds"] = settlementMetadata.pendingDeadlineSeconds
                        endFrame["late_receipt_settlement"] = "not_settled"
                    }
                    try attachRelayBlindTerminal(
                        &endFrame, evidence: relayBlindEvidence, runtime: relayBlindRuntime, claim: relayBlindClaim
                    )
                    let issued = receiptHeader.map { _ in
                        ReceiptIssuedAudit(providerID: receiptProviderID, modelID: request.model, tokensOut: Int64(cancelled.generatedCompletionTokens), ttftMs: 0, unixTs: Int64(Date().timeIntervalSince1970))
                    }
                    attachRelayBlindSettlementReceipt(&endFrame, state: state)
                    try await sendReceiptEndFrame(endFrame, issued: issued, requestID: requestID, stream: true, tier2Session: tier2Session, sendFrame: sendFrame)
                }
                return completion
            }

            // If tool calls landed in the final CompletionResult, emit any
            // concat-safe argument remainder (or the full call if nothing streamed).
            for delta in try streamedToolArgs.finalDeltas(for: completion.toolCalls) {
                batcher.enqueueDelta(["tool_calls": delta])
            }

            batcher.enqueue(sseEvent(chatCompletionChunk(
                id: id,
                created: created,
                model: request.model,
                delta: [:],
                finishReason: completion.finishReason
            )))
            batcher.enqueue(sseEvent([
                "id": id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": request.model,
                "choices": [],
                "usage": usage(completion),
            ]))
            batcher.enqueue("data: [DONE]\n\n")
            buffer.finish()

            let chunksSent = try await consumer.value
            let counts = privacyCounts(completion)
            await emitPrivacyClosing(
                sealer: privacySealer,
                stream: true,
                status: PrivacyClassConstants.finalStatusComplete,
                promptTokens: counts.prompt,
                completionTokens: counts.completion,
                model: request.model,
                requestID: requestID,
                state: state,
                tier2Session: tier2Session,
                sendFrame: sendFrame
            )
            if state.markTerminalSent() {
                let terminalStateTSUnixMS = Int64(Date().timeIntervalSince1970 * 1000)
                var endFrame: [String: Any] = [
                    "type": "inference_response_end",
                    "request_id": requestID,
                    "status": "complete",
                    "chunks_sent": privacySealer == nil ? chunksSent : state.chunksSent,
                    "usage": usage(completion),
                    "terminal_state_ts_unix_ms": terminalStateTSUnixMS,
                ]
                let modelHashSource = RouterHandler.resolveModelHashSource(
                    warmSwapEnabled: warmSwapEnabled,
                    snapshot: handle.snapshot,
                    settlementMetadata: settlementMetadata
                )
                let deliveredOutput = batcher.deliveredCompleteOutput(sent: chunksSent, completion: completion) ?? .unknown
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
                    runtimeSettlementEligible: modelRuntime.isSettlementReceiptEligible,
                    settlementRuntimeSource: modelRuntime.settlementRuntimeSource,
                    relayBlindSuppressed: relayBlindClaim != nil,
                    terminalStateTSUnixMS: terminalStateTSUnixMS,
                    deliveredOutput: deliveredOutput
                )
                if let receiptHeader {
                    endFrame["receipt"] = receiptHeader
                }
                if let settlementMetadata {
                    endFrame["receipt_pending_deadline_seconds"] = settlementMetadata.pendingDeadlineSeconds
                    endFrame["late_receipt_settlement"] = "not_settled"
                }
                try attachRelayBlindTerminal(
                    &endFrame, evidence: relayBlindEvidence, runtime: relayBlindRuntime, claim: relayBlindClaim
                )
                let issued = receiptHeader.map { _ in
                    ReceiptIssuedAudit(providerID: receiptProviderID, modelID: request.model, tokensOut: Int64(completion.generatedCompletionTokens), ttftMs: 0, unixTs: Int64(Date().timeIntervalSince1970))
                }
                attachRelayBlindSettlementReceipt(&endFrame, state: state)
                try await sendReceiptEndFrame(endFrame, issued: issued, requestID: requestID, stream: true, tier2Session: tier2Session, sendFrame: sendFrame)
            }
            return completion
        } catch {
            buffer.cancel()
            consumer.cancel()
            if error is CancellationError {
                let chunksSent = (try? await consumer.value) ?? state.chunksSent
                if state.markTerminalSent() {
                    await emitPrivacyClosing(
                        sealer: privacySealer,
                        stream: true,
                        status: PrivacyClassConstants.finalStatusCancelled,
                        promptTokens: privacyTokenCount(state.usage, key: "prompt_tokens"),
                        completionTokens: privacyTokenCount(state.usage, key: "completion_tokens"),
                        model: request.model,
                        requestID: requestID,
                        state: state,
                        tier2Session: tier2Session,
                        sendFrame: sendFrame
                    )
                    var endFrame: [String: Any] = [
                        "type": "inference_response_end",
                        "request_id": requestID,
                        "status": "cancelled",
                        "chunks_sent": privacySealer == nil ? chunksSent : state.chunksSent,
                        "usage": state.usage ?? zeroUsage(),
                    ]
                    try? attachRelayBlindTerminal(
                        &endFrame, evidence: relayBlindEvidence, runtime: relayBlindRuntime, claim: relayBlindClaim
                    )
                    addSettlementTerminalMetadata(&endFrame, settlementMetadata: settlementMetadata)
                    attachRelayBlindSettlementReceipt(&endFrame, state: state)
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
        // SPEC-001 FR-27 / SPEC-038 lifecycle overlay: continuous-batching
        // queue pressure is refused before admission, so no inference ran and
        // nothing reached the buyer. `error_queue_full` is the one status
        // SPEC-002 FR-P14.1 re-routes; `error_internal` would be a
        // non-rerouted 502. Post-token delivery backpressure is deliberately
        // absent: it stays `error_internal`.
        case "continuous_batching_stream_backpressure", "continuous_batching_queue_wait_timeout":
            status = "error_queue_full"
            // SPEC-038 v0.2.4: the wire status collapses both codes; the
            // provider log keeps which one it was.
            try? FileHandle.standardError.write(contentsOf: Data(
                "event=batching_relay_queue_pressure status=error_queue_full code=\(error.code) request_id=\(requestID)\n".utf8
            ))
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
        state: RelayRequestState,
        tier2Session: Tier2ProviderSession?,
        privacySealer: PrivacyResponseSealerBox? = nil,
        sendFrame: @escaping SendFrame
    ) async throws {
        do {
            let wire: String
            if let privacySealer {
                let frame = try privacySealer.seal(plaintext: data, final: false)
                wire = try privacyFrameSSE(frame)
            } else {
                wire = data
            }
            // SPEC-015 §N.13: the receipt digests exactly the `data` bytes sent. A
            // chunk that loses the race with the terminal receipt is not sent.
            if let attempt = state.relayBlindSettlement, !attempt.recordEmitted(wire) {
                return
            }
            if let tier2Session {
                let sealStart = clockMonotonicMicros()
                let sealed = try tier2Session.sealResponseChunk(requestID: requestID, stream: stream, seq: seq, plaintext: wire)
                EgressPerfTraceKey.current?.recordSeal(durationMicros: clockMonotonicMicros() &- sealStart)
                try await sendFrame(sealed)
                return
            }
            try await sendFrame([
                "type": "inference_response_chunk",
                "request_id": requestID,
                "seq": seq,
                "data": wire,
            ])
        } catch {
            // A chunk that failed to seal, serialize, or send leaves the
            // emitted body short of what the attempt produced (or the digest
            // holding bytes the coordinator never received), so the receipt is
            // withheld for good (R-13.6 missing evidence).
            state.relayBlindSettlement?.suppressReceiptAfterSendFailure()
            throw error
        }
    }

    private static func sendValidationFrame(
        _ evidence: RelayBlindValidationEvidence,
        requestID: String,
        stream: Bool,
        tier2Session: Tier2ProviderSession?,
        sendFrame: @escaping SendFrame
    ) async throws {
        let frame: [String: Any] = [
            "type": "inference_response_validation",
            "request_id": requestID,
            "relay_blind_validation": evidence.wireObject,
        ]
        if let tier2Session {
            try await sendFrame(tier2Session.sealResponseValidation(
                requestID: requestID, stream: stream, payload: frame
            ))
        } else {
            try await sendFrame(frame)
        }
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

    /// Wire usage for a completion. Usage the upstream did not report is
    /// never sent as token counts: a `.usageUnattested` completion carries only
    /// placeholder or display-only counts, so its billing fields are omitted
    /// and the coordinator falls back to its own byte estimate.
    static func usage(_ completion: CompletionResult) -> [String: Any] {
        guard completion.settlementDisposition != .usageUnattested else {
            return ["macprovider_model_hash_observed": completion.modelHashObserved ?? NSNull()]
        }
        return [
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

    private enum PrivacyMarker: Equatable {
        case absent
        case value(String)
        case invalid
    }

    private enum PrivacyPath: Equatable {
        case ordinary
        case privacy
        case downgrade
    }

    /// SPEC-049-R001 leaves ordinary traffic unchanged when privacy mode is on.
    /// SPEC-049-R012 binds the marker only for relay-blind dispatch: privacy mode
    /// rejects a relay-blind request that lacks `operator_constrained_beta_v1`
    /// on both the request and the dispatch context, and a provider that is not
    /// in privacy mode rejects a relay-blind request that carries the marker.
    /// A marker on a non-envelope is `privacy_class_downgrade_rejected` as well.
    private static func privacyDispatchPath(
        mode: Bool,
        request: PrivacyMarker,
        context: PrivacyMarker,
        relayBlind: Bool
    ) -> PrivacyPath {
        let agreed = PrivacyMarker.value(PrivacyClassConstants.v1)
        if !relayBlind {
            return request == .absent ? .ordinary : .downgrade
        }
        if mode {
            return request == agreed && context == agreed ? .privacy : .downgrade
        }
        return request == .absent && context == .absent ? .ordinary : .downgrade
    }

    private static func privacyMarker(_ value: Any?, present: Bool) -> PrivacyMarker {
        guard present else { return .absent }
        guard let value = value as? String else { return .invalid }
        return .value(value)
    }

    private static func privacyCounts(_ completion: CompletionResult) -> (prompt: Int, completion: Int) {
        (max(0, completion.promptTokens), max(0, completion.completionTokens))
    }

    private static func privacyTokenCount(_ usage: [String: Any]?, key: String) -> Int {
        if let value = usage?[key] as? Int { return max(0, value) }
        if let value = usage?[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return max(0, value.intValue)
        }
        return 0
    }

    /// Stream: final frame, then the clear usage chunk and clear `[DONE]`.
    /// Non-stream cancel/error: one `privacy_response` whose only frame is the
    /// final frame, plus clear usage. A failed seal still lets the caller send
    /// the bounded end frame.
    private static func emitPrivacyClosing(
        sealer: PrivacyResponseSealerBox?,
        stream: Bool,
        status: String,
        promptTokens: Int,
        completionTokens: Int,
        model: String,
        requestID: String,
        state: RelayRequestState,
        tier2Session: Tier2ProviderSession?,
        sendFrame: @escaping SendFrame
    ) async {
        guard let sealer, !sealer.hasEmittedFinal else { return }
        let prompt = max(0, promptTokens)
        let completion = max(0, completionTokens)
        do {
            let finalFrame = try sealer.seal(
                plaintext: privacyFinalPlaintext(status: status, prompt: prompt, completion: completion),
                final: true
            )
            if stream {
                try await sendCountedChunk(
                    requestID: requestID, stream: true, state: state,
                    data: try privacyFrameSSE(finalFrame), tier2Session: tier2Session, sendFrame: sendFrame
                )
                try await sendCountedChunk(
                    requestID: requestID, stream: true, state: state,
                    data: privacyClearUsageSSE(model: model, prompt: prompt, completion: completion),
                    tier2Session: tier2Session, sendFrame: sendFrame
                )
                try await sendCountedChunk(
                    requestID: requestID, stream: true, state: state,
                    data: "data: [DONE]\n\n", tier2Session: tier2Session, sendFrame: sendFrame
                )
            } else {
                try await sendCountedChunk(
                    requestID: requestID, stream: false, state: state,
                    data: try privacyResponseJSON(frames: [finalFrame], prompt: prompt, completion: completion),
                    tier2Session: tier2Session, sendFrame: sendFrame
                )
            }
        } catch {
            // A closing frame that failed to seal, serialize, or send leaves
            // the buyer without an authenticated final frame: no receipt.
            state.relayBlindSettlement?.suppressReceiptAfterSendFailure()
            return
        }
    }

    private static func sendCountedChunk(
        requestID: String,
        stream: Bool,
        state: RelayRequestState,
        data: String,
        tier2Session: Tier2ProviderSession?,
        sendFrame: @escaping SendFrame
    ) async throws {
        let seq = state.nextSeq()
        try await sendChunk(
            requestID: requestID, stream: stream, seq: seq, data: data,
            state: state, tier2Session: tier2Session, sendFrame: sendFrame
        )
    }

    private static func privacyFinalPlaintext(status: String, prompt: Int, completion: Int) -> String {
        "{\"version\":\(privacyJSONString(PrivacyClassConstants.finalVersion)),\"status\":\(privacyJSONString(status)),\"prompt_tokens\":\(prompt),\"completion_tokens\":\(completion)}"
    }

    private static func privacyFrameSSE(_ frame: [String: Any]) throws -> String {
        "data: \(try privacyFrameWire(frame))\n\n"
    }

    private static func privacyFrameWire(_ frame: [String: Any]) throws -> String {
        let final: Bool
        if let value = frame["final"] as? Bool {
            final = value
        } else if let value = frame["final"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            final = value.boolValue
        } else {
            throw PrivacyClassError.invalidMaterial
        }
        guard let object = frame["object"] as? String,
              let version = frame["version"] as? String,
              let seq = privacyJSONInteger(frame["seq"]),
              let ciphertext = frame["ciphertext"] as? String else {
            throw PrivacyClassError.invalidMaterial
        }
        return "{\"object\":\(privacyJSONString(object)),\"version\":\(privacyJSONString(version)),\"seq\":\(seq),\"final\":\(final ? "true" : "false"),\"ciphertext\":\(privacyJSONString(ciphertext))}"
    }

    private static func privacyResponseJSON(frames: [[String: Any]], prompt: Int, completion: Int) throws -> String {
        let encoded = try frames.map { try privacyFrameWire($0) }.joined(separator: ",")
        let total = prompt + completion
        return "{\"object\":\(privacyJSONString(PrivacyClassConstants.responseObject)),\"version\":\(privacyJSONString(PrivacyClassConstants.responseVersion)),\"frames\":[\(encoded)],\"usage\":{\"prompt_tokens\":\(prompt),\"completion_tokens\":\(completion),\"total_tokens\":\(total)}}"
    }

    private static func privacyClearUsageSSE(model: String, prompt: Int, completion: Int) -> String {
        let total = prompt + completion
        return "data: {\"object\":\"chat.completion.chunk\",\"model\":\(privacyJSONString(model)),\"choices\":[],\"usage\":{\"prompt_tokens\":\(prompt),\"completion_tokens\":\(completion),\"total_tokens\":\(total)}}\n\n"
    }

    private static func privacyJSONInteger(_ value: Any?) -> Int? {
        if let value = value as? UInt64 { return Int(exactly: value) }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.intValue
        }
        return nil
    }

    private static func privacyJSONString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x5C: out += "\\\\"
            case 0x22: out += "\\\""
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
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

/// Shares one `PrivacyResponseSealer` across the stream consumer and the
/// parent task. `finalEmitted` flips only after a successful final seal.
private final class PrivacyResponseSealerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sealer: PrivacyResponseSealer
    private var finalEmitted = false

    init(_ sealer: PrivacyResponseSealer) {
        self.sealer = sealer
    }

    var hasEmittedFinal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finalEmitted
    }

    func seal(plaintext: String, final: Bool) throws -> [String: Any] {
        var data = Data(plaintext.utf8)
        return try seal(&data, final: final)
    }

    func seal(_ data: inout Data, final: Bool) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if final, finalEmitted { throw PrivacyClassError.invalidMaterial }
        let frame = try sealer.seal(&data, final: final)
        if final { finalEmitted = true }
        return frame
    }
}

/// SPEC-015 §N.13 state for one relay-blind attempt that carried valid
/// SPEC-001-R005 metadata: the pinned model hash, the validated input tokens,
/// and a running SHA-256 of the emitted chunk `data` bytes. It issues at most
/// one receipt; once issued, no further chunk may be emitted.
final class RelayBlindSettlementAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private let metadata: RelayBlindSettlementMetadata
    private let context: RelayBlindDispatchContext
    private let privacyClass: Bool
    private let builder: ReceiptBuilder
    private var modelHash: String?
    private var inputTokens: Int64 = 0
    private var usageValidated = false
    private var responseHasher = SHA256()
    private var responseBytes: Int64 = 0
    private var issued = false
    private var sendFailed = false

    init(metadata: RelayBlindSettlementMetadata, context: RelayBlindDispatchContext, privacyClass: Bool, builder: ReceiptBuilder) {
        self.metadata = metadata
        self.context = context
        self.privacyClass = privacyClass
        self.builder = builder
    }

    /// Records the handle relayBlindPrepare pinned. A model id that does not
    /// resolve to that handle leaves no hash, so no receipt is signed.
    func pin(modelHash: String?, preparedModelID: String?, aliases: [String]) {
        let resolves = metadata.modelID == preparedModelID || aliases.contains(metadata.modelID)
        lock.lock()
        defer { lock.unlock() }
        self.modelHash = resolves ? modelHash : nil
    }

    /// The `input_tokens` of the SPEC-041 `validated` evidence. Until it is
    /// recorded, no receipt is signed.
    func validated(inputTokens: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.inputTokens = Int64(inputTokens)
        usageValidated = true
    }

    /// False once the receipt was issued: the caller must not send `data`.
    func recordEmitted(_ data: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !issued else { return false }
        let bytes = Data(data.utf8)
        responseHasher.update(data: bytes)
        responseBytes += Int64(bytes.count)
        return true
    }

    /// A chunk whose `data` was recorded failed to seal or send: the digest
    /// can no longer match what the coordinator received, so no receipt is
    /// ever issued for this attempt.
    func suppressReceiptAfterSendFailure() {
        lock.lock()
        defer { lock.unlock() }
        sendFailed = true
    }

    func receipt(terminalState: String, terminalStateUnixMS: Int64, outputTokens: Int64) -> String? {
        lock.lock()
        guard !issued else {
            lock.unlock()
            return nil
        }
        issued = true
        guard !sendFailed else {
            lock.unlock()
            return nil
        }
        let digest = responseHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let bytes = responseBytes
        let modelHash = modelHash
        let inputTokens = inputTokens
        let usageValidated = usageValidated
        lock.unlock()
        // SPEC-001-R005 item 3: without a pinned hash or validated usage the
        // receipt is withheld (SPEC-022 R-13.6 missing evidence).
        guard usageValidated,
              let modelHash,
              let inputBound = Int64(exactly: context.inputTokenUpperBound),
              let outputBound = Int64(exactly: context.maxOutputTokens) else {
            return nil
        }
        return try? builder.buildRelayBlindSettlement(
            providerId: metadata.providerID,
            input: RelayBlindSettlementReceiptInput(
                metadata: metadata,
                executionAuthDigest: context.executionAuthDigest,
                providerBindingDigest: context.providerBindingDigest,
                kid: context.kid,
                inputTokenUpperBound: inputBound,
                maxOutputTokens: outputBound,
                privacyClass: privacyClass,
                modelHash: modelHash,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                responseBodyBytes: bytes,
                responseBodySHA256: digest,
                terminalState: terminalState,
                terminalStateUnixMS: terminalStateUnixMS,
                issuedAtUnixMS: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )
    }
}

private final class RelayRequestState: @unchecked Sendable {
    let relayBlindSettlement: RelayBlindSettlementAttempt?
    private let lock = NSLock()
    private var buffer: BlockingChunkBuffer?
    private var terminal = false
    private var sentChunks = 0
    private var cancelled = false
    private var currentUsage: [String: Any]?

    init(relayBlindSettlement: RelayBlindSettlementAttempt? = nil) {
        self.relayBlindSettlement = relayBlindSettlement
    }

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

    /// Usage the upstream did not report is never stored as token counts, so a
    /// cancellation fallback frame cannot send it as billing numbers.
    func setUsage(_ completion: CompletionResult) {
        lock.lock()
        guard completion.settlementDisposition != .usageUnattested else {
            currentUsage = [:]
            lock.unlock()
            return
        }
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

/// T3-01 batching state for one streamed relay request. The runtime's chunk
/// callback is `@Sendable`, so every transition, and the enqueue it causes,
/// happens under one lock: concurrent delivery cannot interleave or corrupt
/// frames. It also counts accepted and dropped frames, so a buyer-cancel
/// receipt is issued only when all generated output reached the buyer.
final class RelayStreamBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let streamInterval: Int
    private let deltaFrame: ([String: Any]) -> String
    private let enqueueFrame: (String) -> Bool
    private var pendingContent = ""
    private var pendingCount = 0
    private var emittedToolCall = false
    private var suppressedPostToolContent = false
    private var enqueuedContent = ""
    private var accepted = 0
    private var dropped = 0

    init(streamInterval: Int, deltaFrame: @escaping ([String: Any]) -> String, enqueueFrame: @escaping (String) -> Bool) {
        self.streamInterval = max(1, streamInterval)
        self.deltaFrame = deltaFrame
        self.enqueueFrame = enqueueFrame
    }

    func enqueue(_ frame: String) {
        lock.lock()
        defer { lock.unlock() }
        enqueueLocked(frame)
    }

    func enqueueDelta(_ delta: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        enqueueLocked(deltaFrame(delta))
    }

    func accept(_ chunk: StreamChunk) {
        lock.lock()
        defer { lock.unlock() }
        switch chunk {
        case .content(let text):
            // Leftover </tool_call> or chatter after tool_calls opened must
            // not become a content delta (the coordinator would kill the
            // stream as "fell back to content").
            guard !emittedToolCall else {
                if !text.isEmpty {
                    suppressedPostToolContent = true
                }
                return
            }
            pendingContent += text
            pendingCount += 1
            if pendingCount >= streamInterval {
                flushContentLocked()
            }
        case .toolCallDelta(let toolDelta):
            flushContentLocked()
            emittedToolCall = true
            enqueueLocked(deltaFrame(["tool_calls": [toolDelta.openAIDeltaDict()]]))
        }
    }

    /// Flushes batched content unless a tool call opened.
    func flushContent() {
        lock.lock()
        defer { lock.unlock() }
        guard !emittedToolCall else { return }
        flushContentLocked()
    }

    /// True when no frame was dropped and every accepted frame was sent.
    func everyFrameDelivered(sent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return dropped == 0 && sent >= accepted
    }

    /// The content the buyer received, when every accepted frame was sent
    /// and no tool call opened; nil otherwise.
    func deliveredContent(sent: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard dropped == 0, sent >= accepted, !emittedToolCall else { return nil }
        return enqueuedContent
    }

    /// The completed output the buyer received, when every accepted frame was
    /// sent and the runtime's final completion is compatible with that stream.
    func deliveredCompleteOutput(sent: Int, completion: CompletionResult) -> InferenceRelay.DeliveredOutput? {
        lock.lock()
        defer { lock.unlock() }
        guard dropped == 0, sent >= accepted, !suppressedPostToolContent else { return nil }
        if emittedToolCall {
            guard completion.toolCalls?.isEmpty == false,
                  completion.content.utf8.elementsEqual(enqueuedContent.utf8)
            else { return nil }
        } else {
            guard completion.content.utf8.elementsEqual(enqueuedContent.utf8) else { return nil }
        }
        return .completeSnapshot(
            content: enqueuedContent,
            toolCalls: completion.toolCalls,
            finishReason: completion.finishReason
        )
    }

    private func flushContentLocked() {
        guard !pendingContent.isEmpty else { return }
        if enqueueLocked(deltaFrame(["content": pendingContent])) {
            enqueuedContent += pendingContent
        }
        pendingContent = ""
        pendingCount = 0
    }

    @discardableResult
    private func enqueueLocked(_ frame: String) -> Bool {
        if enqueueFrame(frame) {
            accepted += 1
            return true
        }
        dropped += 1
        return false
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
