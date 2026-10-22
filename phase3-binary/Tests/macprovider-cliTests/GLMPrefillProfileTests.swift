#if DEBUG || MACPROVIDER_LAB_HARNESS
import XCTest
@testable import macprovider_cli

final class GLMPrefillProfileTests: XCTestCase {
    func testModeEnvironmentCannotContaminateWallMeasurement() throws {
        let base = ["MACPROVIDER_NATIVE_MTP_E2E": "1"]
        try GLMPrefillProfileCommand.validate(mode: .wallOnly, environment: base)
        XCTAssertThrowsError(try GLMPrefillProfileCommand.validate(mode: .census, environment: base))
        let split = base.merging(["MLX_MAX_OPS_PER_BUFFER": "0"]) { _, new in new }
        try GLMPrefillProfileCommand.validate(mode: .census, environment: split)
        XCTAssertThrowsError(try GLMPrefillProfileCommand.validate(mode: .wallOnly, environment: split))
        XCTAssertThrowsError(try GLMPrefillProfileCommand.validate(mode: .wallOnly, environment: [:]))
        XCTAssertThrowsError(try GLMPrefillProfileCommand.validate(
            mode: .census, environment: base.merging(["MLX_MAX_OPS_PER_BUFFER": "1"]) { _, new in new }
        ))
    }

    func testDeviceIntervalUnionDoesNotDoubleCountOverlapOrContainment() {
        XCTAssertEqual(LabDispatchCensus.unionSeconds([(4, 8), (1, 5), (2, 3), (10, 11)]), 8)
        XCTAssertEqual(LabDispatchCensus.unionSeconds([]), 0)
        XCTAssertEqual(LabDispatchCensus.unionSeconds([(1, 2), (2, 3)]), 2)
    }

    func testChunkSummaryPreservesUnattributedResiduals() {
        let chunks: [[String: Any]] = [
            ["census": ["valid_command_buffers": 3, "single_dispatch_command_buffers": 1,
                        "unknown_command_buffers": 1, "multi_dispatch_command_buffers": 1,
                        "gpu_busy_seconds": 2.0, "unknown_seconds": 0.2, "multi_dispatch_seconds": 0.3,
                        "kernel_seconds": ["kda": 1.5]]],
            ["census": ["valid_command_buffers": 1, "single_dispatch_command_buffers": 1,
                        "gpu_busy_seconds": 1.0, "kernel_seconds": ["kda": 1.0]]],
        ]
        let summary = GLMPrefillProfileCapture.censusSummary(chunks)
        XCTAssertEqual(summary["valid_command_buffers"] as? Int, 4)
        XCTAssertEqual(summary["single_dispatch_command_buffers"] as? Int, 2)
        XCTAssertEqual(summary["unknown_command_buffers"] as? Int, 1)
        XCTAssertEqual(summary["multi_dispatch_command_buffers"] as? Int, 1)
        XCTAssertEqual(summary["gpu_busy_seconds"] as? Double, 3)
        XCTAssertEqual(summary["unknown_seconds"] as? Double, 0.2)
        XCTAssertEqual((summary["kernel_seconds"] as? [String: Double])?["kda"], 2.5)
    }
}
#endif
