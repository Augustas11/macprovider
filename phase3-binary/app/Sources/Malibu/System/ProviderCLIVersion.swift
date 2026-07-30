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

enum GitHubLatestReleaseClient {
    static let defaultURL = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!

    static func fetchTag(
        url: URL = defaultURL,
        session: URLSession = .shared
    ) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String else {
                return nil
            }
            return ProviderCLIVersion.normalize(tag)
        } catch {
            return nil
        }
    }
}
