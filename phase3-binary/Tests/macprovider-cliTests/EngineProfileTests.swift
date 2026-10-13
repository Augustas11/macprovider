import XCTest
@testable import macprovider_cli

final class EngineProfileTests: XCTestCase {
    func testEngineFamilyPrefersNativeMTPThenContinuousBatching() {
        let mtp = EngineProfile(nativeMTPActive: true, continuousBatchingActive: true, cbGrantedSlots: 4, chip: "Apple M3 Max", ramGB: 64, maxContextTokens: 32_768)
        XCTAssertEqual(mtp.engineFamily, "native_mtp")
        XCTAssertEqual(mtp.cbGrantedSlots, 4)
        XCTAssertTrue(mtp.nativeMTPActive)

        let cb = EngineProfile(nativeMTPActive: false, continuousBatchingActive: true, cbGrantedSlots: 8, chip: "Apple M2 Ultra", ramGB: 192, maxContextTokens: 65_536)
        XCTAssertEqual(cb.engineFamily, "continuous_batching")
        XCTAssertEqual(cb.cbGrantedSlots, 8)

        let plain = EngineProfile(nativeMTPActive: false, continuousBatchingActive: false, cbGrantedSlots: 8, chip: "Apple M1", ramGB: 8, maxContextTokens: 8_192)
        XCTAssertEqual(plain.engineFamily, "general_mlx")
        XCTAssertEqual(plain.cbGrantedSlots, 0, "granted slots only count while continuous batching is active")
    }

    func testChipClassIsClosed() {
        XCTAssertEqual(EngineProfile.chipClass("Apple M1"), "m1")
        XCTAssertEqual(EngineProfile.chipClass("Apple M2 Pro"), "m2_pro")
        XCTAssertEqual(EngineProfile.chipClass("Apple M4 Max"), "m4_max")
        XCTAssertEqual(EngineProfile.chipClass("Apple M3 Ultra"), "m3_ultra")
        XCTAssertEqual(EngineProfile.chipClass("Apple M5 (Virtual)"), "m5")
        XCTAssertEqual(EngineProfile.chipClass("Intel Core i9"), "unknown")
        XCTAssertEqual(EngineProfile.chipClass("Apple M10"), "unknown")
        XCTAssertEqual(EngineProfile.chipClass(""), "unknown")
        XCTAssertEqual(EngineProfile.chipClass(nil), "unknown")
    }

    func testRAMClassAndBounds() {
        XCTAssertEqual(EngineProfile.ramClass(4), 8)
        XCTAssertEqual(EngineProfile.ramClass(8), 8)
        XCTAssertEqual(EngineProfile.ramClass(18), 16)
        XCTAssertEqual(EngineProfile.ramClass(36), 32)
        XCTAssertEqual(EngineProfile.ramClass(192), 192)
        XCTAssertEqual(EngineProfile.ramClass(1024), 512)
        let bounded = EngineProfile(nativeMTPActive: false, continuousBatchingActive: true, cbGrantedSlots: 10_000, chip: nil, ramGB: 16, maxContextTokens: 50_000_000)
        XCTAssertEqual(bounded.cbGrantedSlots, EngineProfile.maximumCBGrantedSlots)
        XCTAssertEqual(bounded.maxStableContextTokens, EngineProfile.maximumContextTokens)
    }

    func testWireObjectIsClosedAndVersioned() throws {
        let profile = EngineProfile(nativeMTPActive: false, continuousBatchingActive: true, cbGrantedSlots: 3, chip: "Apple M2 Max", ramGB: 96, maxContextTokens: 32_768)
        let object = profile.wireObject
        XCTAssertEqual(Set(object.keys), ["version", "engine_family", "cb_granted_slots", "native_mtp_active", "chip_class", "ram_class_gb", "max_stable_context_tokens"])
        XCTAssertEqual(object["version"] as? String, "engine-profile-v1")
        XCTAssertEqual(object["engine_family"] as? String, "continuous_batching")
        XCTAssertEqual(object["chip_class"] as? String, "m2_max")
        XCTAssertEqual(object["ram_class_gb"] as? Int, 96)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(data.count, 512)
    }
}
