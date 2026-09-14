import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ModelCatalogLocalInspectionTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"max_position_embeddings":4096}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data(repeating: 42, count: 2_100_000).write(to: directory.appendingPathComponent("weights.safetensors"))
        return directory
    }

    func testDescriptorHashPreservesCanonicalFormatAndCountsActualBytesOnce() throws {
        let root = try fixture()
        let expected = try ModelArtifactVerifier.inspectCanonicalArtifact(directory: root)
        let observation = try ModelCatalogVerifiedArtifactObservation(directory: root, check: {})
        var measured: UInt64 = 0
        let verified = try ModelArtifactVerifier.inspectCanonicalArtifact(observation: observation, measuredBytes: { bytes in
            measured += bytes
        })
        XCTAssertEqual(verified.sha256, expected.sha256)
        XCTAssertEqual(verified.configSHA256, expected.configSHA256)
        XCTAssertEqual(verified.configJSONData, expected.configJSONData)
        XCTAssertEqual(measured, 2_100_000 + UInt64(try XCTUnwrap(expected.configJSONData).count))
        try observation.validateFinal(check: {})
        XCTAssertEqual(measured, 2_100_000 + UInt64(try XCTUnwrap(expected.configJSONData).count))
    }

    func testSameSizeMutationDuringHashFailsIncludingChangedCTime() throws {
        let root = try fixture()
        let observation = try ModelCatalogVerifiedArtifactObservation(directory: root, check: {})
        var mutated = false
        XCTAssertThrowsError(try ModelArtifactVerifier.inspectCanonicalArtifact(
            observation: observation, measuredBytes: { _ in
                if !mutated {
                    mutated = true
                    try Data(repeating: 43, count: 2_100_000).write(to: root.appendingPathComponent("weights.safetensors"))
                }
            }))
        XCTAssertTrue(mutated)
    }

    func testRootAndAncestorRenamesInvalidateHeldPlacement() throws {
        for renameAncestor in [false, true] {
            let parent = try fixture()
            let root = parent.appendingPathComponent("artifact")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
            let observation = try ModelCatalogVerifiedArtifactObservation(directory: root, check: {})
            _ = try ModelArtifactVerifier.inspectCanonicalArtifact(observation: observation)
            let source = renameAncestor ? parent : root
            let moved = source.appendingPathExtension("moved")
            try FileManager.default.moveItem(at: source, to: moved)
            addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
            XCTAssertThrowsError(try observation.validateFinal(check: {}))
        }
    }

    func testSymlinksHardlinksAndOversizedConfigFailBeforeAnyRead() throws {
        for variant in ["symlink", "hardlink", "config"] {
            let root = try fixture()
            let weights = root.appendingPathComponent("weights.safetensors")
            if variant == "symlink" {
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: weights)
            } else if variant == "hardlink" {
                XCTAssertEqual(link(weights.path, root.appendingPathComponent("linked").path), 0)
            } else {
                try Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1).write(to: root.appendingPathComponent("config.json"))
            }
            let observation = try ModelCatalogVerifiedArtifactObservation(directory: root, check: {})
            var bytes: UInt64 = 0
            XCTAssertThrowsError(try ModelArtifactVerifier.inspectCanonicalArtifact(
                observation: observation, measuredBytes: { bytes += $0 }))
            XCTAssertEqual(bytes, 0)
        }
    }

    func testFinalSnapshotRejectsAddedDeletedAndReplacedConfig() throws {
        for variant in ["add", "delete", "replace"] {
            let root = try fixture()
            let observation = try ModelCatalogVerifiedArtifactObservation(directory: root, check: {})
            _ = try ModelArtifactVerifier.inspectCanonicalArtifact(observation: observation)
            if variant == "add" {
                try Data().write(to: root.appendingPathComponent("new-file"))
            } else if variant == "delete" {
                try FileManager.default.removeItem(at: root.appendingPathComponent("weights.safetensors"))
            } else {
                try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"), options: .atomic)
            }
            XCTAssertThrowsError(try observation.validateFinal(check: {}))
        }
    }

    func testCancellationStopsBeforeReadingAndNeverRecordsVerifiedSnapshot() throws {
        let root = try fixture()
        let observation = try ModelCatalogVerifiedArtifactObservation(directory: root, check: {})
        var bytes: UInt64 = 0
        XCTAssertThrowsError(try ModelArtifactVerifier.inspectCanonicalArtifact(
            observation: observation, checkCancellation: { throw CancellationError() }, measuredBytes: { bytes += $0 }))
        XCTAssertEqual(bytes, 0)
        XCTAssertThrowsError(try observation.validateFinal(check: {}))
    }

    func testRequestMapQuickUnverifiedAndExactVerificationReusesObservation() throws {
        let root = try fixture()
        let hash = try ModelArtifactVerifier.canonicalArtifactHash(directory: root)
        let storeRoot = root.appendingPathComponent("durable")
        let key = ModelCatalogLocalInspection.Key(modelKey: "test", modelID: "mlx-community/test",
            revision: String(repeating: "1", count: 40), sha256: hash)
        let destination = try DurableModelArtifactStore(root: storeRoot).artifactURL(
            modelID: key.modelID, revision: key.revision, sha256: key.sha256)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["config.json", "weights.safetensors"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
        let request = ModelCatalogLocalInspection(root: storeRoot)
        let quick = try request.inspect(key: key)
        XCTAssertEqual(quick.state, .unverified)
        XCTAssertNil(quick.inspection)
        let verified = try request.inspect(key: key, verify: true)
        XCTAssertEqual(verified.state, .verified)
        XCTAssertEqual(verified.inspection?.sha256, hash)
        // A second consumer receives the same request-local result; finalization
        // rejects changes instead of silently rehashing or caching past readiness.
        try Data("changed".utf8).write(to: destination.appendingPathComponent("weights.safetensors"))
        XCTAssertEqual(try request.inspect(key: key, verify: true).inspection?.sha256, hash)
        XCTAssertThrowsError(try request.validateVerifiedPlacements())
        let next = ModelCatalogLocalInspection(root: storeRoot)
        XCTAssertEqual(try next.inspect(key: key).state, .unverified)
        XCTAssertEqual(try next.inspect(key: key, verify: true).state, .invalid)
    }

    func testActualAbsenceAndCacheOnlyObservationNeverClaimReady() throws {
        let root = try fixture()
        let request = ModelCatalogLocalInspection(root: root.appendingPathComponent("absent"))
        let key = ModelCatalogLocalInspection.Key(modelKey: "test", modelID: "mlx-community/test",
            revision: String(repeating: "1", count: 40), sha256: String(repeating: "2", count: 64))
        XCTAssertEqual(try request.inspect(key: key).state, .missing)
        request.observeCacheCandidate(modelKey: key.modelKey, modelID: key.modelID)
        XCTAssertEqual(request.entry(for: key)?.state, .unverified)
        XCTAssertNil(request.entry(for: key)?.inspection)
        XCTAssertEqual(try request.inspect(key: key, verify: true).state, .missing)
    }
}
