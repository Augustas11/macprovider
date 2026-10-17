import Foundation

enum ProviderCLIVersion {
    static let compatibilitySetReleaseFloor = "1.8.33"

    enum Order: Equatable {
        case ascending
        case same
        case descending
    }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
    }

    /// Returns a canonical three-component release version or `nil` for
    /// malformed/pre-release input. Update authority must never be selected
    /// from the permissive display comparator below.
    static func strictNormalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(
            of: #"^[vV]?[0-9]+\.[0-9]+\.[0-9]+$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        let components = normalize(trimmed).split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else { return nil }
        var canonical: [String] = []
        canonical.reserveCapacity(3)
        for component in components {
            guard let value = Int(component), String(value) == component else {
                // Reject integer overflow and non-canonical leading zeroes.
                return nil
            }
            canonical.append(String(value))
        }
        return canonical.joined(separator: ".")
    }

    static func compare(_ lhs: String, _ rhs: String) -> Order {
        let left = normalize(lhs).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let right = normalize(rhs).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let width = max(left.count, right.count, 3)
        for index in 0..<width {
            let l = Int(left.indices.contains(index) ? left[index] : "0") ?? 0
            let r = Int(right.indices.contains(index) ? right[index] : "0") ?? 0
            if l < r { return .ascending }
            if l > r { return .descending }
        }
        return .same
    }

    static func isNewer(_ candidate: String?, than current: String?) -> Bool {
        guard let candidate, let current else { return false }
        return compare(current, candidate) == .ascending
    }

    /// Highest semver among coordinator recommendation and GitHub latest that
    /// is newer than the running CLI version.
    static func updateTarget(current: String?, recommended: String?, latestRelease: String?) -> String? {
        guard let current else { return nil }
        var best: String?
        for candidate in [recommended, latestRelease].compactMap({ $0 }) {
            guard isNewer(candidate, than: current) else { continue }
            if let existing = best {
                if compare(existing, candidate) == .ascending { best = candidate }
            } else {
                best = candidate
            }
        }
        return best
    }
}

/// Newest provider CLI release for the update badge (#2036). The production
/// coordinator's unauthenticated `/healthz` `recommended_binary_version` (the
/// SPEC-003-R004 release-mirror contract, the release every Mac without GitHub
/// installs) comes first. The anonymous GitHub API (60 requests per hour per
/// IP, shared by every Mac behind one NAT) is only the fallback, and a spent
/// budget is reported as a deferral until its reset. Display only:
/// `malibu-cli update` verifies every release byte under the release key.
enum LatestReleaseClient {
    enum Outcome: Equatable {
        case version(String)
        /// The anonymous GitHub API budget is spent until this time.
        case deferred(until: Date)
        case unavailable
    }

    static let coordinatorHealthzURL = URL(string: "https://coordinator.malibu.tech/healthz")!
    static let gitHubLatestURL = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!
    /// Fallback deferral when a spent budget names no reset time.
    static let rateLimitDeferral: TimeInterval = 3600
    /// Retry spacing after any other failure, so a failing source is never
    /// polled on the two-second status cadence.
    static let failureBackoff: TimeInterval = 600
    static let maxResponseBytes = 256 * 1024

    /// `/healthz` of the coordinator the provider config names (wss/https,
    /// no credentials), else the production coordinator.
    static func healthzURL(coordinatorURL: String?) -> URL {
        guard let coordinatorURL,
              var components = URLComponents(string: coordinatorURL),
              components.user == nil,
              components.password == nil,
              components.host?.isEmpty == false,
              ["wss", "https"].contains(components.scheme?.lowercased() ?? "")
        else {
            return coordinatorHealthzURL
        }
        components.scheme = "https"
        components.path = "/healthz"
        components.query = nil
        components.fragment = nil
        return components.url ?? coordinatorHealthzURL
    }

    static func fetch(
        coordinatorHealthzURL: URL = coordinatorHealthzURL,
        gitHubLatestURL: URL = gitHubLatestURL,
        session: URLSession = .shared,
        now: Date = Date()
    ) async -> Outcome {
        if let advertised = await coordinatorAdvertisedVersion(url: coordinatorHealthzURL, session: session) {
            return .version(advertised)
        }
        return await gitHubLatestVersion(url: gitHubLatestURL, session: session, now: now)
    }

    static func coordinatorAdvertisedVersion(url: URL, session: URLSession) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let advertised = object["recommended_binary_version"] as? String
        else {
            return nil
        }
        return ProviderCLIVersion.strictNormalize(advertised)
    }

    static func gitHubLatestVersion(url: URL, session: URLSession, now: Date) async -> Outcome {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            return .unavailable
        }
        if let reset = rateLimitReset(http, now: now) {
            return .deferred(until: reset)
        }
        guard (200..<300).contains(http.statusCode),
              data.count <= maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = ProviderCLIVersion.strictNormalize(tag)
        else {
            return .unavailable
        }
        return .version(version)
    }

    /// The reset time of a 403/429 whose `x-ratelimit-remaining` is 0,
    /// clamped into (now, now + 1h] (GitHub's window) so a header can never
    /// suppress the fetch for longer. Mirrors the CLI's GitHubAPIRateLimit.
    static func rateLimitReset(_ response: HTTPURLResponse, now: Date) -> Date? {
        guard response.statusCode == 403 || response.statusCode == 429,
              response.value(forHTTPHeaderField: "x-ratelimit-remaining")?
                  .trimmingCharacters(in: .whitespaces) == "0"
        else {
            return nil
        }
        let ceiling = now.addingTimeInterval(rateLimitDeferral)
        guard let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset")
            .flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
            .map({ Date(timeIntervalSince1970: $0) }),
            reset > now
        else {
            return ceiling
        }
        return min(reset, ceiling)
    }

    /// When the next fetch may run after `outcome`; nil after a version,
    /// whose freshness is governed by the caller's TTL instead.
    static func retryAfter(_ outcome: Outcome, now: Date) -> Date? {
        switch outcome {
        case .version:
            return nil
        case .deferred(let until):
            return max(until, now.addingTimeInterval(60))
        case .unavailable:
            return now.addingTimeInterval(failureBackoff)
        }
    }
}
