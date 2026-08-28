import Foundation
import XCTest
@testable import malibu_cli

final class ModelRuntimeHashTests: XCTestCase {
    func testArtifactManifestHashUsesSortedSafetensorsManifest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("beta-data".utf8).write(to: directory.appendingPathComponent("b.safetensors"))
        try Data("ignore me".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try Data("alpha".utf8).write(to: directory.appendingPathComponent("a.safetensors"))

        let hash = try XCTUnwrap(try ModelRuntime.modelWeightArtifactManifestHash(in: directory))

        XCTAssertEqual(hash, "46f90a96d0db51ec7feb04136b986a74b78ce5e5f5cc8aeef4e2d8edef88563e")
    }

    func testArtifactManifestHashFollowsHuggingFaceSnapshotSymlinks() throws {
        let root = try makeTemporaryDirectory()
        let directory = root.appendingPathComponent("snapshots/revision", isDirectory: true)
        let blobDirectory = root.appendingPathComponent("blobs", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)

        let blobA = blobDirectory.appendingPathComponent("blob-a")
        let blobB = blobDirectory.appendingPathComponent("blob-b")
        try Data("alpha".utf8).write(to: blobA)
        try Data("beta-data".utf8).write(to: blobB)
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("a.safetensors").path,
            withDestinationPath: "../../blobs/blob-a"
        )
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("b.safetensors").path,
            withDestinationPath: "../../blobs/blob-b"
        )

        let hash = try XCTUnwrap(try ModelRuntime.modelWeightArtifactManifestHash(in: directory))

        XCTAssertEqual(hash, "46f90a96d0db51ec7feb04136b986a74b78ce5e5f5cc8aeef4e2d8edef88563e")
    }

    func testArtifactManifestHashReturnsNilWithoutSafetensors() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("ignore me".utf8).write(to: directory.appendingPathComponent("config.json"))

        XCTAssertNil(try ModelRuntime.modelWeightArtifactManifestHash(in: directory))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
