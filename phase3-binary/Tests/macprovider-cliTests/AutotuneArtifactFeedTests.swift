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
        var caseCount: Int
    }

    private static func loadCorpus() throws -> Corpus {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as! [String: Any]
        return Corpus(
            candidate: object["candidate"] as! [String: Any],
            feed: object["feed"] as! [String: Any],
            cases: object["cases"] as! [[String: Any]],
            caseCount: object["case_count"] as! Int
        )
    }

    private static let signer = "streamvc-autotune-static-v4"

    /// The only way a test (like production) obtains a matcher's artifact set:
    /// through the offline qualifier.
    private func qualified(_ feedBytes: Data, candidateBytes: Data, now: String = "2026-07-11T00:00:00Z") -> QualifiedArtifactFeed? {
        AutotuneStaticInputs.usableArtifactFeed(
            bakedBytes: feedBytes, bakedSignerKeyID: Self.signer,
            candidateBytes: candidateBytes, candidateSignerKeyID: Self.signer, now: Self.date(now)
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
        XCTAssertEqual(corpus.cases.count, corpus.caseCount)
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 25)
        for testCase in corpus.cases {
            let name = testCase["name"] as! String
            let candidateSource = try Self.applying(testCase["candidate_ops"] as? [[String: Any]] ?? [], to: corpus.candidate)
            let candidateBytes = try Self.canonical(candidateSource)
            let catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes)
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
        XCTAssertEqual(selection.value?.feed.models["test-model"]?.primary.hash, String(repeating: "2", count: 64))
        XCTAssertEqual(selection.value?.signerKeyID, keyID)
        XCTAssertEqual(selection.value?.feedSHA256, AutotuneStaticInputs.candidateCatalogSHA256(bytes: fixture.feedBytes))
        XCTAssertEqual(selection.value?.releaseID, "test-release")
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
        let selection = await inputs.loadArtifactFeed(
            candidate: candidate, bakedArtifactFeed: fixture.feedBytes,
            bakedArtifactFeedSignerKeyID: AutotuneStaticInputs.bakedCatalogSignerKeyID
        )
        XCTAssertNotNil(selection.value)
        XCTAssertTrue(selection.usedFallback)
        XCTAssertEqual(selection.signerKeyID, AutotuneStaticInputs.bakedCatalogSignerKeyID)
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
        let selection = await inputs.loadArtifactFeed(
            candidate: candidate, bakedArtifactFeed: fixture.feedBytes,
            bakedArtifactFeedSignerKeyID: AutotuneStaticInputs.bakedCatalogSignerKeyID
        )
        XCTAssertNil(selection.value)
        XCTAssertTrue(selection.warnings.contains(.catalogArtifactFeedUpdateRequired))
    }

    func testBakedFeedWithoutItsManifestSignerOrWithAnotherOneFailsIntegrity() async throws {
        // The compiled-in path is a genuine three-way identity: candidate
        // signer == artifact signer == release-manifest-bound artifact signer.
        let fixture = try boundFixture()
        let candidate = AutotuneStaticSelection(value: fixture.catalog, selectedBytes: fixture.candidateBytes, warnings: [], usedFallback: false, signerKeyID: AutotuneStaticInputs.bakedCatalogSignerKeyID)
        let inputs = AutotuneStaticInputs(
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            now: { Self.date("2026-07-11T00:00:00Z") }
        )
        for manifestSigner in [nil, "streamvc-autotune-static-v5"] {
            let selection = await inputs.loadArtifactFeed(
                candidate: candidate, bakedArtifactFeed: fixture.feedBytes, bakedArtifactFeedSignerKeyID: manifestSigner
            )
            XCTAssertNil(selection.value, manifestSigner ?? "nil")
            XCTAssertTrue(selection.warnings.contains(.catalogArtifactFeedIntegrityFailure), manifestSigner ?? "nil")
            XCTAssertFalse(AutotuneRecommendEngine.paidTrustBlocks(selection.warnings))
        }
        XCTAssertThrowsError(try AutotuneStaticInputs.decodeArtifactFeed(fixture.feedBytes).bind(
            to: fixture.catalog, candidateBytes: fixture.candidateBytes,
            candidateSignerKeyID: "v4", artifactSignerKeyID: "v4", manifestSignerKeyID: "v5"
        )) { error in
            guard case ArtifactFeedError.integrity = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try AutotuneStaticInputs.decodeArtifactFeed(fixture.feedBytes).bind(
            to: fixture.catalog, candidateBytes: fixture.candidateBytes,
            candidateSignerKeyID: "v4", artifactSignerKeyID: "v4", manifestSignerKeyID: "v4"
        ))
    }

    private func signedLiveInputs(
        feedBytes: Data, now: String, fetchFeed: Data? = nil
    ) throws -> (inputs: AutotuneStaticInputs, keyID: String) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let keyID = "streamvc-autotune-static-v4"
        let served = fetchFeed ?? feedBytes
        let signature = try privateKey.signature(for: served).base64EncodedString()
        let sidecar = Data("{\"key_id\":\"\(keyID)\",\"alg\":\"ed25519\",\"signature\":\"\(signature)\"}".utf8)
        var keyring = AutotuneStaticInputs.defaultTrustedPublicKeys
        keyring[keyID] = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let inputs = AutotuneStaticInputs(
            fetch: { url in url.path.hasSuffix(".sig") ? sidecar : served },
            trustedPublicKeys: keyring,
            now: { Self.date(now) }
        )
        return (inputs, keyID)
    }

    func testStaleLiveFeedIsSelectedButUnusable() async throws {
        // 14–30 days old: the live bytes are still the selection (not a
        // fallback), the stale warning is raised, and no artifact-derived
        // capability may use the feed (§3.5 rule 13 / §3.7.6 rule 5).
        let fixture = try boundFixture()
        let live = try signedLiveInputs(feedBytes: fixture.feedBytes, now: "2026-07-30T00:00:00Z")
        let candidate = AutotuneStaticSelection(value: fixture.catalog, selectedBytes: fixture.candidateBytes, warnings: [], usedFallback: false, signerKeyID: live.keyID)
        let selection = await live.inputs.loadArtifactFeed(candidate: candidate, bakedArtifactFeed: fixture.feedBytes)
        XCTAssertNil(selection.value)
        XCTAssertFalse(selection.usedFallback)
        XCTAssertEqual(selection.selectedBytes, fixture.feedBytes)
        XCTAssertEqual(selection.warnings, [.catalogArtifactFeedStale])
        XCTAssertFalse(AutotuneRecommendEngine.paidTrustBlocks(selection.warnings))
    }

    func testSchemaInvalidLiveFeedIsAnIntegrityFailureNotAnUpdateRequirement() async throws {
        // A validly signed document that fails strict decoding must be
        // classified as integrity (§3.5 order), even when its loosely extracted
        // policy_version would differ from the compiled-in one.
        let corpus = try Self.loadCorpus()
        let fixture = try boundFixture()
        var broken = corpus.feed
        broken["candidate_catalog_sha256"] = Self.sha256Hex(fixture.candidateBytes)
        broken["policy_version"] = "autotune-policy-v9"
        broken["unexpected"] = true
        let brokenBytes = try Self.canonical(broken)
        let live = try signedLiveInputs(feedBytes: fixture.feedBytes, now: "2026-07-11T00:00:00Z", fetchFeed: brokenBytes)
        let candidate = AutotuneStaticSelection(value: fixture.catalog, selectedBytes: fixture.candidateBytes, warnings: [], usedFallback: false, signerKeyID: live.keyID)
        let selection = await live.inputs.loadArtifactFeed(
            candidate: candidate, bakedArtifactFeed: fixture.feedBytes, bakedArtifactFeedSignerKeyID: live.keyID
        )
        XCTAssertNil(selection.value)
        XCTAssertTrue(selection.usedFallback)
        XCTAssertTrue(selection.warnings.contains(.catalogArtifactFeedIntegrityFailure))
        XCTAssertFalse(selection.warnings.contains(.catalogArtifactFeedUpdateRequired))
    }

    func testRecommendationInputsCarryTheArtifactFeedBesideTheOtherFeeds() async throws {
        // The production caller: every recommend/models transcript loads the
        // artifact feed for the selected candidate release alongside the three
        // v0.1 feeds, so its warnings reach the same warning sets.
        let inputs = AutotuneStaticInputs(
            fetch: { _ in throw URLError(.cannotConnectToHost) },
            now: { Self.date("2026-07-11T00:00:00Z") }
        )
        let loaded = await inputs.loadRecommendationInputs()
        XCTAssertTrue(loaded.demand.usedFallback)
        // The committed snapshot is rate-card-bound: no feed, no warnings, v0.1 exactly.
        XCTAssertNil(loaded.artifactFeed.value)
        XCTAssertTrue(loaded.artifactFeed.warnings.isEmpty)
        XCTAssertFalse(loaded.artifactFeed.usedFallback)
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
        let digest = "sha256:" + String(repeating: "4", count: 64)

        let without = BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: nil)
        XCTAssertEqual(without.catalogKey(for: "mlx-community/Test-Model-4bit", runtimeSource: "mlx_cache"), "test-model")
        XCTAssertNil(without.catalogKey(for: "test-model:q4_k_m", runtimeSource: "ollama_loopback", digest: digest))

        let with = BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: try XCTUnwrap(qualified(try Self.canonical(feed), candidateBytes: candidateBytes)))
        // A key the feed covers is decided by the artifact leg alone: the row's
        // repo id matches only together with the primary artifact's revision.
        XCTAssertEqual(with.catalogKey(for: "mlx-community/Test-Model-4bit", runtimeSource: "mlx_cache", revisions: [Self.primaryRevision]), "test-model")
        XCTAssertNil(with.catalogKey(for: "mlx-community/Test-Model-4bit", runtimeSource: "mlx_cache"), "name alone, key covered by the feed")
        XCTAssertNil(with.catalogKey(for: "test-model", runtimeSource: "mlx_cache"), "row key alone, key covered by the feed")
        // The corpus gguf secondary is only `declared`: it is identity in the
        // feed but not yet a catalog match (§3.7.4).
        XCTAssertNil(with.catalogKey(for: "TEST-MODEL:Q4_K_M", runtimeSource: "ollama_loopback", digest: digest))
        XCTAssertNil(with.catalogKey(for: "unrelated:latest", runtimeSource: "ollama_loopback", digest: digest))

        feed = try Self.applying([
            ["op": "set", "path": ["models", "test-model", "artifacts", "gguf-q4", "verification_status"], "value": "verified"],
            ["op": "set", "path": ["models", "test-model", "artifacts", "gguf-q4", "verified_at"], "value": "2026-09-01"],
        ], to: feed)
        let verified = BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: try XCTUnwrap(qualified(try Self.canonical(feed), candidateBytes: candidateBytes)))
        // Content-addressed: the tag matches only together with the layer digest.
        XCTAssertEqual(verified.catalogKey(for: "TEST-MODEL:Q4_K_M", runtimeSource: "ollama_loopback", digest: digest), "test-model")
        XCTAssertNil(verified.catalogKey(for: "TEST-MODEL:Q4_K_M", runtimeSource: "ollama_loopback"), "a library tag alone is a mutable name")
        XCTAssertNil(verified.catalogKey(for: "TEST-MODEL:Q4_K_M", runtimeSource: "ollama_loopback", digest: "sha256:" + String(repeating: "f", count: 64)))
        // The adapter reporting the reference must be one the artifact allows.
        XCTAssertNil(verified.catalogKey(for: "TEST-MODEL:Q4_K_M", runtimeSource: "mlx_cache", digest: digest))
        XCTAssertNil(verified.catalogKey(for: "TEST-MODEL:Q4_K_M", runtimeSource: "lmstudio_loopback", digest: digest))
    }

    func testCatalogMatcherNeverMatchesABlockedArtifact() throws {
        let corpus = try Self.loadCorpus()
        let candidateBytes = try Self.canonical(corpus.candidate)
        var feed = corpus.feed
        feed["candidate_catalog_sha256"] = Self.sha256Hex(candidateBytes)
        let gguf = corpus.cases.first { ($0["name"] as! String) == "declared gguf secondary is accepted" }!
        feed = try Self.applying(gguf["ops"] as! [[String: Any]], to: feed)
        feed = try Self.applying([
            ["op": "set", "path": ["models", "test-model", "artifacts", "gguf-q4", "verification_status"], "value": "blocked"],
        ], to: feed)
        let matcher = BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: try XCTUnwrap(qualified(try Self.canonical(feed), candidateBytes: candidateBytes)))
        XCTAssertNil(matcher.catalogKey(for: "test-model:q4_k_m", runtimeSource: "ollama_loopback", digest: "sha256:" + String(repeating: "4", count: 64)))
        // The primary artifact's own identity is unaffected by a sibling's status.
        XCTAssertEqual(matcher.catalogKey(for: "mlx-community/Test-Model-4bit", runtimeSource: "mlx_cache", revisions: [Self.primaryRevision]), "test-model")
    }

    func testFallbackBakedFeedIsAgedLikeSelectedBytes() async throws {
        // §3.7.6 rules 3–5 apply to whichever artifact bytes were SELECTED, the
        // compiled-in fallback included: an offline binary 14+ days after its
        // baked feed's stamp gets no usable feed.
        let fixture = try boundFixture()
        let candidate = AutotuneStaticSelection(value: fixture.catalog, selectedBytes: fixture.candidateBytes, warnings: [], usedFallback: false, signerKeyID: AutotuneStaticInputs.bakedCatalogSignerKeyID)
        let expectations: [(now: String, warnings: Set<AutotuneRecommendWarning>)] = [
            ("2026-07-23T23:00:00Z", [.catalogArtifactFeedFallbackUsed]),
            ("2026-07-24T00:00:00Z", [.catalogArtifactFeedFallbackUsed, .catalogArtifactFeedStale]),
            ("2026-08-09T00:00:01Z", [.catalogArtifactFeedFallbackUsed, .catalogArtifactFeedUpdateRequired]),
            ("2026-07-09T00:00:00Z", [.catalogArtifactFeedFallbackUsed, .catalogArtifactFeedUpdateRequired]),
        ]
        for expectation in expectations {
            let inputs = AutotuneStaticInputs(
                fetch: { _ in throw URLError(.cannotConnectToHost) },
                now: { Self.date(expectation.now) }
            )
            let selection = await inputs.loadArtifactFeed(
                candidate: candidate, bakedArtifactFeed: fixture.feedBytes,
                bakedArtifactFeedSignerKeyID: AutotuneStaticInputs.bakedCatalogSignerKeyID
            )
            XCTAssertEqual(selection.warnings, expectation.warnings, expectation.now)
            XCTAssertTrue(selection.usedFallback, expectation.now)
            XCTAssertEqual(selection.selectedBytes, fixture.feedBytes, expectation.now)
            XCTAssertEqual(selection.value == nil, expectation.warnings.count > 1, expectation.now)
            XCTAssertFalse(AutotuneRecommendEngine.paidTrustBlocks(selection.warnings), expectation.now)
        }
    }

    func testOfflineQualifiedSelectionMatchesTheLoaderVerdict() throws {
        // The compiled-in matcher's feed is the same qualified selection the
        // loader would make for those bytes offline: bound AND fresh.
        let fixture = try boundFixture()
        let signer = AutotuneStaticInputs.bakedCatalogSignerKeyID
        func usable(now: String, signer bakedSigner: String? = signer, candidateSigner: String? = signer) -> QualifiedArtifactFeed? {
            AutotuneStaticInputs.usableArtifactFeed(
                bakedBytes: fixture.feedBytes, bakedSignerKeyID: bakedSigner,
                candidateBytes: fixture.candidateBytes, candidateSignerKeyID: candidateSigner, now: Self.date(now)
            )
        }
        XCTAssertNotNil(usable(now: "2026-07-11T00:00:00Z"))
        XCTAssertNil(usable(now: "2026-07-24T00:00:00Z"), "stale")
        XCTAssertNil(usable(now: "2026-08-09T00:00:01Z"), "expired")
        XCTAssertNil(usable(now: "2026-07-09T00:00:00Z"), "future")
        XCTAssertNil(usable(now: "2026-07-11T00:00:00Z", signer: nil), "no manifest signer")
        XCTAssertNil(usable(now: "2026-07-11T00:00:00Z", signer: "streamvc-autotune-static-v5"), "other signer")
        XCTAssertNil(AutotuneStaticInputs.usableArtifactFeed(
            bakedBytes: nil, bakedSignerKeyID: signer, candidateBytes: fixture.candidateBytes,
            candidateSignerKeyID: signer, now: Self.date("2026-07-11T00:00:00Z")
        ))
        let stale = BYOMCatalogMatcher(candidateBytes: fixture.candidateBytes, artifactFeed: usable(now: "2026-07-24T00:00:00Z"))
        XCTAssertEqual(stale.catalogKey(for: "mlx-community/Test-Model-4bit", runtimeSource: "mlx_cache"), "test-model", "candidate-row identity is rule 6")
    }

    private static let secondRevision = String(repeating: "3", count: 40)
    private static let primaryRevision = String(repeating: "1", count: 40)

    private func feedWithArtifactOnlyReference() throws -> (candidateBytes: Data, feedBytes: Data, feed: QualifiedArtifactFeed) {
        let corpus = try Self.loadCorpus()
        let candidateBytes = try Self.canonical(corpus.candidate)
        var feed = corpus.feed
        feed["candidate_catalog_sha256"] = Self.sha256Hex(candidateBytes)
        let second = corpus.cases.first { ($0["name"] as! String) == "second verified mlx artifact under another repo id" }!
        feed = try Self.applying(second["ops"] as! [[String: Any]], to: feed)
        let feedBytes = try Self.canonical(feed)
        return (candidateBytes, feedBytes, try XCTUnwrap(qualified(feedBytes, candidateBytes: candidateBytes)))
    }

    func testDiscoveryEmitsNoArtifactDerivedMatchFromAnUnusableSelection() throws {
        // An MLX snapshot known ONLY through the artifact feed (its repo id is
        // not a candidate row's model id) is catalog_matched with a usable
        // selection and unmatched with none; the row-known snapshot is matched
        // either way (rule 6).
        let fixture = try feedWithArtifactOnlyReference()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("byom-artifact-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (modelID, revision) in [("mlx-community/Test-Model-8bit", Self.secondRevision), ("mlx-community/Test-Model-4bit", Self.primaryRevision)] {
            let directory = root.appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"))
                .appendingPathComponent("snapshots").appendingPathComponent(revision)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
            try Data(repeating: 0, count: 16).write(to: directory.appendingPathComponent("model.safetensors"))
        }
        // Revisions are identity-load-bearing: 300 older snapshot directories
        // (beyond the 256-entry content-scan cap) that sort before the
        // artifact's revision must not hide it.
        for index in 0..<300 {
            let stale = root.appendingPathComponent("models--mlx-community--Test-Model-8bit/snapshots")
                .appendingPathComponent(String(repeating: "0", count: 37) + String(format: "%03x", index))
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        }
        let namespace = Data(repeating: 0x37, count: 32)
        func keys(_ matcher: BYOMCatalogMatcher) -> [String: String?] {
            let result = BYOMMLXCacheDiscovery(cacheRoot: root, namespace: namespace, catalogMatcher: matcher).discover()
            return Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.servedModelRef, $0.catalogModelKey) })
        }
        let usable = keys(BYOMCatalogMatcher(candidateBytes: fixture.candidateBytes, artifactFeed: fixture.feed))
        XCTAssertEqual(usable["mlx-community/Test-Model-8bit"], "test-model")
        XCTAssertEqual(usable["mlx-community/Test-Model-4bit"], "test-model")
        // No usable feed: the v0.1 name-level row leg (rule 6).
        let unusable = keys(BYOMCatalogMatcher(candidateBytes: fixture.candidateBytes, artifactFeed: nil))
        XCTAssertEqual(unusable["mlx-community/Test-Model-8bit"], .some(nil))
        XCTAssertEqual(unusable["mlx-community/Test-Model-4bit"], "test-model")
        // A usable feed covering the key: the row's repo id at a revision the
        // feed does not know is NOT that catalog identity.
        let primary = root.appendingPathComponent("models--mlx-community--Test-Model-4bit/snapshots")
        try FileManager.default.moveItem(at: primary.appendingPathComponent(Self.primaryRevision), to: primary.appendingPathComponent(String(repeating: "d", count: 40)))
        let primaryRebased = keys(BYOMCatalogMatcher(candidateBytes: fixture.candidateBytes, artifactFeed: fixture.feed))
        XCTAssertEqual(primaryRebased["mlx-community/Test-Model-4bit"], .some(nil))
        try FileManager.default.moveItem(at: primary.appendingPathComponent(String(repeating: "d", count: 40)), to: primary.appendingPathComponent(Self.primaryRevision))
        // A snapshot at another revision than the artifact's is a different set
        // of bytes: the repo id alone never matches (SPEC-023 §3.7.4).
        let otherRevision = root.appendingPathComponent("models--mlx-community--Test-Model-8bit/snapshots")
        try FileManager.default.removeItem(at: otherRevision.appendingPathComponent(Self.secondRevision))
        let moved = otherRevision.appendingPathComponent(String(repeating: "e", count: 40))
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: moved.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 16).write(to: moved.appendingPathComponent("model.safetensors"))
        let rebased = keys(BYOMCatalogMatcher(candidateBytes: fixture.candidateBytes, artifactFeed: fixture.feed))
        XCTAssertEqual(rebased["mlx-community/Test-Model-8bit"], .some(nil))
        XCTAssertEqual(rebased["mlx-community/Test-Model-4bit"], "test-model")
    }

    func testCatalogMatcherNeverMatchesCandidateOrBlockedRows() throws {
        // SPEC-023 §3.2 ladder: a `candidate` row is never BYOM-matchable and a
        // `blocked` row is diagnostic only — by row identity or by artifact.
        let corpus = try Self.loadCorpus()
        let fixture = try feedWithArtifactOnlyReference()
        for status in ["candidate", "blocked"] {
            var candidate = corpus.candidate
            var rows = candidate["rows"] as! [String: Any]
            var row = rows["test-model"] as! [String: Any]
            row["runtime_status"] = status
            rows["test-model"] = row
            candidate["rows"] = rows
            let candidateBytes = try Self.canonical(candidate)
            XCTAssertNoThrow(try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes), status)
            var rebound = corpus.feed
            rebound["candidate_catalog_sha256"] = Self.sha256Hex(candidateBytes)
            let second = corpus.cases.first { ($0["name"] as! String) == "second verified mlx artifact under another repo id" }!
            rebound = try Self.applying(second["ops"] as! [[String: Any]], to: rebound)
            let matcher = BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: qualified(try Self.canonical(rebound), candidateBytes: candidateBytes))
            XCTAssertNil(matcher.catalogKey(for: "mlx-community/Test-Model-4bit", runtimeSource: "mlx_cache", revisions: [Self.primaryRevision]), status)
            XCTAssertNil(matcher.catalogKey(for: "test-model", runtimeSource: "mlx_cache"), status)
            XCTAssertNil(matcher.catalogKey(for: "mlx-community/Test-Model-8bit", runtimeSource: "mlx_cache", revisions: [Self.secondRevision]), status)
        }
        for status in ["listed", "recommendable"] {
            var candidate = corpus.candidate
            var rows = candidate["rows"] as! [String: Any]
            var row = rows["test-model"] as! [String: Any]
            row["runtime_status"] = status
            rows["test-model"] = row
            candidate["rows"] = rows
            let candidateBytes = try Self.canonical(candidate)
            var rebound = corpus.feed
            rebound["candidate_catalog_sha256"] = Self.sha256Hex(candidateBytes)
            let second = corpus.cases.first { ($0["name"] as! String) == "second verified mlx artifact under another repo id" }!
            rebound = try Self.applying(second["ops"] as! [[String: Any]], to: rebound)
            let matcher = BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: try XCTUnwrap(qualified(try Self.canonical(rebound), candidateBytes: candidateBytes), status))
            XCTAssertEqual(matcher.catalogKey(for: "mlx-community/Test-Model-8bit", runtimeSource: "mlx_cache", revisions: [Self.secondRevision]), "test-model", status)
            XCTAssertNil(matcher.catalogKey(for: "mlx-community/Test-Model-8bit", runtimeSource: "mlx_cache"), "revision is required: \(status)")
        }
        _ = fixture
    }

    func testAmbiguousServedReferenceMintsNoCatalogIdentity() throws {
        // Two listed/recommendable rows whose verified MLX artifacts share a
        // normalized repo id at different revisions (distinct hashes, so every
        // validator accepts the feed): the reference answers to two model keys
        // and discovery must not pick one by sort order.
        let corpus = try Self.loadCorpus()
        var candidate = corpus.candidate
        var rows = candidate["rows"] as! [String: Any]
        var other = rows["test-model"] as! [String: Any]
        other["model_id"] = "mlx-community/Other-Model-4bit"
        other["model_revision"] = String(repeating: "9", count: 40)
        other["model_sha256"] = String(repeating: "8", count: 64)
        rows["other-model"] = other
        candidate["rows"] = rows
        let candidateBytes = try Self.canonical(candidate)

        let fixture = try feedWithArtifactOnlyReference()
        var feed = corpus.feed
        feed["candidate_catalog_sha256"] = Self.sha256Hex(candidateBytes)
        let second = corpus.cases.first { ($0["name"] as! String) == "second verified mlx artifact under another repo id" }!
        feed = try Self.applying(second["ops"] as! [[String: Any]], to: feed)
        var otherPrimary = (second["ops"] as! [[String: Any]])[0]["value"] as! [String: Any]
        otherPrimary["quantization"] = "4bit"
        otherPrimary["min_ram_gb"] = 4
        otherPrimary["hash"] = String(repeating: "8", count: 64)
        otherPrimary["source_ref"] = ["kind": "huggingface_revision", "repo_id": "mlx-community/Other-Model-4bit", "revision": String(repeating: "9", count: 40)]
        var otherSecondary = otherPrimary
        otherSecondary["hash"] = String(repeating: "6", count: 64)
        otherSecondary["source_ref"] = ["kind": "huggingface_revision", "repo_id": "mlx-community/Test-Model-8bit", "revision": String(repeating: "4", count: 40)]
        feed = try Self.applying([
            ["op": "set", "path": ["models", "other-model"], "value": [
                "rate_class": "class-8b", "primary_artifact_id": "mlx-4bit",
                "artifacts": ["mlx-4bit": otherPrimary, "mlx-8bit": otherSecondary],
            ]],
        ], to: feed)
        let decoded = try XCTUnwrap(qualified(try Self.canonical(feed), candidateBytes: candidateBytes))
        XCTAssertEqual(decoded.feed.models.count, 2)
        let matcher = BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: decoded)
        // Both revisions observed locally: the reference answers to two keys.
        let both: Set<String> = [Self.secondRevision, String(repeating: "4", count: 40)]
        XCTAssertNil(matcher.catalogKey(for: "mlx-community/Test-Model-8bit", runtimeSource: "mlx_cache", revisions: both), "ambiguous")
        // One revision observed: the immutable half disambiguates.
        XCTAssertEqual(matcher.catalogKey(for: "mlx-community/Test-Model-8bit", runtimeSource: "mlx_cache", revisions: [Self.secondRevision]), "test-model")
        XCTAssertEqual(matcher.catalogKey(for: "mlx-community/Test-Model-8bit", runtimeSource: "mlx_cache", revisions: [String(repeating: "4", count: 40)]), "other-model")
        XCTAssertEqual(matcher.catalogKey(for: "mlx-community/Other-Model-4bit", runtimeSource: "mlx_cache", revisions: [String(repeating: "9", count: 40)]), "other-model")
        XCTAssertEqual(matcher.catalogKey(for: "mlx-community/Test-Model-4bit", runtimeSource: "mlx_cache", revisions: [Self.primaryRevision]), "test-model")
        XCTAssertNil(matcher.catalogKey(for: "mlx-community/Other-Model-4bit", runtimeSource: "mlx_cache"), "covered key, name alone")
        // Unambiguous in a feed where only one model carries the reference.
        let single = BYOMCatalogMatcher(candidateBytes: fixture.candidateBytes, artifactFeed: fixture.feed)
        XCTAssertEqual(single.catalogKey(for: "mlx-community/Test-Model-8bit", runtimeSource: "mlx_cache", revisions: [Self.secondRevision]), "test-model")
        // The artifact leg also yields the identity with its provenance; the
        // ambiguous case and a name-level row match yield nothing.
        let matched = try XCTUnwrap(single.matchedArtifact(for: "mlx-community/Test-Model-8bit", runtimeSource: "mlx_cache", revisions: [Self.secondRevision]))
        XCTAssertEqual(matched.identity.artifactID, "mlx-8bit")
        XCTAssertEqual(matched.identity.hash, String(repeating: "5", count: 64))
        XCTAssertFalse(matched.identity.isPrimary)
        XCTAssertEqual(matched.feedSHA256, fixture.feed.feedSHA256)
        XCTAssertEqual(matched.signerKeyID, Self.signer)
        XCTAssertEqual(matched.releaseID, "test-release")
        XCTAssertNil(matcher.matchedArtifact(for: "mlx-community/Test-Model-8bit", runtimeSource: "mlx_cache", revisions: both))
        XCTAssertNil(BYOMCatalogMatcher(candidateBytes: fixture.candidateBytes, artifactFeed: nil).matchedArtifact(for: "mlx-community/Test-Model-4bit", runtimeSource: "mlx_cache"))
    }

    func testAmbiguousCandidateRowIdentityMintsNoCatalogIdentity() throws {
        // Two matchable rows sharing a normalized model id (same signed bytes
        // under two keys): the row leg refuses to pick one by dictionary order,
        // exactly like the artifact leg.
        let corpus = try Self.loadCorpus()
        var candidate = corpus.candidate
        var rows = candidate["rows"] as! [String: Any]
        rows["test-model-alias"] = rows["test-model"]
        candidate["rows"] = rows
        let matcher = BYOMCatalogMatcher(candidateBytes: try Self.canonical(candidate), artifactFeed: nil)
        XCTAssertNil(matcher.catalogKey(for: "mlx-community/Test-Model-4bit", runtimeSource: "mlx_cache"))
        XCTAssertEqual(matcher.catalogKey(for: "test-model-alias", runtimeSource: "mlx_cache"), "test-model-alias")
    }

    func testArtifactFeedWarningsLeaveTheCandidateWarningStateUntouched() {
        // §3.7.6 rule 6 at the per-candidate `explanation.warning_state`: the
        // artifact classes ride in `warnings[]` only.
        for warning in AutotuneRecommendEngine.artifactFeedWarnings {
            XCTAssertEqual(
                AutotuneRecommendEngine.warningState(eligible: true, confidence: "high", localHealthWarnings: [], candidateWarnings: Set([warning]).subtracting(AutotuneRecommendEngine.artifactFeedWarnings)),
                "ready", warning.rawValue
            )
        }
        XCTAssertEqual(
            AutotuneRecommendEngine.warningState(eligible: true, confidence: "high", localHealthWarnings: [], candidateWarnings: [.rateCardFallbackUsed]),
            "advisory"
        )
    }

    func testUndecodableCompiledInSnapshotIsAnIntegrityFailureNotATrap() async throws {
        // The shared loader force-unwraps its baked decode; the artifact feed
        // must never take the v0.1 path down (§3.7.6 rule 6).
        let fixture = try boundFixture()
        let candidate = AutotuneStaticSelection(value: fixture.catalog, selectedBytes: fixture.candidateBytes, warnings: [], usedFallback: false, signerKeyID: Self.signer)
        let inputs = AutotuneStaticInputs(
            fetch: { _ in XCTFail("no fetch without a decodable fallback"); throw URLError(.badURL) },
            now: { Self.date("2026-07-11T00:00:00Z") }
        )
        for broken in [Data("not json".utf8), Data("{\"models\":{}}".utf8), Data()] {
            let selection = await inputs.loadArtifactFeed(candidate: candidate, bakedArtifactFeed: broken, bakedArtifactFeedSignerKeyID: Self.signer)
            XCTAssertNil(selection.value)
            XCTAssertEqual(selection.warnings, [.catalogArtifactFeedIntegrityFailure])
            XCTAssertTrue(selection.usedFallback)
            XCTAssertFalse(AutotuneRecommendEngine.paidTrustBlocks(selection.warnings))
            XCTAssertFalse(AutotuneRecommendEngine.networkSubmissionBlocks(selection.warnings))
        }
        XCTAssertNil(AutotuneStaticInputs.usableArtifactFeed(
            bakedBytes: Data("not json".utf8), bakedSignerKeyID: Self.signer,
            candidateBytes: fixture.candidateBytes, candidateSignerKeyID: Self.signer, now: Self.date("2026-07-11T00:00:00Z")
        ))
    }

    func testCompiledInArtifactFeedDecodesAndQualifiesWhenPresent() throws {
        // A no-op until the activation release; from then on the gate that a
        // bake the generator accepted is one this decoder accepts and binds.
        guard let bytes = AutotuneStaticInputs.bakedArtifactFeedBytes else { return }
        XCTAssertNoThrow(try AutotuneStaticInputs.decodeArtifactFeed(bytes))
        XCTAssertNotNil(AutotuneStaticInputs.bakedArtifactFeedSignerKeyID)
        let feed = try AutotuneStaticInputs.decodeArtifactFeed(bytes)
        XCTAssertNotNil(AutotuneStaticInputs.bakedUsableArtifactFeed(now: feed.generatedAt.addingTimeInterval(60)))
    }

    func testGrammarsRejectATrailingLineTerminator() throws {
        // ICU's `$` matches before a final line terminator; Go and Python do
        // not. The decoder requires whole-string matches.
        let fixture = try boundFixture()
        let text = String(decoding: fixture.feedBytes, as: UTF8.self)
        for (needle, replacement) in [
            ("\"hash\":\"" + String(repeating: "2", count: 64) + "\"", "\"hash\":\"" + String(repeating: "2", count: 64) + "\\n\""),
            ("\"revision\":\"" + String(repeating: "1", count: 40) + "\"", "\"revision\":\"" + String(repeating: "1", count: 40) + "\\r\""),
            ("\"mlx-4bit\":{", "\"mlx-4bit\\n\":{"),
        ] {
            XCTAssertTrue(text.contains(needle), needle)
            let mutated = Data(text.replacingOccurrences(of: needle, with: replacement).utf8)
            XCTAssertThrowsError(try AutotuneStaticInputs.decodeArtifactFeed(mutated), needle)
        }
    }

    func testDuplicateObjectKeyInRawBytesIsRejectedBeforeDeserialization() throws {
        // The corpus works on object models and cannot carry a duplicate key;
        // the lexical rule is pinned on raw bytes here.
        let fixture = try boundFixture()
        let text = String(decoding: fixture.feedBytes, as: UTF8.self)
        let needle = "\"policy_version\":\"autotune-policy-v1\""
        XCTAssertTrue(text.contains(needle))
        let duplicated = Data(text.replacingOccurrences(of: needle, with: needle + "," + needle).utf8)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: duplicated), "Foundation itself tolerates the duplicate")
        XCTAssertThrowsError(try AutotuneStaticInputs.decodeArtifactFeed(duplicated))
        let nested = Data(text.replacingOccurrences(of: "\"quantization\":\"4bit\"", with: "\"quantization\":\"4bit\",\"quantization\":\"4bit\"").utf8)
        XCTAssertThrowsError(try AutotuneStaticInputs.decodeArtifactFeed(nested))
    }

    func testGeneratedAtGrammarIsSecondsPrecisionWithExplicitZone() throws {
        for (raw, ok) in [
            ("2026-07-10T00:00:00Z", true), ("2026-07-10T02:00:00+02:00", true),
            ("2026-07-10T00:00:00.000Z", false), ("2026-07-10T00:00:00,000Z", false),
            ("2026-07-10T00:00:00", false), ("2026-07-10 00:00:00Z", false),
        ] {
            XCTAssertEqual(raw.range(of: ArtifactFeed.timestampGrammar, options: .regularExpression) != nil, ok, raw)
        }
    }

    func testGeneratedAtIsCarriedAsTheExactReleaseStamp() throws {
        let fixture = try boundFixture()
        let feed = try AutotuneStaticInputs.decodeArtifactFeed(fixture.feedBytes)
        XCTAssertEqual(feed.generatedAtRaw, "2026-07-10T00:00:00Z")
        XCTAssertEqual(ArtifactFeed.rawGeneratedAt(in: fixture.candidateBytes), "2026-07-10T00:00:00Z")
    }

    func testCommittedSnapshotBakesNoArtifactFeedUntilActivation() {
        // The committed release is rate-card-bound: the compiled-in feed is nil and
        // the compiled-in matcher behaves exactly as v0.1.
        XCTAssertNil(AutotuneStaticInputs.bakedArtifactFeedBase64)
        XCTAssertNil(AutotuneStaticInputs.bakedArtifactFeedBytes)
        XCTAssertNil(AutotuneStaticInputs.bakedArtifactFeedSignerKeyID)
        XCTAssertNil(AutotuneStaticInputs.bakedUsableArtifactFeed())
    }
}
