import Foundation

/// Observes a launchd-managed macprovider-cli via local HTTP /v1/health.
enum InstalledProviderMonitor {
    static func readHTTPPort(paths: ProviderPaths = .current) -> Int? {
        ProviderConfig.readHTTPPort(paths: paths)
    }

    static func isHealthy(port: Int, timeout: TimeInterval = 2) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/health")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
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
