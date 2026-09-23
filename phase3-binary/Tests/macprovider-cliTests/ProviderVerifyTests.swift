import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderVerifyTests: XCTestCase {
    private let port = 18_080
    private let coordinatorURL = "wss://coordinator.example/ws/provider"
    private let feedURL = "https://coordinator.example/v1/stats/routability"
    private let startedAt = "2026-09-23T10:00:00Z"
    private let now = ISO8601DateFormatter().date(from: "2026-09-23T10:05:00Z")!

    func testAllLayersAgreeProducesProofLineAndExitZero() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody()),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])

        let report = await verifier(stub).run()

        XCTAssertEqual(report.outcome, .agree)
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.layers.map(\.state), [.pass, .pass, .pass])
        XCTAssertEqual(report.feedLagSeconds, 12)
        XCTAssertTrue(report.unverifiableFields.contains("provider_id"))
        let text = ProviderVerifyFormatter.text(report)
        XCTAssertTrue(text.contains("✓ Local provider"), text)
        XCTAssertTrue(text.contains("✓ Network"), text)
        XCTAssertTrue(text.contains("✓ Public feed"), text)
        XCTAssertTrue(text.contains(
            "Verified: provider mp-studio · model mlx-community/Qwen3.6-27B-4bit (artifact 518ef47c2987) · context 200000 · slots 8 · catalog release rel-2026-09-23 · public feed 2026-09-23T10:04:48Z (lag 12s)"
        ), text)
    }

    func testLocalNotReadyTimesOutWithLocalExitCode() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (503, Data(#"{"error":{"code":"model_not_loaded"}}"#.utf8)),
            localStatusURL: (200, statusBody(status: "unavailable", modelLoaded: false)),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])

        let report = await verifier(stub, timeout: 10).run()

        XCTAssertEqual(report.outcome, .localNotReady)
        XCTAssertEqual(report.exitCode, 2)
        XCTAssertEqual(report.layers.first?.state, .fail)
        XCTAssertGreaterThan(stub.count(localStatusURL), 1, "verify polls until the deadline")
        XCTAssertTrue(ProviderVerifyFormatter.text(report).contains("Not verified: Local provider"))
    }

    func testCatalogMaterialMissingIsADistinctImmediateFailure() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(networkState: "not_buyer_serving", hold: "catalog_material_missing")),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])

        let report = await verifier(stub, timeout: 60).run()

        XCTAssertEqual(report.outcome, .catalogMaterialMissing)
        XCTAssertEqual(report.exitCode, 6)
        XCTAssertEqual(stub.count(localStatusURL), 1, "a catalog-material hold cannot clear by waiting")
        let network = try XCTUnwrap(report.layers.first { $0.layer == .network })
        XCTAssertEqual(network.state, .fail)
        XCTAssertTrue(network.reason.contains("catalog material missing"), network.reason)
    }

    func testFeedContextBelowLocalIsDisagreementNamingPublicFeed() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody()),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z", modelContext: 4_000)),
        ])

        let report = await verifier(stub, timeout: 0).run()

        XCTAssertEqual(report.outcome, .disagreement)
        XCTAssertEqual(report.exitCode, 4)
        let feed = try XCTUnwrap(report.layers.first { $0.layer == .publicFeed })
        XCTAssertEqual(feed.state, .fail)
        XCTAssertTrue(feed.reason.contains("context 4000"), feed.reason)
        XCTAssertTrue(feed.reason.contains("200000"), feed.reason)
        XCTAssertTrue(ProviderVerifyFormatter.text(report).contains("Not verified: Public feed"))
    }

    func testFeedWithoutMatchingSlotsEntryIsDisagreement() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody()),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z", providerSlots: 1)),
        ])

        let report = await verifier(stub, timeout: 0).run()

        XCTAssertEqual(report.outcome, .disagreement)
        let feed = try XCTUnwrap(report.layers.first { $0.layer == .publicFeed })
        XCTAssertTrue(feed.reason.contains("8 slots"), feed.reason)
    }

    func testFeedOlderThanProviderStartIsStaleTimeout() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody()),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T09:59:00Z", modelContext: 4_000)),
        ])

        let report = await verifier(stub, timeout: 0).run()

        XCTAssertEqual(report.outcome, .timeout)
        XCTAssertEqual(report.exitCode, 5)
        let feed = try XCTUnwrap(report.layers.first { $0.layer == .publicFeed })
        XCTAssertEqual(feed.state, .pending)
        XCTAssertTrue(feed.reason.contains("stale"), feed.reason)
    }

    func testStaleFeed503AndWaitingNetworkRetryThenAgree() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(networkState: "buyer_serving_unknown")),
            feedURL: (503, Data(#"{"error":{"code":"stats_stale"}}"#.utf8)),
        ])
        stub.after(calls: 2, url: localStatusURL, respond: (200, statusBody()))
        stub.after(calls: 2, url: feedURL, respond: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")))

        let report = await verifier(stub, timeout: 120).run()

        XCTAssertEqual(report.outcome, .agree)
        XCTAssertEqual(stub.count(localStatusURL), 3)
    }

    func testFeedNotPublishedIsUnavailable() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody()),
            feedURL: (404, Data(#"{"error":{"code":"bad_request"}}"#.utf8)),
        ])

        let report = await verifier(stub, timeout: 60).run()

        XCTAssertEqual(report.outcome, .publicFeedUnavailable)
        XCTAssertEqual(report.exitCode, 7)
        XCTAssertEqual(stub.count(feedURL), 1)
    }

    func testJSONReportCarriesLayersProofAndUnverifiableFields() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody()),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])

        let report = await verifier(stub).run()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ProviderVerifyFormatter.json(report)) as? [String: Any]
        )

        XCTAssertEqual(object["schema_version"] as? String, "provider_verify.v1")
        XCTAssertEqual(object["outcome"] as? String, "agree")
        XCTAssertEqual(object["exit_code"] as? Int, 0)
        XCTAssertEqual((object["layers"] as? [[String: Any]])?.count, 3)
        let proof = try XCTUnwrap(object["proof"] as? [String: Any])
        XCTAssertEqual(proof["provider_id"] as? String, "mp-studio")
        XCTAssertEqual(proof["max_context_tokens"] as? Int, 200_000)
        XCTAssertEqual(proof["slots"] as? Int, 8)
        XCTAssertEqual(proof["feed_generated_at"] as? String, "2026-09-23T10:04:48Z")
        XCTAssertEqual(object["unverifiable_fields"] as? [String], ["provider_id", "per_provider_context"])
    }

    func testPublicFeedURLDerivation() {
        XCTAssertEqual(
            ProviderVerifier.publicFeedURL(coordinatorURL: "wss://coordinator.malibu.tech/ws/provider")?.absoluteString,
            "https://coordinator.malibu.tech/v1/stats/routability"
        )
        XCTAssertEqual(
            ProviderVerifier.publicFeedURL(coordinatorURL: "ws://127.0.0.1:8088/ws")?.absoluteString,
            "http://127.0.0.1:8088/v1/stats/routability"
        )
        XCTAssertNil(ProviderVerifier.publicFeedURL(coordinatorURL: "ws://coordinator.example/ws"))
        XCTAssertNil(ProviderVerifier.publicFeedURL(coordinatorURL: "wss://user:pw@coordinator.example/ws"))
        XCTAssertNil(ProviderVerifier.publicFeedURL(coordinatorURL: nil))
    }

    func testDefaultTextOutputUsesPublicLanguage() async throws {
        let policyURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("public-language.json")
        let policy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: policyURL)) as? [String: Any])
        let terms = try XCTUnwrap(policy["terms"] as? [[String: Any]]).compactMap { $0["internal"] as? String }
        XCTAssertFalse(terms.isEmpty)
        for (networkState, hold) in [("buyer_serving", nil), ("not_buyer_serving", "catalog_material_missing"), ("not_buyer_serving", "model_admission_pending"), ("not_buyer_serving", nil)] as [(String, String?)] {
            let stub = HTTPStub(routes: [
                localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
                localStatusURL: (200, statusBody(networkState: networkState, hold: hold)),
                feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
            ])
            let text = ProviderVerifyFormatter.text(await verifier(stub, timeout: 0).run()).lowercased()
            for term in terms {
                XCTAssertFalse(text.contains(term), "\(term) leaked in:\n\(text)")
            }
            XCTAssertNil(text.range(of: "spec-?[0-9]+", options: .regularExpression), text)
        }
    }

    func testVerifyCommandParsesUnderProviderGroup() throws {
        let parsed = try MacProviderCLI.parseAsRoot(["provider", "verify", "--timeout", "30", "--json"])
        let verify = try XCTUnwrap(parsed as? ProviderVerifyCommand)
        XCTAssertEqual(verify.timeout, 30)
        XCTAssertTrue(verify.json)
    }

    // MARK: - Fixtures

    private var localStatusURL: String { "http://127.0.0.1:\(port)/v1/status" }
    private var localModelsURL: String { "http://127.0.0.1:\(port)/v1/models" }

    private func verifier(_ stub: HTTPStub, timeout: TimeInterval = 180) -> ProviderVerifier {
        let clock = TestClock(now)
        return ProviderVerifier(
            port: port,
            coordinatorURL: coordinatorURL,
            timeout: timeout,
            fetch: { url in try stub.respond(url) },
            now: { clock.now },
            sleep: { seconds in clock.advance(seconds) }
        )
    }

    private func modelsBody(_ ids: [String]) -> Data {
        let data = ids.map { ["id": $0, "object": "model"] }
        return try! JSONSerialization.data(withJSONObject: ["object": "list", "data": data])
    }

    private func statusBody(
        status: String = "ready",
        modelLoaded: Bool = true,
        networkState: String = "buyer_serving",
        hold: String? = nil
    ) -> Data {
        var body: [String: Any] = [
            "provider_id": "mp-studio",
            "status": status,
            "model": "mlx-community/Qwen3.6-27B-4bit",
            "model_loaded": modelLoaded,
            "model_hash": "ffffffffffff0000",
            "network_state": networkState,
            "service_instance": ["started_at": startedAt],
            "capacity": ["max_context_tokens": 200_000, "max_concurrency": 8],
            "coordinator": ["connected": true, "session": "s-1"],
            "catalog": [
                "release_id": "rel-2026-09-23",
                "catalog_key": "qwen/qwen3.6-27b",
                "model_id": "mlx-community/Qwen3.6-27B-4bit",
                "artifact_sha256": "518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931",
            ],
        ]
        body["buyer_serving_hold"] = hold ?? NSNull()
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func feedBody(generatedAt: String, modelContext: Int = 200_000, providerSlots: Int = 8) -> Data {
        let body: [String: Any] = [
            "generated_at": generatedAt,
            "stale_after": generatedAt,
            "summary": ["state": "operational"],
            "models": [
                [
                    "model_id": "mlx-community/Qwen3.6-27B-4bit",
                    "state": "operational",
                    "slots_total": providerSlots,
                    "max_context_tokens": modelContext,
                ],
            ],
            "providers": [
                [
                    "provider_ref": "provider_000001",
                    "model_id": "mlx-community/Qwen3.6-27B-4bit",
                    "routable": true,
                    "serving_capable": true,
                    "slots_total": providerSlots,
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

private final class HTTPStub: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (Int, Data)]
    private var counts: [String: Int] = [:]
    private var later: [String: (afterCalls: Int, response: (Int, Data))] = [:]

    init(routes: [String: (Int, Data)]) { self.routes = routes }

    func after(calls: Int, url: String, respond response: (Int, Data)) {
        lock.withLock { later[url] = (calls, response) }
    }

    func count(_ url: String) -> Int { lock.withLock { counts[url, default: 0] } }

    func respond(_ url: URL) throws -> (status: Int, body: Data) {
        try lock.withLock {
            let key = url.absoluteString
            counts[key, default: 0] += 1
            if let pending = later[key], counts[key, default: 0] > pending.afterCalls {
                return pending.response
            }
            guard let response = routes[key] else {
                throw URLError(.cannotConnectToHost)
            }
            return response
        }
    }
}
