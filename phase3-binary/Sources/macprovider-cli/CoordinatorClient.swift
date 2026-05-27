import Foundation
import MacProviderCore
import Darwin

actor CoordinatorClient {
    private let config: AppConfig
    private let coordinatorURL: URL
    private let capacity: ProviderCapacity
    private var webSocket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var state = "ready"

    init?(config: AppConfig) {
        guard let rawURL = config.coordinatorURL, let url = URL(string: rawURL) else {
            return nil
        }
        self.config = config
        self.coordinatorURL = url
        self.capacity = ProviderCapacity(
            maxContextOverride: config.maxContextOverride,
            maxConcurrencyOverride: config.maxConcurrencyOverride
        )
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    func stop() {
        runTask?.cancel()
        heartbeatTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        runTask = nil
        heartbeatTask = nil
        webSocket = nil
    }

    private func runReconnectLoop() async {
        var backoffSeconds: UInt64 = 1
        while !Task.isCancelled {
            do {
                try await connectAndRun()
                backoffSeconds = 1
            } catch is CancellationError {
                return
            } catch {
                heartbeatTask?.cancel()
                webSocket?.cancel(with: .goingAway, reason: nil)
                webSocket = nil
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(backoffSeconds * 2, 60)
            }
        }
    }

    private func connectAndRun() async throws {
        let socket = URLSession.shared.webSocketTask(with: coordinatorURL)
        webSocket = socket
        socket.resume()

        try await send(helloMessage())

        while !Task.isCancelled {
            let message = try await socket.receive()
            try await handle(message)
        }
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
            startHeartbeat(intervalSeconds: interval)
            try await sendStateUpdate(state: "ready", reason: "coordinator hello_ack received")
        case "preflight":
            try await handlePreflight(dict)
        case "drain":
            await drainAndExit(reason: "coordinator drain requested")
        case "warm_up":
            try await sendStateUpdate(state: "degraded", reason: "coordinator warm_up requested")
            try await sendStateUpdate(state: "ready", reason: "warm_up complete")
        default:
            try await sendNAK(
                inReplyTo: type,
                code: "unknown_message_type",
                message: "Unrecognized message type: '\(type)'"
            )
        }
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

        if estimatedTokens > capacity.maxContextTokens {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": false,
                "reason": "context_exceeds_capacity",
                "max_context_tokens": capacity.maxContextTokens,
            ])
        } else if state == "draining" {
            try await send([
                "type": "preflight_ack",
                "request_id": requestID,
                "accepted": false,
                "reason": "draining",
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
        try? await sendStateUpdate(state: "draining", reason: reason)
        try? await sendDrainStatus(phase: "starting")
        try? await sendDrainStatus(phase: "in_progress")
        try? await sendDrainStatus(phase: "complete")
        webSocket?.cancel(with: .goingAway, reason: nil)
        Darwin.exit(exitCode)
    }

    private func sendHeartbeat() async throws {
        try await send([
            "type": "heartbeat",
            "status": state,
            "model_id": config.model ?? "",
            "model_params_b": capacity.modelParamsB(modelID: config.model),
            "ram_gb": capacity.ramGB,
            "max_context_tokens": capacity.maxContextTokens,
            "max_concurrency": capacity.maxConcurrency,
            "slots_free": capacity.maxConcurrency,
            "slots_total": capacity.maxConcurrency,
            "throughput_tps_estimate": capacity.throughputTPSEstimate,
            "requests_served_since_last": 0,
            "avg_latency_ms_since_last": NSNull(),
            "throughput_tps_since_last": NSNull(),
        ])
    }

    private func sendStateUpdate(state newState: String, reason: String) async throws {
        state = newState
        try await send([
            "type": "state_update",
            "state": newState,
            "reason": reason,
            "since": ISO8601DateFormatter().string(from: Date()),
            "metrics_snapshot": [
                "slots_free": newState == "busy" ? 0 : capacity.maxConcurrency,
                "slots_total": capacity.maxConcurrency,
                "requests_served_since_last": 0,
                "avg_latency_ms_since_last": NSNull(),
                "throughput_tps_since_last": NSNull(),
            ],
        ])
    }

    private func sendDrainStatus(phase: String) async throws {
        try await send([
            "type": "drain_status",
            "phase": phase,
            "inflight_requests": 0,
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

    private func helloMessage() -> [String: Any] {
        [
            "type": "hello",
            "version": 1,
            "tier": 1,
            "provider_id": UUID().uuidString,
            "hostname": Host.current().localizedName ?? "unknown",
            "model_id": config.model ?? "",
            "model_params_b": capacity.modelParamsB(modelID: config.model),
            "ram_gb": capacity.ramGB,
            "max_context_tokens": capacity.maxContextTokens,
            "max_concurrency": capacity.maxConcurrency,
            "throughput_tps_estimate": capacity.throughputTPSEstimate,
            "binary_version": "0.1.0",
            "attestation": NSNull(),
        ]
    }

    private func send(_ payload: [String: Any]) async throws {
        guard let webSocket else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)
        try await webSocket.send(.string(text))
    }
}

private struct ProviderCapacity: Sendable {
    let ramGB: Int
    let maxContextTokens: Int
    let maxConcurrency: Int
    let throughputTPSEstimate: Double

    init(maxContextOverride: Int?, maxConcurrencyOverride: Int?) {
        let physicalMemoryGB = max(1, Int((ProcessInfo.processInfo.physicalMemory + 1_073_741_823) / 1_073_741_824))
        self.ramGB = physicalMemoryGB

        let defaults: (context: Int, concurrency: Int)
        switch physicalMemoryGB {
        case ...12:
            defaults = (20_000, 1)
        case ...24:
            defaults = (50_000, 2)
        case ...48:
            defaults = (120_000, 4)
        default:
            defaults = (200_000, 8)
        }

        self.maxContextTokens = maxContextOverride ?? defaults.context
        self.maxConcurrency = maxConcurrencyOverride ?? defaults.concurrency
        self.throughputTPSEstimate = 0.0
    }

    func modelParamsB(modelID: String?) -> Double {
        guard let modelID else { return 0.0 }
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: modelID, range: NSRange(modelID.startIndex..., in: modelID)),
              let range = Range(match.range(at: 1), in: modelID)
        else {
            return 0.0
        }
        return Double(modelID[range]) ?? 0.0
    }
}
