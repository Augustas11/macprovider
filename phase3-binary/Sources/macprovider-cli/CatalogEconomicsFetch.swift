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
        try await AutotuneStaticInputs.fetchHonoringRateLimit(
            url,
            load: { try await session.boundedData(for: URLRequest(url: $0), limit: BYOMLiveCatalogMatcher.maxFetchBytes) }
        )
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
        // The matcher reads its candidate catalog from the static-feed origin
        // above and only the artifact feed from its own base.
        if let matcherBaseURL {
            urls += ["catalog-artifacts", "catalog-artifacts.sig"]
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
        /// Candidates whose read the deadline cut off (not those that failed).
        var missedCandidateIDs: Set<String>
        var complete: Bool { missedCandidateIDs.isEmpty }
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
        guard !pending.isEmpty else { return Result(statuses: [:], missedCandidateIDs: []) }
        let width = max(1, maxConcurrentReads)
        return await withTaskGroup(of: Event.self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, deadlineSeconds) * 1_000_000_000))
                return .deadline
            }
            var inFlight = Set<String>()
            func startNext() {
                guard !pending.isEmpty else { return }
                let candidateID = pending.removeFirst()
                inFlight.insert(candidateID)
                group.addTask { .read(candidateID, await status(candidateID)) }
            }
            for _ in 0..<width { startNext() }
            var statuses: [String: BYOMAdmissionStatusWire] = [:]
            while let event = await group.next() {
                switch event {
                case .deadline:
                    group.cancelAll()
                    return Result(statuses: statuses, missedCandidateIDs: inFlight.union(pending))
                case let .read(candidateID, wire):
                    inFlight.remove(candidateID)
                    if let wire { statuses[candidateID] = wire }
                    startNext()
                    if inFlight.isEmpty {
                        group.cancelAll()
                        return Result(statuses: statuses, missedCandidateIDs: [])
                    }
                }
            }
            return Result(statuses: statuses, missedCandidateIDs: inFlight.union(pending))
        }
    }
}

extension ModelCatalogEconomicsWire {
    /// SPEC-044-R002 projection bound: rows whose admission read the
    /// deadline cut off are already on `local_default` admission (no status
    /// was read); they and the projection carry `admission_state_missing`.
    func withAdmissionReadOutcome(missedCandidateIDs: Set<String>) -> ModelCatalogEconomicsWire {
        guard !missedCandidateIDs.isEmpty else { return self }
        let marked = rows.map { row -> Row in
            guard let candidateID = row.actionModelID,
                  missedCandidateIDs.contains(candidateID),
                  !row.warningCodes.contains("admission_state_missing") else { return row }
            var copy = row
            copy.warningCodes = (row.warningCodes + ["admission_state_missing"]).sorted()
            return copy
        }
        return ModelCatalogEconomicsWire(
            generatedAt: generatedAt,
            projectionSequence: projectionSequence,
            source: source,
            rows: marked,
            warnings: Set(warnings + ["admission_state_missing"]).sorted()
        )
    }
}

extension URLSession {
    /// Reads a response body, refusing it as soon as it exceeds `limit`
    /// bytes, so concurrent reads cannot buffer oversized bodies.
    func boundedData(for request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await self.bytes(for: request)
        if response.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        return (data, response)
    }
}
