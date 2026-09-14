import Foundation
import XCTest
@testable import macprovider_cli

final class RecommendationAdoptionJournalPathTests: XCTestCase {
    func testRemoveUsesParentPathIndependentOfURLDirectoryHint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RecommendationAdoptionJournalStore(root: root)
        let file = store.url(transactionID: UUID().uuidString.lowercased())
        try Data("{}".utf8).write(to: file)
        try store.remove(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRemoveRejectsDifferentParentWithoutDeletingItsFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let file = other.appendingPathComponent("record.json")
        try Data("{}".utf8).write(to: file)
        let store = RecommendationAdoptionJournalStore(root: root)
        XCTAssertThrowsError(try store.remove(file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
