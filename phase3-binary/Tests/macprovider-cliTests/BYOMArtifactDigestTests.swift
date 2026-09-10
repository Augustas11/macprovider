import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-010 v1.7 R007(a) on the CLI: the GGUF digest is computed over the
/// complete bytes of the blob the local Ollama store serves, bound to that
/// file's identity, and never adopted from what the runtime reports.
final class BYOMArtifactDigestTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures/artifact_feed_conformance.json")

    private struct Store {
        let root: URL
        let cacheURL: URL
        let blobURL: URL
        let blobBytes: Data
        let manifestDigest: String
        var resolver: BYOMArtifactDigestResolver {
            BYOMArtifactDigestResolver(store: BYOMOllamaModelStore(root: root), cache: BYOMArtifactDigestCache(url: cacheURL))
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    /// A fake Ollama store: manifests/registry.ollama.ai/library/<name>/<tag>
    /// naming a model layer whose digest LOCATES blobs/sha256-<hex>. The
    /// manifest digest may LIE (`locator` != real digest) — the CLI must hash.
    private func makeStore(name: String = "test-model", tag: String = "q4_k_m", blob: Data = Data("GGUF".utf8) + Data(repeating: 0xab, count: 4096), locator: String? = nil) throws -> Store {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("byom-ollama-store-\(UUID().uuidString)")
        let locatorHex = locator ?? Self.sha256Hex(blob)
        let blobURL = root.appendingPathComponent("blobs/sha256-\(locatorHex)")
        try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.write(to: blobURL)
        let manifestURL = root.appendingPathComponent("manifests/registry.ollama.ai/library/\(name)/\(tag)")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest = """
        {"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:\(String(repeating: "0", count: 64))","size":1},"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:\(locatorHex)","size":\(blob.count)},{"mediaType":"application/vnd.ollama.image.template","digest":"sha256:\(String(repeating: "1", count: 64))","size":2}]}
        """
        try Data(manifest.utf8).write(to: manifestURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Store(root: root, cacheURL: root.appendingPathComponent("cache/artifact-digests.json"), blobURL: blobURL, blobBytes: blob, manifestDigest: locatorHex)
    }

    func testStoreResolvesTheModelLayerBlobFromTheManifest() throws {
        let store = try makeStore()
        let resolved = try XCTUnwrap(BYOMOllamaModelStore(root: store.root).resolveModelBlob(name: "test-model:q4_k_m"))
        XCTAssertEqual(resolved.blobURL.resolvingSymlinksInPath().path, store.blobURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(resolved.locatorDigest, "sha256:" + store.manifestDigest)
        // The served reference form and the default tag resolve the same way.
        XCTAssertNotNil(BYOMOllamaModelStore(root: store.root).resolveModelBlob(name: "ollama:test-model:q4_k_m"))
        XCTAssertNil(BYOMOllamaModelStore(root: store.root).resolveModelBlob(name: "test-model"), "default tag latest is absent")
        XCTAssertNil(BYOMOllamaModelStore(root: store.root).resolveModelBlob(name: "other:q4_k_m"))
        XCTAssertEqual(BYOMOllamaModelStore.manifestComponents(for: "ns/model:tag"), ["ns", "model", "tag"])
        XCTAssertEqual(BYOMOllamaModelStore.manifestComponents(for: "model"), ["library", "model", "latest"])
        for bad in ["../x:tag", "a/b/c:tag", "", "model:", "mo del:tag", "model:ta/g"] {
            XCTAssertNil(BYOMOllamaModelStore.manifestComponents(for: bad), bad)
        }
    }

    func testDigestIsComputedOverTheBytesNeverTheManifestLocator() throws {
        let blob = Data("GGUF".utf8) + Data(repeating: 0xcd, count: 10_000)
        let lying = String(repeating: "f", count: 64)
        let store = try makeStore(blob: blob, locator: lying)
        let digest = try store.resolver.computeDigest(forOllamaModel: "test-model:q4_k_m")
        XCTAssertEqual(digest, Self.sha256Hex(blob))
        XCTAssertNotEqual(digest, lying, "the manifest digest is a locator, never the report")
        XCTAssertEqual(store.resolver.knownDigest(forOllamaModel: "test-model:q4_k_m"), digest, "recorded for the exact file identity")
    }

    func testNonGGUFBytesAndMissingBlobsFailClosed() throws {
        let store = try makeStore(blob: Data("not a gguf file at all".utf8))
        XCTAssertThrowsError(try store.resolver.computeDigest(forOllamaModel: "test-model:q4_k_m")) { error in
            XCTAssertEqual(error as? BYOMArtifactDigestError, .notGGUF)
        }
        XCTAssertNil(store.resolver.knownDigest(forOllamaModel: "test-model:q4_k_m"))
        XCTAssertThrowsError(try store.resolver.computeDigest(forOllamaModel: "absent:latest")) { error in
            XCTAssertEqual(error as? BYOMArtifactDigestError, .unresolvedBlob)
        }
    }

    func testCacheIsKeyedByExactFileIdentity() throws {
        let store = try makeStore()
        let digest = try store.resolver.computeDigest(forOllamaModel: "test-model:q4_k_m")
        XCTAssertEqual(store.resolver.knownDigest(forOllamaModel: "test-model:q4_k_m"), digest)
        // Same path, SAME size, different bytes: only the modification time
        // (at filesystem precision) distinguishes the identity.
        var sameSize = store.blobBytes
        sameSize[sameSize.count - 1] ^= 0xff
        try sameSize.write(to: store.blobURL)
        XCTAssertNil(store.resolver.knownDigest(forOllamaModel: "test-model:q4_k_m"), "a changed file is a different identity")
        let recomputed = try store.resolver.computeDigest(forOllamaModel: "test-model:q4_k_m")
        XCTAssertNotEqual(recomputed, digest)
        XCTAssertEqual(store.resolver.knownDigest(forOllamaModel: "test-model:q4_k_m"), recomputed)
        // The cache file is private.
        let attributes = try FileManager.default.attributesOfItem(atPath: store.cacheURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// SPEC-046-R005: hashing at evaluation time has an explicit budget. An
    /// expired deadline discards the incomplete digest and records nothing.
    func testHashingIsBoundedByItsDeadlineAndRecordsNothingOnExpiry() throws {
        let store = try makeStore(blob: Data("GGUF".utf8) + Data(repeating: 0x5a, count: 3 * (1 << 20)))
        XCTAssertThrowsError(try store.resolver.computeDigest(forOllamaModel: "test-model:q4_k_m", deadline: Date.distantPast)) { error in
            XCTAssertEqual(error as? BYOMArtifactDigestError, .hashingBudgetExceeded)
        }
        XCTAssertNil(store.resolver.knownDigest(forOllamaModel: "test-model:q4_k_m"), "nothing recorded for an unfinished hash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cacheURL.path))
        // A live deadline hashes the complete bytes.
        XCTAssertEqual(try store.resolver.computeDigest(forOllamaModel: "test-model:q4_k_m", deadline: Date().addingTimeInterval(60)), Self.sha256Hex(store.blobBytes))
        XCTAssertGreaterThan(BYOMEvaluationLimits.standard.artifactHashSeconds, 0)
    }

    /// SPEC-010-R007(a): the digest binds to the file that was READ. The
    /// identity comes from the open descriptor, so a pathname that resolved
    /// to another file while it was opened, or a blob rewritten through
    /// another descriptor while it was read, is a different identity.
    func testDigestIdentityIsTakenFromTheOpenedDescriptorNotThePathname() throws {
        let store = try makeStore()
        let path = store.blobURL.resolvingSymlinksInPath().standardizedFileURL.path
        let handle = try XCTUnwrap(FileHandle(forReadingAtPath: path))
        defer { try? handle.close() }
        let opened = try XCTUnwrap(BYOMArtifactFileIdentity.of(descriptor: handle.fileDescriptor, path: path))
        XCTAssertEqual(opened, BYOMArtifactFileIdentity.current(of: store.blobURL), "same file: descriptor and path agree")
        // In-place rewrite through another descriptor while ours stays open:
        // the descriptor identity moves with the file (size and mtime).
        var rewritten = store.blobBytes
        rewritten.append(contentsOf: [0x01, 0x02])
        try rewritten.write(to: store.blobURL)
        let afterRewrite = try XCTUnwrap(BYOMArtifactFileIdentity.of(descriptor: handle.fileDescriptor, path: path))
        XCTAssertNotEqual(afterRewrite, opened, "a rewrite during hashing is visible on the descriptor")
        XCTAssertEqual(afterRewrite.inode, opened.inode)
        XCTAssertEqual(afterRewrite.sizeBytes, opened.sizeBytes + 2)
        // The path substituted by another file (unlink + recreate): the
        // descriptor still names the file that was read, the path does not.
        try FileManager.default.removeItem(at: store.blobURL)
        try store.blobBytes.write(to: store.blobURL)
        let substituted = try XCTUnwrap(BYOMArtifactFileIdentity.current(of: store.blobURL))
        let stillOpen = try XCTUnwrap(BYOMArtifactFileIdentity.of(descriptor: handle.fileDescriptor, path: path))
        XCTAssertEqual(stillOpen.inode, opened.inode)
        XCTAssertNotEqual(substituted.inode, stillOpen.inode, "the evidence's identity is the read file's; validation against the path fails closed")
        XCTAssertThrowsError(try store.resolver.validateCurrent(
            BYOMArtifactEvidence(algorithm: ModelArtifactIdentity.ggufFileV1, digest: Self.sha256Hex(store.blobBytes), file: stillOpen, locatorDigest: "sha256:" + store.manifestDigest),
            forOllamaModel: "test-model:q4_k_m"
        )) { error in
            XCTAssertEqual(error as? BYOMArtifactDigestError, .fileIdentityChanged)
        }
        // Not a regular file: no identity.
        XCTAssertNil(BYOMArtifactFileIdentity.current(of: store.root))
    }

    private func qualifiedFeed(ggufHash: String, candidateBytes: inout Data) throws -> QualifiedArtifactFeed {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.corpusURL)) as! [String: Any]
        candidateBytes = try JSONSerialization.data(withJSONObject: object["candidate"]!, options: [.sortedKeys, .withoutEscapingSlashes])
        var feed = object["feed"] as! [String: Any]
        feed["candidate_catalog_sha256"] = Self.sha256Hex(candidateBytes)
        var models = feed["models"] as! [String: Any]
        var model = models["test-model"] as! [String: Any]
        var artifacts = model["artifacts"] as! [String: Any]
        artifacts["gguf-q4"] = [
            "allowed_runtime_sources": ["ollama_loopback"], "hash": ggufHash, "hash_algorithm": "macprovider.gguf-file.v1",
            "min_ram_gb": 4, "quantization": "q4_k_m", "runtime_format": "gguf", "size_bytes": 654321,
            "source_ref": ["digest": "sha256:" + ggufHash, "kind": "ollama_library_tag", "library_tag": "test-model:q4_k_m"],
            "verification_status": "verified", "verified_at": "2026-09-01",
        ]
        model["artifacts"] = artifacts
        models["test-model"] = model
        feed["models"] = models
        let feedBytes = try JSONSerialization.data(withJSONObject: feed, options: [.sortedKeys, .withoutEscapingSlashes])
        let signer = "streamvc-autotune-static-v4"
        return try XCTUnwrap(AutotuneStaticInputs.usableArtifactFeed(
            bakedBytes: feedBytes, bakedSignerKeyID: signer, candidateBytes: candidateBytes, candidateSignerKeyID: signer,
            now: ISO8601DateFormatter.autotuneInternet.date(from: "2026-07-11T00:00:00Z")!
        ))
    }

    func testOllamaDiscoveryReportsHashAvailabilityAndMatchesByComputedDigestOnly() async throws {
        let store = try makeStore()
        let digest = Self.sha256Hex(store.blobBytes)
        var candidateBytes = Data()
        let feed = try qualifiedFeed(ggufHash: digest, candidateBytes: &candidateBytes)
        let tags = Data(#"{"models":[{"name":"test-model:q4_k_m","details":{"family":"llama","quantization_level":"Q4_K_M"}}]}"#.utf8)
        func discover(matcher: BYOMCatalogMatcher, resolver: BYOMArtifactDigestResolver?) async -> BYOMDiscoveryWire.Candidate? {
            await BYOMOllamaDiscovery(
                origin: "http://127.0.0.1:11434", namespace: Data(repeating: 0x37, count: 32),
                catalogMatcher: matcher,
                httpClient: ArtifactStubHTTPClient(response: BYOMHTTPResponse(statusCode: 200, headers: [], body: tags)),
                artifactDigests: resolver
            ).discover().candidates.first
        }
        let matcher = BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: feed)
        // Nothing computed yet: the tag alone is a name, not identity.
        let beforeValue = await discover(matcher: matcher, resolver: store.resolver)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertNil(before.catalogModelKey)
        XCTAssertEqual(before.identityState, "runtime_reported")
        // After a deliberate hash (evaluate/offer), discovery reports the
        // availability and matches by the COMPUTED digest.
        _ = try store.resolver.computeDigest(forOllamaModel: "test-model:q4_k_m")
        let matchedValue = await discover(matcher: matcher, resolver: store.resolver)
        let matched = try XCTUnwrap(matchedValue)
        XCTAssertEqual(matched.catalogModelKey, "test-model")
        XCTAssertEqual(matched.identityState, "catalog_matched")
        XCTAssertTrue(matched.warningCodes.contains(BYOMDiscoveryWarning.catalogMatchUnverified.rawValue))
        // Digest known but no usable feed: hash available, no catalog identity.
        let unmatchedValue = await discover(matcher: BYOMCatalogMatcher(candidateBytes: candidateBytes, artifactFeed: nil), resolver: store.resolver)
        let unmatched = try XCTUnwrap(unmatchedValue)
        XCTAssertNil(unmatched.catalogModelKey)
        XCTAssertEqual(unmatched.identityState, "artifact_hash_available")
        // A feed whose artifact hash differs from the computed digest never matches.
        var otherBytes = Data()
        let otherFeed = try qualifiedFeed(ggufHash: String(repeating: "9", count: 64), candidateBytes: &otherBytes)
        let mismatchValue = await discover(matcher: BYOMCatalogMatcher(candidateBytes: otherBytes, artifactFeed: otherFeed), resolver: store.resolver)
        let mismatch = try XCTUnwrap(mismatchValue)
        XCTAssertNil(mismatch.catalogModelKey)
        XCTAssertEqual(mismatch.identityState, "artifact_hash_available")
        // No resolver (no store): v0.1 behaviour exactly.
        let legacyValue = await discover(matcher: matcher, resolver: nil)
        let legacy = try XCTUnwrap(legacyValue)
        XCTAssertEqual(legacy.identityState, "runtime_reported")
    }

    func testOfferRecomputesTheDigestAndOnlyForOllamaCandidates() async throws {
        let store = try makeStore()
        let environment = BYOMDiscoveryEnvironment(
            namespaceURL: store.root.appendingPathComponent("ns"), mlxCacheRoot: store.root.appendingPathComponent("mlx"),
            ollamaOrigin: nil, ollamaModelsRoot: store.root, artifactDigestCacheURL: store.cacheURL
        )
        let tags = Data(#"{"models":[{"name":"test-model:q4_k_m"}]}"#.utf8)
        let candidateValue = await BYOMOllamaDiscovery(
            origin: "http://127.0.0.1:11434", namespace: Data(repeating: 0x37, count: 32), catalogMatcher: BYOMCatalogMatcher(),
            httpClient: ArtifactStubHTTPClient(response: BYOMHTTPResponse(statusCode: 200, headers: [], body: tags))
        ).discover().candidates.first
        let candidate = try XCTUnwrap(candidateValue)
        XCTAssertNil(store.resolver.knownDigest(forOllamaModel: "test-model:q4_k_m"), "nothing hashed before the offer")
        let evidence = try XCTUnwrap(BYOMModelAdmissionRuntime.artifactEvidence(for: candidate, environment: environment))
        XCTAssertEqual(evidence.hashes, [ModelArtifactIdentity.ggufFileV1: Self.sha256Hex(store.blobBytes)])
        XCTAssertEqual(evidence.locatorDigest, "sha256:" + store.manifestDigest)
        XCTAssertNotNil(store.resolver.knownDigest(forOllamaModel: "test-model:q4_k_m"), "the offer's computation is recorded")
        // The binding survives to the report only while the name still
        // resolves, through the manifest, to the same unchanged file.
        XCTAssertNoThrow(try store.resolver.validateCurrent(evidence, forOllamaModel: "test-model:q4_k_m"))
        let otherBlob = Data("GGUF".utf8) + Data(repeating: 0x11, count: 4096)
        let otherHex = Self.sha256Hex(otherBlob)
        try otherBlob.write(to: store.root.appendingPathComponent("blobs/sha256-\(otherHex)"))
        let manifestURL = store.root.appendingPathComponent("manifests/registry.ollama.ai/library/test-model/q4_k_m")
        let retargeted = try String(contentsOf: manifestURL, encoding: .utf8).replacingOccurrences(of: store.manifestDigest, with: otherHex)
        try Data(retargeted.utf8).write(to: manifestURL)
        XCTAssertThrowsError(try store.resolver.validateCurrent(evidence, forOllamaModel: "test-model:q4_k_m"), "manifest retargeted to another blob") { error in
            XCTAssertEqual(error as? BYOMArtifactDigestError, .fileIdentityChanged)
        }
        // The offer's hash has an explicit budget too: expiry fails the offer
        // closed with its own reason and records nothing new.
        XCTAssertThrowsError(try BYOMModelAdmissionRuntime.artifactEvidence(for: candidate, environment: environment, deadline: Date.distantPast)) { error in
            XCTAssertEqual(error as? BYOMModelAdmissionError, .artifactHashingTimedOut)
        }
        XCTAssertGreaterThan(BYOMModelAdmissionRuntime.artifactHashBudgetSeconds, BYOMEvaluationLimits.standard.artifactHashSeconds, "the binding report gets a more generous budget than the probe")
        // Unresolvable blob: no artifact evidence, the offer proceeds as v0.1.
        let missingTags = Data(#"{"models":[{"name":"absent:latest"}]}"#.utf8)
        let absentValue = await BYOMOllamaDiscovery(
            origin: "http://127.0.0.1:11434", namespace: Data(repeating: 0x37, count: 32), catalogMatcher: BYOMCatalogMatcher(),
            httpClient: ArtifactStubHTTPClient(response: BYOMHTTPResponse(statusCode: 200, headers: [], body: missingTags))
        ).discover().candidates.first
        let absent = try XCTUnwrap(absentValue)
        XCTAssertNil(try BYOMModelAdmissionRuntime.artifactEvidence(for: absent, environment: environment), "never artifact-backed: identity-less offer as v0.1")
        // The same unresolvable blob on a candidate discovery reported as
        // artifact-backed fails the offer closed.
        let backed = BYOMDiscoveryWire.Candidate(
            candidateID: absent.candidateID, runtimeSource: absent.runtimeSource, displayName: absent.displayName, servedModelRef: absent.servedModelRef,
            catalogModelKey: nil, identityState: "artifact_hash_available", locality: absent.locality, estimatedGB: nil, contextWindowTokens: nil,
            capabilities: absent.capabilities, readinessState: absent.readinessState, fitState: absent.fitState,
            evaluationState: absent.evaluationState, admissionState: absent.admissionState, admissionStateSource: absent.admissionStateSource,
            providerGuidance: absent.providerGuidance, warningCodes: absent.warningCodes
        )
        XCTAssertThrowsError(try BYOMModelAdmissionRuntime.artifactEvidence(for: backed, environment: environment)) { error in
            XCTAssertEqual(error as? BYOMModelAdmissionError, .artifactIdentityChanged)
        }
        // A non-Ollama candidate carries no GGUF evidence.
        let mlx = BYOMDiscoveryWire.Candidate(
            candidateID: candidate.candidateID, runtimeSource: "mlx_cache", displayName: candidate.displayName, servedModelRef: "mlx-community/x",
            catalogModelKey: nil, identityState: "runtime_reported", locality: "local_artifact", estimatedGB: nil, contextWindowTokens: nil,
            capabilities: candidate.capabilities, readinessState: candidate.readinessState, fitState: candidate.fitState,
            evaluationState: candidate.evaluationState, admissionState: candidate.admissionState, admissionStateSource: candidate.admissionStateSource,
            providerGuidance: candidate.providerGuidance, warningCodes: candidate.warningCodes
        )
        XCTAssertNil(try BYOMModelAdmissionRuntime.artifactEvidence(for: mlx, environment: environment))
    }
}

private struct ArtifactStubHTTPClient: BYOMDiscoveryHTTPClient {
    let response: BYOMHTTPResponse
    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse { response }
    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse { response }
}
