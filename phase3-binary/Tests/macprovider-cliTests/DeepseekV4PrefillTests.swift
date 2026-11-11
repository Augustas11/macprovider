import MLXLLM
@testable import macprovider_cli
import XCTest

final class DeepseekV4PrefillTests: XCTestCase {
    /// Same recurrence as the fork's DeepseekV4Tests.greedy parity oracle:
    /// whole 32768-token prefix chunks, reserving the final chunk. No model load.
    private func oraclePlan(tokenCount: Int, start: Int = 0) -> [Range<Int>] {
        var cursor = start
        var result: [Range<Int>] = []
        while tokenCount - cursor > 32768 {
            let end = cursor + 32768
            result.append(cursor..<end)
            cursor = end
        }
        return result
    }

    func testLocalPrefillMatchesReferenceOracleRegardlessOfConfiguredStep() throws {
        XCTAssertEqual(DeepseekV4Model.prefillStepSize, 32768)
        for configured in [1, 16, 512, 2048, 8192] {
            for count in [1, 2, 16, 512, 2048, 2049, 2050, 4096, 4097, 5000, 32768, 32769, 65536, 65537] {
                var chunks: [Range<Int>] = []
                let cursor = try ModelRuntime.cancellableLocalPrefill(
                    tokenCount: count, from: 0, stepSize: configured,
                    referenceStepSize: DeepseekV4Model.prefillStepSize, leaveFinalReferenceChunk: true,
                    isCancelled: { false }
                ) { chunks.append($0) }
                XCTAssertEqual(chunks, oraclePlan(tokenCount: count), "count=\(count), configured=\(configured)")
                XCTAssertEqual(cursor, 32768 * ((count - 1) / 32768), "prepare must receive the whole final chunk")
            }
        }
    }

    func testLocalPrefillResumesOnlyWholePrefixChunks() throws {
        let step = DeepseekV4Model.prefillStepSize
        var chunks: [Range<Int>] = []
        let cursor = try ModelRuntime.cancellableLocalPrefill(
            tokenCount: 2 * step + 17, from: step, stepSize: 512,
            referenceStepSize: step, leaveFinalReferenceChunk: true,
            isCancelled: { false }
        ) { chunks.append($0) }
        XCTAssertEqual(chunks, [step..<(2 * step)])
        XCTAssertEqual(cursor, 2 * step)
    }

    func testReferencePrefillPreservesCancellationAtEveryBoundary() throws {
        var chunks: [Range<Int>] = []
        XCTAssertThrowsError(try ModelRuntime.cancellableLocalPrefill(
            tokenCount: 65537, from: 0, stepSize: 512,
            referenceStepSize: DeepseekV4Model.prefillStepSize, leaveFinalReferenceChunk: true,
            isCancelled: { chunks.count == 1 }
        ) { chunks.append($0) }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(chunks, [0..<32768])

        XCTAssertThrowsError(try ModelRuntime.cancellableLocalPrefill(
            tokenCount: 1, from: 0, stepSize: 512,
            referenceStepSize: DeepseekV4Model.prefillStepSize, leaveFinalReferenceChunk: true,
            isCancelled: { true }
        ) { _ in XCTFail("the final chunk belongs to prepare") })
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
