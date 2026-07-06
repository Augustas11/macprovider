import Foundation

/// Observes a launchd-managed macprovider-cli via local HTTP /v1/health.
enum InstalledProviderMonitor {
    struct HealthSnapshot: Equatable {
        let ready: Bool
        let model: String?
        let requestsTotal: Int?
        let uptimeSeconds: Int?
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
            let uptimeSeconds = object["uptime_s"] as? Int
            return HealthSnapshot(
                ready: status == "ready",
                model: model,
                requestsTotal: requestsTotal,
                uptimeSeconds: uptimeSeconds
            )
        } catch {
            return nil
        }
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
}
