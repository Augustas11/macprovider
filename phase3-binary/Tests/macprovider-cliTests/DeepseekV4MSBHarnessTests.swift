import XCTest
@testable import macprovider_cli

final class DeepseekV4MSBHarnessTests: XCTestCase {
    func testOnlyReferencePoolMeasurementShapesAreAccepted() throws {
        for rows in [1, 2, 4, 8] {
            for scenario in [MSBThroughputScenario.throughput, .parity] {
                XCTAssertNoThrow(try MSBThroughputCommand.validateDeepseekV4Harness(
                    engine: .scheduler, scenario: scenario, compiled: false, rows: rows))
            }
        }
        for rows in [0, 9] {
            XCTAssertThrowsError(try MSBThroughputCommand.validateDeepseekV4Harness(
                engine: .scheduler, scenario: .throughput, compiled: false, rows: rows))
        }
        for engine in [MSBThroughputEngine.contiguous, .paged, .serialParallel] {
            XCTAssertThrowsError(try MSBThroughputCommand.validateDeepseekV4Harness(
                engine: engine, scenario: .throughput, compiled: false, rows: 4))
        }
        XCTAssertThrowsError(try MSBThroughputCommand.validateDeepseekV4Harness(
            engine: .scheduler, scenario: .throughput, compiled: true, rows: 4))
        XCTAssertThrowsError(try MSBThroughputCommand.validateDeepseekV4Harness(
            engine: .scheduler, scenario: .raggedPrefill, compiled: false, rows: 4))
    }
}
