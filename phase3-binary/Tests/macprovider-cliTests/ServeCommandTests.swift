import ArgumentParser
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ServeCommandTests: XCTestCase {
    func testReferralCodeAcceptsShortAndLongOptionNames() throws {
        let short = try ServeCommand.parse(["--ref", "MAL1-S-k1-seed-AAAAAAAAAAAAAAAAAAAAAAAAAA"])
        XCTAssertEqual(short.referralCode, "MAL1-S-k1-seed-AAAAAAAAAAAAAAAAAAAAAAAAAA")

        let long = try ServeCommand.parse(["--referral-code", "MAL1-P-k1-issuer-BBBBBBBBBBBBBBBBBBBBBBBBBB"])
        XCTAssertEqual(long.referralCode, "MAL1-P-k1-issuer-BBBBBBBBBBBBBBBBBBBBBBBBBB")
    }

    func testProviderTokenCanBeReadFromInheritedFileDescriptor() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("fd-token\n".utf8))
        try pipe.fileHandleForWriting.close()

        let token = try ServeCommand.readProviderToken(
            fromFileDescriptor: pipe.fileHandleForReading.fileDescriptor
        )

        XCTAssertEqual(token, "fd-token")
        try pipe.fileHandleForReading.close()
    }

    func testServeCommandRejectsInlineProviderTokenArguments() throws {
        let deprecated = try ServeCommand.parse(["--token", "secret"])
        XCTAssertThrowsError(try ConfigLoader.load(cli: CLIOverrides(providerToken: deprecated.providerToken), environment: [:])) { error in
            XCTAssertTrue(String(describing: error).contains("--provider-token"))
        }

        let legacy = try ServeCommand.parse(["--provider-token", "secret"])
        XCTAssertThrowsError(try ConfigLoader.load(cli: CLIOverrides(providerToken: legacy.providerToken), environment: [:])) { error in
            XCTAssertTrue(String(describing: error).contains("--provider-token"))
        }
    }

    func testConfigLoaderReadsProviderTokenFromPrivateTokenFile() throws {
        let dir = try tempDir()
        let tokenFile = dir.appendingPathComponent("token")
        try "file-token\n".write(to: tokenFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)

        let config = try ConfigLoader.load(cli: CLIOverrides(providerTokenFile: tokenFile.path), environment: [:])

        XCTAssertEqual(config.providerToken, "file-token")
    }

    func testConfigLoaderRejectsWorldReadableProviderTokenFile() throws {
        let dir = try tempDir()
        let tokenFile = dir.appendingPathComponent("token")
        try "file-token\n".write(to: tokenFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenFile.path)

        XCTAssertThrowsError(try ConfigLoader.load(cli: CLIOverrides(providerTokenFile: tokenFile.path), environment: [:]))
    }

    func testNoJoinFlagParses() throws {
        let command = try ServeCommand.parse([
            "--no-join",
            "--model", "model-a",
            "--port", "18080",
        ])

        XCTAssertTrue(command.noJoin)
        XCTAssertEqual(command.model, "model-a")
        XCTAssertEqual(command.port, 18080)
    }

    func testEnableReceiptsFlagParses() throws {
        let command = try ServeCommand.parse([
            "--enable-receipts",
            "--model", "model-a",
        ])

        XCTAssertEqual(command.enableReceipts, true)
    }

    func testNoJoinSkipsCoordinatorClientInstantiation() {
        var factoryInvoked = false

        let client = ServeCommand.makeCoordinatorClient(noJoin: true) {
            factoryInvoked = true
            return nil
        }

        XCTAssertNil(client)
        XCTAssertFalse(factoryInvoked)
    }

    func testDefaultServePathInvokesCoordinatorClientFactory() {
        var factoryInvoked = false

        _ = ServeCommand.makeCoordinatorClient(noJoin: false) {
            factoryInvoked = true
            return nil
        }

        XCTAssertTrue(factoryInvoked)
    }

    func testDonorModeSkipsCoordinatorClientInstantiation() {
        var factoryInvoked = false

        let client = ServeCommand.makeCoordinatorClient(noJoin: false, donorMode: true) {
            factoryInvoked = true
            return nil
        }

        XCTAssertNil(client)
        XCTAssertFalse(factoryInvoked)
    }

    func testSafeOfflineCatalogFallbackRequestsCoordinatorCompatibility() {
        var factoryInvoked = false

        let client = ServeCommand.makeCoordinatorClient(
            noJoin: false,
            catalogTrustState: "safe_offline_fallback"
        ) {
            factoryInvoked = true
            return nil
        }

        XCTAssertNil(client)
        XCTAssertTrue(factoryInvoked)
    }

    func testCatalogIntegrityFailureDoesNotJoinCoordinator() {
        var factoryInvoked = false
        let client = ServeCommand.makeCoordinatorClient(
            noJoin: false,
            catalogTrustState: "catalog_integrity_failure"
        ) {
            factoryInvoked = true
            return nil
        }
        XCTAssertNil(client)
        XCTAssertFalse(factoryInvoked)
    }

    func testServeStartupPreflightsAcquireSingletonBeforeModelArtifactPreflight() async throws {
        let lockDirectory = try tempDir()
        let heldLock = try ProviderServeLock.acquire(providerID: "mac", port: 61_919, directory: lockDirectory)
        defer { heldLock.release() }
        var config = configWithInvalidArtifact(port: 61_919)

        do {
            _ = try await ServeCommand.runServeStartupPreflights(
                &config,
                joiningCoordinator: false,
                portIsOpen: { _ in false },
                acquireServeLock: { config in
                    do {
                        return try ProviderServeLock.acquire(
                            providerID: config.providerID,
                            port: config.port,
                            directory: lockDirectory
                        )
                    } catch is ProviderServeLockError {
                        throw ExitCode(1)
                    }
                }
            )
            XCTFail("duplicate serve startup must fail before model artifact preflight")
        } catch {
            XCTAssertEqual(error as? ExitCode, ExitCode(1))
        }
    }

    func testServeStartupPreflightsRejectOpenPortBeforeModelArtifactPreflightAndReleaseLock() async throws {
        let lockDirectory = try tempDir()
        var config = configWithInvalidArtifact(port: 61_920)

        do {
            _ = try await ServeCommand.runServeStartupPreflights(
                &config,
                joiningCoordinator: false,
                portIsOpen: { port in port == 61_920 },
                acquireServeLock: { config in
                    try ProviderServeLock.acquire(
                        providerID: config.providerID,
                        port: config.port,
                        directory: lockDirectory
                    )
                }
            )
            XCTFail("legacy listener on serve port must fail before model artifact preflight")
        } catch {
            XCTAssertEqual(error as? ExitCode, ExitCode(1))
        }

        let retryLock = try ProviderServeLock.acquire(providerID: "retry", port: 61_920, directory: lockDirectory)
        retryLock.release()
    }

    func testReceiptBuilderDisabledByDefault() throws {
        var config = AppConfig.defaults()
        config.providerID = "provider-a"

        XCTAssertNil(try ServeCommand.makeReceiptBuilder(config: config, keyStore: InMemoryReceiptKeyStore()))
    }

    func testReceiptBuilderRequiresProviderID() throws {
        var config = AppConfig.defaults()
        config.enableReceipts = true

        XCTAssertNil(try ServeCommand.makeReceiptBuilder(config: config, keyStore: InMemoryReceiptKeyStore()))
    }

    func testReceiptBuilderEnabledGeneratesCurrentKey() throws {
        var config = AppConfig.defaults()
        config.enableReceipts = true
        config.providerID = "provider-a"
        let store = InMemoryReceiptKeyStore()

        let builder = try XCTUnwrap(ServeCommand.makeReceiptBuilder(config: config, keyStore: store))

        XCTAssertNotNil(try store.loadCurrent(providerId: "provider-a"))
        XCTAssertNotNil(builder)
    }

    func testReceiptRuntimePublishesCurrentKeyPublicBytes() throws {
        var config = AppConfig.defaults()
        config.enableReceipts = true
        config.providerID = "provider-a"
        let store = InMemoryReceiptKeyStore()

        let runtime = try ServeCommand.makeReceiptRuntime(config: config, keyStore: store)
        let current = try XCTUnwrap(store.loadCurrent(providerId: "provider-a"))

        XCTAssertNotNil(runtime.builder)
        XCTAssertEqual(runtime.publicKeyBase64, Data(current.publicKey.rawRepresentation).base64EncodedString())
    }

    func testNoJoinModelArtifactPreflightAcceptsMatchingLocalSnapshotHash() async throws {
        let snapshot = try makeSnapshot()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        var config = AppConfig.defaults()
        config.model = "test-public-model"
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = expected

        try await ServeCommand.runModelArtifactPreflight(config, joiningCoordinator: false)
    }

    func testSelfTestUsesVerifiedArtifactPathForRuntimeLoad() {
        var config = AppConfig.defaults()
        config.model = "test-public-model"
        config.modelArtifactPath = "/tmp/macprovider-test-snapshot"

        XCTAssertEqual(SelfTestCommand.modelLoadPath(for: config), "/tmp/macprovider-test-snapshot")
    }

    func testCoordinatorJoinRequiresCatalogBindingForVerifiedArtifact() async throws {
        let snapshot = try makeSnapshot()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        var config = AppConfig.defaults()
        config.model = "test-public-model"
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = expected

        do {
            try await ServeCommand.runModelArtifactPreflight(config, joiningCoordinator: true)
            XCTFail("coordinator-joining paid mode must require catalog provenance")
        } catch {
            // expected
        }
    }

    func testCoordinatorJoinRequiresVerifiedModelArtifactMetadata() async throws {
        var config = AppConfig.defaults()
        config.model = "test-public-model"

        do {
            try await ServeCommand.runModelArtifactPreflight(config, joiningCoordinator: true)
            XCTFail("coordinator-joining paid mode must require a verified artifact hash")
        } catch {
            // expected
        }
    }

    func testDonorModeRequiresVerifiedModelArtifactHash() async throws {
        var config = AppConfig.defaults()
        config.donorMode = true
        config.model = "/tmp/arbitrary-model"

        do {
            try await ServeCommand.runModelArtifactPreflight(config)
            XCTFail("donor mode must require an artifact hash")
        } catch {
            // expected
        }
    }

    func testDonorModeRequiresCatalogBindingForVerifiedArtifact() async throws {
        let snapshot = try makeSnapshot()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        var config = AppConfig.defaults()
        config.donorMode = true
        config.model = "test-public-model"
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = expected

        do {
            try await ServeCommand.runModelArtifactPreflight(config)
            XCTFail("donor mode must require catalog provenance")
        } catch {
            // expected
        }
    }

    func testDonorModeAcceptsCatalogBoundSnapshot() async throws {
        try await assertCatalogBoundSnapshotPreflight(runtimeStatus: "listed", donorMode: true)
    }

    func testCoordinatorJoinAcceptsCatalogBoundRecommendableSnapshot() async throws {
        try await assertCatalogBoundSnapshotPreflight(runtimeStatus: "recommendable", donorMode: false)
    }

    func testCoordinatorJoinAcceptsNormalizedPublicKeyForCatalogBoundSnapshot() async throws {
        try await assertCatalogBoundSnapshotPreflight(
            runtimeStatus: "recommendable",
            donorMode: false,
            catalogKey: "mlx-community/gpt-oss-20b-MXFP4-Q8",
            configuredModel: "openai/gpt-oss-20b",
            rateCardKey: "openai/gpt-oss-20b"
        )
    }

    func testCoordinatorJoinRejectsCatalogBoundListedSnapshot() async throws {
        do {
            try await assertCatalogBoundSnapshotPreflight(runtimeStatus: "listed", donorMode: false)
            XCTFail("paid coordinator join must require a recommendable catalog row")
        } catch {
            // expected
        }
    }

    func testCoordinatorJoinAcceptsCatalogBoundSnapshotWithStaleProvenanceEnvelope() async throws {
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let key = "test-model"
        let modelID = "test/model"
        let revision = String(repeating: "1", count: 40)
        let snapshot = resolver.snapshotURL(modelID: modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        let artifactSHA = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        let currentCatalogJSON = """
        {"version":"current-catalog","generated_at":"2026-07-11T12:00:00Z","source":"operator_curated_autotune_candidate_catalog","policy_version":"autotune-policy-v1","rows":{"\(key)":{"model_id":"\(modelID)","model_revision":"\(revision)","model_sha256":"\(artifactSHA)","min_ram_gb":1,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommendable"}}}
        """
        let rateCardJSON = """
        {"version":"test-rate-card","generated_at":"2026-07-10T12:00:00Z","usd_per_million_credits":1.0,"rows":{"\(key)":{"prompt_rate_per_mtok":1,"completion_rate_per_mtok":1,"provider_share_bps":9000,"global_multiplier_ppm":1000000}}}
        """
        let catalogBytes = Data(currentCatalogJSON.utf8)
        let rateCardBytes = Data(rateCardJSON.utf8)
        let staticInputs = AutotuneStaticInputs(
            fetch: { url in
                switch url.path {
                case "/v1/rate-card":
                    return rateCardBytes
                case "/v1/autotune-candidates", "/v1/demand-rank":
                    return catalogBytes
                default:
                    break
                }
                if url.path.hasSuffix(".sig") {
                    let signature = Data(repeating: 0, count: 64).base64EncodedString()
                    return Data("{\"key_id\":\"streamvc-autotune-static-v4\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
                }
                return catalogBytes
            },
            verifySignature: { _, _ in true },
            now: { ISO8601DateFormatter.autotuneInternet.date(from: "2026-07-11T12:00:00Z")! }
        )
        var config = AppConfig.defaults()
        config.model = key
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = artifactSHA
        config.modelCatalogKey = key
        config.modelCatalogModelID = modelID
        config.modelCatalogRevision = revision
        config.modelCatalogSHA256 = artifactSHA
        // Simulate config written by an older autotune --apply against a prior catalog publish.
        config.modelCatalogVersion = "prior-catalog"
        config.modelCatalogHash = String(repeating: "a", count: 64)

        try await ServeCommand.runModelArtifactPreflight(
            config,
            joiningCoordinator: true,
            staticInputs: staticInputs,
            artifactResolver: resolver
        )
    }

    func testCoordinatorJoinRejectsPublicModelKeyMismatchForCatalogBoundSnapshot() async throws {
        do {
            try await assertCatalogBoundSnapshotPreflight(
                runtimeStatus: "recommendable",
                donorMode: false,
                catalogKey: "test-model",
                configuredModel: "different-public-model",
                rateCardKey: "test-model"
            )
            XCTFail("paid coordinator join must bind public model key to verified catalog provenance")
        } catch {
            // expected
        }
    }

    private func assertCatalogBoundSnapshotPreflight(runtimeStatus: String, donorMode: Bool) async throws {
        try await assertCatalogBoundSnapshotPreflight(
            runtimeStatus: runtimeStatus,
            donorMode: donorMode,
            catalogKey: "test-model",
            configuredModel: nil,
            rateCardKey: "test-model"
        )
    }

    private func assertCatalogBoundSnapshotPreflight(
        runtimeStatus: String,
        donorMode: Bool,
        catalogKey: String,
        configuredModel: String?,
        rateCardKey: String
    ) async throws {
        let hub = try tempDir()
        let resolver = CachedModelArtifactResolver(hubRoot: hub)
        let key = catalogKey
        let modelID = "test/model"
        let revision = String(repeating: "1", count: 40)
        let snapshot = resolver.snapshotURL(modelID: modelID, revision: revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        let artifactSHA = try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot)
        let catalogJSON = """
        {"version":"test-catalog","generated_at":"2026-07-11T12:00:00Z","source":"operator_curated_autotune_candidate_catalog","policy_version":"autotune-policy-v1","rows":{"\(key)":{"model_id":"\(modelID)","model_revision":"\(revision)","model_sha256":"\(artifactSHA)","min_ram_gb":1,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"\(runtimeStatus)"}}}
        """
        let rateCardJSON = """
        {"version":"test-rate-card","generated_at":"2026-07-10T12:00:00Z","usd_per_million_credits":1.0,"rows":{"\(rateCardKey)":{"prompt_rate_per_mtok":1,"completion_rate_per_mtok":1,"provider_share_bps":9000,"global_multiplier_ppm":1000000}}}
        """
        let catalogBytes = Data(catalogJSON.utf8)
        let rateCardBytes = Data(rateCardJSON.utf8)
        let staticInputs = AutotuneStaticInputs(
            fetch: { url in
                switch url.path {
                case "/v1/rate-card":
                    return rateCardBytes
                case "/v1/autotune-candidates", "/v1/demand-rank":
                    return catalogBytes
                default:
                    break
                }
                if url.path.hasSuffix(".sig") {
                    let signature = Data(repeating: 0, count: 64).base64EncodedString()
                    return Data("{\"key_id\":\"streamvc-autotune-static-v4\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
                }
                return catalogBytes
            },
            verifySignature: { _, _ in true },
            now: { ISO8601DateFormatter.autotuneInternet.date(from: "2026-07-11T12:00:00Z")! }
        )
        var config = AppConfig.defaults()
        config.donorMode = donorMode
        config.model = configuredModel ?? key
        config.modelArtifactPath = snapshot.path
        config.modelArtifactSHA256 = artifactSHA
        config.modelCatalogKey = key
        config.modelCatalogModelID = modelID
        config.modelCatalogRevision = revision
        config.modelCatalogSHA256 = artifactSHA
        config.modelCatalogVersion = "test-catalog"
        config.modelCatalogHash = AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalogBytes)

        try await ServeCommand.runModelArtifactPreflight(
            config,
            joiningCoordinator: true,
            staticInputs: staticInputs,
            artifactResolver: resolver
        )
    }

    func testModelArtifactPreflightRejectsMismatch() async throws {
        let snapshot = try makeSnapshot()
        var config = AppConfig.defaults()
        config.model = snapshot.path
        config.modelArtifactSHA256 = String(repeating: "b", count: 64)

        do {
            try await ServeCommand.runModelArtifactPreflight(config)
            XCTFail("artifact mismatch must fail")
        } catch {
            // expected
        }
    }

    func testModelArtifactPreflightRequiresLocalPathWhenHashSet() async throws {
        var config = AppConfig.defaults()
        config.model = "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"
        config.modelArtifactSHA256 = String(repeating: "a", count: 64)

        do {
            try await ServeCommand.runModelArtifactPreflight(config)
            XCTFail("artifact hash must require a local path")
        } catch {
            // expected
        }
    }

    func testModelArtifactPreflightRequiresHashWhenArtifactPathSet() async throws {
        let snapshot = try makeSnapshot()
        var config = AppConfig.defaults()
        config.model = "test-public-model"
        config.modelArtifactPath = snapshot.path

        do {
            try await ServeCommand.runModelArtifactPreflight(config, joiningCoordinator: false)
            XCTFail("artifact path must require a verification hash")
        } catch {
            // expected
        }
    }

    private func makeSnapshot() throws -> URL {
        let root = try tempDir()
        try Data("weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        return root
    }

    private func configWithInvalidArtifact(port: Int) -> AppConfig {
        var config = AppConfig.defaults()
        config.providerID = "mac"
        config.port = port
        config.model = "test-public-model"
        config.modelArtifactPath = "/tmp/macprovider-missing-\(UUID().uuidString)"
        config.modelArtifactSHA256 = String(repeating: "a", count: 64)
        return config
    }

    private func tempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServeCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
