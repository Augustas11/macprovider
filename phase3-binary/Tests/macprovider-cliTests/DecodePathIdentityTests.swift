import CryptoKit
import Foundation
@testable import macprovider_cli
import XCTest

/// SPEC-048-R013 (0.1.51): the decode-path digest compiled into the CLI is
/// the digest of `decode-path-manifest.json` over this source tree. A changed
/// decode-path file without a regenerated constant fails here and in
/// `scripts/decode_path_digest.py --check`.
final class DecodePathIdentityTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // macprovider-cliTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // phase3-binary
    }

    private struct Manifest: Decodable {
        let schema_version: String
        let files: [String]
        let dependencies: [String]
    }

    /// The same algorithm as scripts/decode_path_digest.py. Dependency
    /// revisions come from KVBuildIdentity, which KVBuildIdentityDriftTests
    /// pins to Package.resolved.
    private func digest(root: URL) throws -> String {
        let data = try Data(contentsOf: root.appendingPathComponent("decode-path-manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(manifest.schema_version, "macprovider.decode-path-manifest.v1")
        XCTAssertEqual(manifest.files, manifest.files.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
        XCTAssertEqual(manifest.dependencies, ["mlx-swift", "mlx-swift-lm"])
        var lines = [DecodePathIdentity.domain]
        for file in manifest.files {
            let url = root.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("decode-path file \(file) is not present in this checkout")
            }
            let bytes = try Data(contentsOf: url)
            lines.append("file \(file) \(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())")
        }
        lines.append("dependency mlx-swift \(KVBuildIdentity.mlxSwiftRevision)")
        lines.append("dependency mlx-swift-lm \(KVBuildIdentity.mlxSwiftLMRevision)")
        let text = lines.joined(separator: "\n") + "\n"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testEmbeddedDigestIsTheManifestDigestOfThisTree() throws {
        XCTAssertEqual(
            try digest(root: packageRoot), DecodePathIdentity.digest,
            "a decode-path file changed: run python3 scripts/decode_path_digest.py --write"
        )
        XCTAssertTrue(DecodePathIdentity.embeddedMarker.hasPrefix("macprovider.decode-path-digest.v1:"))
    }

    func testEveryManifestFileExists() throws {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("decode-path-manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertFalse(manifest.files.isEmpty)
        for file in manifest.files {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(file).path),
                "decode-path-manifest.json lists missing file \(file)"
            )
        }
    }

    /// Editing any listed decode-path file changes the digest.
    func testChangingADecodePathFileChangesTheDigest() throws {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("decode-path-manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try data.write(to: copy.appendingPathComponent("decode-path-manifest.json"))
        for file in manifest.files {
            let target = copy.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: packageRoot.appendingPathComponent(file), to: target)
        }
        XCTAssertEqual(try digest(root: copy), DecodePathIdentity.digest)
        let edited = copy.appendingPathComponent(try XCTUnwrap(manifest.files.first))
        let handle = try FileHandle(forWritingTo: edited)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n// decode path changed\n".utf8))
        try handle.close()
        XCTAssertNotEqual(try digest(root: copy), DecodePathIdentity.digest)
    }

    func testRuntimeMetallibDigestReadsTheMeasuredLibrary() {
        let bytes = Data("metallib".utf8)
        let environment = PagedKVRuntimeMeasurementEnvironment(
            metallibCandidatePaths: { ["/missing", "/present"] },
            fileExists: { $0 == "/present" },
            readFileData: { _ in bytes },
            hardwareFingerprint: { MachineFingerprinter().sample() },
            registeredKernelIdentifier: { nil }
        )
        XCTAssertEqual(
            ModelRuntime.nativeMTPRuntimeMetallibSHA256(environment: environment),
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
        let missing = PagedKVRuntimeMeasurementEnvironment(
            metallibCandidatePaths: { ["/missing"] },
            fileExists: { _ in false },
            readFileData: { _ in bytes },
            hardwareFingerprint: { MachineFingerprinter().sample() },
            registeredKernelIdentifier: { nil }
        )
        XCTAssertNil(ModelRuntime.nativeMTPRuntimeMetallibSHA256(environment: missing))
    }
}
