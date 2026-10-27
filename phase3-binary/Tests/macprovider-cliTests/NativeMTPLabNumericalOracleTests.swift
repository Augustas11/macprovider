#if DEBUG || MACPROVIDER_LAB_HARNESS
import XCTest
@testable import macprovider_cli

final class NativeMTPLabNumericalOracleTests: XCTestCase {
    private let id = "numerical-pair"
    private let logits: [Float] = [0, 1, 0.4]

    private func selectAndEmit(
        _ oracle: NativeMTPLabNumericalOracle, role: NativeMTPLabNumericalOracle.Role,
        requestID: String, ordinal: Int, tokenID: Int
    ) -> Bool {
        guard oracle.select(role: role, requestID: requestID, position: ordinal, tokenID: tokenID) else { return false }
        return oracle.emit(role: role, requestID: requestID, ordinal: ordinal, tokenID: tokenID)
    }

    private func reference(
        _ oracle: NativeMTPLabNumericalOracle, tokens: [Int], vectors: [[Float]]? = nil,
        terminal: NativeMTPLabNumericalOracle.Terminal = .other
    ) {
        for (position, token) in tokens.enumerated() {
            oracle.capture(
                role: .ordinary, requestID: id, position: position, tokenID: token,
                logits: vectors?[position] ?? logits)
            XCTAssertTrue(selectAndEmit(oracle, role: .ordinary, requestID: id, ordinal: position, tokenID: token))
        }
        oracle.finishRequest(role: .ordinary, requestID: id, emittedCount: tokens.count, terminal: terminal)
    }

    func testFirstPrefillAndSampledTokensUseVisiblePosition() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        // Token zero deliberately differs from the argmax: sampled parity
        // compares actual token IDs, independently of the top1 assertion.
        reference(oracle, tokens: [0, 1])
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 0, logits: logits)
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 0))
        oracle.capture(role: .native, requestID: id, position: 1, tokenID: 1, logits: logits, speculative: true)
        oracle.resolveNativeRound(requestID: id, acceptedTokenIDs: [1])
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 1, tokenID: 1))
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 2)
        let result = oracle.summary()
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.positions.map(\.ordinaryTop1), [1, 1])
        XCTAssertEqual(result.positions.map(\.ordinaryToken), [0, 1])
        XCTAssertEqual(result.positions.map(\.nativeToken), [0, 1])
        XCTAssertEqual(result.positions[0].ordinaryGap!, 0.6, accuracy: 0.000001)
        XCTAssertEqual(result.retainedVectors, 0)
    }

    func testMismatchReplacementIncludesItsVectorAndDiscardsLaterDrafts() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [1, 0, 1])
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits, speculative: true)
        oracle.capture(role: .native, requestID: id, position: 1, tokenID: 0, logits: logits, speculative: true)
        oracle.capture(role: .native, requestID: id, position: 2, tokenID: 2, logits: [.nan], speculative: true)
        oracle.resolveNativeRound(requestID: id, acceptedTokenIDs: [1, 0])
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 1, tokenID: 0))
        // Recomputed after the mismatch; the discarded vector cannot leak.
        oracle.capture(role: .native, requestID: id, position: 2, tokenID: 1, logits: logits, speculative: true)
        oracle.resolveNativeRound(requestID: id, acceptedTokenIDs: [1])
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 2, tokenID: 1))
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 3)
        XCTAssertTrue(oracle.summary().passed)
    }

    func testAllAcceptedIncludesBonusAndStopHeldEmissionCanWait() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [1, 0, 1])
        for (position, token) in [1, 0, 1].enumerated() {
            oracle.capture(role: .native, requestID: id, position: position, tokenID: token, logits: logits, speculative: true)
        }
        oracle.resolveNativeRound(requestID: id, acceptedTokenIDs: [1, 0, 1])
        for (position, token) in [1, 0, 1].enumerated() {
            XCTAssertTrue(oracle.select(role: .native, requestID: id, position: position, tokenID: token))
        }
        // Stop-prefix buffering has not emitted these tokens yet. Their
        // comparisons are compact: only ordinary vectors remain retained.
        XCTAssertEqual(oracle.summary().positions.count, 0)
        XCTAssertEqual(oracle.summary().selectedPositions.count, 3)
        XCTAssertEqual(oracle.summary().retainedVectors, 3)
        for (position, token) in [1, 0, 1].enumerated() {
            XCTAssertTrue(oracle.emit(role: .native, requestID: id, ordinal: position, tokenID: token))
        }
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 3)
        XCTAssertTrue(oracle.summary().passed)
    }

    func testUnappliedSuffixIsDiscardedWithoutComparingSpeculativePositions() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        oracle.capture(role: .ordinary, requestID: id, position: 0, tokenID: 1, logits: logits)
        oracle.capture(role: .ordinary, requestID: id, position: 1, tokenID: 2, logits: logits)
        XCTAssertTrue(selectAndEmit(oracle, role: .ordinary, requestID: id, ordinal: 0, tokenID: 1))
        oracle.finishRequest(role: .ordinary, requestID: id, emittedCount: 1)
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits, speculative: true)
        oracle.capture(role: .native, requestID: id, position: 1, tokenID: 2, logits: [.nan], speculative: true)
        oracle.resolveNativeRound(requestID: id, acceptedTokenIDs: [1])
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 1)
        XCTAssertTrue(oracle.summary().passed)
        XCTAssertEqual(oracle.summary().retainedVectors, 0)
    }

    func testAbortDropsTentativeVectorsWithoutRecordingFailure() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [1])
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 2, logits: [.nan], speculative: true)
        oracle.resolveNativeRound(requestID: id, acceptedTokenIDs: nil)
        XCTAssertNil(oracle.summary().firstFailure)
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits, speculative: true)
        oracle.resolveNativeRound(requestID: id, acceptedTokenIDs: [1])
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 1)
        XCTAssertTrue(oracle.summary().passed)
    }

    func testExactSampledTokenMismatchStopsFurtherPositions() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [0, 1])
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits)
        XCTAssertFalse(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "token_mismatch")
        XCTAssertEqual(oracle.summary().selectedPositions[0].ordinaryToken, 0)
        XCTAssertEqual(oracle.summary().selectedPositions[0].nativeToken, 1)
        oracle.capture(role: .native, requestID: id, position: 1, tokenID: 1, logits: logits)
        XCTAssertFalse(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 1, tokenID: 1))
        XCTAssertEqual(oracle.summary().selectedPositions.count, 1)
        XCTAssertEqual(oracle.summary().retainedVectors, 0)
    }

    func testThresholdIsInclusiveAndTop1RemainsExact() throws {
        for (delta, expected) in [(Float(0.05), true), (Float(0.05001), false)] {
            let oracle = NativeMTPLabNumericalOracle()
            try oracle.beginPair(requestID: id)
            reference(oracle, tokens: [1])
            oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: [delta, 1, 0.4])
            XCTAssertEqual(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1), expected)
            XCTAssertEqual(oracle.summary().selectedPositions[0].maxAbsDifference, delta)
        }
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [0], vectors: [[1, 0.99]])
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 0, logits: [0.99, 1])
        XCTAssertFalse(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 0))
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "top1_mismatch")
    }

    func testNonfiniteAndVocabularyMismatchFailClosed() throws {
        for vector: [Float] in [[.nan, 1, 0.4], [.infinity, 1, 0.4], [1, 2]] {
            let oracle = NativeMTPLabNumericalOracle()
            try oracle.beginPair(requestID: id)
            reference(oracle, tokens: [1])
            oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: vector)
            XCTAssertFalse(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
            XCTAssertNotNil(oracle.summary().firstFailure)
        }
    }

    func testDuplicateMissingAndOutOfOrderPositionsAreRejected() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        oracle.capture(role: .ordinary, requestID: id, position: 0, tokenID: 1, logits: logits)
        oracle.capture(role: .ordinary, requestID: id, position: 0, tokenID: 1, logits: logits)
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "duplicate_ordinary_position")
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [1])
        XCTAssertFalse(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "missing_native_vector")
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [1])
        XCTAssertFalse(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 1, tokenID: 1))
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "duplicate_or_missing_selection")
    }

    func testNativeDuplicateAndFailedRequestAreRejected() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [1])
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits)
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits)
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "duplicate_native_position")
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [1])
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 0, completed: false)
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "request_did_not_complete")
        XCTAssertEqual(oracle.summary().retainedVectors, 0)
    }

    func testTerminalMissingPositionsAndResetReleaseMemory() throws {
        let oracle = NativeMTPLabNumericalOracle()
        XCTAssertThrowsError(try oracle.beginPair(requestID: id, maxPositions: 0))
        XCTAssertThrowsError(try oracle.beginPair(requestID: id, maxPositions: 257))
        try oracle.beginPair(requestID: id, maxPositions: 1)
        reference(oracle, tokens: [1])
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 0)
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "native_emission_count_mismatch")
        XCTAssertEqual(oracle.summary().retainedVectors, 0)
        try oracle.beginPair(requestID: "next", maxPositions: 1)
        XCTAssertNil(oracle.summary().firstFailure)
        XCTAssertFalse(oracle.wantsCapture(requestID: id, position: 0))
        XCTAssertFalse(oracle.wantsCapture(requestID: "next", position: 1))
    }

    func testCaptureLimitBoundsVectorsButStillChecksTotalEmittedCount() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id, maxPositions: 1)
        reference(oracle, tokens: [1, 0])
        XCTAssertEqual(oracle.summary().retainedVectors, 1)
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits)
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
        // Beyond the vector limit, ordinal and terminal length checks remain.
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 1, tokenID: 0))
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 2)
        XCTAssertTrue(oracle.summary().passed)
        XCTAssertEqual(oracle.summary().selectedPositions.count, 1)
        XCTAssertEqual(oracle.summary().retainedVectors, 0)
    }

    func testOversizeVerifyBlockFailsClosedAndClearsVectors() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id, maxPositions: 16)
        reference(oracle, tokens: Array(repeating: 1, count: 9))
        for position in 0 ..< 9 {
            oracle.capture(
                role: .native, requestID: id, position: position, tokenID: 1,
                logits: logits, speculative: true)
        }
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "native_block_capacity")
        XCTAssertEqual(oracle.summary().retainedVectors, 0)
    }

    func testTerminalClassificationUsesExplicitSchedulerStopMetadata() {
        typealias Terminal = NativeMTPLabNumericalOracle.Terminal
        XCTAssertEqual(Terminal.classify(status: .stop, stopCause: .modelStop, toolBoundaryTokenCount: nil), .eos)
        XCTAssertEqual(Terminal.classify(status: .stop, stopCause: .requestStop, toolBoundaryTokenCount: nil), .stopSequence)
        XCTAssertEqual(Terminal.classify(status: .length, stopCause: nil, toolBoundaryTokenCount: nil), .maxTokens)
        XCTAssertEqual(Terminal.classify(status: .stop, stopCause: nil, toolBoundaryTokenCount: 3), .toolBoundary)
        XCTAssertEqual(Terminal.classify(status: .length, stopCause: .modelStop, toolBoundaryTokenCount: 3), .toolBoundary)
        // A bare "stop" is insufficient evidence for either EOS or a stop string.
        XCTAssertEqual(Terminal.classify(status: .stop, stopCause: nil, toolBoundaryTokenCount: nil), .other)
        XCTAssertEqual(Terminal.classify(status: .requestFailed, stopCause: .modelStop, toolBoundaryTokenCount: 3), .other)
    }

    func testReasoningObserverRequestStopUsesProductionMatchedStop() {
        typealias Terminal = NativeMTPLabNumericalOracle.Terminal
        // Reasoning-open caller stops share the serial-tool observer count.
        let observed = Terminal.classify(status: .stop, stopCause: nil, toolBoundaryTokenCount: 2)
        XCTAssertEqual(observed, .toolBoundary)
        XCTAssertEqual(Terminal.applyingMatchedRequestStop("done", to: observed), .stopSequence)
        // A request containing a stop is not proof that it actually matched:
        // only CompletionResult.stopSequence supplies this argument.
        XCTAssertEqual(Terminal.applyingMatchedRequestStop(nil, to: observed), .toolBoundary)
        XCTAssertEqual(Terminal.applyingMatchedRequestStop(nil, to: .eos), .eos)
        XCTAssertEqual(Terminal.applyingMatchedRequestStop(nil, to: .maxTokens), .maxTokens)
        XCTAssertNil(Terminal.applyingMatchedRequestStop("done", to: nil))
    }

    func testTerminalMetadataMatchesAndResetClearsIt() throws {
        let oracle = NativeMTPLabNumericalOracle()
        let terminals: [NativeMTPLabNumericalOracle.Terminal] = [.eos, .stopSequence, .maxTokens, .toolBoundary, .other]
        for terminal in terminals {
            try oracle.beginPair(requestID: id)
            XCTAssertNil(oracle.summary().ordinaryTerminal)
            XCTAssertNil(oracle.summary().nativeTerminal)
            reference(oracle, tokens: [1], terminal: terminal)
            oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits)
            XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
            oracle.finishRequest(role: .native, requestID: id, emittedCount: 1, terminal: terminal)
            XCTAssertTrue(oracle.summary().passed)
            XCTAssertEqual(oracle.summary().ordinaryTerminal, terminal)
            XCTAssertEqual(oracle.summary().nativeTerminal, terminal)
        }
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [1], terminal: .eos)
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits)
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 1, terminal: .stopSequence)
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "terminal_mismatch")
        XCTAssertFalse(oracle.summary().passed)
        XCTAssertEqual(oracle.summary().retainedVectors, 0)
    }

    func testNativeRoleOrdinaryFallbackNeedsNoSpeculativeFinalize() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [0, 1, 0], terminal: .maxTokens)
        // A request outside signed native eligibility follows ordinary decode
        // while the runtime retains the native comparison role.
        for (position, token) in [0, 1, 0].enumerated() {
            oracle.capture(role: .native, requestID: id, position: position, tokenID: token, logits: logits)
            XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: position, tokenID: token))
        }
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 3, terminal: .maxTokens)
        XCTAssertTrue(oracle.summary().passed)
        XCTAssertEqual(oracle.summary().positions.map(\.nativeToken), [0, 1, 0])
        XCTAssertEqual(oracle.summary().retainedVectors, 0)
    }

    func testDifferentSelectedEOSFailsDespiteIdenticalTerminalCause() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        oracle.capture(role: .ordinary, requestID: id, position: 0, tokenID: 1, logits: logits)
        XCTAssertTrue(selectAndEmit(oracle, role: .ordinary, requestID: id, ordinal: 0, tokenID: 1))
        oracle.capture(role: .ordinary, requestID: id, position: 1, tokenID: 0, logits: logits)
        XCTAssertTrue(oracle.select(role: .ordinary, requestID: id, position: 1, tokenID: 0))
        oracle.finishRequest(role: .ordinary, requestID: id, emittedCount: 1, terminal: .eos, selectedTokenIDs: [1, 0])
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits)
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
        oracle.capture(role: .native, requestID: id, position: 1, tokenID: 2, logits: logits, speculative: true)
        oracle.resolveNativeRound(requestID: id, acceptedTokenIDs: [2])
        XCTAssertFalse(oracle.select(role: .native, requestID: id, position: 1, tokenID: 2))
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 1, terminal: .eos, selectedTokenIDs: [1, 2])
        let result = oracle.summary()
        XCTAssertEqual(result.ordinaryTerminal, .eos)
        XCTAssertEqual(result.nativeTerminal, .eos)
        XCTAssertEqual(result.firstFailure?.reason, "token_mismatch")
        XCTAssertEqual(result.positions.count, 1)
        XCTAssertEqual(result.selectedPositions[1].ordinaryToken, 0)
        XCTAssertEqual(result.selectedPositions[1].nativeToken, 2)
        XCTAssertFalse(result.passed)
    }

    func testSelectedStopSuffixIsComparedWithoutBecomingBuyerVisible() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        let selected = [1, 0, 2]
        for (position, token) in selected.enumerated() {
            oracle.capture(role: .ordinary, requestID: id, position: position, tokenID: token, logits: logits)
            XCTAssertTrue(oracle.select(role: .ordinary, requestID: id, position: position, tokenID: token))
            if position == 0 { XCTAssertTrue(oracle.emit(role: .ordinary, requestID: id, ordinal: 0, tokenID: token)) }
        }
        oracle.finishRequest(role: .ordinary, requestID: id, emittedCount: 1, terminal: .stopSequence, selectedTokenIDs: selected)
        for (position, token) in selected.enumerated() {
            oracle.capture(role: .native, requestID: id, position: position, tokenID: token, logits: logits, speculative: true)
        }
        oracle.capture(role: .native, requestID: id, position: 3, tokenID: 2, logits: [.nan], speculative: true)
        oracle.resolveNativeRound(requestID: id, acceptedTokenIDs: selected)
        for (position, token) in selected.enumerated() {
            XCTAssertTrue(oracle.select(role: .native, requestID: id, position: position, tokenID: token))
            if position == 0 { XCTAssertTrue(oracle.emit(role: .native, requestID: id, ordinal: 0, tokenID: token)) }
        }
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 1, terminal: .stopSequence, selectedTokenIDs: selected)
        XCTAssertTrue(oracle.summary().passed)
        XCTAssertEqual(oracle.summary().positions.count, 1)
        XCTAssertEqual(oracle.summary().selectedPositions.map(\.nativeToken), selected)
        XCTAssertEqual(oracle.summary().ordinarySelectedCount, 3)
        XCTAssertEqual(oracle.summary().nativeSelectedCount, 3)
        XCTAssertEqual(oracle.summary().retainedVectors, 0)
    }

    func testTiedTop1AndFirstTokenEOSStillHaveNumericEvidence() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        let tied: [Float] = [1, 1, 0]
        oracle.capture(role: .ordinary, requestID: id, position: 0, tokenID: 1, logits: tied)
        XCTAssertTrue(oracle.select(role: .ordinary, requestID: id, position: 0, tokenID: 1))
        oracle.finishRequest(role: .ordinary, requestID: id, emittedCount: 0, terminal: .eos, selectedTokenIDs: [1])
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: tied)
        XCTAssertTrue(oracle.select(role: .native, requestID: id, position: 0, tokenID: 1))
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 0, terminal: .eos, selectedTokenIDs: [1])
        XCTAssertTrue(oracle.summary().passed)
        XCTAssertTrue(oracle.summary().positions.isEmpty)
        XCTAssertEqual(oracle.summary().selectedPositions[0].ordinaryTop1, 0)
        XCTAssertEqual(oracle.summary().selectedPositions[0].nativeTop1, 0)
        XCTAssertEqual(oracle.summary().selectedPositions[0].ordinaryGap, 0)
        XCTAssertEqual(oracle.summary().selectedPositions[0].nativeGap, 0)
    }

    func testCompletionCrossChecksActualSelectedTokenProvenance() throws {
        for actual in [[1, 0], [0]] {
            let oracle = NativeMTPLabNumericalOracle()
            try oracle.beginPair(requestID: id)
            oracle.capture(role: .ordinary, requestID: id, position: 0, tokenID: 1, logits: logits)
            XCTAssertTrue(selectAndEmit(oracle, role: .ordinary, requestID: id, ordinal: 0, tokenID: 1))
            oracle.finishRequest(role: .ordinary, requestID: id, emittedCount: 1, terminal: .maxTokens, selectedTokenIDs: actual)
            XCTAssertEqual(oracle.summary().firstFailure?.reason, "selected_token_provenance_mismatch")
            XCTAssertEqual(oracle.summary().retainedVectors, 0)
        }
    }

    func testCanonicalToolBoundaryExcludesFinalizedButUnappliedOverrun() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        reference(oracle, tokens: [1], terminal: .toolBoundary)
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: logits, speculative: true)
        oracle.capture(role: .native, requestID: id, position: 1, tokenID: 2, logits: [.nan], speculative: true)
        // Finalize can stage ahead of the canonical parser. Only the actual
        // selected prefix up to its boundary participates in the oracle.
        oracle.resolveNativeRound(requestID: id, acceptedTokenIDs: [1, 2])
        XCTAssertTrue(selectAndEmit(oracle, role: .native, requestID: id, ordinal: 0, tokenID: 1))
        oracle.finishRequest(role: .native, requestID: id, emittedCount: 1, terminal: .toolBoundary, selectedTokenIDs: [1])
        XCTAssertTrue(oracle.summary().passed)
        XCTAssertEqual(oracle.summary().selectedPositions.count, 1)
        XCTAssertEqual(oracle.summary().retainedVectors, 0)
    }

    func testEOSLogitFailureIsDetectedBeforeAnyVisibleEmission() throws {
        let oracle = NativeMTPLabNumericalOracle()
        try oracle.beginPair(requestID: id)
        oracle.capture(role: .ordinary, requestID: id, position: 0, tokenID: 1, logits: logits)
        XCTAssertTrue(oracle.select(role: .ordinary, requestID: id, position: 0, tokenID: 1))
        oracle.finishRequest(role: .ordinary, requestID: id, emittedCount: 0, terminal: .eos, selectedTokenIDs: [1])
        oracle.capture(role: .native, requestID: id, position: 0, tokenID: 1, logits: [0.1, 1, 0.4])
        XCTAssertFalse(oracle.select(role: .native, requestID: id, position: 0, tokenID: 1))
        XCTAssertEqual(oracle.summary().firstFailure?.reason, "logit_difference")
        XCTAssertTrue(oracle.summary().positions.isEmpty)
        XCTAssertEqual(oracle.summary().selectedPositions.count, 1)
    }
}
#endif
