import XCTest
@testable import Malibu

final class ModelsHubTests: XCTestCase {
    func testModelsTabsKeepUserFacingOrder() {
        XCTAssertEqual(ModelsHubTab.allCases.map(\.title), ["Recommended", "Browse", "On this Mac", "Downloads"])
    }

    func testEachModelsTabUsesItsRequiredRows() throws {
        let fitting = try ShellScreensTests.catalogOnlyRow(key: "qwen/fitting", modelID: "mlx-community/Qwen3-8B-4bit")
        let tooLarge = try ShellScreensTests.catalogOnlyRow(key: "qwen/large", modelID: "mlx-community/Qwen3-235B-4bit", fit: "does_not_fit")
        let current = try ShellScreensTests.row(key: "current", isCurrent: true)
        let rows = [current, fitting, tooLarge]
        XCTAssertEqual(ModelsHubPresentation.rows(for: .recommended, rows: rows).map(\.id), [current, fitting].map(\.id))
        XCTAssertEqual(ModelsHubPresentation.rows(for: .browse, rows: rows).map(\.id), rows.map(\.id))
        XCTAssertEqual(ModelsHubPresentation.rows(for: .onThisMac, rows: rows).map(\.id), ModelsPresentation.sections(rows).flatMap(\.rows).map(\.id))
        XCTAssertTrue(ModelsHubPresentation.rows(for: .downloads, rows: rows).isEmpty)
        XCTAssertTrue(ModelsHubPresentation.emptyDownloads.contains("No downloads yet"))
    }

    func testRecentDownloadsExcludeSwitchesAndKeepNewestFirst() {
        let entries = (0..<25).map { index in
            ModelActivityEntry(id: UUID(), timestamp: Date(timeIntervalSince1970: Double(index)), operation: "download", fromModelID: nil, toModelID: "model-\(index)", outcome: index % 2 == 0 ? "success" : "cancelled", reason: nil)
        }
        let switchEntry = ModelActivityEntry(id: UUID(), timestamp: Date(), operation: "switch", fromModelID: "a", toModelID: "b", outcome: "success", reason: nil)
        let recent = ModelsHubPresentation.recentDownloads(entries + [switchEntry])
        XCTAssertEqual(recent.count, 20)
        XCTAssertEqual(recent.first?.toModelID, "model-24")
        XCTAssertEqual(recent.last?.toModelID, "model-5")
        XCTAssertFalse(recent.contains { $0.operation != "download" })
    }
}
