import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-023 v0.16.0 (#1690 M1, B3a): a `gguf` artifact sourced by
/// `huggingface_revision` with a REQUIRED `file_path`. The CLI must accept the
/// tuple exactly as the coordinator (`buyer/catalog_artifacts_feed.go`) does,
/// and resolve a llama.cpp-served GGUF through it on the compiled-in (baked)
/// feed path: discover / evaluate / offer all use `BYOMCatalogMatcher` over
/// `usableArtifactFeed`.
final class AutotuneArtifactFeedGGUFRevisionTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let rowKey = "meta-llama/llama-3.2-3b-instruct"
    private static let ggufID = "gguf-q4-k-m"
    /// The M1 tuple (plan §3.2), hash verified on the Mac Studio 2026-09-25.
    private static let m1Hash = "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff"
    private static let m1Repo = "bartowski/Llama-3.2-3B-Instruct-GGUF"
    private static let m1Revision = "5ab33fa94d1d04e903623ae72c95d1696f09f9e8"
    private static let m1File = "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    private static let ggufBytes = Data("GGUF".utf8) + Data(repeating: 0x33, count: 8192)

    private static func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private static func ggufEntry(hash: String = m1Hash, sources: [String] = ["llamacpp_loopback"], sourceRef: [String: Any]? = nil) -> [String: Any] {
        [
            "allowed_runtime_sources": sources,
            "hash": hash,
            "hash_algorithm": "macprovider.gguf-file.v1",
            "min_ram_gb": 4,
            "quantization": "q4_k_m",
            "runtime_format": "gguf",
            "size_bytes": 2019377696,
            "source_ref": sourceRef ?? ["kind": "huggingface_revision", "repo_id": m1Repo, "revision": m1Revision, "file_path": m1File],
            "verification_status": "verified",
            "verified_at": "2026-09-25",
        ]
    }

    /// A feed in the exact shape `catalog-release.py generate` emits for the
    /// committed release, built from the committed artifact source and bound
    /// to the COMPILED-IN candidate catalog, with `gguf` as its GGUF entry.
    private static func bakedReleaseFeed(gguf: [String: Any]) throws -> (feed: Data, candidate: Data, generatedAt: Date) {
        let candidateBytes = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let candidate = try JSONSerialization.jsonObject(with: candidateBytes) as! [String: Any]
        let sourceURL = repoRoot.appendingPathComponent("phase3-binary/catalog/autotune/autotune-artifacts-source.json")
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL)) as! [String: Any]
        var models = source["models"] as! [String: Any]
        for (key, value) in models {
            var model = value as! [String: Any]
            var artifacts = model["artifacts"] as! [String: Any]
            for (id, raw) in artifacts {
                var artifact = raw as! [String: Any]
                if artifact["size_bytes"] is NSNull { artifact["size_bytes"] = 1 }
                artifacts[id] = artifact
            }
            if key == rowKey { artifacts[ggufID] = gguf }
            model["artifacts"] = artifacts
            models[key] = model
        }
        let feed: [String: Any] = [
            "candidate_catalog_sha256": sha256Hex(candidateBytes),
            "generated_at": candidate["generated_at"]!,
            "models": models,
            "policy_version": candidate["policy_version"]!,
            "release_id": candidate["version"]!,
            "source": ArtifactFeed.source,
            "version": candidate["version"]!,
        ]
        let generatedAt = ISO8601DateFormatter.autotuneInternet.date(from: candidate["generated_at"] as! String)!
        return (try canonical(feed), candidateBytes, generatedAt)
    }

    /// The baked selection exactly as `bakedUsableArtifactFeed` makes it.
    private static func bakedQualified(_ feed: Data, candidate: Data, generatedAt: Date) -> QualifiedArtifactFeed? {
        AutotuneStaticInputs.usableArtifactFeed(
            bakedBytes: feed,
            bakedSignerKeyID: AutotuneStaticInputs.bakedCatalogSignerKeyID,
            candidateBytes: candidate,
            candidateSignerKeyID: AutotuneStaticInputs.bakedCatalogSignerKeyID,
            now: generatedAt.addingTimeInterval(3600)
        )
    }

    private func decodeAndBind(_ feed: Data, candidate: Data) throws {
        let catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidate)
        try AutotuneStaticInputs.decodeArtifactFeed(feed).bind(
            to: catalog, candidateBytes: candidate, candidateSignerKeyID: "k", artifactSignerKeyID: "k"
        )
    }

    // MARK: - Decode: accept

    func testM1TupleDecodesAndBindsToTheCompiledInRelease() throws {
        let release = try Self.bakedReleaseFeed(gguf: Self.ggufEntry())
        XCTAssertNoThrow(try decodeAndBind(release.feed, candidate: release.candidate))
        let artifact = try XCTUnwrap(try AutotuneStaticInputs.decodeArtifactFeed(release.feed).models[Self.rowKey]?.artifacts[Self.ggufID])
        XCTAssertEqual(artifact.sourceRef, ArtifactFeed.SourceRef(
            kind: "huggingface_revision", repoID: Self.m1Repo, revision: Self.m1Revision,
            libraryTag: nil, digest: nil, filePath: Self.m1File
        ))
        XCTAssertNotNil(Self.bakedQualified(release.feed, candidate: release.candidate, generatedAt: release.generatedAt),
                        "the baked path must qualify a feed carrying the v0.16.0 tuple")
    }

    func testNestedFilePathAndEveryGGUFLoopbackSourceAreLegal() throws {
        for sources in [["llamacpp_loopback"], ["lmstudio_loopback", "ollama_loopback"], ["llamacpp_loopback", "lmstudio_loopback", "ollama_loopback"]] {
            let entry = Self.ggufEntry(sources: sources, sourceRef: [
                "kind": "huggingface_revision", "repo_id": Self.m1Repo, "revision": Self.m1Revision,
                "file_path": "Q4_K_M/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            ])
            let release = try Self.bakedReleaseFeed(gguf: entry)
            XCTAssertNoThrow(try decodeAndBind(release.feed, candidate: release.candidate), "\(sources)")
        }
    }

    // MARK: - Decode: reject (catalog_artifact_feed_integrity_failure)

    func testIllegalHuggingFaceGGUFTuplesAreIntegrityFailures() throws {
        let base: [String: Any] = ["kind": "huggingface_revision", "repo_id": Self.m1Repo, "revision": Self.m1Revision]
        func ref(_ extra: [String: Any]) -> [String: Any] { base.merging(extra) { $1 } }
        let cases: [(String, [String: Any])] = [
            ("missing file_path", Self.ggufEntry(sourceRef: base)),
            ("absolute file_path", Self.ggufEntry(sourceRef: ref(["file_path": "/models/x.gguf"]))),
            ("dot-dot segment", Self.ggufEntry(sourceRef: ref(["file_path": "a/../x.gguf"]))),
            ("dot segment", Self.ggufEntry(sourceRef: ref(["file_path": "./x.gguf"]))),
            ("not a gguf file", Self.ggufEntry(sourceRef: ref(["file_path": "x.safetensors"]))),
            ("uppercase extension", Self.ggufEntry(sourceRef: ref(["file_path": "x.GGUF"]))),
            ("space in path", Self.ggufEntry(sourceRef: ref(["file_path": "my model.gguf"]))),
            ("trailing newline", Self.ggufEntry(sourceRef: ref(["file_path": "x.gguf\n"]))),
            ("over 255 bytes", Self.ggufEntry(sourceRef: ref(["file_path": String(repeating: "a", count: 252) + ".gguf"]))),
            ("null file_path", Self.ggufEntry(sourceRef: ref(["file_path": NSNull()]))),
            ("digest present", Self.ggufEntry(sourceRef: ref(["file_path": Self.m1File, "digest": "sha256:" + Self.m1Hash]))),
            ("library_tag present", Self.ggufEntry(sourceRef: ref(["file_path": Self.m1File, "library_tag": "llama3.2:3b"]))),
            ("file_path on an ollama gguf", Self.ggufEntry(sourceRef: [
                "kind": "ollama_library_tag", "library_tag": "llama3.2:3b", "digest": "sha256:" + Self.m1Hash, "file_path": Self.m1File,
            ])),
            ("mlx_cache runtime source", Self.ggufEntry(sources: ["llamacpp_loopback", "mlx_cache"])),
            ("mlxlm_loopback runtime source", Self.ggufEntry(sources: ["mlxlm_loopback"])),
            ("verified openai_compatible_loopback", Self.ggufEntry(sources: ["llamacpp_loopback", "openai_compatible_loopback"])),
        ]
        for (name, entry) in cases {
            let release = try Self.bakedReleaseFeed(gguf: entry)
            XCTAssertThrowsError(try decodeAndBind(release.feed, candidate: release.candidate), name) {
                guard case ArtifactFeedError.integrity = $0 else {
                    return XCTFail("\(name): \($0) is not an integrity failure")
                }
            }
            XCTAssertNil(Self.bakedQualified(release.feed, candidate: release.candidate, generatedAt: release.generatedAt), name)
        }
    }

    func testMLXPrimaryMayNotCarryFilePath() throws {
        var release = try Self.bakedReleaseFeed(gguf: Self.ggufEntry())
        var feed = try JSONSerialization.jsonObject(with: release.feed) as! [String: Any]
        var models = feed["models"] as! [String: Any]
        var model = models[Self.rowKey] as! [String: Any]
        var artifacts = model["artifacts"] as! [String: Any]
        var primary = artifacts[model["primary_artifact_id"] as! String] as! [String: Any]
        var ref = primary["source_ref"] as! [String: Any]
        ref["file_path"] = "model.gguf"
        primary["source_ref"] = ref
        artifacts[model["primary_artifact_id"] as! String] = primary
        model["artifacts"] = artifacts
        models[Self.rowKey] = model
        feed["models"] = models
        release.feed = try Self.canonical(feed)
        XCTAssertThrowsError(try decodeAndBind(release.feed, candidate: release.candidate))
    }

    func testFilePathGrammarMatchesTheCoordinator() {
        XCTAssertTrue(ArtifactFeed.validGGUFFilePath("Llama-3.2-3B-Instruct-Q4_K_M.gguf"))
        XCTAssertTrue(ArtifactFeed.validGGUFFilePath("Q4_K_M/test-model-Q4_K_M.gguf"))
        XCTAssertTrue(ArtifactFeed.validGGUFFilePath(String(repeating: "a", count: 250) + ".gguf"))
        XCTAssertFalse(ArtifactFeed.validGGUFFilePath(String(repeating: "a", count: 251) + ".gguf"))
        for bad in ["", ".gguf/", "a//b.gguf", "a/./b.gguf", "../b.gguf", "b.gguf/", "b.gguf.bak", "ü.gguf"] {
            XCTAssertFalse(ArtifactFeed.validGGUFFilePath(bad), bad)
        }
    }

    // MARK: - Identity resolution on the baked path

    func testCatalogMatcherResolvesTheHuggingFaceGGUFByItsFileDigestOnly() throws {
        let release = try Self.bakedReleaseFeed(gguf: Self.ggufEntry())
        let matcher = BYOMCatalogMatcher(
            candidateBytes: release.candidate,
            artifactFeed: try XCTUnwrap(Self.bakedQualified(release.feed, candidate: release.candidate, generatedAt: release.generatedAt))
        )
        let digest = "sha256:" + Self.m1Hash
        // The llama.cpp adapter reports the served file's stem; any stem binds
        // through the CLI-computed digest of the served bytes.
        XCTAssertEqual(matcher.catalogKey(for: "Llama-3.2-3B-Instruct-Q4_K_M", runtimeSource: "llamacpp_loopback", digest: digest), Self.rowKey)
        XCTAssertEqual(matcher.catalogKey(for: "renamed-by-operator", runtimeSource: "llamacpp_loopback", digest: digest), Self.rowKey)
        let matched = try XCTUnwrap(matcher.matchedArtifact(for: "Llama-3.2-3B-Instruct-Q4_K_M", runtimeSource: "llamacpp_loopback", digest: digest))
        XCTAssertEqual(matched.identity.artifactID, Self.ggufID)
        XCTAssertEqual(matched.identity.hash, Self.m1Hash)
        XCTAssertFalse(matched.identity.isPrimary)
        // No digest, another digest, or a runtime the artifact does not allow: no identity.
        XCTAssertNil(matcher.catalogKey(for: "Llama-3.2-3B-Instruct-Q4_K_M", runtimeSource: "llamacpp_loopback"))
        XCTAssertNil(matcher.catalogKey(for: "Llama-3.2-3B-Instruct-Q4_K_M", runtimeSource: "llamacpp_loopback", digest: "sha256:" + String(repeating: "f", count: 64)))
        XCTAssertNil(matcher.catalogKey(for: "Llama-3.2-3B-Instruct-Q4_K_M", runtimeSource: "ollama_loopback", digest: digest))
        XCTAssertNil(matcher.catalogKey(for: "Llama-3.2-3B-Instruct-Q4_K_M", runtimeSource: "llamacpp_loopback", digest: Self.m1Hash), "digest without its sha256: prefix")
        // The repo id with the revision is the MLX leg, never the GGUF artifact.
        XCTAssertNil(matcher.matchedArtifact(for: Self.m1Repo, runtimeSource: "llamacpp_loopback", revisions: [Self.m1Revision]))
    }

    func testLlamaCppDiscoveryIsCatalogMatchedThroughTheBakedFeed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gguf-hf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let file = models.appendingPathComponent(Self.m1File)
        try Self.ggufBytes.write(to: file)
        let servedPath = file.resolvingSymlinksInPath().standardizedFileURL.path

        // The release's GGUF entry names the bytes this runtime serves.
        let hash = Self.sha256Hex(Self.ggufBytes)
        let release = try Self.bakedReleaseFeed(gguf: Self.ggufEntry(hash: hash))
        let matcher = BYOMCatalogMatcher(
            candidateBytes: release.candidate,
            artifactFeed: try XCTUnwrap(Self.bakedQualified(release.feed, candidate: release.candidate, generatedAt: release.generatedAt))
        )
        let resolver = BYOMArtifactDigestResolver(
            locators: [BYOMLlamaCppModelStore(root: nil, pinnedFile: file)],
            cache: BYOMArtifactDigestCache(url: root.appendingPathComponent("digests.json"))
        )
        // Offer/evaluate binding: the CLI hashes the served file itself.
        let evidence = try resolver.computeEvidence(runtimeSource: "llamacpp_loopback", servedModelRef: "llamacpp:Llama-3.2-3B-Instruct-Q4_K_M", runtimeArtifactPath: servedPath)
        XCTAssertEqual(evidence.digest, hash)

        let client = StaticRoutesHTTPClient(routes: [
            "/props": #"{"default_generation_settings":{"n_ctx":8192},"total_slots":4,"model_path":"\#(servedPath)"}"#,
            "/v1/models": #"{"data":[{"id":"\#(servedPath)"}]}"#,
        ])
        let discovery = await BYOMLlamaCppDiscovery(
            origin: "http://127.0.0.1:18130",
            namespace: Data(repeating: 0x42, count: 32),
            catalogMatcher: matcher,
            httpClient: client,
            artifactDigests: resolver
        ).discover()
        XCTAssertEqual(discovery.adapter.status, "ok")
        let candidate = try XCTUnwrap(discovery.candidates.first)
        XCTAssertEqual(candidate.servedModelRef, "llamacpp:Llama-3.2-3B-Instruct-Q4_K_M")
        XCTAssertEqual(candidate.catalogModelKey, Self.rowKey)
        XCTAssertEqual(candidate.identityState, "catalog_matched")
        let member = try XCTUnwrap(matcher.matchedArtifact(for: "Llama-3.2-3B-Instruct-Q4_K_M", runtimeSource: "llamacpp_loopback", digest: "sha256:" + evidence.digest))
        XCTAssertEqual(member.identity.artifactID, Self.ggufID)
        XCTAssertEqual(member.releaseID, try XCTUnwrap(AutotuneStaticInputs.decodeArtifactFeed(release.feed).releaseID))
    }
}

/// GET-only loopback stub; `post` keeps the protocol default.
private final class StaticRoutesHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let routes: [String: String]

    init(routes: [String: String]) {
        self.routes = routes
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        guard let body = routes.first(where: { url.path.hasSuffix($0.key) })?.value else {
            return BYOMHTTPResponse(statusCode: 404, headers: [], body: Data())
        }
        return BYOMHTTPResponse(statusCode: 200, headers: [("content-type", "application/json")], body: Data(body.utf8))
    }
}
