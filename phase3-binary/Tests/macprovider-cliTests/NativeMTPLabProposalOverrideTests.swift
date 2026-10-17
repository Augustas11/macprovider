#if DEBUG || MACPROVIDER_LAB_HARNESS
import XCTest
@testable import macprovider_cli

/// JOURNEY-NATIVE-MTP-SERVING step-05 lab fault injection: the override only
/// touches matching rows, rewrites every proposal to a different in-range
/// token, and in block mode fires only when staged positions cross a block.
final class NativeMTPLabProposalOverrideTests: XCTestCase {
    func testEveryRoundRewritesMatchingRowsOnly() {
        let override = NativeMTPLabProposalOverride(rules: [(prefix: "reject-", mode: .everyRound)])
        XCTAssertEqual(override.apply(requestID: "reject-1", committedKVTokenCount: 5, proposals: [10, 11]), [11, 10])
        XCTAssertEqual(override.apply(requestID: "other", committedKVTokenCount: 5, proposals: [10]), [10])
        XCTAssertEqual(override.overriddenRounds(requestID: "reject-1"), 1)
        XCTAssertEqual(override.overriddenRounds(requestID: "other"), 0)
    }

    func testBlockBoundaryFiresOnlyWhenStagedPositionsCrossABlock() {
        let override = NativeMTPLabProposalOverride(rules: [(prefix: "b-", mode: .blockBoundary(blockTokens: 32))])
        // Positions 30...31 stay in block 0.
        XCTAssertEqual(override.apply(requestID: "b-1", committedKVTokenCount: 30, proposals: [7]), [7])
        // Positions 31...32 cross into block 1.
        XCTAssertEqual(override.apply(requestID: "b-1", committedKVTokenCount: 31, proposals: [7]), [6])
        XCTAssertEqual(override.overriddenRounds(requestID: "b-1"), 1)
        // Crossing-only (the Qwen3.5 rule): a round starting on 32 is untouched.
        XCTAssertEqual(override.apply(requestID: "b-1", committedKVTokenCount: 32, proposals: [7]), [7])
    }

    /// A 256-token block (glm5_next): an accepted round can step from 254 to
    /// 256 without any round crossing 256, so the round that starts on the
    /// boundary is forced too.
    func testBlockStartAlsoFiresWhenARoundStartsOnABoundary() {
        let override = NativeMTPLabProposalOverride(rules: [
            (prefix: "g-", mode: .blockBoundary(blockTokens: 256, includeBlockStart: true)),
        ])
        XCTAssertEqual(override.apply(requestID: "g-1", committedKVTokenCount: 254, proposals: [7]), [7])
        XCTAssertEqual(override.apply(requestID: "g-1", committedKVTokenCount: 256, proposals: [7]), [6])
        XCTAssertEqual(override.apply(requestID: "g-1", committedKVTokenCount: 255, proposals: [7]), [6])
        XCTAssertEqual(override.apply(requestID: "g-1", committedKVTokenCount: 0, proposals: [7]), [7])
        XCTAssertEqual(override.overriddenRounds(requestID: "g-1"), 2)
        let zero = NativeMTPLabProposalOverride(rules: [(prefix: "z-", mode: .blockBoundary(blockTokens: 0, includeBlockStart: true))])
        XCTAssertEqual(zero.apply(requestID: "z-1", committedKVTokenCount: 5, proposals: [7]), [7])
    }
}
#endif
