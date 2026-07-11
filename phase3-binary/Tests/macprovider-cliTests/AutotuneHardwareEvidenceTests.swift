import Darwin
import Foundation
import MacProviderCore
@testable import macprovider_cli
import XCTest

final class AutotuneHardwareEvidenceTests: XCTestCase {
    func testEndpointConvertsCoordinatorWebSocketURL() {
        let url = AutotuneHardwareEvidenceSubmitter.hardwareEvidenceEndpoint(
            from: "wss://coordinator.streamvc.live/v2/provider?x=1"
        )
        XCTAssertEqual(url?.absoluteString, "https://coordinator.streamvc.live/v1/providers/hardware-evidence")
    }

    func testEndpointRejectsCleartextCoordinatorURL() {
        XCTAssertNil(AutotuneHardwareEvidenceSubmitter.hardwareEvidenceEndpoint(from: "http://coordinator.streamvc.live/v2/provider"))
        XCTAssertNil(AutotuneHardwareEvidenceSubmitter.hardwareEvidenceEndpoint(from: "ws://coordinator.streamvc.live/v2/provider"))
    }

    func testPayloadIncludesHardwareAndBenchmarks() throws {
        let fixture = makeFixture()
        let generatedAt = fixture.result.generatedAt

        let data = try AutotuneHardwareEvidenceSubmitter.payloadData(
            providerID: "mac",
            result: fixture.result,
            benchmarks: fixture.benchmarks
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["schema_version"] as? String, "hardware_evidence.autotune.v1")
        XCTAssertEqual(object?["provider_id"] as? String, "mac")
        XCTAssertEqual(object?["generated_at"] as? String, ISO8601DateFormatter.autotuneInternet.string(from: generatedAt))
        let hardware = object?["hardware"] as? [String: Any]
        XCTAssertEqual(hardware?["chip"] as? String, "Apple M5")
        XCTAssertEqual(hardware?["memory_gb"] as? Int, 32)
        let benchmarks = object?["benchmarks"] as? [[String: Any]]
        XCTAssertEqual(benchmarks?.first?["model_key"] as? String, "model-a")
        XCTAssertEqual(benchmarks?.first?["sustained_tps"] as? Double, 42.5)
    }

    func testCanonicalPayloadRetainsCrossLanguageEvidenceSHA() throws {
        let payload = try AutotuneHardwareEvidenceSubmitter.canonicalPayload(
            providerID: "mac",
            snapshot: makeFixture().snapshot
        )

        XCTAssertEqual(
            payload.evidenceSHA,
            "47e9892f2f2c986d4d58389bdf209a9e56b2bd92095720845331bc09758065bf"
        )
        XCTAssertEqual(
            payload.data,
            try AutotuneHardwareEvidenceSubmitter.payloadData(
                providerID: "mac",
                snapshot: makeFixture().snapshot
            )
        )
    }

    func testSuccessResponseRequiresExactCanonicalSubmissionBinding() throws {
        let sha = try AutotuneHardwareEvidenceSubmitter.canonicalPayload(
            providerID: "mac",
            snapshot: makeFixture().snapshot
        ).evidenceSHA

        for status in AutotuneHardwareEvidenceSubmitter.acceptedResponseStatuses {
            let response = responseData(status: status, providerID: "mac", jobID: 7, evidenceSHA: sha)
            XCTAssertEqual(
                AutotuneHardwareEvidenceSubmitter.validateSuccessResponse(
                    response,
                    expectedProviderID: "mac",
                    expectedEvidenceSHA: sha
                ),
                .submitted,
                status
            )
        }

        let invalidResponses: [(String, Data)] = [
            ("empty", Data()),
            ("malformed", Data("not-json".utf8)),
            ("misrouted", responseData(status: "queued", providerID: "other", jobID: 7, evidenceSHA: sha)),
            ("mismatched digest", responseData(status: "queued", providerID: "mac", jobID: 7, evidenceSHA: String(repeating: "0", count: 64))),
            ("invalid job", responseData(status: "queued", providerID: "mac", jobID: 0, evidenceSHA: sha)),
            ("unknown status", responseData(status: "accepted", providerID: "mac", jobID: 7, evidenceSHA: sha)),
            ("missing field", Data("{\"status\":\"queued\",\"provider_id\":\"mac\",\"job_id\":7}".utf8)),
            ("extra field", Data("{\"status\":\"queued\",\"provider_id\":\"mac\",\"job_id\":7,\"evidence_sha\":\"\(sha)\",\"extra\":true}".utf8)),
        ]
        for (name, response) in invalidResponses {
            guard case .failed = AutotuneHardwareEvidenceSubmitter.validateSuccessResponse(
                response,
                expectedProviderID: "mac",
                expectedEvidenceSHA: sha
            ) else {
                return XCTFail("\(name) success response was accepted")
            }
        }
    }

    func testFreshRecommendationSubmitsPersistedEvidence() async {
        let snapshot = makeFixture().snapshot
        var submitted: AutotuneHardwareEvidenceSnapshot?

        let outcome = await AutotuneCommand.freshRecommendationEvidenceOutcome(
            storedEvidence: snapshot,
            submitEnabled: true,
            submit: { evidence in
                submitted = evidence
                return .submitted
            }
        )

        XCTAssertEqual(outcome, .ready(submitted: true))
        XCTAssertEqual(submitted, snapshot)
    }

    func testFreshRecommendationWithoutPersistedEvidenceRequiresNormalRecommendation() async {
        var submitCalled = false

        let outcome = await AutotuneCommand.freshRecommendationEvidenceOutcome(
            storedEvidence: nil,
            submitEnabled: true,
            submit: { _ in
                submitCalled = true
                return .submitted
            }
        )

        XCTAssertEqual(outcome, .rerunRecommendation("stored hardware evidence is missing"))
        XCTAssertFalse(submitCalled)
    }

    func testFreshRecommendationBlocksWhenCredentialsAreMissing() async {
        let outcome = await AutotuneCommand.freshRecommendationEvidenceOutcome(
            storedEvidence: makeFixture().snapshot,
            submitEnabled: true,
            submit: { _ in .skipped("provider_token missing") }
        )

        XCTAssertEqual(outcome, .blocked("provider_token missing"))
    }

    func testSnapshotSubmitterSkipsBeforeNetworkWhenProviderTokenIsMissing() async {
        var config = AppConfig.defaults()
        config.providerID = "mac"
        config.coordinatorURL = "wss://coordinator.streamvc.live/v2/provider"

        let submission = await AutotuneHardwareEvidenceSubmitter(config: config).submit(
            snapshot: makeFixture().snapshot
        )

        XCTAssertEqual(submission, .skipped("provider_token missing"))
    }

    func testFreshRecommendationBlocksWhenSubmissionFails() async {
        let outcome = await AutotuneCommand.freshRecommendationEvidenceOutcome(
            storedEvidence: makeFixture().snapshot,
            submitEnabled: true,
            submit: { _ in .failed("HTTP 503") }
        )

        XCTAssertEqual(outcome, .blocked("HTTP 503"))
    }

    func testFreshRecommendationAllowsExplicitEvidenceOptOut() async {
        var submitCalled = false
        let outcome = await AutotuneCommand.freshRecommendationEvidenceOutcome(
            storedEvidence: nil,
            submitEnabled: false,
            submit: { _ in
                submitCalled = true
                return .submitted
            }
        )

        XCTAssertEqual(outcome, .ready(submitted: false))
        XCTAssertFalse(submitCalled)
    }

    func testRequiredHardwareEvidenceBlocksSkippedOrFailedSubmission() {
        XCTAssertEqual(
            AutotuneCommand.requiredHardwareEvidenceBlockReason(
                submission: .skipped("provider_token missing"),
                required: true
            ),
            "provider_token missing"
        )
        XCTAssertEqual(
            AutotuneCommand.requiredHardwareEvidenceBlockReason(
                submission: .failed("HTTP 503"),
                required: true
            ),
            "HTTP 503"
        )
    }

    func testOrdinaryRecommendationKeepsSubmissionOptional() {
        XCTAssertNil(
            AutotuneCommand.requiredHardwareEvidenceBlockReason(
                submission: .failed("HTTP 503"),
                required: false
            )
        )
    }

    func testStoredEvidenceRetainsImmutableMeasurementTimestamp() throws {
        let fixture = makeFixture()
        let replayData = try AutotuneHardwareEvidenceSubmitter.payloadData(
            providerID: "mac",
            snapshot: fixture.snapshot
        )
        let initialData = try AutotuneHardwareEvidenceSubmitter.payloadData(
            providerID: "mac",
            result: fixture.result,
            benchmarks: fixture.benchmarks
        )
        let object = try JSONSerialization.jsonObject(with: replayData) as? [String: Any]
        let benchmarks = object?["benchmarks"] as? [[String: Any]]

        XCTAssertEqual(replayData, initialData)
        XCTAssertEqual(object?["generated_at"] as? String, ISO8601DateFormatter.autotuneInternet.string(from: fixture.result.generatedAt))
        XCTAssertEqual(
            benchmarks?.first?["generated_at"] as? String,
            ISO8601DateFormatter.autotuneInternet.string(from: fixture.result.generatedAt)
        )
    }

    func testNormalRecommendationStatePersistsReusableEvidence() throws {
        let fixture = makeFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autotune-hardware-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("last-recommendation.json")

        try RecommendationStateStore.write(
            fixture.result,
            benchmarks: fixture.benchmarks,
            to: stateURL
        )
        let stored = try RecommendationStateStore.read(from: stateURL)

        XCTAssertEqual(stored.hardwareEvidence, fixture.snapshot)
    }

    func testRecommendationStateUsesPrivateDirectoryAndFilePermissions() throws {
        let fixture = makeFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autotune-hardware-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("nested/last-recommendation.json")

        try RecommendationStateStore.write(fixture.result, benchmarks: fixture.benchmarks, to: stateURL)

        var directoryStat = stat()
        var fileStat = stat()
        XCTAssertEqual(lstat(stateURL.deletingLastPathComponent().path, &directoryStat), 0)
        XCTAssertEqual(lstat(stateURL.path, &fileStat), 0)
        XCTAssertEqual(directoryStat.st_mode & 0o777, 0o700)
        XCTAssertEqual(fileStat.st_mode & 0o777, 0o600)

        XCTAssertEqual(chmod(stateURL.path, 0o644), 0)
        _ = try RecommendationStateStore.read(from: stateURL)
        XCTAssertEqual(lstat(stateURL.path, &fileStat), 0)
        XCTAssertEqual(fileStat.st_mode & 0o777, 0o600)

        XCTAssertEqual(chmod(stateURL.path, 0o660), 0)
        XCTAssertThrowsError(try RecommendationStateStore.read(from: stateURL))
    }

    func testRecommendationStateRejectsSymlinkRead() throws {
        let fixture = makeFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autotune-hardware-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let realURL = directory.appendingPathComponent("real.json")
        let linkURL = directory.appendingPathComponent("last-recommendation.json")
        try RecommendationStateStore.write(fixture.result, benchmarks: fixture.benchmarks, to: realURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        XCTAssertThrowsError(try RecommendationStateStore.read(from: linkURL))
        XCTAssertThrowsError(
            try RecommendationStateStore.write(fixture.result, benchmarks: fixture.benchmarks, to: linkURL)
        )
    }

    private func makeFixture() -> (
        result: AutotuneRecommendResult,
        benchmarks: [String: CandidateBenchmark],
        snapshot: AutotuneHardwareEvidenceSnapshot
    ) {
        let generatedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let result = AutotuneRecommendResult(
            generatedAt: generatedAt,
            hardware: AutotuneRecommendHardware(
                machine: nil,
                chip: "Apple M5",
                memoryGB: 32,
                bandwidthTier: .c,
                osVersion: "15.5",
                binaryVersion: "1.7.9",
                diversificationID: "div",
                hardwareIdentityHash: "hash"
            ),
            rateCardVersion: "rates.v1",
            demandRankVersion: "demand.v1",
            candidateCatalogVersion: "catalog.v1",
            candidateCatalogSHA256: String(repeating: "a", count: 64),
            benchmarkID: nil,
            benchmarkGeneratedAt: nil,
            recommendedModel: "model-a",
            promptRatePerMillionTokens: nil,
            completionRatePerMillionTokens: nil,
            selectedCandidate: nil,
            candidates: [],
            allCandidates: [],
            defaultModel: nil,
            donorFallbackModel: nil,
            donorFallbackCandidate: nil,
            warnings: []
        )
        let benchmark = CandidateBenchmark(
            modelKey: "model-a",
            sustainedTPS: 42.5,
            ttftMS: 1200,
            swapDetected: false,
            thermalThrottleDetected: false,
            artifactSHA256: String(repeating: "b", count: 64),
            modelArtifactPath: "/tmp/model",
            benchmarkID: "bench-1",
            generatedAt: generatedAt,
            candidateCatalogSHA256: String(repeating: "a", count: 64),
            binaryVersion: "1.7.9",
            modelID: "mlx-community/model-a",
            hardwareIdentityHash: "hash",
            candidateRowIdentity: String(repeating: "c", count: 64)
        )
        let benchmarks = ["model-a": benchmark]
        return (
            result,
            benchmarks,
            AutotuneHardwareEvidenceSnapshot(result: result, benchmarks: benchmarks)
        )
    }

    private func responseData(status: String, providerID: String, jobID: Int64, evidenceSHA: String) -> Data {
        Data(
            "{\"status\":\"\(status)\",\"provider_id\":\"\(providerID)\",\"job_id\":\(jobID),\"evidence_sha\":\"\(evidenceSHA)\"}".utf8
        )
    }
}
