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
        XCTAssertEqual(ModelsHubPresentation.rows(for: .onThisMac, rows: rows).map(\.id), ModelsPresentation.sections(ModelsPresentation.onThisMacRows(rows)).flatMap(\.rows).map(\.id))
        // Catalog-only rows are not on this Mac: that tab lists the served model only.
        XCTAssertEqual(ModelsHubPresentation.rows(for: .onThisMac, rows: rows).map(\.id), [current.id])
        XCTAssertTrue(ModelsHubPresentation.rows(for: .downloads, rows: rows).isEmpty)
        XCTAssertTrue(ModelsHubPresentation.emptyDownloads.contains("No downloads yet"))
    }

    func testRecommendedAlwaysFitsWhileBrowseCanShowTheFullCatalog() throws {
        let fitting = try ShellScreensTests.catalogOnlyRow(key: "fits", modelID: "vendor/fits")
        let large = try ShellScreensTests.catalogOnlyRow(key: "large", modelID: "vendor/large", fit: "does_not_fit")
        for filter in [false, true] {
            XCTAssertEqual(ModelsHubPresentation.discoveryRows(for: .recommended, rows: [fitting, large],
                search: "", fitsOnly: filter, sort: .bestMatch).map(\.id), [fitting.id])
        }
        XCTAssertEqual(ModelsHubPresentation.discoveryRows(for: .browse, rows: [fitting, large],
            search: "", fitsOnly: false, sort: .bestMatch).map(\.id), [fitting.id, large.id])
        XCTAssertEqual(ModelsHubPresentation.discoveryRows(for: .browse, rows: [fitting, large],
            search: "", fitsOnly: true, sort: .bestMatch).map(\.id), [fitting.id])
    }

    func testRecommendedShowsTheTopFiveFittingRowsAndBrowseShowsAll() throws {
        let rows = try (1...7).map { index in
            try ShellScreensTests.row(key: "model-\(index)", weightsLocal: true, completion: Double(index) / 10)
        }
        let large = try ShellScreensTests.row(key: "large", fit: "does_not_fit", weightsLocal: true)
        let all = rows + [large]
        XCTAssertEqual(ModelsHubPresentation.discoveryRows(for: .recommended, rows: all, search: "", fitsOnly: false, sort: .bestMatch).map(\.id),
                       ["model-1", "model-2", "model-3", "model-4", "model-5"], "the first five fitting rows in R005 order")
        XCTAssertEqual(ModelsHubPresentation.discoveryRows(for: .recommended, rows: all, search: "", fitsOnly: false, sort: .rate).map(\.id),
                       ["model-5", "model-4", "model-3", "model-2", "model-1"], "a sort reorders the same five rows")
        XCTAssertEqual(ModelsHubPresentation.discoveryRows(for: .browse, rows: all, search: "", fitsOnly: false, sort: .bestMatch).count, 8,
                       "Browse still lists every signed catalog model")
        XCTAssertEqual(DiscoverPresentation.recommendedLimit, 5)
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
