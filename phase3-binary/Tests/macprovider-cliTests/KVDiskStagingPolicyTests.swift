import Foundation
import XCTest
@testable import macprovider_cli

final class KVDiskStagingPolicyTests: XCTestCase {
    func testLiveLongGLMEntryUsesMeasuredShareInsteadOfLegacyOneGib() {
        let decoded = 1_445_244_936
        let promotion = decoded * 2
        let measured = 4 * 1024 * 1024 * 1024
        XCTAssertEqual(promotion, 2_890_489_872)
        let ceiling = KVDiskStagingPolicy.limit(configured: 1 << 30, adaptive: true, measured: measured)
        XCTAssertEqual(ceiling, measured)
        XCTAssertLessThan(promotion, ceiling)
        XCTAssertLessThan(decoded + 202 * 1024 * 1024, ceiling)
    }

    func testExplicitCeilingsOnlyLowerMeasuredReserve() {
        XCTAssertEqual(KVDiskStagingPolicy.limit(configured: Int.max, adaptive: false, measured: Int.max), 1 << 30)
        XCTAssertEqual(KVDiskStagingPolicy.limit(configured: 1000, adaptive: false, measured: 2000), 1000)
        XCTAssertEqual(KVDiskStagingPolicy.limit(configured: 1000, adaptive: false, measured: 900), 900)
        XCTAssertEqual(KVDiskStagingPolicy.limit(configured: 1000, adaptive: false, measured: 0), 0)
        XCTAssertEqual(KVDiskStagingPolicy.limit(configured: 1000, adaptive: false, measured: -1), 0)
    }

    func testAdaptiveFailsClosedWithoutMeasurementAndAtReserveFloor() {
        XCTAssertEqual(KVDiskStagingPolicy.limit(configured: 1 << 30, adaptive: true, measured: nil), 0)
        XCTAssertEqual(KVDiskStagingPolicy.limit(configured: 1 << 30, adaptive: true, measured: 0), 0)
        XCTAssertEqual(KVDiskStagingPolicy.limit(configured: 1 << 30, adaptive: true, measured: Int.max),
                       KVDiskStagingPolicy.adaptiveHardMax)
    }

    func testServingAttachmentRebindsStoreToRuntimeReserve() async {
        let gib = 1 << 30
        var config = KVDiskCacheStoreConfig(
            root: URL(fileURLWithPath: "/unused-staging-binding"), namespaceID: "test",
            maxBytes: 16 * gib, maxEntries: 64, maxEntryBytes: 2 * gib,
            retentionSeconds: 3600, stagingMaxBytes: gib, writeStagingMaxBytes: gib,
            minFreeBytes: gib, promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        config.adaptiveStaging = true
        config.adaptiveWriteStaging = true
        let initial = ConversationCacheMemoryBudget(probe: .init(identity: "initial-permissive") {
            .init(availableBytes: 128 * gib, physicalBytes: 256 * gib)
        })
        let store = KVDiskCacheStore(config: config, keychain: KVInMemoryKeychain(), memoryBudget: initial)
        let initialLimit = await store.promotionStagingLimit()
        XCTAssertEqual(initialLimit, 4 * gib)
        // The exact production bind call must replace the unrelated initial
        // probe, including the unknown-geometry failure case on first load.
        let runtime = ConversationCacheMemoryBudget(probe: .init(identity: "runtime-unknown") {
            .init(availableBytes: 128 * gib, physicalBytes: 256 * gib)
        })
        runtime.configure(maxContextTokens: 200_000, slots: 4, residentTokens: 26_214_400, verifyBytes: 0)
        await store.bindMemoryBudget(runtime)
        let readLimit = await store.promotionStagingLimit()
        let writeLimit = await store.writeStagingLimit()
        XCTAssertEqual(readLimit, 0)
        XCTAssertEqual(writeLimit, 0)
        runtime.observe(geometry: .init(fixedRowBytes: 150_616_064, bytesPerToken: 11_968))
        let seededLimit = await store.promotionStagingLimit()
        XCTAssertEqual(seededLimit, runtime.stagingByteLimit())
        XCTAssertEqual(seededLimit, 4 * gib)
        let pressure = ConversationCacheMemoryBudget(probe: .init(identity: "runtime-pressure") {
            // System + four rows + slack + hot allowance, then 128 MiB
            // remaining for each disk direction.
            .init(availableBytes: 46_763_432_755 + 256 * 1024 * 1024, physicalBytes: 256 * gib)
        })
        pressure.configure(maxContextTokens: 200_000, slots: 4, residentTokens: 26_214_400, verifyBytes: 0)
        pressure.observe(geometry: .init(fixedRowBytes: 150_616_064, bytesPerToken: 11_968))
        await store.bindMemoryBudget(pressure)
        let pressuredRead = await store.promotionStagingLimit()
        let pressuredWrite = await store.writeStagingLimit()
        XCTAssertEqual(pressuredRead, 128 * 1024 * 1024)
        XCTAssertEqual(pressuredWrite, pressuredRead)
    }

    func testProductionStoreUsesSameMeasuredLimitAsCapture() async {
        let gib = 1024 * 1024 * 1024
        let budget = ConversationCacheMemoryBudget(probe: .init(identity: "disk-staging-policy") {
            .init(availableBytes: 128 * gib, physicalBytes: 256 * gib)
        })
        var config = KVDiskCacheStoreConfig(
            root: URL(fileURLWithPath: "/unused-staging-policy"), namespaceID: "test",
            maxBytes: 16 * gib, maxEntries: 64, maxEntryBytes: 2 * gib,
            retentionSeconds: 3600, stagingMaxBytes: gib, writeStagingMaxBytes: gib,
            minFreeBytes: gib, promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        config.adaptiveStaging = true
        config.adaptiveWriteStaging = true
        let store = KVDiskCacheStore(config: config, keychain: KVInMemoryKeychain(),
                                    memoryBudget: budget)
        let readLimit = await store.promotionStagingLimit()
        let writeLimit = await store.writeStagingLimit()
        XCTAssertEqual(readLimit, 4 * gib)
        XCTAssertEqual(writeLimit, 4 * gib)
        let adapter = KVConversationColdTierAdapter(store: store, namespaceID: "test", eligibilityTTLSeconds: 900,
            adaptiveStaging: true, adaptiveWriteStaging: true, memoryBudget: budget)
        // No tensors or filesystem operations: reservation arithmetic alone.
        let footprint = adapter.writeFootprintForTest(decoded: 1_445_244_936)
        XCTAssertEqual(footprint, 1_646_637_120)
        XCTAssertTrue(adapter.reserveWriteLive(footprint, volumeBytes: 1_445_244_936))
        XCTAssertEqual(adapter.writeLiveBytesForTest, footprint)
        XCTAssertFalse(adapter.reserveWriteLive(4 * gib))
        adapter.releaseWriteLive(footprint)
        XCTAssertEqual(adapter.writeLiveBytesForTest, 0)
        XCTAssertFalse(adapter.reserveWriteLive(Int.max))
        XCTAssertFalse(adapter.reserveWriteLive(-1))
    }
}
