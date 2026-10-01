import Foundation
import MacProviderCore

/// #1816: the catalog matcher the BYOM admission commands share.
///
/// A release built with no compiled-in artifact feed
/// (`bakedArtifactFeedBase64 == nil`) can never match a served artifact
/// through the artifact leg, so `discover`, `evaluate`, `offer`, and
/// `catalog-economics` used to report `no_earning_path_in_v0_1` for a GGUF or
/// MLX-snapshot artifact the coordinator's own signed feed binds. This
/// selects the coordinator's signed live artifact feed, bound to the live
/// candidate catalog of the same release (SPEC-023 §3.7.6 rule 5), and falls
/// back to the compiled-in selection when no usable live feed exists. The
/// feed is signed coordinator authority; selecting it creates no local
/// catalog authority (SPEC-046).
enum BYOMLiveCatalogMatcher {
    static let productionBaseURL = URL(string: "https://coordinator.malibu.tech")!
    /// Discovery must stay responsive when the coordinator is unreachable.
    static let fetchTimeoutSeconds: TimeInterval = 10
    static let maxFetchBytes = 4 * 1024 * 1024

    enum Source: String, Sendable {
        case liveSigned = "live_signed"
        case compiledIn = "compiled_in"
    }

    static func resolve(
        offline: Bool,
        coordinatorURL: String?,
        inputs: AutotuneStaticInputs = AutotuneStaticInputs(fetch: boundedFetch),
        now: Date = Date()
    ) async -> (matcher: BYOMCatalogMatcher, source: Source) {
        guard !offline else { return (BYOMCatalogMatcher(now: now), .compiledIn) }
        let baseURL = BYOMModelAdmissionClient.httpBaseURL(from: coordinatorURL) ?? productionBaseURL
        let candidate = await inputs.loadCandidateCatalog()
        let live = await inputs.loadLiveArtifactFeed(candidate: candidate, baseURL: baseURL)
        return select(candidate: candidate, live: live, now: now)
    }

    /// The live feed is used only together with the candidate catalog it was
    /// qualified against; anything else is the compiled-in selection.
    static func select(
        candidate: AutotuneStaticSelection<CandidateCatalog>,
        live: AutotuneStaticSelection<QualifiedArtifactFeed?>,
        now: Date = Date()
    ) -> (matcher: BYOMCatalogMatcher, source: Source) {
        if let feed = live.value {
            return (BYOMCatalogMatcher(candidateBytes: candidate.selectedBytes, artifactFeed: feed), .liveSigned)
        }
        return (BYOMCatalogMatcher(now: now), .compiledIn)
    }

    /// The coordinator URL a command without its own `--coordinator-url`
    /// reads the feed from: the provider config's. A config that is missing
    /// (when named by `--config` or `MACPROVIDER_CONFIG`), unreadable, or
    /// invalid is an error, never a silent fall-back to the production
    /// coordinator; production is the default only after the config loaded.
    static func configuredCoordinatorURL(configPath: String? = nil) throws -> String? {
        try ConfigLoader.load(cli: CLIOverrides(configPath: configPath)).coordinatorURL
    }

    static func boundedFetch(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = fetchTimeoutSeconds
        configuration.timeoutIntervalForResource = fetchTimeoutSeconds * 2
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw AutotuneRecommendError.invalidStaticJSON("HTTP \(http.statusCode)")
        }
        guard data.count <= maxFetchBytes else {
            throw AutotuneRecommendError.invalidStaticJSON("response too large")
        }
        return data
    }
}

extension BYOMDiscoveryEnvironment {
    /// The same environment with the live-or-compiled-in matcher installed.
    func withCatalogMatcher(offline: Bool, coordinatorURL: String?) async -> BYOMDiscoveryEnvironment {
        var copy = self
        copy.catalogMatcher = await BYOMLiveCatalogMatcher.resolve(offline: offline, coordinatorURL: coordinatorURL).matcher
        return copy
    }
}
