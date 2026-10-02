#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-048-R015 / R007: an admission policy must cover the mandatory matrix
/// before any measurement, so a reduced matrix can never be analyzed to PASS.
final class NativeMTPBenchPolicyTests: XCTestCase {
    private static let templateURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/research/spec048-r015/policy-template.json")

    func testTemplateCoversTheMandatoryMatrix() throws {
        let policy = try load(template())
        XCTAssertEqual(policy.slots, Array(1...8))
        XCTAssertEqual(policy.qualifiedSlots, 8)
        XCTAssertTrue(NativeMTPBenchPolicy.mandatoryPromptTokens.isSubset(of: Set(policy.promptTokens)))
        XCTAssertTrue(NativeMTPBenchPolicy.mandatoryMaxTokens.isSubset(of: Set(policy.maxTokens)))
    }

    func testAdmissionPolicyWithoutOneSlotCellFailsClosed() throws {
        var object = try template()
        object["slots"] = [2, 4, 8]
        XCTAssertThrowsError(try load(object)) { error in
            XCTAssertTrue("\(error)".contains("slots missing mandatory counts [1, 3, 5, 6, 7]"), "\(error)")
        }
    }

    func testAdmissionPolicyMissingAPromptStratumOrOutputBudgetFailsClosed() throws {
        var prompts = try template()
        prompts["prompt_tokens"] = [1536, 4096]
        XCTAssertThrowsError(try load(prompts)) { error in
            XCTAssertTrue("\(error)".contains("prompt_tokens missing mandatory strata [8192]"), "\(error)")
        }
        var outputs = try template()
        outputs["max_tokens"] = [128]
        XCTAssertThrowsError(try load(outputs)) { error in
            XCTAssertTrue("\(error)".contains("max_tokens missing mandatory budgets [512]"), "\(error)")
        }
    }

    func testAdmissionPolicyRequiresQualifiedSlotsAndBound() throws {
        var noQualified = try template()
        noQualified.removeValue(forKey: "qualified_slots")
        XCTAssertThrowsError(try load(noQualified))
        var noBound = try template()
        noBound.removeValue(forKey: "max_native_active_rows")
        XCTAssertThrowsError(try load(noBound))
    }

    func testSlotsAndBoundCannotExceedQualifiedSlots() throws {
        var overSlot = try template()
        overSlot["qualified_slots"] = 4
        XCTAssertThrowsError(try load(overSlot))
        var overBound = try template()
        overBound["slots"] = [1, 2, 3, 4]
        overBound["qualified_slots"] = 4
        overBound["max_native_active_rows"] = 5
        overBound["sustained_cell_id"] = "s4-p4096-o512"
        XCTAssertThrowsError(try load(overBound))
        var outOfRange = try template()
        outOfRange["qualified_slots"] = 9
        XCTAssertThrowsError(try load(outOfRange))
    }

    func testCellBoundIsClampedToTheCellsQualifiedRuntime() throws {
        var object = try template()
        object["max_native_active_rows"] = 4
        let policy = try load(object)
        XCTAssertEqual(policy.maxNativeActiveRows(for: NativeMTPBenchCell(slots: 1, promptTokens: 1536, maxTokens: 128)), 2)
        XCTAssertEqual(policy.maxNativeActiveRows(for: NativeMTPBenchCell(slots: 3, promptTokens: 1536, maxTokens: 128)), 3)
        XCTAssertEqual(policy.maxNativeActiveRows(for: NativeMTPBenchCell(slots: 8, promptTokens: 1536, maxTokens: 128)), 4)
    }

    func testTemplateFreezesBoundOneAndGatedNonInferiorityMargins() throws {
        let policy = try load(template())
        XCTAssertEqual(policy.maxNativeActiveRows, 1)
        XCTAssertEqual((policy.thresholds["gated_throughput_lower_bound_min"] as? NSNumber)?.doubleValue, -0.05)
        var unfrozen = try template()
        var thresholds = try XCTUnwrap(unfrozen["thresholds"] as? [String: Any])
        thresholds.removeValue(forKey: "gated_ttft_p95_upper_bound_max")
        unfrozen["thresholds"] = thresholds
        XCTAssertThrowsError(try load(unfrozen))
        var relaxed = try template()
        thresholds = try XCTUnwrap(relaxed["thresholds"] as? [String: Any])
        thresholds["gated_throughput_lower_bound_min"] = -0.2
        relaxed["thresholds"] = thresholds
        XCTAssertThrowsError(try load(relaxed))
    }

    func testGatedCellsRequireStaggeredArrivals() throws {
        XCTAssertEqual(try load(template()).arrivalIntervalMS, 250)
        var simultaneous = try template()
        simultaneous["arrival_interval_ms"] = 0
        XCTAssertThrowsError(try load(simultaneous)) { error in
            XCTAssertTrue("\(error)".contains("arrival_interval_ms must be > 0"), "\(error)")
        }
        // A bound covering every slot leaves no gated cell to stagger.
        var ungated = try template()
        ungated["arrival_interval_ms"] = 0
        ungated["max_native_active_rows"] = 8
        XCTAssertNoThrow(try load(ungated))
    }

    /// Golden vectors shared with scripts/tests/test_native_mtp_r015_analyze.py:
    /// the analyzer recomputes this order and rejects any other.
    func testPreregisteredRunOrderMatchesAnalyzerGoldenVectors() {
        XCTAssertEqual(
            NativeMTPBenchPolicy.nativeFirstOrder(seed: 48015, cell: NativeMTPBenchCell(slots: 8, promptTokens: 4096, maxTokens: 512), blocks: 10),
            [true, false, false, false, true, false, true, true, true, false]
        )
        XCTAssertEqual(
            NativeMTPBenchPolicy.nativeFirstOrder(seed: 1234, cell: NativeMTPBenchCell(slots: 1, promptTokens: 1536, maxTokens: 128), blocks: 10),
            [false, true, true, false, true, false, true, false, false, true]
        )
        let odd = NativeMTPBenchPolicy.nativeFirstOrder(seed: 0, cell: NativeMTPBenchCell(slots: 2, promptTokens: 8192, maxTokens: 128), blocks: 11)
        XCTAssertEqual(odd, [false, false, true, false, true, true, true, true, false, false, true])
        XCTAssertEqual(odd.filter { $0 }.count, 6)
    }

    func testExploratoryPolicyMayUseAReducedMatrix() throws {
        var object = try template()
        object["schema"] = "macprovider.native-mtp-exploratory-policy.v1"
        object["slots"] = [2]
        object["prompt_tokens"] = [384]
        object["max_tokens"] = [64]
        object["sustained_seconds"] = 0
        object["sustained_cell_id"] = "s2-p384-o64"
        object.removeValue(forKey: "qualified_slots")
        object.removeValue(forKey: "max_native_active_rows")
        XCTAssertNoThrow(try load(object))
    }

    private func template() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.templateURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func load(_ object: [String: Any]) throws -> NativeMTPBenchPolicy {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-policy-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try NativeMTPBenchPolicy.load(from: url)
    }
}
#endif
