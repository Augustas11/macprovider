import Foundation

struct NativeMTPPackedRowMap: Equatable, Sendable {
    let schedulerRowID: String
    let packedRowIndex: Int
    let inputTokenCount: Int
    let proposalTokenCount: Int

    init(
        schedulerRowID: String,
        packedRowIndex: Int,
        inputTokenCount: Int,
        proposalTokenCount: Int
    ) {
        self.schedulerRowID = schedulerRowID
        self.packedRowIndex = packedRowIndex
        self.inputTokenCount = inputTokenCount
        self.proposalTokenCount = proposalTokenCount
    }
}

struct NativeMTPVerifiedRow: Equatable, Sendable {
    let schedulerRowID: String
    let packedRowIndex: Int
    let proposedTokenIDs: [Int]
    /// Target-selected token at each verified position: the argmax for a
    /// greedy row, the row sampler's draw for a sampled row. Acceptance is an
    /// exact match against these, so one rule covers both.
    let targetTopTokenIDs: [Int]

    init(
        schedulerRowID: String,
        packedRowIndex: Int,
        proposedTokenIDs: [Int],
        targetTopTokenIDs: [Int]
    ) {
        self.schedulerRowID = schedulerRowID
        self.packedRowIndex = packedRowIndex
        self.proposedTokenIDs = proposedTokenIDs
        self.targetTopTokenIDs = targetTopTokenIDs
    }
}

enum NativeMTPTokenCandidateSource: Equatable, Sendable {
    case ordinary
    case acceptedProposal
    case correction
    case bonus
}

struct NativeMTPTokenCandidate: Equatable, Sendable {
    let tokenID: Int
    let source: NativeMTPTokenCandidateSource
    let cumulativeProposalCommitCount: Int
}

struct NativeMTPAcceptedRow: Equatable, Sendable {
    let schedulerRowID: String
    let packedRowIndex: Int
    let inputTokenCount: Int
    let proposalTokenCount: Int
    let acceptedProposalPrefixCount: Int
    let proposalCommitCount: Int
    /// Ordered visibility candidates only. The scheduler must apply terminal,
    /// max-token, cancellation, and stream visibility filters before committing
    /// the derived `cumulativeProposalCommitCount`.
    let tokenCandidates: [NativeMTPTokenCandidate]
}

enum NativeMTPAcceptanceError: Error, Equatable, Sendable {
    case packedRowCountMismatch(expected: Int, actual: Int)
    case verifiedRowCountMismatch(expected: Int, actual: Int)
    case emptySchedulerRowID(packedRowIndex: Int)
    case negativePackedRowIndex(rowID: String, packedRowIndex: Int)
    case duplicateSchedulerRowID(String)
    case duplicatePackedRowIndex(Int)
    case duplicateVerifiedPackedRowIndex(Int)
    case packedRowIndexOutOfBounds(rowID: String, packedRowIndex: Int, packedRowCount: Int)
    case verifiedPackedRowIndexOutOfBounds(rowID: String, packedRowIndex: Int, packedRowCount: Int)
    case negativeProposalTokenCount(rowID: String, count: Int)
    case inputTokenCountMismatch(rowID: String, expected: Int, actual: Int)
    case missingVerification(rowID: String, packedRowIndex: Int)
    case unexpectedVerification(rowID: String, packedRowIndex: Int)
    case verificationRowIDMismatch(expected: String, actual: String, packedRowIndex: Int)
    case proposedTokenCountMismatch(rowID: String, expected: Int, actual: Int)
    case targetTopTokenCountMismatch(rowID: String, expected: Int, actual: Int)
}

enum NativeMTPAcceptance {
    static func acceptGreedy(
        rowMaps: [NativeMTPPackedRowMap],
        verifiedRows: [NativeMTPVerifiedRow],
        packedRowCount: Int
    ) throws -> [NativeMTPAcceptedRow] {
        guard rowMaps.count == packedRowCount else {
            throw NativeMTPAcceptanceError.packedRowCountMismatch(
                expected: packedRowCount,
                actual: rowMaps.count
            )
        }
        guard verifiedRows.count == packedRowCount else {
            throw NativeMTPAcceptanceError.verifiedRowCountMismatch(
                expected: packedRowCount,
                actual: verifiedRows.count
            )
        }
        try validateRowMaps(rowMaps, packedRowCount: packedRowCount)

        var verifiedByPackedIndex: [Int: NativeMTPVerifiedRow] = [:]
        for verifiedRow in verifiedRows {
            guard verifiedRow.packedRowIndex >= 0,
                  verifiedRow.packedRowIndex < packedRowCount else {
                throw NativeMTPAcceptanceError.verifiedPackedRowIndexOutOfBounds(
                    rowID: verifiedRow.schedulerRowID,
                    packedRowIndex: verifiedRow.packedRowIndex,
                    packedRowCount: packedRowCount
                )
            }
            if verifiedByPackedIndex.updateValue(verifiedRow, forKey: verifiedRow.packedRowIndex) != nil {
                throw NativeMTPAcceptanceError.duplicateVerifiedPackedRowIndex(verifiedRow.packedRowIndex)
            }
        }

        let mappedPackedIndices = Set(rowMaps.map(\.packedRowIndex))
        for verifiedRow in verifiedRows where !mappedPackedIndices.contains(verifiedRow.packedRowIndex) {
            throw NativeMTPAcceptanceError.unexpectedVerification(
                rowID: verifiedRow.schedulerRowID,
                packedRowIndex: verifiedRow.packedRowIndex
            )
        }

        return try rowMaps.map { rowMap in
            guard let verifiedRow = verifiedByPackedIndex[rowMap.packedRowIndex] else {
                throw NativeMTPAcceptanceError.missingVerification(
                    rowID: rowMap.schedulerRowID,
                    packedRowIndex: rowMap.packedRowIndex
                )
            }
            guard verifiedRow.schedulerRowID == rowMap.schedulerRowID else {
                throw NativeMTPAcceptanceError.verificationRowIDMismatch(
                    expected: rowMap.schedulerRowID,
                    actual: verifiedRow.schedulerRowID,
                    packedRowIndex: rowMap.packedRowIndex
                )
            }
            guard verifiedRow.proposedTokenIDs.count == rowMap.proposalTokenCount else {
                throw NativeMTPAcceptanceError.proposedTokenCountMismatch(
                    rowID: rowMap.schedulerRowID,
                    expected: rowMap.proposalTokenCount,
                    actual: verifiedRow.proposedTokenIDs.count
                )
            }
            guard verifiedRow.targetTopTokenIDs.count == rowMap.proposalTokenCount + 1 else {
                throw NativeMTPAcceptanceError.targetTopTokenCountMismatch(
                    rowID: rowMap.schedulerRowID,
                    expected: rowMap.proposalTokenCount + 1,
                    actual: verifiedRow.targetTopTokenIDs.count
                )
            }

            let acceptedPrefix = acceptedProposalPrefix(
                proposals: verifiedRow.proposedTokenIDs,
                targetTop: verifiedRow.targetTopTokenIDs
            )
            let candidates = tokenCandidates(
                acceptedPrefix: acceptedPrefix,
                proposedTokenIDs: verifiedRow.proposedTokenIDs,
                targetTopTokenIDs: verifiedRow.targetTopTokenIDs
            )

            return NativeMTPAcceptedRow(
                schedulerRowID: rowMap.schedulerRowID,
                packedRowIndex: rowMap.packedRowIndex,
                inputTokenCount: rowMap.inputTokenCount,
                proposalTokenCount: rowMap.proposalTokenCount,
                acceptedProposalPrefixCount: acceptedPrefix,
                proposalCommitCount: acceptedPrefix,
                tokenCandidates: candidates
            )
        }
    }

    private static func validateRowMaps(
        _ rowMaps: [NativeMTPPackedRowMap],
        packedRowCount: Int
    ) throws {
        var rowIDs: Set<String> = []
        var packedIndices: Set<Int> = []

        for rowMap in rowMaps {
            guard !rowMap.schedulerRowID.isEmpty else {
                throw NativeMTPAcceptanceError.emptySchedulerRowID(packedRowIndex: rowMap.packedRowIndex)
            }
            guard rowIDs.insert(rowMap.schedulerRowID).inserted else {
                throw NativeMTPAcceptanceError.duplicateSchedulerRowID(rowMap.schedulerRowID)
            }
            guard rowMap.packedRowIndex >= 0 else {
                throw NativeMTPAcceptanceError.negativePackedRowIndex(
                    rowID: rowMap.schedulerRowID,
                    packedRowIndex: rowMap.packedRowIndex
                )
            }
            guard rowMap.packedRowIndex < packedRowCount else {
                throw NativeMTPAcceptanceError.packedRowIndexOutOfBounds(
                    rowID: rowMap.schedulerRowID,
                    packedRowIndex: rowMap.packedRowIndex,
                    packedRowCount: packedRowCount
                )
            }
            guard packedIndices.insert(rowMap.packedRowIndex).inserted else {
                throw NativeMTPAcceptanceError.duplicatePackedRowIndex(rowMap.packedRowIndex)
            }
            guard rowMap.proposalTokenCount >= 0 else {
                throw NativeMTPAcceptanceError.negativeProposalTokenCount(
                    rowID: rowMap.schedulerRowID,
                    count: rowMap.proposalTokenCount
                )
            }
            let expectedInputTokenCount = rowMap.proposalTokenCount + 1
            guard rowMap.inputTokenCount == expectedInputTokenCount else {
                throw NativeMTPAcceptanceError.inputTokenCountMismatch(
                    rowID: rowMap.schedulerRowID,
                    expected: expectedInputTokenCount,
                    actual: rowMap.inputTokenCount
                )
            }
        }
    }

    private static func acceptedProposalPrefix(proposals: [Int], targetTop: [Int]) -> Int {
        var accepted = 0
        while accepted < proposals.count, proposals[accepted] == targetTop[accepted] {
            accepted += 1
        }
        return accepted
    }

    private static func tokenCandidates(
        acceptedPrefix: Int,
        proposedTokenIDs: [Int],
        targetTopTokenIDs: [Int]
    ) -> [NativeMTPTokenCandidate] {
        if proposedTokenIDs.isEmpty {
            return [
                NativeMTPTokenCandidate(
                    tokenID: targetTopTokenIDs[0],
                    source: .ordinary,
                    cumulativeProposalCommitCount: 0
                ),
            ]
        }

        var candidates: [NativeMTPTokenCandidate] = []
        for index in 0..<acceptedPrefix {
            candidates.append(NativeMTPTokenCandidate(
                tokenID: proposedTokenIDs[index],
                source: .acceptedProposal,
                cumulativeProposalCommitCount: index + 1
            ))
        }

        if acceptedPrefix == proposedTokenIDs.count {
            candidates.append(NativeMTPTokenCandidate(
                tokenID: targetTopTokenIDs[acceptedPrefix],
                source: .bonus,
                cumulativeProposalCommitCount: acceptedPrefix
            ))
        } else {
            candidates.append(NativeMTPTokenCandidate(
                tokenID: targetTopTokenIDs[acceptedPrefix],
                source: .correction,
                cumulativeProposalCommitCount: acceptedPrefix
            ))
        }

        return candidates
    }
}
