import Darwin
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

    // MARK: - Deadline and redirects

    func testHangingEndpointIsCancelledAtTheDeadline() async throws {
        let verifier = ProviderVerifier(
            port: port,
            coordinatorURL: coordinatorURL,
            timeout: 1,
            fetch: { _ in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return (200, Data())
            }
        )
        let started = Date()

        let report = await verifier.run()

        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "--timeout bounds the whole run, including in-flight requests")
        XCTAssertEqual(report.outcome, .localNotReady)
    }

    func testTimeoutZeroChecksOnceWithinTheSinglePassBudget() async throws {
        let calls = LockedCounter()
        var verifier = ProviderVerifier(
            port: port,
            coordinatorURL: coordinatorURL,
            timeout: 0,
            fetch: { _ in
                calls.increment()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return (200, Data())
            }
        )
        verifier.singlePassBudget = 0.5
        let started = Date()

        let report = await verifier.run()

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(report.outcome, .localNotReady)
        XCTAssertEqual(calls.value, 1, "one pass: the local status request, cancelled at the budget")
    }

    func testNoRequestStartsAfterTheDeadline() async throws {
        let clock = TestClock(now)
        let deadline = now.addingTimeInterval(4)
        let lateStarts = LockedCounter()
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(status: "loading", modelLoaded: false)),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])
        let verifier = ProviderVerifier(
            port: port,
            coordinatorURL: coordinatorURL,
            timeout: 4,
            fetch: { url in
                if clock.now >= deadline { lateStarts.increment() }
                clock.advance(3)
                return try stub.respond(url)
            },
            now: { clock.now },
            sleep: { seconds in clock.advance(seconds) }
        )

        _ = await verifier.run()

        XCTAssertEqual(lateStarts.value, 0)
        XCTAssertGreaterThan(stub.count(localStatusURL), 0)
    }

    /// #1689 F1: a run that polls to its deadline reports the last layer
    /// state it observed, not a local failure from a fetch the deadline cut.
    func testDeadlineReportsTheLastObservedNetworkFailure() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(networkState: "catalog_update_required", connected: false)),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])

        let report = await verifier(stub, timeout: 5).run()

        XCTAssertEqual(report.outcome, .networkNotServing)
        XCTAssertEqual(report.exitCode, 3)
        XCTAssertEqual(report.layers.first?.state, .pass, "local is ready; the deadline must not relabel it")
        XCTAssertGreaterThan(stub.count(localStatusURL), 1, "verify still polls until the deadline")
    }

    /// Studio E2E round 2 (N2): an operator pause is named, not reported
    /// as an unexplained network state.
    func testOperatorPausedProviderSaysItIsPaused() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(networkState: "buyer_serving_unknown", lifecycleState: "paused_by_operator")),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])

        let report = await verifier(stub, timeout: 0).run()

        XCTAssertEqual(report.outcome, .networkNotServing)
        XCTAssertEqual(report.exitCode, 3)
        let network = try XCTUnwrap(report.layers.first { $0.layer == .network })
        XCTAssertEqual(network.state, .fail)
        XCTAssertEqual(network.reason, "paused by operator (resume it from Malibu or its control socket)")
        XCTAssertFalse(ProviderVerifyFormatter.text(report).contains("buyer_serving_unknown"))
    }

    /// Studio E2E round 3 (N4): a paused serve reports `status: unavailable`;
    /// the local layer names the pause and the outcome is not-serving (exit 3),
    /// not local-not-ready (exit 2).
    func testOperatorPausedServeWithUnavailableStatusIsNotServingNotLocalNotReady() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (503, Data(#"{"error":{"code":"provider_paused"}}"#.utf8)),
            localStatusURL: (200, statusBody(status: "unavailable", networkState: "not_buyer_serving", lifecycleState: "paused_by_operator")),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])

        let report = await verifier(stub, timeout: 0).run()

        XCTAssertEqual(report.outcome, .networkNotServing)
        XCTAssertEqual(report.exitCode, 3)
        let local = try XCTUnwrap(report.layers.first { $0.layer == .local })
        XCTAssertEqual(local.state, .fail)
        XCTAssertEqual(local.reason, "paused by operator (resume it from Malibu or its control socket)")
        let text = ProviderVerifyFormatter.text(report)
        XCTAssertTrue(text.contains("Not verified: Local provider — paused by operator"), text)
        XCTAssertFalse(text.contains("status is unavailable"), text)
    }

    /// A serve that is not loaded is still local-not-ready even if a stale
    /// lifecycle record says paused: only a loaded, paused serve is exempt.
    func testUnloadedServeIsLocalNotReadyEvenWhenLifecycleSaysPaused() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (503, Data(#"{"error":{"code":"model_not_loaded"}}"#.utf8)),
            localStatusURL: (200, statusBody(status: "unavailable", modelLoaded: false, networkState: "not_buyer_serving", lifecycleState: "paused_by_operator")),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])

        let report = await verifier(stub, timeout: 0).run()

        XCTAssertEqual(report.outcome, .localNotReady)
        XCTAssertEqual(report.exitCode, 2)
    }

    func testDeadlineOnAStaleFeedIsTheFeedTimeout() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody()),
            feedURL: (503, Data(#"{"error":{"code":"stats_stale"}}"#.utf8)),
        ])

        let report = await verifier(stub, timeout: 30).run()

        XCTAssertEqual(report.outcome, .timeout)
        XCTAssertEqual(report.exitCode, 5)
    }

    /// An evaluation the deadline cuts short is discarded for the last
    /// complete one.
    func testEvaluationCutByTheDeadlineKeepsThePreviousReport() async throws {
        let clock = TestClock(now)
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(networkState: "catalog_update_required", connected: false)),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])
        let verifier = ProviderVerifier(
            port: port,
            coordinatorURL: coordinatorURL,
            timeout: 12,
            fetch: { url in
                clock.advance(3)
                return try stub.respond(url)
            },
            now: { clock.now },
            sleep: { seconds in clock.advance(seconds) }
        )

        let report = await verifier.run()

        XCTAssertEqual(stub.count(localStatusURL), 2, "a second evaluation started before the deadline")
        XCTAssertEqual(report.outcome, .networkNotServing)
        XCTAssertEqual(report.exitCode, 3)
    }

    func testRedirectIsNotFollowed() async throws {
        let target = try LoopbackHTTPResponder(response: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        defer { target.stop() }
        let redirect = try LoopbackHTTPResponder(
            response: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(target.port)/v1/status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
        defer { redirect.stop() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(redirect.port)/v1/status"))
        let (code, _) = try await ProviderVerifier.urlSessionFetch(url)

        XCTAssertEqual(code, 302, "the redirect response is returned, not followed")
        XCTAssertEqual(target.connections, 0, "the redirect target is never contacted")
    }

    func testResponseForAnotherURLIsRejected() throws {
        let requested = try XCTUnwrap(URL(string: "https://coordinator.example/v1/stats/routability"))
        let other = try XCTUnwrap(URL(string: "https://elsewhere.example/v1/stats/routability"))
        let response = try XCTUnwrap(HTTPURLResponse(url: other, statusCode: 200, httpVersion: nil, headerFields: nil))

        XCTAssertThrowsError(try ProviderVerifier.checkedResponse(requested: requested, response: response, body: Data()))
        let same = try XCTUnwrap(HTTPURLResponse(url: requested, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertEqual(try ProviderVerifier.checkedResponse(requested: requested, response: same, body: Data("x".utf8)).status, 200)
    }

    /// #1689 L1: an unverifiable feed layer is terminal, so it does not use
    /// the pending glyph.
    func testUnverifiableLayerDoesNotUseThePendingGlyph() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(coordinatorOrigin: nil)),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])

        let report = await verifier(stub, timeout: 0).run()
        let text = ProviderVerifyFormatter.text(report)

        XCTAssertEqual(report.layers.last?.state, .unverifiable)
        XCTAssertTrue(text.contains("  ? Public feed:"), text)
        XCTAssertFalse(text.contains("… Public feed:"), text)
    }

    func testExpectedDefaultContextRequiresTheDefaultSource() async throws {
        let expected = ProviderVerifier.ExpectedContext(tokens: 200_000, source: .ramTierDefault)
        let operatorValue = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(contextSource: "operator_config")),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])
        var stale = verifier(operatorValue, timeout: 0)
        stale.expectedContext = expected
        let staleReport = await stale.run()
        XCTAssertEqual(staleReport.layers.first?.state, .fail)
        XCTAssertTrue(staleReport.layers.first?.reason.contains("waiting for ram_tier_default") == true, staleReport.layers.first?.reason ?? "")

        let defaultValue = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(contextSource: "ram_tier_default")),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])
        var fresh = verifier(defaultValue, timeout: 0)
        fresh.expectedContext = expected
        let freshReport = await fresh.run()
        XCTAssertEqual(freshReport.outcome, .agree)
    }

    /// #1689 R5: an SSH shell whose config or MACPROVIDER_COORDINATOR_URL
    /// names another coordinator must not decide which public feed proves the
    /// running provider; the running serve reports its own coordinator origin.
    func testFeedIsCheckedAgainstTheRunningProvidersCoordinatorNotThisShells() async throws {
        let stagingFeed = "https://staging.example/v1/stats/routability"
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(coordinatorOrigin: "wss://coordinator.example")),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
            stagingFeed: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z", providerSlots: 1)),
        ])
        var verifier = verifier(stub)
        verifier.coordinatorURL = "wss://staging.example/ws/provider"

        let report = await verifier.run()

        XCTAssertEqual(report.outcome, .agree, ProviderVerifyFormatter.text(report))
        XCTAssertEqual(stub.count(feedURL), 1)
        XCTAssertEqual(stub.count(stagingFeed), 0, "this shell's coordinator is never the proof")
    }

    func testRunningProviderWithoutCoordinatorOriginIsNeverAgree() async throws {
        let stub = HTTPStub(routes: [
            localModelsURL: (200, modelsBody(["mlx-community/Qwen3.6-27B-4bit"])),
            localStatusURL: (200, statusBody(coordinatorOrigin: nil)),
            feedURL: (200, feedBody(generatedAt: "2026-09-23T10:04:48Z")),
        ])

        let report = await verifier(stub, timeout: 60).run()

        XCTAssertNotEqual(report.outcome, .agree)
        XCTAssertNotEqual(report.exitCode, 0)
        XCTAssertEqual(report.layers.last?.state, .unverifiable)
        XCTAssertEqual(stub.count(feedURL), 0, "the shell's coordinator is not checked in its place")
        let text = ProviderVerifyFormatter.text(report)
        XCTAssertTrue(text.contains("running provider does not report its coordinator"), text)
        XCTAssertTrue(text.contains("this shell's config names wss://coordinator.example"), text)
    }

    func testCoordinatorOriginNormalizationStripsUserinfoPathAndQuery() {
        XCTAssertEqual(
            ProviderVerifier.coordinatorOrigin("wss://user:pw@Coordinator.Malibu.Tech:8443/ws/provider?token=x#f"),
            "wss://coordinator.malibu.tech:8443"
        )
        XCTAssertEqual(ProviderVerifier.coordinatorOrigin(" ws://127.0.0.1:8088/ws "), "ws://127.0.0.1:8088")
        XCTAssertEqual(ProviderVerifier.coordinatorOrigin("HTTPS://coordinator.example"), "https://coordinator.example")
        XCTAssertNil(ProviderVerifier.coordinatorOrigin("ftp://coordinator.example"))
        XCTAssertNil(ProviderVerifier.coordinatorOrigin("not a url"))
        XCTAssertNil(ProviderVerifier.coordinatorOrigin(nil))
    }

    func testStatusResponseAdvertisesTheServesCoordinatorOrigin() async throws {
        let status = ProviderStatus(modelID: "model-a", modelLoaded: true, capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil))
        let snapshot = await status.snapshot()
        let body = RouterHandler.statusResponse(snapshot, providerID: "p", coordinatorURL: "wss://user:pw@coordinator.example/ws/provider?x=1")

        let contract = try XCTUnwrap(body["local_status_contract"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(contract["capabilities"] as? [String]).contains("coordinator_origin_v1"))
        XCTAssertEqual(body["coordinator_origin"] as? String, "wss://coordinator.example")

        let unset = RouterHandler.statusResponse(snapshot, providerID: "p", coordinatorURL: nil)
        XCTAssertTrue(unset["coordinator_origin"] is NSNull)
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
        hold: String? = nil,
        connected: Bool = true,
        contextSource: String? = nil,
        coordinatorOrigin: String? = "wss://coordinator.example",
        lifecycleState: String? = nil
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
            "coordinator": ["connected": connected, "session": "s-1"],
            "catalog": [
                "release_id": "rel-2026-09-23",
                "catalog_key": "qwen/qwen3.6-27b",
                "model_id": "mlx-community/Qwen3.6-27B-4bit",
                "artifact_sha256": "518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931",
            ],
        ]
        body["buyer_serving_hold"] = hold ?? NSNull()
        if let lifecycleState {
            body["lifecycle"] = ["record_state": "valid", "state": lifecycleState]
        }
        if let coordinatorOrigin {
            body["local_status_contract"] = ["version": 1, "capabilities": ["coordinator_origin_v1"]]
            body["coordinator_origin"] = coordinatorOrigin
        }
        if let contextSource {
            body["capacity"] = ["max_context_tokens": 200_000, "max_concurrency": 8, "max_context_source": contextSource]
        }
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Answers every loopback connection with one fixed HTTP response.
private final class LoopbackHTTPResponder: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var accepted = 0
    var connections: Int { lock.withLock { accepted } }

    init(response: String) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw URLError(.cannotCreateFile) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { close(listener); throw URLError(.cannotConnectToHost) }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        fd = listener
        port = Int(UInt16(bigEndian: address.sin_port))
        let bytes = Array(response.utf8)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                self?.lock.withLock { self?.accepted += 1 }
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = read(client, &buffer, buffer.count)
                _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, bytes.count) }
                close(client)
            }
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}
