#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-048-R015 / R007: an admission policy must name exactly the mandatory
/// matrix before any measurement, so a reduced or substituted matrix can never
/// be analyzed to PASS.
final class NativeMTPBenchPolicyTests: XCTestCase {
    private static let templateURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/research/spec048-r015/policy-template.json")

    func testTemplateCoversTheMandatoryMatrix() throws {
        let policy = try load(template())
        XCTAssertEqual(policy.slots, [1])
        XCTAssertEqual(policy.qualifiedSlots, 8)
        XCTAssertEqual(policy.maximumPromptTokens, 4096)
        XCTAssertEqual(policy.promptTokens, [1536, 4096])
        XCTAssertEqual(Set(policy.maxTokens), NativeMTPBenchPolicy.mandatoryMaxTokens)
        XCTAssertEqual(
            policy.matrixCells.map(\.id),
            ["s1-p1536-o128", "s1-p1536-o512", "s1-p4096-o128", "s1-p4096-o512", "s2-p1536-o512", "s8-p1536-o512"]
        )
        XCTAssertEqual(policy.sustainedCellID, "s8-p1536-o512")
        XCTAssertNotNil(policy.cell(id: "s2-p1536-o512"))
        XCTAssertNil(policy.cell(id: "s2-p4096-o512"))
    }

    func testMandatoryPromptStrataAreCappedAndIncludeTheCap() {
        XCTAssertEqual(NativeMTPBenchPolicy.mandatoryPromptTokens(cap: 4096), [1536, 4096])
        XCTAssertEqual(NativeMTPBenchPolicy.mandatoryPromptTokens(cap: 2048), [1536, 2048])
        XCTAssertEqual(NativeMTPBenchPolicy.mandatoryPromptTokens(cap: 32768), [1536, 4096, 32768])
        XCTAssertEqual(NativeMTPBenchPolicy.mandatoryGatedCellIDs(bound: 1, qualifiedSlots: 8), ["s2-p1536-o512", "s8-p1536-o512"])
        XCTAssertEqual(NativeMTPBenchPolicy.mandatoryGatedCellIDs(bound: 7, qualifiedSlots: 8), ["s8-p1536-o512"])
        XCTAssertEqual(NativeMTPBenchPolicy.mandatoryGatedCellIDs(bound: 8, qualifiedSlots: 8), [])
    }

    func testAdmissionPolicyNativeEligibleSlotsMustBeExactlyOneThroughTheBound() throws {
        var missing = try template()
        missing["max_native_active_rows"] = 2
        missing["gated_cells"] = ["s3-p1536-o512", "s8-p1536-o512"]
        XCTAssertThrowsError(try load(missing)) { error in
            XCTAssertTrue("\(error)".contains("slots must be exactly 1...2"), "\(error)")
        }
        var above = try template()
        above["slots"] = [1, 3]
        XCTAssertThrowsError(try load(above)) { error in
            XCTAssertTrue("\(error)".contains("slots must be exactly 1...1"), "\(error)")
        }
    }

    func testAdmissionPolicyPromptStrataAndOutputBudgetsAreExact() throws {
        var missing = try template()
        missing["prompt_tokens"] = [1536]
        XCTAssertThrowsError(try load(missing)) { error in
            XCTAssertTrue("\(error)".contains("prompt_tokens must be exactly [1536, 4096]"), "\(error)")
        }
        var aboveCap = try template()
        aboveCap["prompt_tokens"] = [1536, 4096, 8192]
        XCTAssertThrowsError(try load(aboveCap))
        var noCap = try template()
        noCap.removeValue(forKey: "maximum_prompt_tokens")
        XCTAssertThrowsError(try load(noCap)) { error in
            XCTAssertTrue("\(error)".contains("maximum_prompt_tokens is required"), "\(error)")
        }
        var hugeCap = try template()
        hugeCap["maximum_prompt_tokens"] = 1_048_577
        hugeCap["prompt_tokens"] = [1536, 4096, 1_048_577]
        XCTAssertThrowsError(try load(hugeCap)) { error in
            XCTAssertTrue("\(error)".contains("maximum_prompt_tokens must be within"), "\(error)")
        }
        var smallCap = try template()
        smallCap["maximum_prompt_tokens"] = 1024
        smallCap["prompt_tokens"] = [1024]
        XCTAssertThrowsError(try load(smallCap))
        var outputs = try template()
        outputs["max_tokens"] = [128]
        XCTAssertThrowsError(try load(outputs)) { error in
            XCTAssertTrue("\(error)".contains("max_tokens must be exactly [128, 512]"), "\(error)")
        }
    }

    func testAdmissionPolicyGatedCellsAndSustainedCellAreExact() throws {
        var missing = try template()
        missing["gated_cells"] = ["s8-p1536-o512"]
        XCTAssertThrowsError(try load(missing)) { error in
            XCTAssertTrue("\(error)".contains("gated_cells must be exactly"), "\(error)")
        }
        var substituted = try template()
        substituted["gated_cells"] = ["s2-p4096-o512", "s8-p1536-o512"]
        XCTAssertThrowsError(try load(substituted))
        var malformed = try template()
        malformed["gated_cells"] = ["s2-p1536"]
        XCTAssertThrowsError(try load(malformed))
        var duplicate = try template()
        duplicate["gated_cells"] = ["s1-p1536-o512", "s2-p1536-o512", "s8-p1536-o512"]
        XCTAssertThrowsError(try load(duplicate))
        var sustained = try template()
        sustained["sustained_cell_id"] = "s2-p1536-o512"
        XCTAssertThrowsError(try load(sustained)) { error in
            XCTAssertTrue("\(error)".contains("sustained_cell_id must be s8-p1536-o512"), "\(error)")
        }
        var short = try template()
        short["sustained_seconds"] = 1799
        XCTAssertThrowsError(try load(short))
    }

    func testBoundCoveringEverySlotNeedsNoGatedCells() throws {
        var object = try template()
        object["qualified_slots"] = 2
        object["max_native_active_rows"] = 2
        object["slots"] = [1, 2]
        object["gated_cells"] = []
        object["sustained_cell_id"] = "s2-p1536-o512"
        object["arrival_interval_ms"] = 0
        let policy = try load(object)
        XCTAssertEqual(policy.matrixCells.count, 8)
        XCTAssertNotNil(policy.cell(id: policy.sustainedCellID))
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
        XCTAssertThrowsError(try load(overSlot)) { error in
            XCTAssertTrue("\(error)".contains("cell s8-p1536-o512 exceeds qualified_slots 4"), "\(error)")
        }
        var overBound = try template()
        overBound["qualified_slots"] = 4
        overBound["max_native_active_rows"] = 5
        overBound["slots"] = [1, 2, 3, 4, 5]
        overBound["gated_cells"] = []
        overBound["sustained_cell_id"] = "s4-p1536-o512"
        XCTAssertThrowsError(try load(overBound))
        var outOfRange = try template()
        outOfRange["qualified_slots"] = 9
        XCTAssertThrowsError(try load(outOfRange))
    }

    func testCellBoundIsClampedToTheCellsQualifiedRuntime() throws {
        var object = try template()
        object["max_native_active_rows"] = 4
        object["slots"] = [1, 2, 3, 4]
        object["gated_cells"] = ["s5-p1536-o512", "s8-p1536-o512"]
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

    func testTemplateFreezesAmendedLatencyGatesAndRefusesTheInterChunkGate() throws {
        let policy = try load(template())
        XCTAssertEqual((policy.thresholds["tpot_p95_upper_bound_max"] as? NSNumber)?.doubleValue, 0.0)
        XCTAssertEqual((policy.thresholds["chunk_gap_p99_upper_bound_max"] as? NSNumber)?.doubleValue, 1.0)
        XCTAssertEqual((policy.thresholds["gated_tpot_p95_upper_bound_max"] as? NSNumber)?.doubleValue, 0.05)
        // SPEC-048 0.1.24 gate set: no longer accepted for a new run.
        var legacy = try template()
        var thresholds = try XCTUnwrap(legacy["thresholds"] as? [String: Any])
        thresholds.removeValue(forKey: "tpot_p95_upper_bound_max")
        thresholds.removeValue(forKey: "chunk_gap_p99_upper_bound_max")
        thresholds.removeValue(forKey: "gated_tpot_p95_upper_bound_max")
        thresholds["itl_p95_upper_bound_max"] = 0.0
        thresholds["gated_itl_p95_upper_bound_max"] = 0.05
        legacy["thresholds"] = thresholds
        XCTAssertThrowsError(try load(legacy))
        var looseGap = try template()
        thresholds = try XCTUnwrap(looseGap["thresholds"] as? [String: Any])
        thresholds["chunk_gap_p99_upper_bound_max"] = 1.5
        looseGap["thresholds"] = thresholds
        XCTAssertThrowsError(try load(looseGap))
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
        ungated["qualified_slots"] = 2
        ungated["max_native_active_rows"] = 2
        ungated["slots"] = [1, 2]
        ungated["gated_cells"] = []
        ungated["sustained_cell_id"] = "s2-p1536-o512"
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
        object.removeValue(forKey: "maximum_prompt_tokens")
        object.removeValue(forKey: "gated_cells")
        XCTAssertNoThrow(try load(object))
    }

    func testDuplicateKeysAndBooleanThresholdsFailClosed() throws {
        let template = try String(contentsOf: Self.templateURL, encoding: .utf8)
        let duplicateTop = template.replacingOccurrences(of: "\"blocks\": 10,", with: "\"blocks\": 10, \"blocks\": 10,")
        XCTAssertThrowsError(try loadText(duplicateTop)) { error in
            XCTAssertTrue("\(error)".contains("duplicate JSON key blocks"), "\(error)")
        }
        let duplicateNested = template.replacingOccurrences(of: "\"alpha\": 0.05,", with: "\"alpha\": 0.05, \"alpha\": 0.05,")
        XCTAssertThrowsError(try loadText(duplicateNested))
        XCTAssertNoThrow(try NativeMTPBenchJSON.rejectDuplicateKeys(Data(#"{"a":[{"a":1},{"a":2}],"b":"a"}"#.utf8), label: "t"))
        XCTAssertThrowsError(try NativeMTPBenchJSON.rejectDuplicateKeys(Data(#"{"a":1,"\u0061":2}"#.utf8), label: "t"))
        var boolThreshold = try self.template()
        var thresholds = try XCTUnwrap(boolThreshold["thresholds"] as? [String: Any])
        thresholds["rejection_increase_max_pp"] = true
        boolThreshold["thresholds"] = thresholds
        XCTAssertThrowsError(try load(boolThreshold))
    }

    private func loadText(_ text: String) throws -> NativeMTPBenchPolicy {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-policy-\(UUID().uuidString).json")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try NativeMTPBenchPolicy.load(from: url)
    }

    func testCellIDsRoundTripExactly() {
        XCTAssertEqual(NativeMTPBenchCell(id: "s8-p1536-o512"), NativeMTPBenchCell(slots: 8, promptTokens: 1536, maxTokens: 512))
        for bad in ["s08-p1536-o512", "s8-p1536-o512-x", "s8-p1536", "x8-p1536-o512", "s0-p1536-o512", "s8-p-o512", "s+8-p1536-o512"] {
            XCTAssertNil(NativeMTPBenchCell(id: bad), bad)
        }
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
