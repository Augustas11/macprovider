import Foundation
import XCTest
@testable import macprovider_cli

/// Fake slow sources for the catalog-economics projection bound (SPEC-044-R002).
private actor LoadLog {
    var loads: [URL] = []
    var active = 0
    var peak = 0
    func begin(_ url: URL? = nil) {
        if let url { loads.append(url) }
        active += 1
        peak = max(peak, active)
    }
    func end() { active -= 1 }
}

final class CatalogEconomicsFetchTests: XCTestCase {
    private static let base = URL(string: "https://coordinator.example")!

    func testFeedFetcherReadsEachURLOnceAndOverlapsReads() async throws {
        let log = LoadLog()
        let fetcher = CoordinatorFeedFetcher(load: { url in
            await log.begin(url)
            try await Task.sleep(nanoseconds: 400_000_000)
            await log.end()
            return Data(url.lastPathComponent.utf8)
        })
        let urls = ["a", "b", "c", "d"].map { Self.base.appendingPathComponent($0) }
        let started = Date()
        await fetcher.prefetch(urls)
        async let first = fetcher.fetch(urls[0])
        async let again = fetcher.fetch(urls[0])
        async let last = fetcher.fetch(urls[3])
        let values = try await [first, again, last]
        XCTAssertEqual(values.map { String(decoding: $0, as: UTF8.self) }, ["a", "a", "d"])
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 1.2, "four 0.4 s reads must overlap, not run back to back")
        let loads = await log.loads
        XCTAssertEqual(loads.count, 4, "each URL is loaded exactly once")
        XCTAssertEqual(Set(loads), Set(urls))
        let peak = await log.peak
        XCTAssertGreaterThan(peak, 1)
    }

    func testFeedFetcherSharesAFailureWithoutRetryingTheSource() async {
        let log = LoadLog()
        let fetcher = CoordinatorFeedFetcher(load: { url in
            await log.begin(url)
            throw URLError(.timedOut)
        })
        let url = Self.base.appendingPathComponent("rate-card")
        for _ in 0..<3 {
            do {
                _ = try await fetcher.fetch(url)
                XCTFail("expected the timeout to propagate")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
            }
        }
        let loads = await log.loads
        XCTAssertEqual(loads.count, 1)
    }

    func testSlowFeedHitsItsDeadlineInsteadOfHoldingTheProjection() async {
        let fetcher = CoordinatorFeedFetcher(
            load: { _ in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return Data()
            },
            deadlineSeconds: 0.3
        )
        let started = Date()
        do {
            _ = try await fetcher.fetch(Self.base.appendingPathComponent("catalog-artifacts"))
            XCTFail("expected the deadline to fire")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertLessThanOrEqual(CoordinatorFeedFetcher.feedDeadlineSeconds, 5)
    }

    func testDeadlineReportsQueuedAndInFlightReadsAsMissed() async {
        let result = await CatalogEconomicsAdmissionReader.read(
            candidateIDs: ["a", "b", "c"],
            deadlineSeconds: 0.3,
            maxConcurrentReads: 1
        ) { id in
            if id == "a" { return Self.status(id) }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return nil
        }
        XCTAssertEqual(Set(result.statuses.keys), ["a"])
        XCTAssertEqual(result.missedCandidateIDs, ["b", "c"], "the in-flight read and the queued one")
    }

    func testBoundedDataRefusesAnOversizedBody() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let small = URLRequest(url: URL(string: "data:application/json;base64,e30=")!)
        let (data, _) = try await session.boundedData(for: small, limit: 16)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{}")
        let large = URLRequest(url: URL(string: "data:text/plain;base64," + Data(repeating: 0x41, count: 64).base64EncodedString())!)
        do {
            _ = try await session.boundedData(for: large, limit: 16)
            XCTFail("expected the size bound to refuse the body")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
    }

    func testCatalogEconomicsFeedURLsCoverSignedPairsWithoutDuplicates() {
        let offline = CoordinatorFeedFetcher.catalogEconomicsFeedURLs(matcherBaseURL: nil)
        XCTAssertEqual(offline.count, 6)
        XCTAssertEqual(Set(offline).count, offline.count)
        let live = CoordinatorFeedFetcher.catalogEconomicsFeedURLs(matcherBaseURL: StaticFeedOrigin.base)
        XCTAssertEqual(Set(live).count, live.count)
        XCTAssertTrue(live.contains { $0.lastPathComponent == "catalog-artifacts.sig" })
        let elsewhere = CoordinatorFeedFetcher.catalogEconomicsFeedURLs(matcherBaseURL: Self.base)
        XCTAssertEqual(elsewhere.count, 8, "only the artifact pair is read from the matcher base")
        XCTAssertEqual(
            Set(elsewhere.filter { $0.host == Self.base.host }.map(\.lastPathComponent)),
            ["catalog-artifacts", "catalog-artifacts.sig"]
        )
    }

    func testFeedSessionIsBoundedAndHonoursHTTPCaching() {
        let configuration = CoordinatorFeedFetcher.session.configuration
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForRequest, 3)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForResource, 4)
        XCTAssertEqual(configuration.requestCachePolicy, .useProtocolCachePolicy)
        XCTAssertNotNil(configuration.urlCache)
    }

    func testAdmissionReadsRunConcurrentlyUpToTheCap() async {
        let log = LoadLog()
        let ids = (0..<12).map { "candidate-\($0)" }
        let started = Date()
        let result = await CatalogEconomicsAdmissionReader.read(
            candidateIDs: ids,
            deadlineSeconds: 5,
            maxConcurrentReads: 4
        ) { id in
            await log.begin()
            try? await Task.sleep(nanoseconds: 200_000_000)
            await log.end()
            return Self.status(id)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(Set(result.statuses.keys), Set(ids))
        let peak = await log.peak
        XCTAssertEqual(peak, 4, "reads overlap but never exceed the cap")
        XCTAssertLessThan(elapsed, 1.5, "twelve 0.2 s reads at width 4 take about 0.6 s, not 2.4 s")
    }

    func testOneSlowAdmissionReadDoesNotBlockTheOthers() async {
        let started = Date()
        let result = await CatalogEconomicsAdmissionReader.read(
            candidateIDs: ["fast-a", "slow", "fast-b"],
            deadlineSeconds: 0.5
        ) { id in
            if id == "slow" {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return Task.isCancelled ? nil : Self.status(id)
            }
            return Self.status(id)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.missedCandidateIDs, ["slow"])
        XCTAssertEqual(Set(result.statuses.keys), ["fast-a", "fast-b"])
        XCTAssertLessThan(elapsed, 2, "the deadline bounds the read, not the slowest source")
    }

    func testFailedAdmissionReadIsNotAnIncompleteRead() async {
        let result = await CatalogEconomicsAdmissionReader.read(candidateIDs: ["a", "b", "a"]) { id in
            id == "a" ? nil : Self.status(id)
        }
        XCTAssertTrue(result.complete)
        XCTAssertTrue(result.missedCandidateIDs.isEmpty)
        XCTAssertEqual(Array(result.statuses.keys), ["b"])
        let empty = await CatalogEconomicsAdmissionReader.read(candidateIDs: []) { _ in
            XCTFail("no candidates, no reads")
            return nil
        }
        XCTAssertTrue(empty.complete)
    }

    private static func status(_ candidateID: String) -> BYOMAdmissionStatusWire {
        BYOMAdmissionStatusWire(
            schema: "model_admission_status.v1",
            generatedAt: "2027-01-15T08:00:00Z",
            cliVersion: "test",
            providerID: "provider-test",
            candidateID: candidateID,
            servedModelRef: "test-model",
            catalogModelKey: nil,
            admissionState: "not_offered",
            admissionStateSource: "coordinator",
            coordinatorEventID: "event-test",
            stateObservedAt: "2027-01-15T08:00:00Z",
            providerGuidance: BYOMDiscoveryWire.Guidance(
                stateLabelKey: "byom.admission.not_offered",
                stateMeaningKey: "byom.admission.not_earning",
                nextAction: "wait_for_coordinator",
                transitionReasonCode: nil,
                earningPathClass: "no_earning_path_in_v0_1"
            ),
            allowedNextStates: [],
            warnings: []
        )
    }
}
