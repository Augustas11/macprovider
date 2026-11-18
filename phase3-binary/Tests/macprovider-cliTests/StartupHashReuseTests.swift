import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// Start-up hashes every weight file once: the preflight records each file's
/// hash and identity, and the post-load check and weights manifest reuse it
/// only while every file's identity is unchanged.
final class StartupHashReuseTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-hash-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files: [(String, Data)] = [
            ("config.json", Data(#"{"model_type":"llama"}"#.utf8)),
            ("model-00001-of-00002.safetensors", Data(repeating: 0xA1, count: 300_000)),
            ("model-00002-of-00002.safetensors", Data(repeating: 0xB2, count: 5 * 1024 * 1024 + 17)),
            ("tokenizer.json", Data("{}".utf8)),
            ("empty.txt", Data()),
            ("nested/dir with space/é-weights.safetensors", Data(repeating: 0x03, count: 4096)),
            ("nested/a.bin", Data("a".utf8)),
            ("variant/model.safetensors", Data(repeating: 0x44, count: 2048)),
            ("variant/config.json", Data("{}".utf8)),
        ]
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return root
    }

    /// Today's algorithm, serial and from first principles.
    private func referenceCanonicalHash(_ root: URL) throws -> String {
        let base = root.resolvingSymlinksInPath().path
        var lines: [(String, String)] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue { continue }
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
            let data = try Data(contentsOf: url)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            lines.append((rel, "\(rel)\n\(data.count)\n\(sha)\n"))
        }
        let manifest = lines.sorted { $0.0 < $1.0 }.map(\.1).joined()
        return SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func bumpMtime(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: url.path)
    }

    func testCanonicalHashMatchesReferenceAndParallelMatchesSerial() throws {
        let root = try fixture()
        let reference = try referenceCanonicalHash(root)
        let serial = try ModelArtifactVerifier.inspectCanonicalArtifact(
            directory: root, scopedSubdirectory: "variant", hashConcurrency: 1)
        let parallel = try ModelArtifactVerifier.inspectCanonicalArtifact(
            directory: root, scopedSubdirectory: "variant", hashConcurrency: 4)
        XCTAssertEqual(serial.sha256, reference)
        XCTAssertEqual(parallel.sha256, reference)
        XCTAssertEqual(parallel.scopedSHA256, try referenceCanonicalHash(root.appendingPathComponent("variant")))
        XCTAssertEqual(parallel.scopedSHA256, serial.scopedSHA256)
        XCTAssertEqual(parallel.files.map(\.sha256), serial.files.map(\.sha256))
        XCTAssertEqual(parallel.files.map(\.relativePath), parallel.files.map(\.relativePath).sorted())
        XCTAssertEqual(parallel.sizeBytes, serial.sizeBytes)
        XCTAssertEqual(parallel.configJSONData, Data(#"{"model_type":"llama"}"#.utf8))
        XCTAssertEqual(parallel.configSHA256, serial.configSHA256)
    }

    func testWeightsManifestFromRecordIsByteIdentical() throws {
        let root = try fixture()
        let variant = root.appendingPathComponent("variant")
        let rehashed = try ModelRuntime.modelWeightArtifactManifestHash(in: root)
        let variantRehashed = try ModelRuntime.modelWeightArtifactManifestHash(in: variant)
        XCTAssertNotNil(rehashed)
        XCTAssertNil(ModelArtifactVerifier.recordedFiles(forDirectory: root))
        _ = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: root, recordForReuse: true)
        XCTAssertNotNil(ModelArtifactVerifier.identityVerifiedRecordedFiles(directory: root))
        XCTAssertEqual(try ModelRuntime.modelWeightArtifactManifestHash(in: root), rehashed)
        XCTAssertNotNil(ModelArtifactVerifier.identityVerifiedRecordedFiles(directory: variant))
        XCTAssertEqual(variantRehashed, try ModelRuntime.modelWeightArtifactManifestHash(in: variant))
    }

    func testWeightsManifestIgnoresRecordAfterChange() throws {
        let root = try fixture()
        _ = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: root, recordForReuse: true)
        let shard = root.appendingPathComponent("model-00001-of-00002.safetensors")
        try Data(repeating: 0xEE, count: 300_000).write(to: shard)
        XCTAssertNil(ModelArtifactVerifier.identityVerifiedRecordedFiles(directory: root))
        let expected = try fixtureCopyManifest(of: root)
        XCTAssertEqual(try ModelRuntime.modelWeightArtifactManifestHash(in: root), expected)
    }

    /// The manifest of an unrecorded copy, which takes the per-file hash path.
    private func fixtureCopyManifest(of root: URL) throws -> String? {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-hash-copy-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: root, to: copy)
        return try ModelRuntime.modelWeightArtifactManifestHash(in: copy)
    }

    func testPostLoadVerifyUsesIdentityWhenUnchanged() throws {
        let root = try fixture()
        let inspection = try ModelArtifactVerifier.inspectCanonicalArtifact(
            directory: root, scopedSubdirectory: "variant", recordForReuse: true)
        XCTAssertEqual(try ModelRuntime.verifyLoadedArtifact(directory: root, expectedSHA256: inspection.sha256), "identity")
        XCTAssertEqual(try ModelRuntime.verifyLoadedArtifact(
            directory: root.appendingPathComponent("variant"), expectedSHA256: inspection.scopedSHA256!), "identity")
        XCTAssertThrowsError(try ModelRuntime.verifyLoadedArtifact(directory: root, expectedSHA256: String(repeating: "0", count: 64)))
    }

    func testPostLoadVerifyWithoutRecordRehashes() throws {
        let root = try fixture()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: root)
        XCTAssertEqual(try ModelRuntime.verifyLoadedArtifact(directory: root, expectedSHA256: expected), "rehash")
    }

    func testPostLoadVerifyRehashesWhenMtimeChanges() throws {
        let root = try fixture()
        let inspection = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: root, recordForReuse: true)
        try bumpMtime(root.appendingPathComponent("tokenizer.json"))
        XCTAssertEqual(try ModelRuntime.verifyLoadedArtifact(directory: root, expectedSHA256: inspection.sha256), "rehash")
    }

    func testPostLoadVerifyFailsWhenContentChangesAtSameSize() throws {
        let root = try fixture()
        let inspection = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: root, recordForReuse: true)
        try Data(repeating: 0xEE, count: 300_000).write(to: root.appendingPathComponent("model-00001-of-00002.safetensors"))
        XCTAssertThrowsError(try ModelRuntime.verifyLoadedArtifact(directory: root, expectedSHA256: inspection.sha256))
    }

    func testPostLoadVerifyFailsWhenSizeChanges() throws {
        let root = try fixture()
        let inspection = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: root, recordForReuse: true)
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("nested/a.bin"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("b".utf8))
        try handle.close()
        XCTAssertNil(ModelArtifactVerifier.identityVerifiedRecordedFiles(directory: root))
        XCTAssertThrowsError(try ModelRuntime.verifyLoadedArtifact(directory: root, expectedSHA256: inspection.sha256))
    }

    func testPostLoadVerifyFailsWhenFileAddedOrRemoved() throws {
        let added = try fixture()
        let addedInspection = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: added, recordForReuse: true)
        try Data("x".utf8).write(to: added.appendingPathComponent("nested/extra.bin"))
        XCTAssertNil(ModelArtifactVerifier.identityVerifiedRecordedFiles(directory: added))
        XCTAssertThrowsError(try ModelRuntime.verifyLoadedArtifact(directory: added, expectedSHA256: addedInspection.sha256))

        let removed = try fixture()
        let removedInspection = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: removed, recordForReuse: true)
        try FileManager.default.removeItem(at: removed.appendingPathComponent("empty.txt"))
        XCTAssertNil(ModelArtifactVerifier.identityVerifiedRecordedFiles(directory: removed))
        XCTAssertThrowsError(try ModelRuntime.verifyLoadedArtifact(directory: removed, expectedSHA256: removedInspection.sha256))
    }
}
