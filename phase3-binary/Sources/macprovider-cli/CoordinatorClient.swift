import Foundation
import MacProviderCore
import Darwin

actor CoordinatorClient {
    static let binaryVersion = "1.2.3"

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
    private let reconnectGraceNanoseconds: UInt64
    private let connectAndRunOverride: (() async throws -> Void)?
    private var inferenceRelay: InferenceRelay?
    private var webSocket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private let sendOverride: (([String: Any]) async throws -> Void)?

    init?(
        config: AppConfig,
        modelRuntime: ModelRuntime,
        providerStatus: ProviderStatus,
        sendOverride: (([String: Any]) async throws -> Void)? = nil,
        reconnectGraceNanoseconds: UInt64 = 10 * 1_000_000_000,
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
        self.reconnectGraceNanoseconds = reconnectGraceNanoseconds
        self.connectAndRunOverride = connectAndRunOverride
        self.sendOverride = sendOverride
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    func stop() async {
        runTask?.cancel()
        heartbeatTask?.cancel()
        await inferenceRelay?.cancelAllAndClear()
        webSocket?.cancel(with: .goingAway, reason: nil)
        await providerStatus.setCoordinatorSession(connected: false)
        runTask = nil
        heartbeatTask = nil
        webSocket = nil
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

    private func connectAndRun() async throws {
        let socket = URLSession.shared.webSocketTask(with: coordinatorURL)
        webSocket = socket
        socket.resume()
        if wsTunneledMode {
            inferenceRelay = InferenceRelay(
                modelRuntime: modelRuntime,
                providerStatus: providerStatus,
                loadedModelID: loadedModelID,
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

        while !Task.isCancelled {
            let message = try await socket.receive()
            try await handle(message)
        }
    }

    private func cleanupConnection() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await inferenceRelay?.cancelAllAndClear()
        inferenceRelay = nil
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

        switch type {
        case "hello_ack":
            let interval = max((dict["heartbeat_interval_s"] as? Int) ?? 30, 1)
            await providerStatus.setCoordinatorSession(
                connected: true,
                assignedID: dict["assigned_id"] as? String,
                tier: dict["tier"] as? String,
                recommendedBinaryVersion: dict["recommended_binary_version"] as? String
            )
            if let tier = dict["tier"] as? String {
                print("Coordinator tier: \(tier)")
            }
            if let recommended = dict["recommended_binary_version"] as? String,
               Self.compareSemver(Self.binaryVersion, recommended) == .orderedAscending
            {
                print("A newer version is available (v\(recommended)). Run 'macprovider-cli update' to upgrade.")
            }
            startHeartbeat(intervalSeconds: interval)
            try await sendStateUpdate(state: nil, reason: "coordinator hello_ack received")
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

    private func startHeartbeat(intervalSeconds: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                try? await self?.sendHeartbeat()
            }
        }
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
        // v1.1.4: reset local state for the next coordinator session.
        // Local HTTP server kept serving throughout drain; provider is ready.
        await providerStatus.setState(.ready)
    }

    private func sendHeartbeat() async throws {
        let snapshot = await providerStatus.snapshot(resetWindow: true)
        try await send([
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
        ])
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

    private func helloMessage() async -> [String: Any] {
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

    private static func send(_ payload: [String: Any], to webSocket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        let text = String(decoding: data, as: UTF8.self)
        try await webSocket.send(.string(text))
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
