import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class DurableModelArtifactStoreTests: XCTestCase {
    func testAdoptCopiesRegularFilesAndRejectsSymlinks() throws {
        let root = try tempDir()
        let store = DurableModelArtifactStore(root: root)
        let staging = try tempDir()
        try Data("weights".utf8).write(to: staging.appendingPathComponent("weights.bin"))
        try Data("{}".utf8).write(to: staging.appendingPathComponent("config.json"))
        let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: staging)
        let revision = String(repeating: "a", count: 40)

        let adopted = try store.adoptVerifiedStaging(
            staging: staging,
            modelID: "namespace/model",
            revision: revision,
            sha256: sha
        )
        XCTAssertTrue(store.contains(adopted.path))
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: adopted), sha)
        XCTAssertEqual(
            try String(contentsOf: adopted.appendingPathComponent("weights.bin")),
            "weights"
        )

        let linked = try tempDir()
        try Data("weights".utf8).write(to: linked.appendingPathComponent("weights.bin"))
        XCTAssertEqual(symlink("weights.bin", linked.appendingPathComponent("link.bin").path), 0)
        XCTAssertThrowsError(
            try store.adoptVerifiedStaging(
                staging: linked,
                modelID: "namespace/symlink",
                revision: revision,
                sha256: sha
            )
        )
    }

    func testGCKeepsActiveArtifactAndRemovesSiblings() throws {
        let root = try tempDir()
        let store = DurableModelArtifactStore(root: root)
        let first = try tempDir()
        try Data("one".utf8).write(to: first.appendingPathComponent("weights.bin"))
        let firstSHA = try ModelArtifactVerifier.canonicalArtifactHash(directory: first)
        let second = try tempDir()
        try Data("two".utf8).write(to: second.appendingPathComponent("weights.bin"))
        let secondSHA = try ModelArtifactVerifier.canonicalArtifactHash(directory: second)
        let revision = String(repeating: "b", count: 40)

        let kept = try store.adoptVerifiedStaging(
            staging: first,
            modelID: "namespace/model",
            revision: revision,
            sha256: firstSHA
        )
        let stale = try store.adoptVerifiedStaging(
            staging: second,
            modelID: "namespace/other",
            revision: revision,
            sha256: secondSHA
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))

        try store.gcInactive(keeping: [kept.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testEscapedComponentRejectsPathTraversal() {
        let store = DurableModelArtifactStore(root: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(
            try store.artifactURL(
                modelID: "foo/../bar",
                revision: String(repeating: "c", count: 40),
                sha256: String(repeating: "a", count: 64)
            )
        )
    }

    func testDetectsHuggingFaceCachePaths() {
        XCTAssertTrue(
            DurableModelArtifactStore.isHuggingFaceCachePath(
                "/Users/tester/.cache/huggingface/hub/models--x--y/snapshots/abc"
            )
        )
        XCTAssertFalse(
            DurableModelArtifactStore.isHuggingFaceCachePath(
                "/Users/tester/Library/Application Support/macprovider/models/x/abc"
            )
        )
    }

    func testIsModelMaterializedAfterAdopt() throws {
        let root = try tempDir()
        let store = DurableModelArtifactStore(root: root)
        let staging = try tempDir()
        try Data("weights".utf8).write(to: staging.appendingPathComponent("weights.bin"))
        let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: staging)
        XCTAssertFalse(store.isModelMaterialized(modelID: "namespace/model"))
        _ = try store.adoptVerifiedStaging(
            staging: staging,
            modelID: "namespace/model",
            revision: String(repeating: "d", count: 40),
            sha256: sha
        )
        XCTAssertTrue(store.isModelMaterialized(modelID: "namespace/model"))
        XCTAssertFalse(store.isModelMaterialized(modelID: "namespace/other"))
    }

    func testAdoptRepairsCorruptDurableDestinationFromHealthyStaging() throws {
        let root = try tempDir()
        let store = DurableModelArtifactStore(root: root)
        let staging = try tempDir()
        try Data("healthy".utf8).write(to: staging.appendingPathComponent("weights.bin"))
        let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: staging)
        let revision = String(repeating: "e", count: 40)
        let destination = try store.artifactURL(
            modelID: "namespace/model",
            revision: revision,
            sha256: sha
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertEqual(symlink("missing.bin", destination.appendingPathComponent("broken.bin").path), 0)

        let adopted = try store.adoptVerifiedStaging(
            staging: staging,
            modelID: "namespace/model",
            revision: revision,
            sha256: sha
        )
        XCTAssertEqual(adopted.path, destination.path)
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: adopted), sha)
        XCTAssertEqual(try String(contentsOf: adopted.appendingPathComponent("weights.bin")), "healthy")
    }

    func testContainsRejectsSymlinkInDurablePath() throws {
        let root = try tempDir()
        let store = DurableModelArtifactStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = try tempDir()
        try Data("escaped".utf8).write(to: outside.appendingPathComponent("weights.bin"))
        let link = root.appendingPathComponent("escape-link")
        XCTAssertEqual(symlink(outside.path, link.path), 0)
        XCTAssertFalse(store.contains(link.path))
        XCTAssertFalse(store.contains(link.appendingPathComponent("weights.bin").path))
    }

    func testAdoptRejectsExistingDestinationReachedThroughSymlinkAncestor() throws {
        let root = try tempDir()
        let store = DurableModelArtifactStore(root: root)
        let staging = try tempDir()
        try Data("weights".utf8).write(to: staging.appendingPathComponent("weights.bin"))
        let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: staging)
        let revision = String(repeating: "f", count: 40)
        let destination = try store.artifactURL(
            modelID: "namespace/model",
            revision: revision,
            sha256: sha
        )
        let modelDir = destination.deletingLastPathComponent().deletingLastPathComponent()
        let outside = try tempDir()
        let escaped = outside.appendingPathComponent(modelDir.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: destination.appendingPathComponent("weights.bin"))
        try FileManager.default.moveItem(at: modelDir, to: escaped)
        XCTAssertEqual(symlink(escaped.path, modelDir.path), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        XCTAssertThrowsError(
            try store.adoptVerifiedStaging(
                staging: staging,
                modelID: "namespace/model",
                revision: revision,
                sha256: sha
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("symlink"), "\(error)")
        }
        XCTAssertThrowsError(try store.validatedContainedDirectory(destination.path))
    }

    private func tempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableModelArtifactStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
