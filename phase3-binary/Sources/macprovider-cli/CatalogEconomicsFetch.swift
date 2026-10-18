import Foundation

/// `models catalog-economics` reads up to eight signed coordinator feeds and
/// one admission status per discovered candidate. Each read used to open its
/// own ephemeral TLS connection, one after another, so the projection took
/// longer than Malibu's subprocess timeout on an ordinary home link
/// (SPEC-044-R002 projection bound).
///
/// One command shares this fetcher: every feed URL is fetched at most once,
/// concurrently, over one bounded session that honours the coordinator's
/// HTTP cache headers (the static feeds are `max-age=300`). Signature and
/// freshness checks run on the returned bytes exactly as before, so a cached
/// response carries no more trust than a fresh one.
actor CoordinatorFeedFetcher {
    typealias Load = @Sendable (URL) async throws -> Data

    static let requestTimeoutSeconds: TimeInterval = 3
    static let resourceTimeoutSeconds: TimeInterval = 4
    /// Whole-read bound per feed, including the 429 retry waits, so a slow
    /// or rate-limited coordinator falls back to the compiled-in feed
    /// instead of holding the projection.
    static let feedDeadlineSeconds: TimeInterval = 5

    /// Process-wide so concurrent feed reads reuse one connection pool, and
    /// on the default configuration so `URLCache.shared` serves fresh feeds.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        configuration.timeoutIntervalForResource = resourceTimeoutSeconds
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: configuration)
    }()

    static let boundedLoad: Load = { url in
        let data = try await AutotuneStaticInputs.fetchHonoringRateLimit(
            url,
            load: { try await session.data(from: $0) }
        )
        guard data.count <= BYOMLiveCatalogMatcher.maxFetchBytes else {
            throw AutotuneRecommendError.invalidStaticJSON("response too large")
        }
        return data
    }

    private let load: Load
    private let deadlineSeconds: TimeInterval
    private var reads: [URL: Task<Data, Error>] = [:]

    init(
        load: @escaping Load = CoordinatorFeedFetcher.boundedLoad,
        deadlineSeconds: TimeInterval = CoordinatorFeedFetcher.feedDeadlineSeconds
    ) {
        self.load = load
        self.deadlineSeconds = deadlineSeconds
    }

    /// Starts every URL now so the reads overlap with local discovery.
    func prefetch(_ urls: [URL]) {
        for url in urls { _ = read(url) }
    }

    func fetch(_ url: URL) async throws -> Data {
        try await read(url).value
    }

    private func read(_ url: URL) -> Task<Data, Error> {
        if let existing = reads[url] { return existing }
        let load = self.load
        let deadline = deadlineSeconds
        let task = Task { try await Self.withDeadline(seconds: deadline) { try await load(url) } }
        reads[url] = task
        return task
    }

    static func withDeadline(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }

    /// The feeds `loadRecommendationInputs` and the live catalog matcher read.
    static func catalogEconomicsFeedURLs(matcherBaseURL: URL?) -> [URL] {
        var urls = ["demand-rank", "autotune-candidates", "rate-card"].flatMap { name in
            [name, "\(name).sig"].map { AutotuneStaticInputs.staticFeedURL(baseURL: StaticFeedOrigin.base, name: $0) }
        }
        if let matcherBaseURL {
            urls += ["autotune-candidates", "autotune-candidates.sig", "catalog-artifacts", "catalog-artifacts.sig"]
                .map { AutotuneStaticInputs.staticFeedURL(baseURL: matcherBaseURL, name: $0) }
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }
}

/// Reads coordinator admission status for each candidate concurrently, under
/// one deadline. A candidate whose read has not finished by the deadline is
/// left out, so its row falls back to `local_default` admission with
/// `admission_state_missing` (fail-closed) instead of holding up every row.
enum CatalogEconomicsAdmissionReader {
    static let deadlineSeconds: TimeInterval = 3
    static let maxConcurrentReads = 8

    struct Result: Sendable {
        var statuses: [String: BYOMAdmissionStatusWire]
        /// False when the deadline cut off at least one read.
        var complete: Bool
    }

    private enum Event: Sendable {
        case read(String, BYOMAdmissionStatusWire?)
        case deadline
    }

    static func read(
        candidateIDs: [String],
        deadlineSeconds: TimeInterval = deadlineSeconds,
        maxConcurrentReads: Int = maxConcurrentReads,
        status: @escaping @Sendable (String) async -> BYOMAdmissionStatusWire?
    ) async -> Result {
        var pending = Array(Set(candidateIDs)).sorted()
        guard !pending.isEmpty else { return Result(statuses: [:], complete: true) }
        let width = max(1, maxConcurrentReads)
        return await withTaskGroup(of: Event.self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, deadlineSeconds) * 1_000_000_000))
                return .deadline
            }
            var inFlight = 0
            func startNext() {
                guard !pending.isEmpty else { return }
                let candidateID = pending.removeFirst()
                inFlight += 1
                group.addTask { .read(candidateID, await status(candidateID)) }
            }
            for _ in 0..<width { startNext() }
            var statuses: [String: BYOMAdmissionStatusWire] = [:]
            while let event = await group.next() {
                switch event {
                case .deadline:
                    group.cancelAll()
                    return Result(statuses: statuses, complete: false)
                case let .read(candidateID, wire):
                    inFlight -= 1
                    if let wire { statuses[candidateID] = wire }
                    startNext()
                    if inFlight == 0 {
                        group.cancelAll()
                        return Result(statuses: statuses, complete: true)
                    }
                }
            }
            return Result(statuses: statuses, complete: true)
        }
    }
}

extension ModelCatalogEconomicsWire {
    /// SPEC-044-R002 projection bound: when the admission read hit its
    /// deadline, the rows it missed already carry `local_default` admission
    /// and `admission_state_missing`; the projection says so too.
    func withAdmissionReadOutcome(complete: Bool) -> ModelCatalogEconomicsWire {
        guard !complete, !warnings.contains("admission_state_missing") else { return self }
        return ModelCatalogEconomicsWire(
            generatedAt: generatedAt,
            projectionSequence: projectionSequence,
            source: source,
            rows: rows,
            warnings: (warnings + ["admission_state_missing"]).sorted()
        )
    }
}
