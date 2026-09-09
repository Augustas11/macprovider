import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-023 §3.7 artifact feed consumption (BYOM v0.2 slice 2c). The decode
/// and binding rules are pinned by the shared corpus that the Python
/// generator and the Go coordinator also read.
final class AutotuneArtifactFeedTests: XCTestCase {
    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/tests/fixtures/artifact_feed_conformance.json")
    }

    private struct Corpus {
        var candidate: [String: Any]
        var feed: [String: Any]
        var cases: [[String: Any]]
    }

    private static func loadCorpus() throws -> Corpus {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as! [String: Any]
        return Corpus(
            candidate: object["candidate"] as! [String: Any],
            feed: object["feed"] as! [String: Any],
            cases: object["cases"] as! [[String: Any]]
        )
    }

    private static func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    /// Applies the corpus mutation ops (`set` / `delete` along a key path).
    private static func applying(_ ops: [[String: Any]], to object: [String: Any]) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: canonical(object), options: [.mutableContainers]) as! NSMutableDictionary
        for op in ops {
            let path = op["path"] as! [String]
            var target = root
            for key in path.dropLast() {
                target = target[key] as! NSMutableDictionary
            }
            switch op["op"] as! String {
            case "set":
                target[path.last!] = op["value"] ?? NSNull()
            case "delete":
                target.removeObject(forKey: path.last!)
            default:
                XCTFail("unknown corpus op")
            }
        }
        return try JSONSerialization.jsonObject(with: canonical(root)) as! [String: Any]
    }

    private static func date(_ raw: String) -> Date {
        ISO8601DateFormatter.autotuneInternet.date(from: raw)!
    }

    private func boundFixture() throws -> (candidateBytes: Data, catalog: CandidateCatalog, feedBytes: Data) {
        let corpus = try Self.loadCorpus()
        let candidateBytes = try Self.canonical(corpus.candidate)
        let catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes)
        var feed = corpus.feed
        feed["candidate_catalog_sha256"] = Self.sha256Hex(candidateBytes)
        return (candidateBytes, catalog, try Self.canonical(feed))
    }

    func testSharedConformanceCorpus() throws {
        let corpus = try Self.loadCorpus()
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 25)
        let candidateBytes = try Self.canonical(corpus.candidate)
        let catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes)
        for testCase in corpus.cases {
            let name = testCase["name"] as! String
            var feed = corpus.feed
            feed["candidate_catalog_sha256"] = Self.sha256Hex(candidateBytes)
            feed = try Self.applying(testCase["ops"] as! [[String: Any]], to: feed)
            let bytes = try Self.canonical(feed)
            let outcome: () throws -> Void = {
                try AutotuneStaticInputs.decodeArtifactFeed(bytes).bind(
                    to: catalog,
                    candidateBytes: candidateBytes,
                    candidateSignerKeyID: "test-key",
                    artifactSignerKeyID: "test-key"
                )
            }
            switch testCase["expect"] as! String {
            case "accept":
                XCTAssertNoThrow(try outcome(), "corpus case \(name) must be accepted")
            case "reject":
                XCTAssertThrowsError(try outcome(), "corpus case \(name) must be rejected")
            default:
                XCTFail("corpus case \(name) has an unknown expectation")
            }
        }
    }

    func testSignerIdentityEqualityIsCheckedNotAssumed() throws {
        let fixture = try boundFixture()
        let feed = try AutotuneStaticInputs.decodeArtifactFeed(fixture.feedBytes)
        XCTAssertNoThrow(try feed.bind(to: fixture.catalog, candidateBytes: fixture.candidateBytes, candidateSignerKeyID: "v4", artifactSignerKeyID: "v4"))
        XCTAssertThrowsError(try feed.bind(to: fixture.catalog, candidateBytes: fixture.candidateBytes, candidateSignerKeyID: "v4", artifactSignerKeyID: "v5")) { error in
            guard case ArtifactFeedError.integrity = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try feed.bind(to: fixture.catalog, candidateBytes: fixture.candidateBytes, candidateSignerKeyID: nil, artifactSignerKeyID: "v4"))
    }

    func testAbsentBakedFeedIsIndistinguishableFromV01() async throws {
        let fixture = try boundFixture()
        let candidate = AutotuneStaticSelection(value: fixture.catalog, selectedBytes: fixture.candidateBytes, warnings: [], usedFallback: false, signerKeyID: "streamvc-autotune-static-v4")
        let inputs = AutotuneStaticInputs(fetch: { _ in XCTFail("no fetch for an absent feed"); throw URLError(.badURL) })
        let selection = await inputs.loadArtifactFeed(candidate: candidate, bakedArtifactFeed: nil)
        XCTAssertNil(selection.value)
        XCTAssertTrue(selection.warnings.isEmpty)
        XCTAssertFalse(selection.usedFallback)
    }

    func testVerifiedLiveFeedBoundToTheSelectedCandidateIsUsable() async throws {
        let fixture = try boundFixture()
        let privateKey = Curve25519.Signing.PrivateKey()
        let keyID = "streamvc-autotune-static-v4"
        let signature = try privateKey.signature(for: fixture.feedBytes).base64EncodedString()
        let sidecar = Data("{\"key_id\":\"\(keyID)\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        var keyring = AutotuneStaticInputs.defaultTrustedPublicKeys
        keyring[keyID] = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let candidate = AutotuneStaticSelection(value: fixture.catalog, selectedBytes: fixture.candidateBytes, warnings: [], usedFallback: false, signerKeyID: keyID)
        let inputs = AutotuneStaticInputs(
            fetch: { url in
                XCTAssertTrue(url.path.hasPrefix("/v1/catalog-artifacts"))
                return url.path.hasSuffix(".sig") ? sidecar : fixture.feedBytes
            },
            trustedPublicKeys: keyring,
            now: { Self.date("2026-07-11T00:00:00Z") }
        )
        let selection = await inputs.loadArtifactFeed(candidate: candidate, bakedArtifactFeed: fixture.feedBytes)
        XCTAssertNotNil(selection.value)
        XCTAssertFalse(selection.usedFallback)
        XCTAssertEqual(selection.signerKeyID, keyID)
        XCTAssertTrue(selection.warnings.isEmpty)
        XCTAssertEqual(selection.value?.models["test-model"]?.primary.hash, String(repeating: "2", count: 64))
    }

    func testLiveFeedSignedByASecondTrustedKeyFailsIntegrity() async throws {
        let fixture = try boundFixture()
        let privateKey = Curve25519.Signing.PrivateKey()
        let signature = try privateKey.signature(for: fixture.feedBytes).base64EncodedString()
        let sidecar = Data("{\"key_id\":\"streamvc-autotune-static-v5\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        var keyring = AutotuneStaticInputs.defaultTrustedPublicKeys
        keyring["streamvc-autotune-static-v5"] = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let candidate = AutotuneStaticSelection(value: fixture.catalog, selectedBytes: fixture.candidateBytes, warnings: [], usedFallback: false, signerKeyID: "streamvc-autotune-static-v4")
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : fixture.feedBytes },
            trustedPublicKeys: keyring,
            now: { Self.date("2026-07-11T00:00:00Z") }
        )
        let selection = await inputs.loadArtifactFeed(candidate: candidate, bakedArtifactFeed: fixture.feedBytes)
        XCTAssertNil(selection.value)
        XCTAssertTrue(selection.warnings.contains(.catalogArtifactFeedIntegrityFailure))
    }

    func testTransportFailureFallsBackToTheBakedFeedWithoutBlocking() async throws {
        let fixture = try boundFixture()
        let candidate = AutotuneStaticSelection(value: fixture.catalog, selectedBytes: fixture.candidateBytes, warnings: [], usedFallback: false, signerKeyID: AutotuneStaticInputs.bakedCatalogSignerKeyID)
        let inputs = AutotuneStaticInputs(
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            now: { Self.date("2026-07-11T00:00:00Z") }
        )
        let selection = await inputs.loadArtifactFeed(candidate: candidate, bakedArtifactFeed: fixture.feedBytes)
        XCTAssertNotNil(selection.value)
        XCTAssertTrue(selection.usedFallback)
        XCTAssertEqual(selection.warnings, [.catalogArtifactFeedFallbackUsed])
        // §3.7.6 rule 6: never a paid-trust or network-submission blocker.
        XCTAssertFalse(AutotuneRecommendEngine.paidTrustBlocks(selection.warnings))
        XCTAssertFalse(AutotuneRecommendEngine.networkSubmissionBlocks(selection.warnings))
    }

    func testFeedFromAnotherReleaseIsUpdateRequiredAndUnusable() async throws {
        let corpus = try Self.loadCorpus()
        var otherCandidate = corpus.candidate
        otherCandidate["version"] = "other-release"
        let candidateBytes = try Self.canonical(otherCandidate)
        let catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes)
        let fixture = try boundFixture()
        let candidate = AutotuneStaticSelection(value: catalog, selectedBytes: candidateBytes, warnings: [], usedFallback: false, signerKeyID: AutotuneStaticInputs.bakedCatalogSignerKeyID)
        let inputs = AutotuneStaticInputs(
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            now: { Self.date("2026-07-11T00:00:00Z") }
        )
        let selection = await inputs.loadArtifactFeed(candidate: candidate, bakedArtifactFeed: fixture.feedBytes)
        XCTAssertNil(selection.value)
        XCTAssertTrue(selection.warnings.contains(.catalogArtifactFeedUpdateRequired))
    }

    func testArtifactFeedWarningsAreNeverBlocking() {
        for warning in [
            AutotuneRecommendWarning.catalogArtifactFeedFallbackUsed, .catalogArtifactFeedIntegrityFailure,
            .catalogArtifactFeedUpdateRequired, .catalogArtifactFeedStale,
        ] {
            XCTAssertFalse(AutotuneRecommendEngine.paidTrustBlocks([warning]), warning.rawValue)
            XCTAssertFalse(AutotuneRecommendEngine.networkSubmissionBlocks([warning]), warning.rawValue)
        }
    }

    func testCatalogMatcherResolvesArtifactReferencesOnlyWhenTheFeedIsBound() throws {
        let corpus = try Self.loadCorpus()
        let candidateBytes = try Self.canonical(corpus.candidate)
        var feed = corpus.feed
        feed["candidate_catalog_sha256"] = Self.sha256Hex(candidateBytes)
        let gguf = corpus.cases.first { ($0["name"] as! String) == "declared gguf secondary is accepted" }!
        feed = try Self.applying(gguf["ops"] as! [[String: Any]], to: feed)
        let decoded = try AutotuneStaticInputs.decodeArtifactFeed(try Self.canonical(feed))

        let without = BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: nil)
        XCTAssertEqual(without.catalogKey(for: "mlx-community/Test-Model-4bit"), "test-model")
        XCTAssertNil(without.catalogKey(for: "test-model:q4_k_m"))

        let with = BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: decoded)
        XCTAssertEqual(with.catalogKey(for: "mlx-community/Test-Model-4bit"), "test-model")
        XCTAssertEqual(with.catalogKey(for: "TEST-MODEL:Q4_K_M"), "test-model")
        XCTAssertNil(with.catalogKey(for: "unrelated:latest"))
    }

    func testCommittedSnapshotBakesNoArtifactFeedUntilActivation() {
        // The committed release is rate-card-bound: the compiled-in feed is nil and
        // the compiled-in matcher behaves exactly as v0.1.
        XCTAssertNil(AutotuneStaticInputs.bakedArtifactFeedJSON)
        XCTAssertNil(AutotuneStaticInputs.bakedBoundArtifactFeed())
    }
}
