@testable import macprovider_cli
import XCTest

final class NativeMTPAcceptanceTests: XCTestCase {
    func testMixedRaggedRowsAcceptIndependently() throws {
        let accepted = try NativeMTPAcceptance.acceptGreedy(
            rowMaps: [
                row("ordinary", packed: 2, proposals: 0),
                row("all", packed: 0, proposals: 3),
                row("middle-reject", packed: 1, proposals: 4),
            ],
            verifiedRows: [
                verified("middle-reject", packed: 1, proposals: [40, 41, 42, 43], target: [40, 41, 900, 901, 902]),
                verified("ordinary", packed: 2, proposals: [], target: [700]),
                verified("all", packed: 0, proposals: [10, 11, 12], target: [10, 11, 12, 99]),
            ],
            packedRowCount: 3
        )

        XCTAssertEqual(accepted.map(\.schedulerRowID), ["ordinary", "all", "middle-reject"])
        XCTAssertEqual(accepted.map(\.packedRowIndex), [2, 0, 1])
        XCTAssertEqual(accepted[0].tokenCandidates, [candidate(700, .ordinary, commit: 0)])
        XCTAssertEqual(accepted[1].tokenCandidates, [
            candidate(10, .acceptedProposal, commit: 1),
            candidate(11, .acceptedProposal, commit: 2),
            candidate(12, .acceptedProposal, commit: 3),
            candidate(99, .bonus, commit: 3),
        ])
        XCTAssertEqual(accepted[2].tokenCandidates, [
            candidate(40, .acceptedProposal, commit: 1),
            candidate(41, .acceptedProposal, commit: 2),
            candidate(900, .correction, commit: 2),
        ])
    }

    func testRejectsAtEveryProposalPosition() throws {
        for rejectionIndex in 0..<4 {
            var target = [1, 2, 3, 4, 5]
            target[rejectionIndex] = 100 + rejectionIndex

            let accepted = try NativeMTPAcceptance.acceptGreedy(
                rowMaps: [row("row-\(rejectionIndex)", packed: 0, proposals: 4)],
                verifiedRows: [
                    verified(
                        "row-\(rejectionIndex)",
                        packed: 0,
                        proposals: [1, 2, 3, 4],
                        target: target
                    ),
                ],
                packedRowCount: 1
            )

            let acceptedRow = try accepted.single
            XCTAssertEqual(acceptedRow.acceptedProposalPrefixCount, rejectionIndex)
            XCTAssertEqual(acceptedRow.proposalCommitCount, rejectionIndex)
            XCTAssertEqual(acceptedRow.tokenCandidates.last, candidate(100 + rejectionIndex, .correction, commit: rejectionIndex))
        }
    }

    func testAllAcceptedReturnsOrderedCandidatesIncludingBonus() throws {
        let accepted = try NativeMTPAcceptance.acceptGreedy(
            rowMaps: [row("row", packed: 0, proposals: 2)],
            verifiedRows: [verified("row", packed: 0, proposals: [8, 9], target: [8, 9, 10])],
            packedRowCount: 1
        ).single

        XCTAssertEqual(accepted.acceptedProposalPrefixCount, 2)
        XCTAssertEqual(accepted.proposalCommitCount, 2)
        XCTAssertEqual(accepted.tokenCandidates, [
            candidate(8, .acceptedProposal, commit: 1),
            candidate(9, .acceptedProposal, commit: 2),
            candidate(10, .bonus, commit: 2),
        ])
    }

    func testPartialAcceptanceReturnsAcceptedPrefixThenCorrection() throws {
        let accepted = try NativeMTPAcceptance.acceptGreedy(
            rowMaps: [row("row", packed: 0, proposals: 3)],
            verifiedRows: [verified("row", packed: 0, proposals: [8, 9, 10], target: [8, 900, 901, 902])],
            packedRowCount: 1
        ).single

        XCTAssertEqual(accepted.acceptedProposalPrefixCount, 1)
        XCTAssertEqual(accepted.proposalCommitCount, 1)
        XCTAssertEqual(accepted.tokenCandidates, [
            candidate(8, .acceptedProposal, commit: 1),
            candidate(900, .correction, commit: 1),
        ])
    }

    func testNoneAcceptedReturnsSingleCorrectionCandidate() throws {
        let accepted = try NativeMTPAcceptance.acceptGreedy(
            rowMaps: [row("row", packed: 0, proposals: 2)],
            verifiedRows: [verified("row", packed: 0, proposals: [8, 9], target: [10, 11, 12])],
            packedRowCount: 1
        ).single

        XCTAssertEqual(accepted.acceptedProposalPrefixCount, 0)
        XCTAssertEqual(accepted.proposalCommitCount, 0)
        XCTAssertEqual(accepted.tokenCandidates, [candidate(10, .correction, commit: 0)])
    }

    func testTerminalStylePrefixTruncationBeforeBonusDerivesCommitCountWithoutBonusVisibility() throws {
        let accepted = try NativeMTPAcceptance.acceptGreedy(
            rowMaps: [row("row", packed: 0, proposals: 2)],
            verifiedRows: [verified("row", packed: 0, proposals: [8, 9], target: [8, 9, 10])],
            packedRowCount: 1
        ).single

        let visiblePrefix = accepted.tokenCandidates.prefix { $0.source != .bonus }
        let derivedCommitCount = visiblePrefix.last?.cumulativeProposalCommitCount ?? 0

        XCTAssertEqual(visiblePrefix.map(\.tokenID), [8, 9])
        XCTAssertFalse(visiblePrefix.contains { $0.source == .bonus })
        XCTAssertEqual(derivedCommitCount, 2)
    }

    func testRowReorderUsesPackedIndexWithoutBleed() throws {
        let accepted = try NativeMTPAcceptance.acceptGreedy(
            rowMaps: [
                row("scheduler-b", packed: 1, proposals: 1),
                row("scheduler-a", packed: 0, proposals: 1),
            ],
            verifiedRows: [
                verified("scheduler-a", packed: 0, proposals: [50], target: [50, 51]),
                verified("scheduler-b", packed: 1, proposals: [60], target: [999, 61]),
            ],
            packedRowCount: 2
        )

        XCTAssertEqual(accepted[0].schedulerRowID, "scheduler-b")
        XCTAssertEqual(accepted[0].tokenCandidates, [candidate(999, .correction, commit: 0)])

        XCTAssertEqual(accepted[1].schedulerRowID, "scheduler-a")
        XCTAssertEqual(accepted[1].tokenCandidates, [
            candidate(50, .acceptedProposal, commit: 1),
            candidate(51, .bonus, commit: 1),
        ])
    }

    func testInvalidMapsAndVerificationAreRejected() {
        assertThrows(
            rowMaps: [row("row", packed: 0, proposals: 1)],
            verifiedRows: [verified("row", packed: 0, proposals: [1], target: [1, 2])],
            packedRowCount: 2,
            expected: .packedRowCountMismatch(expected: 2, actual: 1)
        )
        assertThrows(
            rowMaps: [row("row", packed: 0, proposals: 1)],
            verifiedRows: [],
            packedRowCount: 1,
            expected: .verifiedRowCountMismatch(expected: 1, actual: 0)
        )
        assertThrows(
            rowMaps: [row("", packed: 0, proposals: 1)],
            verifiedRows: [verified("", packed: 0, proposals: [1], target: [1, 2])],
            packedRowCount: 1,
            expected: .emptySchedulerRowID(packedRowIndex: 0)
        )
        assertThrows(
            rowMaps: [
                row("same", packed: 0, proposals: 1),
                row("same", packed: 1, proposals: 1),
            ],
            verifiedRows: [
                verified("same", packed: 0, proposals: [1], target: [1, 2]),
                verified("same", packed: 1, proposals: [1], target: [1, 2]),
            ],
            packedRowCount: 2,
            expected: .duplicateSchedulerRowID("same")
        )
        assertThrows(
            rowMaps: [row("row", packed: -1, proposals: 1)],
            verifiedRows: [verified("row", packed: -1, proposals: [1], target: [1, 2])],
            packedRowCount: 1,
            expected: .negativePackedRowIndex(rowID: "row", packedRowIndex: -1)
        )
        assertThrows(
            rowMaps: [row("row", packed: 2, proposals: 1)],
            verifiedRows: [verified("row", packed: 2, proposals: [1], target: [1, 2])],
            packedRowCount: 1,
            expected: .packedRowIndexOutOfBounds(rowID: "row", packedRowIndex: 2, packedRowCount: 1)
        )
        assertThrows(
            rowMaps: [
                row("a", packed: 0, proposals: 1),
                row("b", packed: 0, proposals: 1),
            ],
            verifiedRows: [
                verified("a", packed: 0, proposals: [1], target: [1, 2]),
                verified("b", packed: 0, proposals: [1], target: [1, 2]),
            ],
            packedRowCount: 2,
            expected: .duplicatePackedRowIndex(0)
        )
        assertThrows(
            rowMaps: [row("row", packed: 0, input: 0, proposals: 0)],
            verifiedRows: [verified("row", packed: 0, proposals: [], target: [1])],
            packedRowCount: 1,
            expected: .inputTokenCountMismatch(rowID: "row", expected: 1, actual: 0)
        )
        assertThrows(
            rowMaps: [row("row", packed: 0, input: 1, proposals: 1)],
            verifiedRows: [verified("row", packed: 0, proposals: [1], target: [1, 2])],
            packedRowCount: 1,
            expected: .inputTokenCountMismatch(rowID: "row", expected: 2, actual: 1)
        )
        assertThrows(
            rowMaps: [row("row", packed: 0, proposals: -1)],
            verifiedRows: [verified("row", packed: 0, proposals: [], target: [])],
            packedRowCount: 1,
            expected: .negativeProposalTokenCount(rowID: "row", count: -1)
        )
        assertThrows(
            rowMaps: [
                row("a", packed: 0, proposals: 1),
                row("b", packed: 1, proposals: 1),
            ],
            verifiedRows: [
                verified("a", packed: 0, proposals: [1], target: [1, 2]),
                verified("b", packed: 0, proposals: [3], target: [3, 4]),
            ],
            packedRowCount: 2,
            expected: .duplicateVerifiedPackedRowIndex(0)
        )
        assertThrows(
            rowMaps: [row("row", packed: 0, proposals: 1)],
            verifiedRows: [verified("extra", packed: 1, proposals: [1], target: [1, 2])],
            packedRowCount: 1,
            expected: .verifiedPackedRowIndexOutOfBounds(rowID: "extra", packedRowIndex: 1, packedRowCount: 1)
        )
        assertThrows(
            rowMaps: [row("row", packed: 0, proposals: 1)],
            verifiedRows: [verified("wrong", packed: 0, proposals: [1], target: [1, 2])],
            packedRowCount: 1,
            expected: .verificationRowIDMismatch(expected: "row", actual: "wrong", packedRowIndex: 0)
        )
        assertThrows(
            rowMaps: [row("row", packed: 0, proposals: 2)],
            verifiedRows: [verified("row", packed: 0, proposals: [1], target: [1, 2, 3])],
            packedRowCount: 1,
            expected: .proposedTokenCountMismatch(rowID: "row", expected: 2, actual: 1)
        )
        assertThrows(
            rowMaps: [row("row", packed: 0, proposals: 2)],
            verifiedRows: [verified("row", packed: 0, proposals: [1, 2], target: [1, 2])],
            packedRowCount: 1,
            expected: .targetTopTokenCountMismatch(rowID: "row", expected: 3, actual: 2)
        )
    }

    private func assertThrows(
        rowMaps: [NativeMTPPackedRowMap],
        verifiedRows: [NativeMTPVerifiedRow],
        packedRowCount: Int,
        expected: NativeMTPAcceptanceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try NativeMTPAcceptance.acceptGreedy(
                rowMaps: rowMaps,
                verifiedRows: verifiedRows,
                packedRowCount: packedRowCount
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? NativeMTPAcceptanceError, expected, file: file, line: line)
        }
    }

    private func row(
        _ id: String,
        packed: Int,
        input: Int? = nil,
        proposals: Int
    ) -> NativeMTPPackedRowMap {
        NativeMTPPackedRowMap(
            schedulerRowID: id,
            packedRowIndex: packed,
            inputTokenCount: input ?? proposals + 1,
            proposalTokenCount: proposals
        )
    }

    private func verified(
        _ id: String,
        packed: Int,
        proposals: [Int],
        target: [Int]
    ) -> NativeMTPVerifiedRow {
        NativeMTPVerifiedRow(
            schedulerRowID: id,
            packedRowIndex: packed,
            proposedTokenIDs: proposals,
            targetTopTokenIDs: target
        )
    }

    private func candidate(
        _ tokenID: Int,
        _ source: NativeMTPTokenCandidateSource,
        commit: Int
    ) -> NativeMTPTokenCandidate {
        NativeMTPTokenCandidate(
            tokenID: tokenID,
            source: source,
            cumulativeProposalCommitCount: commit
        )
    }
}

private enum NativeMTPAcceptanceTestError: Error {
    case expectedSingleElement(Int)
}

private extension Array {
    var single: Element {
        get throws {
            guard count == 1 else {
                throw NativeMTPAcceptanceTestError.expectedSingleElement(count)
            }
            return self[0]
        }
    }
}
