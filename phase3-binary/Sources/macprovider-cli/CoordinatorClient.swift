import Foundation
import MacProviderCore
import Darwin

protocol ProviderWebSocketTask: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func sendPing() async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: ProviderWebSocketTask {}

extension URLSessionWebSocketTask {
    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

protocol ProviderSleepAssertion: AnyObject, Sendable {
    func stop()
}

final class CaffeinateSleepAssertion: ProviderSleepAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    private init(process: Process) {
        self.process = process
    }

    static func start() -> CaffeinateSleepAssertion? {
        let path = "/usr/bin/caffeinate"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-dimsu", "-w", String(getpid())]
        do {
            try process.run()
            return CaffeinateSleepAssertion(process: process)
        } catch {
            CoordinatorClient.keepaliveDebug("sleep_assertion_start_failed error=\(error)")
            return nil
        }
    }

    func stop() {
        lock.lock()
        let running = process
        process = nil
        lock.unlock()
        running?.terminate()
    }
}

actor CoordinatorClient {
    static let binaryVersion = "1.3.0"
    private static let keepaliveDebugEnabled = ProcessInfo.processInfo.environment["MACPROVIDER_KEEPALIVE_DEBUG"] == "1"

    private let coordinatorURL: URL
    private let providerStatus: ProviderStatus
    private let drainTimeoutSeconds: Int
    private let providerID: String
    private let endpointURL: String?
    private let wsTunneledMode: Bool
    private let modelRuntime: ModelRuntime
    private let loadedModelID: String?
    private let maxBodyBytes: Int
    private let maxActiveRequests: Int
    private let supportedModels: [String]?
    private let publishesSupportedModels: Bool
    private let warmSwapEnabled: Bool
    private let reconnectGraceNanoseconds: UInt64
    private let connectAndRunOverride: (() async throws -> Void)?
    private let attestationGenerator: Tier2AttestationTokenGenerating
    private let webSocketFactory: (URL) -> ProviderWebSocketTask
    private let sleepAssertionFactory: @Sendable () -> ProviderSleepAssertion?
    private var inferenceRelay: InferenceRelay?
    private var tier2Session: Tier2ProviderSession?
    private var webSocket: ProviderWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var swapHeartbeatTask: Task<Void, Never>?
    private var sleepAssertion: ProviderSleepAssertion?
    private let sendOverride: (([String: Any]) async throws -> Void)?

    init?(
        config: AppConfig,
        modelRuntime: ModelRuntime,
        providerStatus: ProviderStatus,
        sendOverride: (([String: Any]) async throws -> Void)? = nil,
        reconnectGraceNanoseconds: UInt64 = 10 * 1_000_000_000,
        attestationGenerator: Tier2AttestationTokenGenerating = ManagedDeviceAttestationGenerator(),
        webSocketFactory: @escaping @Sendable (URL) -> ProviderWebSocketTask = { URLSession.shared.webSocketTask(with: $0) },
        sleepAssertionFactory: @escaping @Sendable () -> ProviderSleepAssertion? = { CaffeinateSleepAssertion.start() },
        connectAndRunOverride: (() async throws -> Void)? = nil
    ) {
        guard let rawURL = config.coordinatorURL, let url = URL(string: rawURL) else {
            return nil
        }
        self.coordinatorURL = url
        self.providerStatus = providerStatus
        self.drainTimeoutSeconds = config.drainTimeoutSeconds
        // SPEC-001 v1.1.2 / SPEC-002 v1.0.4 F-2: provider_id is the operator-issued
        // stable identifier matching coordinator's config.providers[] map. If unset,
        // we fall back to a per-instance UUID (dev/test only — production coordinators
        // will reject with close code 4002 unknown_provider_id).
        self.providerID = config.providerID ?? UUID().uuidString
        self.endpointURL = config.endpointURL?.isEmpty == false ? config.endpointURL : nil
        self.wsTunneledMode = self.endpointURL == nil && (config.wsTunneledMode ?? true)
        self.modelRuntime = modelRuntime
        self.loadedModelID = config.model
        self.maxBodyBytes = config.maxRequestBodyBytes
        self.maxActiveRequests = 1
        self.supportedModels = config.supportedModels
        self.publishesSupportedModels = config.publishesSupportedModels
        self.warmSwapEnabled = config.enableWarmSwap
        self.reconnectGraceNanoseconds = reconnectGraceNanoseconds
        self.attestationGenerator = attestationGenerator
        self.webSocketFactory = webSocketFactory
        self.sleepAssertionFactory = sleepAssertionFactory
        self.connectAndRunOverride = connectAndRunOverride
        self.sendOverride = sendOverride
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
        if warmSwapEnabled {
            swapHeartbeatTask = Task { [weak self] in
                await self?.consumeSwapSignals()
            }
        }
    }

    func stop() async {
        runTask?.cancel()
        heartbeatTask?.cancel()
        swapHeartbeatTask?.cancel()
        sleepAssertion?.stop()
        sleepAssertion = nil
        await inferenceRelay?.cancelAllAndClear()
        inferenceRelay = nil
        tier2Session = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        await providerStatus.setCoordinatorSession(connected: false)
        runTask = nil
        heartbeatTask = nil
        swapHeartbeatTask = nil
        webSocket = nil
    }

    private func consumeSwapSignals() async {
        let stream = await modelRuntime.swapSignals()
        for await signal in stream {
            if Task.isCancelled {
                return
            }
            switch signal.outcome {
            case .loadFinished:
                continue
            case .completed:
                do {
                    try await sendHeartbeat()
                } catch {
                    Self.keepaliveDebug("warm_swap_heartbeat_send_error error=\(error)")
                }
            case let .failed(reason):
                Self.keepaliveDebug("coordinator.warmSwap.swapFailed reason=\(reason)")
            }
        }
    }

    private func runReconnectLoop() async {
        var backoffSeconds: UInt64 = 1
        var failedAttempts = 0
        while !Task.isCancelled {
            do {
                try await connectAndRunOnce()
                await cleanupConnection()
                backoffSeconds = 1
                failedAttempts = 0
            } catch is CancellationError {
                await cleanupConnection()
                return
            } catch is CoordinatorDrainComplete {
                // Coordinator asked us to drain (likely it is restarting).
                // We acknowledged with drain_status; the WS is already closed.
                // Wait a grace period so the coordinator has time to come back
                // before we try to reconnect, then loop.
                await cleanupConnection()
                print("coordinator reconnect attempt 1 scheduled after drain")
                try? await Task.sleep(nanoseconds: reconnectGraceNanoseconds)
                backoffSeconds = 1
                failedAttempts = 0
            } catch {
                await cleanupConnection()
                failedAttempts += 1
                if failedAttempts >= 3 {
                    print("WARN coordinator reconnect failed attempt_count=\(failedAttempts) last_error=\(error)")
                }
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(backoffSeconds * 2, 60)
            }
        }
    }

    private func connectAndRunOnce() async throws {
        if let connectAndRunOverride {
            try await connectAndRunOverride()
            return
        }
        try await connectAndRun()
    }

    func connectAndRunOnceForTest() async throws {
        try await connectAndRunOnce()
    }

    private func connectAndRun() async throws {
        if wsTunneledMode {
            try await connectAndRunTier2(socket: openWebSocket())
        } else {
            try await connectAndRunLegacy(socket: openWebSocket())
        }
    }

    private func openWebSocket() -> ProviderWebSocketTask {
        let socket = webSocketFactory(coordinatorURL)
        webSocket = socket
        socket.resume()
        Self.keepaliveDebug("ws_resume url=\(Self.redactedURL(coordinatorURL))")
        return socket
    }

    private func connectAndRunTier2(socket: ProviderWebSocketTask) async throws {
        let authAttempt = Tier2AuthAttempt()
        try await send(await authInitialMessage(attempt: authAttempt))
        let challenge: [String: Any]
        do {
            challenge = try await receiveAuthChallenge(from: socket)
        } catch { throw error }
        let session = try makeTier2Session(attempt: authAttempt, challenge: challenge)
        try await send(try await authProofMessage(challenge: challenge, attempt: authAttempt))
        let response = try await receiveAuthResponse(from: socket)
        try await acceptAuthResponse(response, session: session)
        tier2Session = session
        inferenceRelay = InferenceRelay(
            modelRuntime: modelRuntime,
            providerStatus: providerStatus,
            loadedModelID: loadedModelID,
            warmSwapEnabled: warmSwapEnabled,
            maxActiveRequests: maxActiveRequests,
            maxBodyBytes: maxBodyBytes,
            tier2Session: session,
            sendFrame: { payload in
                try await Self.send(payload, to: socket)
            }
        )
        try await receiveLoop(socket)
    }

    private func connectAndRunLegacy(socket: ProviderWebSocketTask) async throws {
        tier2Session = nil
        if wsTunneledMode {
            inferenceRelay = InferenceRelay(
                modelRuntime: modelRuntime,
                providerStatus: providerStatus,
                loadedModelID: loadedModelID,
                warmSwapEnabled: warmSwapEnabled,
                maxActiveRequests: maxActiveRequests,
                maxBodyBytes: maxBodyBytes,
                sendFrame: { payload in
                    try await Self.send(payload, to: socket)
                }
            )
        } else {
            inferenceRelay = nil
        }
        try await send(await helloMessage())
        try await receiveLoop(socket)
    }

    private func receiveLoop(_ socket: ProviderWebSocketTask) async throws {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                Self.keepaliveDebug("ws_receive_error error=\(error)")
                throw error
            }
            try await handle(message)
        }
    }

    private func cleanupConnection() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        sleepAssertion?.stop()
        sleepAssertion = nil
        await inferenceRelay?.cancelAllAndClear()
        inferenceRelay = nil
        tier2Session = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        await providerStatus.setCoordinatorSession(connected: false)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async throws {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(decoding: data, as: UTF8.self)
        @unknown default:
            try await sendNAK(inReplyTo: "unknown", code: "unsupported_frame", message: "Unsupported WebSocket frame")
            return
        }

        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any],
              let type = dict["type"] as? String
        else {
            try await sendNAK(inReplyTo: "unknown", code: "invalid_json", message: "Coordinator message must be a JSON object")
            return
        }
        Self.keepaliveDebug("ws_recv type=\(type) bytes=\(text.utf8.count)")

        switch type {
        case "hello_ack":
            try await acceptCoordinatorSession(dict, reason: "coordinator hello_ack received")
        case "preflight":
            try await handlePreflight(dict)
        case "inference_request":
            guard wsTunneledMode, let inferenceRelay else {
                try await sendNAK(
                    inReplyTo: type,
                    code: "unknown_message_type",
                    message: "Unrecognized message type: '\(type)'"
                )
                return
            }
            try await inferenceRelay.handleInferenceRequest(dict)
        case "cancel_request":
            guard wsTunneledMode, let inferenceRelay else {
                try await sendNAK(
                    inReplyTo: type,
                    code: "unknown_message_type",
                    message: "Unrecognized message type: '\(type)'"
                )
                return
            }
            try await inferenceRelay.handleCancelRequest(dict)
        case "drain":
            // SPEC-001 v1.1.3: coordinator drain stops registration only.
            // The local buyer HTTP server keeps serving. Throwing
            // CoordinatorDrainComplete unwinds connectAndRun and signals
            // the reconnect loop to wait a grace period before reconnecting.
            try await drainFromCoordinator(reason: "coordinator drain requested")
            throw CoordinatorDrainComplete()
        case "warm_up":
            try await sendStateUpdate(state: .degraded, reason: "coordinator warm_up requested")
            try await sendStateUpdate(state: .ready, reason: "warm_up complete")
        default:
            try await sendNAK(
                inReplyTo: type,
                code: "unknown_message_type",
                message: "Unrecognized message type: '\(type)'"
            )
        }
    }

    func handleCoordinatorPayloadForTest(_ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await handle(.string(String(decoding: data, as: UTF8.self)))
    }

    func sendHeartbeatForTest() async throws {
        try await sendHeartbeat()
    }

    private func receiveAuthChallenge(from socket: ProviderWebSocketTask) async throws -> [String: Any] {
        let challenge = try await Self.receiveJSONObject(from: socket)
        guard challenge["type"] as? String == "auth_challenge",
              Self.intValue(challenge["version"]) == 2
        else {
            throw CoordinatorAuthError.invalidMessage("Expected auth_challenge v2")
        }
        return challenge
    }

    private func receiveAuthResponse(from socket: ProviderWebSocketTask) async throws -> [String: Any] {
        let response = try await Self.receiveJSONObject(from: socket)
        guard response["type"] as? String == "auth_response",
              Self.intValue(response["version"]) == 2
        else {
            throw CoordinatorAuthError.invalidMessage("Expected auth_response v2")
        }
        return response
    }

    private func makeTier2Session(attempt: Tier2AuthAttempt, challenge: [String: Any]) throws -> Tier2ProviderSession {
        guard let assignedID = challenge["assigned_id"] as? String,
              let coordinatorPublicKey = challenge["coordinator_ecdh_public_key"] as? String
        else {
            throw CoordinatorAuthError.invalidMessage("auth_challenge missing assigned_id or coordinator_ecdh_public_key")
        }
        let selectedAEAD = (challenge["selected_aead_suite"] as? String) ?? (challenge["selected_aead"] as? String) ?? ""
        guard !selectedAEAD.isEmpty else {
            throw CoordinatorAuthError.invalidMessage("auth_challenge missing selected_aead_suite")
        }
        return try Tier2ProviderSession(
            attempt: attempt,
            providerID: providerID,
            assignedID: assignedID,
            coordinatorPublicKeyBase64URL: coordinatorPublicKey,
            selectedAEAD: selectedAEAD,
            expectedKeyID: challenge["key_id"] as? String
        )
    }

    func authProofMessage(challenge: [String: Any], attempt: Tier2AuthAttempt) async throws -> [String: Any] {
        guard let attemptID = challenge["auth_attempt_id"] as? String, !attemptID.isEmpty else {
            throw CoordinatorAuthError.invalidMessage("auth_challenge missing auth_attempt_id")
        }
        let snapshot = await providerStatus.snapshot()
        let token = await attestationGenerator.makeAttestationToken(
            challengeBase64URL: challenge["attestation_challenge"] as? String,
            authAttemptID: attemptID,
            providerID: providerID,
            binaryVersion: Self.binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: attempt.publicKeyBase64URL
        )
        var proof: [String: Any] = [
            "type": "auth_request",
            "version": 2,
            "stage": "proof",
            "auth_attempt_id": attemptID,
            "provider_id": providerID,
        ]
        proof["attestation_token"] = token ?? NSNull()
        return proof
    }

    private func acceptAuthResponse(_ response: [String: Any], session: Tier2ProviderSession) async throws {
        guard response["status"] as? String == "accepted" else {
            let error = response["error"] as? [String: Any]
            throw CoordinatorAuthError.rejected(
                code: error?["code"] as? String ?? "auth_rejected",
                message: error?["message"] as? String ?? "Coordinator rejected auth_response"
            )
        }
        guard let tier2 = response["tier2_session"] as? [String: Any],
              let encryptedLeg = tier2["encrypted_leg"] as? [String: Any],
              encryptedLeg["enabled"] as? Bool == true,
              encryptedLeg["alg"] as? String == session.selectedAEAD,
              encryptedLeg["kid"] as? String == session.keyID
        else {
            throw CoordinatorAuthError.invalidMessage("auth_response missing matching encrypted_leg session")
        }
        try await acceptCoordinatorSession(response, reason: "coordinator auth_response accepted")
    }

    private func acceptCoordinatorSession(_ payload: [String: Any], reason: String) async throws {
        let interval = max(Self.intValue(payload["heartbeat_interval_s"]) ?? 30, 1)
        await providerStatus.setCoordinatorSession(
            connected: true,
            assignedID: payload["assigned_id"] as? String,
            tier: payload["tier"] as? String,
            recommendedBinaryVersion: payload["recommended_binary_version"] as? String
        )
        if let tier = payload["tier"] as? String {
            print("Coordinator tier: \(tier)")
        }
        if let recommended = payload["recommended_binary_version"] as? String,
           Self.compareSemver(Self.binaryVersion, recommended) == .orderedAscending
        {
            print("A newer version is available (v\(recommended)). Run 'macprovider-cli update' to upgrade.")
        }
        sleepAssertion?.stop()
        sleepAssertion = sleepAssertionFactory()
        startHeartbeat(intervalSeconds: interval)
        try await sendStateUpdate(state: nil, reason: reason)
    }

    private func startHeartbeat(intervalSeconds: Int) {
        heartbeatTask?.cancel()
        Self.keepaliveDebug("heartbeat_start interval_s=\(intervalSeconds)")
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                if Task.isCancelled {
                    return
                }
                do {
                    try await self?.sendWebSocketPing()
                    try await self?.sendHeartbeat()
                } catch {
                    Self.keepaliveDebug("keepalive_send_error error=\(error)")
                    await self?.closeWebSocketAfterKeepaliveFailure()
                    return
                }
            }
        }
    }

    private func sendWebSocketPing() async throws {
        guard let webSocket else { throw CancellationError() }
        try await webSocket.sendPing()
        Self.keepaliveDebug("ws_ping")
    }

    private func closeWebSocketAfterKeepaliveFailure() {
        webSocket?.cancel(with: .goingAway, reason: nil)
    }

    private func handlePreflight(_ message: [String: Any]) async throws {
        let requestID = message["request_id"] as? String ?? ""
        let estimatedTokens = message["estimated_tokens"] as? Int ?? 0
        let snapshot = await providerStatus.snapshot()

        if estimatedTokens > snapshot.capacity.maxContextTokens {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": false,
                "reason": "context_exceeds_capacity",
                "max_context_tokens": snapshot.capacity.maxContextTokens,
            ])
        } else if snapshot.status == .draining {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": false,
                "reason": "draining",
            ])
        } else if !snapshot.modelLoaded {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": false,
                "reason": "model_not_loaded",
            ])
        } else if snapshot.status == .unavailable {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": false,
                "reason": "unhealthy",
            ])
        } else {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": true,
                "estimated_wait_ms": 0,
            ])
        }
    }

    func drainAndExit(reason: String, exitCode: Int32 = 0) async {
        // Used by SIGTERM signal handler — drain in-flight buyer requests,
        // notify coordinator, then exit the whole process.
        try? await sendStateUpdate(state: .draining, reason: reason)
        try? await sendDrainStatus(phase: "starting")
        try? await sendDrainStatus(phase: "in_progress")
        let drained = await providerStatus.waitUntilDrained(timeoutSeconds: drainTimeoutSeconds)
        if !drained {
            await inferenceRelay?.cancelAll()
            _ = await inferenceRelay?.waitUntilIdle(timeoutSeconds: 5)
        }
        try? await sendDrainStatus(phase: "complete")
        webSocket?.cancel(with: .goingAway, reason: nil)
        Darwin.exit(exitCode)
    }

    /// Handle a coordinator-initiated drain (typically because the coordinator
    /// is shutting down or restarting). Sends the drain_status sequence,
    /// closes the WebSocket, but does NOT exit the process — the local buyer
    /// HTTP server keeps serving direct traffic. The reconnect loop will
    /// attempt to rejoin the coordinator after a grace period.
    /// SPEC-001 v1.1.4 § 6.5: after drain_status=complete, the provider's
    /// internal state machine MUST be reset back to .ready before the next
    /// hello, since hello starts a fresh coordinator session and any
    /// `draining` status carried over from the previous session would be
    /// reported in the very first heartbeat and stick (the coordinator
    /// has no implicit "draining → ready" transition).
    func drainFromCoordinator(reason: String) async throws {
        try? await sendStateUpdate(state: .draining, reason: reason)
        try? await sendDrainStatus(phase: "starting")
        try? await sendDrainStatus(phase: "in_progress")
        let drained = await providerStatus.waitUntilDrained(timeoutSeconds: drainTimeoutSeconds)
        if !drained {
            await inferenceRelay?.cancelAll()
            _ = await inferenceRelay?.waitUntilIdle(timeoutSeconds: 5)
        }
        try? await sendDrainStatus(phase: "complete")
        webSocket?.cancel(with: .goingAway, reason: nil)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        sleepAssertion?.stop()
        sleepAssertion = nil
        // v1.1.4: reset local state for the next coordinator session.
        // Local HTTP server kept serving throughout drain; provider is ready.
        await providerStatus.setState(.ready)
    }

    private func sendHeartbeat() async throws {
        let snapshot = await providerStatus.snapshot(resetWindow: true)
        var payload: [String: Any] = [
            "type": "heartbeat",
            "status": snapshot.status.rawValue,
            "model_id": snapshot.modelID ?? "",
            "model_params_b": snapshot.capacity.modelParamsB(modelID: snapshot.modelID),
            "ram_gb": snapshot.capacity.ramGB,
            "max_context_tokens": snapshot.capacity.maxContextTokens,
            "max_concurrency": snapshot.capacity.maxConcurrency,
            "slots_free": snapshot.slotsFree,
            "slots_total": snapshot.slotsTotal,
            "throughput_tps_estimate": snapshot.capacity.throughputTPSEstimate,
            "requests_served_since_last": snapshot.requestsServedSinceLast,
            "avg_latency_ms_since_last": nullableNumber(snapshot.avgLatencyMSSinceLast),
            "throughput_tps_since_last": nullableNumber(snapshot.throughputTPSSinceLast),
        ]
        if warmSwapEnabled {
            let runtimeSnapshot = await modelRuntime.currentSnapshot()
            payload["model_id"] = runtimeSnapshot.modelID ?? ""
            if let modelHash = runtimeSnapshot.modelHash {
                payload["model_hash"] = modelHash
            }
            payload["loading"] = runtimeSnapshot.state == .loading || runtimeSnapshot.state == .draining
        }
        try await send(payload)
    }

    private func sendStateUpdate(state newState: ProviderHealthState?, reason: String) async throws {
        if let newState {
            await providerStatus.setState(newState)
        }
        let snapshot = await providerStatus.snapshot()
        try await send([
            "type": "state_update",
            "state": snapshot.status.rawValue,
            "reason": reason,
            "since": ISO8601DateFormatter().string(from: Date()),
            "metrics_snapshot": [
                "slots_free": snapshot.slotsFree,
                "slots_total": snapshot.slotsTotal,
                "requests_served_since_last": snapshot.requestsServedSinceLast,
                "avg_latency_ms_since_last": nullableNumber(snapshot.avgLatencyMSSinceLast),
                "throughput_tps_since_last": nullableNumber(snapshot.throughputTPSSinceLast),
            ],
        ])
    }

    private func sendDrainStatus(phase: String) async throws {
        let snapshot = await providerStatus.snapshot()
        try await send([
            "type": "drain_status",
            "phase": phase,
            "inflight_requests": snapshot.requestsInFlight,
            "estimated_drain_seconds": 0,
        ])
    }

    private func sendNAK(inReplyTo: String, code: String, message: String) async throws {
        try await send([
            "type": "nak",
            "in_reply_to": inReplyTo,
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    func authInitialMessage(attempt: Tier2AuthAttempt) async -> [String: Any] {
        let snapshot = await providerStatus.snapshot()
        var message: [String: Any] = [
            "type": "auth_request",
            "version": 2,
            "stage": "initial",
            "provider_id": providerID,
            "hostname": Host.current().localizedName ?? "unknown",
            "model_id": snapshot.modelID ?? "",
            "model_params_b": snapshot.capacity.modelParamsB(modelID: snapshot.modelID),
            "ram_gb": snapshot.capacity.ramGB,
            "max_context_tokens": snapshot.capacity.maxContextTokens,
            "max_concurrency": snapshot.capacity.maxConcurrency,
            "throughput_tps_estimate": snapshot.capacity.throughputTPSEstimate,
            "binary_version": Self.binaryVersion,
            "provider_ecdh_public_key": attempt.publicKeyBase64URL,
            "tier2_capabilities": [
                "encrypted_leg": true,
                "attestation": true,
                "aead_suites": [Tier2ProviderSession.aeadSuite],
            ],
        ]
        let resolvedCatalog: [String]
        do {
            resolvedCatalog = try SupportedModels.validate(
                model: snapshot.modelID ?? "",
                supportedModels: supportedModels
            )
        } catch {
            resolvedCatalog = [snapshot.modelID ?? ""]
        }
        message["supported_models"] = resolvedCatalog
        if publishesSupportedModels {
            message["publishes_supported_models"] = true
        }
        if let endpointURL {
            message["endpoint_url"] = endpointURL
        }
        if let modelHash = snapshot.modelHash {
            message["model_hash"] = modelHash
        }
        return message
    }

    func helloMessage() async -> [String: Any] {
        let snapshot = await providerStatus.snapshot()
        var message: [String: Any] = [
            "type": "hello",
            "version": 1,
            "tier": 1,
            "provider_id": providerID,
            "hostname": Host.current().localizedName ?? "unknown",
            "model_id": snapshot.modelID ?? "",
            "model_params_b": snapshot.capacity.modelParamsB(modelID: snapshot.modelID),
            "ram_gb": snapshot.capacity.ramGB,
            "max_context_tokens": snapshot.capacity.maxContextTokens,
            "max_concurrency": snapshot.capacity.maxConcurrency,
            "throughput_tps_estimate": snapshot.capacity.throughputTPSEstimate,
            "binary_version": Self.binaryVersion,
            "attestation": NSNull(),
        ]
        if let endpointURL {
            message["endpoint_url"] = endpointURL
        }
        let modelIDForHello: String
        let hashForHello: String?
        if warmSwapEnabled {
            let runtimeSnapshot = await modelRuntime.currentSnapshot()
            modelIDForHello = runtimeSnapshot.modelID ?? ""
            hashForHello = runtimeSnapshot.modelHash
        } else {
            modelIDForHello = snapshot.modelID ?? ""
            hashForHello = snapshot.modelHash
        }
        message["model_id"] = modelIDForHello
        if let hashForHello {
            message["model_hash"] = hashForHello
        }
        return message
    }

    private func send(_ payload: [String: Any]) async throws {
        if let sendOverride {
            try await sendOverride(payload)
            return
        }
        guard let webSocket else { throw CancellationError() }
        try await Self.send(payload, to: webSocket)
    }

    private static func send(_ payload: [String: Any], to webSocket: ProviderWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        let text = String(decoding: data, as: UTF8.self)
        if let type = payload["type"] as? String {
            keepaliveDebug("ws_send type=\(type) bytes=\(text.utf8.count)")
        }
        try await webSocket.send(.string(text))
    }

    private static func receiveJSONObject(from webSocket: ProviderWebSocketTask) async throws -> [String: Any] {
        let message = try await webSocket.receive()
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(decoding: data, as: UTF8.self)
        @unknown default:
            throw CoordinatorAuthError.invalidMessage("Unsupported WebSocket frame")
        }
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any]
        else {
            throw CoordinatorAuthError.invalidMessage("Coordinator message must be a JSON object")
        }
        if let type = dict["type"] as? String {
            keepaliveDebug("ws_recv type=\(type) bytes=\(text.utf8.count)")
        }
        return dict
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }

    fileprivate static func keepaliveDebug(_ message: String) {
        guard keepaliveDebugEnabled else { return }
        let timestamp = String(format: "%.2f", Date().timeIntervalSince1970)
        FileHandle.standardError.write(Data("[keepalive \(timestamp)] \(message)\n".utf8))
    }

    private static func redactedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? "\(url.scheme ?? "wss")://\(url.host ?? "unknown")"
    }

    private func nullableNumber(_ value: Double?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private static func compareSemver(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }
}

/// Signals "coordinator asked us to drain, handle complete, reconnect later
/// after a grace period." Caught by runReconnectLoop.
struct CoordinatorDrainComplete: Error {}

enum CoordinatorAuthError: Error, Equatable, CustomStringConvertible {
    case invalidMessage(String)
    case rejected(code: String, message: String)

    var description: String {
        switch self {
        case .invalidMessage(let message):
            return message
        case .rejected(let code, let message):
            return "\(code): \(message)"
        }
    }
}
