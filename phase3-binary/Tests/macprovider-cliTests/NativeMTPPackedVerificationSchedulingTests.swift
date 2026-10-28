import MLX
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// oMLX equal-depth cohorts and DeepInfer batch-invariant target sampling.
final class NativeMTPPackedVerificationSchedulingTests: XCTestCase {
    typealias Backend = PagedKVSharedForwardBackend

    func testVariableDepthRowsPackWithoutPaddingAndKeepOriginalIdentity() {
        let widths = [2, 2, 1, 1, 3, 3, 2]
        let groups = Backend.packedVerifyGroups(widths: widths, maxTokens: 8)
        XCTAssertEqual(groups, [[0, 1], [2, 3], [4, 5], [6]])
        XCTAssertEqual(groups.flatMap { $0 }, Array(widths.indices))
        for group in groups {
            XCTAssertEqual(Set(group.map { widths[$0] }).count, 1)
            XCTAssertLessThanOrEqual(group.reduce(0) { $0 + widths[$1] }, 8)
        }
        let paddedConsecutiveCost = Backend.verifyGroups(widths: widths, maxTokens: 8)
            .reduce(0) { $0 + ($1.map { widths[$0] }.max() ?? 0) * $1.count }
        XCTAssertLessThan(widths.reduce(0, +), paddedConsecutiveCost)
    }

    func testEveryRowCountAndPermutationPreservesWidthAndVectorRouteBound() {
        for count in 1...16 {
            let original = (0..<count).map { 1 + $0 % 4 }
            for widths in [original, Array(original.reversed()), original.sorted()] {
                for cap in [1, 8, 11, Int.max] {
                    let groups = Backend.packedVerifyGroups(widths: widths, maxTokens: cap)
                    XCTAssertEqual(groups.flatMap { $0 }, Array(widths.indices))
                    for group in groups {
                        XCTAssertEqual(Set(group.map { widths[$0] }).count, 1)
                        XCTAssertTrue(group.count == 1 || group.count <= cap / widths[group[0]])
                    }
                }
            }
        }
        XCTAssertEqual(Backend.packedVerifyGroups(widths: [], maxTokens: 8), [])
        XCTAssertEqual(Backend.packedVerifyGroups(widths: [Int.max, 1, Int.max], maxTokens: Int.max), [[0], [1], [2]])
    }

    func testTargetSamplesAreExactAcrossDepthCohortsAndRowPermutations() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX metallib unavailable; run on the hardware test host")
        }
        let widths = [2, 1, 3, 2]
        let logits = widths.enumerated().map { row, width in
            MLXArray((0..<width * 8).map { Float(($0 * 7 + row * 3) % 13) / 5 }, [width, 8])
        }
        let samplers = widths.indices.map { row in
            ContinuousBatchRowSampler.Row(
                temperature: row % 2 == 0 ? 1.0 : 0, topP: 0.95,
                samplerSeed: 100 + row, samplerStep: 17 + row
            )
        }
        func sample(_ indices: [Int]) -> [[Int]] {
            Backend.packedTargetTokenIDs(rows: indices.map { index in
                let width = widths[index]
                return (logits[index][..<(width - 1), 0...], logits[index][(width - 1) ..< width, 0...])
            }, samplers: indices.map { samplers[$0] })
        }
        let lone = widths.indices.map { sample([$0])[0] }
        for order in [[0], [0, 1], [0, 1, 2, 3], [3, 1, 0, 2]] {
            XCTAssertEqual(sample(order), order.map { lone[$0] })
            var packed: [Int: [Int]] = [:]
            for group in Backend.packedVerifyGroups(widths: order.map { widths[$0] }, maxTokens: 8) {
                let ids = group.map { order[$0] }
                for (id, tokens) in zip(ids, sample(ids)) { packed[id] = tokens }
            }
            for id in order { XCTAssertEqual(packed[id], lone[id]) }
        }
    }
}
