import MLXLLM
@testable import macprovider_cli
import XCTest

final class DeepseekV4PrefillTests: XCTestCase {
    /// Same recurrence as the fork's DeepseekV4Tests.greedy parity oracle:
    /// min(2048, remaining - 1), with the final token alone. No model load.
    private func oraclePlan(tokenCount: Int, start: Int = 0) -> [Range<Int>] {
        var cursor = start
        var result: [Range<Int>] = []
        while tokenCount - cursor > 1 {
            let end = cursor + min(2048, tokenCount - cursor - 1)
            result.append(cursor..<end)
            cursor = end
        }
        return result
    }

    func testLocalPrefillMatchesReferenceOracleRegardlessOfConfiguredStep() throws {
        XCTAssertEqual(DeepseekV4Model.prefillStepSize, 2048)
        for configured in [1, 16, 512, 2048, 8192] {
            for count in [1, 2, 16, 512, 2048, 2049, 2050, 4096, 4097, 5000] {
                var chunks: [Range<Int>] = []
                let cursor = try ModelRuntime.cancellableLocalPrefill(
                    tokenCount: count, from: 0, stepSize: configured,
                    referenceStepSize: DeepseekV4Model.prefillStepSize,
                    isCancelled: { false }
                ) { chunks.append($0) }
                XCTAssertEqual(chunks, oraclePlan(tokenCount: count), "count=\(count), configured=\(configured)")
                XCTAssertEqual(cursor, count - 1, "the iterator must receive the last token alone")
            }
        }
    }

    func testReferencePrefillPreservesCancellationAtEveryBoundary() throws {
        var chunks: [Range<Int>] = []
        XCTAssertThrowsError(try ModelRuntime.cancellableLocalPrefill(
            tokenCount: 5000, from: 0, stepSize: 512,
            referenceStepSize: DeepseekV4Model.prefillStepSize,
            isCancelled: { chunks.count == 1 }
        ) { chunks.append($0) }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(chunks, [0..<2048])

        XCTAssertThrowsError(try ModelRuntime.cancellableLocalPrefill(
            tokenCount: 1, from: 0, stepSize: 512,
            referenceStepSize: DeepseekV4Model.prefillStepSize,
            isCancelled: { true }
        ) { _ in XCTFail("the last token belongs to the iterator") })
    }

    func testOtherFamiliesKeepConfiguredLocalChunkingAndResumeOffset() throws {
        var chunks: [Range<Int>] = []
        let cursor = try ModelRuntime.cancellableLocalPrefill(
            tokenCount: 1300, from: 100, stepSize: 512, isCancelled: { false }
        ) { chunks.append($0) }
        XCTAssertEqual(chunks, [100..<612, 612..<1124])
        XCTAssertEqual(cursor, 1124)
    }
}
