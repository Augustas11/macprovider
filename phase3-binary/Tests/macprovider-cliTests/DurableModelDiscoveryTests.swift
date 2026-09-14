import CryptoKit
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class DurableModelDiscoveryTests: XCTestCase {
    private let modelID = "mlx-community/Test-Model-4bit"
    private let revision = String(repeating: "1", count: 40)

    func testPreparedArtifactSurvivesEmptyCacheAndRestartWithStableIdentity() async throws {
        let fixture = try makeFixture()
        let before = try await candidate(fixture)
        _ = try createCacheCopy(fixture)
        let cacheID = BYOMMLXCacheDiscovery(
            cacheRoot: fixture.cache, namespace: fixture.namespaceBytes,
            catalogMatcher: fixture.matcher
        ).discover().candidates.first?.candidateID
        XCTAssertEqual(before.candidateID, cacheID)
        try FileManager.default.removeItem(at: fixture.cache)
        let restarted = try await candidate(fixture)
        XCTAssertEqual(restarted.candidateID, before.candidateID)
        XCTAssertEqual(restarted.readinessState, "ready")
        XCTAssertEqual(restarted.servedModelRef, modelID)
        XCTAssertEqual(restarted.runtimeSource, "mlx_cache")
        XCTAssertEqual(restarted.catalogModelKey, "test-model")
        XCTAssertEqual(restarted.identityState, "catalog_matched")
        XCTAssertEqual(restarted.admissionStateSource, "local_default")
        let wire = String(decoding: try JSONEncoder().encode(restarted), as: UTF8.self)
        XCTAssertFalse(wire.contains(fixture.root.path))
        XCTAssertFalse(wire.contains(fixture.hash))
    }

    func testSimultaneousCopiesDeduplicateAndPreferVerifiedDurableMetadata() async throws {
        let fixture = try makeFixture()
        let snapshot = try createCacheCopy(fixture)
        try Data(#"{"max_position_embeddings":99}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        let row = try await candidate(fixture)
        XCTAssertEqual(row.readinessState, "ready")
        XCTAssertEqual(row.contextWindowTokens, 4096)
    }

    func testCorruptDurableBytesBlockCacheFallbackWithoutRepairOrDeletion() async throws {
        let fixture = try makeFixture()
        _ = try createCacheCopy(fixture)
        let weights = fixture.artifact.appendingPathComponent("weights.safetensors")
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: weights)
        let row = try await candidate(fixture)
        XCTAssertEqual(row.readinessState, "needs_weights")
        XCTAssertTrue(row.warningCodes.contains("requires_preparation"))
        XCTAssertEqual(row.admissionState, "local_only")
        XCTAssertEqual(try Data(contentsOf: weights), corrupt)
    }

    func testWrongHashOrRevisionDoesNotSubstituteSiblingArtifact() async throws {
        for wrongRevision in [false, true] {
            let fixture = try makeFixture()
            let store = DurableModelArtifactStore(root: fixture.durable)
            let other = try store.artifactURL(
                modelID: modelID,
                revision: wrongRevision ? String(repeating: "3", count: 40) : revision,
                sha256: wrongRevision ? fixture.hash : String(repeating: "4", count: 64)
            )
            try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: fixture.artifact, to: other)
            let row = try await candidate(fixture)
            XCTAssertEqual(row.readinessState, "needs_weights")
            XCTAssertEqual(row.catalogModelKey, "test-model")
            XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        }
    }

    func testMissingArtifactAndSymlinkedWeightsFailClosed() async throws {
        for symlinked in [false, true] {
            let fixture = try makeFixture()
            let weights = fixture.artifact.appendingPathComponent("weights.safetensors")
            try FileManager.default.removeItem(at: weights)
            if symlinked {
                let external = fixture.root.appendingPathComponent("external-weights")
                try Data("fixture-weights".utf8).write(to: external)
                try FileManager.default.createSymbolicLink(at: weights, withDestinationURL: external)
            }
            let row = try await candidate(fixture)
            XCTAssertEqual(row.readinessState, "needs_weights")
        }
    }

    func testSymlinkedDurableRootAndAncestorFailClosed() async throws {
        for linkedAncestor in [false, true] {
            let fixture = try makeFixture()
            let link = fixture.root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: linkedAncestor ? fixture.root : fixture.durable
            )
            let root = linkedAncestor ? link.appendingPathComponent("durable") : link
            let rows = DurableModelDiscovery(
                root: root, namespace: fixture.namespaceBytes, catalogMatcher: fixture.matcher
            ).discover()
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.readinessState, "needs_weights")
        }
    }

    func testUnqualifiedFeedCannotDiscoverDurableArtifact() throws {
        let fixture = try makeFixture()
        let rows = DurableModelDiscovery(
            root: fixture.durable, namespace: fixture.namespaceBytes,
            catalogMatcher: BYOMCatalogMatcher(candidateBytes: fixture.candidateBytes, artifactFeed: nil)
        ).discover()
        XCTAssertTrue(rows.isEmpty)
    }

    func testCandidateAndQualifiedFeedMustAgreeOnExactTarget() throws {
        let fixture = try makeFixture()
        for field in ["model_revision", "model_sha256"] {
            var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.candidateBytes) as? [String: Any])
            var rows = try XCTUnwrap(catalog["rows"] as? [String: [String: Any]])
            rows["test-model"]?[field] = String(repeating: "9", count: field == "model_revision" ? 40 : 64)
            catalog["rows"] = rows
            let matcher = BYOMCatalogMatcher(candidateBytes: try canonical(catalog), artifactFeed: fixture.feed)
            XCTAssertTrue(matcher.durableTargets.isEmpty)
        }
    }

    func testProductionUsesSameInjectedRootResolverAsRecommendation() {
        let home = URL(fileURLWithPath: "/isolated-home")
        var config = AppConfig.defaults()
        config.modelArtifactRoot = "/configured-models"
        let environment = ["MACPROVIDER_MODEL_ARTIFACT_ROOT": "/environment-models"]
        for selectedConfig: AppConfig? in [config, nil] {
            let discovery = BYOMDiscoveryEnvironment.production(
                namespacePath: nil, mlxCacheDir: nil, ollamaOrigin: nil,
                config: selectedConfig, environment: environment, homeDirectory: home
            )
            XCTAssertEqual(discovery.durableArtifactRoot, CachedModelArtifactResolver.forConfig(
                selectedConfig, environment: environment, homeDirectory: home
            ).durableRoot)
            XCTAssertEqual(discovery.durableArtifactRoot?.path,
                           selectedConfig == nil ? "/environment-models" : "/configured-models")
        }
    }

    func testOwnedQuickMapShadowsCacheAndExactVerificationIsShared() async throws {
        let fixture = try makeFixture()
        _ = try createCacheCopy(fixture)
        let request = ModelCatalogLocalInspection(root: fixture.durable)
        let key = ModelCatalogLocalInspection.Key(modelKey: "test-model", modelID: modelID,
            revision: revision, sha256: fixture.hash)
        XCTAssertEqual(try request.inspect(key: key).state, .unverified)
        let runner = BYOMDiscoveryRunner(environment: BYOMDiscoveryEnvironment(
            namespaceURL: fixture.namespace, mlxCacheRoot: fixture.cache, ollamaOrigin: nil,
            durableArtifactRoot: fixture.durable), catalogMatcher: fixture.matcher, localInspection: request)
        let quick = try await runner.discoverCatalog()
        XCTAssertEqual(quick.candidates.count, 1)
        XCTAssertEqual(quick.candidates.first?.readinessState, "needs_weights")
        XCTAssertNil(quick.candidates.first?.contextWindowTokens)
        XCTAssertEqual(try request.inspect(key: key, verify: true).state, .verified)
        let verified = try await runner.discoverCatalog()
        XCTAssertEqual(verified.candidates.count, 1)
        XCTAssertEqual(verified.candidates.first?.readinessState, "ready")
        XCTAssertEqual(verified.candidates.first?.contextWindowTokens, 4096)
        try request.validateVerifiedPlacements()
    }

    func testOwnedMetadataScanPropagatesInterruptionAndReadsNoContent() throws {
        let fixture = try makeFixture()
        _ = try createCacheCopy(fixture)
        let scanner = BYOMMLXCacheDiscovery(cacheRoot: fixture.cache, namespace: fixture.namespaceBytes,
            catalogMatcher: fixture.matcher)
        var checks = 0
        XCTAssertThrowsError(try scanner.discoverCatalog(check: {
            checks += 1
            if checks == 5 { throw CancellationError() }
        }))
        XCTAssertEqual(checks, 5)
        let result = try scanner.discoverCatalog(check: {})
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.readinessState, "needs_weights")
        XCTAssertNil(result.candidates.first?.contextWindowTokens)
    }

    private struct Fixture {
        let root: URL
        let durable: URL
        let cache: URL
        let artifact: URL
        let hash: String
        let namespace: URL
        let namespaceBytes: Data
        let candidateBytes: Data
        let matcher: BYOMCatalogMatcher
        let feed: QualifiedArtifactFeed
    }

    private func candidate(_ fixture: Fixture) async throws -> BYOMDiscoveryWire.Candidate {
        let discovery = await BYOMDiscoveryRunner(
            environment: BYOMDiscoveryEnvironment(
                namespaceURL: fixture.namespace, mlxCacheRoot: fixture.cache,
                ollamaOrigin: nil, durableArtifactRoot: fixture.durable
            ), catalogMatcher: fixture.matcher
        ).discover()
        XCTAssertEqual(discovery.candidates.count, 1)
        return try XCTUnwrap(discovery.candidates.first)
    }

    private func createCacheCopy(_ fixture: Fixture) throws -> URL {
        let snapshot = fixture.cache.appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots").appendingPathComponent(revision)
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.artifact, to: snapshot)
        return snapshot
    }

    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(#"{"max_position_embeddings":4096}"#.utf8).write(to: staging.appendingPathComponent("config.json"))
        try Data("fixture-weights".utf8).write(to: staging.appendingPathComponent("weights.safetensors"))
        let hash = try ModelArtifactVerifier.canonicalArtifactHash(directory: staging)
        let durable = root.appendingPathComponent("durable")
        let artifact = try DurableModelArtifactStore(root: durable).adoptVerifiedStaging(
            staging: staging, modelID: modelID, revision: revision, sha256: hash
        )
        try fm.removeItem(at: staging)
        let cache = root.appendingPathComponent("empty-hf")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let namespace = root.appendingPathComponent("identity/namespace")
        _ = BYOMDiscoveryNamespaceStore().provisionNamespaceIfMissing(at: namespace)
        let namespaceBytes = try Data(contentsOf: namespace)
        let corpusURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/tests/fixtures/artifact_feed_conformance.json")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as? [String: Any])
        var candidate = try XCTUnwrap(corpus["candidate"] as? [String: Any])
        var candidateRows = try XCTUnwrap(candidate["rows"] as? [String: [String: Any]])
        candidateRows["test-model"]?["model_sha256"] = hash
        candidate["rows"] = candidateRows
        let candidateBytes = try canonical(candidate)
        var feed = try XCTUnwrap(corpus["feed"] as? [String: Any])
        var models = try XCTUnwrap(feed["models"] as? [String: [String: Any]])
        var artifacts = try XCTUnwrap(models["test-model"]?["artifacts"] as? [String: [String: Any]])
        artifacts["mlx-4bit"]?["hash"] = hash
        models["test-model"]?["artifacts"] = artifacts
        feed["models"] = models
        feed["candidate_catalog_sha256"] = Data(SHA256.hash(data: candidateBytes)).map { String(format: "%02x", $0) }.joined()
        let qualified = try XCTUnwrap(AutotuneStaticInputs.usableArtifactFeed(
            bakedBytes: try canonical(feed), bakedSignerKeyID: "streamvc-autotune-static-v4",
            candidateBytes: candidateBytes, candidateSignerKeyID: "streamvc-autotune-static-v4",
            now: ISO8601DateFormatter().date(from: "2026-07-11T00:00:00Z")!
        ))
        return Fixture(root: root, durable: durable, cache: cache, artifact: artifact,
                       hash: hash, namespace: namespace, namespaceBytes: namespaceBytes,
                       candidateBytes: candidateBytes,
                       matcher: BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: qualified), feed: qualified)
    }

    private func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
