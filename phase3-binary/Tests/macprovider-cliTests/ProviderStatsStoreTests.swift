import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderStatsStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mac.json")
        let store = ProviderStatsStore(fileURL: fileURL)
        let dayStart = Calendar.current.startOfDay(for: Date())
        let record = ProviderStatsRecord(
            version: ProviderStatsRecord.currentVersion,
            providerID: "mac",
            requestsTotal: 42,
            requestsToday: 3,
            requestsTodayDayStart: dayStart,
            inputTokensToday: 100,
            outputTokensToday: 200,
            inputTokensAllTime: 1_000,
            outputTokensAllTime: 2_000,
            errorsTotal: 1,
            restartCount: 2,
            updatedAt: Date()
        )

        store.save(record)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.version, record.version)
        XCTAssertEqual(loaded.providerID, record.providerID)
        XCTAssertEqual(loaded.requestsTotal, record.requestsTotal)
        XCTAssertEqual(loaded.requestsToday, record.requestsToday)
        XCTAssertEqual(loaded.requestsTodayDayStart, record.requestsTodayDayStart)
        XCTAssertEqual(loaded.inputTokensToday, record.inputTokensToday)
        XCTAssertEqual(loaded.outputTokensToday, record.outputTokensToday)
        XCTAssertEqual(loaded.inputTokensAllTime, record.inputTokensAllTime)
        XCTAssertEqual(loaded.outputTokensAllTime, record.outputTokensAllTime)
        XCTAssertEqual(loaded.errorsTotal, record.errorsTotal)
        XCTAssertEqual(loaded.restartCount, record.restartCount)
    }

    func testSanitizeProviderID() {
        XCTAssertEqual(ProviderStatsStore.sanitizeProviderID("p_upiv4dug"), "p_upiv4dug")
        XCTAssertEqual(ProviderStatsStore.sanitizeProviderID("bad/id"), "bad_id")
        XCTAssertEqual(ProviderStatsStore.sanitizeProviderID("   "), "unknown")
    }
}

final class ProviderStatsPersistenceTests: XCTestCase {
    func testProviderStatusRestoresAndPersistsAcrossActorInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mac.json")
        let store = ProviderStatsStore(fileURL: fileURL)

        let first = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 4_000, maxConcurrencyOverride: 1),
            providerID: "mac",
            statsStore: store
        )
        let startedAt = await first.beginRequest(requestID: "r-1")
        await first.finishRequest(
            startedAt: startedAt,
            completion: CompletionResult(content: "ok", finishReason: "stop", promptTokens: 1, completionTokens: 2),
            failed: false,
            requestID: "r-1"
        )

        let reloaded = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 4_000, maxConcurrencyOverride: 1),
            providerID: "mac",
            statsStore: store
        )
        let snap = await reloaded.snapshot()
        XCTAssertEqual(snap.requestsTotal, 1)
        XCTAssertEqual(snap.requestsToday, 1)
        XCTAssertEqual(snap.restartCount, 1)
        XCTAssertEqual(snap.inputTokensAllTime, 1)
        XCTAssertEqual(snap.outputTokensAllTime, 2)
    }

    func testProviderStatusIncrementsRestartCountOnEachServeStart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mac.json")
        let store = ProviderStatsStore(fileURL: fileURL)

        _ = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 4_000, maxConcurrencyOverride: 1),
            providerID: "mac",
            statsStore: store
        )
        let second = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 4_000, maxConcurrencyOverride: 1),
            providerID: "mac",
            statsStore: store
        )
        let snap = await second.snapshot()
        XCTAssertEqual(snap.restartCount, 1)
    }
}
