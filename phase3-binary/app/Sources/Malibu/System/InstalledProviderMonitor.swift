import Foundation

/// Observes a launchd-managed macprovider-cli via local HTTP /v1/health and /v1/status.
enum InstalledProviderMonitor {
    struct HealthSnapshot: Equatable {
        let ready: Bool
        let model: String?
        let requestsTotal: Int?
        let requestsToday: Int?
        let inputTokensToday: Int64?
        let outputTokensToday: Int64?
        let inputTokensAllTime: Int64?
        let outputTokensAllTime: Int64?
        let uptimeSeconds: Int?
        let restartCount: Int?
    }

    struct StatusSnapshot: Equatable {
        let binaryVersion: String?
        let recommendedVersion: String?
        let coordinatorConnected: Bool
        let coordinatorTier: String?
    }

    static func readHTTPPort(paths: ProviderPaths = .current) -> Int? {
        ProviderConfig.readHTTPPort(paths: paths)
    }

    static func isHealthy(port: Int, timeout: TimeInterval = 2) async -> Bool {
        await fetchHealth(port: port, timeout: timeout)?.ready == true
    }

    static func fetchHealth(port: Int, timeout: TimeInterval = 2) async -> HealthSnapshot? {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/health")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let status = object["status"] as? String
            let model = object["model"] as? String
            let requestsTotal = object["requests_total"] as? Int
            let requestsToday = object["requests_today"] as? Int
            let inputTokensToday = int64Value(object["input_tokens_today"])
            let outputTokensToday = int64Value(object["output_tokens_today"])
            let inputTokensAllTime = int64Value(object["input_tokens_all_time"])
            let outputTokensAllTime = int64Value(object["output_tokens_all_time"])
            let uptimeSeconds = object["uptime_s"] as? Int
            let restartCount = object["restart_count"] as? Int
            return HealthSnapshot(
                ready: status == "ready",
                model: model,
                requestsTotal: requestsTotal,
                requestsToday: requestsToday,
                inputTokensToday: inputTokensToday,
                outputTokensToday: outputTokensToday,
                inputTokensAllTime: inputTokensAllTime,
                outputTokensAllTime: outputTokensAllTime,
                uptimeSeconds: uptimeSeconds,
                restartCount: restartCount
            )
        } catch {
            return nil
        }
    }

    static func fetchStatus(port: Int, timeout: TimeInterval = 2) async -> StatusSnapshot? {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/status")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let coordinator = object["coordinator"] as? [String: Any] ?? [:]
            let recommended = stringValue(coordinator["recommended_binary_version"])
            return StatusSnapshot(
                binaryVersion: stringValue(object["binary_version"]),
                recommendedVersion: recommended,
                coordinatorConnected: (coordinator["connected"] as? Bool) == true,
                coordinatorTier: stringValue(coordinator["tier"])
            )
        } catch {
            return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "<null>" else { return nil }
        return text
    }

    /// Poll until health responds or deadline elapses.
    static func waitForHealthy(
        port: Int,
        deadline: Date,
        pollInterval: TimeInterval = 2
    ) async -> Bool {
        while Date() < deadline {
            if await isHealthy(port: port) { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let sleep = min(pollInterval, remaining)
            try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
        }
        return false
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}
