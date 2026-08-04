import Darwin
import Foundation
import MacProviderCore
import Security
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
        XCTAssertEqual(object?["schema_version"] as? String, "hardware_evidence.autotune.v2")
        XCTAssertEqual(object?["provider_id"] as? String, "mac")
        XCTAssertEqual(object?["generated_at"] as? String, ISO8601DateFormatter.autotuneInternet.string(from: generatedAt))
        let hardware = object?["hardware"] as? [String: Any]
        XCTAssertEqual(hardware?["chip"] as? String, "Apple M5")
        XCTAssertEqual(hardware?["memory_gb"] as? Int, 32)
        let benchmarks = object?["benchmarks"] as? [[String: Any]]
        XCTAssertEqual(benchmarks?.first?["model_key"] as? String, "model-a")
        XCTAssertEqual(benchmarks?.first?["sustained_tps"] as? Double, 42.5)
        XCTAssertEqual(benchmarks?.first?["model_artifact_path"] as? String, "/tmp/model")
    }

    func testCanonicalPayloadRetainsCrossLanguageEvidenceSHA() throws {
        let payload = try AutotuneHardwareEvidenceSubmitter.canonicalPayload(
            providerID: "mac",
            snapshot: makeFixture().snapshot
        )

        // Golden updated for #745: benchmarks now include model_artifact_path.
        XCTAssertEqual(
            payload.evidenceSHA,
            "1c477957d51a8064a311f55b8ae86c963d83737c7d276a6a44e87e0a0fb350b7"
        )
        XCTAssertEqual(
            payload.data,
            try AutotuneHardwareEvidenceSubmitter.payloadData(
                providerID: "mac",
                snapshot: makeFixture().snapshot
            )
        )
    }

    func testCanonicalPayloadRejectsNonLowercaseSHA256Bindings() throws {
        var snapshot = makeFixture().snapshot
        snapshot.hardware.executableSHA256 = String(repeating: "A", count: 64)
        XCTAssertThrowsError(
            try AutotuneHardwareEvidenceSubmitter.canonicalPayload(
                providerID: "mac",
                snapshot: snapshot
            )
        )

        snapshot = makeFixture().snapshot
        snapshot.benchmarks[0].candidateRowIdentity = String(repeating: "a", count: 63) + "Ａ"
        XCTAssertThrowsError(
            try AutotuneHardwareEvidenceSubmitter.canonicalPayload(
                providerID: "mac",
                snapshot: snapshot
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

    func testSnapshotSubmitterFailsClosedBeforeNetworkWhenKeychainCredentialIsMissing() async throws {
        let config = try makeTokenlessConfig(providerID: "mac")

        let submission = await AutotuneHardwareEvidenceSubmitter(
            config: config,
            credentialStore: InMemoryProviderCredentialStore()
        ).submit(
            snapshot: makeFixture().snapshot
        )

        XCTAssertEqual(
            submission,
            .failed("provider credential unavailable (condition=missing action=restore_or_reenroll)")
        )
    }

    func testResultSubmitterFailsClosedBeforeNetworkOnCatalogFallbackEvidence() async {
        let fixture = makeFixture()
        var result = fixture.result
        result.warnings = [.candidateCatalogFallbackUsed]

        let submission = await AutotuneHardwareEvidenceSubmitter(
            config: try? makeTokenlessConfig(providerID: "mac"),
            credentialStore: InMemoryProviderCredentialStore()
        ).submit(result: result, benchmarks: fixture.benchmarks)

        guard case .failed(let reason) = submission else {
            return XCTFail("expected failed submission, got \(submission)")
        }
        XCTAssertTrue(reason.contains("signed live catalog unavailable"), reason)
        XCTAssertTrue(reason.contains("candidate_catalog_fallback_used"), reason)
        XCTAssertTrue(reason.contains("cannot be submitted"), reason)
    }

    func testInitialRecommendationHydratesTokenlessConfigFromKeychainBeforeEvidenceSubmission() async throws {
        let providerID = "mp-0123456789abcdef0123456789abcdef"
        let token = "keychain-bootstrap-bearer"
        let fixture = makeFixture()
        let expectedSHA = try AutotuneHardwareEvidenceSubmitter.canonicalPayload(
            providerID: providerID,
            snapshot: AutotuneHardwareEvidenceSnapshot(result: fixture.result, benchmarks: fixture.benchmarks)
        ).evidenceSHA
        let config = try makeTokenlessConfig(providerID: providerID)
        let session = evidenceSession { request in
            XCTAssertEqual(request.url?.path, AutotuneHardwareEvidenceSubmitter.endpointPath)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            return Self.successResponse(
                for: request,
                data: self.responseData(
                    status: "queued",
                    providerID: providerID,
                    jobID: 7,
                    evidenceSHA: expectedSHA
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            AutotuneHardwareEvidenceMockURLProtocol.requestHandler = nil
        }

        let submission = await AutotuneHardwareEvidenceSubmitter(
            config: config,
            credentialStore: InMemoryProviderCredentialStore(values: [providerID: token]),
            session: session
        ).submit(result: fixture.result, benchmarks: fixture.benchmarks)

        XCTAssertEqual(submission, .submitted)
        try assertConfigRemainsTokenless(config, bearer: token)
    }

    func testFreshnessResubmissionHydratesTokenlessConfigFromKeychain() async throws {
        let providerID = "mp-fedcba9876543210fedcba9876543210"
        let token = "keychain-freshness-bearer"
        let fixture = makeFixture()
        let expectedSHA = try AutotuneHardwareEvidenceSubmitter.canonicalPayload(
            providerID: providerID,
            snapshot: fixture.snapshot
        ).evidenceSHA
        let config = try makeTokenlessConfig(providerID: providerID)
        let session = evidenceSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            return Self.successResponse(
                for: request,
                data: self.responseData(
                    status: "existing",
                    providerID: providerID,
                    jobID: 8,
                    evidenceSHA: expectedSHA
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            AutotuneHardwareEvidenceMockURLProtocol.requestHandler = nil
        }
        let submitter = AutotuneHardwareEvidenceSubmitter(
            config: config,
            credentialStore: InMemoryProviderCredentialStore(values: [providerID: token]),
            session: session
        )

        let outcome = await AutotuneCommand.freshRecommendationEvidenceOutcome(
            storedEvidence: fixture.snapshot,
            submitEnabled: true,
            submit: { evidence in
                await submitter.submit(snapshot: evidence)
            }
        )

        XCTAssertEqual(outcome, .ready(submitted: true))
        try assertConfigRemainsTokenless(config, bearer: token)
    }

    func testEvidenceSubmissionFailsClosedForLockedMissingAndConflictingKeychain() async throws {
        let providerID = "mp-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let session = evidenceSession { request in
            XCTFail("credential failure must stop before network request: \(request)")
            return Self.successResponse(for: request, data: Data())
        }
        defer {
            session.invalidateAndCancel()
            AutotuneHardwareEvidenceMockURLProtocol.requestHandler = nil
        }
        let snapshot = makeFixture().snapshot
        let tokenlessConfig = try makeTokenlessConfig(providerID: providerID)

        let locked = await AutotuneHardwareEvidenceSubmitter(
            config: tokenlessConfig,
            credentialStore: InMemoryProviderCredentialStore(
                loadError: ProviderCredentialStoreError.readFailed(
                    providerID: providerID,
                    status: errSecInteractionNotAllowed
                )
            ),
            session: session
        ).submit(snapshot: snapshot)
        XCTAssertEqual(
            locked,
            .failed("provider credential unavailable (condition=locked action=unlock_keychain)")
        )

        let missing = await AutotuneHardwareEvidenceSubmitter(
            config: tokenlessConfig,
            credentialStore: InMemoryProviderCredentialStore(),
            session: session
        ).submit(snapshot: snapshot)
        XCTAssertEqual(
            missing,
            .failed("provider credential unavailable (condition=missing action=restore_or_reenroll)")
        )

        var conflictingConfig = tokenlessConfig
        conflictingConfig.providerToken = "stale-config-bearer"
        let conflict = await AutotuneHardwareEvidenceSubmitter(
            config: conflictingConfig,
            credentialStore: InMemoryProviderCredentialStore(values: [providerID: "authoritative-keychain-bearer"]),
            session: session
        ).submit(snapshot: snapshot)
        XCTAssertEqual(
            conflict,
            .failed("provider credential unavailable (condition=conflict action=restore_or_reenroll)")
        )
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
        let runtimeSnapshot = AutotuneHardwareEvidenceSnapshot(
            result: fixture.result,
            benchmarks: fixture.benchmarks
        )
        let replayData = try AutotuneHardwareEvidenceSubmitter.payloadData(
            providerID: "mac",
            snapshot: runtimeSnapshot
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

        XCTAssertEqual(
            stored.hardwareEvidence,
            AutotuneHardwareEvidenceSnapshot(result: fixture.result, benchmarks: fixture.benchmarks)
        )
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
            AutotuneHardwareEvidenceSnapshot(
                result: result,
                benchmarks: benchmarks,
                executableSHA256: String(repeating: "d", count: 64)
            )
        )
    }

    private func responseData(status: String, providerID: String, jobID: Int64, evidenceSHA: String) -> Data {
        Data(
            "{\"status\":\"\(status)\",\"provider_id\":\"\(providerID)\",\"job_id\":\(jobID),\"evidence_sha\":\"\(evidenceSHA)\"}".utf8
        )
    }

    private func makeTokenlessConfig(providerID: String) throws -> AppConfig {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenless-autotune-config-\(UUID().uuidString).yaml")
        let yaml = """
        provider_id: "\(providerID)"
        coordinator_url: "wss://coordinator.streamvc.live/ws/provider"
        """
        try Data(yaml.utf8).write(to: configURL, options: .atomic)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: configURL)
        }
        return try ConfigLoader.load(
            cli: CLIOverrides(configPath: configURL.path),
            environment: [:]
        )
    }

    private func assertConfigRemainsTokenless(_ config: AppConfig, bearer: String) throws {
        let yaml = try String(contentsOfFile: config.configPath, encoding: .utf8)
        XCTAssertFalse(yaml.contains("provider_token"))
        XCTAssertFalse(yaml.contains(bearer))
    }

    private func evidenceSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        AutotuneHardwareEvidenceMockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutotuneHardwareEvidenceMockURLProtocol.self]
        return URLSession(
            configuration: configuration,
            delegate: NoRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    private static func successResponse(for request: URLRequest, data: Data) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }
}

private final class AutotuneHardwareEvidenceMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
