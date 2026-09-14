import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class ModelCatalogArtifactSealTests: XCTestCase {
    func testActualFullHashProducesStableObservationAndRejectsChangesBeforeCapture() throws {
        let root = try fixture()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: root)
        let snapshot = try ModelCatalogArtifactSnapshot.verified(directory: root, sha256: expected, deadline: nil, check: {})
        XCTAssertEqual(snapshot.entries.count, 2)
        try snapshot.observe(directory: root, deadline: nil).validatePlacement()
        let file = root.appendingPathComponent("weights.bin")
        try Data(repeating: 0x62, count: 2_097_152).write(to: file)
        XCTAssertThrowsError(try snapshot.observe(directory: root, deadline: nil))
        XCTAssertThrowsError(try ModelCatalogArtifactSnapshot.verified(directory: root, sha256: expected, deadline: nil, check: {}))
    }

    func testPostCaptureInPlaceMutationPreservesOnlyHistoricalPlacementNotFreshIntegrity() throws {
        let root = try fixture()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: root)
        let snapshot = try ModelCatalogArtifactSnapshot.verified(directory: root, sha256: expected, deadline: nil, check: {})
        let observation = try snapshot.observe(directory: root, deadline: nil)
        let fd = open(root.appendingPathComponent("weights.bin").path, O_WRONLY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var byte: UInt8 = 0x62
        XCTAssertEqual(write(fd, &byte, 1), 1); close(fd)
        // This is intentionally historical object placement, not a current-ready assertion.
        XCTAssertNoThrow(try observation.validatePlacement())
        XCTAssertNotEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: root), expected)
        XCTAssertThrowsError(try snapshot.observe(directory: root, deadline: nil))
    }

    func testMutationDuringFullVerificationAndRootSubstitutionFailClosed() throws {
        let root = try fixture()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: root)
        var checks = 0
        XCTAssertThrowsError(try ModelCatalogArtifactSnapshot.verified(directory: root, sha256: expected, deadline: nil) {
            checks += 1
            if checks == 6 { try Data("changed".utf8).write(to: root.appendingPathComponent("weights.bin")) }
        })
        let current = try ModelArtifactVerifier.canonicalArtifactHash(directory: root)
        let snapshot = try ModelCatalogArtifactSnapshot.verified(directory: root, sha256: current, deadline: nil, check: {})
        let observation = try snapshot.observe(directory: root, deadline: nil)
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try observation.validatePlacement())
        XCTAssertThrowsError(try snapshot.observe(directory: root, deadline: nil))
    }

    func testSymlinkHardlinkUnexpectedFileAndDeadlineRejectSealReuse() throws {
        let root = try fixture()
        let expected = try ModelArtifactVerifier.canonicalArtifactHash(directory: root)
        let snapshot = try ModelCatalogArtifactSnapshot.verified(directory: root, sha256: expected, deadline: nil, check: {})
        XCTAssertThrowsError(try snapshot.observe(directory: root, deadline: Date().addingTimeInterval(-1)))
        try Data().write(to: root.appendingPathComponent("extra"))
        XCTAssertThrowsError(try snapshot.observe(directory: root, deadline: nil))
        try FileManager.default.removeItem(at: root.appendingPathComponent("extra"))
        let linked = root.appendingPathComponent("linked")
        XCTAssertEqual(link(root.appendingPathComponent("weights.bin").path, linked.path), 0)
        XCTAssertThrowsError(try ModelCatalogArtifactSnapshot.verified(directory: root, sha256: expected, deadline: nil, check: {}))
        try FileManager.default.removeItem(at: linked)
        XCTAssertEqual(symlink("weights.bin", linked.path), 0)
        XCTAssertThrowsError(try ModelCatalogArtifactSnapshot.verified(directory: root, sha256: expected, deadline: nil, check: {}))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Build1Seal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data(repeating: 0x61, count: 2_097_152).write(to: root.appendingPathComponent("weights.bin"))
        return root
    }
}
